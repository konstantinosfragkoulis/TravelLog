//
//  TemporaryHomeFormZoneTests.swift
//  TravelLogTests
//
//  A day picked in the temporary-home form is that day at the place: the form
//  carries the civil day into the place's zone before the worker turns it
//  into the stored instants.
//

import Foundation
import Testing
@testable import TravelLog

struct TemporaryHomeFormZoneTests {

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    private func utc(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    /// The stored instants for a day picked as `picked` in `device`, for a place in `place`.
    private func stored(
        _ picked: Date, device: TimeZone, place: TimeZone
    ) -> (start: Date, end: Date) {
        TemporaryHomeSaveWorker.civilDayBounds(
            of: TemporaryHomeFormSheet.sameDay(picked, from: device, in: place), in: place)
    }

    /// A day picked at `picked` (UTC) in `device`, for a place in `place`,
    /// and the stored instants it must produce.
    struct InstantRow: Sendable, CustomTestStringConvertible {
        let name: String
        let device: String
        let place: String
        let picked: String
        var start: String?
        var end: String?
        var testDescription: String { name }
    }

    static let instantRows: [InstantRow] = [
        // 4 Sep 2028, 09:00 in Athens; 4 Sep 00:00 CEST.
        InstantRow(name: "A day picked in Athens for Brussels starts at Brussels midnight",
                   device: "Europe/Athens", place: "Europe/Brussels",
                   picked: "2028-09-04T06:00:00Z", start: "2028-09-03T22:00:00Z"),
        // 1 Feb 2029, 09:00 in Athens; 1 Feb 23:59:59 CET.
        InstantRow(name: "A day picked in Athens for Brussels ends at Brussels midnight",
                   device: "Europe/Athens", place: "Europe/Brussels",
                   picked: "2029-02-01T07:00:00Z", end: "2029-02-01T22:59:59Z"),
        // 11 Dec 00:00 EST to 11 Dec 23:59:59 EST.
        InstantRow(name: "A day picked in Athens for White Plains keeps its whole last evening there",
                   device: "Europe/Athens", place: "America/New_York",
                   picked: "2028-12-11T08:00:00Z",
                   start: "2028-12-11T05:00:00Z", end: "2028-12-12T04:59:59Z"),
        // 23 Aug 00:00 JST.
        InstantRow(name: "A day picked in Athens for Tokyo starts at Tokyo midnight, not at six in the morning",
                   device: "Europe/Athens", place: "Asia/Tokyo",
                   picked: "2028-08-23T06:00:00Z", start: "2028-08-22T15:00:00Z"),
        // 23:59 on 4 Sep in Brussels.
        InstantRow(name: "The same zone leaves the picked day where it was",
                   device: "Europe/Brussels", place: "Europe/Brussels",
                   picked: "2028-09-04T21:59:00Z",
                   start: "2028-09-03T22:00:00Z", end: "2028-09-04T21:59:59Z"),
    ]

    @Test("A picked day is stored as that day's bounds at the place", arguments: instantRows)
    func storedInstants(row: InstantRow) throws {
        let bounds = stored(
            try utc(row.picked), device: try zone(row.device), place: try zone(row.place))
        if let start = row.start {
            #expect(bounds.start == (try utc(start)))
        }
        if let end = row.end {
            #expect(bounds.end == (try utc(end)))
        }
    }

    /// The civil day at the place for a day picked at `picked` (UTC) in
    /// `device`. A `bounds` row checks both stored instants fall on that day
    /// and the end follows the start; otherwise the moved date is checked.
    struct CivilRow: Sendable, CustomTestStringConvertible {
        let name: String
        let device: String
        let place: String
        let picked: String
        let year: Int
        let month: Int
        let day: Int
        var bounds = false
        var testDescription: String { name }
    }

    static let civilRows: [CivilRow] = [
        // 3 Sep 2028, 23:30 in Athens, which is still 22:30 on 3 Sep in Brussels.
        CivilRow(name: "The day is the one on the device's calendar, just before its midnight",
                 device: "Europe/Athens", place: "Europe/Brussels",
                 picked: "2028-09-03T20:30:00Z", year: 2028, month: 9, day: 3),
        // Just after Athens midnight it is 4 Sep there and still 3 Sep in Brussels.
        CivilRow(name: "The day is the one on the device's calendar, just after its midnight",
                 device: "Europe/Athens", place: "Europe/Brussels",
                 picked: "2028-09-03T21:30:00Z", year: 2028, month: 9, day: 4),
        // 1 Mar 2028, 10:00 in Honolulu is already 2 Mar in Kiritimati.
        CivilRow(name: "Across the date line the picked day survives going west to east",
                 device: "Pacific/Honolulu", place: "Pacific/Kiritimati",
                 picked: "2028-03-01T20:00:00Z", year: 2028, month: 3, day: 1),
        CivilRow(name: "Across the date line the picked day survives going east to west",
                 device: "Pacific/Kiritimati", place: "Pacific/Honolulu",
                 picked: "2028-03-01T20:00:00Z", year: 2028, month: 3, day: 2),
        // Europe falls back on 31 Oct 2027.
        CivilRow(name: "A clock-change day keeps the picked day",
                 device: "Europe/Athens", place: "Europe/Brussels",
                 picked: "2027-10-31T09:00:00Z", year: 2027, month: 10, day: 31, bounds: true),
        // Santiago springs forward at midnight on 5 Sep 2027.
        CivilRow(name: "A zone with no midnight that day keeps the picked day",
                 device: "Europe/Athens", place: "America/Santiago",
                 picked: "2027-09-05T09:00:00Z", year: 2027, month: 9, day: 5, bounds: true),
    ]

    @Test("A picked day stays the same civil day at the place", arguments: civilRows)
    func civilDay(row: CivilRow) throws {
        let device = try zone(row.device)
        let place = try zone(row.place)
        let picked = try utc(row.picked)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = place
        let day = DateComponents(year: row.year, month: row.month, day: row.day)
        if row.bounds {
            let bounds = stored(picked, device: device, place: place)
            #expect(calendar.dateComponents([.year, .month, .day], from: bounds.start) == day)
            #expect(calendar.dateComponents([.year, .month, .day], from: bounds.end) == day)
            #expect(bounds.end > bounds.start)
        } else {
            let moved = TemporaryHomeFormSheet.sameDay(picked, from: device, in: place)
            #expect(calendar.dateComponents([.year, .month, .day], from: moved) == day)
        }
    }

    @Test("The Home form's area hint stays hidden until a preview says the pin is in a city boundary")
    func areaHintNeedsAPreview() {
        #expect(!TemporaryHomeFormSheet.showsAreaSourceHint(for: nil))
    }
}
