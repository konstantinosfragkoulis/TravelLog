//
//  StatsYearLedgerTests.swift
//  TravelLogTests
//
//  The per-year ledger, favourite month and days-per-country aggregates
//  behind the Stats page's "By Year" card, Records tiles and country
//  captions (2026-09). All three derive from one travel-day set walk.
//
//  UTC calendar throughout so day-boundary fixtures cannot flake on the
//  runner's time zone. `@MainActor` because `@Model` types are
//  MainActor-isolated under the app target's default isolation.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct StatsYearLedgerTests {

    // MARK: - Fixtures

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeTrip(_ start: Date, _ end: Date?, codes: String = "") -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        trip.countryCodes = codes
        return trip
    }

    private func makeDestinationStay(
        _ start: Date, _ end: Date, iso: String, in context: ModelContext, trip: Trip?
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 100, pingIDs: []
        )
        stay.category = .destination
        stay.isoCountryCode = iso
        stay.country = iso
        context.insert(stay)
        stay.trip = trip
        return stay
    }

    // MARK: - Year ledger

    @Test("days bucket by year; trips and countries by completed start year; ascending")
    func yearLedger() {
        let trips = [
            // Straddles New Year: 2 days in 2024, 2 in 2025; the trip and
            // its countries belong to its start year.
            makeTrip(date(2024, 12, 30), date(2025, 1, 2), codes: "GR,IT"),
            makeTrip(date(2025, 6, 1), date(2025, 6, 3), codes: "FR"),
            // Ongoing: its elapsed days count, the trip and country do not
            // until it completes.
            makeTrip(date(2025, 8, 1), nil, codes: "ES"),
        ]
        let now = date(2025, 8, 2)

        let days = StatsAggregator.travelDaySet(trips: trips, now: now, calendar: utc)
        let ledger = StatsAggregator.yearStats(
            days: days, completedTrips: trips.filter(\.isComplete), calendar: utc)

        #expect(ledger.map(\.year) == [2024, 2025])
        #expect(ledger[0] == StatsAggregator.YearStat(year: 2024, trips: 1, days: 2, countries: 2))
        #expect(ledger[1] == StatsAggregator.YearStat(year: 2025, trips: 1, days: 2 + 3 + 2, countries: 1))
    }

    @Test("the lifetime counters still come from the same day set")
    func lifetimeCountersAgreeWithTheSet() {
        let trips = [
            makeTrip(date(2024, 12, 30), date(2025, 1, 2)),
            makeTrip(date(2025, 6, 1), date(2025, 6, 3)),
        ]
        let now = date(2025, 8, 2)
        let counters = StatsAggregator.travelDays(trips: trips, now: now, calendar: utc)
        #expect(counters.total == 7)
        #expect(counters.thisYear == 5)
    }

    @Test("Buddhist calendars keep June trips and days in one Gregorian row")
    func buddhistLedgerUsesGregorianLabels() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = utc.timeZone
        let trip = makeTrip(date(2025, 6, 10), date(2025, 6, 13), codes: "GR")
        let days = StatsAggregator.travelDaySet(trips: [trip], now: date(2025, 7, 1), calendar: buddhist)
        let ledger = StatsAggregator.yearStats(days: days, completedTrips: [trip], calendar: buddhist)
        #expect(ledger == [.init(year: 2025, trips: 1, days: 4, countries: 1)])
    }

    @Test("Gregorian June renders June even with an Islamic calendar")
    func islamicCalendarMonthName() throws {
        var islamic = Calendar(identifier: .islamicUmmAlQura)
        islamic.timeZone = utc.timeZone
        let trip = makeTrip(date(2025, 6, 10), date(2025, 6, 13))
        let days = StatsAggregator.travelDaySet(trips: [trip], now: date(2025, 7, 1), calendar: islamic)
        let favorite = try #require(StatsAggregator.favoriteMonth(days: days, calendar: islamic))
        #expect(favorite.month == 6)
        #expect(favorite.days == 4)
        #expect(StatsView.monthName(favorite.month, locale: Locale(identifier: "en")) == "June")
    }

    @Test("current-year selection uses today's Gregorian label in the injected zone")
    func currentYearUsesGregorianLocalLabel() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(2025, 1, 1, hour: 6)
        #expect(StatsYearCard.currentYear(now: now, calendar: buddhist) == 2024)
        buddhist.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        #expect(StatsYearCard.currentYear(now: now, calendar: buddhist) == 2025)
    }

    @Test("trip start labels use the injected fallback when there are no boundary stays")
    func tripStartUsesFallbackZone() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let trip = makeTrip(date(2025, 1, 1, hour: 6), date(2025, 1, 1, hour: 7))
        let days = StatsAggregator.travelDaySet(trips: [trip], now: date(2025, 1, 5), calendar: buddhist)
        #expect(StatsAggregator.yearStats(days: days, completedTrips: [trip], calendar: buddhist)
                == [.init(year: 2024, trips: 1, days: 1, countries: 0)])
    }

    // MARK: - Favourite month

    @Test("favourite month pools every year and breaks ties on the earlier month")
    func favoriteMonth() {
        let trips = [
            makeTrip(date(2024, 3, 10), date(2024, 3, 12)),   // March: 3
            makeTrip(date(2025, 3, 1), date(2025, 3, 1)),     // March: 4
            makeTrip(date(2025, 7, 1), date(2025, 7, 4)),     // July: 4 — tie
        ]
        let days = StatsAggregator.travelDaySet(trips: trips, now: date(2026, 1, 1), calendar: utc)

        let favourite = StatsAggregator.favoriteMonth(days: days, calendar: utc)
        #expect(favourite?.month == 3)
        #expect(favourite?.days == 4)
        #expect(StatsAggregator.favoriteMonth(days: [], calendar: utc) == nil)
    }

    // MARK: - Days per country

    @Test("country days are distinct calendar days from trip destination stays only")
    func daysByCountry() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(date(2025, 5, 1), date(2025, 5, 6), codes: "GR,IT")
        context.insert(trip)

        let stays = [
            // May 1, 2, 3
            makeDestinationStay(date(2025, 5, 1, hour: 18), date(2025, 5, 3, hour: 9), iso: "GR", in: context, trip: trip),
            // May 3 again — a second stay on the same day counts once.
            makeDestinationStay(date(2025, 5, 3, hour: 12), date(2025, 5, 3, hour: 20), iso: "GR", in: context, trip: trip),
            // May 4, 5
            makeDestinationStay(date(2025, 5, 4), date(2025, 5, 5), iso: "IT", in: context, trip: trip),
            // Tripless destination residue never stamps a country.
            makeDestinationStay(date(2025, 5, 9), date(2025, 5, 10), iso: "GR", in: context, trip: nil),
        ]

        let byCountry = StatsAggregator.daysByCountry(destinationStays: stays, calendar: utc)
        #expect(byCountry == ["GR": 3, "IT": 2])
    }

    @Test("country days read each stay's own zone, not the viewer's")
    func daysByCountryUsesStayZones() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(date(2025, 7, 1), date(2025, 7, 5), codes: "JP,AU")
        context.insert(trip)

        // Jul 1 15:00 to Jul 4 10:00 JST: four Tokyo days.
        let tokyo = makeDestinationStay(date(2025, 7, 1, hour: 6), date(2025, 7, 4, hour: 1), iso: "JP", in: context, trip: trip)
        tokyo.timeZoneIdentifier = "Asia/Tokyo"
        // Jul 2 09:00 to 20:00 AEST: one Sydney day.
        let sydney = makeDestinationStay(date(2025, 7, 1, hour: 23), date(2025, 7, 2, hour: 10), iso: "AU", in: context, trip: trip)
        sydney.timeZoneIdentifier = "Australia/Sydney"

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(StatsAggregator.daysByCountry(destinationStays: [tokyo, sydney], calendar: newYork) == ["JP": 4, "AU": 1])
        #expect(StatsAggregator.daysByCountry(destinationStays: [tokyo, sydney], calendar: utc) == ["JP": 4, "AU": 1])
    }

    // MARK: - End to end

    @Test("aggregate carries the ledger, the favourite month and the country days")
    func aggregateCarriesTheNewFields() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(date(2025, 5, 1), date(2025, 5, 6), codes: "GR")
        context.insert(trip)
        let stays = [
            makeDestinationStay(date(2025, 5, 1, hour: 18), date(2025, 5, 3, hour: 9), iso: "GR", in: context, trip: trip),
        ]

        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [trip],
            hexVisits: [], totalPings: 0, totalStays: stays.count,
            flightCount: 0, trackingSince: nil,
            now: date(2025, 6, 1), calendar: utc
        )

        #expect(result.yearStats == [StatsAggregator.YearStat(year: 2025, trips: 1, days: 6, countries: 1)])
        #expect(result.favoriteMonth == 5)
        #expect(result.favoriteMonthDays == 6)
        #expect(result.countryStats.first { $0.code == "GR" }?.days == 3)
        #expect(result.travelDaysTotal == 6)
    }

    @Test("aggregate honors the injected calendar for country day boundaries")
    func aggregateHonorsInjectedCalendar() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = date(2025, 5, 1, hour: 20)
        let end = date(2025, 5, 1, hour: 23, minute: 30)
        let trip = makeTrip(start, end, codes: "GR")
        context.insert(trip)
        let stays = [
            makeDestinationStay(start, end, iso: "GR", in: context, trip: trip),
        ]

        func days(in calendar: Calendar) -> Int? {
            StatsAggregator.aggregate(
                visitedStays: stays, transitStays: [], trips: [trip],
                hexVisits: [], totalPings: 0, totalStays: stays.count,
                flightCount: 0, trackingSince: nil,
                now: date(2025, 6, 1), calendar: calendar
            ).countryStats.first { $0.code == "GR" }?.days
        }
        // Two calendars that disagree on the day boundary: the pre-fix
        // shadowing `Calendar.current` could satisfy at most one of them,
        // whatever the runner's zone.
        var plusThree = Calendar(identifier: .gregorian)
        plusThree.timeZone = TimeZone(secondsFromGMT: 3 * 3_600)!

        #expect(days(in: utc) == 1)
        #expect(days(in: plusThree) == 2)
    }

    // MARK: - Snapshot forward-compat

    @Test("a snapshot written before these fields existed decodes with them nil")
    func snapshotWithoutTheFieldsStillDecodes() throws {
        let stat = try JSONDecoder().decode(
            CountryStat.self,
            from: Data(#"{"code":"GR","name":"Greece","tripCount":2,"isHome":false}"#.utf8))
        #expect(stat.days == nil)
        #expect(stat.tripCount == 2)

        var aggregates = StatsAggregator.Aggregates()
        aggregates.yearStats = [StatsAggregator.YearStat(year: 2025, trips: 1, days: 3, countries: 1)]
        aggregates.favoriteMonth = 5
        aggregates.favoriteMonthDays = 3
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregates)) as? [String: Any])
        for key in ["yearStats", "favoriteMonth", "favoriteMonthDays"] {
            object.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StatsAggregator.Aggregates.self, from: stripped)
        #expect(decoded.yearStats == nil)
        #expect(decoded.favoriteMonth == nil)
        #expect(decoded.favoriteMonthDays == nil)
    }
}
