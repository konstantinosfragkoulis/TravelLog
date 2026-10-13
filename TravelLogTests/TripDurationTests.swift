//
//  TripDurationTests.swift
//  TravelLogTests
//
//  Pure model logic. Covers `Trip.durationDays`, the inclusive
//  calendar-day span shown in trip lists and Wrapped ("longest trip"). The
//  contract (per the property doc): April 10 to 13 is 4 days, not 3; an ongoing
//  trip is nil; the span is clamped to a minimum of 1 day.
//
//  Dates are built with `Calendar.current`, the same calendar `durationDays`
//  uses internally, so the assertions hold regardless of the test machine's
//  time zone.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripDurationTests {

    /// Noon on a given day in the current calendar (noon avoids any DST
    /// midnight edge from skewing the .day component).
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("an ongoing trip (no endDate) has nil duration")
    func ongoingIsNil() {
        let trip = Trip(startDate: day(2026, 4, 10))
        #expect(trip.durationDays == nil)
    }

    @Test("a same-day trip is 1 day")
    func sameDayIsOne() {
        let trip = Trip(startDate: day(2026, 4, 10))
        trip.endDate = day(2026, 4, 10)
        #expect(trip.durationDays == 1)
    }

    @Test("April 10 to 13 spans 4 inclusive days")
    func inclusiveSpan() {
        let trip = Trip(startDate: day(2026, 4, 10))
        trip.endDate = day(2026, 4, 13)
        #expect(trip.durationDays == 4)
    }

    @Test("a single overnight (Apr 10 → Apr 11) is 2 days")
    func singleOvernightIsTwo() {
        let trip = Trip(startDate: day(2026, 4, 10))
        trip.endDate = day(2026, 4, 11)
        #expect(trip.durationDays == 2)
    }

    // MARK: - Boundary zones (V18)

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("each boundary is read in its own zone: a late Athens departure and an LA return")
    func boundariesReadInTheirOwnZones() {
        let athens = TimeZone(identifier: "Europe/Athens")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        // 23:30 Athens on Apr 10 (20:30 UTC) → 22:00 LA on Apr 20 (05:00 UTC Apr 21).
        let start = utc(2026, 4, 10, 20, 30)
        let end = utc(2026, 4, 21, 5, 0)
        #expect(Trip.inclusiveDays(from: start, in: athens, to: end, in: la) == 11)
        // The same instants read in UTC would give Apr 10 → Apr 21 = 12 days.
        let zulu = TimeZone(secondsFromGMT: 0)!
        #expect(Trip.inclusiveDays(from: start, in: zulu, to: end, in: zulu) == 12)
    }

    @Test("a trip that never crosses local midnight is one day whatever the interior zones")
    func interiorZonesAreIrrelevant() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 08:00 Tokyo → 23:00 Tokyo, same local day.
        let start = utc(2026, 4, 9, 23, 0)
        let end = utc(2026, 4, 10, 14, 0)
        #expect(Trip.inclusiveDays(from: start, in: tokyo, to: end, in: tokyo) == 1)
    }

    @Test("durationDays takes the zones from the earliest and latest stays")
    func durationDaysReadsStayZones() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = utc(2026, 4, 10, 20, 30)   // 23:30 Athens, Apr 10
        let end = utc(2026, 4, 21, 5, 0)       // 22:00 LA, Apr 20
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = true
        let first = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 38, centroidLongitude: 23.8, h3IndexRes6: "A",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "Europe/Athens")
        let last = Stay(
            startTime: end.addingTimeInterval(-3600), endTime: end,
            centroidLatitude: 34, centroidLongitude: -118.2, h3IndexRes6: "L",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "America/Los_Angeles")
        ctx.insert(trip); ctx.insert(first); ctx.insert(last)
        first.trip = trip; last.trip = trip
        try ctx.save()
        #expect(trip.durationDays == 11)

        // Pre-V18 rows (nil zone) fall back to the device zone: the
        // inclusive calendar-day span read in Calendar.current.
        first.timeZoneIdentifier = nil
        last.timeZoneIdentifier = nil
        let cal = Calendar.current
        let expected = (cal.dateComponents(
            [.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0) + 1
        #expect(trip.durationDays == expected)
    }

    @Test("duration spanning a month boundary is correct")
    func monthBoundary() {
        let trip = Trip(startDate: day(2026, 4, 28))
        trip.endDate = day(2026, 5, 2) // Apr 28,29,30, May 1,2 = 5 days
        #expect(trip.durationDays == 5)
    }

    @Test("a reversed end < start is clamped to a minimum of 1 day, never negative")
    func reversedClampsToOne() {
        let trip = Trip(startDate: day(2026, 4, 13))
        trip.endDate = day(2026, 4, 10) // nonsensical, but must not go negative
        #expect(trip.durationDays == 1)
    }
}
