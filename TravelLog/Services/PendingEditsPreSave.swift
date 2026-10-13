//
//  PendingEditsPreSave.swift
//  TravelLog
//
//  Rollback is context-wide. A worker that rolls back on failure calls this
//  first so an earlier, unrelated pending edit on the same context is
//  committed rather than discarded with the worker's own changes.
//

import Foundation
import SwiftData
import os.log

nonisolated private let pendingEditsLogger = Logger(subsystem: "com.travellog.app", category: "PendingEdits")

/// Commits whatever the context already holds. Returns false when that
/// commit fails; the caller then reports failure without rolling back, so
/// the pending edit stays pending instead of vanishing.
nonisolated func preserveUnrelatedPendingEdits(in modelContext: ModelContext) -> Bool {
    guard modelContext.hasChanges else { return true }
    do {
        try modelContext.save()
        return true
    } catch {
        pendingEditsLogger.error("Pre-save of pending edits failed: \(error.localizedDescription)")
        return false
    }
}
