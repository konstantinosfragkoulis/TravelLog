//
//  StatsReadFailureTests.swift
//  TravelLogTests
//
//  A failed required read is not an empty history.
//  The Siri Travel Stats loader must throw IntentDataError instead of
//  answering "no trips", and a degraded Stats compute must be rejected by the
//  refresh decision, cold page or not, and never make the passport shareable.
//  Failures are injected by name through the aggregator's task-local read
//  hook, which both loaders re-install on their detached workers.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
@MainActor
@Suite("Stats and Siri read failures")
struct StatsReadFailureTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// One completed 2025 trip to France with a flight leg in, plus a home
    /// stay, so every summary and compute read has rows behind it.
    private func seededContainer() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: utc(2025, 5, 4))
        trip.endDate = utc(2025, 5, 8)
        trip.isComplete = true
        trip.countryCodes = "FR"
        context.insert(trip)
        let destination = Stay(
            startTime: utc(2025, 5, 4), endTime: utc(2025, 5, 7),
            centroidLatitude: 48.85, centroidLongitude: 2.35, h3IndexRes6: "86paris",
            pingCount: 1, distanceFromHomeKm: 2_000, pingIDs: [], timeZoneIdentifier: "Europe/Paris")
        context.insert(destination)
        destination.category = .destination
        destination.isoCountryCode = "FR"
        destination.transitMode = .flight
        destination.trip = trip
        let home = Stay(
            startTime: utc(2025, 4, 3), endTime: utc(2025, 4, 4),
            centroidLatitude: 37.98, centroidLongitude: 23.73, h3IndexRes6: "86athens",
            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], timeZoneIdentifier: "Europe/Athens")
        context.insert(home)
        home.category = .home
        home.isoCountryCode = "GR"
        try context.save()
        return container
    }

    private func failing(_ target: StatsAggregator.Read) -> @Sendable (StatsAggregator.Read) throws -> Void {
        { read in
            if read == target { throw CocoaError(.fileReadUnknown) }
        }
    }

    // MARK: - Siri Travel Stats

    @Test("a failed lifetime read makes Siri report unavailable, never an empty answer",
          arguments: StatsAggregator.Read.lifetimeReads)
    func lifetimeReadFailureIsUnavailable(read: StatsAggregator.Read) async throws {
        let container = try seededContainer()
        await #expect(throws: IntentDataError.unavailable) {
            try await StatsAggregator.$readFailureForTesting.withValue(failing(read)) {
                try await TravelStatsSummaryLoader.passportSummary(
                    container: container, isPersistentStore: true)
            }
        }
        // The helper itself propagates the storage error instead of zeroing it.
        #expect(throws: CocoaError.self) {
            try StatsAggregator.$readFailureForTesting.withValue(failing(read)) {
                try StatsAggregator.passportSummary(container: container)
            }
        }
    }

    @Test("a failed year read makes Siri report unavailable, never an empty year",
          arguments: StatsAggregator.Read.yearReads)
    func yearReadFailureIsUnavailable(read: StatsAggregator.Read) async throws {
        let container = try seededContainer()
        await #expect(throws: IntentDataError.unavailable) {
            try await StatsAggregator.$readFailureForTesting.withValue(failing(read)) {
                try await TravelStatsSummaryLoader.yearSummary(
                    2025, container: container, isPersistentStore: true)
            }
        }
        #expect(throws: CocoaError.self) {
            try StatsAggregator.$readFailureForTesting.withValue(failing(read)) {
                try StatsAggregator.yearSummary(container: container, year: 2025)
            }
        }
    }

    @Test("the in-memory fallback store is refused before any read")
    func fallbackStoreIsRefusedWithoutReading() async throws {
        let container = try seededContainer()
        let log = OSAllocatedUnfairLock(initialState: [StatsAggregator.Read]())
        let recording: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        await StatsAggregator.$readFailureForTesting.withValue(recording) {
            await #expect(throws: IntentDataError.unavailable) {
                try await TravelStatsSummaryLoader.passportSummary(
                    container: container, isPersistentStore: false)
            }
            await #expect(throws: IntentDataError.unavailable) {
                try await TravelStatsSummaryLoader.yearSummary(
                    2025, container: container, isPersistentStore: false)
            }
        }
        #expect(log.withLock { $0 }.isEmpty)
    }

    @Test("healthy reads answer through the loader exactly as the direct summaries do")
    func healthyLoaderMatchesDirectSummaries() async throws {
        let container = try seededContainer()
        let log = OSAllocatedUnfairLock(initialState: [StatsAggregator.Read]())
        let recording: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        let lifetime = try await StatsAggregator.$readFailureForTesting.withValue(recording) {
            try await TravelStatsSummaryLoader.passportSummary(container: container, isPersistentStore: true)
        }
        // The hook really reached the detached worker, once per read.
        #expect(log.withLock { $0 } == StatsAggregator.Read.lifetimeReads)
        let direct = try StatsAggregator.passportSummary(container: container)
        #expect(lifetime.countries == direct.countries)
        #expect(lifetime.countries == ["FR", "GR"])
        #expect(lifetime.trips == 1)
        #expect(lifetime.flights == 1)
        #expect(lifetime.daysAbroad == direct.daysAbroad)

        let year = try await TravelStatsSummaryLoader.yearSummary(
            2025, container: container, isPersistentStore: true)
        let directYear = try StatsAggregator.yearSummary(container: container, year: 2025)
        #expect(year == directYear)
        #expect(year.trips == 1)
        #expect(year.countries == ["FR"])
    }

    @Test("a healthy empty store is still an ordinary empty answer")
    func healthyEmptyStoreIsEmpty() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let lifetime = try await TravelStatsSummaryLoader.passportSummary(
            container: container, isPersistentStore: true)
        #expect(lifetime.countries.isEmpty)
        #expect(lifetime.trips == 0)
        #expect(lifetime.daysAbroad == 0)
        let year = try await TravelStatsSummaryLoader.yearSummary(
            2025, container: container, isPersistentStore: true)
        #expect(year == StatsAggregator.YearSummary(year: 2025))
    }

    @Test("an out-of-range year stays input validation: empty, with no read")
    func invalidYearReadsNothing() async throws {
        let container = try seededContainer()
        let log = OSAllocatedUnfairLock(initialState: [StatsAggregator.Read]())
        let recording: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        let summary = try await StatsAggregator.$readFailureForTesting.withValue(recording) {
            try await TravelStatsSummaryLoader.yearSummary(
                20_000, container: container, isPersistentStore: true)
        }
        #expect(summary == StatsAggregator.YearSummary(year: 20_000))
        #expect(log.withLock { $0 }.isEmpty)
    }

    @Test("cancellation stays cancellation, never the unavailable answer")
    func cancellationIsNotUnavailable() async throws {
        let container = try seededContainer()
        let cancelInside: @Sendable (StatsAggregator.Read) throws -> Void = { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await StatsAggregator.$readFailureForTesting.withValue(cancelInside) {
                try await TravelStatsSummaryLoader.passportSummary(
                    container: container, isPersistentStore: true)
            }
        }
        let cancelledCaller = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await TravelStatsSummaryLoader.yearSummary(
                    2025, container: container, isPersistentStore: true)
                return "answered"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other"
            }
        }.value
        #expect(cancelledCaller == "cancelled")
    }

    // MARK: - Stats page compute

    @Test("any failed compute read is degraded and rejected, cold page or not",
          arguments: StatsAggregator.Read.computeReads)
    func degradedComputeIsRejected(read: StatsAggregator.Read) async throws {
        let container = try seededContainer()
        let result = try await StatsAggregator.$readFailureForTesting.withValue(failing(read)) {
            try await StatsAggregator.load(container: container, now: utc(2026, 1, 1))
        }
        #expect(result.computeDegraded == true)
        #expect(StatsRefreshDecision(computeDegraded: result.computeDegraded, pendingSaveOwed: false)
            == .rejectAndRetry)
        #expect(StatsRefreshDecision(computeDegraded: result.computeDegraded, pendingSaveOwed: true)
            == .rejectAndRetry)
    }

    @Test("a healthy compute is complete and marks the token current")
    func healthyComputeApplies() async throws {
        let container = try seededContainer()
        let result = try await StatsAggregator.load(container: container, now: utc(2026, 1, 1))
        #expect(result.computeDegraded == nil)
        #expect(result.totalTrips == 1)
        #expect(StatsRefreshDecision(computeDegraded: result.computeDegraded, pendingSaveOwed: false)
            == .applyAndMarkCurrent)

        let empty = try await StatsAggregator.load(container: TestSupport.makeInMemoryContainer())
        #expect(empty.computeDegraded == nil)
        #expect(StatsRefreshDecision(computeDegraded: empty.computeDegraded, pendingSaveOwed: false)
            == .applyAndMarkCurrent)
    }

    @Test("cancellation inside a compute read is not a degraded snapshot")
    func computeCancellationThrows() async throws {
        let container = try seededContainer()
        let cancelInside: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            if read == .trips { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            try await StatsAggregator.$readFailureForTesting.withValue(cancelInside) {
                try await StatsAggregator.load(container: container)
            }
        }
    }

    @Test("refresh decision truth table")
    func refreshDecisionTable() {
        #expect(StatsRefreshDecision(computeDegraded: nil, pendingSaveOwed: false) == .applyAndMarkCurrent)
        #expect(StatsRefreshDecision(computeDegraded: false, pendingSaveOwed: false) == .applyAndMarkCurrent)
        #expect(StatsRefreshDecision(computeDegraded: nil, pendingSaveOwed: true) == .applyAndRetry)
        #expect(StatsRefreshDecision(computeDegraded: true, pendingSaveOwed: false) == .rejectAndRetry)
        #expect(StatsRefreshDecision(computeDegraded: true, pendingSaveOwed: true) == .rejectAndRetry)
    }

    @Test("the passport is shareable only from complete aggregates")
    func passportShareGate() {
        var rememberedOnly = PassportData()
        rememberedOnly.countries = 3
        #expect(!rememberedOnly.isShareable(aggregatesComplete: false))
        #expect(rememberedOnly.isShareable(aggregatesComplete: true))
        #expect(!PassportData().isShareable(aggregatesComplete: true))
        #expect(!PassportData().isShareable(aggregatesComplete: false))
    }
}
#endif
