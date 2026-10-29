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

    @Test("a bare name after a destination via a stop is another stop to it: Tokyo via Seoul or Taipei")
    func viaAlternativeKeepsDestination() {
        let trips = [
            trip("Tokyo", date(2024, 5, 10), transit: ["Seoul"]),
            trip("Tokyo", date(2024, 6, 10), transit: ["Taipei"]),
            trip("Taipei", date(2024, 7, 10)),
            trip("Paris", date(2024, 8, 10), transit: ["Taipei"]),
        ]
        #expect(found(trips, "Tokyo via Seoul or Taipei") == [0, 1])
        #expect(found(trips, "Tokyo via Seoul 2024 or Taipei") == [0, 1])
        #expect(found(trips, "Tokyo Seoul üzerinden veya Taipei", languageTag: "tr") == [0, 1])
        // A side with its own via, or no via at all, keeps its own scope.
        #expect(found(trips, "Tokyo via Seoul or Paris via Taipei") == [0, 3])
        #expect(found(trips, "via Seoul or Taipei") == [0, 1, 3])
        let either = found(trips, "Tokyo or Taipei")
        #expect(either.contains(0) && either.contains(1) && either.contains(2))
    }

    @Test("an inherited via scopes the alternative's place, not its filters, until a side with its own scope")
    func viaAlternativeScopeEnds() {
        let trips = [
            trip("Tokyo", date(2024, 5, 10), transit: ["Seoul"]),
            trip("Tokyo", date(2024, 6, 10), transit: ["Taipei"]),
            trip("Tokyo", date(2023, 6, 10), transit: ["Taipei"]),
            trip("Paris", date(2024, 8, 10)),
            trip("Rome", date(2024, 9, 10)),
            trip("Tokyo", date(2024, 10, 10), transit: ["Bangkok"]),
            trip("Bangkok", date(2024, 11, 10)),
        ]
        // The year stays a year on the side that names it, and is lent to the other.
        #expect(found(trips, "Tokyo via Seoul or 2024 Taipei") == [0, 1])
        #expect(found(trips, "Tokyo Seoul üzerinden veya Taipei 2024", languageTag: "tr") == [0, 1])
        // An explicit destination ends the via scope for the sides after it.
        #expect(found(trips, "Tokyo via Seoul or to Paris or Rome") == [0, 3, 4])
        // A run of bare names stays in it.
        #expect(found(trips, "Tokyo via Seoul or Taipei or Bangkok") == [0, 1, 2, 5])
    }

    @Test("a date's preposition is the date's, not the side's own scope: Tokyo via Rome or Lima in 2024")
    func viaAlternativeDatePreposition() {
        let trips = [
            trip("Tokyo", date(2024, 5, 10), transit: ["Lima"]),
            trip("Lima", date(2024, 5, 12)),
            trip("Paris", date(2024, 5, 14), transit: ["Lima"]),
            trip("Tokyo", date(2023, 5, 10), transit: ["Lima"]),
            trip("Tokyo", date(2024, 5, 20), transit: ["Rome"]),
            trip("Tokyo", date(2023, 5, 20), transit: ["Rome"]),
        ]
        for typing in [false, true] {
            for query in ["Tokyo via Rome or Lima 2024", "Tokyo via Rome or Lima in 2024", "Tokyo via Rome or Lima in May 2024"] {
                #expect(found(trips, query, typing: typing) == [0, 4], "\(query) \(typing)")
            }
            #expect(found(trips, "Tokyo über Rome oder Lima in 2024", languageTag: "de", typing: typing) == [0, 4])
            // A via word after the place takes the place without the date's particle.
            #expect(found(trips, "Tokyo Rome 경유 또는 Lima 2024년에", languageTag: "ko", typing: typing) == [0, 4])
            // An explicit destination is still its own scope.
            let scoped = found(trips, "Tokyo via Rome or to Lima in 2024", typing: typing)
            #expect(scoped.contains(1) && scoped.contains(4) && !scoped.contains(5), "\(typing)")
        }
        // A holiday word the side reads as a place keeps its connector:
        // `para Natal` is a destination of its own, not a stop to Tóquio.
        let natal = [
            trip("Tóquio", date(2024, 5, 10), transit: ["Roma"]),
            trip("Tóquio", date(2024, 5, 12), transit: ["Natal"]),
            trip("Natal", date(2024, 5, 14)),
            trip("Natal", date(2023, 5, 14)),
        ]
        for typing in [false, true] {
            #expect(found(natal, "Tóquio via Roma ou para Natal em 2024", languageTag: "pt-BR", typing: typing) == [0, 2])
        }
        // A postposition written onto the place (Japanese `リマへ`, to Lima)
        // is the place's own scope, not the year's.
        let japanese = [
            trip("東京", date(2024, 5, 10), transit: ["リマ"]),
            trip("リマ", date(2024, 5, 12)),
            trip("東京", date(2023, 5, 10), transit: ["リマ"]),
            trip("東京", date(2024, 5, 20), transit: ["ローマ"]),
        ]
        for typing in [false, true] {
            let scoped = found(japanese, "東京 ローマ経由 or リマへ 2024年", languageTag: "ja", typing: typing)
            #expect(scoped.contains(1) && scoped.contains(3) && !scoped.contains(2), "\(typing)")
        }
        let bare = { (query: String, languageTag: String) in
            TripQueryParser.parse(query, now: now, calendar: utcCal, languageTag: languageTag).isBareNames
        }
        for (query, languageTag) in [
            ("Lima in 2024", "en"), ("Lima in summer", "en"), ("in 2024 Lima", "en"), ("Lima im Sommer", "de"),
            ("Lima en 2024", "fr"), ("Lima en 2024", "es"), ("Λίμα το 2024", "el"), ("리마 2024년에", "ko"),
        ] {
            #expect(bare(query, languageTag), "\(query)")
        }
        for (query, languageTag) in [
            ("to Lima in 2024", "en"), ("Lima trips in 2024", "en"), ("in 2024 to Lima", "en"),
            ("nach Lima 2024", "de"), ("στη Λίμα το 2024", "el"), ("リマへ 2024年", "ja"),
        ] {
            #expect(!bare(query, languageTag), "\(query)")
        }
    }

    @Test("a place a via word joins is finished when a filter follows it: via Nice or Austria 2024")
    func viaAlternativeFinishedBeforeFilter() {
        let trips = [
            trip("Kostavo", date(2024, 5, 10), transit: ["Nice"]),
            trip("Marenza", date(2024, 6, 10), transit: ["Austria"]),
            trip("Ostrel", date(2024, 7, 10), transit: ["Austriana"]),
        ]
        #expect(found(trips, "via Nice or Austria 2024", typing: true) == [0, 1])
        let tokyo = [
            trip("Tokyo", date(2024, 5, 10), transit: ["Seoul"]),
            trip("Tokyo", date(2024, 6, 10), transit: ["Austria"]),
            trip("Tokyo", date(2024, 7, 10), transit: ["Austriana"]),
        ]
        #expect(found(tokyo, "Tokyo via Seoul or Austria 2024", typing: true) == [0, 1])
    }

    @Test("a side that borrows via place words keeps their via scope: via Seoul before 2015 or after 2020")
    func viaScopeLentWithPlaces() {
        let trips = [
            trip("Tokyo", date(2014, 5, 10), transit: ["Seoul"]),
            trip("Tokyo", date(2024, 5, 10), transit: ["Seoul"]),
            trip("Seoul", date(2024, 6, 10)),
            trip("Tokyo", date(2018, 5, 10), transit: ["Seoul"]),
        ]
        for typing in [false, true] {
            #expect(found(trips, "via Seoul before 2015 or after 2020", typing: typing) == [0, 1], "\(typing)")
        }
    }

    @Test("a via word that starts a whole duration comparative is the comparative: über eine Woche")
    func durationComparativeBeforeVia() {
        let trips = [
            trip("Kostavo", date(2024, 5, 10), days: 10),
            trip("Marenza", date(2024, 6, 10), days: 3),
            trip("Ostrel", date(2024, 7, 10), transit: ["Wien"]),
        ]
        for corpus in [nil, TripSearchIndex(documents: trips)] {
            let p = TripQueryParser.parse(
                "Reisen über eine Woche", now: now, calendar: utcCal, languageTag: "de", corpus: corpus)
            #expect(p.minDurationDays == 8 && p.maxDurationDays == nil)
            #expect(p.viaTerms.isEmpty && p.placeTerms.isEmpty)
        }
        for typing in [false, true] {
            #expect(found(trips, "Reisen über eine Woche", languageTag: "de", typing: typing) == [0], "\(typing)")
        }
        // Before a place it is still via.
        #expect(found(trips, "über Wien", languageTag: "de") == [2])
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
