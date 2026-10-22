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
/// copies have no convergence-safe survivor ordering, and window dedup could collapse a short stay’s ping pair.
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
/// stay unless ALL its pings were duplicates. A photo and a Timeline or GPX
/// fix are never duplicates of each other: each is removed by a different
/// action, so keeping one for both would let a photo discard take the other. Identical UUID/timestamp
/// twins (independent restores of one backup) share one synced rank and are
/// all kept: persistent row identity orders them only within this store, so
/// two devices electing opposite survivors would together delete every copy.
///
/// **Two-phase execution.** The local import loop mutates
/// `Stay.pingIDsString` across gate units. Defer the WHOLE pass while a
/// photo or external-history import is active locally; the next launch or
/// remote notification retries against the intact rows. When idle:
///   - **Phase A** — select and delete duplicate physical ping rows.
///   - **Phase B** — remove only UUIDs with no retained physical copy from
///     stays and recompute affected trip summaries. A completed trip this
///     empties hands its choices to its counterpart in the same save;
///     duplicates whose removal would empty one with no counterpart are kept.
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
    /// Exclude jsonImport because its pings were inserted atomically with their stay.
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

    /// The deleted UUIDs to keep because removing them would empty a completed
    /// trip no carry can take over, after carrying the user data of every
    /// trip they may empty. An emptied completed trip needs one populated,
    /// completed counterpart this pass leaves untouched: the identical
    /// journey (`TripDeduplicator.winner`), or else the one trip holding
    /// every fix that deletes its own, which proves the journey too when two
    /// devices' graphs differ by a second and no identical one exists, as
    /// long as it is the same journey both ways: every stay of it holds only
    /// fixes that duplicate the emptied trip's, and its dates agree within
    /// the dedup window (a larger trip that merely contains the duplicates
    /// is a different journey and takes nothing). Its
    /// name, edit mark and hidden and pinned photos move there in this
    /// pass's save, so no choice waits out the ghost sweep's grace without a
    /// gallery, and the carry is logged so the sweep later removes the empty
    /// row (moving a Favorite with it) and late rows follow it. Counterparts
    /// are judged together: emptied trips with different names of their
    /// own, or a name the counterpart's differs from, would strand all but
    /// one, so the named ones keep their graphs. A trip with no counterpart,
    /// or one a populated row of its own id already owns, keeps every stay
    /// and ping (its duplicate graph stays as it was). A failed read throws.
    private static func retainedForCompletedTrips(
        memberships: [StayMembership],
        deletedPingIDs: Set<UUID>,
        keepersOf: [UUID: Set<UUID>],
        visitBackedStayIDs: Set<UUID>,
        in context: ModelContext,
        carried: inout [TripDeduplicator.CarriedFavourite]
    ) throws -> Set<UUID> {
        var touchedTrips: [ObjectIdentifier: Trip] = [:]
        var emptiedStays = Set<ObjectIdentifier>()
        var deletedByStay: [ObjectIdentifier: [UUID]] = [:]
        // The trip rows holding each ping; a ping two trips hold names none.
        var tripsByPing: [UUID: Set<ObjectIdentifier>] = [:]
        var tripRows: [ObjectIdentifier: Trip] = [:]
        var pingIDsByStay: [ObjectIdentifier: [UUID]] = [:]
        for (stay, ids) in memberships {
            pingIDsByStay[ObjectIdentifier(stay)] = ids
            if let trip = stay.trip, !trip.isDeleted {
                tripRows[ObjectIdentifier(trip)] = trip
                for id in ids { tripsByPing[id, default: []].insert(ObjectIdentifier(trip)) }
            }
            let deleted = ids.filter { deletedPingIDs.contains($0) }
            guard !deleted.isEmpty else { continue }
            deletedByStay[ObjectIdentifier(stay)] = deleted
            if let trip = stay.trip { touchedTrips[ObjectIdentifier(trip)] = trip }
            // Phase B's rule for a stay it deletes.
            if deleted.count == ids.count, !visitBackedStayIDs.contains(stay.id), !stay.userOverridden {
                emptiedStays.insert(ObjectIdentifier(stay))
            }
        }
        let emptied = touchedTrips.values.filter { trip in
            trip.isComplete && trip.orderedStays.allSatisfy {
                $0.isDeleted || emptiedStays.contains(ObjectIdentifier($0))
            }
        }
        guard !emptied.isEmpty else { return [] }

        let emptiedRows = Set(emptied.map { ObjectIdentifier($0) })
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let populated = trips.filter {
            !emptiedRows.contains(ObjectIdentifier($0)) && !($0.stays ?? []).isEmpty
        }
        let populatedIDs = Set(populated.map(\.id))
        // A counterpart this pass reshapes is judged again on the next pass.
        let untouched = populated.filter { touchedTrips[ObjectIdentifier($0)] == nil }
        let untouchedRows = Set(untouched.map { ObjectIdentifier($0) })

        func deletedIDs(of trip: Trip) -> [UUID] {
            trip.orderedStays.flatMap { deletedByStay[ObjectIdentifier($0)] ?? [] }
        }
        /// The one untouched completed trip holding every keeper of `trip`'s
        /// fixes, and nothing else: each of its stays holds only such keepers,
        /// and its dates agree with `trip`'s within the dedup window.
        func evidenceCounterpart(of trip: Trip) -> Trip? {
            var holders = Set<ObjectIdentifier>()
            var allKeepers = Set<UUID>()
            for id in deletedIDs(of: trip) {
                guard let keepers = keepersOf[id], !keepers.isEmpty else { return nil }
                for keeper in keepers {
                    guard let rows = tripsByPing[keeper], rows.count == 1 else { return nil }
                    holders.formUnion(rows)
                }
                allKeepers.formUnion(keepers)
            }
            guard holders.count == 1, let row = holders.first, untouchedRows.contains(row),
                  let counterpart = tripRows[row], counterpart.isComplete,
                  counterpart.id != trip.id else { return nil }
            // The reciprocal half: a stay of the counterpart with a fix (or
            // no fix at all) that duplicates none of `trip`'s is evidence of
            // a different journey.
            let reciprocal = counterpart.orderedStays.filter { !$0.isDeleted }.allSatisfy { stay in
                let ids = pingIDsByStay[ObjectIdentifier(stay)] ?? []
                return !ids.isEmpty && ids.allSatisfy(allKeepers.contains)
            }
            let window = ImportDedupPolicy.maxWindowSeconds
            guard reciprocal,
                  abs(counterpart.startDate.timeIntervalSince(trip.startDate)) <= window,
                  let counterpartEnd = counterpart.endDate, let end = trip.endDate,
                  abs(counterpartEnd.timeIntervalSince(end)) <= window else { return nil }
            return counterpart
        }
        func ownName(_ trip: Trip) -> String? {
            let name = (trip.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }

        var retained = Set<UUID>()
        var groups: [ObjectIdentifier: (counterpart: Trip, losers: [Trip])] = [:]
        for trip in emptied where !populatedIDs.contains(trip.id) {
            guard let counterpart = TripDeduplicator.winner(for: trip, among: untouched)
                    ?? evidenceCounterpart(of: trip) else {
                retained.formUnion(deletedIDs(of: trip))
                continue
            }
            groups[ObjectIdentifier(counterpart), default: (counterpart, [])].losers.append(trip)
        }
        for (counterpart, losers) in groups.values {
            let names = Set(losers.compactMap(ownName))
            for loser in losers {
                let compatible: Bool
                if let name = ownName(loser) {
                    compatible = ownName(counterpart).map { $0 == name } ?? (names.count == 1)
                } else {
                    compatible = true
                }
                guard compatible,
                      try TripDeduplicator.carryChoices(from: loser, to: counterpart, in: context) else {
                    retained.formUnion(deletedIDs(of: loser))
                    continue
                }
                carried.append(TripDeduplicator.CarriedFavourite(ghostID: loser.id, winnerID: counterpart.id))
            }
        }
        return retained
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

    /// The single-flight lease is container-scoped. Returns true only when
    /// the pass and its orphan sweep ran to completion; a deferral or a
    /// failure returns false so the caller can retry on a later trigger.
    #if DEBUG
    @TaskLocal static var beforeFetchForTesting: (@Sendable () async -> Void)?
    @TaskLocal static var beforeVisitBackingReadForTesting: (@Sendable () throws -> Void)?
    #endif

    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        await run(modelContainer: modelContainer, isolatedFixture: false, importActivity: nil, defaults: defaults)
    }

    #if DEBUG
    /// Testing entry point. `bypassSingleFlightForTesting` skips the
    /// container lease and the process-global importer activity probes for
    /// isolated fixture stores; `importActivityForTesting` overrides that
    /// activity to exercise deferral.
    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        bypassSingleFlightForTesting: Bool,
        importActivityForTesting: (photo: Bool, external: Bool)? = nil,
        defaults: UserDefaults = .standard
    ) async -> Bool {
        await run(modelContainer: modelContainer, isolatedFixture: bypassSingleFlightForTesting,
                  importActivity: importActivityForTesting, defaults: defaults)
    }
    #endif

    /// `isolatedFixture` and `importActivity` are set only by the DEBUG
    /// testing entry point above.
    private static func run(
        modelContainer: ModelContainer,
        isolatedFixture: Bool,
        importActivity: (photo: Bool, external: Bool)?,
        defaults: UserDefaults
    ) async -> Bool {
        if !isolatedFixture {
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
            if !isolatedFixture { _ = isRunning.withLock { $0.remove(ObjectIdentifier(modelContainer)) } }
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
        if isolatedFixture {
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
        if let importActivity {
            isImportActive = importActivity.photo
            isExternalImportActive = importActivity.external
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

        // Logical ordering converges across devices; physical identity only
        // fixes the local scan order of equal-rank twins, which the scan never
        // deletes from each other. Model getters
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
        // The row each deleted row was a duplicate of, which survives.
        var keeper = [Int?](repeating: nil, count: sorted.count)
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
                // Equal synced rank: no device can choose between them the
                // same way, so neither is a duplicate the other may delete.
                if other.timestamp == candidate.timestamp, other.ping.id == candidate.ping.id {
                    j += 1
                    continue
                }
                // Nor is a pair across removal domains: a Timeline or GPX fix
                // deleted for a photo's would go with Discard Imported Photos
                // (`ImportDedupPolicy.mayCollapse`, as insert time admits it).
                if !ImportDedupPolicy.mayCollapse(candidate.source, other.source) {
                    j += 1
                    continue
                }

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
                        keeper[j] = i
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

        // A completed trip these deletions would empty keeps its whole graph
        // unless one counterpart takes its user data (`retainedForCompletedTrips`).
        var keepersOf: [UUID: Set<UUID>] = [:]
        for row in deletedRows {
            if let kept = keeper[row] { keepersOf[sorted[row].ping.id, default: []].insert(sorted[kept].ping.id) }
        }
        let retainedIDs: Set<UUID>
        var carried: [TripDeduplicator.CarriedFavourite] = []
        do {
            retainedIDs = try retainedForCompletedTrips(
                memberships: allStays, deletedPingIDs: deletedPingIDs, keepersOf: keepersOf,
                visitBackedStayIDs: visitBackedStayIDs, in: context, carried: &carried)
        } catch {
            context.rollback()
            logger.error("Failed to read trips for reconciliation: \(error.localizedDescription)")
            return false
        }
        deletedPingIDs.subtract(retainedIDs)
        let stagedRows = deletedRows.filter { !retainedIDs.contains(sorted[$0].ping.id) }

        // PHASE A — stage physical deletions. Phase B and these deletions
        // share the final save so neither can commit without the other.
        for row in stagedRows {
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
            if survivingIDs.isEmpty && !visitBackedStayIDs.contains(stay.id) && !stay.userOverridden {
                // Empty ping membership is valid when independent Visit evidence backs the logical stay.
                // A user's correction outweighs the duplicate, as in the clusterer's displaced-host rule.
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
                // and assembly does not revisit completed trips; an emptied open trip goes, as in discard repair.
                // Filter pending-deleted rows before reading dates; invalidated model properties trap.
                // SwiftDataRelationshipContractTests pins this relationship rule.
                let remaining = trip.orderedStays.filter { !$0.isDeleted }
                guard let first = remaining.first, let last = remaining.last else {
                    // A completed trip stays as an empty row, dates and summary
                    // untouched. A favourite or photo choice can own it without
                    // a name or edit, and can still sync in from another device;
                    // its choices moved to its counterpart in this save, and only
                    // the ghost sweep, after its grace, rechecks favourites and
                    // removes it (`retainedForCompletedTrips`).
                    if !trip.isComplete { context.delete(trip) }
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

        // Logged before the save, so a favourite and late photo rows can
        // follow a carry whose sweep never runs; a failed save restores it.
        let loggedCarries = defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey)
        TripDeduplicator.logCarries(carried, defaults: defaults)
        do {
            try context.save()
            logger.info("Deleted \(stagedRows.count) duplicate import ping(s), kept \(deletedRows.count - stagedRows.count) for completed trips; reconciled \(staysReconciled) stay(s) (\(staysToDelete.count) emptied + deleted), recomputed \(affectedTrips.count) trip(s).")
            return readoptCompleted
        } catch {
            context.rollback()
            if !carried.isEmpty { defaults.set(loggedCarries, forKey: TripDeduplicator.carriedFavouritesKey) }
            logger.error("Dedup save failed: \(error.localizedDescription)")
            return false
        }
    }
}
