//
//  BackgroundTaskCompletion.swift
//  TravelLog
//

import os

/// Arbitrates terminal completion across the task's natural and expiration paths.
/// Cancellation, renewal and the system completion call stay with each driver.
nonisolated final class BackgroundTaskCompletion: Sendable {
    private struct State: Sendable {
        var completed = false
        var expired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isExpired: Bool { state.withLock { $0.expired } }

    /// Must be called synchronously before cancelling the underlying work.
    func markExpired() {
        state.withLock { $0.expired = true }
    }

    /// Returns the winning completion's success, or nil if another path won.
    /// Expiration and the terminal claim share a lock so a completed pipeline
    /// waiting on renewal cannot report success after expiration was recorded.
    func claim(ranToEnd: Bool) -> Bool? {
        state.withLock { value in
            guard !value.completed else { return nil }
            value.completed = true
            return ranToEnd && !value.expired
        }
    }
}
