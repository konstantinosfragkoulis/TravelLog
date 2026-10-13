//
//  WrappedGenerationFailureTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator failure contract: a failed read,
//  encoding or save returns `.failed`, commits nothing and leaves nothing
//  pending in the long-lived actor context, so the next request retries
//  from scratch instead of reporting the unsaved row as `.existing`. Every
//  call goes through a `PipelineGate.runReturning(touching: [.yearWrapped])`
//  unit, the same wrapper Settings and the notification tap use. Faults are
//  injected per generator instance through `setFaultForTesting`.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedGenerationFailureTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// 2025 passes the minimum-data gate: an early stay and three completed
    /// trips.
    private func makeEligibleContainer() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = utc(2025, 3, 1).addingTimeInterval(2_419_200)
        context.insert(Stay(startTime: start, endTime: start.addingTimeInterval(3_600),
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "wrapped-failure", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: []))
        for (index, name) in ["Athens", "Cephalonia", "Berlin"].enumerated() {
            let tripStart = utc(2025, 4 + index, 1).addingTimeInterval(2_419_200)
            let trip = Trip(startDate: tripStart)
            trip.endDate = tripStart.addingTimeInterval(2 * 86_400)
            trip.isComplete = true
            trip.customName = name
            context.insert(trip)
        }
        try context.save()
        return container
    }

    private func committedRows(_ container: ModelContainer, year: Int = 2025) throws -> [YearWrapped] {
        let y = year
        return try ModelContext(container).fetch(
            FetchDescriptor<YearWrapped>(predicate: #Predicate { $0.year == y }))
    }

    private func generate(
        _ generator: YearWrappedGenerator, gate: PipelineGate, year: Int = 2025
    ) async -> WrappedGenerationOutcome {
        await gate.runReturning(touching: [.yearWrapped]) {
            await generator.generateIfNeeded(forYear: year)
        }
    }

    @Test("most visited country counts every distinct country on each trip")
    func mostVisitedCountryIncludesSecondaryCodes() async throws {
        let container = try makeEligibleContainer()
        let context = ModelContext(container)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        for trip in trips { trip.countryCodes = "FR, IT,IT,, " }
        for index in 0..<2 {
            let trip = Trip(startDate: utc(2025, 8 + index, 1))
            trip.endDate = utc(2025, 8 + index, 3)
            trip.isComplete = true
            trip.countryCodes = "ES,IT"
            context.insert(trip)
        }
        try context.save()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generate(generator, gate: PipelineGate(forTesting: ())) == .created)
        let blob = try #require(try committedRows(container).first?.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(stats.mostVisitedCountryCode == "IT")
        #expect(stats.mostVisitedCountryTripCount == 5)
    }

    @Test("most visited country ties choose the lexicographically smaller code")
    func mostVisitedCountryTieIsLexicographic() async throws {
        let container = try makeEligibleContainer()
        let context = ModelContext(container)
        for trip in try context.fetch(FetchDescriptor<Trip>()) { trip.countryCodes = "IT,FR" }
        try context.save()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generate(generator, gate: PipelineGate(forTesting: ())) == .created)
        let blob = try #require(try committedRows(container).first?.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(stats.mostVisitedCountryCode == "FR")
        #expect(stats.mostVisitedCountryTripCount == 3)
    }

    @Test("a failed save rolls back, a retry with the fault still armed fails again, and a clean retry commits")
    func failedSaveRollsBackAndRetryCommits() async throws {
        let container = try makeEligibleContainer()
        let gate = PipelineGate(forTesting: ())
        let generator = YearWrappedGenerator(modelContainer: container)
        await generator.setFaultForTesting { step in
            if step == .save { throw CocoaError(.fileWriteUnknown) }
        }

        #expect(await generate(generator, gate: gate) == .failed)
        #expect(try committedRows(container).isEmpty)

        // The regression: the unsaved insert used to stay pending in the
        // actor's context, so this call found it and reported a recap the
        // store never received.
        #expect(await generate(generator, gate: gate) == .failed)
        #expect(try committedRows(container).isEmpty)

        await generator.setFaultForTesting(nil)
        #expect(await generate(generator, gate: gate) == .created)
        let rows = try committedRows(container)
        #expect(rows.count == 1)
        let blob = try #require(rows.first?.statsData)
        #expect(WrappedStats.decoded(from: blob)?.tripsCompleted == 3)

        #expect(await generate(generator, gate: gate) == .existing)
        #expect(try committedRows(container).count == 1)
    }

    @Test("every required read, the encoding and the save fail closed with nothing committed",
          arguments: [
              YearWrappedGenerator.Step.existingRead, .thresholdRead, .staysRead,
              .tripsRead, .travelDaysRead, .awayDaysRead, .homeAnchorsRead,
              .priorCountriesRead, .hexCountRead, .encode, .save,
          ])
    func eachStepFailsClosed(step failing: YearWrappedGenerator.Step) async throws {
        let container = try makeEligibleContainer()
        let gate = PipelineGate(forTesting: ())
        let generator = YearWrappedGenerator(modelContainer: container)
        await generator.setFaultForTesting { step in
            if step == failing { throw CocoaError(.fileReadUnknown) }
        }

        // Not `.insufficientData`: a failed count is not too little travel,
        // and a failed lookup is neither "no row" nor "a row exists".
        #expect(await generate(generator, gate: gate) == .failed)
        #expect(try committedRows(container).isEmpty)

        await generator.setFaultForTesting(nil)
        #expect(await generate(generator, gate: gate) == .created)
        let rows = try committedRows(container)
        #expect(rows.count == 1)
        #expect(rows.first?.statsData.flatMap(WrappedStats.decoded(from:)) != nil)
    }

    @Test("a failed DEBUG regeneration keeps the original recap",
          arguments: [YearWrappedGenerator.Step.existingRead, .staysRead, .encode, .save])
    func failedForceRegenerateKeepsOriginal(step failing: YearWrappedGenerator.Step) async throws {
        let container = try makeEligibleContainer()
        let seed = ModelContext(container)
        let original = YearWrapped(year: 2025)
        original.yearNarrative = "Original"
        seed.insert(original)
        try seed.save()
        let originalID = original.id

        let gate = PipelineGate(forTesting: ())
        let generator = YearWrappedGenerator(modelContainer: container)
        await generator.setFaultForTesting { step in
            if step == failing { throw CocoaError(.fileWriteUnknown) }
        }
        let failed = await gate.runReturning(touching: [.yearWrapped]) {
            await generator.forceRegenerate(forYear: 2025)
        }
        #expect(!failed)
        var rows = try committedRows(container)
        #expect(rows.map(\.id) == [originalID])
        #expect(rows.first?.yearNarrative == "Original")

        // Nothing pending either: the original is still the existing row.
        await generator.setFaultForTesting(nil)
        #expect(await generate(generator, gate: gate) == .existing)
        rows = try committedRows(container)
        #expect(rows.map(\.id) == [originalID])

        // A clean regeneration replaces it in one save.
        let regenerated = await gate.runReturning(touching: [.yearWrapped]) {
            await generator.forceRegenerate(forYear: 2025)
        }
        #expect(regenerated)
        rows = try committedRows(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id != originalID)
        #expect(rows.first?.statsData.flatMap(WrappedStats.decoded(from:))?.tripsCompleted == 3)
    }
}
