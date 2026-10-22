//
//  RemoteSyncWidgetReloadTests.swift
//  TravelLogTests
//
//  Pins the background new-hex widget reload throttle: a drive enters a new
//  hex every few minutes and each SLC wake used to reload every timeline,
//  which spent WidgetKit's daily budget mid-trip. Foreground batches and
//  completed CloudKit imports still reload without a throttle.
//

import Testing
import Foundation
import CoreData
@testable import TravelLog

private actor MaintenancePassRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor MaintenancePassLatch {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

struct RemoteSyncWidgetReloadTests {

    @Test("first reload is always due; repeats gate on the min interval")
    func throttleRule() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let interval = AppDelegate.hexWidgetReloadMinInterval

        #expect(AppDelegate.widgetReloadDue(last: nil, now: t0, minInterval: interval))
        #expect(!AppDelegate.widgetReloadDue(
            last: t0, now: t0.addingTimeInterval(interval - 1), minInterval: interval))
        #expect(AppDelegate.widgetReloadDue(
            last: t0, now: t0.addingTimeInterval(interval), minInterval: interval))
        // A clock that runs BACKWARDS (restored backup, manual clock change)
        // must not reload — the rule is `>=`, never absolute-difference.
        #expect(!AppDelegate.widgetReloadDue(
            last: t0, now: t0.addingTimeInterval(-1), minInterval: interval))
    }

    @Test("the hex slot is due first, gates an immediate repeat, and is due again after the interval")
    func hexSlotClaims() {
        // The slot is process-global and other suites claim it with the real
        // clock, so reset before and after and use a far-future clock that a
        // concurrent real-time claim cannot outrun.
        AppDelegate.resetWidgetReloadSlotsForTesting()
        defer { AppDelegate.resetWidgetReloadSlotsForTesting() }
        let t0 = Date.now.addingTimeInterval(10 * 365 * 24 * 3600)
        let interval = AppDelegate.hexWidgetReloadMinInterval

        #expect(AppDelegate.claimHexWidgetReloadSlot(now: t0))
        #expect(!AppDelegate.claimHexWidgetReloadSlot(now: t0.addingTimeInterval(1)))
        #expect(AppDelegate.claimHexWidgetReloadSlot(now: t0.addingTimeInterval(interval)))
    }

    @Test("a suppressed new-hex reload is owed to the next batch")
    func suppressedReloadIsOwed() {
        typealias D = AppDelegate
        // Nothing new and nothing owed: no reload.
        #expect(D.hexWidgetReloadDecision(insertedNewHex: false, pending: false, batchIsSLC: true, claimSlot: { true }) == (false, false))
        // Foreground batches reload at once, including an owed one without a new hex.
        #expect(D.hexWidgetReloadDecision(insertedNewHex: true, pending: false, batchIsSLC: false, claimSlot: { false }) == (true, false))
        #expect(D.hexWidgetReloadDecision(insertedNewHex: false, pending: true, batchIsSLC: false, claimSlot: { false }) == (true, false))
        // Background batches wait for the slot and carry the debt meanwhile.
        #expect(D.hexWidgetReloadDecision(insertedNewHex: true, pending: false, batchIsSLC: true, claimSlot: { false }) == (false, true))
        #expect(D.hexWidgetReloadDecision(insertedNewHex: false, pending: true, batchIsSLC: true, claimSlot: { false }) == (false, true))
        #expect(D.hexWidgetReloadDecision(insertedNewHex: false, pending: true, batchIsSLC: true, claimSlot: { true }) == (true, false))
    }

    @Test("the shipped interval bounds staleness at 15 minutes")
    func shippedInterval() {
        #expect(AppDelegate.hexWidgetReloadMinInterval == 15 * 60)
    }

    @Test("title maintenance waits for a successful completed CloudKit import")
    func completedImportGate() {
        let finished = Date(timeIntervalSinceReferenceDate: 100)
        #expect(AppDelegate.shouldRunPostCloudImportMaintenance(
            eventType: .import, endDate: finished,
            succeeded: true, iCloudEnabled: true))
        #expect(!AppDelegate.shouldRunPostCloudImportMaintenance(
            eventType: .import, endDate: nil,
            succeeded: true, iCloudEnabled: true))
        #expect(!AppDelegate.shouldRunPostCloudImportMaintenance(
            eventType: .import, endDate: finished,
            succeeded: false, iCloudEnabled: true))
        #expect(!AppDelegate.shouldRunPostCloudImportMaintenance(
            eventType: .export, endDate: finished,
            succeeded: true, iCloudEnabled: true))
        #expect(!AppDelegate.shouldRunPostCloudImportMaintenance(
            eventType: .import, endDate: finished,
            succeeded: true, iCloudEnabled: false))
    }

    @Test("only completed failed CloudKit imports and exports are recorded")
    func failedSyncEventGate() {
        let finished = Date(timeIntervalSinceReferenceDate: 100)
        #expect(AppDelegate.shouldRecordCloudKitSyncFailure(
            eventType: .import, endDate: finished, succeeded: false))
        #expect(AppDelegate.shouldRecordCloudKitSyncFailure(
            eventType: .export, endDate: finished, succeeded: false))
        #expect(!AppDelegate.shouldRecordCloudKitSyncFailure(
            eventType: .setup, endDate: finished, succeeded: false))
        #expect(!AppDelegate.shouldRecordCloudKitSyncFailure(
            eventType: .import, endDate: nil, succeeded: false))
        #expect(!AppDelegate.shouldRecordCloudKitSyncFailure(
            eventType: .export, endDate: finished, succeeded: true))
    }

    @Test("failed CloudKit event diagnostics include the operation, timestamp, and error")
    func failedSyncEventDescription() {
        let finished = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedTimestamp = ISO8601DateFormatter().string(from: finished)

        let importMessage = AppDelegate.cloudKitSyncFailureDescription(
            eventType: .import,
            errorDescription: "network unavailable",
            timestamp: finished
        )
        #expect(importMessage?.contains("import") == true)
        #expect(importMessage?.contains(expectedTimestamp) == true)
        #expect(importMessage?.contains("network unavailable") == true)

        #expect(AppDelegate.cloudKitSyncFailureDescription(
            eventType: .setup,
            errorDescription: "ignored",
            timestamp: finished
        ) == nil)
    }

    @Test("completed-import maintenance supersedes pending speculative push work")
    func completedImportSupersedesPendingPush() async throws {
        let admissions = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let coalescer = RemotePushCoalescer(waitForQuietWindow: {
            await release.wait(until: 1)
            try Task.checkCancellation()
        }, admitted: { await admissions.arrive() })
        let recorder = MaintenancePassRecorder()

        let push = Task {
            await coalescer.schedule {
                await recorder.append("push")
            }
        }
        await admissions.wait(until: 1)
        let completedImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("completed-import")
            }
        }
        await admissions.wait(until: 2)
        await release.arrive()
        await push.value
        await completedImport.value

        #expect(await recorder.snapshot() == ["completed-import"])
    }

    @Test("a push superseded by completed-import maintenance waits for that pass")
    func supersededPushAwaitsCompletedImport() async throws {
        let admissions = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let coalescer = RemotePushCoalescer(waitForQuietWindow: {
            await release.wait(until: 1)
            try Task.checkCancellation()
        }, admitted: { await admissions.arrive() })
        let recorder = MaintenancePassRecorder()
        let latch = MaintenancePassLatch()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        var startedIterator = started.makeAsyncIterator()

        let push = Task {
            await coalescer.schedule {
                await recorder.append("push")
            }
            await recorder.append("push-returned")
        }
        await admissions.wait(until: 1)
        let completedImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("completed-import-start")
                startedContinuation.yield()
                await latch.wait()
                await recorder.append("completed-import-end")
            }
        }
        await admissions.wait(until: 2)
        await release.arrive()
        _ = await startedIterator.next()
        // The push's background window must still be held.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !recorder.snapshot().contains("push-returned"))
        await latch.release()
        await push.value
        await completedImport.value

        #expect(await recorder.snapshot()
            == ["completed-import-start", "completed-import-end", "push-returned"])
    }

    @Test("a superseded push follows every completed-import pass that replaces its replacement",
          .timeLimit(.minutes(1)))
    func supersededPushFollowsReplacementChain() async throws {
        let admissions = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let coalescer = RemotePushCoalescer(waitForQuietWindow: {
            await release.wait(until: 1)
            try Task.checkCancellation()
        }, admitted: { await admissions.arrive() })
        let recorder = MaintenancePassRecorder()
        let firstLatch = MaintenancePassLatch()
        let secondLatch = MaintenancePassLatch()
        let (firstStarted, firstContinuation) = AsyncStream<Void>.makeStream()
        var firstIterator = firstStarted.makeAsyncIterator()
        let (secondStarted, secondContinuation) = AsyncStream<Void>.makeStream()
        var secondIterator = secondStarted.makeAsyncIterator()

        let push = Task {
            await coalescer.schedule {
                await recorder.append("push")
            }
            await recorder.append("push-returned")
        }
        await admissions.wait(until: 1)
        let firstImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("first-import-start")
                firstContinuation.yield()
                await firstLatch.wait()
                await recorder.append("first-import-end")
            }
        }
        await admissions.wait(until: 2)
        await release.arrive()
        _ = await firstIterator.next()
        // Let the superseded push settle on the first import before a later
        // completed import replaces that still-running pass.
        try await Task.sleep(for: .milliseconds(30))
        let secondImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("second-import-start")
                secondContinuation.yield()
                await secondLatch.wait()
                await recorder.append("second-import-end")
            }
        }
        await admissions.wait(until: 3)
        await firstLatch.release()
        _ = await secondIterator.next()
        // The push's background window must still be held.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !recorder.snapshot().contains("push-returned"))
        await secondLatch.release()
        await push.value
        await firstImport.value
        await secondImport.value

        #expect(await recorder.snapshot() == [
            "first-import-start", "first-import-end",
            "second-import-start", "second-import-end", "push-returned",
        ])
    }

    @Test("a push joined to completed-import maintenance follows its replacement",
          .timeLimit(.minutes(1)))
    func joinedPushFollowsReplacedCompletedImport() async throws {
        let admissions = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let coalescer = RemotePushCoalescer(waitForQuietWindow: {
            await release.wait(until: 1)
            try Task.checkCancellation()
        }, admitted: { await admissions.arrive() })
        let recorder = MaintenancePassRecorder()
        let latch = MaintenancePassLatch()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        var startedIterator = started.makeAsyncIterator()

        let firstImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("first-import")
            }
        }
        await admissions.wait(until: 1)
        let push = Task {
            await coalescer.schedule {
                await recorder.append("push")
            }
            await recorder.append("push-returned")
        }
        await admissions.wait(until: 2)
        let secondImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("second-import-start")
                startedContinuation.yield()
                await latch.wait()
                await recorder.append("second-import-end")
            }
        }
        await admissions.wait(until: 3)
        await release.arrive()
        _ = await startedIterator.next()
        // The push's background window must still be held.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !recorder.snapshot().contains("push-returned"))
        await latch.release()
        await push.value
        await firstImport.value
        await secondImport.value

        #expect(await recorder.snapshot()
            == ["second-import-start", "second-import-end", "push-returned"])
    }

    @Test("a speculative push joins pending authoritative maintenance")
    func pendingCompletedImportCannotBeSupersededByPush() async throws {
        let admissions = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let coalescer = RemotePushCoalescer(waitForQuietWindow: {
            await release.wait(until: 1)
            try Task.checkCancellation()
        }, admitted: { await admissions.arrive() })
        let recorder = MaintenancePassRecorder()

        let completedImport = Task {
            await coalescer.schedule(authoritative: true) {
                await recorder.append("completed-import")
            }
        }
        await admissions.wait(until: 1)
        let push = Task {
            await coalescer.schedule {
                await recorder.append("push")
            }
        }
        await admissions.wait(until: 2)
        await release.arrive()
        await completedImport.value
        await push.value

        #expect(await recorder.snapshot() == ["completed-import"])
    }

    @Test("a cancelled waiter cannot race its replacement into maintenance")
    func cancelledWaiterCannotRunWithReplacement() async throws {
        let coalescer = RemotePushCoalescer(
            quietWindow: .milliseconds(10))
        let recorder = MaintenancePassRecorder()
        let latch = MaintenancePassLatch()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        var startedIterator = started.makeAsyncIterator()

        let initial = Task {
            await coalescer.schedule {
                await recorder.append("initial")
                startedContinuation.yield()
                await latch.wait()
            }
        }
        _ = await startedIterator.next()

        let replaced = Task {
            await coalescer.schedule {
                await recorder.append("replaced")
            }
        }
        // Let the first replacement pass its debounce and suspend on the
        // running initial pass before a newer request cancels it.
        try await Task.sleep(for: .milliseconds(30))
        let replacement = Task {
            await coalescer.schedule {
                await recorder.append("replacement")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        await latch.release()

        await initial.value
        await replaced.value
        await replacement.value

        #expect(await recorder.snapshot() == ["initial", "replacement"])
    }
}
