//
//  TripClassifier+TripAssembly.swift
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

    // MARK: - Stage 3: Trip Assembly

    /// Snapshot for Phase 3c to restore Trip.id, which keys favorites, photo annotations, and Spotlight.
    private struct DetachedCompletedTrip {
        let id: UUID
        let stayIDs: Set<UUID>
        let startDate: Date
        let classifiedByAI: Bool
    }

    /// Exact-membership rebuilds are structural churn, not a semantic title
    /// change. Preserve the canonical title and one deterministic current-
    /// source row per language so offline language switches do not regress to
    /// English merely because a Trip row was re-minted.
    private struct CarriedTripTitle {
        struct Variant {
            let id: UUID
            let languageTag: String
            let title: String
            let sourceTitle: String
            let sourceRevision: UUID?
            let generationVersion: Int
            let updatedAt: Date
        }

        let sourceTripID: UUID
        let canonicalTitle: String
        let sourceRevision: UUID?
        let variants: [Variant]
        let semanticSnapshot: TripTitleStore.SemanticSnapshot
    }

    private func carriedTripTitle(for trip: Trip) -> CarriedTripTitle? {
        guard let canonicalTitle = TripTitleStore.normalized(
            trip.aiGeneratedTitle) else { return nil }

        var winners: [String: TripTitleVariant] = [:]
        for variant in trip.localizedTitles ?? [] {
            guard let tag = AppLanguagePreference.normalizedSupportedTag(
                variant.languageTag),
                  tag != "en",
                  TripTitleStore.normalized(variant.sourceTitle) == canonicalTitle,
                  variant.sourceRevision == trip.titleSourceRevision,
                  TripTitleStore.isUsableVariantTitle(
                      variant.title, languageTag: tag),
                  variant.generationVersion >= TripTitleStore.currentGenerationVersion
            else { continue }
            if let incumbent = winners[tag] {
                if TripTitleStore.hasPreferredContent(variant, over: incumbent) {
                    winners[tag] = variant
                }
            } else {
                winners[tag] = variant
            }
        }

        let variants = winners.map { tag, row in
            CarriedTripTitle.Variant(
                id: row.id,
                languageTag: tag,
                title: TripTitleStore.normalized(row.title) ?? row.title,
                sourceTitle: canonicalTitle,
                sourceRevision: row.sourceRevision,
                generationVersion: row.generationVersion,
                updatedAt: row.updatedAt)
        }.sorted { $0.languageTag < $1.languageTag }
        return CarriedTripTitle(
            sourceTripID: trip.id,
            canonicalTitle: canonicalTitle,
            sourceRevision: trip.titleSourceRevision,
            variants: variants,
            semanticSnapshot: TripTitleStore.semanticSnapshot(for: trip))
    }

    /// Reassemble incomplete trips while preserving user-overridden categories and user-edited trips.
    /// A trip a live temporary home keeps (`keptTripIDs`) is preserved as an edited one, before its
    /// own edit mark syncs. Trip boundaries are deterministic home-stay gaps; ignore the AI continuesPreviousTrip flag.
    /// Returns -1 after rolling back a dependency read failure; zero remains successful absence.
    internal func assembleTrips() -> Int {
        #if DEBUG
        assemblyFetchCallForTesting = 0
        #endif
        do {
            return try assembleTripsReadingDependencies()
        } catch {
            // Preparation and Stage 2 batches are already committed. This also
            // undoes this gate's sanity corrections and explicit rebuild detachments.
            modelContext.rollback()
            hasRunBackHalfSinceLaunch = false
            logger.error("Trip assembly rolled back: \(error.localizedDescription)")
            return -1
        }
    }

    func fetchAssemblyDependency<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        #if DEBUG
        assemblyFetchCallForTesting += 1
        if failAssemblyStayFetchForTesting,
           assemblyFetchCallForTesting == assemblyFetchFailureCallForTesting {
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try modelContext.fetch(descriptor)
    }

    private func assembleTripsReadingDependencies() throws -> Int {
        // Carry titles only for identical membership and semantic inputs.
        var aiTitleCarryForward: [Set<UUID>: CarriedTripTitle] = [:]
        // Preserve one incomplete PersistentModel so open detail views retain a live row.
        // Choose latest startDate, then smallest ID; Phase 3 binds it by prior-stay overlap.
        var reusableOngoingTrip: Trip?
        // Snapshot prior membership before detaching so Phase 3b can choose the best-overlap reuse target.
        var reusablePriorStayIDs = Set<UUID>()
        var reusablePriorWasProvisional = false
        // A trip a live temporary home keeps is never taken apart: the keep
        // syncs with the declaration and the trip's edit mark with the trip,
        // each on its own.
        let keptTripIDs = try fetchRequiredKeptTripIDs()
        let incompletePredicate = #Predicate<Trip> { $0.isComplete == false && $0.userEdited == false }
        let incompleteTrips = try fetchAssemblyDependency(FetchDescriptor<Trip>(predicate: incompletePredicate))
            .filter { !keptTripIDs.contains($0.id) }
        do {
            reusableOngoingTrip = incompleteTrips.min { a, b in
                if a.startDate != b.startDate { return a.startDate > b.startDate }
                return a.id.uuidString < b.id.uuidString
            }
            let priorStays = reusableOngoingTrip?.stays ?? []
            reusablePriorStayIDs = Set(priorStays.map(\.id))
            reusablePriorWasProvisional = !priorStays.isEmpty
                && !priorStays.contains { $0.category == .destination }
            for trip in incompleteTrips {
                let stayIDs = Set((trip.stays ?? []).map(\.id))
                if !stayIDs.isEmpty {
                    deferredAssemblyIdentities?.constituents.append(
                        (id: trip.id, stayIDs: stayIDs, startDate: trip.startDate))
                }
                if !stayIDs.isEmpty, let title = carriedTripTitle(for: trip) {
                    aiTitleCarryForward[stayIDs] = title
                }
                for stay in (trip.stays ?? []) {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                if trip !== reusableOngoingTrip {
                    modelContext.delete(trip)
                    lastPipelineMadeChanges = true
                }
            }
        }

        // Phase 2: Find all destination/transit stays not in any trip.
        let predicate = #Predicate<Stay> {
            $0.categoryRaw == "destination" || $0.categoryRaw == "transit"
        }
        let descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stay.startTime, order: .forward)]
        )

        let allTripStays = try fetchAssemblyDependency(descriptor)
        guard !allTripStays.isEmpty else {
            // Delete the detached reusable row when no trip-class stays remain, avoiding an empty trip.
            if let reusableOngoingTrip {
                modelContext.delete(reusableOngoingTrip)
                lastPipelineMadeChanges = true
            }
            return 0
        }

        let unassignedStays = allTripStays.filter { $0.trip == nil }
        guard !unassignedStays.isEmpty else {
            if let reusableOngoingTrip {
                modelContext.delete(reusableOngoingTrip)
                lastPipelineMadeChanges = true
            }
            return 0
        }

        // Also fetch all stays for home-gap detection
        let allDescriptor = FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\Stay.startTime, order: .forward)]
        )
        let allStays = try fetchAssemblyDependency(allDescriptor)
        // Precompute boundaries once to avoid repeated full-stay scans during completed-trip reconciliation.
        let homeBoundarySpans = qualifyingHomeBoundarySpans(allStays)

        // Preserve curated open trips and append later home-free stays as the same journey.
        // Late imports inside or before the edited span deliberately regroup separately.
        let adoptedCount = try adoptStaysIntoUserEditedOpenTrips(
            unassignedStays: unassignedStays, boundaries: homeBoundarySpans, keptTripIDs: keptTripIDs
        )
        let poolAfterAdoption = adoptedCount == 0
            ? unassignedStays
            : allTripStays.filter { $0.trip == nil }
        guard !poolAfterAdoption.isEmpty else {
            // Delete the empty reusable row after all stays are adopted.
            if let reusableOngoingTrip {
                modelContext.delete(reusableOngoingTrip)
                lastPipelineMadeChanges = true
            }
            logger.info("Adoption absorbed every unassigned stay — no regrouping needed.")
            return adoptedCount
        }

        // Regroup completed trips when late stays overlap or join their home-free segment.
        // Normal later live stays are separated by the closing home boundary. CloudKit record order is
        // unguaranteed, so a synced stay may temporarily arrive without its trip relationship;
        // the same grouping fold and Phase 3c identity restoration must converge across devices.
        // User-edited and kept trips remain exempt, even when an import fragments their span.
        var detachedCompletedSnapshots: [DetachedCompletedTrip] = []
        let completedPredicate = #Predicate<Trip> { $0.isComplete == true && $0.userEdited == false }
        let completedTrips = try fetchAssemblyDependency(FetchDescriptor<Trip>(predicate: completedPredicate))
            .filter { !keptTripIDs.contains($0.id) }
        do {
            for trip in completedTrips {
                guard let endDate = trip.endDate else { continue }
                let ordered = trip.orderedStays
                guard let firstStay = ordered.first, let lastStay = ordered.last else { continue }
                // O(completed × unassigned) date comparisons, in-memory and
                // import-bounded — the pool is empty or tiny on live passes.
                let affected = poolAfterAdoption.contains { s in
                    // (1) The stay interleaves the trip's span.
                    if s.startTime < endDate && s.endTime > trip.startDate { return true }
                    // (2) After the trip but before its return-home stay.
                    if s.startTime >= lastStay.endTime {
                        return !hasHomeStayBetween(afterStay: lastStay, beforeStay: s, boundaries: homeBoundarySpans)
                    }
                    // (3) Before the trip with no home between.
                    if s.endTime <= firstStay.startTime {
                        return !hasHomeStayBetween(afterStay: s, beforeStay: firstStay, boundaries: homeBoundarySpans)
                    }
                    return false
                }
                guard affected else { continue }
                let stayIDs = Set(ordered.map(\.id))
                detachedCompletedSnapshots.append(DetachedCompletedTrip(
                    id: trip.id,
                    stayIDs: stayIDs,
                    startDate: trip.startDate,
                    classifiedByAI: trip.classifiedByAI
                ))
                // Use the same exact-membership title carry rule as Phase 1.
                if !stayIDs.isEmpty, let title = carriedTripTitle(for: trip) {
                    aiTitleCarryForward[stayIDs] = title
                }
                for stay in (trip.stays ?? []) {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(trip)
                lastPipelineMadeChanges = true
            }
        }
        if !detachedCompletedSnapshots.isEmpty {
            logger.info("Import reconciliation: detached \(detachedCompletedSnapshots.count) completed trip(s) overlapping newly classified stays.")
        }

        // The grouping pool: originally-unassigned stays plus anything Phase
        // 2.5 just detached. Re-filtering `allTripStays` preserves the
        // chronological sort the fold depends on.
        let groupingPool = detachedCompletedSnapshots.isEmpty
            ? poolAfterAdoption
            : allTripStays.filter { $0.trip == nil }

        // Group only on home-stay gaps before any model writes, so reuse can be selected from the complete groups.
        var groups: [[Stay]] = []
        for stay in groupingPool {
            // Track the last appended stay explicitly: SwiftData assignment realizes inverses immediately,
            // but pending deletes do not nullify them until save.
            if let prev = groups.last?.last,
               !hasHomeStayBetween(afterStay: prev, beforeStay: stay, boundaries: homeBoundarySpans) {
                groups[groups.count - 1].append(stay)
            } else {
                groups.append([stay])
            }
        }

        // gateMemberships scopes shapes to home eras so later visits to a former home can be trips,
        // and dates a temporary home's membership, so the base after the end is an ordinary place.
        let shapedHomeRings = withShapes(try fetchRequiredAnchors().map { Self.HomeRing($0) },
            overrides: try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()))

        // Home-bounded all-transit groups remain tripless errand residue, which the dirty gate accepts;
        // stay semantics still feed map, flight, and statistics consumers.
        let lastGroupIndex = groups.indices.last
        var fastPathResult: (index: Int, reason: String, admitted: Bool)?
        let materializedGroups: [[Stay]] = groups.enumerated().compactMap { index, group in
            if group.contains(where: { $0.category == .destination }) { return group }
            // Foreground fast path: an all-transit
            // OPEN TAIL may materialize provisionally. Every
            // other all-transit group is errand residue (comment above) and stays
            // tripless.
            guard index == lastGroupIndex,
                  let tailStay = group.last else { return nil }
            let verdict = provisionalTailVerdict(
                group,
                tailStay: tailStay,
                homeBoundarySpans: homeBoundarySpans,
                shapedHomeRings: shapedHomeRings,
                reusablePriorStayIDs: reusablePriorStayIDs)
            fastPathResult = (index, verdict.reason, verdict.admitted)
            return verdict.admitted ? group : nil
        }
        let fastPathVerdict: (group: [Stay], reason: String, admitted: Bool)? =
            fastPathResult.map { (groups[$0.index], $0.reason, $0.admitted) }
        if materializedGroups.count != groups.count {
            logger.info("Skipped \(groups.count - materializedGroups.count) all-transit group(s) — errand residue, not journeys.")
        }

        // Confidence separates trips from errands outside measured home coverage.
        // Memoize suppressed destination fingerprints so assemblyInvariantViolated accepts
        // their tripless steady state instead of rebuilding on every pass.
        var suppressedFingerprints: [UUID: SuppressedStayFingerprint] = [:]
        #if DEBUG
        var gateAuditRecords: [DebugGateAudit.GroupRecord] = []
        if let verdict = fastPathVerdict, !verdict.admitted {
            gateAuditRecords.append(debugGateRecord(
                verdict.group,
                homeRings: shapedHomeRings,
                cleared: false,
                fastPath: verdict.reason))
        }
        #endif
        let confidentGroups = materializedGroups.filter { group in
            let cleared = groupClearsConfidence(group, homeRings: shapedHomeRings)
            #if DEBUG
            gateAuditRecords.append(debugGateRecord(
                group,
                homeRings: shapedHomeRings,
                cleared: cleared,
                fastPath: fastPathVerdict?.group.first?.id == group.first?.id
                    ? fastPathVerdict?.reason : nil))
            #endif
            if cleared { return true }
            let clearsAt = suppressedGroupAccretionClearsAt(group, homeRings: shapedHomeRings)
            for stay in group where stay.category == .destination {
                suppressedFingerprints[stay.id] = SuppressedStayFingerprint(
                    startTime: stay.startTime,
                    endTime: stay.endTime,
                    distanceFromHomeKm: stay.distanceFromHomeKm,
                    centroidLatitude: stay.centroidLatitude,
                    centroidLongitude: stay.centroidLongitude,
                    isAirport: stay.isAirport,
                    accretionClearsAt: clearsAt)
            }
            return false
        }
        gateSuppressedStayFingerprints = suppressedFingerprints
        // Digest the inputs as the store will hold them once this pass's admitted
        // groups hold their trips, which is what the next check reads.
        let temporaryRings = shapedHomeRings.filter(\.isTemporary)
        if suppressedFingerprints.isEmpty || temporaryRings.isEmpty {
            gateSuppressionInputDigest = nil
        } else {
            let admitted = Set(confidentGroups.joined().map { ObjectIdentifier($0) })
            gateSuppressionInputDigest = Self.suppressionInputDigest(
                rings: shapedHomeRings,
                stays: allStays.filter {
                    $0.trip == nil && ($0.category == .destination || $0.category == .transit)
                        && !admitted.contains(ObjectIdentifier($0))
                })
        }
        #if DEBUG
        // DEBUG diagnostics explain candidate-group verdicts; empty passes have nothing to record.
        if !gateAuditRecords.isEmpty {
            DebugGateAudit.record(DebugGateAudit.Pass(
                at: .now, threshold: TripConfidence.threshold,
                groups: gateAuditRecords))
        }
        #endif
        logger.info("Confidence gate: \(confidentGroups.count, privacy: .public) of \(materializedGroups.count, privacy: .public) candidate group(s) cleared threshold \(TripConfidence.threshold, privacy: .public).")

        // Reuse the row for the group with most prior-stay overlap so identity follows the same journey.
        // Ties prefer the later fragment; zero overlap falls back to the last group unless the prior row was provisional.
        // Reset derived fields, then restore titles only when membership and semantic inputs still match.
        var newTripsCreated = 0
        var createdTrips: [(trip: Trip, stayIDs: Set<UUID>)] = []
        var reusedOngoingRow = false

        let overlaps = confidentGroups.map { group in
            group.count { reusablePriorStayIDs.contains($0.id) }
        }
        let maxOverlap = overlaps.max() ?? 0
        // A vanished provisional group must not donate its UUID to an unrelated
        // journey merely because every surviving group has zero stay overlap.
        let reuseIndex: Int? = maxOverlap == 0
            ? (reusablePriorWasProvisional ? nil : confidentGroups.count - 1)
            : overlaps.lastIndex(of: maxOverlap)

        let homeStaysForAnchors = allStays.filter { $0.category == .home }
        for (index, group) in confidentGroups.enumerated() {
            let trip: Trip
            if index == reuseIndex, let reusable = reusableOngoingTrip {
                trip = reusable
                trip.startDate = group[0].startTime
                trip.endDate = nil
                trip.isComplete = false
                // Invalidate after the exact-membership carry-forward
                // decision below so unchanged membership keeps its localized
                // derivatives as well as its canonical title.
                reusedOngoingRow = true
            } else {
                trip = Trip(startDate: group[0].startTime)
                modelContext.insert(trip)
            }
            // Any freshly FM-classified member grants AI provenance; heuristic fallback for other members cannot demote it.
            // A trip with no members classified this pass retains its existing flag.
            let touchedByFM = group.contains { fmClassifiedStayIDs.contains($0.id) }
            let touchedByHeuristics = group.contains { heuristicClassifiedStayIDs.contains($0.id) }
            if touchedByFM || touchedByHeuristics {
                trip.classifiedByAI = touchedByFM
            }

            var stayIDs = Set<UUID>()
            for (order, stay) in group.enumerated() {
                stay.trip = trip
                stay.orderInTrip = order
                stayIDs.insert(stay.id)
                // Preserve userEdited flag for trips containing
                // user-overridden stays. The edit is the user's own.
                if stay.userOverridden {
                    trip.userEdited = true
                    trip.keptByTemporaryHome = false
                }
            }
            stampDistancesFromDepartureHome(
                group, homeStays: homeStaysForAnchors, homeRings: shapedHomeRings)
            closeTrip(trip, boundaries: homeBoundarySpans)
            createdTrips.append((trip: trip, stayIDs: stayIDs))
            newTripsCreated += 1
        }

        if !reusedOngoingRow, let reusableOngoingTrip {
            // A deletion-only pass must still reload widgets and persist.
            modelContext.delete(reusableOngoingTrip)
            lastPipelineMadeChanges = true
        }

        // Restore titles after closeTrip only for identical membership and semantic inputs,
        // so unchanged trips retain localized derivatives.
        if !aiTitleCarryForward.isEmpty {
            for entry in createdTrips {
                if let kept = aiTitleCarryForward[entry.stayIDs],
                   TripTitleStore.hasSameSemanticInputs(
                    kept.semanticSnapshot,
                    TripTitleStore.semanticSnapshot(for: entry.trip)) {
                    entry.trip.aiGeneratedTitle = kept.canonicalTitle
                    entry.trip.titleSourceRevision = kept.sourceRevision
                    if kept.sourceTripID != entry.trip.id {
                        for value in kept.variants {
                            modelContext.insert(TripTitleVariant(
                                id: value.id,
                                languageTag: value.languageTag,
                                title: value.title,
                                sourceTitle: value.sourceTitle,
                                sourceRevision: value.sourceRevision,
                                generationVersion: value.generationVersion,
                                updatedAt: value.updatedAt,
                                trip: entry.trip))
                        }
                    }
                } else if entry.trip === reusableOngoingTrip {
                    TripTitleStore.invalidateGeneratedTitles(
                        for: entry.trip, in: modelContext)
                }
            }
        } else if let reusableOngoingTrip, reusedOngoingRow {
            TripTitleStore.invalidateGeneratedTitles(
                for: reusableOngoingTrip, in: modelContext)
        }

        // A temporary-home unit arbitrates every identity itself.
        if deferredAssemblyIdentities != nil {
            deferredAssemblyIdentities?.constituents += detachedCompletedSnapshots.map {
                (id: $0.id, stayIDs: $0.stayIDs, startDate: $0.startDate)
            }
            deferredAssemblyIdentities?.outputs = createdTrips.map(\.trip)
        }

        // Restore detached identities by maximum prior-stay overlap, mirroring identityClaims.
        // Claim in descending stay count, then startDate and ID order; each rebuilt trip is claimed once.
        // Candidate ties prefer later startDate, then smaller ID; a merged-away constituent retires its ID.
        if !detachedCompletedSnapshots.isEmpty {
            var restored = 0
            if deferredAssemblyIdentities == nil {
                let arbitration = TripIdentityArbitration(createdTrips.map {
                    (id: $0.trip.id, stayIDs: $0.stayIDs, startDate: $0.trip.startDate)
                })
                let snapshots = detachedCompletedSnapshots.map {
                    (id: $0.id, stayIDs: $0.stayIDs, startDate: $0.startDate)
                }
                let ongoingIndex = reusedOngoingRow ? reuseIndex : nil
                let ongoingOverlap = ongoingIndex.map {
                    createdTrips[$0].stayIDs.intersection(reusablePriorStayIDs).count
                } ?? 0
                let claims = arbitration.claims(snapshots: snapshots, claimKey: { $0 }) {
                    // Preserve the open-detail row; a completed constituent takes
                    // its UUID only when its overlap strictly exceeds the ongoing one.
                    $0 != ongoingIndex || $1 > ongoingOverlap
                }
                for (index, id) in claims {
                    createdTrips[index].trip.id = id
                }
                restored = claims.count
            }
            // FM credit reaches every overlapping output even when identities are deferred.
            for snapshot in detachedCompletedSnapshots where snapshot.classifiedByAI {
                for entry in createdTrips
                where !entry.stayIDs.isDisjoint(with: snapshot.stayIDs) {
                    entry.trip.classifiedByAI = true
                }
            }
            logger.info("Import reconciliation: restored stable Trip.id on \(restored) of \(detachedCompletedSnapshots.count) regrouped trip(s).")
        }

        logger.info("Assembled \(newTripsCreated) new trip(s).")
        // Adopted stays are a store mutation too — callers key "did the
        // pipeline change anything" off this return, and a pure-adoption
        // pass must still propagate (save, widgets, summaries).
        return newTripsCreated + adoptedCount
    }

    // MARK: - Departure-home distance anchor

    /// Anchor all member distances to the departure home so later moves or nearer simultaneous homes cannot shrink a trip.
    /// Without a claimed preceding home stay, use closestHomeDistanceKm at the trip start for one shared anchor era.
    /// Write only changed values because same-value setters dirty CloudKit rows; completed stays retain their stamps.
    func stampDistancesFromDepartureHome(
        _ group: [Stay], homeStays: [Stay], homeRings: [HomeRing]
    ) {
        guard let first = group.first else { return }
        let anchor = Self.departureHomeAnchor(
            tripStart: first.startTime, homeStays: homeStays, homeRings: homeRings)
        let windows = homeRings.map {
            StayClusterer.HomeWindow(
                latitude: $0.latitude, longitude: $0.longitude,
                startedAt: $0.startedAt, endedAt: $0.endedAt,
                isTemporary: $0.isTemporary)
        }
        for stay in group {
            let km: Double
            if let anchor {
                km = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    .distance(from: CLLocation(
                        latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)) / 1000.0
            } else {
                km = StayClusterer.closestHomeDistanceKm(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    atTime: first.startTime, homes: windows)
            }
            if km.isFinite, abs(km - stay.distanceFromHomeKm) > 0.001 {
                stay.distanceFromHomeKm = km
            }
        }
    }

    /// The centre of the ring that contained the last `.home` stay before
    /// `tripStart`, evaluated at that stay's own time with the same geometry
    /// as `matchesHome` (measured membership when attached, the declared
    /// circle otherwise). Nearest centre wins when several rings overlap.
    /// Nil when there is no such stay or no ring claims it. Pure; test seam.
    nonisolated static func departureHomeAnchor(
        tripStart: Date, homeStays: [Stay], homeRings: [HomeRing]
    ) -> (latitude: Double, longitude: Double)? {
        guard let departure = homeStays
            .filter({ $0.startTime < tripStart })
            .max(by: { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) })
        else { return nil }
        let location = CLLocation(
            latitude: departure.centroidLatitude, longitude: departure.centroidLongitude)
        var best: (ring: HomeRing, km: Double)?
        for ring in homeRings {
            if let endedAt = ring.endedAt, departure.startTime > endedAt { continue }
            if ring.startedAt > departure.startTime { continue }
            let km = CLLocation(latitude: ring.latitude, longitude: ring.longitude)
                .distance(from: location) / 1000.0
            let contains: Bool
            if let membership = ring.membership {
                contains = membership.contains(
                    latitude: departure.centroidLatitude,
                    longitude: departure.centroidLongitude,
                    at: departure.startTime)
            } else {
                contains = km <= ring.radiusKm
            }
            guard contains else { continue }
            if best == nil || km < best!.km { best = (ring, km) }
        }
        // A departure before every real home's start that no temporary home
        // claims left the real home (`matchesHome` pass 2 stamped it). While a
        // temporary home's dates cover it or the trip's start, the distance
        // fallback would otherwise measure each stay from whichever is nearer.
        func temporaryRingCovers(_ date: Date) -> Bool {
            homeRings.contains { ring in
                ring.isTemporary && ring.startedAt <= date
                    && (ring.endedAt.map { date <= $0 } ?? true)
            }
        }
        if best == nil,
           homeRings.contains(where: { $0.claimsPrehistory && $0.endedAt == nil }),
           homeRings.allSatisfy({ !$0.claimsPrehistory || departure.startTime < $0.startedAt }),
           temporaryRingCovers(departure.startTime) || temporaryRingCovers(tripStart) {
            for ring in homeRings where ring.claimsPrehistory {
                let km = CLLocation(latitude: ring.latitude, longitude: ring.longitude)
                    .distance(from: location) / 1000.0
                let contains = ring.membership.map {
                    $0.contains(latitude: departure.centroidLatitude,
                                longitude: departure.centroidLongitude,
                                at: departure.startTime, includeTaught: false)
                } ?? (km <= ring.radiusKm)
                guard contains else { continue }
                if best == nil || km < best!.km { best = (ring, km) }
            }
        }
        return best.map { ($0.ring.latitude, $0.ring.longitude) }
    }

    /// The confidence gate admits groups with no shaped home or with user-overridden stays,
    /// and groups with a run no home existed throughout (see `groupScoreClears`).
    private func groupClearsConfidence(_ group: [Stay], homeRings: [HomeRing]) -> Bool {
        if group.contains(where: { $0.userOverridden }) { return true }
        let memberships = Self.gateMemberships(
            stayStarts: group.map(\.startTime), rings: homeRings)
        guard !memberships.isEmpty else { return true }
        return groupScoreClears(group, memberships: memberships)
    }

    /// The earliest `endTime` at which a group the gate just suppressed
    /// could clear θ through dwell alone (see `SuppressedStayFingerprint`).
    /// Nil when no dwell can lift any of its excursions. Called only for
    /// suppressed groups, so memberships are never empty here — an empty
    /// set makes `groupClearsConfidence` admit the group instead.
    private func suppressedGroupAccretionClearsAt(
        _ group: [Stay], homeRings: [HomeRing]
    ) -> Date? {
        let memberships = Self.gateMemberships(
            stayStarts: group.map(\.startTime), rings: homeRings)
        guard !memberships.isEmpty else { return nil }
        return TripConfidence.excursions(
            from: group.map(Self.confidenceInput), memberships: memberships)
            .compactMap(\.accretionClearsAt)
            .min()
    }

    private static func confidenceInput(_ stay: Stay) -> TripConfidence.StayInput {
        TripConfidence.StayInput(
            id: stay.id, start: stay.startTime, end: stay.endTime,
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
            isTransitNode: stay.isAirport)
    }

    /// A group clears when one of its runs scores as a trip, or when no home existed
    /// throughout one of its runs: nothing can call that run an errand, the gate's own
    /// rule when no membership exists at all. `admitsUnscored: false` asks for a
    /// scored trip run only. Without a temporary home every run is scored.
    private func groupScoreClears(
        _ group: [Stay],
        memberships: [HomeMembership],
        admitsUnscored: Bool = true
    ) -> Bool {
        return TripConfidence.excursions(
            from: group.map(Self.confidenceInput), memberships: memberships)
            .contains { $0.isTrip || (admitsUnscored && !$0.hasScoringMembership) }
    }

    /// Foreground admission for the last all-transit group; returns a reason for DEBUG diagnostics.
    private func provisionalTailVerdict(
        _ group: [Stay],
        tailStay: Stay,
        homeBoundarySpans: [HomeBoundarySpan],
        shapedHomeRings: [HomeRing],
        reusablePriorStayIDs: Set<UUID>
    ) -> (admitted: Bool, reason: String) {
        // Open tail: `groups.last` alone is not enough — a qualifying terminal
        // home stay is not in `groups`.
        if homeBoundarySpans.contains(where: { $0.start >= tailStay.endTime }) {
            return (false, "closed tail")
        }
        if group.contains(where: { $0.userOverridden }) {
            return (false, "user-overridden")
        }
        let memberships = Self.gateMemberships(
            stayStarts: group.map(\.startTime), rings: shapedHomeRings)
        if memberships.isEmpty { return (false, "no membership") }
        // Retention: silence must never remove an admitted row.
        if group.contains(where: { reusablePriorStayIDs.contains($0.id) }) {
            return (true, "retained")
        }
        // Opening requires a corroborated, fresh, accurate live witness.
        guard tailStay.pingCount >= 2 else { return (false, "single ping") }
        guard let ping = newestWitnessPing(for: tailStay) else {
            return (false, "no witness ping")
        }
        guard ping.source.isLiveObservation else {
            return (false, "witness not live")
        }
        guard abs(ping.timestamp.timeIntervalSinceNow) <= Self.fastPathFreshnessSeconds else {
            return (false, "witness stale")
        }
        guard ping.horizontalAccuracy >= 0,
              ping.horizontalAccuracy <= Self.fastPathMaxAccuracyMeters else {
            return (false, "witness inaccurate")
        }
        // Use the same group score as groupClearsConfidence so the later filter cannot disagree.
        // Opening needs a scored trip run: a run no home's dates span is no evidence of travel.
        let clears = groupScoreClears(group, memberships: memberships, admitsUnscored: false)
        return (clears, clears ? "opened" : "below threshold")
    }

    nonisolated static let fastPathFreshnessSeconds: TimeInterval = 15 * 60
    nonisolated static let fastPathMaxAccuracyMeters: Double = 1_000

    #if DEBUG
    /// DEBUG diagnostics use the same gateMemberships and TripConfidence.excursions inputs as groupClearsConfidence; explain the supplied verdict without re-deciding.
    private func debugGateRecord(
        _ group: [Stay],
        homeRings: [HomeRing],
        cleared: Bool,
        fastPath: String? = nil
    ) -> DebugGateAudit.GroupRecord {
        var places: [String: Int] = [:]
        for stay in group {
            if let name = stay.locality ?? stay.islandName {
                places[name, default: 0] += 1
            }
        }
        let placeName = places.max(by: {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        })?.key

        var exemption: String?
        var score: Double?
        if group.contains(where: { $0.userOverridden }) {
            exemption = "a member stay is user-overridden"
        } else {
            let memberships = Self.gateMemberships(
                stayStarts: group.map(\.startTime), rings: homeRings)
            if memberships.isEmpty {
                exemption = "no shaped home covers this era"
            } else {
                let inputs = group.map {
                    TripConfidence.StayInput(
                        id: $0.id, start: $0.startTime, end: $0.endTime,
                        latitude: $0.centroidLatitude,
                        longitude: $0.centroidLongitude,
                        isTransitNode: $0.isAirport)
                }
                let excursions = TripConfidence.excursions(from: inputs, memberships: memberships)
                // An unscored run's zero is a placeholder, not a suppression score.
                if excursions.contains(where: { !$0.hasScoringMembership }) {
                    exemption = "no home's dates span a run"
                }
                score = excursions.filter(\.hasScoringMembership).map(\.score).max()
            }
        }
        return DebugGateAudit.GroupRecord(
            id: UUID(),
            start: group[0].startTime,
            end: group.map(\.endTime).max() ?? group[0].startTime,
            stayCount: group.count,
            placeName: placeName,
            score: score,
            exemption: exemption,
            cleared: cleared,
            fastPath: fastPath)
    }
    #endif
}
