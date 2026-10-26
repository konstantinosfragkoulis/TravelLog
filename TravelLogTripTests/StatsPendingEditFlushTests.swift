import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Stats pending edit recovery")
struct StatsPendingEditFlushTests {
    @Test("a successful flush makes pending edits visible to a separate Stats context")
    func savesPendingEdits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let trip = Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(trip)
        #expect(StatsPendingEditFlush.flush(context) == .saved)
        #expect(!context.hasChanges)
        let result = try await StatsAggregator.load(
            container: container)
        #expect(result.totalTrips == 1)
    }

    #if DEBUG
    @Test("failed flush preserves pending edits and committed Stats remain readable")
    func failedFlushCanReadAndRetry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000)))
        try context.save()
        context.insert(Trip(startDate: Date(timeIntervalSince1970: 1_700_100_000)))
        let failed = StatsPendingEditFlush.flushForTesting(context) {
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(failed == .failed)
        #expect(context.hasChanges)
        let committed = try await StatsAggregator.load(
            container: container)
        #expect(committed.totalTrips == 1)
        #expect(StatsPendingEditFlush.flush(context) == .saved)
        let retried = try await StatsAggregator.load(
            container: container)
        #expect(retried.totalTrips == 2)
    }

    @Test("an autosave before gate admission needs publication without another save")
    func autosavedWhileQueued() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(Trip(startDate: .now))
        try context.save()
        let outcome = StatsPendingEditFlush.flushForTesting(context) {
            Issue.record("Clean context was saved again")
        }
        #expect(outcome == .saved)
    }

    @Test("a failed save with healthy committed Stats keeps retrying until the save lands and publishes")
    func failedSaveRetriesUntilPublished() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000)))
        try context.save()
        context.insert(Trip(startDate: Date(timeIntervalSince1970: 1_700_100_000)))
        var published: [StoreChange] = []

        let failed = StatsPendingEditFlush.flushForTesting(
            context, publishing: { published.append($0) }
        ) { throw CocoaError(.fileWriteUnknown) }
        #expect(failed == .failed)
        #expect(published.isEmpty)
        let committed = try await StatsAggregator.load(container: container)
        #expect(committed.totalTrips == 1)
        #expect(committed.computeDegraded == nil)
        // The old loop stopped here: a healthy read after a failed save
        // reported the refresh finished while the edit was still unsaved.
        #expect(StatsRefreshDecision(computeDegraded: committed.computeDegraded, pendingSaveOwed: true)
            == .applyAndRetry)

        let retried = StatsPendingEditFlush.flush(context) { published.append($0) }
        #expect(retried == .saved)
        #expect(published == [.all])
        let refreshed = try await StatsAggregator.load(container: container)
        #expect(refreshed.totalTrips == 2)
        #expect(StatsRefreshDecision(computeDegraded: refreshed.computeDegraded, pendingSaveOwed: false)
            == .applyAndMarkCurrent)
    }

    @Test("an autosave after a failed flush is still published exactly once, without saving again")
    func autosaveAfterFailedFlushIsPublishedOnce() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(Trip(startDate: .now))
        var published: [StoreChange] = []

        let failed = StatsPendingEditFlush.flushForTesting(
            context, publishing: { published.append($0) }
        ) { throw CocoaError(.fileWriteUnknown) }
        #expect(failed == .failed)
        // Stands in for an autosave: the edit commits with no store-change bump.
        try context.save()
        #expect(!context.hasChanges)

        // The owed retry reaches a clean context; it must publish, not save.
        let owed = StatsPendingEditFlush.flushForTesting(
            context, publishing: { published.append($0) }
        ) { Issue.record("Clean context was saved again") }
        #expect(owed == .saved)
        #expect(published == [.all])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 1)
    }
    #endif

    @Test("cancellation before gate admission leaves pending edits unsaved")
    func cancellationBeforeFlush() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let result = await Task { @MainActor in
            let context = container.mainContext
            context.autosaveEnabled = false
            context.insert(Trip(startDate: .now))
            withUnsafeCurrentTask { $0?.cancel() }
            return StatsPendingEditFlush.flush(context)
        }.value
        #expect(result == .cancelled)
        #expect(container.mainContext.hasChanges)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
    }
}
