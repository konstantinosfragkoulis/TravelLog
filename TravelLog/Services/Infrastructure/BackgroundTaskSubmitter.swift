//
//  BackgroundTaskSubmitter.swift
//  TravelLog
//

import BackgroundTasks

/// The slice of a `BGTask` the refresh and geocode-backfill drivers touch; tests substitute a recorder.
nonisolated protocol BackgroundRefreshTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundRefreshTaskHandle {}
extension BGProcessingTask: BackgroundRefreshTaskHandle {}

nonisolated enum BackgroundTaskSubmitter {
    /// Submits off the main thread: iOS 27's asynchronous API must not be called from the main thread; iOS 26 keeps the synchronous API.
    @concurrent static func submit(_ request: BGTaskRequest) async throws {
        if #available(iOS 27, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    /// Waits for a renewal submission with a bound: expiration handlers must complete promptly,
    /// so a slow scheduler cannot hold them while the renewal still gets a head start.
    /// A task group cannot enforce the bound: it awaits every child before returning, and a child
    /// awaiting `renewal.value` ignores cancellation. Two unstructured waiters race instead;
    /// the renewal waiter simply ends whenever the submission does.
    static func awaitRenewal(_ renewal: Task<Void, Never>, seconds: Double) async {
        let first = AsyncStream<Void>.makeStream()
        Task {
            await renewal.value
            first.continuation.yield()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            first.continuation.yield()
        }
        for await _ in first.stream { break }
        timeout.cancel()
    }
}
