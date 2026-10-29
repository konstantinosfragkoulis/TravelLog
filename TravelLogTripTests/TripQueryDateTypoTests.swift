//
//  TripQueryDateTypoTests.swift
//  TravelLogTests
//
//  Misspelt month, season and weekend words (`correctDateTypos`): with the
//  searched corpus, a word of 5+ letters that no trip matches in any way
//  and that is one edit (two when both words have 8+ letters) from exactly
//  one date meaning with the same first letter reads as that word. Pure
//  parses and searches with an injected `now` (2026-07-14, UTC).
//

import Testing
import Foundation
@testable import TravelLog

struct TripQueryDateTypoTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func trip(_ place: String, year: Int, month: Int, durationDays: Int = 4) -> TripSearchDocument {
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

    private var trips: [TripSearchDocument] {
        [
            trip("Lisbon", year: 2025, month: 8),
            trip("Lisbon", year: 2024, month: 2),
            trip("Oslo", year: 2025, month: 12, durationDays: 2),
            trip("Marsh Harbour", year: 2023, month: 3),
        ]
    }

    private func parse(_ q: String, corpus: [TripSearchDocument]?, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(
            q, now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag,
            corpus: corpus.map { TripSearchIndex(documents: $0) })
    }

    private func found(_ trips: [TripSearchDocument], _ query: String, typing: Bool = false) -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: typing,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
            .map(\.documentIndex)
    }

    @Test(
        "a misspelt date word reads as the word it misspells",
        arguments: [
            ("Agust 2025", [8]), ("Febuary 2024", [2]), ("Decmber 2025", [12]), ("Novembar 2025", [11]),
            // Two edits once both words have 8+ letters.
            ("Septmbre 2025", [9]),
            ("Sumer 2025", [6, 7, 8]),
        ] as [(String, Set<Int>)]
    )
    func corrected(query: String, months: Set<Int>) {
        let p = parse(query, corpus: trips)
        #expect(p.months == months, "\(query)")
        #expect(p.years == [2025] || p.years == [2024], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("a misspelt weekend word is a weekend")
    func weekendTypo() {
        let p = parse("Lisbon wekend", corpus: trips)
        #expect(p.minDurationDays == 2 && p.maxDurationDays == 3)
        #expect(p.placeTerms.map(\.raw) == ["lisbon"])
    }

    @Test(
        "short, distant, differently starting, known or matching words stay place text",
        arguments: [
            "Agst 2025",       // 4 letters
            "Decmbr 2025",     // two edits below 8 letters
            "Ougust 2025",     // another first letter
            "Marsh 2023",      // a trip's own word
            "Marsha 2023",     // the engine matches it (Marsh Harbour by typo)
        ]
    )
    func notCorrected(query: String) {
        let p = parse(query, corpus: trips)
        #expect(p.months.isEmpty, "\(query)")
        #expect(p.placeTerms.count == 1, "\(query)")
    }

    @Test("without a corpus nothing is corrected")
    func needsCorpus() {
        let p = parse("Agust 2025", corpus: nil)
        #expect(p.months.isEmpty)
        #expect(p.placeTerms.map(\.raw) == ["agust"])
    }

    @Test("a corrected bare month stays ambiguous, so the place reading runs first")
    func correctedBareMonthIsAmbiguous() throws {
        let p = parse("Agust", corpus: trips)
        #expect(p.months == [8])
        #expect(p.ambiguousDateTokens == ["agust"])
        #expect(p.placeInterpretation != nil)
    }

    @Test("searches find the misspelt month's trips, typed or finished")
    func search() {
        let trips = trips
        #expect(found(trips, "Agust 2025") == [0])
        #expect(found(trips, "Lisbon Febuary") == [1])
        #expect(found(trips, "Febuary 2024", typing: true) == [1])
        #expect(found(trips, "Decmber") == [2])
    }
}
