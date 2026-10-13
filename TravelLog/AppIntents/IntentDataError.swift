//
//  IntentDataError.swift
//  TravelLog
//
//  The one failure the read-only Siri and Shortcuts intents report when they
//  cannot read the journal. A failed required read, or the empty in-memory
//  fallback store, is not "no travel", so an intent throws
//  this instead of speaking an empty answer.
//

import AppIntents
import Foundation
import os.log

nonisolated enum IntentDataError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(
            "app-intent.data-unavailable",
            defaultValue: "Travel Log couldn't read your travel data. Try again in a moment.",
            comment: "Siri and Shortcuts response when the travel journal could not be read, so no answer is given."
        )
    }

    private static let logger = Logger(subsystem: "com.travellog.app", category: "AppIntents")

    /// The in-memory fallback store opens empty after a failed migration or an
    /// unreadable store; RootView shows StorageUnavailableView for it. Capture
    /// `AppDelegate.modelContainer` before reading the mode: its initializer
    /// records the mode.
    static func requirePersistentStore(_ isPersistentStore: Bool) throws {
        guard isPersistentStore else {
            logger.error("Intent refused: the journal store is the in-memory fallback.")
            throw IntentDataError.unavailable
        }
    }

    /// Runs `body` and turns any storage error into `.unavailable`.
    static func reading<T>(_ intent: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw mapped(error, intent: intent)
        }
    }

    /// Logs a storage error and replaces it with `.unavailable`.
    /// Cancellation stays cancellation.
    static func mapped(_ error: any Error, intent: String) -> any Error {
        if error is CancellationError || error is IntentDataError { return error }
        logger.error("\(intent, privacy: .public) read failed: \(error.localizedDescription, privacy: .private)")
        return IntentDataError.unavailable
    }

    /// Refuses the in-memory fallback, then runs `read` on a detached worker
    /// so an intent never reduces rows on the main thread. Caller
    /// cancellation reaches the worker; only a complete value returns.
    static func detachedRead<Value: Sendable>(
        _ intent: String,
        isPersistentStore: Bool,
        _ read: @escaping @Sendable (_ checkCancellation: () throws -> Void) throws -> Value
    ) async throws -> Value {
        try requirePersistentStore(isPersistentStore)
        try Task.checkCancellation()
        #if DEBUG
        let readFailure = IntentRead.failureForTesting
        #endif
        let worker = Task.detached(priority: .userInitiated) { () throws -> Value in
            let checkCancellation: () throws -> Void = { try Task.checkCancellation() }
            #if DEBUG
            return try IntentRead.$failureForTesting.withValue(readFailure) {
                try IntentDataError.reading(intent) { try read(checkCancellation) }
            }
            #else
            return try IntentDataError.reading(intent) { try read(checkCancellation) }
            #endif
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Required intent reads, so tests can fail one by name.
nonisolated enum IntentRead: Sendable, Equatable {
    case dayStays, tripEntities, searchTrips, searchFallbackTrips

    #if DEBUG
    /// `IntentDataError.detachedRead` re-installs it on its detached worker.
    @TaskLocal static var failureForTesting: (@Sendable (IntentRead) throws -> Void)?
    #endif

    /// Test checkpoint immediately before a required read; a no-op in release.
    static func check(_ read: IntentRead) throws {
        #if DEBUG
        try failureForTesting?(read)
        #endif
    }
}
