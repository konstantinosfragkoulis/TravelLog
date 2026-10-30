//
//  TripQueryDisjunctionTests.swift
//  TravelLogTests
//
//  "or" between places or year bounds (`ParsedQuery.disjunctionSides`):
//  the search unions each side's full matches, a side lacking place words
//  taking the other sides' place words and one lacking dates or lengths
//  their other words. A side no trip matches adds none; without a side to
//  search ("Or Yehuda") or any side matching, the single reading stays; a
//  comma list stays AND. Pure searches with an
//  injected `now` (2026-07-14, UTC).
//

import Testing
import Foundation
@testable import TravelLog

struct TripQueryDisjunctionTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func trip(_ place: String, year: Int, month: Int = 5, durationDays: Int = 4) -> TripSearchDocument {
        let start = date(year, month, 3)
        let end = utcCal.date(byAdding: .day, value: durationDays - 1, to: start)!
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(
                    kind: .date,
                    displayValues: TripSearchDocument.dateWords(
                        start: start, end: end, languageTag: "en", calendar: utcCal)),
            ],
            startDate: start, endDate: end, startYear: year, startMonth: month,
            durationDays: durationDays, isComplete: true)
    }

    /// 0 Paris 2014, 1 Rome 2021, 2 Paris 2021 (10 days), 3 Lima 2018 (9 days), 4 Or Yehuda 2019.
    private var trips: [TripSearchDocument] {
        [
            trip("Paris", year: 2014), trip("Rome", year: 2021), trip("Paris", year: 2021, durationDays: 10),
            trip("Lima", year: 2018, durationDays: 12), trip("Or Yehuda", year: 2019),
        ]
    }

    private func search(_ query: String, typing: Bool = false, languageTag: String = "en") -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: typing,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    private func found(_ query: String, typing: Bool = false, languageTag: String = "en") -> [Int] {
        search(query, typing: typing, languageTag: languageTag).map(\.documentIndex)
    }

    @Test("places joined by or find either place")
    func places() {
        #expect(found("Paris or Rome") == [0, 1, 2])
        #expect(found("trips to Paris or Lima") == [0, 2, 3])
        #expect(found("Paris or Rome or Lima") == [0, 1, 2, 3])
        #expect(search("Paris or Rome").allSatisfy { $0.strength == .strong })
        #expect(found("Roma o Lima", languageTag: "es") == [1, 3])
        #expect(found("Rome oder Lima", languageTag: "de") == [1, 3])
    }

    @Test("a side without dates or lengths shares the other side's")
    func sharedFilters() {
        #expect(found("Paris or Rome 2021") == [1, 2])
        #expect(found("Paris or Lima long trips") == [2, 3])
        // A side with no full match adds none (no Rome trip is long).
        #expect(found("Paris or Rome long trips") == [2])
        // Each side keeps its own date.
        #expect(found("Paris 2014 or Rome 2021") == [0, 1])
    }

    @Test("year bounds joined by or admit either range, with a shared place")
    func bounds() {
        #expect(found("before 2015 or after 2020") == [0, 1, 2])
        #expect(found("Paris before 2015 or after 2020") == [0, 2])
        #expect(found("between 2013 and 2014 or since 2021") == [0, 1, 2])
    }

    @Test("an or the single reading needs stays: a place named Or, no side with a trip, a comma list")
    func fallbacks() {
        #expect(found("Or Yehuda") == [4])
        // "or" between bound words is part of the bound.
        #expect(found("2014 or earlier") == [0])
        // A side no trip matches adds none; with no side matching, the single reading.
        #expect(found("Paris or Atlantis") == [0, 2])
        #expect(search("Paris or Atlantis").allSatisfy { $0.strength == .strong })
        #expect(search("Lemuria or Atlantis").allSatisfy { $0.strength == .partial })
        #expect(search("Paris, Rome").allSatisfy { $0.strength == .partial })
    }

    @Test("a side shares only what the other side's resolved reading left as filters")
    func resolvedSides() {
        func region(_ document: TripSearchDocument, _ name: String) -> TripSearchDocument {
            TripSearchDocument(
                tripID: document.tripID,
                fields: document.fields + [TripSearchField(kind: .region, displayValues: [name])],
                startDate: document.startDate, endDate: document.endDate, startYear: document.startYear,
                startMonth: document.startMonth, durationDays: document.durationDays, isComplete: true)
        }
        // 0 Providence (Rhode Island) and 1 Rome (10 days), neither an island
        // trip; 2 and 3 Cape May in June for 4 and 10 days, 4 Rome (4 days).
        let documents = [
            region(trip("Providence", year: 2022), "Rhode Island"), trip("Rome", year: 2024, durationDays: 10),
            trip("Cape May", year: 2023, month: 6), trip("Cape May", year: 2024, month: 6, durationDays: 10),
            trip("Rome", year: 2023),
        ]
        func found(_ query: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }
                .map(\.documentIndex)
        }
        // "Rhode Island" is a place, so Rome gets no island filter.
        #expect(found("Rhode Island or Rome") == [0, 1, 4])
        // "Cape May" resolves as a place, not as May, so it takes the other side's length.
        #expect(found("Cape May or Rome long trips") == [1, 3])

        // Each side keeps its own resolved reading: "Ha Long" is a place
        // (no long bound), and only Rome's side asks for short trips.
        let short = [trip("Ha Long", year: 2024, durationDays: 3), trip("Rome", year: 2024, durationDays: 3)]
        let hits = TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: short), query: "Ha Long trips or Rome short trips",
            allowsTrailingPartial: false, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
        #expect(hits.map(\.documentIndex) == [0, 1])
        #expect(hits.allSatisfy { $0.strength != .partial })
    }

    @Test("each side resolves like a query of its own, title matches included")
    func sidesUseTheFullResolver() {
        func titled(_ title: String, place: String) -> TripSearchDocument {
            let document = trip(place, year: 2024)
            return TripSearchDocument(
                tripID: document.tripID,
                fields: [TripSearchField(kind: .title, displayValues: [title])] + document.fields.dropFirst(),
                startDate: document.startDate, endDate: document.endDate, startYear: document.startYear,
                startMonth: document.startMonth, durationDays: document.durationDays, isComplete: true)
        }
        // Four-day trips whose titles say "Weekend": the engine pass finds each title.
        let documents = [titled("Paris Weekend", place: "Paris"), titled("Rome Weekend", place: "Rome")]
        func search(_ query: String, typing: Bool = false) -> [TripSearchMatch] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
        }
        for query in ["Paris weekend", "Rome weekend"] {
            #expect(search(query).contains { $0.strength != .partial }, "\(query)")
        }
        let both = search("Paris weekend or Rome weekend")
        #expect(both.map(\.documentIndex) == [0, 1])
        #expect(both.allSatisfy { $0.strength != .partial })
        #expect(search("Paris weekend or Rome weeke", typing: true).filter { $0.strength != .partial }
            .map(\.documentIndex) == [0, 1])
    }

    @Test("a side with shared place words matches like the single query with them typed in")
    func sharedPlaceWordsAreTyped() {
        func places(_ values: [String], year: Int) -> TripSearchDocument {
            let document = trip(values[0], year: year)
            return TripSearchDocument(
                tripID: document.tripID,
                fields: [TripSearchField(kind: .title, displayValues: [values.joined(separator: ", ")]),
                         TripSearchField(kind: .place, displayValues: values)] + document.fields.dropFirst(2),
                startDate: document.startDate, endDate: document.endDate, startYear: document.startYear,
                startMonth: document.startMonth, durationDays: document.durationDays, isComplete: true)
        }
        // 0 Cape May 2014, 1 Cape May 2024, 2 Cape Town and Mayfair 2024.
        let documents = [
            places(["Cape May"], year: 2014), places(["Cape May"], year: 2024),
            places(["Cape Town", "Mayfair"], year: 2024),
        ]
        func found(_ query: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }
                .map(\.documentIndex)
        }
        // "may" next to "cape" is a whole place word, in a single query and on a side.
        #expect(found("Cape May after 2020") == [1])
        #expect(found("Cape May before 2015") == [0])
        #expect(found("Cape May before 2015 or after 2020") == [0, 1])
        #expect(found("before 2015 or after 2020 Cape May") == [0, 1])

        // The lent text is the side as typed minus its own filters: "Ha Long
        // trips" keeps the place reading that matches whole words only, so
        // `ha` never prefixes Hanoi.
        let haLong = [
            places(["Ha Long"], year: 2014), places(["Ha Long"], year: 2024),
            places(["Hanoi", "Long Beach"], year: 2024),
        ]
        func foundHaLong(_ query: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: haLong), query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }
                .map(\.documentIndex)
        }
        #expect(foundHaLong("Ha Long trips after 2020") == [1])
        #expect(foundHaLong("Ha Long trips before 2015 or after 2020") == [0, 1])
    }

    @Test("a side lends its words without its own filter syntax")
    func borrowableText() {
        let parse = { (q: String) in TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en") }
        #expect(parse("Paris long trips before 2015").borrowableText == "paris trips")
        #expect(parse("Paris weekend 2024").borrowableText == "paris")
        #expect(parse("trips to Paris islands 2024").borrowableText == "trips to paris")
        // A name some trip has keeps its syntax words (`protectNames`).
        let corpus = TripSearchIndex(documents: [trip("Ha Long", year: 2014), trip("Cape May", year: 2014)])
        let named = { (q: String) in
            TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en", corpus: corpus)
        }
        #expect(named("Ha Long trips before 2015").borrowableText == "ha long trips")
        #expect(named("Cape May before 2015").borrowableText == "cape may")
    }

    @Test("the word being typed completes on the last side")
    func typing() {
        #expect(found("Paris or Ro", typing: true) == [0, 1, 2])
        // A side sharing the typed side's place words shares the word being typed.
        #expect(found("before 2015 or after 2020 Par", typing: true) == [0, 2])
    }

    @Test("sides are the query around a dropped or word")
    func sides() {
        let parse = { (q: String) in TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en") }
        #expect(parse("Paris or Rome 2021").disjunctionSides == ["paris", "rome 2021"])
        #expect(parse("Paris or").disjunctionSides.isEmpty)
        #expect(parse("summer 2024 or winter 2025").disjunctionSides.isEmpty)
        #expect(parse("Paris Rome").disjunctionSides.isEmpty)
    }
}
