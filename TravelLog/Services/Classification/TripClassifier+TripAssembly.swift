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
        /// The name goes with the id to the trip that keeps it.
        let customName: String?
    }

    /// The trips a regroup takes apart, with the photos hidden on them read
    /// before they are detached, so those choices can follow their stays.
    struct RegroupedTrips {
        var members: [(id: UUID, stays: [Stay])] = []
        var hidden: [UUID: [PhotoLineageStore.HiddenChoice]] = [:]
        /// The rows holding `hidden`, for a split that keeps the original id.
        var hiddenRowIDs: [UUID: Set<UUID>] = [:]

        /// Reads the hidden choices of `trips` and notes their stays; call
        /// before detaching them. Throws on a failed read.
        mutating func note(_ trips: [Trip], in context: ModelContext) throws {
            let held = trips.filter { !($0.stays ?? []).isEmpty }
            guard !held.isEmpty else { return }
            let read = try PhotoLineageStore.hiddenRows(of: Set(held.map(\.id)), in: context)
            hidden.merge(read.choices) { $0 + $1 }
            hiddenRowIDs.merge(read.rowIDs) { $0.union($1) }
            members += held.map { (id: $0.id, stays: $0.stays ?? []) }
        }

        /// Adds `stays` to the noted trip `id` (the first of its rows).
        mutating func adopt(_ stays: [Stay], into id: UUID) {
            guard !stays.isEmpty, let index = members.firstIndex(where: { $0.id == id }) else { return }
            members[index].stays += stays.filter { stay in !members[index].stays.contains { $0 === stay } }
        }

        /// The noted trips other than `ids`.
        func excluding(_ ids: Set<UUID>) -> RegroupedTrips {
            guard !ids.isEmpty else { return self }
            var kept = self
            kept.members = members.filter { !ids.contains($0.id) }
            return kept
        }
    }

    /// Hidden photo choices follow the stays of the trips a regroup took
    /// apart (`PhotoLineageStore`): every trip now holding one of a detached
    /// trip's stays inherits that trip's hidden photos in this unit, as rows
    /// it can unhide on its own, and each detached id that neither `outputs`
    /// nor such a trip kept is logged as retired onto them before the unit's
    /// save, for hidden rows that sync in later. A detached id one piece kept
    /// while other pieces took some of its stays is logged as a split
    /// (`PhotoLineageStore.SplitProvenance`), so a row hidden before the split
    /// that syncs in later reaches those pieces too, once. Call once
    /// identities are final. Pins and favourites stay with the id. Throws on
    /// a failed read.
    func inheritRegroupedHiddenChoices(_ regrouped: RegroupedTrips, outputs: [Trip]) throws {
        guard !regrouped.members.isEmpty else { return }
        let keptIDs = Set(outputs.filter { !$0.isDeleted }.map(\.id))
        var successorsByID: [UUID: Set<UUID>] = [:]
        for member in regrouped.members {
            var successors = successorsByID[member.id] ?? []
            for stay in member.stays where !stay.isDeleted {
                if let trip = stay.trip, !trip.isDeleted { successors.insert(trip.id) }
            }
            successorsByID[member.id] = successors
        }
        for (id, successors) in successorsByID.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let choices = regrouped.hidden[id] {
                for successor in successors.sorted(by: { $0.uuidString < $1.uuidString }) where successor != id {
                    try PhotoLineageStore.inheritHidden(choices, onto: successor, in: modelContext)
                }
            }
            if !keptIDs.contains(id), !successors.contains(id), !successors.isEmpty {
                pendingHiddenLineages.append(.init(retiredID: id, successorIDs: successors))
            } else if successors.contains(id), successors.count > 1 {
                pendingHiddenSplits.append(.init(
                    parentID: id, successorIDs: successors.subtracting([id]), splitAt: .now,
                    settledRowIDs: regrouped.hiddenRowIDs[id] ?? []))
            }
        }
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
    /// own edit mark syncs. Trip boundaries are deterministic: home-stay gaps, then the gap judge
    /// inside closed groups (`splitOnJudgedGaps`); ignore the AI continuesPreviousTrip flag.
    /// `pinnedTripIDs` are the favourites, which a late home boundary leaves whole.
    /// Returns -1 after rolling back a dependency read failure; zero remains successful absence.
    internal func assembleTrips(pinnedTripIDs: Set<UUID> = []) -> Int {
        #if DEBUG
        assemblyFetchCallForTesting = 0
        #endif
        pendingHiddenLineages = []
        pendingHiddenSplits = []
        pendingDetachedMembers = nil
        pendingHistoricalScan = .none
        do {
            return try assembleTripsReadingDependencies(pinnedTripIDs: pinnedTripIDs)
        } catch {
            // Preparation and Stage 2 batches are already committed. This also
            // undoes this gate's sanity corrections and explicit rebuild detachments.
            modelContext.rollback()
            pendingHiddenLineages = []
            pendingHiddenSplits = []
            pendingDetachedMembers = nil
            // The rollback undid this unit's spared-trip release too.
            pendingSparedTrips = nil
            pendingHistoricalScan = .none
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

    private func assembleTripsReadingDependencies(pinnedTripIDs: Set<UUID>) throws -> Int {
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
        // Read before detaching. Inside a temporary-home unit, which
        // arbitrates identities itself, they are inherited after its
        // arbitration (`finishRegroup`).
        var regrouped = RegroupedTrips()
        try regrouped.note(incompleteTrips, in: modelContext)
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

        // History before every read the completed-trip scan below stands on.
        let historyToken = newestStoreHistoryToken()
        let allTripStays = try fetchAssemblyDependency(descriptor)
        guard !allTripStays.isEmpty else {
            // Delete the detached reusable row when no trip-class stays remain, avoiding an empty trip.
            if let reusableOngoingTrip {
                modelContext.delete(reusableOngoingTrip)
                lastPipelineMadeChanges = true
            }
            // No trip holds a stay a home stay could split: an empty scan, so
            // the idle check still sees a trip that syncs in with its stays.
            let none = TripExtents([])
            pendingHistoricalScan = .scanned(HistoricalBoundaryScan(
                token: historyToken, boundaries: Self.retroactiveBoundaryDigest([], within: none),
                extents: none, homeStays: [], membership: [], curatedSpanning: []))
            return 0
        }

        let unassignedStays = allTripStays.filter { $0.trip == nil }

        // Home stays for home-gap detection: only they delimit trips and
        // anchor departures, and the suppression digest below reads the
        // trip-class rows already fetched. Read even with no unassigned stay:
        // a home stay alone can split a completed trip.
        let homeDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "home" },
            sortBy: [SortDescriptor(\Stay.startTime, order: .forward)]
        )
        let homeStays = try fetchAssemblyDependency(homeDescriptor)
        // Index boundaries once: every gap test and closure below is a binary search.
        let homeBoundaries = HomeBoundaryIndex(qualifyingHomeBoundarySpans(homeStays))
        // Only a boundary that clears the live bar splits a trip already assembled.
        let retroactive = retroactiveHomeBoundaries(homeStays, visitBacked: visitBackedStayIDs)

        // Preserve curated open trips and append later home-free stays as the same journey.
        // Late imports inside or before the edited span deliberately regroup separately.
        let adoptedCount = unassignedStays.isEmpty ? 0 : try adoptStaysIntoUserEditedOpenTrips(
            unassignedStays: unassignedStays, boundaries: homeBoundaries, keptTripIDs: keptTripIDs
        )
        let poolAfterAdoption = adoptedCount == 0
            ? unassignedStays
            : allTripStays.filter { $0.trip == nil }

        // Regroup completed trips when late stays overlap or join their home-free segment.
        // Normal later live stays are separated by the closing home boundary. CloudKit record order is
        // unguaranteed, so a synced stay may temporarily arrive without its trip relationship;
        // the same grouping fold and Phase 3c identity restoration must converge across devices.
        // A completed trip with a retroactive home boundary between two of its stays (a late
        // home-only import, a home stay that synced in or came to qualify) regroups too, with or
        // without new away stays. User-edited and kept trips remain exempt, even when an import
        // fragments their span, and a curated trip stays whole against a late boundary,
        // whether or not new away stays arrive with it.
        var detachedCompletedSnapshots: [DetachedCompletedTrip] = []
        // The spans of the completed trips regrouped here: between two stays
        // inside one, only a retroactive boundary separates (see the fold).
        var regroupedCompletedSpans: [HomeBoundarySpan] = []
        // The spans of the curated ones among them, their detached members
        // included: inside one nothing separates, so the journey stays whole
        // and evidence arriving inside it joins it.
        var curatedCompletedSpans: [HomeBoundarySpan] = []
        // Every completed row, edited ones included, so the memberships read
        // below and after regrouping fault no trip in one at a time.
        let completedTrips = try fetchAssemblyDependency(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.isComplete == true }))
            .filter { !$0.userEdited && !keptTripIDs.contains($0.id) }
        // The scan for retroactive boundaries walks every completed trip's members;
        // while nothing it stood on has moved since its last commit, it found nothing new.
        let acknowledged = acknowledgedHistoricalScan
        let membershipRead = completedMembership(allTripStays, keptTripIDs: keptTripIDs)
        let retroactiveScanDue = try historicalScanDue(
            acknowledged,
            boundaries: Self.retroactiveBoundaryDigest(retroactive.spans, within: membershipRead.extents),
            membership: membershipRead.membership,
            completedTrips: completedTrips, pinnedTripIDs: pinnedTripIDs)
        var curatedSpanning = retroactiveScanDue ? [] : acknowledged?.curatedSpanning ?? []
        #if DEBUG
        if retroactiveScanDue { historicalScanCountForTesting += 1 }
        #endif
        // What this assembly's scan stood on, with the memberships it leaves.
        func scanRead(membership read: CompletedMembership) -> HistoricalBoundaryScan {
            HistoricalBoundaryScan(
                token: historyToken,
                boundaries: Self.retroactiveBoundaryDigest(retroactive.spans, within: read.extents),
                extents: read.extents,
                homeStays: Set(homeStays.filter {
                    read.extents.overlaps(start: $0.startTime, end: $0.endTime)
                }.map(\.persistentModelID)),
                membership: read.membership, curatedSpanning: curatedSpanning)
        }
        // The pool is fixed for the loop, so index it once; the scan below
        // remains for a NaN date, which the index cannot order.
        let poolIndex = completedTrips.isEmpty || poolAfterAdoption.isEmpty ? nil : ReconciliationPoolIndex(
            poolAfterAdoption.map { (start: $0.startTime, end: $0.endTime) })
        do {
            var affectedTrips: [(trip: Trip, ordered: [Stay])] = []
            var spanningTrips: [(trip: Trip, ordered: [Stay])] = []
            for trip in completedTrips where !poolAfterAdoption.isEmpty || retroactiveScanDue {
                guard let endDate = trip.endDate else { continue }
                let ordered = trip.orderedStays
                guard let firstStay = ordered.first, let lastStay = ordered.last else { continue }
                let affected = poolIndex?.affects(
                    tripStart: trip.startDate, tripEnd: endDate,
                    firstStart: firstStay.startTime, lastEnd: lastStay.endTime,
                    boundaries: homeBoundaries)
                ?? poolAfterAdoption.contains { s in
                    // (1) The stay interleaves the trip's span.
                    if s.startTime < endDate && s.endTime > trip.startDate { return true }
                    // (2) After the trip but before its return-home stay. The gap judge
                    // is left to the fold: the stays between may not be in the pool yet.
                    if s.startTime >= lastStay.endTime {
                        return !hasHomeStayBetween(afterStay: lastStay, beforeStay: s, boundaries: homeBoundaries)
                    }
                    // (3) Before the trip with no home between.
                    if s.endTime <= firstStay.startTime {
                        return !hasHomeStayBetween(afterStay: s, beforeStay: firstStay, boundaries: homeBoundaries)
                    }
                    return false
                }
                if affected {
                    affectedTrips.append((trip, ordered))
                } else if retroactiveScanDue, spansHomeBoundary(ordered, boundaries: retroactive.index) {
                    spanningTrips.append((trip, ordered))
                }
            }
            // A favourite, a named trip, one with a photo choice or a stay the user
            // set is the user's whole journey: a late boundary does not take it apart.
            if !spanningTrips.isEmpty {
                let curated = try curatedTrips(among: spanningTrips.map(\.trip), pinnedTripIDs: pinnedTripIDs)
                for entry in spanningTrips {
                    if curated.contains(entry.trip.id) {
                        curatedSpanning.insert(entry.trip.id)
                    } else {
                        affectedTrips.append(entry)
                    }
                }
            }
            guard !poolAfterAdoption.isEmpty || !affectedTrips.isEmpty else {
                pendingHistoricalScan = .scanned(scanRead(membership: membershipRead))
                // Delete the empty reusable row after all stays are adopted.
                if let reusableOngoingTrip {
                    modelContext.delete(reusableOngoingTrip)
                    lastPipelineMadeChanges = true
                }
                try finishRegroup(regrouped, outputs: [])
                if adoptedCount > 0 {
                    logger.info("Adoption absorbed every unassigned stay — no regrouping needed.")
                }
                return adoptedCount
            }
            try regrouped.note(affectedTrips.map(\.trip), in: modelContext)
            // Stays an import or a shared removal took out of these trips
            // before this regroup (`PhotoLineageStore.detachedMembers`) still
            // count as theirs: for the id each keeps and its hidden choices.
            let detachedLog = PhotoLineageStore.detachedMembers(defaults: hiddenLineageDefaults)
            var detachedPool: [UUID: [Stay]] = [:]
            for (trip, _) in affectedTrips {
                guard let recorded = detachedLog[trip.id] else { continue }
                detachedPool[trip.id] = poolAfterAdoption.filter { recorded.contains($0.id) }
                regrouped.adopt(detachedPool[trip.id] ?? [], into: trip.id)
            }
            // New away stays do not let a boundary take a curated journey
            // apart either, as on the home-only path above: it regroups whole
            // with its detached members, and stays left whole across a
            // retroactive boundary are noted so un-curating it re-arms the scan.
            let curatedAffected = try curatedTrips(among: affectedTrips.map(\.trip), pinnedTripIDs: pinnedTripIDs)
            for (trip, ordered) in affectedTrips {
                if let first = ordered.first, let last = ordered.last {
                    regroupedCompletedSpans.append(HomeBoundarySpan(start: first.startTime, end: last.endTime))
                }
                let members = ordered + (detachedPool[trip.id] ?? [])
                if curatedAffected.contains(trip.id),
                   let start = members.map(\.startTime).min(), let end = members.map(\.endTime).max() {
                    curatedCompletedSpans.append(HomeBoundarySpan(start: start, end: end))
                    if spansHomeBoundary(members, boundaries: retroactive.index) {
                        curatedSpanning.insert(trip.id)
                    }
                }
                let stayIDs = Set(ordered.map(\.id))
                detachedCompletedSnapshots.append(DetachedCompletedTrip(
                    id: trip.id,
                    stayIDs: stayIDs.union(detachedLog[trip.id] ?? []),
                    startDate: trip.startDate,
                    classifiedByAI: trip.classifiedByAI,
                    customName: trip.customName
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
            if !detachedLog.isEmpty {
                pendingDetachedMembers = Self.prunedDetachedMembers(
                    detachedLog, regrouped: Set(affectedTrips.map(\.trip.id)),
                    automaticCompleted: Set(completedTrips.map(\.id)), stays: allTripStays)
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

        // gateMemberships scopes shapes to home eras so later visits to a former home can be trips,
        // and dates a temporary home's membership, so the base after the end is an ordinary place.
        // Read before grouping: the gap judge measures from the same departure home.
        let shapedHomeRings = withShapes(try fetchRequiredAnchors().map { Self.HomeRing($0) },
            overrides: try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()))
        let gapEvidence = TripGapEvidence(
            homeStays: homeStays, homeRings: shapedHomeRings,
            boundaries: homeBoundaries)

        // A journey already assembled is taken apart only where a boundary
        // clears the live bar (`isRetroactiveHomeBoundary`), whether or not new
        // away stays arrived with the home stay: between two stays inside a
        // regrouped completed trip's span, one imported home photo or a noisy
        // fix separates nothing. Elsewhere every qualifying boundary does.
        // Inside a curated one's span nothing does, nor does the gap judge.
        let curatedSpans = curatedCompletedSpans
        func separates(_ prev: Stay, _ stay: Stay) -> Bool {
            guard hasHomeStayBetween(afterStay: prev, beforeStay: stay, boundaries: homeBoundaries),
                  !Self.gap(after: prev, before: stay, isInside: curatedSpans) else {
                return false
            }
            guard regroupedCompletedSpans.contains(where: {
                prev.endTime >= $0.start && stay.startTime <= $0.end
            }) else { return true }
            return hasHomeStayBetween(afterStay: prev, beforeStay: stay, boundaries: retroactive.index)
        }

        // Group on home-stay gaps before any model writes, so reuse can be selected from the complete groups.
        var homeGroups: [[Stay]] = []
        for stay in groupingPool {
            // Track the last appended stay explicitly: SwiftData assignment realizes inverses immediately,
            // but pending deletes do not nullify them until save.
            if let prev = homeGroups.last?.last, !separates(prev, stay) {
                homeGroups[homeGroups.count - 1].append(stay)
            } else {
                homeGroups.append([stay])
            }
        }
        // Then end trips inside a closed group where the gap judge sees a return home.
        let groups = homeGroups.flatMap {
            splitOnJudgedGaps($0, evidence: gapEvidence, keptWhole: curatedSpans)
        }

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
                homeBoundaries: homeBoundaries,
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
        // groups hold their trips, which is what the next check reads. Real homes
        // alone need it too: a move inside a fingerprint's allowance can cross a
        // home area's edge, and a tripless transit row can change a run's length.
        if suppressedFingerprints.isEmpty {
            gateSuppressionInputDigest = nil
        } else {
            let admitted = Set(confidentGroups.joined().map { ObjectIdentifier($0) })
            gateSuppressionInputDigest = Self.suppressionInputDigest(
                rings: shapedHomeRings,
                stays: allTripStays.filter {
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
                group, homeStays: homeStays, homeRings: shapedHomeRings)
            closeTrip(trip, boundaries: homeBoundaries)
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
                let names = Dictionary(detachedCompletedSnapshots.compactMap { snapshot in
                    snapshot.customName.map { (snapshot.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
                for (index, id) in claims {
                    createdTrips[index].trip.id = id
                    if let name = names[id], createdTrips[index].trip.customName == nil {
                        createdTrips[index].trip.customName = name
                    }
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
        // Identities are final: hidden choices follow the detached trips' stays.
        try finishRegroup(regrouped, outputs: createdTrips.map(\.trip))
        pendingHistoricalScan = .scanned(scanRead(
            membership: completedMembership(allTripStays, keptTripIDs: keptTripIDs)))

        logger.info("Assembled \(newTripsCreated) new trip(s).")
        // Adopted stays are a store mutation too — callers key "did the
        // pipeline change anything" off this return, and a pure-adoption
        // pass must still propagate (save, widgets, summaries).
        return newTripsCreated + adoptedCount
    }

    /// Hidden choices follow a regroup's stays once identities are final:
    /// here, or, inside a temporary-home unit, after its own arbitration,
    /// which takes `regrouped` from `deferredAssemblyIdentities`.
    private func finishRegroup(_ regrouped: RegroupedTrips, outputs: [Trip]) throws {
        if deferredAssemblyIdentities != nil {
            deferredAssemblyIdentities?.regrouped = regrouped
        } else {
            try inheritRegroupedHiddenChoices(regrouped, outputs: outputs)
        }
    }

    /// The detached-member log after a regroup: the trips it regrouped, and
    /// any that is no longer an automatic completed trip, leave it; a stay
    /// another trip holds now leaves its entry.
    static func prunedDetachedMembers(
        _ log: [UUID: Set<UUID>], regrouped: Set<UUID>, automaticCompleted: Set<UUID>, stays: [Stay]
    ) -> [UUID: Set<UUID>] {
        var tripOfStay: [UUID: UUID] = [:]
        for stay in stays where !stay.isDeleted {
            if let trip = stay.trip, !trip.isDeleted { tripOfStay[stay.id] = trip.id }
        }
        var pruned: [UUID: Set<UUID>] = [:]
        for (tripID, stayIDs) in log where !regrouped.contains(tripID) && automaticCompleted.contains(tripID) {
            let pending = stayIDs.filter { tripOfStay[$0] == nil || tripOfStay[$0] == tripID }
            if !pending.isEmpty { pruned[tripID] = pending }
        }
        return pruned
    }

    // MARK: - Retroactive home boundaries

    /// What an assembly's scan of completed trips for retroactive home
    /// boundaries stood on. The scan walks every completed trip's members, so
    /// an assembly with no stay to group skips it while all of this holds.
    /// Only a boundary within a completed trip's span can split it, so the
    /// home stay a person is living in, after the last trip, moves none of it.
    struct HistoricalBoundaryScan {
        /// The store's history before the scan's reads: a commit after it is unseen.
        var token: DefaultHistoryToken?
        /// The retroactive boundaries within `extents` (`retroactiveBoundaryDigest`).
        var boundaries: SHA256.Digest
        /// The spans of the completed trips in `membership`.
        var extents: TripExtents
        /// Every home stay within `extents`, so a later commit that touches
        /// none of them, and puts no home stay there, reads nothing more.
        var homeStays: Set<PersistentIdentifier>
        /// The completed trips the scan may take apart, with their stays, as
        /// the scanning assembly left them (`completedMembership`).
        var membership: Set<StayMembership>
        /// The trips that span a retroactive boundary but stay whole because
        /// the user curated them: once one no longer is, it is scanned again.
        var curatedSpanning: Set<UUID>
    }

    /// A stay held by a completed trip a retroactive boundary may take apart.
    struct StayMembership: Hashable {
        let stayID: UUID
        let tripID: UUID
    }

    /// The completed trips a retroactive boundary may take apart, with the
    /// time their stays cover.
    struct CompletedMembership {
        var membership: Set<StayMembership>
        var extents: TripExtents
    }

    /// The time covered by trips, merged into sorted disjoint closed spans.
    /// A boundary that touches none of them separates no two stays of a trip.
    struct TripExtents {
        private(set) var spans: [HomeBoundarySpan] = []
        /// A member stay with an unordered (NaN) instant: every span is in.
        private(set) var coversAll = false

        init(_ ranges: [(start: Date, end: Date)]) {
            if ranges.contains(where: { Self.isUnordered($0.start) || Self.isUnordered($0.end) }) {
                coversAll = true
                return
            }
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                if let last = spans.last, range.start <= last.end {
                    spans[spans.count - 1] = HomeBoundarySpan(start: last.start, end: max(last.end, range.end))
                } else {
                    spans.append(HomeBoundarySpan(start: range.start, end: max(range.start, range.end)))
                }
            }
        }

        /// Whether `start...end` touches a span, endpoints included.
        func overlaps(start: Date, end: Date) -> Bool {
            if coversAll || Self.isUnordered(start) || Self.isUnordered(end) { return true }
            guard !spans.isEmpty else { return false }
            // The last span starting at or before `max(start, end)`.
            let upper = max(start, end)
            var low = 0, high = spans.count
            while low < high {
                let mid = (low + high) / 2
                if spans[mid].start <= upper { low = mid + 1 } else { high = mid }
            }
            return low > 0 && spans[low - 1].end >= min(start, end)
        }

        static func isUnordered(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isNaN }
    }

    /// What a unit's assembly read for `acknowledgedHistoricalScan`.
    enum PendingHistoricalScan {
        /// The unit has not assembled.
        case none
        case scanned(HistoricalBoundaryScan)
    }

    /// Makes the scan this unit's assembly read the acknowledged one; call
    /// only once the unit's save committed.
    func acknowledgePendingHistoricalScan() {
        switch pendingHistoricalScan {
        case .none: break
        case .scanned(let scan): acknowledgedHistoricalScan = scan
        }
        pendingHistoricalScan = .none
    }

    /// Whether `stay` takes a completed trip apart after the fact: a home stay
    /// that clears the bar live evidence must (`isQualifyingHomeBoundary` for a
    /// live stay), at least `homeBoundaryMinimumDwellSeconds` of dwell from more
    /// than one observation or with a linked Visit. One imported home photo or
    /// a noisy single fix still separates stays the fold groups together for
    /// the first time, but never splits a journey already assembled.
    func isRetroactiveHomeBoundary(_ stay: Stay, visitBacked: Set<UUID>) -> Bool {
        guard stay.category == .home, stay.source != .sharedImport else { return false }
        return Self.isQualifyingHomeBoundary(
            category: .home, source: .liveSLC,
            startTime: stay.startTime, endTime: stay.endTime,
            pingCount: stay.pingCount, hasVisit: visitBacked.contains(stay.id))
    }

    /// The retroactive boundaries among `homeStays`, and their index.
    func retroactiveHomeBoundaries(
        _ homeStays: [Stay], visitBacked: Set<UUID>
    ) -> (index: HomeBoundaryIndex, spans: [HomeBoundarySpan]) {
        let spans = homeStays
            .filter { isRetroactiveHomeBoundary($0, visitBacked: visitBacked) }
            .map { HomeBoundarySpan(start: $0.startTime, end: $0.endTime) }
        return (HomeBoundaryIndex(spans), spans)
    }

    /// A digest, which no fetch order changes, of the boundaries among `spans`
    /// that touch `extents`: the only ones that can split a trip there.
    static func retroactiveBoundaryDigest(
        _ spans: [HomeBoundarySpan], within extents: TripExtents
    ) -> SHA256.Digest {
        let bits = spans.filter { extents.overlaps(start: $0.start, end: $0.end) }.map {
            ($0.start.timeIntervalSinceReferenceDate.bitPattern, $0.end.timeIntervalSinceReferenceDate.bitPattern)
        }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var data = Data(capacity: bits.count * 16)
        for (start, end) in bits {
            for value in [start, end] {
                var big = value.bigEndian
                withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data)
    }

    /// Each stay among `stays` held by a completed trip that is not edited or
    /// kept, with that trip's id, and the time those trips' stays cover. The
    /// trips are read by this unit (or created by it), so no trip faults in
    /// on its own.
    func completedMembership(_ stays: [Stay], keptTripIDs: Set<UUID>) -> CompletedMembership {
        var membership = Set<StayMembership>()
        var covered: [UUID: (start: Date, end: Date)] = [:]
        var unordered: [(start: Date, end: Date)] = []
        for stay in stays where !stay.isDeleted {
            guard let trip = stay.trip, !trip.isDeleted, trip.isComplete, !trip.userEdited,
                  !keptTripIDs.contains(trip.id) else { continue }
            membership.insert(StayMembership(stayID: stay.id, tripID: trip.id))
            let start = stay.startTime, end = stay.endTime
            if TripExtents.isUnordered(start) || TripExtents.isUnordered(end) {
                unordered.append((start, end))
                continue
            }
            if let span = covered[trip.id] {
                covered[trip.id] = (min(span.start, start), max(span.end, end))
            } else {
                covered[trip.id] = (start, end)
            }
        }
        return CompletedMembership(membership: membership, extents: TripExtents(Array(covered.values) + unordered))
    }

    /// Whether the completed trips must be scanned for retroactive boundaries:
    /// no committed scan yet, its boundaries or memberships moved since, or a
    /// trip it left whole for the user is no longer curated. Throws on a failed read.
    private func historicalScanDue(
        _ acknowledged: HistoricalBoundaryScan?, boundaries: SHA256.Digest,
        membership: Set<StayMembership>, completedTrips: [Trip], pinnedTripIDs: Set<UUID>
    ) throws -> Bool {
        guard let acknowledged, acknowledged.boundaries == boundaries,
              acknowledged.membership == membership else { return true }
        guard !acknowledged.curatedSpanning.isEmpty else { return false }
        let held = completedTrips.filter { acknowledged.curatedSpanning.contains($0.id) }
        return try curatedTrips(among: held, pinnedTripIDs: pinnedTripIDs) != acknowledged.curatedSpanning
    }

    /// The trips among `trips` the user curated: a favourite, a name, a hidden
    /// or pinned photo, or a member the user set (`curatedTripIDs` for one
    /// coverage edit). Throws on a failed read: an unread photo table is not
    /// one without choices.
    func curatedTrips(among trips: [Trip], pinnedTripIDs: Set<UUID>) throws -> Set<UUID> {
        guard !trips.isEmpty else { return [] }
        let ids = Array(Set(trips.map(\.id)))
        var curated = Set(ids).intersection(pinnedTripIDs)
        var hidden = FetchDescriptor<HiddenPhoto>(predicate: #Predicate { ids.contains($0.tripID) })
        hidden.propertiesToFetch = [\.tripID]
        curated.formUnion(try modelContext.fetch(hidden).map(\.tripID))
        var pinned = FetchDescriptor<PinnedPhoto>(predicate: #Predicate { ids.contains($0.tripID) })
        pinned.propertiesToFetch = [\.tripID]
        curated.formUnion(try modelContext.fetch(pinned).map(\.tripID))
        for trip in trips where trip.customName != nil || (trip.stays ?? []).contains(where: \.userOverridden) {
            curated.insert(trip.id)
        }
        return curated
    }

    /// Whether a qualifying home boundary lies between two consecutive stays
    /// of a trip in time order, the grouping fold's own test: a home stay that
    /// arrived late, or came to qualify, after the trip was assembled splits it.
    /// Only the trip-class stays the fold groups are read.
    func spansHomeBoundary(_ stays: [Stay], boundaries: HomeBoundaryIndex) -> Bool {
        guard stays.count > 1, !boundaries.isEmpty else { return false }
        let grouped = stays
            .filter { $0.category == .destination || $0.category == .transit }
            .sorted {
                $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.id.uuidString < $1.id.uuidString
            }
        return zip(grouped, grouped.dropFirst()).contains {
            hasHomeStayBetween(afterStay: $0, beforeStay: $1, boundaries: boundaries)
        }
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
        let windows = Self.homeWindows(homeRings)
        for stay in group {
            let km = Self.departureDistanceKm(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                anchor: anchor, tripStart: first.startTime, homes: windows)
            if km.isFinite, abs(km - stay.distanceFromHomeKm) > 0.001 {
                stay.distanceFromHomeKm = km
            }
        }
    }

    nonisolated static func homeWindows(_ homeRings: [HomeRing]) -> [StayClusterer.HomeWindow] {
        homeRings.map {
            StayClusterer.HomeWindow(
                latitude: $0.latitude, longitude: $0.longitude,
                startedAt: $0.startedAt, endedAt: $0.endedAt,
                isTemporary: $0.isTemporary)
        }
    }

    /// One stay's distance as a trip starting at `tripStart` stamps it: from
    /// the departure home when one claimed the last home stay before, else
    /// from the nearest home that applied at the trip's start.
    nonisolated static func departureDistanceKm(
        latitude: Double, longitude: Double,
        anchor: (latitude: Double, longitude: Double)?,
        tripStart: Date, homes: [StayClusterer.HomeWindow]
    ) -> Double {
        if let anchor {
            return CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude)) / 1000.0
        }
        return StayClusterer.closestHomeDistanceKm(
            latitude: latitude, longitude: longitude, atTime: tripStart, homes: homes)
    }

    // MARK: - Gap judge

    /// What `TripGapJudge` reads beside a gap's two stays, gathered once per pass.
    struct TripGapEvidence {
        let homeStays: [Stay]
        let homeRings: [HomeRing]
        let homeWindows: [StayClusterer.HomeWindow]
        let boundaries: HomeBoundaryIndex

        init(homeStays: [Stay], homeRings: [HomeRing], boundaries: HomeBoundaryIndex) {
            self.homeStays = homeStays
            self.homeRings = homeRings
            self.homeWindows = TripClassifier.homeWindows(homeRings)
            self.boundaries = boundaries
        }
    }

    /// Whether the gap from `earlier`'s end to `later`'s start lies inside one of `spans`.
    nonisolated static func gap(after earlier: Stay, before later: Stay, isInside spans: [HomeBoundarySpan]) -> Bool {
        spans.contains { earlier.endTime >= $0.start && later.startTime <= $0.end }
    }

    /// Splits a home-bounded group where the gap judge sees a trip end: between two
    /// stays with no home evidence, `.separateTrips` starts a new trip at the later
    /// stay, and `.sameTrip` and `.unsure` keep one. An open group (no qualifying
    /// home stay after it, the test `closeTrip` applies) is never split, so silence
    /// inside a trip still being recorded cannot cut it; it is judged once it closes.
    /// Edited and kept trips never reach the pool, so a user's merge or split holds;
    /// a gap inside one of `keptWhole` (a curated journey's span) is not judged.
    func splitOnJudgedGaps(
        _ group: [Stay], evidence: TripGapEvidence, keptWhole: [HomeBoundarySpan] = []
    ) -> [[Stay]] {
        guard group.count > 1, let last = group.last,
              evidence.boundaries.hasStart(atOrAfter: last.endTime) else { return [group] }
        var pieces: [[Stay]] = [[group[0]]]
        var anchor = Self.departureHomeAnchor(
            tripStart: group[0].startTime, homeStays: evidence.homeStays, homeRings: evidence.homeRings)
        for stay in group.dropFirst() {
            let piece = pieces[pieces.count - 1]
            let verdict = Self.gap(after: piece[piece.count - 1], before: stay, isInside: keptWhole)
                ? nil
                : gapVerdict(
                    after: piece[piece.count - 1], before: stay,
                    tripStart: piece[0].startTime, anchor: anchor, evidence: evidence)
            if verdict == .separateTrips {
                pieces.append([stay])
                anchor = Self.departureHomeAnchor(
                    tripStart: stay.startTime, homeStays: evidence.homeStays, homeRings: evidence.homeRings)
            } else {
                pieces[pieces.count - 1].append(stay)
            }
        }
        return pieces
    }

    /// The judge's verdict on the gap from `earlier`'s end to `later`'s start,
    /// each side measured as the trip starting at `tripStart` stamps it, which is
    /// what `TripGapQuestion` reads back. Nil when the stays touch or overlap.
    private func gapVerdict(
        after earlier: Stay, before later: Stay, tripStart: Date,
        anchor: (latitude: Double, longitude: Double)?, evidence: TripGapEvidence
    ) -> TripGapJudge.Verdict? {
        guard earlier.endTime < later.startTime else { return nil }
        func side(_ stay: Stay, at time: Date) -> TripGapJudge.Side {
            TripGapJudge.Side(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                distanceFromHomeKm: Self.departureDistanceKm(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    anchor: anchor, tripStart: tripStart, homes: evidence.homeWindows),
                time: time)
        }
        return TripGapJudge.verdict(
            after: side(earlier, at: earlier.endTime), before: side(later, at: later.startTime))
    }

    /// The centre of the ring that contained the last `.home` stay before
    /// `tripStart`, evaluated at that stay's own time with the same geometry
    /// as `matchesHome` (measured membership when attached, the declared
    /// circle otherwise). When several rings overlap, the temporary home the
    /// stay records as its owner wins while it still claims the stay, the one
    /// the trip's header names (`departurePlaceName`); otherwise the nearest
    /// centre wins. Nil when there is no such stay or no ring claims it.
    /// Pure; test seam.
    nonisolated static func departureHomeAnchor(
        tripStart: Date, homeStays: [Stay], homeRings: [HomeRing]
    ) -> (latitude: Double, longitude: Double)? {
        guard let departure = homeStays
            .filter({ $0.startTime < tripStart })
            .max(by: { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) })
        else { return nil }
        let location = CLLocation(
            latitude: departure.centroidLatitude, longitude: departure.centroidLongitude)
        let recordedOwner = departure.temporaryHomeID
        var recorded: HomeRing?
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
            if ring.isTemporary, let recordedOwner, ring.homeID == recordedOwner { recorded = ring }
            if best == nil || km < best!.km { best = (ring, km) }
        }
        if let recorded { return (recorded.latitude, recorded.longitude) }
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
        homeBoundaries: HomeBoundaryIndex,
        shapedHomeRings: [HomeRing],
        reusablePriorStayIDs: Set<UUID>
    ) -> (admitted: Bool, reason: String) {
        // Open tail: `groups.last` alone is not enough — a qualifying terminal
        // home stay is not in `groups`.
        if homeBoundaries.hasStart(atOrAfter: tailStay.endTime) {
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
