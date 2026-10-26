//
//  TripsSearchClockTests.swift
//  TravelLogTests
//
//  The Trips list keys its search slices on the local day and zone while a
//  query is active, so relative dates ("this year", "last month") turn over
//  in a retained list at local midnight and on a zone change, with no store
//  write. The notification wiring itself is a device check.
//

import Foundation
import Testing
@testable import TravelLog

struct TripsSearchClockTests {

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    private func at(_ zone: TimeZone, _ year: Int, _ month: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour, minute: minute))!
    }

    @Test func clockTurnsOverAtTheGivenZonesMidnight() throws {
        let athens = try zone("Europe/Athens")
        // 23:58 on 31 Dec and 00:30 on 1 Jan share a UTC day but not an Athens one.
        let lastEvening = TripsListView.makeSearchClock(now: at(athens, 2026, 12, 31, 23, 58), timeZone: athens)
        let afterMidnight = TripsListView.makeSearchClock(now: at(athens, 2027, 1, 1, 0, 30), timeZone: athens)
        let lateThatDay = TripsListView.makeSearchClock(now: at(athens, 2027, 1, 1, 23, 30), timeZone: athens)
        #expect(lastEvening != afterMidnight)
        #expect(afterMidnight == lateThatDay)
    }

    @Test func zoneChangeAtTheSameInstantChangesTheClock() throws {
        let athens = try zone("Europe/Athens")
        let berlin = try zone("Europe/Berlin")
        let tokyo = try zone("Asia/Tokyo")
        let noon = at(athens, 2027, 1, 1, 12, 0)
        // Same local day in Berlin, but another zone reads relative dates.
        #expect(TripsListView.makeSearchClock(now: noon, timeZone: athens)
            != TripsListView.makeSearchClock(now: noon, timeZone: berlin))
        let lateEvening = at(athens, 2027, 1, 1, 22, 0)
        #expect(TripsListView.makeSearchClock(now: lateEvening, timeZone: athens).day
            != TripsListView.makeSearchClock(now: lateEvening, timeZone: tokyo).day)
    }

    @Test func sliceKeyObservesTheClockOnlyWhileSearching() throws {
        let athens = try zone("Europe/Athens")
        let today = TripsListView.makeSearchClock(now: at(athens, 2026, 12, 31, 23, 58), timeZone: athens)
        let tomorrow = TripsListView.makeSearchClock(now: at(athens, 2027, 1, 1, 0, 30), timeZone: athens)
        for idle in ["", "   ", "\n"] {
            #expect(TripsListView.sliceSearchClock(query: idle, clock: today) == nil)
            #expect(TripsListView.sliceSearchClock(query: idle, clock: tomorrow) == nil)
        }
        #expect(TripsListView.sliceSearchClock(query: "this year", clock: today) == today)
        #expect(TripsListView.sliceSearchClock(query: "this year", clock: today)
            != TripsListView.sliceSearchClock(query: "this year", clock: tomorrow))
    }
}
