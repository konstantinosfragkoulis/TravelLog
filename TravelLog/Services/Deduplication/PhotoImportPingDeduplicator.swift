//
//  PhotoImportPingDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

/// Deduplicate photo, Timeline, and GPX pings arriving through CloudKit outside insert-time checks.
/// CloudKit disallows unique constraints; import ownership gates cannot eliminate cross-device races.
/// Exclude jsonImport: ImportFence warns on cross-device file reuse because identical-UUID Trip/Stay
/// copies have no convergence-safe survivor ordering, and window dedup could collapse a short stay’s synthetic pair.
///
/// **Convergence property.** Both devices compute the same "to-delete"
/// set OVER THE SAME ROW SET: the deterministic `(timestamp,
/// id.uuidString)` sort + keep-first rule makes deletes idempotent
/// across CloudKit once hydration has delivered the same rows to both
/// sides — the same convergence rule as `PhotoAnnotationDeduplicator`
/// and `PhotoImportStateDeduplicator`. The greedy WINDOW CHAINING is
/// not subset-stable: a partially-hydrated
/// device seeing only a chain's middle+late members can delete a row
/// the full set would keep. Accepted: insert-time dedup (same window)
/// prevents same-source chains from existing, cross-device duplicates
/// of the same asset land at IDENTICAL timestamps (trivially
/// convergent same-t groups), and the residual multi-source chain case
/// costs one redundant intra-cluster map dot — Phase B never deletes a
/// stay unless ALL its pings were duplicates. Identical UUID/timestamp
/// twins use persistent row identity as a deterministic local tiebreak;
/// persistent identifiers do not establish an ordering across devices.
///
/// **Two-phase execution.** The local import loop mutates
/// `Stay.pingIDsString` across gate units. Defer the WHOLE pass while a
/// photo or external-history import is active locally; the next launch or
/// remote notification retries against the intact rows. When idle:
///   - **Phase A** — select and delete duplicate physical ping rows.
///   - **Phase B** — remove only UUIDs with no retained physical copy from
///     stays and recompute affected trip summaries.
/// Both phases commit in one save, so a failed reconciliation cannot leave
/// durable deletions whose stay-reference cleanup has been forgotten.
///
/// Do not deduplicate Stay rows, undo approximate HexVisit counts, or move centroids after ping removal.
/// Reentrancy is guarded by OSAllocatedUnfairLock. Launch and remote-sync callers run off-main.
/// nonisolated is required under default-MainActor isolation so detached callers do not hop back to main.
nonisolated enum PhotoImportPingDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "PhotoImportPingDeduplicator"
    )

    private static let isRunning = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    // MARK: - Orphan import-ping re-adoption

    /// Device-local first-sighting ages for orphaned import pings.
    /// Deliberately NOT synced — each device ages orphans from its own
    /// first sighting (the `PhotoAnnotationDeduplicator` orphan pattern).
    static let orphanPingFirstObservedKey = "orphanImportPingFirstObserved_v1"

    /// A ping must look orphaned for this long on THIS device before
    /// re-adoption: transient CloudKit arrival order (a stay's
    /// `pingIDsString` write landing after its ping row) must never trigger
    /// a spurious re-cluster.
    static let orphanPingGracePeriod: TimeInterval = 60 * 60

    #if DEBUG
    /// Cross-device whole-field merges can orphan processed pings; re-adopt aged orphans for reclustering.
    /// Exclude jsonImport because its synthetic pings are inserted atomically with their stay.
    /// Tests inject importActivityProbe to avoid process-global activity from unrelated fixture stores.
    /// Returns false when the sweep deferred or failed, so a caller can retry on a later trigger.
    @discardableResult
    static func readoptOrphanImportPings(
        modelContainer: ModelContainer,
        now: Date = .now,
        defaults: UserDefaults = .standard,
        importActivityProbe: (@Sendable () async -> Bool)? = nil
    ) async -> Bool {
        // Same deferral as Phase B: an active local import is mid-flight
        // between gate units and its just-attached pings must not be judged.
        let anImportIsActive: Bool
        if let importActivityProbe {
            anImportIsActive = await importActivityProbe()
        } else {
            let isImportActive = await AppDelegate.photoImportService.isCurrentlyRunning()
            let isExternalImportActive = await MainActor.run { ExternalHistoryImporter.isImportRunning }
            anImportIsActive = isImportActive || isExternalImportActive
        }
        guard !anImportIsActive else { return false }

        let context = ModelContext(modelContainer)
        let predicate = #Predicate<LocationPing> {
            ($0.sourceRaw == "photoImport"
                || $0.sourceRaw == "timelineImport"
                || $0.sourceRaw == "gpxImport")
                && $0.isProcessed == true
        }
        let importPings: [LocationPing]
        do {
            importPings = try context.fetch(FetchDescriptor<LocationPing>(predicate: predicate))
        } catch {
            logger.error("Orphan re-adoption: ping fetch failed: \(error.localizedDescription)")
            return false
        }
        return readoptOrphans(among: importPings, in: context, now: now, defaults: defaults)
    }
    #endif

    /// A stay and its parsed ping membership, read once per pass.
    private typealias StayMembership = (stay: Stay, pingIDs: [UUID])

    /// Every stay with its membership. Only the membership column is fetched;
    /// Phase B faults in the rest of the rows it rewrites.
    private static func fetchMemberships(in context: ModelContext) throws -> [StayMembership] {
        var descriptor = FetchDescriptor<Stay>()
        descriptor.propertiesToFetch = [\.pingIDsString]
        return try context.fetch(descriptor).map { (stay: $0, pingIDs: $0.pingIDs) }
    }

    /// The orphan sweep over already-fetched processed import pings. Shared by
    /// the standalone sweep and `deduplicateAll`, which passes the processed
    /// subset of its own fetch. Its save commits only the re-adoption flips.
    /// Returns false when it bailed on a stay fetch, the mid-sync guard or a
    /// failed save.
    private static func readoptOrphans(
        among importPings: [LocationPing],
        in context: ModelContext,
        now: Date,
        defaults: UserDefaults
    ) -> Bool {
        guard !importPings.isEmpty else {
            // No import ping is left to observe, so every entry is stale.
            defaults.removeObject(forKey: orphanPingFirstObservedKey)
            return true
        }

        // A fetch failure or an empty stay table alongside import pings is
        // mid-sync (or worse) — bail rather than judge every ping an orphan
        // (the annotation sweep's mass-delete guard, adapted).
        let stays: [StayMembership]
        do {
            stays = try fetchMemberships(in: context)
        } catch {
            logger.error("Orphan re-adoption: stay fetch failed: \(error.localizedDescription)")
            return false
        }
        guard !stays.isEmpty else { return false }
        var referenced = Set<UUID>()
        for stay in stays { referenced.formUnion(stay.pingIDs) }

        let firstObserved = (defaults.dictionary(forKey: orphanPingFirstObservedKey) as? [String: Double]) ?? [:]
        let nowEpoch = now.timeIntervalSince1970
        var nextObserved: [String: Double] = [:]
        var readopted = 0
        for ping in importPings where !referenced.contains(ping.id) {
            let key = ping.id.uuidString
            let seenEpoch = firstObserved[key] ?? nowEpoch
            if nowEpoch - seenEpoch >= orphanPingGracePeriod {
                ping.isProcessed = false
                readopted += 1
            } else {
                nextObserved[key] = seenEpoch
            }
        }
        // Healed (re-referenced) and re-adopted entries drop off the map so
        // it never grows unboundedly.
        defaults.set(nextObserved, forKey: orphanPingFirstObservedKey)
        guard readopted > 0 else { return true }
        do {
            try context.save()
            logger.info("Re-adopted \(readopted) orphaned import ping(s) — next cluster pass re-folds them.")
            return true
        } catch {
            context.rollback()
            logger.error("Orphan re-adoption save failed: \(error.localizedDescription)")
            return false
        }
    }

    static let hexVisitRepairCompletedKey = "hexVisitRepairCompleted_v1"

    #if DEBUG
    @TaskLocal static var failHexVisitRepairSaveForTesting = false
    #endif

    /// Local-only, additive HexVisit repair projects import cell/timestamp in one fetch because H3 is unindexed.
    /// Own one hexVisit gate unit and latch completion only after successful save so failures/cancellation retry.
    static func repairMissingHexVisitsOnce(
        modelContainer: ModelContainer,
        defaultsSuiteName: String? = nil,
        gate: PipelineGate = .shared
    ) async {
        guard modelContainer.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else { return }
        guard !Task.isCancelled else { return }
        let completed = (defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
            .bool(forKey: hexVisitRepairCompletedKey)
        guard !completed else { return }
        await gate.run(touching: [.hexVisit]) {
            let defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            do {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate {
                    $0.sourceRaw == "photoImport" || $0.sourceRaw == "timelineImport"
                        || $0.sourceRaw == "gpxImport"
                })
                descriptor.propertiesToFetch = [\.h3IndexRes6, \.timestamp]
                let evidence = try context.fetch(descriptor)
                let restored = try restoreMissingHexVisits(from: evidence, in: context)
                try Task.checkCancellation()
                #if DEBUG
                if failHexVisitRepairSaveForTesting { throw CocoaError(.fileWriteUnknown) }
                #endif
                if context.hasChanges { try context.save() }
                defaults.set(true, forKey: hexVisitRepairCompletedKey)
                logger.info("Local HexVisit repair restored \(restored) row(s) from \(evidence.count) import ping(s).")
            } catch {
                context.rollback()
                logger.error("Local HexVisit repair will retry next launch: \(error.localizedDescription)")
            }
        }
    }

    /// Repair missing map rows using positive local ping evidence only. Existing
    /// rows are never shrunk or overwritten: they may describe history whose
    /// pings have not hydrated here. A new row records one proven visit and
    /// the observed date envelope, not an invented historical entry total.
    private static func restoreMissingHexVisits(from pings: [LocationPing], in context: ModelContext) throws -> Int {
        // A remote privacy deletion can deliver its hex tombstone before its
        // ping tombstones. Recreating that row during partial sync resurrects
        // deleted history, so automatic repair is only safe in a local store.
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else { return 0 }
        try Task.checkCancellation()
        let existing = Set(try context.fetch(FetchDescriptor<HexVisit>()).map(\.h3Index))
        var byCell: [String: (first: Date, last: Date)] = [:]
        for ping in pings where !existing.contains(ping.h3IndexRes6) {
            let timestamp = ping.timestamp
            if let bounds = byCell[ping.h3IndexRes6] {
                byCell[ping.h3IndexRes6] = (min(bounds.first, timestamp), max(bounds.last, timestamp))
            } else {
                byCell[ping.h3IndexRes6] = (timestamp, timestamp)
            }
        }
        var restored = 0
        for (cell, bounds) in byCell {
            try Task.checkCancellation()
            guard let center = H3Service.centerCoordinate(for: cell) else { continue }
            let row = HexVisit(h3Index: cell, firstVisited: bounds.first,
                centerLatitude: center.latitude, centerLongitude: center.longitude)
            row.lastVisited = bounds.last
            context.insert(row)
            restored += 1
        }
        return restored
    }

    /// The single-flight lease is container-scoped. The legacy testing flag
    /// also bypasses process-global importer activity probes for isolated
    /// fixture stores; production callers never pass it. Activity can be
    /// overridden explicitly in DEBUG to exercise deferral. Returns true only
    /// when the pass and its orphan sweep ran to completion; a deferral or a
    /// failure returns false so the caller can retry on a later trigger.
    #if DEBUG
    @TaskLocal static var beforeFetchForTesting: (@Sendable () async -> Void)?
    @TaskLocal static var beforeVisitBackingReadForTesting: (@Sendable () throws -> Void)?
    #endif

    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        bypassSingleFlightForTesting: Bool = false,
        importActivityForTesting: (photo: Bool, external: Bool)? = nil,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        if !bypassSingleFlightForTesting {
            let alreadyRunning = isRunning.withLock { running -> Bool in
                if running.contains(ObjectIdentifier(modelContainer)) { return true }
                running.insert(ObjectIdentifier(modelContainer))
                return false
            }
            guard !alreadyRunning else {
                logger.debug("PhotoImportPing dedup already in progress, skipping.")
                return false
            }
        }
        defer {
            if !bypassSingleFlightForTesting { _ = isRunning.withLock { $0.remove(ObjectIdentifier(modelContainer)) } }
        }

        #if DEBUG
        if let beforeFetchForTesting { await beforeFetchForTesting() }
        #endif
        // A crash can leave a pending local transaction witness. Resolve it
        // through the owning Resume path before dedup can erase those IDs.
        do {
            if try PhotoImportCheckpointJournal.read(in: modelContainer)?.pending != nil { return false }
        } catch {
            logger.error("Dedup deferred: checkpoint recovery journal is unreadable.")
            return false
        }

        // Defer before any store work: deleting now would lose the UUIDs
        // needed to reconcile stays when the import eventually finishes.
        var isImportActive: Bool
        var isExternalImportActive: Bool
        if bypassSingleFlightForTesting {
            // Hermetic stores cannot be touched by the process-global import
            // actors; bypass those unrelated activity probes for fixtures.
            isImportActive = false
            isExternalImportActive = false
        } else {
            isImportActive = await AppDelegate.photoImportService.isCurrentlyRunning()
            // The Timeline/GPX spine mutates the same `Stay.pingIDsString` via
            // its pre-attach merge across many gate units — same conflict
            // hazard as the photo loop, same deferral.
            isExternalImportActive = await MainActor.run { ExternalHistoryImporter.isImportRunning }
        }
        #if DEBUG
        if let importActivityForTesting {
            isImportActive = importActivityForTesting.photo
            isExternalImportActive = importActivityForTesting.external
        }
        #endif
        guard !isImportActive, !isExternalImportActive else {
            logger.info("Dedup deferred: an import is running locally; will retry next trigger.")
            return false
        }

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Group photo, Timeline, and GPX sources as insert-time dedup does.
        // Sort UUID strings in memory because SwiftData SortDescriptor requires Comparable keys.
        let predicate = #Predicate<LocationPing> {
            $0.sourceRaw == "photoImport"
                || $0.sourceRaw == "timelineImport"
                || $0.sourceRaw == "gpxImport"
        }
        let allImportPings: [LocationPing]
        do {
            allImportPings = try context.fetch(FetchDescriptor<LocationPing>(predicate: predicate))
        } catch {
            logger.error("Failed to fetch import pings: \(error.localizedDescription)")
            return false
        }
        // Re-adopt on every idle trigger, even when there are no duplicates, over
        // this pass's own fetch. Activity was checked above; callers hold
        // PipelineGate throughout.
        let readoptCompleted = readoptOrphans(
            among: allImportPings.filter { $0.isProcessed },
            in: context, now: .now, defaults: defaults)
        let restoredHexes: Int
        do { restoredHexes = try restoreMissingHexVisits(from: allImportPings, in: context) }
        catch {
            context.rollback()
            logger.error("Missing HexVisit repair failed: \(error.localizedDescription)")
            return false
        }
        guard allImportPings.count >= 2 else {
            if restoredHexes > 0 {
                do { try context.save() } catch { context.rollback(); return false }
            }
            return readoptCompleted
        }

        // Logical ordering converges across devices; physical identity breaks
        // UUID-twin ties deterministically within this store. Model getters
        // are costly, so the sort and the scan work on fields read once per
        // ping; id and row identity are read only on ties, as before.
        let sorted = allImportPings.map { ping in
            (ping: ping, timestamp: ping.timestamp, source: ping.source)
        }.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            let aID = a.ping.id, bID = b.ping.id
            if aID != bID { return aID.uuidString < bID.uuidString }
            return a.ping.persistentModelID < b.ping.persistentModelID
        }

        // Every pair's window is bounded by its candidate's source window.
        // Dense same-window inputs remain quadratic. Rows are marked by sorted
        // position; coordinates are read at a row's first distance check.
        var deleting = [Bool](repeating: false, count: sorted.count)
        var coordinates: [(latitude: Double, longitude: Double)?] = Array(repeating: nil, count: sorted.count)
        func newLocation(_ k: Int) -> CLLocation {
            let coordinate = coordinates[k]
                ?? (latitude: sorted[k].ping.latitude, longitude: sorted[k].ping.longitude)
            coordinates[k] = coordinate
            return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        for i in 0..<sorted.count {
            let candidate = sorted[i]
            guard !deleting[i] else { continue }

            var candidateLoc: CLLocation?
            let candidateWindow = ImportDedupPolicy.thresholds(for: candidate.source).windowSeconds

            var j = i + 1
            while j < sorted.count {
                let other = sorted[j]
                if other.timestamp.timeIntervalSince(candidate.timestamp) > candidateWindow {
                    break
                }
                if deleting[j] { j += 1; continue }

                // Use the symmetric, narrowest-of-two source window and MUST match insert-time dedup.
                // Symmetry is required for devices with the same rows to compute the same delete set.
                let pairThresholds = ImportDedupPolicy.pair(candidate.source, other.source)
                if other.timestamp.timeIntervalSince(candidate.timestamp) <= pairThresholds.windowSeconds {
                    let location = candidateLoc ?? newLocation(i)
                    candidateLoc = location
                    let otherLoc = newLocation(j)
                    if location.distance(from: otherLoc) <= pairThresholds.radiusMeters {
                        // Keep `candidate` (earlier in deterministic sort),
                        // delete `other`.
                        deleting[j] = true
                    }
                }
                j += 1
            }
        }

        let deletedRows = sorted.indices.filter { deleting[$0] }
        guard !deletedRows.isEmpty else {
            if restoredHexes > 0 {
                do { try context.save() } catch { context.rollback(); return false }
            }
            logger.debug("No duplicate import pings found.")
            return readoptCompleted
        }

        // Resolve logical deletions before mutating. A retained UUID twin,
        // including one outside the import-source predicate, still represents
        // the stay membership. Locally absent, unrelated UUIDs are untouched.
        let pingsToDelete = Set(deletedRows.map { sorted[$0].ping.persistentModelID })
        let deletedIDs = Array(Set(deletedRows.map { sorted[$0].ping.id }))
        var deletedPingIDs = Set(deletedIDs)
        let allStays: [StayMembership]
        let visitBackedStayIDs: Set<UUID>
        do {
            // Bound each IN predicate for large re-imported libraries.
            for start in stride(from: 0, to: deletedIDs.count, by: 500) {
                let chunk = Array(deletedIDs[start..<min(start + 500, deletedIDs.count)])
                let twins = try context.fetch(FetchDescriptor<LocationPing>(
                    predicate: #Predicate { chunk.contains($0.id) }))
                for ping in twins where !pingsToDelete.contains(ping.persistentModelID) {
                    deletedPingIDs.remove(ping.id)
                }
            }
            // Fresh read right before Phase B, as before: a sync may have landed since the sweep.
            allStays = try fetchMemberships(in: context)
            #if DEBUG
            try beforeVisitBackingReadForTesting?()
            #endif
            var visitDescriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stayID != nil })
            visitDescriptor.propertiesToFetch = [\.stayID]
            visitBackedStayIDs = Set(try context.fetch(visitDescriptor).compactMap(\.stayID))
        } catch {
            context.rollback()
            logger.error("Failed to fetch rows for reconciliation: \(error.localizedDescription)")
            return false
        }

        // PHASE A — stage physical deletions. Phase B and these deletions
        // share the final save so neither can commit without the other.
        for row in deletedRows {
            context.delete(sorted[row].ping)
        }

        // PHASE B — reconcile memberships and affected trip summaries.
        var staysToDelete: [Stay] = []
        var affectedTrips:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        var staysReconciled = 0

        for (stay, originalIDs) in allStays {
            let survivingIDs = originalIDs.filter { !deletedPingIDs.contains($0) }
            guard survivingIDs.count != originalIDs.count else { continue }
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if affectedTrips[identity] == nil {
                    affectedTrips[identity] =
                        TripTitleStore.ParentSemanticSnapshot(
                            trip: trip,
                            semantic: TripTitleStore.semanticSnapshot(for: trip))
                }
            }
            stay.pingIDs = survivingIDs
            stay.pingCount = survivingIDs.count
            staysReconciled += 1
            if survivingIDs.isEmpty && !visitBackedStayIDs.contains(stay.id) {
                // Empty ping membership is valid when independent Visit evidence backs the logical stay.
                staysToDelete.append(stay)
            }
        }
        for stay in staysToDelete {
            // Detach BEFORE deleting so recomputeSummary cannot read removed stays from a stale inverse array.
            stay.trip = nil
            context.delete(stay)
        }

        for snapshot in affectedTrips.values {
            let trip = snapshot.trip
            if !trip.isDeleted {
                // Repair date boundaries as well as summaries: recomputeSummary never changes dates,
                // and assembly does not revisit completed trips; delete empty trips as in discard repair.
                // Filter pending-deleted rows before reading dates; invalidated model properties trap.
                // SwiftDataRelationshipContractTests pins this relationship rule.
                let remaining = trip.orderedStays.filter { !$0.isDeleted }
                guard let first = remaining.first, let last = remaining.last else {
                    context.delete(trip)
                    continue
                }
                trip.startDate = first.startTime
                if trip.isComplete, trip.endDate != nil {
                    trip.endDate = last.endTime
                }
                trip.recomputeSummary()
                if TripTitleStore.semanticSnapshot(for: trip)
                        != snapshot.semantic {
                    TripTitleStore.invalidateGeneratedTitles(
                        for: trip, in: context)
                }
            }
        }

        do {
            try context.save()
            logger.info("Deleted \(pingsToDelete.count) duplicate import ping(s); reconciled \(staysReconciled) stay(s) (\(staysToDelete.count) emptied + deleted), recomputed \(affectedTrips.count) trip(s).")
            return readoptCompleted
        } catch {
            context.rollback()
            logger.error("Dedup save failed: \(error.localizedDescription)")
            return false
        }
    }
}
