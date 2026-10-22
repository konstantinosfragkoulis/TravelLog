//
//  WrappedMonthCountsTests.swift
//  TravelLogTests
//
//  Wrapped's months card (busiest month, months travelled, month columns)
//  covers every trip the recap admitted, not the narrative's capped 8-trip
//  sample. New recaps store full counts in `WrappedStats.tripStartMonthCounts`;
//  older blobs without them fall back to the narrative start dates only while
//  that list is below the cap, and otherwise show no months card.
//  @MainActor + async: instantiates the `@ModelActor` and builds `@Model`
//  fixtures through a separate ModelContext on the shared in-memory store.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedMonthCountsTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private static func inputs(year: Int, starts: [Date]) -> NarrativeInputs {
        NarrativeInputs(
            year: year, tripDisplayNames: starts.indices.map { "Trip \($0)" }, tripStartDates: starts,
            longestTripName: nil, longestTripDays: nil, farthestPlaceName: nil,
            farthestDistanceKm: nil, firstTimeCountryISOCodes: [])
    }

    @Test("a generated recap stores month counts over every trip of a year with more than eight")
    func generatorCountsEveryTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Stay(startTime: utc(2025, 2, 1), endTime: utc(2025, 2, 1, 13),
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: []))
        let starts = [
            utc(2025, 1, 5), utc(2025, 1, 20), utc(2025, 3, 8), utc(2025, 4, 12),
            utc(2025, 5, 2), utc(2025, 5, 14), utc(2025, 5, 27), utc(2025, 7, 9),
            utc(2025, 9, 18), utc(2025, 11, 22),
        ]
        for (index, start) in starts.enumerated() {
            let trip = Trip(startDate: start)
            trip.endDate = start.addingTimeInterval(86_400)
            trip.isComplete = true
            trip.customName = "Trip \(index)"
            ctx.insert(trip)
        }
        try ctx.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        let outcome = await generator.generateIfNeeded(forYear: 2025)
        #expect(outcome == .created)

        let year = 2025
        let predicate = #Predicate<YearWrapped> { $0.year == year }
        let wrapped = try #require(try ModelContext(container).fetch(
            FetchDescriptor<YearWrapped>(predicate: predicate)).first)
        let stats = try #require(wrapped.statsData.flatMap(WrappedStats.decoded(from:)))

        let expected = [2, 0, 1, 1, 3, 0, 1, 0, 1, 0, 1, 0]
        // The narrative keeps its capped sample; the months card does not use it.
        #expect(stats.narrativeInputs?.tripStartDates.count == YearWrappedGenerator.narrativeTripLineCap)
        #expect(stats.tripStartMonthCounts == expected)
        #expect(WrappedView.tripsPerMonth(stats: stats) == expected)
        #expect(WrappedView.visibleCards(stats: stats, weatherCoverage: 0).contains(.months))
    }

    @Test("stored month counts win over a capped narrative sample")
    func storedCountsWin() {
        var stats = WrappedStats()
        stats.narrativeInputs = Self.inputs(year: 2025, starts: (1...8).map { utc(2025, $0, 3) })
        stats.tripStartMonthCounts = [3, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1]
        #expect(WrappedView.tripsPerMonth(stats: stats) == [3, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1])
    }

    @Test("an older recap below the narrative cap still counts its complete start dates")
    func legacyBelowCapUsesStartDates() {
        var stats = WrappedStats()
        stats.narrativeInputs = Self.inputs(year: 2025, starts: [
            utc(2025, 2, 1), utc(2025, 2, 20), utc(2025, 6, 6), utc(2025, 6, 7),
            utc(2025, 6, 30), utc(2025, 10, 4), utc(2025, 12, 31, 23),
        ])
        #expect(stats.tripStartMonthCounts == nil)
        #expect(WrappedView.tripsPerMonth(stats: stats) == [0, 2, 0, 0, 0, 3, 0, 0, 0, 1, 0, 1])
        #expect(WrappedView.visibleCards(stats: stats, weatherCoverage: 0).contains(.months))
    }

    @Test("an older recap at the narrative cap may hold a sample, so it has no months card")
    func legacyAtCapHidesMonthsCard() {
        var stats = WrappedStats()
        stats.narrativeInputs = Self.inputs(
            year: 2025, starts: (1...YearWrappedGenerator.narrativeTripLineCap).map { utc(2025, $0, 3) })
        #expect(WrappedView.tripsPerMonth(stats: stats) == nil)
        #expect(!WrappedView.visibleCards(stats: stats, weatherCoverage: 0).contains(.months))
    }

    @Test("a blob without the month counts key decodes with nil counts, and the counts round-trip")
    func monthCountsAreForwardCompatible() throws {
        var stats = WrappedStats()
        stats.tripsCompleted = 9
        stats.narrativeInputs = Self.inputs(year: 2025, starts: [utc(2025, 3, 3)])
        let legacyData = try #require(stats.encoded())
        let legacyObject = try #require(try JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(!legacyObject.keys.contains("tripStartMonthCounts"))
        let legacy = try #require(WrappedStats.decoded(from: legacyData))
        #expect(legacy.tripStartMonthCounts == nil)
        #expect(legacy.tripsCompleted == 9)

        stats.tripStartMonthCounts = [0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let current = try #require(stats.encoded().flatMap(WrappedStats.decoded(from:)))
        #expect(current.tripStartMonthCounts == [0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }
}
