//
//  TransitInfererReadFailureTests.swift
//  TravelLogTests
//
//  A failed read is not absence, and counts are committed outcomes. The
//  drain used to turn a failed predecessor fetch into the terminal no-leg
//  value (`.unknown`, nil distance) that no later drain revisits, and
//  counted flights before a save that could fail and leave the rows dirty
//  and unretried. The re-passes swallowed read and save errors the same
//  way. Faults are injected per read site through `TransitInferer.TestScope`.
//

import EventKit
import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

@MainActor
struct TransitInfererReadFailureTests {

    private typealias Fixture = TransitInfererRepassRevalidationTests

    nonisolated private static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        Fixture.utc(y, mo, d, h)
    }

    nonisolated private static let predecessorEnd = utc(2025, 6, 1, 12)
    nonisolated private static let targetStart = predecessorEnd.addingTimeInterval(4.6 * 3600)

    private func stays(_ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]))
    }

    /// Mid-Atlantic predecessor (terminal) and a nil-transit target about
    /// 556 km north: deterministically `.unknown` with a stored distance.
    private func oceanLeg(_ container: ModelContainer) throws -> UUID {
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: 30.0, lon: -40.0,
                         start: Self.utc(2025, 6, 1, 8), end: Self.utc(2025, 6, 1, 10),
                         transit: .unknown, km: nil)
        let target = Fixture.makeStay(ctx, lat: 35.0, lon: -40.0,
                                      start: Self.utc(2025, 6, 1, 12), end: Self.utc(2025, 6, 1, 18),
                                      transit: nil, km: nil)
        try ctx.save()
        return target.id
    }

    private func geometryOnly<T: Sendable>(
        _ body: @escaping @Sendable () async -> T
    ) async -> T {
        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await body()
        }
    }

    // MARK: - Drain

    @Test("a failed predecessor read leaves the leg pending instead of committing a terminal no-leg value")
    func predecessorReadFailureLeavesLegPending() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let target = try oceanLeg(container)
        let inferer = TransitInferer(modelContainer: container)

        let failed = await geometryOnly {
            await TransitInferer.TestScope.$readFault.withValue({ site in
                if site == .predecessor { throw CocoaError(.fileReadUnknown) }
            }) {
                await inferer.inferTransitForRecentStaysReportingChanges()
            }
        }

        #expect(failed.failed && failed.fetched == 1)
        #expect(failed.classified == 0 && failed.flights == 0 && !failed.needsPublication)
        let pending = try #require(try stays(container).first { $0.id == target })
        #expect(pending.transitFromPreviousRaw == nil)
        #expect(pending.distanceFromPreviousKm == nil)

        let retry = await geometryOnly { await inferer.inferTransitForRecentStaysReportingChanges() }
        #expect(!retry.failed && retry.fetched == 1 && retry.classified == 1)
        let classified = try #require(try stays(container).first { $0.id == target })
        #expect(classified.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect((540...570).contains(try #require(classified.distanceFromPreviousKm)))
    }

    @Test("a predecessor read failing mid-batch rolls back the whole unit; the retry commits every row")
    func midBatchReadFailureRollsBackUnit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: 30.0, lon: -40.0,
                         start: Self.utc(2025, 6, 1, 8), end: Self.utc(2025, 6, 1, 10),
                         transit: .unknown, km: nil)
        for index in 1...3 {
            Fixture.makeStay(ctx, lat: 30.0 + Double(index), lon: -40.0,
                             start: Self.utc(2025, 6, 1, 8 + 4 * index),
                             end: Self.utc(2025, 6, 1, 10 + 4 * index),
                             transit: nil, km: nil)
        }
        try ctx.save()
        let inferer = TransitInferer(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)

        let failed = await geometryOnly {
            await TransitInferer.TestScope.$readFault.withValue({ site in
                guard site == .predecessor else { return }
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 2 { throw CocoaError(.fileReadUnknown) }
            }) {
                await inferer.inferTransitForRecentStaysReportingChanges()
            }
        }

        #expect(failed.failed && failed.classified == 0)
        #expect(try stays(container).filter { $0.transitFromPreviousRaw == nil }.count == 3)

        let retry = await geometryOnly { await inferer.inferTransitForRecentStaysReportingChanges() }
        #expect(!retry.failed && retry.classified == 3)
        #expect(try stays(container).allSatisfy { $0.transitFromPreviousRaw == TransitMode.unknown.rawValue })
    }

    @Test("a failed batch fetch reports failure without writing")
    func batchFetchFailureCommitsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let target = try oceanLeg(container)
        let inferer = TransitInferer(modelContainer: container)

        let failed = await geometryOnly {
            await TransitInferer.TestScope.$readFault.withValue({ site in
                if site == .drainBatch { throw CocoaError(.fileReadUnknown) }
            }) {
                await inferer.inferTransitForRecentStaysReportingChanges()
            }
        }

        #expect(failed.failed && failed.fetched == 0 && !failed.needsPublication)
        #expect(try stays(container).first { $0.id == target }?.transitFromPreviousRaw == nil)
    }

    @Test("a failed flight save reports no flight, rolls back, and the next drain commits it")
    func failedFlightSaveRollsBackAndRetries() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: Fixture.ath.lat, lon: Fixture.ath.lon,
                         start: Self.utc(2025, 6, 1, 10), end: Self.predecessorEnd,
                         transit: .unknown, km: nil, retainedObservations: true)
        let target = Fixture.makeStay(ctx, lat: Fixture.ams.lat, lon: Fixture.ams.lon,
                                      start: Self.targetStart, end: Self.utc(2025, 6, 1, 22),
                                      transit: nil, km: nil, retainedObservations: true)
        try ctx.save()
        let targetID = target.id
        let inferer = TransitInferer(modelContainer: container)
        let saves = OSAllocatedUnfairLock(initialState: 0)

        let failed = await geometryOnly {
            await inferer.inferTransitForRecentStaysReportingChanges(beforeSave: {
                saves.withLock { $0 += 1 }
                throw CocoaError(.fileWriteUnknown)
            })
        }

        #expect(saves.withLock { $0 } == 1)
        #expect(failed.failed && failed.flights == 0 && failed.classified == 0)
        // Fail-open publication for the dirty attempt is unchanged.
        #expect(failed.needsPublication)
        #expect(try stays(container).first { $0.id == targetID }?.transitFromPreviousRaw == nil)

        // Rolled back, so the row re-enters the nil-transit fetch.
        let retry = await geometryOnly { await inferer.inferTransitForRecentStaysReportingChanges() }
        #expect(!retry.failed && retry.fetched == 1 && retry.flights == 1)
        #expect(try stays(container).first { $0.id == targetID }?.transitFromPreviousRaw
                == TransitMode.flight.rawValue)
    }

    // MARK: - Detect Flights driver

    /// Consecutive nil-transit legs about 11 km apart: `.unknown`, never flights.
    private func seedDrainBacklog(_ container: ModelContainer, count: Int) throws {
        let ctx = ModelContext(container)
        let base = Self.utc(2025, 6, 1, 0)
        for index in 0..<count {
            let start = base.addingTimeInterval(Double(index) * 7200)
            Fixture.makeStay(ctx, lat: 30.0 + Double(index % 2) * 0.1, lon: -40.0,
                             start: start, end: start.addingTimeInterval(3600),
                             transit: nil, km: nil)
        }
        try ctx.save()
    }

    @Test("Detect Flights stops at a failed full batch instead of re-inferring it to the cap",
          .timeLimit(.minutes(1)))
    func detectFlightsStopsOnFailedFullBatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedDrainBacklog(container, count: TransitInferer.inferenceBatchSize)
        let inferer = TransitInferer(modelContainer: container)
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let gate = PipelineGate(forTesting: ())

        let outcome = await geometryOnly {
            await TransitInferer.TestScope.$beforeSave.withValue({
                saves.withLock { $0 += 1 }
                throw CocoaError(.fileWriteUnknown)
            }) {
                await inferer.detectFlights(gate: gate)
            }
        }

        #expect(saves.withLock { $0 } == 1)
        #expect(outcome.failed && !outcome.complete)
        #expect(outcome.analyzed == 0 && outcome.found == 0)
        #expect(try stays(container).allSatisfy { $0.transitFromPreviousRaw == nil })
    }

    @Test("Detect Flights keeps an earlier committed batch and reports the later failure",
          .timeLimit(.minutes(1)))
    func detectFlightsKeepsEarlierCommittedBatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let batch = TransitInferer.inferenceBatchSize
        try seedDrainBacklog(container, count: batch + 1)
        let inferer = TransitInferer(modelContainer: container)
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let gate = PipelineGate(forTesting: ())

        let outcome = await geometryOnly {
            await TransitInferer.TestScope.$beforeSave.withValue({
                let call = saves.withLock { $0 += 1; return $0 }
                if call == 2 { throw CocoaError(.fileWriteUnknown) }
            }) {
                await inferer.detectFlights(gate: gate)
            }
        }

        #expect(outcome.analyzed == batch && outcome.found == 0)
        #expect(outcome.failed && !outcome.complete)
        let rows = try stays(container)
        #expect(rows.filter { $0.transitFromPreviousRaw == nil }.count == 1)
        #expect(rows.filter { $0.transitFromPreviousRaw == TransitMode.unknown.rawValue }.count == batch)
    }

    @Test("Detect Flights completes on a clean backlog")
    func detectFlightsCompletes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedDrainBacklog(container, count: 3)
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())

        let outcome = await geometryOnly { await inferer.detectFlights(gate: gate) }

        #expect(outcome.analyzed == 3 && outcome.found == 0)
        #expect(!outcome.failed && outcome.complete)
    }

    // MARK: - Re-pass reads and applies

    private func runGeometry(
        _ inferer: TransitInferer,
        fault: TransitInferer.ReadSite
    ) async -> TransitInferer.UnknownLegPassOutcome {
        let gate = PipelineGate(forTesting: ())
        let visitedFault = OSAllocatedUnfairLock(initialState: false)
        let outcome = await geometryOnly {
            await TransitInferer.TestScope.$readFault.withValue({ site in
                if site == fault {
                    visitedFault.withLock { $0 = true }
                    throw CocoaError(.fileReadUnknown)
                }
            }) {
                await inferer.reinferUnknownLegsGeometry(gate: gate)
            }
        }
        #expect(visitedFault.withLock { $0 }, "The injected read failure must be reached")
        return outcome
    }

    @Test("a failed unknown-leg scan stops the geometry re-pass as failed, not exhausted")
    func scanFailureStopsRepass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: 30.0, lon: -40.0,
                         start: Self.utc(2025, 6, 1, 8), end: Self.utc(2025, 6, 1, 10),
                         transit: .unknown, km: nil)
        try ctx.save()
        let inferer = TransitInferer(modelContainer: container)

        let outcome = await runGeometry(inferer, fault: .unknownScan)

        #expect(outcome.failed && !outcome.complete && outcome.upgraded == 0)
    }

    @Test("a failed boundary tie fetch stops the batch without advancing the cursor")
    func tieFetchFailureStopsBatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Self.utc(2025, 6, 1, 12)
        for _ in 0..<3 {
            Fixture.makeStay(ctx, lat: 37.9838, lon: 23.7275,
                             start: start, end: start.addingTimeInterval(1800),
                             transit: .unknown, km: nil)
        }
        try ctx.save()
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())

        let result = await geometryOnly {
            await TransitInferer.TestScope.$readFault.withValue({ site in
                if site == .unknownTies { throw CocoaError(.fileReadUnknown) }
            }) {
                await inferer.reinferUnknownLegsGeometryBatch(from: .start, batchSize: 2, gate: gate)
            }
        }

        #expect(result.failed && result.next == nil && result.upgraded == 0)
    }

    /// ATH -> AMS `.unknown` leg with a garbage stored distance.
    private func geometryLeg(_ container: ModelContainer) throws -> UUID {
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: Fixture.ath.lat, lon: Fixture.ath.lon,
                         start: Self.utc(2025, 6, 1, 10), end: Self.predecessorEnd,
                         transit: .unknown, km: nil, retainedObservations: true)
        let target = Fixture.makeStay(ctx, lat: Fixture.ams.lat, lon: Fixture.ams.lon,
                                      start: Self.targetStart, end: Self.utc(2025, 6, 1, 22),
                                      transit: .unknown, km: 9999, retainedObservations: true)
        try ctx.save()
        return target.id
    }

    private func expectUnknown(_ container: ModelContainer, _ id: UUID) throws {
        let row = try #require(try stays(container).first { $0.id == id })
        #expect(row.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(row.distanceFromPreviousKm == 9999)
    }

    @Test("failed predecessor and apply reads upgrade nothing; the retry upgrades the leg",
          arguments: [TransitInferer.ReadSite.predecessor, .applyTargets])
    func repassReadFailureRetries(site: TransitInferer.ReadSite) async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let target = try geometryLeg(container)
        let inferer = TransitInferer(modelContainer: container)

        let failed = await runGeometry(inferer, fault: site)
        #expect(failed.failed && !failed.complete && failed.upgraded == 0)
        try expectUnknown(container, target)

        let gate = PipelineGate(forTesting: ())
        let retry = await geometryOnly { await inferer.reinferUnknownLegsGeometry(gate: gate) }
        #expect(!retry.failed && retry.complete && retry.upgraded == 1)
    }

    @Test("a failed geometry apply save counts nothing and leaves the leg retryable")
    func geometryApplySaveFailureRetries() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let target = try geometryLeg(container)
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let saves = OSAllocatedUnfairLock(initialState: 0)

        let failed = await geometryOnly {
            await TransitInferer.TestScope.$beforeSave.withValue({
                saves.withLock { $0 += 1 }
                throw CocoaError(.fileWriteUnknown)
            }) {
                await inferer.reinferUnknownLegsGeometry(gate: gate)
            }
        }
        #expect(saves.withLock { $0 } == 1)
        #expect(failed.failed && failed.upgraded == 0)
        try expectUnknown(container, target)

        let retry = await geometryOnly { await inferer.reinferUnknownLegsGeometry(gate: gate) }
        #expect(retry.upgraded == 1)
        #expect(try stays(container).first { $0.id == target }?.transitFromPreviousRaw
                == TransitMode.flight.rawValue)
    }

    @Test("a failed calendar apply save counts nothing and leaves the leg retryable")
    func calendarApplySaveFailureRetries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Fixture.makeStay(ctx, lat: 30.0, lon: -40.0,
                         start: Self.utc(2025, 6, 1, 8), end: Self.utc(2025, 6, 1, 10),
                         transit: .unknown, km: nil)
        let target = Fixture.makeStay(ctx, lat: 31.35, lon: -40.0,
                                      start: Self.utc(2025, 6, 1, 12), end: Self.utc(2025, 6, 1, 18),
                                      transit: .unknown, km: 42)
        try ctx.save()
        let targetID = target.id
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())

        func run(failing: Bool) async -> TransitInferer.UnknownLegPassOutcome {
            await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
                await TransitInferer.TestScope.$corroborates.withValue({ _, _ in true }) {
                    await TransitInferer.TestScope.$beforeSave.withValue({
                        if failing { throw CocoaError(.fileWriteUnknown) }
                    }) {
                        await inferer.recorroborateUnknownLegs(gate: gate)
                    }
                }
            }
        }

        let failed = await run(failing: true)
        #expect(failed.failed && failed.upgraded == 0)
        let pending = try #require(try stays(container).first { $0.id == targetID })
        #expect(pending.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(pending.distanceFromPreviousKm == 42)

        let retry = await run(failing: false)
        #expect(!retry.failed && retry.upgraded == 1)
        #expect(try stays(container).first { $0.id == targetID }?.transitFromPreviousRaw
                == TransitMode.flight.rawValue)
    }

    // MARK: - Settings result text

    @Test("an unfinished run keeps committed counts but never claims nothing was found")
    func unfinishedRunsNeverClaimNothingFound() {
        #expect(SettingsView.flightDetectText(analyzed: 0, found: 0, unfinished: true).isEmpty)
        #expect(!SettingsView.flightDetectText(analyzed: 0, found: 0, unfinished: false).isEmpty)
        #expect(SettingsView.flightDetectText(analyzed: 50, found: 0, unfinished: true)
                != SettingsView.flightDetectText(analyzed: 50, found: 0, unfinished: false))
        #expect(!SettingsView.flightDetectText(analyzed: 50, found: 0, unfinished: true).isEmpty)
        #expect(SettingsView.flightDetectText(analyzed: 0, found: 2, unfinished: true)
                == SettingsView.flightDetectText(analyzed: 0, found: 2, unfinished: false))

        #expect(SettingsView.resultText(flights: 0, unfinished: true).isEmpty)
        #expect(!SettingsView.resultText(flights: 0, unfinished: false).isEmpty)
        #expect(SettingsView.resultText(flights: 1, unfinished: true)
                == SettingsView.resultText(flights: 1, unfinished: false))
    }
}
