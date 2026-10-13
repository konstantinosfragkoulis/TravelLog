//
//  BackfillLatchPolicyTests.swift
//  TravelLogTests
//
//  Pins the latch policy: one-shot repair backfills must not
//  latch their completion gate against an empty or still-hydrating CloudKit
//  store (new device / reinstall), while local-only stores latch freely.
//

import Testing
import Foundation
@testable import TravelLog

struct BackfillLatchPolicyTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Offsets are seconds before `now`; a negative offset is in the future.
    private func context(
        persistent: Bool = true,
        iCloud: Bool,
        rows: Int,
        importAgo: TimeInterval? = nil,
        importDuration: TimeInterval = 5,
        importInFlight: Bool = false,
        latestStartAgo: TimeInterval? = nil,
        passAgo: TimeInterval = 10,
        pushAgo: TimeInterval? = nil
    ) -> BackfillLatchPolicy.Context {
        .init(
            isPersistentStore: persistent,
            iCloudSyncEnabled: iCloud,
            processedRowCount: rows,
            lastRemoteImportAt: pushAgo.map { now.addingTimeInterval(-$0) },
            lastSuccessfulImportAt: importAgo.map { now.addingTimeInterval(-$0) },
            lastSuccessfulImportStartedAt: importAgo.map { now.addingTimeInterval(-$0 - importDuration) },
            importInFlight: importInFlight,
            lastImportStartedAt: latestStartAgo.map { now.addingTimeInterval(-$0) },
            passStartedAt: now.addingTimeInterval(-passAgo),
            now: now
        )
    }

    @Test("an in-memory fallback never latches, even when iCloud is off")
    func inMemoryStoreNeverLatches() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            persistent: false, iCloud: false, rows: 0)))
        #expect(!BackfillLatchPolicy.mayLatch(context(
            persistent: false, iCloud: false, rows: 500)))
        #expect(!BackfillLatchPolicy.mayLatch(context(
            persistent: false, iCloud: true, rows: 500, importAgo: 60)))
    }

    @Test("iCloud off always latches; a local store cannot hydrate further")
    func localStoreAlwaysLatches() {
        #expect(BackfillLatchPolicy.mayLatch(context(iCloud: false, rows: 0)))
        #expect(BackfillLatchPolicy.mayLatch(context(iCloud: false, rows: 0, pushAgo: 1)))
        #expect(BackfillLatchPolicy.mayLatch(context(iCloud: false, rows: 500, pushAgo: 1)))
    }

    @Test("an empty table under iCloud never latches; indistinguishable from pre-hydration")
    func emptyTableNeverLatchesUnderICloud() {
        #expect(!BackfillLatchPolicy.mayLatch(context(iCloud: true, rows: 0)))
        #expect(!BackfillLatchPolicy.mayLatch(context(iCloud: true, rows: 0, importAgo: 60)))
    }

    @Test("no completed CloudKit import under iCloud defers the latch")
    func noCompletedImportDefers() {
        #expect(!BackfillLatchPolicy.mayLatch(context(iCloud: true, rows: 100)))
        #expect(!BackfillLatchPolicy.mayLatch(context(iCloud: true, rows: 100, pushAgo: 600)))
    }

    @Test("an import completed before the pass started with no later push latches")
    func importBeforePassLatches() {
        #expect(BackfillLatchPolicy.mayLatch(context(iCloud: true, rows: 100, importAgo: 60)))
        // An import ending exactly as the pass starts still counts.
        #expect(BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 10, passAgo: 10)))
    }

    @Test("a running import defers the latch even after an older one completed")
    func importInFlightDefers() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, importInFlight: true)))
        #expect(BackfillLatchPolicy.mayLatch(context(iCloud: false, rows: 100, importInFlight: true)))
    }

    @Test("an import that ended after the pass started defers the latch")
    func importAfterPassStartDefers() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 5, passAgo: 10)))
    }

    @Test("a push after the last import began defers the latch; an older one does not")
    func pushOrderingAgainstImport() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, pushAgo: 30)))
        // Arrived while the import ran (started 65 s ago, ended 60 s ago).
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, pushAgo: 62)))
        #expect(BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, pushAgo: 120)))
    }

    @Test("an import that began after the last success without succeeding defers the latch")
    func laterImportWithoutSuccessDefers() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, latestStartAgo: 30)))
        // The latest start is the success itself.
        #expect(BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, latestStartAgo: 65)))
        // A stamp from an older build has no start: never latch on it.
        var stampless = context(iCloud: true, rows: 100, importAgo: 60)
        stampless.lastSuccessfulImportStartedAt = nil
        #expect(!BackfillLatchPolicy.mayLatch(stampless))
    }

    @Test("an import end or pass start in the future defers the latch")
    func futureTimestampsDefer() {
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: -600, passAgo: -1200)))
        #expect(!BackfillLatchPolicy.mayLatch(context(
            iCloud: true, rows: 100, importAgo: 60, passAgo: -30)))
    }
}
