//
//  OnThisDayEngineTests.swift
//  TravelLogTests
//
//  Pure-function tests for OnThisDayEngine: calendar (month, day) matching
//  across past years, interval overlap (multi-day and New-Year-spanning
//  stays), Feb-29 leap-year handling, current-year exclusion, and the
//  per-year / per-trip grouping with place dedup. No container needed —
//  the engine consumes Sendable value snapshots.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

struct OnThisDayEngineTests {

    /// Deterministic UTC calendar — the engine takes the calendar as a
    /// parameter precisely so tests don't depend on the host timezone.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func stay(
        trip: UUID? = UUID(),
        place: String? = "Kyoto",
        start: Date,
        end: Date,
        weather: String? = nil,
        temp: Double? = nil
    ) -> OnThisDayStay {
        OnThisDayStay(
            stayID: UUID(), tripID: trip, place: place,
            startTime: start, endTime: end,
            weatherConditionRaw: weather, avgTemperatureC: temp
        )
    }

    // MARK: - Matching

    @Test("a stay ending exactly at midnight belongs to the previous day only (half-open)")
    func exactMidnightEndIsPreviousDayOnly() {
        // Ends 2023-06-10 00:00:00 — the user occupied June 9, not June 10.
        // Pre-fix `endTime >= dayStart` counted it for BOTH days.
        let s = stay(start: date(2023, 6, 9, 18), end: date(2023, 6, 10, 0))
        let onTenth = OnThisDayEngine.yearGroups(on: date(2026, 6, 10), stays: [s], calendar: Self.utc)
        #expect(onTenth.isEmpty)
        let onNinth = OnThisDayEngine.yearGroups(on: date(2026, 6, 9), stays: [s], calendar: Self.utc)
        #expect(onNinth.count == 1)
    }

    @Test("a past-year stay on the same month/day matches; yearsAgo is correct")
    func pastYearSameDayMatches() {
        let groups = OnThisDayEngine.yearGroups(
            on: date(2026, 6, 10),
            stays: [stay(start: date(2023, 6, 10, 9), end: date(2023, 6, 10, 18))],
            calendar: Self.utc
        )
        #expect(groups.count == 1)
        #expect(groups.first?.year == 2023)
        #expect(groups.first?.yearsAgo == 3)
        #expect(groups.first?.trips.first?.places == ["Kyoto"])
    }

    @Test("a stay from the CURRENT year today is not a memory")
    func currentYearExcluded() {
        let groups = OnThisDayEngine.yearGroups(
            on: date(2026, 6, 10),
            stays: [stay(start: date(2026, 6, 10, 8), end: date(2026, 6, 10, 11))],
            calendar: Self.utc
        )
        #expect(groups.isEmpty)
    }

    @Test("a different month/day does not match")
    func differentDayNoMatch() {
        let groups = OnThisDayEngine.yearGroups(
            on: date(2026, 6, 10),
            stays: [stay(start: date(2023, 6, 11), end: date(2023, 6, 12))],
            calendar: Self.utc
        )
        #expect(groups.isEmpty)
    }

    @Test("a multi-day stay matches every day it covers, including the target")
    func multiDayStaySpanningTargetMatches() {
        // Jun 5 – Jun 20, 2022 covers Jun 10.
        let groups = OnThisDayEngine.yearGroups(
            on: date(2026, 6, 10),
            stays: [stay(start: date(2022, 6, 5), end: date(2022, 6, 20))],
            calendar: Self.utc
        )
        #expect(groups.count == 1)
        #expect(groups.first?.year == 2022)
    }

    @Test("a New-Year-spanning stay matches dates in BOTH of its years")
    func newYearSpanningStayMatchesBothYears() {
        // Dec 30, 2022 → Jan 3, 2023: a Jan 1 query must match year 2023
        // (the day it covers in 2023), and a Dec 31 query year 2022.
        let nyStay = stay(start: date(2022, 12, 30), end: date(2023, 1, 3))

        let january = OnThisDayEngine.yearGroups(on: date(2026, 1, 1), stays: [nyStay], calendar: Self.utc)
        #expect(january.map(\.year) == [2023])

        let december = OnThisDayEngine.yearGroups(on: date(2026, 12, 31), stays: [nyStay], calendar: Self.utc)
        #expect(december.map(\.year) == [2022])
    }

    @Test("Feb 29 matches only in actual leap years — no Mar 1 aliasing")
    func feb29OnlyInLeapYears() {
        // 2024 is a leap year; 2023 is not. A stay on Mar 1, 2023 must NOT
        // surface for a Feb 29 query (Calendar auto-corrects Feb 29 2023 to
        // Mar 1 — the engine rejects that).
        let leapStay = stay(place: "Quito", start: date(2024, 2, 29), end: date(2024, 2, 29, 20))
        let marchStay = stay(place: "Lima", start: date(2023, 3, 1), end: date(2023, 3, 1, 20))

        let groups = OnThisDayEngine.yearGroups(
            on: date(2028, 2, 29),   // 2028 is a leap year
            stays: [leapStay, marchStay],
            calendar: Self.utc
        )
        #expect(groups.count == 1)
        #expect(groups.first?.year == 2024)
        #expect(groups.first?.trips.first?.places == ["Quito"])
    }

    // MARK: - Grouping

    @Test("repeated valid and invalid years preserve matches and cancellation checks")
    func repeatedYearIntervalsPreserveCancellation() {
        let trip = UUID()
        let invalid = stay(trip: trip, start: date(2023, 3, 1), end: date(2023, 3, 1, 20))
        let valid = stay(trip: trip, start: date(2024, 2, 29), end: date(2024, 2, 29, 20))
        let stays = [invalid, invalid, valid, valid]
        let groups = OnThisDayEngine.yearGroups(on: date(2028, 2, 29), stays: stays, calendar: Self.utc)
        #expect(groups.map(\.year) == [2024])
        #expect(groups.first?.trips.first?.stayCount == 2)
        for stopAt in [5, 9] {
            var calls = 0
            #expect(throws: CancellationError.self) {
                try OnThisDayEngine.yearGroups(on: date(2028, 2, 29), stays: stays, calendar: Self.utc) {
                    calls += 1
                    if calls == stopAt { throw CancellationError() }
                }
            }
            #expect(calls == stopAt)
        }
    }

    @Test("multiple things on the same date are all kept: years sort newest-first, trips group within a year")
    func multipleMatchesGroupCorrectly() {
        let tripA = UUID()
        let tripB = UUID()
        let stays = [
            stay(trip: tripA, place: "Kyoto", start: date(2023, 12, 2, 8), end: date(2023, 12, 2, 12)),
            stay(trip: tripA, place: "Osaka", start: date(2023, 12, 2, 14), end: date(2023, 12, 2, 20)),
            stay(trip: tripB, place: "Berlin", start: date(2023, 12, 2, 9), end: date(2023, 12, 2, 18)),
            stay(trip: UUID(), place: "Samos", start: date(2021, 12, 2), end: date(2021, 12, 4))
        ]

        let groups = OnThisDayEngine.yearGroups(on: date(2026, 12, 2), stays: stays, calendar: Self.utc)

        #expect(groups.map(\.year) == [2023, 2021])
        let year2023 = groups[0]
        #expect(year2023.trips.count == 2)
        #expect(year2023.trips[0].places == ["Kyoto", "Osaka"])
        #expect(year2023.trips[0].stayCount == 2)
        #expect(year2023.trips[1].places == ["Berlin"])
        #expect(groups[1].trips.first?.places == ["Samos"])
    }

    @Test("repeated place names within one trip dedupe; nil-trip stays form their own groups")
    func placeDedupAndNilTrips() {
        let trip = UUID()
        let stays = [
            stay(trip: trip, place: "Syros", start: date(2024, 12, 2, 8), end: date(2024, 12, 2, 10)),
            stay(trip: trip, place: "Syros", start: date(2024, 12, 2, 12), end: date(2024, 12, 2, 16)),
            stay(trip: nil, place: "Livadeiá", start: date(2024, 12, 2, 9), end: date(2024, 12, 2, 11)),
            stay(trip: nil, place: "Athens", start: date(2024, 12, 2, 13), end: date(2024, 12, 2, 15))
        ]

        let groups = OnThisDayEngine.yearGroups(on: date(2026, 12, 2), stays: stays, calendar: Self.utc)

        #expect(groups.count == 1)
        let tripGroups = groups[0].trips
        #expect(tripGroups.count == 3)
        #expect(tripGroups[0].places == ["Syros"])
        #expect(tripGroups[0].stayCount == 2)
        // Each nil-trip stay stands alone.
        #expect(tripGroups[1].places == ["Livadeiá"])
        #expect(tripGroups[2].places == ["Athens"])
    }

    @Test("the first non-nil weather among a trip's matched stays surfaces on the group")
    func weatherChipPicksFirstAvailable() {
        let trip = UUID()
        let stays = [
            stay(trip: trip, place: "Cephalonia", start: date(2024, 12, 2, 8), end: date(2024, 12, 2, 10)),
            stay(trip: trip, place: "Cephalonia", start: date(2024, 12, 2, 12), end: date(2024, 12, 2, 16),
                 weather: "clear", temp: 28.5)
        ]

        let groups = OnThisDayEngine.yearGroups(on: date(2026, 12, 2), stays: stays, calendar: Self.utc)

        #expect(groups.first?.trips.first?.weatherConditionRaw == "clear")
        #expect(groups.first?.trips.first?.avgTemperatureC == 28.5)
    }
}

