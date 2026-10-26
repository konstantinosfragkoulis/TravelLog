import Testing
import Foundation
import SwiftData
import os
@testable import TravelLog

@MainActor
@Suite("Stats worker cancellation")
struct StatsAggregatorCancellationTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("an already cancelled caller never starts the Stats worker")
    func cancelledBeforeLoad() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StatsAggregator.load(
                container: container
            ) {
                calls.withLock { $0 += 1 }
                try Task.checkCancellation()
            }
        }
        do {
            _ = try await caller.value
            Issue.record("Cancelled caller returned Stats")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("parent cancellation reaches the active Stats worker", .timeLimit(.minutes(1)))
    func cancelsActiveWorker() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let offMain = OSAllocatedUnfairLock(initialState: false)
        let cancelCaller = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let caller = Task { @MainActor in
            return try await StatsAggregator.load(
                container: container
            ) {
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    offMain.withLock { $0 = !Thread.isMainThread }
                    // Cancel the caller at the live worker checkpoint. The
                    // production handler must forward this to the worker;
                    // cancelling only the caller still fails the call-count pin.
                    let cancel = cancelCaller.withLock { $0 }
                    #expect(cancel != nil)
                    cancel?()
                    // A newly detached worker can beat handler registration.
                    // Bound only forwarding after the cancellation request,
                    // without waiting for the test's MainActor to resume.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while !Task.isCancelled, ContinuousClock.now < deadline {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    #expect(Task.isCancelled)
                }
                try Task.checkCancellation()
            }
        }
        // The caller is MainActor-isolated, so it cannot enter load until
        // this test suspends below. Install its cancellation handle first.
        cancelCaller.withLock { $0 = { caller.cancel() } }
        defer {
            cancelCaller.withLock { $0 = nil }
            caller.cancel()
        }
        do {
            _ = try await caller.value
            Issue.record("Cancelled worker returned Stats")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(caller.isCancelled)
        #expect(calls.withLock { $0 } == 1)
        #expect(offMain.withLock { $0 })
    }

    @Test("cancellation at fetch checkpoints throws instead of degrading", arguments: [1, 3, 10])
    func fetchCancellation(stopAt: Int) throws {
        let container = try TestSupport.makeInMemoryContainer()
        var calls = 0
        #expect(throws: CancellationError.self) {
            try StatsAggregator.compute(
                container: container
            ) {
                calls += 1
                if calls == stopAt { throw CancellationError() }
            }
        }
        #expect(calls == stopAt)
    }

    @Test("hex reduction cancellation never returns partial totals")
    func hexReductionCancellation() throws {
        let index = try #require(H3Service.cellIndex(latitude: 38, longitude: 24))
        let rows = (0..<128).map { _ in
            HexVisit(h3Index: index, firstVisited: now, centerLatitude: 38, centerLongitude: 24)
        }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try StatsAggregator.aggregate(
                visitedStays: [], transitStays: [], trips: [], hexVisits: rows,
                totalPings: 0, totalStays: 0, flightCount: 0, trackingSince: nil, now: now
            ) {
                calls += 1
                // With no stays or trips, this interrupts the H3 row walk.
                if calls == 32 { throw CancellationError() }
            }
        }
        #expect(calls == 32)
    }

    @Test("travel-day expansion stops inside a long trip")
    func dayWalkCancellation() {
        let trip = Trip(startDate: now.addingTimeInterval(-1000 * 86_400))
        trip.endDate = now
        var calls = 0
        #expect(throws: CancellationError.self) {
            try StatsAggregator.travelDaySet(trips: [trip], now: now, calendar: .current) {
                calls += 1
                if calls == 8 { throw CancellationError() }
            }
        }
        #expect(calls == 8)
    }

    @Test("Collections cancellation reaches the nested area-pair walk")
    func collectionsPairCancellation() {
        let stays = (0..<128).map { _ in
            let stay = Stay(startTime: now, endTime: now, centroidLatitude: 38,
                            centroidLongitude: 24, h3IndexRes6: "", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.administrativeArea = "Attica"
            return stay
        }
        var entries: [String: CollectionsAggregator.PlaceEntry] = [:]
        var tripIDs: [String: Set<UUID>] = [:]
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        var calls = 0
        #expect(throws: CancellationError.self) {
            try CollectionsAggregator.appendAreaClusters(
                unnamed: stays, entries: &entries, tripIDs: &tripIDs, days: &days, order: &order
            ) {
                calls += 1
                // Pass filtering and bucket preparation before interrupting pair work.
                if calls == 430 { throw CancellationError() }
            }
        }
        #expect(calls == 430)
        #expect(entries.isEmpty)
    }

    @Test("city deduplication cancellation reaches dense proximity comparisons")
    func cityPairCancellation() {
        let stays = (0..<128).map { _ in
            Stay(startTime: now, endTime: now, centroidLatitude: 38,
                 centroidLongitude: 24, h3IndexRes6: "", pingCount: 1,
                 distanceFromHomeKm: 0, pingIDs: [])
        }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try Stay.deduplicatedCityCount(from: stays) {
                calls += 1
                // Beyond the 128-row grouping pass, inside the pair walk.
                if calls == 200 { throw CancellationError() }
            }
        }
        #expect(calls == 200)
        #expect(Stay.deduplicatedCityCount(from: stays) == 1)
    }

    @Test("On This Day cancellation interrupts a stay's year walk")
    func onThisDayCancellation() {
        let stay = OnThisDayStay(
            stayID: UUID(), tripID: nil, place: "Athens",
            startTime: now.addingTimeInterval(-20 * 365 * 86_400), endTime: now,
            weatherConditionRaw: nil, avgTemperatureC: nil
        )
        var calls = 0
        #expect(throws: CancellationError.self) {
            try OnThisDayEngine.yearGroups(on: now, stays: [stay]) {
                calls += 1
                if calls == 8 { throw CancellationError() }
            }
        }
        #expect(calls == 8)
    }

    @Test("uncancelled worker preserves the complete aggregate snapshot")
    func workerParity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let index = try #require(H3Service.cellIndex(latitude: 38, longitude: 24))
        let start = now.addingTimeInterval(-4 * 86_400)
        let trip = Trip(startDate: start)
        trip.endDate = now.addingTimeInterval(-86_400)
        trip.isComplete = true
        trip.countryCodes = "GR"
        context.insert(trip)
        let stay = Stay(startTime: start, endTime: trip.endDate!, centroidLatitude: 38,
                        centroidLongitude: 24, h3IndexRes6: index, pingCount: 1,
                        distanceFromHomeKm: 100, pingIDs: [])
        stay.category = .destination
        stay.trip = trip
        stay.locality = "Athens"
        stay.country = "Greece"
        stay.isoCountryCode = "GR"
        context.insert(stay)
        let hex = HexVisit(h3Index: index, firstVisited: start,
                           centerLatitude: 38, centerLongitude: 24)
        hex.country = "Greece"
        hex.isoCountryCode = "GR"
        context.insert(hex)
        try context.save()
        let expected = try StatsAggregator.compute(container: container, now: now)
        let actual = try await StatsAggregator.load(container: container, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This fixture has one member per set; JSON ordering is deterministic.
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        #expect(actual.totalHexes == 1)
        #expect(actual.totalTrips == 1)
        #expect(actual.countryStats.first?.code == "GR")
        #expect(actual.collections.places.count == 1)
        #expect(actual.computeDegraded == nil)
        #expect(!context.hasChanges)
    }
}
