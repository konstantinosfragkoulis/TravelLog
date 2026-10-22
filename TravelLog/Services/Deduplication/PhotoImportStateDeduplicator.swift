//
//  PhotoImportStateDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// Collapses duplicate `PhotoImportState` rows that accumulate from
/// CloudKit sync when two devices start an import within the same
/// propagation window.
///
/// `PhotoImportState` is semantically a singleton — one logical "current
/// import" per user — but CloudKit has no unique-constraint enforcement
/// (same reason `LocationPing`, `Stay`, `Trip` etc. don't have
/// `@Attribute(.unique)`). So when device A
/// inserts a state row at T1 and device B inserts one at T2 < T1
/// + propagation, both rows survive the sync. The Settings UI on each
/// device then has to pick "the" state row to display, with no
/// deterministic answer until we converge.
///
/// Reentrancy via `OSAllocatedUnfairLock` — same pattern as
/// `HexVisitDeduplicator` / `PhotoAnnotationDeduplicator`. Both AppDelegate
/// launch and CloudKit remote-notification handlers call into this,
/// sometimes concurrently; the lock permits one pass per container. Independent
/// fixture stores cannot suppress each other's maintenance.
/// `nonisolated` so the full-table dedup fetches really run off the main actor.
nonisolated enum PhotoImportStateDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "PhotoImportStateDeduplicator"
    )

    private static let isRunning = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    #if DEBUG
    @TaskLocal static var beforeFetchForTesting: (@Sendable () async -> Void)?
    #endif

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running.contains(ObjectIdentifier(modelContainer)) { return true }
            running.insert(ObjectIdentifier(modelContainer))
            return false
        }
        guard !alreadyRunning else {
            logger.debug("PhotoImportState dedup already in progress, skipping.")
            return false
        }
        defer { _ = isRunning.withLock { $0.remove(ObjectIdentifier(modelContainer)) } }

        #if DEBUG
        if let beforeFetchForTesting { await beforeFetchForTesting() }
        #endif

        let context = ModelContext(modelContainer)

        guard let all = try? context.fetch(FetchDescriptor<PhotoImportState>()) else { return false }
        guard all.count > 1 else { return true }

        // Survivor keyed on the immutable `id`:
        // `startedAt` is MUTABLE — `PhotoImportService` re-stamps it to
        // `.now` on every import (re)start — so two devices sorting on it
        // mid-restart could pick different survivors and delete each
        // other's row (the delete-war shape). The immutable UUID selects the
        // logical survivor, and every physical twin of it stays: the
        // store-local physical-ID tiebreak that checkpoint and lifecycle reads
        // use is no cross-device key, and two devices electing opposite twins
        // would together delete every copy.
        // Every survivor keeps its writer generation, including while paused:
        // the durable local journal, checkpoint commits and lifecycle writes
        // use startedAt as session identity to reject prior invocations.
        // Progress fields stay the survivor's own — the import pipeline is
        // idempotent (watermark re-walks dedup via `isDuplicatePing`), so a
        // conservative watermark only costs re-checked work, never data.
        guard let survivor = PhotoImportStateSnapshot.selectState(from: all) else { return true }
        var deleted = 0
        for row in all where !row.isDeleted && row.id != survivor.id {
            context.delete(row)
            deleted += 1
        }

        guard deleted > 0 else { return true }
        do {
            try context.save()
            logger.info("Removed \(deleted) duplicate PhotoImportState row(s); kept the smallest id and its twins, preserved writer generation.")
            return true
        } catch {
            logger.error("Failed to save PhotoImportState dedup: \(error.localizedDescription)")
            return false
        }
    }
}
