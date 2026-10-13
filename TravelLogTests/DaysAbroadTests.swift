//
//  DaysAbroadTests.swift
//  TravelLogTests
//
//  Phase 2 — `YearWrappedGenerator.computeDaysAbroad(trips:year:)`, the
//  days-abroad headline stat (Wrapped Card 1 / Card 8). These tests pin the
//  three subtleties of its rewrite, using a UTC calendar to match the function's internal frame:
//   • cross-year spillover is CLAMPED to the requested year (no January
//     overcount from a trip that starts in Dec and ends in Jan),
//   • distinct calendar days are counted as startOfDay instants (a sub-24h
//     midnight crossing is 2 days; overlapping trips on one day are 1 day),
//   • a trip entirely outside the year contributes 0.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct DaysAbroadTests {

    private func generator() throws -> YearWrappedGenerator {
        YearWrappedGenerator(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    /// UTC date — matches the UTC gregorian calendar `computeDaysAbroad` uses.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
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

    @Test("empty trips → 0 days")
    func emptyIsZero() throws {
        let gen = try generator()
        #expect(gen.computeDaysAbroad(trips: [], year: 2026, now: utc(2027, 1, 1)) == 0)
    }

    @Test("a trip fully inside the year counts inclusive distinct days")
    func fullyInsideYear() throws {
        let gen = try generator()
        let s = trip(utc(2026, 6, 1), utc(2026, 6, 4)) // Jun 1,2,3,4
        #expect(gen.computeDaysAbroad(trips: [s], year: 2026, now: utc(2027, 1, 1)) == 4)
    }

    @Test("a New-Year-spanning trip is clamped: Dec days to the old year, Jan days to the new")
    func crossYearClamp() throws {
        let gen = try generator()
        let s = trip(utc(2025, 12, 30), utc(2026, 1, 3))
        // 2025 gets Dec 30, 31 = 2 days (clamped at year end).
        #expect(gen.computeDaysAbroad(trips: [s], year: 2025, now: utc(2027, 1, 1)) == 2)
        // 2026 gets Jan 1, 2, 3 = 3 days (NOT the December days — the overcount fix).
        #expect(gen.computeDaysAbroad(trips: [s], year: 2026, now: utc(2027, 1, 1)) == 3)
    }

    @Test("a sub-24h trip crossing local midnight counts as 2 days")
    func midnightCrossingIsTwoDays() throws {
        let gen = try generator()
        let s = trip(utc(2026, 6, 1, 23), utc(2026, 6, 2, 1)) // 2 hours, across midnight
        #expect(gen.computeDaysAbroad(trips: [s], year: 2026, now: utc(2027, 1, 1)) == 2)
    }

    @Test("overlapping trips on the same day are not double-counted")
    func overlappingSameDayIsOne() throws {
        let gen = try generator()
        let a = trip(utc(2026, 6, 1, 8), utc(2026, 6, 1, 10))
        let b = trip(utc(2026, 6, 1, 9), utc(2026, 6, 1, 18))
        #expect(gen.computeDaysAbroad(trips: [a, b], year: 2026, now: utc(2027, 1, 1)) == 1)
    }

    @Test("distinct non-adjacent days union correctly")
    func distinctDaysUnion() throws {
        let gen = try generator()
        let a = trip(utc(2026, 6, 1), utc(2026, 6, 1))
        let b = trip(utc(2026, 6, 5), utc(2026, 6, 6))
        #expect(gen.computeDaysAbroad(trips: [a, b], year: 2026, now: utc(2027, 1, 1)) == 3) // Jun 1,5,6
    }

    @Test("a trip entirely outside the requested year contributes 0")
    func outsideYearIsZero() throws {
        let gen = try generator()
        let s = trip(utc(2024, 3, 1), utc(2024, 3, 10))
        #expect(gen.computeDaysAbroad(trips: [s], year: 2026, now: utc(2027, 1, 1)) == 0)
    }
}
