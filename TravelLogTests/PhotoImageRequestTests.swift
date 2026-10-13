import Photos
import UIKit
import Testing
@testable import TravelLog

@MainActor
@Suite("Share image request ownership", .timeLimit(.minutes(1)))
struct PhotoImageRequestTests {
    @Test("an already-cancelled caller starts no native request")
    func alreadyCancelled() async {
        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await PhotoImageRequest.load { _ in
                Issue.record("Cancelled caller started an image request")
                return 1
            } cancel: { _ in
                Issue.record("No native request should exist")
            }
        }.value
        #expect(result == nil)
    }

    @Test("active cancellation releases the waiter without a PhotoKit callback")
    func activeCancellation() async {
        let provider = Provider()
        let task = Task {
            await PhotoImageRequest.load(request: provider.request, cancel: { @MainActor @Sendable id in provider.cancel(id) })
        }
        var starts = provider.starts.stream.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()
        #expect(await task.value == nil)
        var cancellations = provider.cancellations.stream.makeAsyncIterator()
        #expect(await cancellations.next() == 41)
        #expect(provider.cancelledIDs == [41])
        // PhotoKit may still deliver a result after cancelImageRequest.
        let callback = provider.completion
        let lateImage = UIImage()
        await Task.detached { callback?(lateImage) }.value
        task.cancel()
        #expect(provider.cancelledIDs == [41])
    }

    @Test("an asynchronous PhotoKit callback returns the requested image")
    func asynchronousCompletion() async {
        let provider = Provider()
        let task = Task {
            await PhotoImageRequest.load(request: provider.request, cancel: { @MainActor @Sendable id in provider.cancel(id) })
        }
        var starts = provider.starts.stream.makeAsyncIterator()
        _ = await starts.next()
        let image = UIImage()
        let callback = provider.completion
        await Task.detached { callback?(image) }.value
        #expect(await task.value === image)
        #expect(provider.cancelledIDs.isEmpty)
    }

    @Test("a synchronous result wins before ID installation and ignores duplicate results")
    func synchronousCompletion() async {
        let image = UIImage()
        var cancellations: [PHImageRequestID] = []
        let result = await Task { @MainActor in
            await PhotoImageRequest.load { completion in
                completion(image)
                completion(nil)
                // Completion won; cancellation must not cancel its late ID.
                withUnsafeCurrentTask { $0?.cancel() }
                return 42
            } cancel: { cancellations.append($0) }
        }.value
        #expect(result === image)
        #expect(cancellations.isEmpty)
    }

    @Test("a nil or failed PhotoKit result completes once")
    func nilResult() async {
        let result = await PhotoImageRequest.load { completion in
            completion(nil)
            completion(UIImage())
            return 43
        } cancel: { _ in Issue.record("Completed request was cancelled") }
        #expect(result == nil)
    }

    @Test("cancellation during native request start cancels its late ID")
    func cancellationBeforeID() async {
        let provider = Provider()
        let result = await Task { @MainActor in
            await PhotoImageRequest.load { completion in
                provider.completion = completion
                withUnsafeCurrentTask { $0?.cancel() }
                completion(UIImage())
                return 44
            } cancel: { id in
                provider.cancel(id)
                // A manager may invoke its result handler synchronously on cancel.
                provider.completion?(nil)
            }
        }.value
        #expect(result == nil)
        #expect(provider.cancelledIDs == [44])
    }

    @Test("cancellation before continuation installation leaves no waiter")
    func cancellationBeforeContinuation() async {
        // This ordering sits inside withTaskCancellationHandler's entry race;
        // exercise the same state object without a scheduler-dependent delay.
        let state = PhotoImageRequest.State()
        let (continuation, id) = state.cancel()
        #expect(continuation == nil)
        #expect(id == nil)
        let result: UIImage? = await withCheckedContinuation { continuation in
            #expect(!state.install(continuation))
            continuation.resume(returning: nil)
        }
        #expect(result == nil)
        #expect(state.install(requestID: 45))
        state.complete(UIImage())
        let repeated = state.cancel()
        #expect(repeated.0 == nil && repeated.1 == nil)
    }

    private final class Provider {
        var completion: (@Sendable (UIImage?) -> Void)?
        var cancelledIDs: [PHImageRequestID] = []
        let starts = AsyncStream<PHImageRequestID>.makeStream()
        let cancellations = AsyncStream<PHImageRequestID>.makeStream()

        func request(_ completion: @escaping @Sendable (UIImage?) -> Void) -> PHImageRequestID {
            self.completion = completion
            starts.continuation.yield(41)
            return 41
        }

        func cancel(_ id: PHImageRequestID) {
            cancelledIDs.append(id)
            cancellations.continuation.yield(id)
        }
    }
}
