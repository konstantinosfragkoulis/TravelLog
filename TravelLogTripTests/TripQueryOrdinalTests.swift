//
//  TripQueryOrdinalTests.swift
//  TravelLogTests
//
//  Ordinals (`ParsedQuery.ordinal`): "first trip", "last trip to X" and
//  their equivalents keep only the earliest or latest fully matching trip;
//  "last summer" stays a date. Invented trips, UTC.
//

import Foundation
import Testing
@testable import TravelLog

struct TripQueryOrdinalTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 10) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    @Test(
        "ordinal words next to a trip noun",
        arguments: [
            ("last trip", "en", TripQueryParser.Ordinal.last), ("my most recent trip", "en", .last),
            ("first trip", "en", .first), ("latest trip to Valdoria", "en", .last),
            ("τελευταίο ταξίδι", "el", .last), ("πρώτο ταξίδι", "el", .first), ("letzte Reise", "de", .last),
            ("premier voyage", "fr", .first), ("último viaje", "es", .last), ("viaje más reciente", "es", .last),
            ("ilk gezi", "tr", .first), ("chuyến đi đầu tiên", "vi", .first),
        ] as [(String, String, TripQueryParser.Ordinal)]
    )
    func ordinalWords(query: String, languageTag: String, ordinal: TripQueryParser.Ordinal) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.ordinal == ordinal, "\(query)")
        #expect(p.hasStructuredFilter, "\(query)")
    }

    @Test("an ordinal needs a trip noun; last summer and last year are dates")
    func notOrdinals() {
        #expect(parse("last summer").ordinal == nil)
        #expect(parse("last summer").months == [6, 7, 8])
        #expect(parse("last year").ordinal == nil)
        #expect(parse("first").ordinal == nil)
    }

    private func trip(_ place: String, year: Int, month: Int) -> TripSearchDocument {
        let start = date(year, month)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
            ],
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400), startYear: year, startMonth: month,
            durationDays: 4, isComplete: true)
    }

    private func found(_ query: String, languageTag: String = "en") -> [Int] {
        let trips = [
            trip("Valdoria", year: 2020, month: 5), trip("Marenza", year: 2024, month: 9),
            trip("Valdoria", year: 2023, month: 6), trip("Marenza", year: 2021, month: 3),
        ]
        return TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    @Test("only the earliest or latest matching trip is kept")
    func search() {
        #expect(found("last trip") == [1])
        #expect(found("most recent trip") == [1])
        #expect(found("first trip") == [0])
        #expect(found("first trip to Valdoria") == [0])
        #expect(found("last trip to Valdoria") == [2])
        #expect(found("my last trip to Marenza") == [1])
        #expect(found("τελευταίο ταξίδι", languageTag: "el") == [1])
        #expect(found("first trip in 2023") == [2])
    }

    @Test("one ordinal picks from every side of an or")
    func ordinalOverOr() {
        #expect(found("last trip to Valdoria or Marenza") == [1])
        #expect(found("first trip to Valdoria or Marenza") == [0])
        #expect(found("first trip to Marenza or Valdoria") == [0])
    }

    @Test("an or-side with only the ordinal still takes the other side's dates")
    func ordinalSideTakesDates() {
        let trips = [
            trip("Valdoria", year: 2021, month: 3), trip("Valdoria", year: 2023, month: 6),
            trip("Marenza", year: 2021, month: 9),
        ]
        let found = TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: "last trip to Valdoria or Marenza 2021",
            allowsTrailingPartial: false, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
            .filter { $0.strength != .partial }.map(\.documentIndex)
        #expect(found == [2])
    }
}
