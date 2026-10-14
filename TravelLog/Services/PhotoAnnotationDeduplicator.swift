//
//  PhotoAnnotationDeduplicator.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 13/5/26.
//

import Foundation
import SwiftData
import os.log

/// Removes duplicate `HiddenPhoto` and `PinnedPhoto` records that accumulate
/// from multi-device CloudKit sync.
///
/// When two devices independently hide or pin the same photo at roughly the
/// same time, both create their own record. After CloudKit sync, both records
/// coexist in the store. The read paths in `PhotoService` use a `Set<String>`
/// so duplicates don't affect user-facing behavior, but the rows pile up
/// forever and slow CloudKit sync. This service finds duplicates by
/// `(tripID, cloudIdentifier ?? localIdentifier)` and keeps the oldest,
/// retaining physical twins whose timestamp and UUID are indistinguishable.
///
/// Mirrors `HexVisitDeduplicator` in structure (reentrancy lock, detached
/// context, run on launch + remote notification). Differs in that
/// photo-annotation records have no fields to merge — we keep the oldest by
/// timestamp and UUID, deleting only strictly lower-ranked rows.
/// `nonisolated` so the full-table dedup fetches really run off the main actor.
nonisolated enum PhotoAnnotationDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "PhotoAnnotationDeduplicator"
    )

    /// Single flight per container: passes over unrelated stores never skip each other.
    private static let isRunning = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())
    private static let isSweepingOrphans = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    /// What one orphan sweep did.
    nonisolated struct OrphanSweepOutcome: Sendable, Equatable {
        /// False when the sweep did not run to its end (single-flight, fetch
        /// or save); nothing it staged was kept.
        var completed = false
        /// Trips that received rows keyed to a deleted, carried ghost. Their
        /// cached galleries are stale once the sweep has saved.
        var rekeyedOnto: Set<UUID> = []
        var deleted = 0
    }

    #if DEBUG
    nonisolated enum OrphanSweepFault: Sendable {
        case hiddenRead, pinnedRead, save
    }
    @TaskLocal static var orphanSweepFaultForTesting: OrphanSweepFault?
    #endif

    /// How long a row must remain a *locally-observed* orphan before the
    /// sweep deletes it. Measured from when THIS device first saw the row
    /// without a matching Trip — NOT from the user's original hide/pin time
    /// — so historical rows that sync onto a new / restored device get a
    /// full window during which their Trips can arrive. 24 h comfortably
    /// exceeds even a large-library initial CloudKit import while still
    /// reclaiming genuine-orphan storage within a day. See
    /// `firstObservedOrphansKey`.
    private static let orphanGracePeriod: TimeInterval = 24 * 60 * 60

    /// UserDefaults key for the device-local map `[rowID.uuidString:
    /// firstObservedEpochSeconds]` recording when this device first saw each
    /// annotation row as an orphan. Deliberately NOT CloudKit-synced: it must
    /// reflect *local arrival*, so each device ages orphans from its own first
    /// sighting rather than the user's (synced) original action time.
    static let firstObservedOrphansKey = "orphanFirstObserved_v1"

    /// One trip's photo choices of one kind, under the identity the dedup
    /// keys on: a row is redundant when its cloud-first stable ID is already
    /// held, or when it is local-only and that local asset is already held.
    /// The trip merge copy and the backup restore admit rows through it.
    nonisolated struct ChoiceIdentities {
        private var stableIDs = Set<String>()
        private var localIdentifiers = Set<String>()

        /// Records a row the trip already holds.
        mutating func hold(localIdentifier: String, cloudIdentifier: String?) {
            stableIDs.insert(cloudIdentifier ?? localIdentifier)
            if !localIdentifier.isEmpty { localIdentifiers.insert(localIdentifier) }
        }

        /// True, and held from now on, when the row adds a choice the trip
        /// does not hold yet.
        mutating func admit(localIdentifier: String, cloudIdentifier: String?) -> Bool {
            if cloudIdentifier == nil, localIdentifiers.contains(localIdentifier) { return false }
            guard stableIDs.insert(cloudIdentifier ?? localIdentifier).inserted else { return false }
            if !localIdentifier.isEmpty { localIdentifiers.insert(localIdentifier) }
            return true
        }
    }

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let containerID = ObjectIdentifier(modelContainer)
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running.contains(containerID) { return true }
            running.insert(containerID)
            return false
        }
        guard !alreadyRunning else {
            logger.debug("Deduplication already in progress, skipping.")
            return false
        }
        defer { _ = isRunning.withLock { $0.remove(containerID) } }

        let context = ModelContext(modelContainer)

        let hiddenResult = dedupHidden(in: context)
        let pinnedResult = dedupPinned(in: context)
        let readsSucceeded = hiddenResult != nil && pinnedResult != nil
        let hiddenDeleted = hiddenResult ?? 0
        let pinnedDeleted = pinnedResult ?? 0

        let total = hiddenDeleted + pinnedDeleted
        guard total > 0 else { return readsSucceeded }

        do {
            try context.save()
            logger.info("Removed \(total) duplicate photo-annotation record(s): \(hiddenDeleted) hidden + \(pinnedDeleted) pinned.")
            return readsSucceeded
        } catch {
            logger.error("Failed to save photo-annotation dedup: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete `HiddenPhoto` / `PinnedPhoto` rows whose `tripID` no longer
    /// matches any existing `Trip`. Handles the case where a Trip was
    /// deleted on another device and synced to this device — SwiftData
    /// can't cascade because there is no inverse relationship (intentional
    /// for CloudKit compatibility), so orphan annotation rows would
    /// otherwise accumulate forever in storage and CloudKit.
    ///
    /// Conservative by design in three layers:
    ///  1. **Device-local first-observed grace** — a row is deleted only once
    ///     it has been an orphan *on this device* for `orphanGracePeriod`,
    ///     timed from the first sweep that saw it without its Trip (persisted
    ///     in `firstObservedOrphansKey`), NOT from the user's original
    ///     hide/pin time. With iCloud on, a successful CloudKit import must
    ///     also have completed past that grace. On a new /
    ///     restored device, historical rows sync in carrying months-old
    ///     timestamps and would otherwise be deleted instantly — before their
    ///     Trips finish the initial CloudKit import — wiping the user's
    ///     hide/pin choices on every device.
    ///  2. **Empty-store / mid-sync guard** — if the store reports zero Trips
    ///     yet holds annotation rows, we cannot distinguish "user deleted all
    ///     trips" from "initial import hasn't delivered the Trips yet", so we
    ///     skip entirely.
    ///  3. **Explicit fetch error handling** — a Trip fetch *failure* is never
    ///     read as "no trips exist", so a transient
    ///     error can't turn every row into an orphan. Both
    ///     annotation reads must succeed too before anything changes.
    ///
    /// A row keyed to a ghost `TripDeduplicator` deleted and carried onto a
    /// winner is not an orphan: it synced in from a device that still had the
    /// ghost after the carry's snapshot, so it follows the carry log to the
    /// chain's existing winner at once. A logged ghost whose chain ends at a
    /// missing trip ages like any other orphan.
    /// Queued, unspent Removed Trips still own their rows: late choices rescue
    /// an ordinary dissolved trip, or wait for a split's explicit Keep. An
    /// unreadable queue is never treated as proof those owners are gone.
    @discardableResult
    static func removeOrphans(modelContainer: ModelContainer) async -> Bool {
        await sweepOrphans(modelContainer: modelContainer).completed
    }

    /// Test seam: injectable clock + defaults so the two-pass first-observed
    /// grace can be driven deterministically without touching the shared
    /// `UserDefaults.standard`. False when the sweep did not run to its end.
    @discardableResult
    static func removeOrphans(
        modelContainer: ModelContainer,
        now: Date,
        defaults: UserDefaults
    ) async -> Bool {
        await sweepOrphans(modelContainer: modelContainer, now: now, defaults: defaults).completed
    }

    /// The orphan sweep, reporting the trips whose rows it re-keyed so the
    /// caller can refresh their galleries after the gate unit.
    static func sweepOrphans(
        modelContainer: ModelContainer,
        now: Date = .now,
        defaults: UserDefaults = .standard,
        queueDirectory: URL? = nil
    ) async -> OrphanSweepOutcome {
        let containerID = ObjectIdentifier(modelContainer)
        let alreadyRunning = isSweepingOrphans.withLock { running -> Bool in
            if running.contains(containerID) { return true }
            running.insert(containerID)
            return false
        }
        guard !alreadyRunning else {
            logger.debug("Orphan sweep already in progress, skipping.")
            return OrphanSweepOutcome()
        }
        defer { _ = isSweepingOrphans.withLock { $0.remove(containerID) } }

        let context = ModelContext(modelContainer)

        // Layer 3: fetch Trips EXPLICITLY. A fetch failure must never be read
        // as "no trips exist" — an empty `knownTripIDs` would mark every
        // annotation an orphan. Bail on error; the next sweep retries.
        let trips: [Trip]
        do {
            trips = try context.fetch(FetchDescriptor<Trip>())
        } catch {
            logger.error("Orphan sweep: Trip fetch failed (\(error.localizedDescription)); skipping to avoid mass-deleting annotations.")
            return OrphanSweepOutcome()
        }
        let knownTripIDs = Set(trips.map(\.id))

        // A failed read is not absence: an unread table would drop its rows'
        // observations and leave the pass half done.
        let allHidden: [HiddenPhoto]
        let allPinned: [PinnedPhoto]
        do {
            #if DEBUG
            if orphanSweepFaultForTesting == .hiddenRead { throw CocoaError(.fileReadUnknown) }
            #endif
            allHidden = try context.fetch(FetchDescriptor<HiddenPhoto>())
            #if DEBUG
            if orphanSweepFaultForTesting == .pinnedRead { throw CocoaError(.fileReadUnknown) }
            #endif
            allPinned = try context.fetch(FetchDescriptor<PinnedPhoto>())
        } catch {
            logger.error("Orphan sweep: annotation fetch failed (\(error.localizedDescription)); skipping.")
            return OrphanSweepOutcome()
        }

        // Layer 2: zero Trips but annotation rows present ⇒ treat as mid-sync
        // (or a fetch that returned nothing) and skip, rather than wipe the
        // user's hide/pin history on a fresh restore.
        if knownTripIDs.isEmpty && !(allHidden.isEmpty && allPinned.isEmpty) {
            logger.info("Orphan sweep: store reports 0 Trips but has annotation rows — treating as mid-sync, skipping.")
            return OrphanSweepOutcome()
        }

        // Split archives (prepared or committed) keep the retired original's
        // choices until Keep/Forget; ordinary archives need late rows for rescue.
        // A Keep whose commit was recorded has spent its archive. Read before
        // any carry, deletion or observation update so failure changes nothing.
        let protectedTripIDs: Set<UUID>
        do {
            protectedTripIDs = Set(try DissolvedTripQueue.loadThrowing(from: queueDirectory)
                .filter { $0.keepCommitted != true }.map(\.id))
        } catch {
            logger.error("Orphan sweep: Removed Trips queue unreadable (\(error.localizedDescription)); skipping.")
            return OrphanSweepOutcome()
        }

        // Rows keyed to a deleted, carried ghost follow the carry log. Only
        // UUIDs without a row reach it, and `knownTripIDs` holds every row.
        let winnerByGhost = TripDeduplicator.carriedWinners(defaults: defaults)
        func carryTarget(_ tripID: UUID) -> UUID? {
            guard !winnerByGhost.isEmpty else { return nil }
            return TripDeduplicator.terminalWinner(
                for: tripID, winnerByGhost: winnerByGhost, existing: knownTripIDs)
        }

        // Layer 1: age orphans from this device's first sighting.
        let firstObserved = (defaults.dictionary(forKey: firstObservedOrphansKey) as? [String: Double]) ?? [:]
        let nowEpoch = now.timeIntervalSince1970
        // With iCloud on, a row matures only once a successful import has
        // completed past its grace, not on wall-clock age alone.
        let syncOn = defaults.bool(forKey: AppDelegate.iCloudSyncEnabledKey)
        let lastImport = (defaults.object(forKey: AppDelegate.lastSuccessfulCloudImportAtKey) as? Date)?
            .timeIntervalSince1970
        var nextObserved: [String: Double] = [:]
        var outcome = OrphanSweepOutcome()
        var rekeyed = 0

        for row in allHidden where !knownTripIDs.contains(row.tripID) && !protectedTripIDs.contains(row.tripID) {
            if let winner = carryTarget(row.tripID) {
                row.tripID = winner
                outcome.rekeyedOnto.insert(winner)
                rekeyed += 1
                continue
            }
            let key = row.id.uuidString
            let firstSeen = firstObserved[key] ?? nowEpoch
            if nowEpoch - firstSeen >= orphanGracePeriod,
               !syncOn || (lastImport ?? -.infinity) >= firstSeen + orphanGracePeriod {
                context.delete(row)
                outcome.deleted += 1
            } else {
                nextObserved[key] = firstSeen
            }
        }
        for row in allPinned where !knownTripIDs.contains(row.tripID) && !protectedTripIDs.contains(row.tripID) {
            if let winner = carryTarget(row.tripID) {
                row.tripID = winner
                outcome.rekeyedOnto.insert(winner)
                rekeyed += 1
                continue
            }
            let key = row.id.uuidString
            let firstSeen = firstObserved[key] ?? nowEpoch
            if nowEpoch - firstSeen >= orphanGracePeriod,
               !syncOn || (lastImport ?? -.infinity) >= firstSeen + orphanGracePeriod {
                context.delete(row)
                outcome.deleted += 1
            } else {
                nextObserved[key] = firstSeen
            }
        }

        // Persist the pruned map: only currently-orphaned, not-yet-deleted
        // rows survive, so entries for rows whose Trip has since arrived (or
        // that were just deleted or re-keyed) drop out — bounding the map to
        // live orphans. Written even when nothing changed, so the first sweep
        // records its observations; after a store change, only once it saved,
        // so a failed save keeps the prior observations.
        func persistObservations() {
            if nextObserved.isEmpty {
                defaults.removeObject(forKey: firstObservedOrphansKey)
            } else {
                defaults.set(nextObserved, forKey: firstObservedOrphansKey)
            }
        }

        guard outcome.deleted + rekeyed > 0 else {
            persistObservations()
            outcome.completed = true
            return outcome
        }
        do {
            #if DEBUG
            if orphanSweepFaultForTesting == .save { throw CocoaError(.fileWriteUnknown) }
            #endif
            try context.save()
        } catch {
            logger.error("Failed to save orphan sweep: \(error.localizedDescription)")
            return OrphanSweepOutcome()
        }
        persistObservations()
        logger.info("Orphan sweep: removed \(outcome.deleted) orphan photo-annotation row(s), moved \(rekeyed) onto carry winners.")
        outcome.completed = true
        return outcome
    }

    // MARK: - Per-model

    /// Nil when the fetch failed.
    private static func dedupHidden(in context: ModelContext) -> Int? {
        guard let all = try? context.fetch(FetchDescriptor<HiddenPhoto>()) else { return nil }
        guard all.count > 1 else { return 0 }

        // Sort in-memory: SortDescriptor cannot use UUID as the secondary key
        // (Foundation's UUID is Hashable, not Comparable), and we need a
        // deterministic tiebreaker so two devices arrive at the same "keep"
        // choice — otherwise device A could delete record1 while device B
        // deletes record2 and both devices converge to zero rows. Row count
        // here is bounded by user-issued hides, so O(N log N) is free.
        let sorted = all.sorted { a, b in
            if a.hiddenAt != b.hiddenAt { return a.hiddenAt < b.hiddenAt }
            return a.id.uuidString < b.id.uuidString
        }

        var survivorByKey: [String: HiddenPhoto] = [:]
        var deleted = 0
        for record in sorted {
            // Key on the device-stable cloud ID when available — that's what
            // makes two devices' rows for the same iCloud photo collide.
            // Fall back to localIdentifier for legacy V6 rows or device-only
            // photos (where cross-device collisions can't happen anyway).
            let stableID = record.cloudIdentifier ?? record.localIdentifier
            let key = "\(record.tripID.uuidString)|\(stableID)"
            if let survivor = survivorByKey[key] {
                // Equal synced rank cannot identify a physical winner. Opposite
                // fetch orders must not make replicas delete each other's twins.
                guard record.hiddenAt != survivor.hiddenAt
                        || record.id != survivor.id else { continue }
                context.delete(record)
                deleted += 1
            } else {
                survivorByKey[key] = record
            }
        }
        return deleted
    }

    /// Nil when the fetch failed.
    private static func dedupPinned(in context: ModelContext) -> Int? {
        guard let all = try? context.fetch(FetchDescriptor<PinnedPhoto>()) else { return nil }
        guard all.count > 1 else { return 0 }

        // Same deterministic-tiebreaker rationale as `dedupHidden` — see
        // its body comment.
        let sorted = all.sorted { a, b in
            if a.pinnedAt != b.pinnedAt { return a.pinnedAt < b.pinnedAt }
            return a.id.uuidString < b.id.uuidString
        }

        var survivorByKey: [String: PinnedPhoto] = [:]
        var deleted = 0
        for record in sorted {
            let stableID = record.cloudIdentifier ?? record.localIdentifier
            let key = "\(record.tripID.uuidString)|\(stableID)"
            if let survivor = survivorByKey[key] {
                // Preserve the same rank-minimal physical twins as hidden rows.
                guard record.pinnedAt != survivor.pinnedAt
                        || record.id != survivor.id else { continue }
                context.delete(record)
                deleted += 1
            } else {
                survivorByKey[key] = record
            }
        }
        return deleted
    }
}
