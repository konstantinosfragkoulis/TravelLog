import Dispatch
import Foundation
import os
import Testing
@testable import TravelLog

@Suite("Background task completion arbitration")
struct BackgroundTaskCompletionArbitrationTests {
    @Test("terminal status is preserved and late expiration cannot complete again", arguments: [false, true])
    func lateExpirationDoesNotReplaceCompletion(ranToEnd: Bool) {
        let completion = BackgroundTaskCompletion()
        #expect(completion.claim(ranToEnd: ranToEnd) == ranToEnd)
        completion.markExpired()
        #expect(completion.claim(ranToEnd: false) == nil)
        #expect(completion.claim(ranToEnd: true) == nil)
    }

    @Test("expiration before a terminal claim forces failure", arguments: [false, true])
    func expirationWinsOverFinishedWork(ranToEnd: Bool) {
        let completion = BackgroundTaskCompletion()
        completion.markExpired()
        #expect(completion.claim(ranToEnd: ranToEnd) == false)
        #expect(completion.claim(ranToEnd: true) == nil)
    }

    @Test("concurrent terminal paths after expiration report one failure")
    func concurrentClaimsAfterExpirationCompleteOnce() {
        let completion = BackgroundTaskCompletion()
        let results = OSAllocatedUnfairLock(initialState: [Bool]())
        completion.markExpired()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if let success = completion.claim(ranToEnd: index.isMultiple(of: 2)) {
                results.withLock { $0.append(success) }
            }
        }
        #expect(results.withLock { $0 } == [false])
    }
}

/// Stands in for `BGAppRefreshTask`: records every completion and lets a test await the first.
private final class RecordingRefreshTask: BackgroundRefreshTaskHandle {
    var expirationHandler: (() -> Void)?
    private let recorded = OSAllocatedUnfairLock(initialState: [Bool]())
    private let completions = AsyncStream<Bool>.makeStream()

    var calls: [Bool] { recorded.withLock { $0 } }

    func setTaskCompleted(success: Bool) {
        recorded.withLock { $0.append(success) }
        completions.continuation.yield(success)
    }

    func firstCompletion() async -> Bool? {
        for await success in completions.stream { return success }
        return nil
    }
}

@MainActor
@Suite("Background refresh completion", .timeLimit(.minutes(1)))
struct BackgroundRefreshCompletionTests {
    private func finishedRenewal() async -> Task<Void, Never> {
        let renewal = Task {}
        await renewal.value
        return renewal
    }

    @Test("a pipeline that runs to its end completes the task once with success")
    func naturalCompletionReportsSuccess() async {
        let task = RecordingRefreshTask()
        await AppDelegate.driveBackgroundRefresh(task, renewal: await finishedRenewal()) {}.value
        #expect(task.calls == [true])
    }

    @Test("a pipeline stopped at a cancellation checkpoint completes the task with failure")
    func cancelledPipelineReportsFailure() async {
        let task = RecordingRefreshTask()
        await AppDelegate.driveBackgroundRefresh(task, renewal: await finishedRenewal()) {
            throw CancellationError()
        }.value
        #expect(task.calls == [false])
    }

    @Test("expiration during the pipeline reports failure exactly once, whichever path wins")
    func expirationMidPipelineReportsFailureOnce() async {
        let task = RecordingRefreshTask()
        let entered = AsyncStream<Void>.makeStream()
        let completion = AppDelegate.driveBackgroundRefresh(task, renewal: await finishedRenewal()) {
            entered.continuation.yield()
            try await Task.sleep(for: .seconds(3600))
        }
        for await _ in entered.stream { break }
        task.expirationHandler?()
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
    }

    @Test("expiration after the last checkpoint still reports failure")
    func expirationAfterLastCheckpointReportsFailure() async {
        let task = RecordingRefreshTask()
        let entered = AsyncStream<Void>.makeStream()
        let hold = AsyncStream<Void>.makeStream()
        // Returns normally once cancelled, like a final stage that never checks cancellation.
        let completion = AppDelegate.driveBackgroundRefresh(task, renewal: await finishedRenewal()) {
            entered.continuation.yield()
            for await _ in hold.stream { break }
        }
        for await _ in entered.stream { break }
        task.expirationHandler?()
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
    }

    @Test("expiration while a finished pipeline waits on the renewal reports failure, whichever path wins")
    func expirationDuringRenewalWaitReportsFailure() async {
        let task = RecordingRefreshTask()
        let finished = AsyncStream<Void>.makeStream()
        let hold = AsyncStream<Void>.makeStream()
        let renewal = Task { for await _ in hold.stream { break } }
        let completion = AppDelegate.driveBackgroundRefresh(
            task, renewal: renewal, renewalGraceSeconds: 3600
        ) {
            finished.continuation.yield()
        }
        for await _ in finished.stream { break }
        task.expirationHandler?()
        // Both paths now wake on the same renewal; neither may report success.
        hold.continuation.yield()
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
    }