// MARK: - OnThisDayView.tripLookup

/// The view builds its trip lookup ONCE per body evaluation via this pure
/// static helper. The load-bearing rule: duplicate Trip.ids (possible under
/// CloudKit — no uniqueness constraint, no Trip deduplicator) collapse
/// first-wins instead of trapping `Dictionary(uniqueKeysWithValues:)`.
@MainActor
struct OnThisDayTripLookupTests {

    @Test("deleted Trips are omitted from the lookup")
    func deletedTripsAreOmitted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let trip = Trip(startDate: .now)
        ctx.insert(trip)
        try ctx.save()
        let tripID = trip.id

        // A pending deletion is what the `isDeleted` guard detects: a saved
        // deletion detaches the object and `isDeleted` reads false again.
        ctx.delete(trip)
        #expect(trip.isDeleted)

        let lookup = OnThisDayView.tripLookup([trip])
        #expect(lookup[tripID] == nil)
    }

    @Test("duplicate Trip.ids collapse first-wins instead of trapping")
    func duplicateIDsCollapseFirstWins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let shared = UUID()
        let a = Trip(startDate: .now); a.id = shared; ctx.insert(a)
        let b = Trip(startDate: .now); b.id = shared; ctx.insert(b)
        let c = Trip(startDate: .now); ctx.insert(c)

        let lookup = OnThisDayView.tripLookup([a, b, c])
        #expect(lookup.count == 2)
        #expect(lookup[shared] === a, "first row wins the collapse")
        #expect(lookup[c.id] === c)
    }
}
