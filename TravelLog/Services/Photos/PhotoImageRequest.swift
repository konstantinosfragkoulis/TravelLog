import Photos
import UIKit
import os

/// Owns one share-image request until its first result or caller cancellation.
@MainActor
enum PhotoImageRequest {
    static func load(
        request: (@escaping @Sendable (UIImage?) -> Void) -> PHImageRequestID,
        cancel: @escaping @MainActor @Sendable (PHImageRequestID) -> Void
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                let id = request { image in state.complete(image) }
                if state.install(requestID: id) {
                    // Cancellation won while requestImage was returning its ID.
                    cancel(id)
                }
            }
        } onCancel: {
            let (continuation, id) = state.cancel()
            continuation?.resume(returning: nil)
            if let id {
                Task { @MainActor in cancel(id) }
            }
        }
    }

    // Only ownership metadata is shared between PhotoKit's callback, the
    // caller's cancellation handler and MainActor request installation.
    nonisolated final class State: Sendable {
        private nonisolated struct Storage {
            var continuation: CheckedContinuation<UIImage?, Never>?
            var requestID: PHImageRequestID?
            var finished = false
            var cancelled = false
        }
        private let storage = OSAllocatedUnfairLock(initialState: Storage())

        func install(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
            storage.withLock { state in
                guard !state.finished else { return false }
                state.continuation = continuation
                return true
            }
        }

        /// True means a late ID belongs to an already-cancelled request.
        func install(requestID: PHImageRequestID) -> Bool {
            storage.withLock { state in
                if state.cancelled { return true }
                if !state.finished { state.requestID = requestID }
                return false
            }
        }

        func complete(_ image: UIImage?) {
            let continuation = storage.withLock { state in
                guard !state.finished else {
                    return Optional<CheckedContinuation<UIImage?, Never>>.none
                }
                state.finished = true
                state.requestID = nil
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(returning: image)
        }

        func cancel() -> (CheckedContinuation<UIImage?, Never>?, PHImageRequestID?) {
            storage.withLock { state in
                guard !state.finished else { return (nil, nil) }
                state.finished = true
                state.cancelled = true
                let result = (state.continuation, state.requestID)
                state.continuation = nil
                state.requestID = nil
                return result
            }
        }
    }
}
