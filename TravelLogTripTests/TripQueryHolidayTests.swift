//
//  TripQueryHolidayTests.swift
//  TravelLogTests
//
//  Holidays as date filters (`TripQueryHoliday`, `ParsedQuery.holidays`):
//  the computed Western and Orthodox Easter, each holiday's days, the
//  words that name them in the parser's languages, and searches that keep
//  the trips overlapping those days. Invented trips, UTC.
//

import Foundation
import Testing
@testable import TravelLog

struct TripQueryHolidayTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    // MARK: - Dates

    @Test("Easter Sunday by both computuses")
    func easterDates() {
        let western = [2023: (4, 9), 2024: (3, 31), 2025: (4, 20), 2026: (4, 5), 2000: (4, 23)]
        let orthodox = [2023: (4, 16), 2024: (5, 5), 2025: (4, 20), 2026: (4, 12), 2000: (4, 30)]
        for (year, day) in western {
            let easter = TripQueryHoliday.westernEaster(year)
            #expect(easter.month == day.0 && easter.day == day.1, "\(year)")
        }
        for (year, day) in orthodox {
            let easter = TripQueryHoliday.orthodoxEaster(year)
            #expect(easter.year == year && easter.month == day.0 && easter.day == day.1, "\(year)")
        }
    }

    @Test("each holiday's days")
    func holidayDays() {
        let christmas = TripQueryHoliday.christmas.windows(in: 2024)[0]
        #expect(christmas.first == DateComponents(year: 2024, month: 12, day: 24))
        #expect(christmas.last == DateComponents(year: 2024, month: 12, day: 26))
        let newYear = TripQueryHoliday.newYear.windows(in: 2025)[0]
        #expect(newYear.first == DateComponents(year: 2024, month: 12, day: 31))
        #expect(newYear.last == DateComponents(year: 2025, month: 1, day: 1))
        // Good Friday to Easter Monday.
        let easter = TripQueryHoliday.westernEaster.windows(in: 2024)[0]
        #expect(easter.first == DateComponents(year: 2024, month: 3, day: 29))
        #expect(easter.last == DateComponents(year: 2024, month: 4, day: 1))
        #expect(TripQueryHoliday.assumption.windows(in: 2023)[0].first == DateComponents(year: 2023, month: 8, day: 15))
    }

    // MARK: - Words

    @Test(
        "holiday words in the parser's languages",
        arguments: [
            ("christmas", "en", [TripQueryHoliday.christmas]), ("xmas", "en", [.christmas]),
            ("new year", "en", [.newYear]), ("new year's eve", "en", [.newYearsEve]),
            ("easter", "en", [.westernEaster, .orthodoxEaster]),
            ("Χριστούγεννα", "el", [.christmas]), ("Πάσχα", "el", [.orthodoxEaster]),
            ("Πάσχα", "en", [.orthodoxEaster]), ("Δεκαπενταύγουστος", "el", [.assumption]),
            ("Weihnachten", "de", [.christmas]), ("Ostern", "de", [.westernEaster]), ("Silvester", "de", [.newYearsEve]),
            ("Noël", "fr", [.christmas]), ("Pâques", "fr", [.westernEaster]), ("Semana Santa", "es", [.holyWeek]),
            ("Ferragosto", "it", [.assumption]), ("påsk", "sv", [.westernEaster]), ("yılbaşı", "tr", [.newYear]),
            ("クリスマス", "ja", [.christmas]), ("부활절", "ko", [.westernEaster]), ("圣诞节", "zh-Hans", [.christmas]),
        ] as [(String, String, Set<TripQueryHoliday>)]
    )
    func holidayWords(query: String, languageTag: String, holidays: Set<TripQueryHoliday>) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.holidays == holidays, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.hasStructuredFilter, "\(query)")
    }

    @Test("a holiday word inside a place name, or no holiday at all, stays place text")
    func placesStayPlaces() {
        #expect(parse("Christmas Island").holidays.isEmpty)
        #expect(parse("new york").holidays.isEmpty)
        // Every holiday word is tried as a place word first (Natal).
        #expect(parse("Natal", languageTag: "pt-BR").placeInterpretation?.holidays.isEmpty == true)
    }

    // MARK: - Search

    private func trip(_ place: String, from start: Date, to end: Date) -> TripSearchDocument {
        let days = (utcCal.dateComponents([.day], from: utcCal.startOfDay(for: start), to: utcCal.startOfDay(for: end)).day ?? 0) + 1
        let parts = utcCal.dateComponents([.year, .month], from: start)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(
                    kind: .date,
                    displayValues: TripSearchDocument.dateWords(start: start, end: end, languageTag: "en", calendar: utcCal)),
            ],
            startDate: start, endDate: end, startYear: parts.year!, startMonth: parts.month!,
            durationDays: days, isComplete: true)
    }

    /// 0 Christmas 2023, 1 New Year 2024, 2 Western Easter 2024, 3 Orthodox
    /// Easter 2024, 4 Assumption 2023, 5 none, 6 Christmas 2021.
    private var trips: [TripSearchDocument] {
        [
            trip("Valdoria", from: date(2023, 12, 22), to: date(2023, 12, 27)),
            trip("Port Ellis", from: date(2023, 12, 30), to: date(2024, 1, 2)),
            trip("Marenza", from: date(2024, 3, 28), to: date(2024, 4, 2)),
            trip("Kostavo", from: date(2024, 5, 2), to: date(2024, 5, 7)),
            trip("Valdoria", from: date(2023, 8, 13), to: date(2023, 8, 17)),
            trip("Marenza", from: date(2024, 7, 1), to: date(2024, 7, 9)),
            trip("Kostavo", from: date(2021, 12, 26), to: date(2021, 12, 29)),
        ]
    }

    private func found(_ query: String, languageTag: String = "en") -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    @Test("holidays keep the trips overlapping their days, with years, places and or")
    func search() {
        #expect(found("christmas") == [0, 6])
        #expect(found("christmas 2023") == [0])
        #expect(found("new year") == [1])
        #expect(found("new year 2024") == [1])
        #expect(found("new year's eve") == [1])
        #expect(found("easter") == [2, 3])
        #expect(found("Πάσχα", languageTag: "el") == [3])
        #expect(found("Ostern", languageTag: "de") == [2])
        #expect(found("Δεκαπενταύγουστος", languageTag: "el") == [4])
        #expect(found("Ferragosto", languageTag: "it") == [4])
        #expect(found("Valdoria christmas") == [0])
        #expect(found("Kostavo at christmas") == [6])
        #expect(found("christmas 2023 or easter 2024") == [0, 2, 3])
        #expect(found("christmas 2022").isEmpty)
    }

    @Test("a year with a holiday is the holiday's year, not any year the trip touches")
    func holidayYearOnTripAcrossNewYear() {
        let index = TripSearchIndex(documents: [trip("Valdoria", from: date(2023, 12, 25), to: date(2024, 1, 1))])
        func found(_ query: String) -> Int {
            TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }.count
        }
        #expect(found("christmas 2023") == 1)
        #expect(found("new year 2024") == 1)
        #expect(found("christmas 2024") == 0)
        #expect(found("Valdoria christmas 2024") == 0)
        #expect(found("new year 2023") == 0)
    }

    @Test("a holiday's year names its window: New Year's Eve 2023 is in new year 2024")
    func holidayYearNamesTheWindow() {
        let index = TripSearchIndex(documents: [trip("Valdoria", from: date(2023, 12, 31), to: date(2023, 12, 31))])
        func found(_ query: String) -> Int {
            TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }.count
        }
        #expect(found("new year 2024") == 1)
        #expect(found("Valdoria new year 2024") == 1)
        #expect(found("new year's eve 2023") == 1)
        #expect(found("new year 2023") == 0)
        #expect(found("new year's eve 2024") == 0)
    }

    @Test("a holiday word that is a trip's whole title finds that trip")
    func holidayWordAsTitle() {
        let start = date(2024, 6, 10)
        let named = TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: ["Noel"]),
                TripSearchField(kind: .place, displayValues: ["Valdoria"]),
            ],
            startDate: start, endDate: date(2024, 6, 14), startYear: 2024, startMonth: 6,
            durationDays: 5, isComplete: true)
        let documents = [named, trip("Marenza", from: date(2023, 12, 22), to: date(2023, 12, 27))]
        func found(_ query: String, _ languageTag: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
                .filter { $0.strength != .partial }.map(\.documentIndex)
        }
        #expect(found("Noel", "fr") == [0])
        // A title with an apostrophe suffix normalizes like the query.
        let eve = TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: ["New Year’s Eve"]),
                TripSearchField(kind: .place, displayValues: ["Kostavo"]),
            ],
            startDate: start, endDate: date(2024, 6, 14), startYear: 2024, startMonth: 6,
            durationDays: 5, isComplete: true)
        let eveFound = TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: [eve]), query: "New Year's Eve", allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: "en")
            .filter { $0.strength != .partial }.count
        #expect(eveFound == 1)
        #expect(found("Noël", "fr") == [0])
        // A holiday word inside a longer title stays the holiday.
        #expect(found("Marenza Noël", "fr") == [1])
    }
}
