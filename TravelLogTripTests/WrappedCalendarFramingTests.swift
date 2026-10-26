//
//  WrappedCalendarFramingTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator keeps `daysAbroad`, `totalDays`, and `startOfYear`
//  in one UTC calendar frame. These tests cover that frame, the leap-year
//  `totalDays` boundary, and the `daysAtHome` clamp and complement:
//  `max(0, totalDays - daysAbroad)`.
//  @MainActor because it instantiates the `@ModelActor` `YearWrappedGenerator`
//  the same way DaysAbroadTests does; `calendar`/`startOfYear`/`computeDaysAbroad`
//  are `nonisolated` and called synchronously without `await`.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedCalendarFramingTests {

    private func gen() throws -> YearWrappedGenerator {
        YearWrappedGenerator(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    /// UTC reference calendar; mirrors the function-under-test's internal frame.
    private var utcCal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func trip(_ start: Date, _ end: Date) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = true
        let stay = Stay(startTime: start, endTime: end,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [],
                        timeZoneIdentifier: "UTC")
        trip.stays = [stay]
        return trip
    }

    // MARK: - Calendar identity

    @Test("the generator's calendar is the UTC gregorian frame")
    func calendarIsUTCGregorian() throws {
        let cal = try gen().calendar
        #expect(cal.identifier == .gregorian)
        #expect(cal.timeZone == TimeZone(identifier: "UTC")!)
    }

    @Test("Settings uses the Gregorian Wrapped year at the device time-zone boundary")
    func settingsWrappedYearIsGregorian() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = utc(2026, 10, 14)
        #expect(buddhist.component(.year, from: now) == 2569)
        #expect(SettingsView.wrappedYear(at: now, timeZone: buddhist.timeZone) == 2026)

        let boundary = utc(2026, 12, 31, 23)
        #expect(SettingsView.wrappedYear(at: boundary, timeZone: TimeZone(secondsFromGMT: 7200)!) == 2027)
        #expect(SettingsView.wrappedYear(at: boundary, timeZone: TimeZone(secondsFromGMT: -7200)!) == 2026)
    }

    // MARK: - startOfYear bounds

    @Test("startOfYear(2026) is Jan 1 00:00:00 UTC")
    func startOfYearIsJanuaryFirstMidnightUTC() throws {
        #expect(try gen().startOfYear(2026) == utc(2026, 1, 1, 0))
    }

    @Test("consecutive startOfYear values differ by exactly one calendar year (365 common, 366 leap)")
    func startOfYearConsecutiveYearsDifferByOneCalendarYear() throws {
        let g = try gen()
        let secondsPerDay: TimeInterval = 86_400
        // 2026 is a common year → 365 days from its start to 2027's start.
        #expect(g.startOfYear(2027).timeIntervalSince(g.startOfYear(2026)) == 365 * secondsPerDay)
        // 2024 is a leap year → 366 days from its start to 2025's start.
        #expect(g.startOfYear(2025).timeIntervalSince(g.startOfYear(2024)) == 366 * secondsPerDay)
    }

    // The consecutive-startOfYear test above keeps the leap boundary pinned
    // THROUGH production `startOfYear`; its exact 365/366 × 86,400 s
    // arithmetic fails in any DST-bearing frame, which is the invariant this
    // file exists for.

    // MARK: - daysAtHome clamp / complement

    @Test("computeDaysAtHome floors at 0 and complements daysAbroad")
    func daysAtHomeFormulaNeverNegativeAndComplementsAbroad() throws {
        let g = try gen()
        let year = 2026
        let totalDays = g.calendar.range(of: .day, in: .year, for: g.startOfYear(year))?.count ?? 365

        // Full-coverage: a stay spanning the entire year → daysAbroad == totalDays →
        // the production helper's max(0,…) floor yields exactly 0 home days.
        let fullYear = trip(utc(2026, 1, 1, 0), utc(2026, 12, 31, 23))
        let abroadFull = g.computeDaysAbroad(trips: [fullYear], year: year, now: utc(2027, 1, 1))
        #expect(abroadFull == totalDays)
        #expect(g.computeDaysAtHome(daysAbroad: abroadFull, year: year, now: utc(2027, 1, 1)) == 0)

        // Partial: a 4-day stay → home days == totalDays - 4.
        let partial = trip(utc(2026, 6, 1, 0), utc(2026, 6, 4, 23)) // Jun 1,2,3,4
        let abroadPartial = g.computeDaysAbroad(trips: [partial], year: year, now: utc(2027, 1, 1))
        #expect(abroadPartial == 4)
        #expect(g.computeDaysAtHome(daysAbroad: abroadPartial, year: year, now: utc(2027, 1, 1)) == totalDays - 4)

        // A daysAbroad value exceeding totalDays must clamp to 0 through
        // the production helper's max(0, ...) floor.
        #expect(g.computeDaysAtHome(daysAbroad: totalDays + 50, year: year, now: utc(2027, 1, 1)) == 0)
    }

    @Test("a recap generated before its year ends counts home days only through the generation day")
    func daysAtHomeStopsAtTheGenerationDay() throws {
        let g = try gen()
        let utcZone = TimeZone(identifier: "UTC")!
        // December 1 is the 335th day of 2026: 30 dates have not happened.
        #expect(g.computeDaysAtHome(daysAbroad: 40, year: 2026, now: utc(2026, 12, 1, 9), zone: utcZone) == 295)
        // Leap year: December 1 is the 336th day of 2028.
        #expect(g.computeDaysAtHome(daysAbroad: 40, year: 2028, now: utc(2028, 12, 1, 9), zone: utcZone) == 296)
        // The generation day is labelled in the zone: already 2027 at UTC+2.
        #expect(g.computeDaysAtHome(daysAbroad: 40, year: 2026, now: utc(2026, 12, 31, 23),
                                    zone: TimeZone(secondsFromGMT: 7200)!) == 325)
        // A past year keeps its whole length.
        #expect(g.computeDaysAtHome(daysAbroad: 40, year: 2025, now: utc(2026, 12, 1, 9), zone: utcZone) == 325)
    }
}
