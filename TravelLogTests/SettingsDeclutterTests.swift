//
//  SettingsDeclutterTests.swift
//  TravelLogTests
//
//  The narrow signals behind the reorganized Settings: the batched
//  temporary-home status read agrees with the per-id read, every queue and
//  status-record write posts the dedicated notification, and the history
//  rebuild backlog is counted on its own context.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Settings declutter signals", .serialized)
struct SettingsDeclutterTests {

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SettingsDeclutterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("the batched status read matches the per-id read for owed, waiting, failed and settled temporary homes")
    func batchedStatusesMatchPerIDReads() throws {
        try withSuite { defaults in
            let updating = UUID(), waiting = UUID(), failed = UUID(), settled = UUID(), untouched = UUID()
            CoverageReconciliationQueue.enqueue(.temporaryHome, id: updating, defaults: defaults)
            let waitingEntry = CoverageReconciliationQueue.enqueue(.temporaryHome, id: waiting, defaults: defaults)
            CoverageReconciliationQueue.recordTemporaryHomeOutcome(
                .deferred(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0), for: waitingEntry, defaults: defaults)
            let failedEntry = CoverageReconciliationQueue.enqueue(.temporaryHome, id: failed, defaults: defaults)
            CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: failedEntry, defaults: defaults)
            let settledEntry = CoverageReconciliationQueue.enqueue(.temporaryHome, id: settled, defaults: defaults)
            CoverageReconciliationQueue.complete(settledEntry, defaults: defaults)
            // A Home owed under an id is not a temporary home's work.
            CoverageReconciliationQueue.enqueue(.home, id: untouched, defaults: defaults)

            let ids: Set<UUID> = [updating, waiting, failed, settled, untouched]
            let batched = CoverageReconciliationQueue.temporaryHomeStatuses(ids: ids, defaults: defaults)
            for id in ids {
                #expect(batched[id] == CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults))
            }
            #expect(batched == [updating: .updating, waiting: .waiting, failed: .failed])
            #expect(CoverageReconciliationQueue.temporaryHomeStatuses(ids: [], defaults: defaults).isEmpty)
        }
    }

    @Test("staging, withdrawing, completing and recording an outcome each post the queue status notification")
    func queueWritesPostTheStatusSignal() throws {
        try withSuite { defaults in
            var posts = 0
            let observer = NotificationCenter.default.addObserver(
                forName: CoverageReconciliationQueue.statusDidChangeNotification,
                object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated { posts += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            func posted(_ write: () -> Void) -> Bool {
                let before = posts
                write()
                return posts > before
            }

            let id = UUID()
            var entry: CoverageReconciliationQueue.Entry?
            #expect(posted { entry = CoverageReconciliationQueue.enqueue(.temporaryHome, id: id, defaults: defaults) })
            let owed = try #require(entry)
            #expect(posted { CoverageReconciliationQueue.recordTemporaryHomeOutcome(.failed, for: owed, defaults: defaults) })
            #expect(posted { CoverageReconciliationQueue.complete(owed, defaults: defaults) })
            var staged: CoverageReconciliationQueue.Staged?
            #expect(posted { staged = CoverageReconciliationQueue.stage(.temporaryHome, id: id, defaults: defaults) })
            let pending = try #require(staged)
            #expect(posted { CoverageReconciliationQueue.withdraw(pending, defaults: defaults) })
            #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: id, defaults: defaults) == nil)
        }
    }
}
