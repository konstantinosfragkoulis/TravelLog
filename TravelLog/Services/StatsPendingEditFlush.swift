import Foundation
import SwiftData
import os.log

/// The main-context fallback used before Stats reads committed state. The
/// caller owns PipelineGate; `flush(_:publishing:)` publishes a success
/// before returning.
@MainActor
enum StatsPendingEditFlush {
    enum Outcome: Sendable { case saved, failed, cancelled }

    /// Flush, then publish a success once. A clean context also publishes:
    /// the caller observed pending edits before its gate unit was admitted,
    /// and an autosave in between committed them without any store-change
    /// bump, so this publication is still owed to every other reader.
    static func flush(_ context: ModelContext, publishing publish: (StoreChange) -> Void) -> Outcome {
        let outcome = flush(context)
        if outcome == .saved { publish(.all) }
        return outcome
    }

    static func flush(_ context: ModelContext) -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        do {
            if context.hasChanges {
                #if DEBUG
                try saveFailure?()
                #endif
                try context.save()
            }
            return .saved
        } catch {
            Logger(subsystem: "com.travellog.app", category: "StatsView")
                .error("Pending Stats edit save failed; reading committed data: \(error.localizedDescription)")
            return .failed
        }
    }

    #if DEBUG
    @TaskLocal private static var saveFailure: (@MainActor () throws -> Void)?

    static func flushForTesting(
        _ context: ModelContext, beforeSave: @escaping @MainActor () throws -> Void
    ) -> Outcome {
        $saveFailure.withValue(beforeSave) { flush(context) }
    }

    static func flushForTesting(
        _ context: ModelContext,
        publishing publish: (StoreChange) -> Void,
        beforeSave: @escaping @MainActor () throws -> Void
    ) -> Outcome {
        $saveFailure.withValue(beforeSave) { flush(context, publishing: publish) }
    }
    #endif
}
