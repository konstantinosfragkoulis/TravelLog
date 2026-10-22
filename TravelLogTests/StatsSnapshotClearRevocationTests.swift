//
//  StatsSnapshotClearRevocationTests.swift
//  TravelLogTests
//
//  A snapshot clear revokes the Stats aggregates on screen:
//  the page shows and shares only complete aggregates of the current
//  clear generation. Drives `StatsRefreshLedger`, the bookkeeping the Stats
//  refresh task runs on, through real `StatsAggregator` computes and real
//  clears, including Delete Calendar Data, whose `.plannedTrip` unit touches
//  no store type Stats observes and so reaches the page only through the
//  `statsSnapshotCleared` notification.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Stats snapshot clear revocation", .serialized, IsolatedCalendarDefaults())
struct StatsSnapshotClearRevocationTests {

    private let token = StatsRefreshIdentity(
        storeToken: 7, now: Date(timeIntervalSince1970: 1_750_000_000),
        timeZone: TimeZone(identifier: "UTC")!)

    private func withIsolatedStorage(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (_ suiteName: String) async throws -> Void
    ) async throws {
        let suiteName = "StatsSnapshotClearRevocationTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suiteName
        )) {
            try await body(suiteName)
        }
    }

    /// A store with one trip, so a complete compute has something to share.
    private func populatedContainer() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000)))
        try context.save()
        return container
    }

    /// Runs a real compute and lets the ledger judge it as the refresh does.
    private func computeAndConclude(
        _ ledger: inout StatsRefreshLedger, container: ModelContainer, computedAt generation: Int
    ) async throws -> StatsRefreshLedger.Conclusion {
        let result = try await StatsAggregator.load(container: container)
        #expect(result.computeDegraded == nil)
        return ledger.conclude(
            token, computedAt: generation, currentToken: token,
            currentGeneration: StatsSnapshotStore.clearGeneration,
            computeDegraded: result.computeDegraded, pendingSaveOwed: false)
    }

    @Test("Delete Calendar Data after acceptance posts a clear that revokes shareable aggregates before the up-to-date fast path, then recomputes")
    func calendarDeletionRevokesAcceptedAggregates() async throws {
        let container = try populatedContainer()
        let context = ModelContext(container)
        context.insert(PlannedTrip(
            eventExternalIdentifier: "ext", eventLocalIdentifier: "loc", title: "Private Event",
            startDate: .now, endDate: .now.addingTimeInterval(86_400), isAllDay: false, locationText: nil))
        try context.save()
        let enricher = CalendarEnricher(modelContainer: container)

        try await withIsolatedStorage { suiteName in
            var ledger = StatsRefreshLedger()
            let accepted = StatsSnapshotStore.clearGeneration
            let start1 = ledger.begin(token, currentGeneration: accepted)
            #expect(start1 == .refresh(revoked: false))
            let first = try await computeAndConclude(&ledger, container: container, computedAt: accepted)
            #expect(first == .decided(.applyAndMarkCurrent))
            #expect(!first.needsRetry)
            #expect(ledger.hasCompleteAggregates(currentGeneration: accepted))
            let start2 = ledger.begin(token, currentGeneration: accepted)
            #expect(start2 == .upToDate)

            // Count only this test's clears: delivery is synchronous on the
            // clearing thread, which still carries this test's storage.
            let posts = OSAllocatedUnfairLock(initialState: 0)
            let observer = NotificationCenter.default.addObserver(
                forName: .statsSnapshotCleared, object: nil, queue: nil
            ) { _ in
                guard StatsSnapshotStore.storageForTesting?.defaultsSuiteName == suiteName else { return }
                posts.withLock { $0 += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let deletion = await enricher.deleteAllCalendarData()
            #expect(deletion.succeeded)
            #expect(posts.withLock { $0 } == 1, "Stats observes a clear only through this notification")

            let cleared = StatsSnapshotStore.clearGeneration
            #expect(cleared != accepted)
            #expect(!ledger.hasCompleteAggregates(currentGeneration: cleared))

            // The page's notification handler revokes on its own.
            var observed = ledger
            let observedRevoked = observed.revokeIfCleared(currentGeneration: cleared)
            #expect(observedRevoked)
            #expect(observed.isCold)

            // The restarted refresh, with the SAME store token, revokes before
            // the up-to-date fast path instead of keeping the deleted totals.
            let start3 = ledger.begin(token, currentGeneration: cleared)
            #expect(start3 == .refresh(revoked: true))
            #expect(ledger.isCold)
            let start4 = ledger.begin(token, currentGeneration: cleared)
            #expect(start4 == .refresh(revoked: false))

            // A fresh compute of the new generation is accepted again.
            let fresh = try await computeAndConclude(&ledger, container: container, computedAt: cleared)
            #expect(fresh == .decided(.applyAndMarkCurrent))
            #expect(ledger.hasCompleteAggregates(currentGeneration: cleared))
        }
    }

    @Test("a clear while a compute is loading discards its result, revokes hydrated aggregates and keeps the refresh retrying")
    func clearDuringLoadingRevokesAndRetries() async throws {
        let container = try populatedContainer()
        try await withIsolatedStorage { _ in
            // Cold-launch hydration of a complete snapshot.
            let hydrationGeneration = StatsSnapshotStore.clearGeneration
            let seeded = try await StatsAggregator.load(container: container)
            StatsSnapshotStore.save(seeded, generation: hydrationGeneration)
            #expect(StatsSnapshotStore.load() != nil)
            var ledger = StatsRefreshLedger()
            let start5 = ledger.begin(token, currentGeneration: hydrationGeneration)
            #expect(start5 == .refresh(revoked: false))
            ledger.acceptHydrated(generation: hydrationGeneration)
            #expect(ledger.hasCompleteAggregates(currentGeneration: hydrationGeneration))

            // The refresh captures its generation, then a deletion lands
            // while the compute is still loading.
            let computeGeneration = StatsSnapshotStore.clearGeneration
            let loading = Task { try await StatsAggregator.load(container: container) }
            StatsSnapshotStore.clear()
            let result = try await loading.value

            let conclusion = ledger.conclude(
                token, computedAt: computeGeneration, currentToken: token,
                currentGeneration: StatsSnapshotStore.clearGeneration,
                computeDegraded: result.computeDegraded, pendingSaveOwed: false)
            #expect(conclusion == .clearedDuringCompute(revoked: true))
            #expect(conclusion.needsRetry, "a mid-compute clear must not end the retry loop")
            #expect(ledger.isCold)
            #expect(!ledger.hasCompleteAggregates(currentGeneration: StatsSnapshotStore.clearGeneration))
            #expect(StatsSnapshotStore.reserveSave(generation: computeGeneration) == nil)
            #expect(StatsSnapshotStore.load() == nil)

            // The retry computes the new generation and is accepted.
            let retryGeneration = StatsSnapshotStore.clearGeneration
            let start6 = ledger.begin(token, currentGeneration: retryGeneration)
            #expect(start6 == .refresh(revoked: false))
            let retried = try await computeAndConclude(&ledger, container: container, computedAt: retryGeneration)
            #expect(retried == .decided(.applyAndMarkCurrent))
            #expect(ledger.hasCompleteAggregates(currentGeneration: retryGeneration))
        }
    }

    @Test("a clear during a cold page's first compute still retries instead of stopping on placeholders")
    func clearDuringColdComputeRetries() async throws {
        let container = try populatedContainer()
        try await withIsolatedStorage { _ in
            var ledger = StatsRefreshLedger()
            let computeGeneration = StatsSnapshotStore.clearGeneration
            let start7 = ledger.begin(token, currentGeneration: computeGeneration)
            #expect(start7 == .refresh(revoked: false))
            let result = try await StatsAggregator.load(container: container)
            StatsSnapshotStore.clear()

            let conclusion = ledger.conclude(
                token, computedAt: computeGeneration, currentToken: token,
                currentGeneration: StatsSnapshotStore.clearGeneration,
                computeDegraded: result.computeDegraded, pendingSaveOwed: false)
            #expect(conclusion == .clearedDuringCompute(revoked: false))
            #expect(conclusion.needsRetry)
            #expect(ledger.isCold)
        }
    }

    @Test("a clear wins over a concurrent store-token change, so accepted aggregates are still revoked")
    func clearWinsOverSupersededToken() {
        var ledger = StatsRefreshLedger()
        _ = ledger.conclude(
            token, computedAt: 3, currentToken: token, currentGeneration: 3,
            computeDegraded: nil, pendingSaveOwed: false)
        #expect(ledger.hasCompleteAggregates(currentGeneration: 3))

        let moved = StatsRefreshIdentity(
            storeToken: 8, now: Date(timeIntervalSince1970: 1_750_000_000),
            timeZone: TimeZone(identifier: "UTC")!)
        let conclusion = ledger.conclude(
            moved, computedAt: 3, currentToken: token, currentGeneration: 4,
            computeDegraded: nil, pendingSaveOwed: false)
        #expect(conclusion == .clearedDuringCompute(revoked: true))
        #expect(ledger.isCold)

        // Without a clear, a moved identity is only superseded and keeps
        // whatever was accepted.
        var current = StatsRefreshLedger()
        _ = current.conclude(
            token, computedAt: 4, currentToken: token, currentGeneration: 4,
            computeDegraded: nil, pendingSaveOwed: false)
        let superseded = current.conclude(
            token, computedAt: 4, currentToken: moved, currentGeneration: 4,
            computeDegraded: nil, pendingSaveOwed: false)
        #expect(superseded == .superseded)
        #expect(current.hasCompleteAggregates(currentGeneration: 4))
    }

    @Test("only a complete result with no owed save finishes a refresh; degraded and owed-save results keep it unfinished")
    func retryMapping() {
        var ledger = StatsRefreshLedger()
        let degraded = ledger.conclude(
            token, computedAt: 0, currentToken: token, currentGeneration: 0,
            computeDegraded: true, pendingSaveOwed: false)
        #expect(degraded == .decided(.rejectAndRetry) && degraded.needsRetry)
        #expect(!ledger.hasCompleteAggregates(currentGeneration: 0))

        let owed = ledger.conclude(
            token, computedAt: 0, currentToken: token, currentGeneration: 0,
            computeDegraded: nil, pendingSaveOwed: true)
        #expect(owed == .decided(.applyAndRetry) && owed.needsRetry)
        #expect(ledger.hasCompleteAggregates(currentGeneration: 0))
        let start8 = ledger.begin(token, currentGeneration: 0)
        #expect(start8 == .refresh(revoked: false))

        let complete = ledger.conclude(
            token, computedAt: 0, currentToken: token, currentGeneration: 0,
            computeDegraded: nil, pendingSaveOwed: false)
        #expect(complete == .decided(.applyAndMarkCurrent) && !complete.needsRetry)
        let start9 = ledger.begin(token, currentGeneration: 0)
        #expect(start9 == .upToDate)
    }
}
