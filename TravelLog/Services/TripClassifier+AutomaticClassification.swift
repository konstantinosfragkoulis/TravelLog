//
//  TripClassifier+AutomaticClassification.swift
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

    // MARK: - Automatic classification

    /// The trip detail's "Automatic" for a stay the user set (any other is left as it
    /// is), in one gated unit and save: its setting goes and the pre-filter, duration
    /// rules and heuristics judge it again on its trip (the model lane skips edited
    /// trips). Every live temporary home holding it is then queued (`stage`) and drained
    /// after the gate, so its trip splits as any covered trip. False, with nothing
    /// changed or queued, when the stay is gone or a read, the judging or the save failed.
    func resetStayToAutomatic(
        stayID: UUID,
        gate: PipelineGate = .shared,
        stage: @escaping @MainActor @Sendable (UUID) -> Void = {
            _ = CoverageReconciliationQueue.stage(.temporaryHome, id: $0)
        },
        drain: @escaping @MainActor @Sendable () async -> Void = {
            _ = await CoverageReconciliationQueue.drainIfNeeded()
        }
    ) async -> Bool {
        let reset = await gate.runReturning(touching: [.stay, .trip]) {
            guard await self.primeHomeShapes() else { return AutomaticReset?.none }
            return await self.resetStayToAutomaticCore(stayID: stayID)
        }
        guard let reset else { return false }
        guard reset.changed else { return true }
        await MainActor.run {
            for id in reset.temporaryHomeIDs { stage(id) }
        }
        _ = await classifyAndAssembleTripsQueuedWithGates(maxStaysPerCall: nil, gate: gate)
        await drain()
        return true
    }

    private nonisolated struct AutomaticReset: Sendable {
        let changed: Bool
        /// The live temporary homes whose dates and area hold the stay.
        let temporaryHomeIDs: [UUID]
    }

    /// `resetStayToAutomatic`'s unit: every read first, then each physical
    /// row of the stay the user set loses its setting and is judged again,
    /// a trip whose stay changed category gets a fresh summary, and one save.
    /// Nil when the stay is gone or a read, the judging or the save failed;
    /// the context is then rolled back.
    private func resetStayToAutomaticCore(stayID: UUID) -> AutomaticReset? {
        let id = stayID
        let rows: [Stay]
        let rings: [HomeRing]
        let timeline: [Stay]
        do {
            rows = try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id }))
            rings = withShapes(try fetchRequiredAnchors().map { Self.HomeRing($0) },
                               overrides: try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()))
            timeline = try orderedClassificationStays(in: modelContext)
        } catch {
            logger.error("Automatic classification skipped; unreadable: \(error.localizedDescription)")
            return nil
        }
        guard !rows.isEmpty else { return nil }
        let userSet = rows.filter(\.userOverridden)
        guard let stay = userSet.first else { return AutomaticReset(changed: false, temporaryHomeIDs: []) }
        // A temporary ring's own dated match, as `temporaryOwner` reads one.
        let holders = rings.filter {
            $0.isTemporary && Self.matchesHome(
                stayStart: stay.startTime, latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude, homes: [$0])
        }.compactMap(\.homeID)

        func rollBack(_ reason: String) -> AutomaticReset? {
            modelContext.rollback()
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("Automatic classification rolled back: \(reason, privacy: .public)")
            return nil
        }
        let before = userSet.map(\.categoryRaw)
        for row in userSet {
            row.userOverridden = false
            row.category = .unclassified
        }
        guard preFilterStays(userSet) >= 0 else { return rollBack("the pre-filter could not read its dependencies") }
        let settled = resolveDeterministicOutcomes(userSet)
        registerStage2aProvenance(settled.resolved, asFM: false)
        _ = classifyWithHeuristics(stays: settled.ambiguous, ordered: timeline)
        guard userSet.allSatisfy({ $0.category != .unclassified }) else {
            return rollBack("the stay was left unclassified")
        }
        // What the trip shows depends on its stays' categories.
        var refreshed = Set<ObjectIdentifier>()
        for (row, old) in zip(userSet, before) where row.categoryRaw != old {
            guard let trip = row.trip, refreshed.insert(ObjectIdentifier(trip)).inserted else { continue }
            TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
            guard trip.recomputeSummary() else { return rollBack("home places unreadable for a trip summary") }
        }
        guard saveReconciliation(unit: "Automatic classification") else { return nil }
        return AutomaticReset(changed: true, temporaryHomeIDs: holders)
    }

    /// Free home stays only within removed coverage and only when matchesHome disclaims them at their own time.
    /// The follow-up pipeline rejudges them; do not revisit unrelated home geometry.
    /// includingSacred withdraws Arm B's own home overrides when an include is removed, returning those stays to pipeline control.
    /// A temporary home's stamp is freed only as its own unit may free it (`automaticReleaseAllows`).
    func unHomeStays(
        nearLatitude latitude: Double, longitude: Double, radiusKm: Double,
        includingSacred: Bool = false, persistChanges: Bool = true
    ) throws -> Int {
        #if DEBUG
        if failUnHomeStaysFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
            .filter { !$0.isDeleted }
        let anchors = try fetchAnchorsForHomeAreaHealing()
        let homeRings = withShapes(anchors.anchors.map { Self.HomeRing($0) }, overrides: overrides)
        // Fetch only .home candidates in a conservative box; the filter below stays the authority.
        let homeRaw = StayCategory.home.rawValue
        let dLat = radiusKm / 110.0 * 1.05 + 0.001
        let minLat = latitude - dLat, maxLat = latitude + dLat
        let maxAbsLat = Swift.min(89.0, Swift.max(abs(minLat), abs(maxLat)))
        let dLon = dLat / cos(maxAbsLat * .pi / 180)
        let descriptor: FetchDescriptor<Stay>
        if maxAbsLat < 89.0 && longitude - dLon > -180 && longitude + dLon < 180 {
            let minLon = longitude - dLon, maxLon = longitude + dLon
            descriptor = FetchDescriptor(predicate: #Predicate<Stay> {
                $0.categoryRaw == homeRaw
                && $0.centroidLatitude >= minLat && $0.centroidLatitude <= maxLat
                && $0.centroidLongitude >= minLon && $0.centroidLongitude <= maxLon
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate<Stay> {
                $0.categoryRaw == homeRaw
                && $0.centroidLatitude >= minLat && $0.centroidLatitude <= maxLat
            })
        }
        let stays = try fetchForHomeAreaHealing(descriptor)
            .filter { stay in
                stay.category == .home
                && (includingSacred || !stay.userOverridden)
                && HomeOrbit.greatCircleKm(stay.centroidLatitude, stay.centroidLongitude,
                                           latitude, longitude) <= radiusKm
                && Self.automaticReleaseAllows(
                    stay, liveRevisions: anchors.revisions, removedIDs: anchors.removedIDs)
            }
        var freed = 0
        for stay in stays {
            let claimed = Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings)
            if !claimed {
                stay.category = .unclassified
                stay.userOverridden = false
                freed += 1
            }
        }
        if freed > 0 {
            #if DEBUG
            if shouldFailNextUnHomeStaysSaveForTesting {
                shouldFailNextUnHomeStaysSaveForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            do {
                if persistChanges { try modelContext.save() }
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        return freed
    }

    /// Re-prime using checked reads, including the staged override insertion/deletion.
    func primeOverrideRemovalOrbits() throws {
        let anchors = try HomeAnchors.fetch(in: modelContext)
        let stays = try modelContext.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)]))
        let overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
            .filter { !$0.isDeleted }
        primeHomeOrbits(anchors: anchors, stays: stays, overrides: overrides)
    }

    /// Remove coverage and free its stranded stays in one commit.
    /// Returns false for a vanished row or a dependency read/save failure.
    func removeOverride(id: UUID) async -> Bool {
        let removed = removeOverrideRows(unit: "Override removal") { rows in
            rows.first(where: { $0.id == id }).map { [$0] } ?? []
        }
        return (removed ?? 0) > 0
    }

    /// Withdraw one taught place in every Home era: every row with this kind
    /// and centre, carried copies included, in one commit. Rows are selected
    /// inside the caller's gate unit, so a copy made while the request waited
    /// goes too. False when no row matches or a read/save fails.
    func removeOverrides(kindRaw: String, latitude: Double, longitude: Double) async -> Bool {
        let key = HomeAreaOverrideDeduplicator.placeKey(
            kindRaw: kindRaw, latitude: latitude, longitude: longitude)
        let removed = removeOverrideRows(unit: "Place removal") { rows in
            rows.filter {
                HomeAreaOverrideDeduplicator.placeKey(
                    kindRaw: $0.kindRaw, latitude: $0.centerLatitude,
                    longitude: $0.centerLongitude) == key
            }
        }
        return (removed ?? 0) > 0
    }

    /// Deletes the selected rows, re-primes once, frees the stays each removed
    /// include had claimed, then saves once. Nil when a read or the save
    /// failed; the unit and the orbit memo are then rolled back.
    func removeOverrideRows(
        unit: String,
        select: ([HomeAreaOverride]) -> [HomeAreaOverride]
    ) -> Int? {
        let previousOrbits = resolvedHomeOrbits
        let previousDigests = resolvedHomeOrbitInputDigests
        do {
            let rows = select(try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
                .filter { !$0.isDeleted })
            guard !rows.isEmpty else { return 0 }
            var footprints: [CoverageDisc] = []
            for row in rows {
                if row.kind == .include {
                    let footprint = CoverageDisc(latitude: row.centerLatitude,
                                                 longitude: row.centerLongitude,
                                                 radiusKm: row.radiusKm)
                    if !footprints.contains(footprint) { footprints.append(footprint) }
                }
                modelContext.delete(row)
            }
            try primeOverrideRemovalOrbits()
            for footprint in footprints {
                // Withdrawing taught coverage also frees the sacred stays it created.
                _ = try unHomeStays(nearLatitude: footprint.latitude,
                    longitude: footprint.longitude, radiusKm: footprint.radiusKm,
                    includingSacred: true, persistChanges: false)
            }
            try modelContext.save()
            return rows.count
        } catch {
            modelContext.rollback()
            resolvedHomeOrbits = previousOrbits
            resolvedHomeOrbitInputDigests = previousDigests
            logger.error("\(unit, privacy: .public) rolled back: \(error.localizedDescription)")
            return nil
        }
    }

    func fetchForHomeAreaHealing<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) throws -> [T] {
        #if DEBUG
        homeAreaHealingFetchCallCountForTesting += 1
        if failingHomeAreaHealingFetchCallForTesting
            == homeAreaHealingFetchCallCountForTesting {
            failingHomeAreaHealingFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try modelContext.fetch(descriptor)
    }

    /// Healing's anchors, with each live temporary home's revision and the
    /// removed ids from the same read. The Home read keeps its place in the
    /// counted fetch order; an unreadable temporary-home table fails the unit
    /// with it.
    func fetchAnchorsForHomeAreaHealing() throws -> (
        anchors: [HomeAnchor], revisions: [UUID: Int], removedIDs: Set<UUID>
    ) {
        let homes = try fetchForHomeAreaHealing(FetchDescriptor<Home>())
        let declarations = try fetchRequiredTemporaryHomeDeclarations()
        return (homes.map { HomeAnchor($0) } + declarations.anchors,
                declarations.revisions, declarations.removedIDs)
    }

    /// Persist previous learned/taught footprints for shrink repair because derived discs are not stored elsewhere;
    /// membership may shrink without an override-removal event.
    nonisolated struct CoverageDisc: Codable, Sendable, Equatable, Hashable {
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
    }

    /// The current pass's learned + taught coverage (orbit discs and
    /// include overrides; the seed is immutable and never needs a shrink
    /// repair). Primes first so the answer reflects the present store.
    func homeAreaCoverage() async throws -> [CoverageDisc] {
        // A failed prime keeps the previous orbit memo; stamping it as the
        // shrink arm's snapshot would record stale geometry as current.
        guard await primeHomeShapes() else { throw CocoaError(.fileReadUnknown) }
        var out: [CoverageDisc] = resolvedHomeOrbits.values.flatMap { discs in
            discs.map { CoverageDisc(latitude: $0.centerLatitude,
                                     longitude: $0.centerLongitude,
                                     radiusKm: $0.radiusKm) }
        }
        let includes = try fetchForHomeAreaHealing(
            FetchDescriptor<HomeAreaOverride>())
            .filter { $0.kind == .include }
            .map { CoverageDisc(latitude: $0.centerLatitude,
                                longitude: $0.centerLongitude,
                                radiusKm: $0.radiusKm) }
        out.append(contentsOf: includes)
        return out.sorted {
            ($0.latitude, $0.longitude, $0.radiusKm)
                < ($1.latitude, $1.longitude, $1.radiusKm)
        }
    }

    /// Phase 2.4 (see the call-site comment): append home-free unassigned
    /// stays arriving after a `userEdited` OPEN trip's last stay to that
    /// trip, or after one a live temporary home keeps (`keptTripIDs`, whose
    /// edit mark may not have synced yet). Strict no-op when no such
    /// incomplete trip exists. With
    /// several candidates (rare), the stay follows the trip whose last stay
    /// ends latest — the nearest journey; ties break on smaller trip id.
    /// Returns the number of stays adopted.
    internal func adoptStaysIntoUserEditedOpenTrips(
        unassignedStays: [Stay], boundaries: [HomeBoundarySpan], keptTripIDs: Set<UUID> = []
    ) throws -> Int {
        let editedOpenPredicate = #Predicate<Trip> { $0.isComplete == false }
        let editedOpenTrips = try fetchAssemblyDependency(
            FetchDescriptor<Trip>(predicate: editedOpenPredicate)
        ).filter { $0.userEdited || keptTripIDs.contains($0.id) }
        guard !editedOpenTrips.isEmpty else { return 0 }

        // Track each trip's chronologically-last stay and next order slot
        // EXPLICITLY — the inverse relationship may not be realized
        // pre-save (same rationale as Phase 3a's boundary test).
        var tripsByID: [UUID: Trip] = [:]
        var lastStayByTrip: [UUID: Stay] = [:]
        var nextOrderByTrip: [UUID: Int] = [:]
        for trip in editedOpenTrips {
            guard let last = trip.orderedStays.last else { continue }
            tripsByID[trip.id] = trip
            lastStayByTrip[trip.id] = last
            nextOrderByTrip[trip.id] = ((trip.stays ?? []).compactMap(\.orderInTrip).max() ?? -1) + 1
        }
        guard !lastStayByTrip.isEmpty else { return 0 }

        var adopted = 0
        var touchedTripIDs = Set<UUID>()
        // Inside a temporary-home unit a split trip's stays go to new pieces.
        let retired = deferredAssemblyIdentities?.retiredStayIDs ?? []
        for stay in unassignedStays where !retired.contains(stay.id) { // chronological — pool sort order
            var bestID: UUID?
            for (tripID, last) in lastStayByTrip {
                guard last.endTime <= stay.startTime else { continue }
                guard !hasHomeStayBetween(afterStay: last, beforeStay: stay, boundaries: boundaries) else { continue }
                if let incumbentID = bestID, let incumbentLast = lastStayByTrip[incumbentID] {
                    if last.endTime > incumbentLast.endTime
                        || (last.endTime == incumbentLast.endTime
                            && tripID.uuidString < incumbentID.uuidString) {
                        bestID = tripID
                    }
                } else {
                    bestID = tripID
                }
            }
            guard let bestID, let trip = tripsByID[bestID] else { continue }
            let order = nextOrderByTrip[bestID] ?? 0
            stay.trip = trip
            stay.orderInTrip = order
            nextOrderByTrip[bestID] = order + 1
            lastStayByTrip[bestID] = stay
            adopted += 1
            touchedTripIDs.insert(bestID)
        }
        for id in touchedTripIDs {
            guard let trip = tripsByID[id] else { continue }
            recomputeBackHalfSummary(trip)
            // Adoption bypasses Phase 1, so invalidate generated titles after membership changes; customName remains the user's display priority.
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
        }
        if adopted > 0 {
            logger.info("Adopted \(adopted) new stay(s) into \(touchedTripIDs.count) user-edited ongoing trip(s).")
        }
        return adopted
    }

    /// Require measured live-SLC home dwell before splitting or closing trips to reject isolated false home fixes;
    /// the 15-minute minimum matches the airport set-foot rule.
    nonisolated static let homeBoundaryMinimumDwellSeconds: TimeInterval = 15 * 60

    /// Imported home stays always qualify: even one home photo can separate historical trips.
    /// Live-SLC dwell must be measured: StayClusterer can synthesize midpoint endTime from a later out-of-cluster fix.
    /// Only pingCount == 1 disqualifies; zero means unknown for legacy rows and fixtures.
    /// A linked Core Location visit supplies measured dwell even for a single ping; open visits intentionally
    /// include arrival-to-receipt dwell and any corroborated extrapolated tail in the stay interval.
    nonisolated static func isQualifyingHomeBoundary(
        category: StayCategory,
        source: DataSource,
        startTime: Date,
        endTime: Date,
        pingCount: Int,
        hasVisit: Bool
    ) -> Bool {
        guard category == .home else { return false }
        guard source == .liveSLC else { return true }
        guard pingCount != 1 || hasVisit else { return false }
        return endTime.timeIntervalSince(startTime) >= homeBoundaryMinimumDwellSeconds
    }

    func isQualifyingHomeBoundary(_ stay: Stay) -> Bool {
        Self.isQualifyingHomeBoundary(
            category: stay.category,
            source: stay.source,
            startTime: stay.startTime,
            endTime: stay.endTime,
            pingCount: stay.pingCount,
            hasVisit: visitBackedStayIDs.contains(stay.id)
        )
    }
}
