//
//  TripSearchNameSpanTests.swift
//  TravelLogTests
//
//  Names before syntax (`TripSearchIndex.namePhrase`, the parser's name
//  pass): a multiword name some trip has (Cape May, Spring Hill, Ha Long,
//  Long Beach, Weekend Island) is place text before any date, duration or
//  facet word inside it reads as syntax, while complete date and duration
//  expressions keep their meaning next to a colliding one-word name
//  (May 2024, mars 2024, last winter, long weekend). Via takes a whole
//  known name, "or" keeps an unmatched side as no trips, and typing a date
//  word offers the places it starts as similar matches. Invented trips and
//  generic place names; every positive case has a decoy.
//

import Foundation
import Testing
@testable import TravelLog

struct TripSearchNameSpanTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    private var now: Date { date(2026, 7, 14) }

    /// A trip to `place` (and `transit` stops) from `start`, `days` long.
    private func trip(
        _ place: String, _ start: Date, days: Int = 5, transit: [String] = [], title: String? = nil,
        alternate: String? = nil
    ) -> TripSearchDocument {
        let end = start.addingTimeInterval(Double(days - 1) * 86_400)
        let parts = utcCal.dateComponents([.year, .month], from: start)
        var fields = [
            TripSearchField(kind: .title, displayValues: [title ?? place]),
            TripSearchField(kind: .place, displayValues: [place]),
            TripSearchField(
                kind: .date,
                displayValues: TripSearchDocument.dateWords(start: start, end: end, languageTag: "en", calendar: utcCal)),
        ]
        if !transit.isEmpty { fields.append(TripSearchField(kind: .transit, displayValues: transit)) }
        if let alternate { fields.append(TripSearchField(kind: .place, displayValues: [alternate], alternateOf: [place])) }
        return TripSearchDocument(
            tripID: UUID(), fields: fields, startDate: start, endDate: end,
            startYear: parts.year!, startMonth: parts.month!, durationDays: days, isComplete: true)
    }

    private func search(
        _ documents: [TripSearchDocument], _ query: String, languageTag: String = "en", typing: Bool = false
    ) -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
            now: now, calendar: utcCal, languageTag: languageTag)
    }

    private func found(
        _ documents: [TripSearchDocument], _ query: String, languageTag: String = "en", typing: Bool = false
    ) -> [Int] {
        search(documents, query, languageTag: languageTag, typing: typing)
            .filter { $0.strength != .partial }.map(\.documentIndex)
    }

    private func strong(
        _ documents: [TripSearchDocument], _ query: String, languageTag: String = "en", typing: Bool = false
    ) -> [Int] {
        search(documents, query, languageTag: languageTag, typing: typing)
            .filter { $0.strength == .strong }.map(\.documentIndex)
    }

    // MARK: - Names before syntax

    @Test("a multiword name with a date word keeps it: Cape May 2024")
    func capeMay() {
        let trips = [
            trip("Cape May", date(2024, 6, 10)),
            trip("Cape Town", date(2024, 5, 10)),
            trip("Cape May", date(2023, 6, 10)),
        ]
        #expect(found(trips, "Cape May 2024") == [0])
        #expect(found(trips, "trips to Cape May 2024") == [0])
        #expect(found(trips, "Cape Town May 2024") == [1])
        #expect(TripQueryParser.parse("Cape May 2024", now: now, calendar: utcCal, languageTag: "en",
                                      corpus: TripSearchIndex(documents: trips)).years == [2024])
    }

    @Test("a name with a frame or weekend word inside stays a name: in Spring Hill, Weekend Island")
    func frameAndWeekendInsideNames() {
        let trips = [
            trip("Spring Hill", date(2024, 10, 3)),
            trip("Valdoria", date(2024, 4, 3)),
            trip("Weekend Island", date(2024, 8, 1), days: 10),
            trip("Marenza", date(2024, 9, 6), days: 2),
        ]
        #expect(found(trips, "in Spring Hill") == [0])
        #expect(found(trips, "Weekend Island") == [2])
        // Without the names, the syntax as before.
        #expect(found(trips, "Valdoria in spring") == [1])
        #expect(found(trips, "Marenza weekend") == [3])
    }

    @Test("a length word after a name that ends in one is still a length: Ha Long long trips, Long Beach long weekend")
    func repeatedLengthWords() {
        let trips = [
            trip("Ha Long", date(2024, 3, 1), days: 10),
            trip("Ha Long", date(2024, 4, 1), days: 3),
            trip("Valdoria", date(2024, 5, 1), days: 10),
            trip("Long Beach", date(2024, 6, 7), days: 3),
            trip("Long Beach", date(2024, 7, 1), days: 10),
        ]
        #expect(found(trips, "Ha Long long trips") == [0])
        #expect(found(trips, "Long Beach long weekend") == [3])
        #expect(found(trips, "Ha Long trips") == [0, 1])
    }

    @Test("a name only a transit stop has keeps no syntax word from its reading, except after via")
    func transitOnlyNames() {
        let trips = [
            trip("Kostavo", date(2024, 10, 3), transit: ["Spring Hill"]),
            trip("Valdoria", date(2024, 4, 3)),
        ]
        let parsed = TripQueryParser.parse(
            "in Spring Hill", now: now, calendar: utcCal, languageTag: "en", corpus: TripSearchIndex(documents: trips))
        #expect(parsed.namePhrases.isEmpty)
        #expect(parsed.months == [3, 4, 5])
        #expect(found(trips, "via Spring Hill") == [0])
    }

    // MARK: - Complete dates and durations beside a one-word name

    @Test(
        "a complete date or duration keeps its meaning when one trip's place has that name",
        arguments: [
            ("May 2024", "en", "May", 5), ("mars 2024", "fr", "Mars", 3), ("Mayo 2024", "es", "Mayo", 5),
            ("Αύγουστος 2024", "el", "Αύγουστος", 8),
        ]
    )
    func monthYearBeatsOneWordPlace(query: String, languageTag: String, place: String, month: Int) {
        // 0 is in that month; 1 is a place of that name, the same year.
        let trips = [trip("Valdoria", date(2024, month, 10)), trip(place, date(2024, 11, 2))]
        #expect(strong(trips, query, languageTag: languageTag) == [0], "\(query)")
        // The place of that name in that year is a suggestion, never a full
        // match (Siri and Shortcuts take full matches as answers).
        #expect(found(trips, query, languageTag: languageTag) == [0], "\(query)")
        let suggested = search(trips, query, languageTag: languageTag).filter { $0.strength == .partial }.map(\.documentIndex)
        #expect(suggested == [1], "\(query)")
    }

    @Test("the place named like the month replaces only the month: every other constraint still applies")
    func monthPlaceKeepsOtherConstraints() {
        let trips = [
            trip("May", date(2024, 6, 10)),
            trip("May", date(2024, 12, 22)),
            trip("May", date(2024, 8, 1), days: 12),
            trip("Valdoria", date(2023, 5, 10)),
        ]
        let suggested = { (query: String) in
            search(trips, query).filter { $0.strength == .partial }.map(\.documentIndex)
        }
        #expect(suggested("May 2024 Christmas") == [1])
        #expect(suggested("May 2024 long trips") == [2])
        #expect(suggested("May 2024") == [0, 1, 2])
        #expect(found(trips, "May 2024").isEmpty)
        #expect(found(trips, "May 2023") == [3])
    }

    @Test("the place named like the month must be that whole name: Cape May is not May")
    func monthPlaceNeedsWholeName() {
        let trips = [
            trip("Cape May", date(2024, 6, 10)),
            trip("May", date(2022, 6, 10)),
            trip("May", date(2024, 9, 10)),
            trip("Valdoria", date(2024, 5, 10)),
        ]
        let results = search(trips, "May 2024")
        #expect(results.filter { $0.strength == .strong }.map(\.documentIndex) == [3])
        #expect(results.filter { $0.strength == .partial }.map(\.documentIndex) == [2])
        #expect(!results.contains { $0.documentIndex == 0 })
    }

    @Test("adding a colliding destination, transit stop or alternate name keeps explicit dates and durations")
    func pairedCorpora() {
        let cases: [(query: String, tag: String, base: TripSearchDocument, decoy: TripSearchDocument)] = [
            ("May 2024", "en", trip("Valdoria", date(2024, 5, 10)), trip("May", date(2022, 2, 1))),
            ("last winter", "en", trip("Valdoria", date(2026, 1, 10)), trip("Winter", date(2022, 2, 1))),
            ("long weekend", "en", trip("Valdoria", date(2024, 5, 10), days: 3), trip("Long", date(2022, 2, 1))),
            ("long weekend trips", "en", trip("Valdoria", date(2024, 5, 10), days: 3),
             trip("Long Weekend Island", date(2022, 2, 1))),
            ("summer 2024", "en", trip("Valdoria", date(2024, 7, 10)),
             trip("Marenza", date(2022, 2, 1), transit: ["Summer"])),
            ("mars 2024", "fr", trip("Valdoria", date(2024, 3, 10)),
             trip("Marenza", date(2022, 2, 1), alternate: "Mars")),
            ("Αύγουστος 2024", "el", trip("Valdoria", date(2024, 8, 10)), trip("Αύγουστος", date(2022, 2, 1))),
            ("καλοκαίρι 2024", "el", trip("Valdoria", date(2024, 7, 10)),
             trip("Marenza", date(2022, 2, 1), transit: ["Καλοκαίρι"])),
            ("去年の夏", "ja", trip("Valdoria", date(2025, 7, 10)), trip("夏", date(2022, 2, 1))),
            ("2024年5月", "ja", trip("Valdoria", date(2024, 5, 10)), trip("五月", date(2022, 2, 1))),
        ]
        for item in cases {
            #expect(found([item.base], item.query, languageTag: item.tag) == [0], "\(item.query) alone")
            #expect(found([item.base, item.decoy], item.query, languageTag: item.tag).contains(0),
                    "\(item.query) with \(item.decoy.fields[1].displayValues)")
        }
    }

    @Test("Han and kana: a date beside a name stays a date; a name with a season character stays a name")
    func cjk() {
        let trips = [
            trip("東京", date(2024, 5, 10)),
            trip("東京", date(2023, 5, 10)),
            trip("夏威夷", date(2024, 12, 20)),
        ]
        #expect(found(trips, "東京2024年5月", languageTag: "ja") == [0])
        #expect(found(trips, "夏威夷", languageTag: "zh-Hans") == [2])
    }

    @Test("a protected word still matches a title")
    func titlesStillMatch() {
        let trips = [
            trip("Valdoria", date(2024, 5, 10), title: "Nice escape"),
            trip("Nice", date(2024, 6, 10)),
        ]
        #expect(found(trips, "nice") == [0, 1])
        #expect(found(trips, "Nice escape") == [0])
    }

    // MARK: - Typing

    @Test(
        "a typed date word keeps its dates; the places it starts are similar matches",
        arguments: [("Mars", "fr", "Marsolène", 3), ("Aug", "en", "Augsburg", 8), ("summer", "en", "Summerland", 7)]
    )
    func typedDateWords(query: String, languageTag: String, place: String, month: Int) {
        let trips = [trip("Valdoria", date(2024, month, 10)), trip(place, date(2024, 11, 2))]
        #expect(strong(trips, query, languageTag: languageTag, typing: true) == [0], "\(query)")
        #expect(found(trips, query, languageTag: languageTag, typing: true) == [0, 1], "\(query)")
    }

    // MARK: - Via

    @Test("via takes a whole known name, a function word included (Dutch via Van)")
    func viaKnownFunctionWordName() {
        let trips = [
            trip("Kostavo", date(2024, 5, 10), transit: ["Van"]),
            trip("Marenza", date(2024, 6, 10)),
        ]
        #expect(found(trips, "via Van", languageTag: "nl") == [0])
    }

    @Test("a whole known name that is also a function word stays a name on its own: Dutch Nice or Van, via Nice or Van")
    func knownFunctionWordNameAlone() {
        let trips = [
            trip("Kostavo", date(2024, 5, 10), transit: ["Nice"]),
            trip("Marenza", date(2024, 6, 10), transit: ["Van"]),
            trip("Van", date(2024, 7, 10)),
            trip("Nice", date(2024, 8, 10)),
            trip("Ostrel", date(2024, 9, 10)),
        ]
        #expect(found(trips, "via Nice or Van", languageTag: "nl") == [0, 1])
        #expect(found(trips, "via Van or Nice", languageTag: "nl") == [0, 1])
        let either = found(trips, "Nice or Van", languageTag: "nl")
        #expect(either.contains(2) && either.contains(3) && !either.contains(4))
        #expect(Set(either) == Set(found(trips, "Nice", languageTag: "nl") + found(trips, "Van", languageTag: "nl")))
        #expect(strong(trips, "Van", languageTag: "nl") == [2])
        // Beside other words it is still a function word.
        #expect(found(trips, "reizen van 2024", languageTag: "nl") == [0, 1, 2, 3, 4])
        #expect(found(trips, "Ostrel van 2024", languageTag: "nl") == [4])
    }

    @Test("a side of several function words keeps them function words, a town called Of recorded")
    func functionWordsBesideKnownName() {
        let trips = [trip("Of", date(2024, 5, 10)), trip("Valdoria", date(2024, 6, 10))]
        // As without the town: "of" is no place here.
        #expect(found(trips, "all of my trips") == found([trips[1]], "all of my trips").map { $0 + 1 })
        #expect(!found(trips, "all of my trips").contains(0))
        #expect(strong(trips, "Of") == [0])
    }

    @Test("via before names joined by or applies to each: via Nice or Split")
    func viaDistributesOverOr() {
        let trips = [
            trip("Kostavo", date(2024, 5, 10), transit: ["Nice"]),
            trip("Marenza", date(2024, 6, 10), transit: ["Split"]),
            trip("Split", date(2024, 7, 10)),
            trip("Nice", date(2024, 8, 10)),
        ]
        #expect(found(trips, "via Nice or Split") == [0, 1])
        // An explicit destination is its own scope.
        let scoped = found(trips, "via Nice or to Split")
        #expect(scoped.contains(0) && scoped.contains(2) && !scoped.contains(3))
    }

    // MARK: - Or

    @Test("an or-side no trip matches adds nothing instead of undoing the or")
    func unmatchedOrSide() {
        let trips = [
            trip("Paris", date(2024, 5, 10)),
            trip("Rome", date(2024, 6, 10)),
            trip("Nice", date(2023, 6, 10)),
            trip("Nice", date(2024, 6, 10)),
        ]
        #expect(found(trips, "Paris or Atlantis") == [0])
        #expect(found(trips, "Atlantis or Rome") == [1])
        #expect(found(trips, "Nice or Split 2024") == [3])
        // No side matches: the single reading's partial matches, as before.
        #expect(found(trips, "Atlantis or Lemuria").isEmpty)
    }
}
