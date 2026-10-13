//
//  TripClassifier+HomeMembership.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Home change reconciliation

    /// One stay's geometry + time, as a Sendable value for the pure
    /// `homeEffectiveStart` seam.
    nonisolated struct StayPoint: Sendable {
        let latitude: Double
        let longitude: Double
        let startTime: Date
    }

    /// One Home's ring + active window, as a Sendable value for the shared
    /// `matchesHome` rule.
    nonisolated struct HomeRing: Sendable {
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
        let startedAt: Date
        let endedAt: Date?
        /// The `Home.id` this ring mirrors — lets `withShapes` attach that
        /// home's `HomeAreaOverride` rows to the right membership. nil in
        /// pure-value tests that never consult overrides.
        var homeID: UUID?
        /// The measured home area; an unprimed ring falls back to its declared radius.
        var membership: HomeMembership?
        /// False for a temporary home: it claims stays inside its own dates
        /// only, and is ignored when deciding whether a stay predates every home.
        var claimsPrehistory: Bool = true
        var isTemporary: Bool = false

        /// The seed shape alone — read-only convenience for logging and for
        /// pins that assert which seed substituted. Membership decisions must
        /// go through `membership`, never through this.
        var shape: HomeShape? { membership?.seed }

        /// The inclusive window the ring claims stays in. A reversed window
        /// (end before start) clamps to a single instant because `DateInterval`
        /// traps on reversed ranges; `matchesHome` and `gateMemberships` test
        /// the raw dates first, so such a ring never reaches a membership read.
        var era: DateInterval {
            DateInterval(start: startedAt, end: max(startedAt, endedAt ?? .distantFuture))
        }

        init(latitude: Double, longitude: Double, radiusKm: Double,
             startedAt: Date, endedAt: Date?, homeID: UUID? = nil,
             membership: HomeMembership? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.radiusKm = radiusKm
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.homeID = homeID
            self.membership = membership
        }

        /// The ring of one classification anchor, carrying its kind.
        init(_ anchor: HomeAnchor) {
            self.init(latitude: anchor.latitude, longitude: anchor.longitude,
                      radiusKm: anchor.radiusKm, startedAt: anchor.startedAt,
                      endedAt: anchor.endedAt, homeID: anchor.id)
            claimsPrehistory = !anchor.isTemporary
            isTemporary = anchor.isTemporary
        }

        /// Attach seed-only membership; full membership also carries orbit discs.
        func withShape(_ shape: HomeShape?) -> HomeRing {
            withMembership(shape.map { HomeMembership(seed: $0) })
        }

        func withMembership(_ membership: HomeMembership?) -> HomeRing {
            var ring = self
            ring.membership = membership
            return ring
        }
    }

    nonisolated static func shapeKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f,%.5f", latitude, longitude)
    }

    /// Prime shapes before invoking synchronous cores; seeds are memoized and orbit inputs are re-read.
    /// A seeds-only prime neither reads nor changes orbit state.
    /// Returns false when a required read fails; the previous orbit memo is kept.
    /// `realHomesOnly` skips the temporary-home read, for Welcome Home's seeds.
    @discardableResult
    func primeHomeShapes(seedsOnly: Bool = false, realHomesOnly: Bool = false) async -> Bool {
        let homes: [HomeAnchor]
        do {
            homes = try realHomesOnly
                ? fetchRequiredHomes().map { HomeAnchor($0) } : fetchRequiredAnchors()
        } catch {
            logger.error("Home shapes not primed; homes unreadable: \(error.localizedDescription)")
            return false
        }
        for home in homes {
            let key = Self.shapeKey(home.latitude, home.longitude)
            guard resolvedHomeShapes[key] == nil else { continue }
            let shape = await HomeShapeProvider.shared.shape(
                latitude: home.latitude, longitude: home.longitude)
            resolvedHomeShapes[key] = shape
            let dstar = String(format: "%.2f", shape.areaEquivalentRadiusKm)
            switch shape.seed {
            case .urbanCentre(let id, let name):
                let label = name ?? "(unnamed)"
                logger.info("Home shape: urban centre \(label, privacy: .private) #\(id, privacy: .private), \(shape.areaKm2, privacy: .private) km2, D* \(dstar, privacy: .private) km")
            case .fallbackDisc:
                logger.info("Home shape: no urban centre — 1 km disc + learned orbit define this home (declared radius is vestigial). Expected for a rural home.")
            }
        }
        if !seedsOnly {
            return primeHomeOrbits(anchors: homes)
        }
        return true
    }

    /// Derive orbit discs from live, non-transit evidence and seed-only excursions in each home era.
    /// Exclude overrides bar clusters; results feed withShapes and homeAreaFingerprint.
    @discardableResult
    func primeHomeOrbits(anchors: [HomeAnchor], stays suppliedStays: [Stay]? = nil,
        overrides suppliedOverrides: [HomeAreaOverride]? = nil) -> Bool {
        // A temporary home learns no orbit: a semester of day trips to one
        // nearby town is three same-day returns, and a disc there would stop
        // the next visit from being a trip. Its area is its seed plus the
        // includes and excludes the user taught it.
        let homes = anchors.filter { !$0.isTemporary }
        guard let start = homes.map(\.startedAt).min(),
              let end = homes.map({ $0.endedAt ?? .distantFuture }).max() else {
            resolvedHomeOrbits = [:]
            resolvedHomeOrbitInputDigests = [:]
            return true
        }
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime >= start && $0.startTime <= end },
            sortBy: [SortDescriptor(\.startTime)])
        descriptor.propertiesToFetch = [\.id, \.startTime, \.endTime,
            \.centroidLatitude, \.centroidLongitude, \.isAirport, \.sourceRaw]
        let allStays: [Stay]
        let overrides: [HomeAreaOverride]
        do {
            #if DEBUG
            if failOrbitEvidenceReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            allStays = try suppliedStays ?? modelContext.fetch(descriptor)
            overrides = try suppliedOverrides ?? modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
        } catch {
            logger.error("Home orbits kept; evidence unreadable: \(error.localizedDescription)")
            return false
        }
        var orbits: [String: [HomeOrbit.OrbitDisc]] = [:]
        var digests: [String: SHA256.Digest] = [:]
        for home in homes {
            let key = Self.shapeKey(home.latitude, home.longitude)
            guard let seed = resolvedHomeShapes[key] else { continue }
            let windowEnd = home.endedAt ?? .distantFuture
            let stays = allStays
                .filter { $0.startTime >= home.startedAt && $0.startTime <= windowEnd }
            let excludes = overrides
                .filter { ($0.homeID == nil || $0.homeID == home.id) && $0.kind == .exclude }
                .map { (latitude: $0.centerLatitude, longitude: $0.centerLongitude,
                        radiusKm: $0.radiusKm) }
            let homeKey = home.id.uuidString
            let digest = homeOrbitInputDigest(home: home, seed: seed, stays: stays, excludes: excludes)
            digests[homeKey] = digest
            if resolvedHomeOrbitInputDigests[homeKey] == digest,
               let cached = resolvedHomeOrbits[homeKey] {
                orbits[homeKey] = cached
                continue
            }
            let observations = stays.map {
                HomeOrbit.StayObservation(
                    id: $0.id, start: $0.startTime, end: $0.endTime,
                    latitude: $0.centroidLatitude, longitude: $0.centroidLongitude,
                    isTransitNode: $0.isAirport,
                    isLive: $0.sourceRaw == DataSource.liveSLC.rawValue
                         || $0.sourceRaw == DataSource.merged.rawValue)
            }
            #if DEBUG
            orbitDerivationCountForTesting += 1
            #endif
            let discs = HomeOrbit.deriveDiscs(
                observations: observations, seed: seed, excludes: excludes)
                .compactMap(\.disc)
            // Key orbits by home identity because repeated coordinates can have distinct evidence eras;
            // seed shapes remain coordinate-keyed.
            orbits[homeKey] = discs
            if !discs.isEmpty {
                logger.info("Home orbit: \(discs.count, privacy: .public) learned disc(s) for the home at \(key, privacy: .private).")
            }
        }
        resolvedHomeOrbits = orbits
        resolvedHomeOrbitInputDigests = digests
        return true
    }

    private func homeOrbitInputDigest(
        home: HomeAnchor, seed: HomeShape, stays: [Stay],
        excludes: [(latitude: Double, longitude: Double, radiusKm: Double)]
    ) -> SHA256.Digest {
        var data = Data()
        func appendBits(_ value: UInt64) {
            var bits = value.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        func appendDouble(_ value: Double) { appendBits(value.bitPattern) }
        func appendUUID(_ value: UUID) {
            var bytes = value.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        // Length-prefix variable-sized sequences to keep the encoding unambiguous.
        func appendString(_ value: String) {
            appendBits(UInt64(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }
        appendUUID(home.id)
        appendDouble(home.startedAt.timeIntervalSinceReferenceDate)
        appendBits(home.endedAt == nil ? 0 : 1)
        appendDouble((home.endedAt ?? .distantFuture).timeIntervalSinceReferenceDate)
        switch seed.seed {
        case .fallbackDisc:
            appendBits(0)
        case .urbanCentre(let id, let name):
            appendBits(1)
            appendBits(UInt64(bitPattern: id))
            appendBits(name == nil ? 0 : 1)
            appendString(name ?? "")
        }
        appendDouble(seed.centreLatitude)
        appendDouble(seed.centreLongitude)
        appendDouble(seed.areaKm2)
        appendBits(UInt64(seed.rings.count))
        for polygon in seed.rings {
            appendBits(UInt64(polygon.count))
            for ring in polygon {
                appendBits(UInt64(ring.count))
                for coordinate in ring { appendDouble(coordinate) }
            }
        }
        appendBits(UInt64(stays.count))
        for stay in stays {
            appendUUID(stay.id)
            appendDouble(stay.startTime.timeIntervalSinceReferenceDate)
            appendDouble(stay.endTime.timeIntervalSinceReferenceDate)
            appendDouble(stay.centroidLatitude)
            appendDouble(stay.centroidLongitude)
            appendBits(stay.isAirport ? 1 : 0)
            appendString(stay.sourceRaw)
        }
        appendBits(UInt64(excludes.count))
        for exclude in excludes {
            appendDouble(exclude.latitude)
            appendDouble(exclude.longitude)
            appendDouble(exclude.radiusKm)
        }
        return SHA256.hash(data: data)
    }

    /// Attach primed memberships; an unprimed coordinate retains its legacy circle.
    func withShapes(_ rings: [HomeRing], overrides suppliedOverrides: [HomeAreaOverride]? = nil) -> [HomeRing] {
        // User overrides attach to each matching home, with nil-homeID rows applying everywhere.
        let overrides = suppliedOverrides ?? ((try? modelContext.fetch(
            FetchDescriptor<HomeAreaOverride>())) ?? [])
        return rings.map { ring in
            let key = Self.shapeKey(ring.latitude, ring.longitude)
            guard let shape = resolvedHomeShapes[key] else { return ring }
            let mine = overrides.filter { $0.homeID == nil || $0.homeID == ring.homeID }
            let includes = mine.filter { $0.kind == .include }
                .map { (latitude: $0.centerLatitude, longitude: $0.centerLongitude,
                        radiusKm: $0.radiusKm) }
            let excludes = mine.filter { $0.kind == .exclude }
                .map { (latitude: $0.centerLatitude, longitude: $0.centerLongitude,
                        radiusKm: $0.radiusKm) }
            // Clamp discs to their home era so a former home cannot claim a later routine.
            // The membership itself stays undated: the ring's readers apply its window.
            let era = ring.era
            let discs: [HomeOrbit.OrbitDisc] =
                (ring.homeID.flatMap { resolvedHomeOrbits[$0.uuidString] } ?? [])
                .compactMap { $0.clamped(toEra: era) }
            return ring.withMembership(HomeMembership(
                seed: shape,
                orbitDiscs: discs,
                includeDiscs: includes, excludeDiscs: excludes))
        }
    }

    #if DEBUG
    /// Test seam for priming shapes without the asynchronous geocoder; unavailable in Release.
    func primeShapeForTesting(latitude: Double, longitude: Double, shape: HomeShape) {
        resolvedHomeShapes[Self.shapeKey(latitude, longitude)] = shape
    }
    #endif

    /// The collapsed temporary anchors, then every tripless destination and transit
    /// stay (the rows assembly groups) as a sorted multiset: a same-id twin arriving,
    /// leaving or diverging changes it, and no fetch order does. A transit row goes in
    /// whole. A destination row gives its start and, for each ring the gate reads,
    /// real or temporary, whether the ring's area holds it: its end and its exact place
    /// are its fingerprint's, judged with the dwell and jitter allowances a growing live
    /// stay needs, but a move inside that allowance across an area's edge changes where
    /// a run closes. `rings` carry their measured areas (`withShapes`) in the same order
    /// on both sides; an unprimed area falls back to its circle and only re-arms the check.
    static func suppressionInputDigest(
        rings: [HomeRing], stays: [Stay]
    ) -> SHA256.Digest {
        let temporaryRings = rings.filter(\.isTemporary)
        func bits(_ value: UInt64, into data: inout Data) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        func uuid(_ value: UUID, into data: inout Data) {
            var bytes = value.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        var data = Data()
        bits(UInt64(temporaryRings.count), into: &data)
        for ring in temporaryRings {
            bits(ring.homeID == nil ? 0 : 1, into: &data)
            if let id = ring.homeID { uuid(id, into: &data) }
            bits(ring.latitude.bitPattern, into: &data)
            bits(ring.longitude.bitPattern, into: &data)
            bits(ring.radiusKm.bitPattern, into: &data)
            bits(ring.startedAt.timeIntervalSinceReferenceDate.bitPattern, into: &data)
            bits(ring.endedAt == nil ? 0 : 1, into: &data)
            bits((ring.endedAt ?? .distantFuture).timeIntervalSinceReferenceDate.bitPattern,
                 into: &data)
        }
        func inArea(_ ring: HomeRing, _ stay: Stay) -> Bool {
            if let membership = ring.membership {
                return membership.contains(latitude: stay.centroidLatitude,
                                           longitude: stay.centroidLongitude, at: stay.startTime)
            }
            return HomeOrbit.greatCircleKm(stay.centroidLatitude, stay.centroidLongitude,
                                           ring.latitude, ring.longitude) <= ring.radiusKm
        }
        let rows: [Data] = stays.map { stay in
            let isTransit = stay.category == .transit
            var row = Data()
            uuid(stay.id, into: &row)
            bits(isTransit ? 1 : 0, into: &row)
            var fields: [UInt64] = [
                stay.startTime.timeIntervalSinceReferenceDate.bitPattern,
                stay.isAirport ? 1 : 0,
                stay.userOverridden ? 1 : 0,
            ]
            if isTransit {
                fields += [
                    stay.endTime.timeIntervalSinceReferenceDate.bitPattern,
                    stay.centroidLatitude.bitPattern,
                    stay.centroidLongitude.bitPattern,
                ]
            } else {
                fields += rings.map { inArea($0, stay) ? 1 : 0 }
            }
            for value in fields { bits(value, into: &row) }
            return row
        }
        bits(UInt64(rows.count), into: &data)
        // Rows differ in width, so each carries its length.
        for row in rows.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            bits(UInt64(row.count), into: &data)
            data.append(row)
        }
        return SHA256.hash(data: data)
    }

    /// One suppressed stay's decision inputs as the gate last saw them.
    nonisolated struct SuppressedStayFingerprint: Sendable, Equatable {
        /// A centroid or home-distance move of at least this much re-arms the
        /// gate. Matches the foreground thinner's spacing so jitter below one
        /// kept fix never counts.
        nonisolated static let homeDistanceToleranceKm: Double = 0.25

        let startTime: Date
        let endTime: Date
        let distanceFromHomeKm: Double
        let centroidLatitude: Double
        let centroidLongitude: Double
        let isAirport: Bool
        /// Earliest `endTime` at which the stay's group could clear θ by
        /// dwell alone; nil means no amount of dwell can.
        let accretionClearsAt: Date?

        /// Whether the stay, as stored now, is still the suppressed steady
        /// state the gate already decided on.
        func excuses(
            startTime: Date,
            endTime: Date,
            distanceFromHomeKm: Double,
            centroidLatitude: Double,
            centroidLongitude: Double,
            isAirport: Bool
        ) -> Bool {
            guard startTime == self.startTime else { return false }
            guard isAirport == self.isAirport else { return false }
            let centroidDisplacementKm = CLLocation(
                latitude: centroidLatitude, longitude: centroidLongitude
            ).distance(from: CLLocation(
                latitude: self.centroidLatitude, longitude: self.centroidLongitude
            )) / 1000.0
            guard centroidDisplacementKm.isFinite,
                  centroidDisplacementKm < Self.homeDistanceToleranceKm else { return false }
            if distanceFromHomeKm != self.distanceFromHomeKm {
                let moved = abs(distanceFromHomeKm - self.distanceFromHomeKm)
                guard moved.isFinite, moved < Self.homeDistanceToleranceKm else { return false }
            }
            if endTime == self.endTime { return true }
            guard endTime > self.endTime else { return false }
            guard let accretionClearsAt else { return true }
            return endTime < accretionClearsAt
        }
    }

    /// THE home-classification predicate, shared verbatim by
    /// `preFilterStays` (stamping `.home`) and `applyHomeChangeCore`'s
    /// stale-home pass (UNstamping after a ring shrank or moved). Pass 1:
    /// any home whose active window covers the stay's start and whose ring
    /// contains it. Pass 2: for stays that predate EVERY home record, and only
    /// while the user still has a current home, EVERY registered ring — ended
    /// ones included (the fallback that classifies pre-history stays without
    /// letting it override a legitimate gap between two historical homes).
    /// Same CLLocation great-circle math as `Home.contains`.
    nonisolated static func matchesHome(
        stayStart: Date,
        latitude: Double,
        longitude: Double,
        homes: [HomeRing]
    ) -> Bool {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        func inRing(_ home: HomeRing) -> Bool {
            // Evaluate measured membership at the stay's time so learned discs cannot claim unrelated eras;
            // fall back to the declared radius when no membership is attached.
            if let membership = home.membership {
                return membership.contains(latitude: latitude, longitude: longitude,
                                           at: stayStart)
            }
            return CLLocation(latitude: home.latitude, longitude: home.longitude)
                .distance(from: location) / 1000.0 <= home.radiusKm
        }
        for home in homes {
            if let endedAt = home.endedAt, stayStart > endedAt { continue }
            if home.startedAt > stayStart { continue }
            if inRing(home) { return true }
        }
        // Prehistory requires a current home but may match ended rings to preserve historical boundaries.
        // It belongs to real homes: a temporary ring neither counts as a home the stay must predate nor claims it.
        let hasCurrentHome = homes.contains { $0.claimsPrehistory && $0.endedAt == nil }
        if hasCurrentHome, homes.allSatisfy({ !$0.claimsPrehistory || stayStart < $0.startedAt }) {
            for home in homes where home.claimsPrehistory {
                // Prehistory uses the seed and time-valid orbit discs; timeless taught includes must not claim earlier history.
                if let membership = home.membership {
                    if membership.contains(latitude: latitude, longitude: longitude,
                                           at: stayStart, includeTaught: false) {
                        return true
                    }
                } else if inRing(home) {
                    return true
                }
            }
        }
        return false
    }

    /// The temporary home that makes a stay home, which its home writers record
    /// as `Stay.temporaryHomeID`: nil when a real Home's ring claims the stay
    /// (pass 1 or the real-only prehistory pass), else the id of the first
    /// temporary ring whose dated match claims it. `rings` must be in
    /// `HomeAnchors.fetch` order (Homes, then temporary homes by start, then
    /// id) so every caller names the same owner. Given temporary rings only,
    /// it is the first temporary claimant whatever a real Home claims.
    nonisolated static func temporaryOwner(
        stayStart: Date, latitude: Double, longitude: Double, rings: [HomeRing]
    ) -> UUID? {
        let real = rings.filter { !$0.isTemporary }
        if !real.isEmpty,
           matchesHome(stayStart: stayStart, latitude: latitude, longitude: longitude, homes: real) {
            return nil
        }
        // One temporary ring has no prehistory pass: this is its dated match.
        return rings.first {
            $0.isTemporary
                && matchesHome(stayStart: stayStart, latitude: latitude, longitude: longitude,
                               homes: [$0])
        }?.homeID
    }

    /// `HomeAnchors.fetch`'s order, which `temporaryOwner` reads, for anchors
    /// assembled by hand: Homes as given, then temporary homes by start, then id.
    nonisolated static func canonicalAnchorOrder(_ anchors: [HomeAnchor]) -> [HomeAnchor] {
        anchors.filter { !$0.isTemporary } + anchors.filter(\.isTemporary).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// MUST mirror matchesHome's era and prehistory rules. A ring participates if its inclusive
    /// window covers any member start; min-over-shapes scoring favors suppression across home changes.
    /// Groups predating every home score against all rings only while a current home exists;
    /// a group in a gap between home eras gets no membership and the gate declines.
    /// A temporary home's membership carries its dates, so a member they do not cover
    /// is scored against the other homes, never the base.
    nonisolated static func gateMemberships(
        stayStarts: [Date], rings: [HomeRing]
    ) -> [HomeMembership] {
        var memberships: [HomeMembership] = []
        for ring in rings {
            guard let membership = ring.membership else { continue }
            let inWindow = stayStarts.contains { start in
                if let endedAt = ring.endedAt, start > endedAt { return false }
                return ring.startedAt <= start
            }
            guard inWindow else { continue }
            // A real Home's membership stays undated: a group that straddles a home
            // change is scored against both homes, which favors suppression on purpose.
            // A temporary home is home for no instant outside its dates (`matchesHome`
            // pass 1 only, no prehistory), so its membership carries them.
            memberships.append(ring.isTemporary ? membership.clamped(toEra: ring.era) : membership)
        }
        // The prehistory fallback mirrors matchesHome pass 2: real-home rings only. A group
        // that predates them all has no real-home ring in window, so only a temporary
        // ring whose dates cover it can already be in `memberships`.
        if rings.contains(where: { $0.claimsPrehistory && $0.endedAt == nil }),
           !stayStarts.isEmpty,
           stayStarts.allSatisfy({ start in
               rings.allSatisfy { !$0.claimsPrehistory || start < $0.startedAt }
           }) {
            return memberships + rings.filter(\.claimsPrehistory).compactMap(\.membership)
        }
        return memberships
    }

    /// When a user registers a home AFTER arriving there (the "I moved to
    /// another country" flow: end home A in Settings, create home B at the
    /// destination), the home's `startedAt` defaults to NOW — which
    /// excludes the very stays that should have classified `.home` and
    /// closed the in-flight trip (`preFilterStays` Pass 1 requires
    /// `startedAt <= stay.startTime`). The honest effective date is the
    /// start of the user's CONTIGUOUS trailing presence inside the new
    /// ring: walk back from the most recent stay while stays remain
    /// in-ring; the earliest of that run is when "living here" began.
    /// Returns nil when the most recent stay is outside the ring (the
    /// user is registering a place they aren't currently at — e.g. a
    /// future home — where `startedAt = now` is already correct) or when
    /// there are no stays. A historical visit to the same place years ago
    /// stays a trip: the first out-of-ring stay breaks the walk.
    nonisolated static func homeEffectiveStart(
        homeLatitude: Double,
        homeLongitude: Double,
        radiusKm: Double,
        membership: HomeMembership? = nil,
        stays: [StayPoint]
    ) -> Date? {
        let homeLocation = CLLocation(latitude: homeLatitude, longitude: homeLongitude)
        var earliest: Date?
        for point in stays.sorted(by: { $0.startTime > $1.startTime }) {
            // Use the same geometry as matchesHome so backdating cannot include stays outside measured coverage.
            let inside: Bool
            if let membership {
                inside = membership.contains(latitude: point.latitude,
                                             longitude: point.longitude,
                                             at: point.startTime)
            } else {
                inside = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    .distance(from: homeLocation) / 1000.0 <= radiusKm
            }
            guard inside else { break }
            earliest = point.startTime
        }
        return earliest
    }
}
