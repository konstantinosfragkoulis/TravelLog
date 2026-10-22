//
//  TripFiltersUpgradeTests.swift
//  TravelLogTests
//
//  Saved trip filters from builds that matched years in the device calendar
//  (format 1, no `formatVersion`) are upgraded once to Gregorian years.
//  Each test owns an isolated UserDefaults suite.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripFiltersUpgradeTests {

    /// Earlier builds read years with `Calendar.current`, in the current time zone.
    private func deviceCalendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .current
        return calendar
    }

    private func gregorianDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        TripFilters.yearCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "TripFiltersUpgradeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("a Buddhist year saved by the previous build still shows that year's trips")
    func buddhistYearSurvivesUpgrade() throws {
        try withIsolatedDefaults { defaults in
            // Frozen shape the previous build saved after picking 2569 (2026) on a Buddhist calendar.
            defaults.set(#"{"years":[2569],"countryCodes":["TH"],"durations":[],"requiresPhotos":false}"#,
                         forKey: "tripFiltersJSON")

            let filters = TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: deviceCalendar(.buddhist))
            #expect(filters.years == [2026])
            #expect(filters.countryCodes == ["TH"])

            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            func trip(_ start: Date, _ codes: String) -> Trip {
                let trip = Trip(startDate: start)
                trip.countryCodes = codes
                context.insert(trip)
                return trip
            }
            let first = trip(gregorianDate(2026, 1, 1), "TH")
            let last = trip(gregorianDate(2026, 12, 31, 23, 59), "TH")
            let before = trip(gregorianDate(2025, 12, 31, 23, 59), "TH")
            let elsewhere = trip(gregorianDate(2026, 6, 1), "GR")
            let kept = filters.apply(to: [first, last, before, elsewhere], photoService: .shared)
            #expect(kept.map(\.id) == [first.id, last.id])

            // Saved back once: a later calendar change cannot reinterpret it.
            #expect(TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: deviceCalendar(.gregorian)) == filters)
        }
    }

    @Test("mapped calendars keep exactly the dates the previous build matched",
          arguments: [Calendar.Identifier.gregorian, .iso8601, .buddhist, .republicOfChina])
    func mappedYearsMatchTheSameDates(identifier: Calendar.Identifier) {
        let legacy = deviceCalendar(identifier)
        let gregorian = TripFilters.yearCalendar
        // First and last minute of each year, where an offset or straddling year would slip.
        let dates = (2020...2027).flatMap { [gregorianDate($0, 1, 1), gregorianDate($0, 12, 31, 23, 59)] }
        // Selections the previous build's picker offered for these dates.
        let offered = TripsListView.computeAvailableYears(startDates: dates, calendar: legacy)
        for selection in [Set(offered), Set(offered.prefix(1)), Set(offered.suffix(3))] {
            let years = TripFilters.gregorianYears(fromLegacy: selection, deviceCalendar: legacy)
            let matchedBefore = dates.filter { selection.contains(legacy.component(.year, from: $0)) }
            let matchedAfter = dates.filter { years.contains(gregorian.component(.year, from: $0)) }
            #expect(!matchedBefore.isEmpty)
            #expect(matchedAfter == matchedBefore)
        }
    }

    @Test("years without one whole Gregorian year are cleared and the other filters kept",
          arguments: [Calendar.Identifier.japanese, .hebrew, .persian, .islamicUmmAlQura, .chinese, .indian])
    func unmappableYearsAreClearedKeepingOtherFilters(identifier: Calendar.Identifier) throws {
        try withIsolatedDefaults { defaults in
            let legacy = deviceCalendar(identifier)
            let thisYear = legacy.component(.year, from: .now)
            defaults.set(#"{"years":[\#(thisYear)],"countryCodes":["JP"],"durations":["week"],"requiresPhotos":true}"#,
                         forKey: "tripFiltersJSON")

            let filters = TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: legacy)
            #expect(filters.years.isEmpty)
            #expect(filters.countryCodes == ["JP"])
            #expect(filters.durations == [.week])
            #expect(filters.requiresPhotos)
            #expect(TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: legacy) == filters)
        }
    }

    @Test("Gregorian selections are unchanged, upgraded once, and still readable by earlier builds")
    func gregorianSelectionIsUnchangedAndUpgradedOnce() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(#"{"years":[2024,2025],"countryCodes":["GR"],"durations":["long"],"requiresPhotos":false}"#,
                         forKey: "tripFiltersJSON")

            let filters = TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: deviceCalendar(.gregorian))
            #expect(filters.years == [2024, 2025])
            #expect(filters.countryCodes == ["GR"])
            #expect(filters.durations == [.long])

            // A saved Gregorian selection is never read as device calendar years again.
            #expect(TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: deviceCalendar(.buddhist)) == filters)
            var edited = filters
            edited.years = [2026]
            edited.saveToDefaults(defaults: defaults)
            #expect(TripFilters.loadFromDefaults(defaults: defaults, deviceCalendar: deviceCalendar(.japanese)) == edited)

            // Earlier builds decode the saved blob, ignoring its format version.
            let saved = try #require(defaults.string(forKey: "tripFiltersJSON"))
            #expect(try JSONDecoder().decode(TripFilters.self, from: Data(saved.utf8)) == edited)
        }
    }
}
