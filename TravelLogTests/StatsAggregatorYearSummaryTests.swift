//
//  StatsAggregatorYearSummaryTests.swift
//  TravelLogTests
//
//  Year-scoped stats backing `TravelStatsIntent`. The container variant
//  fetches on its own context; seed contexts must save first.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct StatsAggregatorYearSummaryTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeTrip(
        in context: ModelContext,
        start: Date,
        end: Date?,
        countryCodes: String = ""
    ) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        trip.countryCodes = countryCodes
        context.insert(trip)
        return trip
    }

    private func makeStay(
        in context: ModelContext,
        start: Date,
        category: StayCategory,
        isoCountryCode: String? = nil,
        transitFromPrevious: TransitMode? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "861f01867ffffff",
            pingCount: 4,
            distanceFromHomeKm: 500,
            pingIDs: []
        )
        stay.categoryRaw = category.rawValue
        stay.isoCountryCode = isoCountryCode
        if let transitFromPrevious {
            stay.transitFromPreviousRaw = transitFromPrevious.rawValue
        }
        context.insert(stay)
        return stay
    }

    @Test func yearScopedCountsFilterByYearAndUnionCountrySources() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        // In-year: completed 4-day trip (Oct 7 to 10 inclusive) to GR.
        let grTrip = makeTrip(in: context, start: date(2025, 10, 7), end: date(2025, 10, 10), countryCodes: "GR")
        // Out-of-year completed trip; must not count.
        let jpTrip = makeTrip(in: context, start: date(2024, 10, 7), end: date(2024, 10, 10), countryCodes: "JP")
        // Ongoing travel contributes dates, but not a completed trip or its countries.
        _ = makeTrip(in: context, start: date(2025, 12, 30), end: nil, countryCodes: "US")

        // In-year destination stay contributes FR even though no counted
        // trip's countryCodes carry it (the two-source union). Trip-attached:
        // stay-source countries are trip-membership-gated, so this stay
        // belongs to the GR trip whose codes lack FR.
        let frStay = makeStay(in: context, start: date(2025, 10, 8), category: .destination, isoCountryCode: "FR")
        frStay.trip = grTrip
        // Out-of-year destination stay; excluded by the YEAR filter (trip
        // attached so the membership gate isn't what excludes it).
        let jpStay = makeStay(in: context, start: date(2024, 6, 28), category: .destination, isoCountryCode: "JP")
        jpStay.trip = jpTrip
        // Home stay in-year; not a destination, contributes nothing.
        _ = makeStay(in: context, start: date(2025, 5, 31), category: .home, isoCountryCode: "DE")

        // One in-year flight leg, one out-of-year.
        _ = makeStay(in: context, start: date(2025, 10, 7), category: .transit, transitFromPrevious: .flight)
        _ = makeStay(in: context, start: date(2024, 10, 7), category: .transit, transitFromPrevious: .flight)

        try context.save()

        let summary = try StatsAggregator.yearSummary(container: container, year: 2025, now: date(2026, 1, 1))
        #expect(summary.year == 2025)
        #expect(summary.trips == 1)
        #expect(summary.countries == Set(["GR", "FR"]))
        #expect(summary.daysAbroad == 6) // four October dates plus December 30 and 31
        #expect(summary.flights == 1)
    }

    @Test func buddhistSummaryUsesGregorianLabelYear() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let utc = TravelDays.labelCalendar
        let start = utc.date(from: DateComponents(year: 2025, month: 10, day: 7, hour: 12))!
        let end = utc.date(from: DateComponents(year: 2025, month: 10, day: 10, hour: 12))!
        let trip = makeTrip(in: context, start: start, end: end, countryCodes: "GR")
        let stay = makeStay(in: context, start: start, category: .destination,
                            isoCountryCode: "FR", transitFromPrevious: .flight)
        stay.timeZoneIdentifier = "UTC"
        stay.trip = trip
        try context.save()
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = utc.timeZone
        let summary = try StatsAggregator.yearSummary(container: container, year: 2025,
                                                   calendar: buddhist, now: end)
        #expect(summary.year == 2025)
        #expect(summary.trips == 1)
        #expect(summary.countries == ["GR", "FR"])
        #expect(summary.daysAbroad == 4)
        #expect(summary.flights == 1)
    }

    @Test func emptyYearReturnsZeros() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = makeTrip(in: context, start: date(2024, 10, 7), end: date(2024, 10, 10), countryCodes: "JP")
        try context.save()

        let summary = try StatsAggregator.yearSummary(container: container, year: 2020)
        #expect(summary.trips == 0)
        #expect(summary.countries.isEmpty)
        #expect(summary.daysAbroad == 0)
        #expect(summary.flights == 0)
    }

    @Test func pureReductionSumsDurationsAndSplitsCodes() {
        let tripA = Trip(startDate: date(2025, 5, 9))
        tripA.endDate = date(2025, 5, 11)   // 3 inclusive days
        tripA.isComplete = true
        tripA.countryCodes = "GR,IT"
        let tripB = Trip(startDate: date(2025, 12, 29))
        tripB.endDate = date(2025, 12, 29)    // 1 day minimum
        tripB.isComplete = true
        tripB.countryCodes = ""

        let summary = StatsAggregator.yearSummary(
            completedTrips: [tripA, tripB],
            destinationStays: [],
            flightCount: 2,
            year: 2025
        )
        #expect(summary.trips == 2)
        #expect(summary.daysAbroad == 4)
        #expect(summary.countries == Set(["GR", "IT"]))
        #expect(summary.flights == 2)
    }

    @Test func daysAbroadClampsYearSpanningTripsToTheYearWindow() {
        // Dec 28 2025 → Jan 5 2026 is 9 inclusive days, but
        // only Dec 28 to 31 fall in 2025; the old whole-duration sum leaked
        // next January's days into the start year.
        let trip = Trip(startDate: date(2025, 12, 28))
        trip.endDate = date(2026, 1, 5)
        trip.isComplete = true

        let summary = StatsAggregator.yearSummary(
            completedTrips: [trip],
            destinationStays: [],
            flightCount: 0,
            year: 2025
        )
        #expect(summary.daysAbroad == 4)
    }

    @Test func absurdYearReturnsZeroDaysWithoutTrapping() {
        // The year arrives unclamped from Siri; the
        // pure reduction's `year + 1` trapped on Int.max pre-fix.
        let summary = StatsAggregator.yearSummary(
            completedTrips: [],
            destinationStays: [],
            flightCount: 0,
            year: Int.max
        )
        #expect(summary.daysAbroad == 0)
    }
}
