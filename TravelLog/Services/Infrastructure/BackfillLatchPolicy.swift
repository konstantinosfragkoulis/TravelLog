//
//  BackfillLatchPolicy.swift
//  TravelLog
//
//  A one-shot repair backfill must not latch its UserDefaults completion gate
//  after processing whatever rows the local store happens to hold: on a new
//  device or reinstall that is an EMPTY or partially-hydrated CloudKit store,
//  so rows syncing in later would never be repaired on that device (stale
//  isAirport stamps, nil administrativeArea, mixed-script localities…
//  permanently, until a dataset-version bump).
//
//  This policy centralizes the "may I latch?" decision. The pass itself
//  always RUNS (all passes are idempotent, so repairing the visible subset
//  early is free); only the permanent completion latch waits until the store
//  is plausibly fully hydrated.
//

import Foundation

/// Pure decision: may a one-shot backfill latch its completion gate now?
///
/// Signals (all cheap, no CoreData internals):
/// - Non-persistent container → never latch. An empty in-memory fallback must
///   not permanently suppress a repair against the preserved on-disk store.
/// - iCloud sync OFF → the local store cannot hydrate further; always latch.
/// - Empty table + iCloud ON → indistinguishable from pre-hydration; never
///   latch. A genuinely-empty new user re-runs a no-op pass per launch,
///   one empty fetch, microseconds.
/// - Non-empty table + iCloud ON → latch only when no import is running,
///   a CloudKit import completed before the pass started, no remote push
///   arrived after that import began, and no later import began without
///   succeeding.
///   A push-less partial hydration can still latch early; accepted
///   residual, bounded by the dataset-version re-arm mechanism.
nonisolated enum BackfillLatchPolicy {

    struct Context {
        /// False only for the emergency writable in-memory container.
        var isPersistentStore: Bool
        var iCloudSyncEnabled: Bool
        /// Rows in the table the pass repairs, counted in the same gate
        /// window the pass ran in.
        var processedRowCount: Int
        /// Last remote CloudKit push (nil = never).
        var lastRemoteImportAt: Date?
        /// End of the last successful CloudKit import (nil = never).
        var lastSuccessfulImportAt: Date?
        /// Start of that same import (nil = never, or stamped by an older build).
        var lastSuccessfulImportStartedAt: Date?
        /// A CloudKit import has started and not yet ended.
        var importInFlight: Bool
        /// Start of the latest import this process saw begin, whatever its
        /// outcome (nil = none yet).
        var lastImportStartedAt: Date?
        /// When the pass's worker started.
        var passStartedAt: Date
        var now: Date
    }

    static func mayLatch(_ context: Context) -> Bool {
        guard context.isPersistentStore else { return false }
        guard context.iCloudSyncEnabled else { return true }
        guard context.processedRowCount > 0 else { return false }
        guard !context.importInFlight else { return false }
        // A future import end or pass start (clock skew) defers the latch.
        guard let imported = context.lastSuccessfulImportAt,
              let importedStart = context.lastSuccessfulImportStartedAt,
              importedStart <= imported,
              imported <= context.passStartedAt,
              context.passStartedAt <= context.now else { return false }
        // A push during the import is not covered by it: another import follows.
        if let push = context.lastRemoteImportAt, push > importedStart { return false }
        // An import that began after the last success and did not succeed
        // (failed, or ended before its stamp landed) leaves the store partial.
        if let started = context.lastImportStartedAt, started > importedStart { return false }
        return true
    }
}