    @Test("a completion path that arrives after expiration does not complete the task again")
    func lateCompletionPathIsIgnored() async {
        let task = RecordingRefreshTask()
        let hold = AsyncStream<Void>.makeStream()
        let renewal = Task { for await _ in hold.stream { break } }
        let completion = AppDelegate.driveBackgroundRefresh(
            task, renewal: renewal, renewalGraceSeconds: 0.05) {}
        // The completion path is parked on the unfinished renewal, so expiration's bounded wait wins.
        task.expirationHandler?()
        #expect(await task.firstCompletion() == false)
        hold.continuation.yield()
        await completion.value
        #expect(task.calls == [false])
    }
}

/// Parks any number of callers until opened; counts entries so a test can await one.
private actor ParkingLatch {
    private(set) var entries = 0
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func park() async {
        entries += 1
        let ready = entryWaiters.filter { $0.count <= entries }
        entryWaiters.removeAll { $0.count <= entries }
        for waiter in ready { waiter.continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        if entries >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        for continuation in parked { continuation.resume() }
        parked.removeAll()
    }
}

@MainActor
@Suite("Geocode backfill completion", .timeLimit(.minutes(1)))
struct GeocodeBackfillCompletionTests {
    @Test("a completed drain reports success once and does not reschedule")
    func completedDrainReportsSuccess() async {
        let task = RecordingRefreshTask()
        let reschedules = OSAllocatedUnfairLock(initialState: 0)
        await AppDelegate.driveGeocodeBackfill(
            task,
            reschedule: { reschedules.withLock { $0 += 1 } },
            drain: { true }
        ).value
        #expect(task.calls == [true])
        #expect(reschedules.withLock { $0 } == 0)
    }

    @Test("an incomplete drain reschedules once and reports failure")
    func incompleteDrainReschedulesAndFails() async {
        let task = RecordingRefreshTask()
        let reschedules = OSAllocatedUnfairLock(initialState: 0)
        await AppDelegate.driveGeocodeBackfill(
            task,
            reschedule: { reschedules.withLock { $0 += 1 } },
            drain: { false }
        ).value
        #expect(task.calls == [false])
        #expect(reschedules.withLock { $0 } == 1)
    }

    @Test("a drain that returns true after expiration still reports failure")
    func trueDrainAfterExpirationReportsFailure() async {
        let task = RecordingRefreshTask()
        let entered = AsyncStream<Void>.makeStream()
        let hold = AsyncStream<Void>.makeStream()
        let renewal = ParkingLatch()
        // Ignores cancellation like a final unit that never checks it.
        let completion = AppDelegate.driveGeocodeBackfill(
            task,
            renewalGraceSeconds: 3600,
            reschedule: { await renewal.park() },
            drain: {
                entered.continuation.yield()
                for await _ in hold.stream { break }
                return true
            })
        for await _ in entered.stream { break }
        task.expirationHandler?()
        hold.continuation.yield()
        // Expiration's renewal is parked with a long grace, so the natural path claims first.
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
        // Only expiration renewed: a completed natural run never reschedules.
        await renewal.waitForEntries(1)
        #expect(await renewal.entries == 1)
        await renewal.open()
    }

    @Test("expiration mid-drain reports failure once and the late natural path is ignored")
    func expirationMidDrainReportsFailureOnce() async {
        let task = RecordingRefreshTask()
        let entered = AsyncStream<Void>.makeStream()
        let renewal = ParkingLatch()
        let completion = AppDelegate.driveGeocodeBackfill(
            task,
            renewalGraceSeconds: 0.05,
            reschedule: { await renewal.park() },
            drain: {
                entered.continuation.yield()
                let hold = AsyncStream<Void>.makeStream()
                // Ends when expiration cancels the drain.
                for await _ in hold.stream { break }
                return !Task.isCancelled
            })
        for await _ in entered.stream { break }
        task.expirationHandler?()
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
        // Expiration renewed; the cancelled natural path finished without parking a second submit.
        await renewal.waitForEntries(1)
        #expect(await renewal.entries == 1)
        await renewal.open()
    }

    @Test("expiration while an incomplete run reschedules still completes once with failure")
    func expirationDuringNaturalRescheduleFailsOnce() async {
        let task = RecordingRefreshTask()
        let renewal = ParkingLatch()
        let completion = AppDelegate.driveGeocodeBackfill(
            task,
            renewalGraceSeconds: 3600,
            reschedule: { await renewal.park() },
            drain: { false })
        await renewal.waitForEntries(1)
        task.expirationHandler?()
        await renewal.waitForEntries(2)
        // Duplicate submits replace the pending request; both paths may renew.
        await renewal.open()
        #expect(await task.firstCompletion() == false)
        await completion.value
        #expect(task.calls == [false])
    }
}
