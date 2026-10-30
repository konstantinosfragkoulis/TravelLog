//
//  TripQueryCalendarTests.swift
//  TravelLogTests
//
//  Time in queries beyond months and years: each holiday rule's days
//  (`TripQueryHoliday.windows(in:)`: fixed dates, Easter offsets by either
//  computus, nth weekdays, bridges, lunar and Islamic dates), the words
//  that name them per language, calendar days (`15 august 2024`,
//  `2024年8月15日`), trip-length words and Han and Hangul lengths, recent
//  spans (`last 6 months`), weekend trips, and ongoing trips, whose days
//  run to today. Invented trips, UTC.
//

import Foundation
import Testing
@testable import TravelLog

struct TripQueryCalendarTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    private var now: Date { date(2026, 7, 14) }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: now, calendar: utcCal, languageTag: languageTag)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: m, day: d) }

    // MARK: - Holiday rules

    @Test(
        "each rule's days",
        arguments: [
            (TripQueryHoliday.thanksgiving, 2024, (2024, 11, 27), (2024, 12, 1)),
            (.memorialDay, 2024, (2024, 5, 25), (2024, 5, 27)),
            (.laborDay, 2024, (2024, 8, 31), (2024, 9, 2)),
            (.independenceDay, 2024, (2024, 7, 4), (2024, 7, 4)),
            (.carnival, 2024, (2024, 2, 8), (2024, 2, 13)),
            (.ascension, 2024, (2024, 5, 9), (2024, 5, 12)),
            (.pentecost, 2024, (2024, 5, 18), (2024, 5, 20)),
            (.orthodoxPentecost, 2024, (2024, 6, 22), (2024, 6, 24)),
            (.cleanMonday, 2024, (2024, 3, 16), (2024, 3, 18)),
            (.holyWeek, 2024, (2024, 3, 24), (2024, 4, 1)),
            (.betweenTheYears, 2024, (2024, 12, 27), (2024, 12, 30)),
            (.goldenWeek, 2024, (2024, 4, 29), (2024, 5, 5)),
            (.yearEndHolidays, 2024, (2024, 12, 29), (2025, 1, 3)),
            (.shogatsu, 2025, (2025, 1, 1), (2025, 1, 3)),
            (.midsummer, 2024, (2024, 6, 21), (2024, 6, 23)),
            // Equinox two days after Respect for the Aged Day: five days.
            (.silverWeek, 2015, (2015, 9, 19), (2015, 9, 23)),
            (.silverWeek, 2026, (2026, 9, 19), (2026, 9, 23)),
            // Equinox on the Sunday after: the long weekend alone.
            (.silverWeek, 2018, (2018, 9, 15), (2018, 9, 17)),
            // Bridged: Tuesday to Thursday becomes Saturday to Sunday.
            (.decemberBridge, 2016, (2016, 12, 3), (2016, 12, 11)),
            (.decemberBridge, 2017, (2017, 12, 6), (2017, 12, 10)),
            (.mayDayBridge, 2022, (2022, 4, 30), (2022, 5, 1)),
            (.allSaints, 2024, (2024, 11, 1), (2024, 11, 3)),
            (.springFestival, 2024, (2024, 2, 9), (2024, 2, 16)),
            (.seollal, 2024, (2024, 2, 9), (2024, 2, 11)),
            (.chuseok, 2024, (2024, 9, 16), (2024, 9, 18)),
            (.eidAlAdha, 2024, (2024, 6, 15), (2024, 6, 19)),
        ] as [(TripQueryHoliday, Int, (Int, Int, Int), (Int, Int, Int))]
    )
    func ruleDays(holiday: TripQueryHoliday, year: Int, first: (Int, Int, Int), last: (Int, Int, Int)) {
        let window = holiday.windows(in: year)[0]
        #expect(window.first == day(first.0, first.1, first.2), "\(holiday) \(year)")
        #expect(window.last == day(last.0, last.1, last.2), "\(holiday) \(year)")
    }

    @Test("an Islamic holiday can fall twice in one Gregorian year")
    func islamicTwice() {
        // Eid al-Fitr fell on 8 January and 27 December 2000.
        #expect(TripQueryHoliday.eidAlFitr.windows(in: 2000).count == 2)
        #expect(TripQueryHoliday.eidAlFitr.windows(in: 2024).count == 1)
    }

    // MARK: - Words

    @Test(
        "holiday words belong to the languages that keep them",
        arguments: [
            ("Thanksgiving", "en", [TripQueryHoliday.thanksgiving]), ("Labor Day weekend", "en", [.laborDay]),
            ("4th of July", "en", [.independenceDay]), ("labor day", "en", [.laborDay]),
            ("labour day", "en", [.laborDay, .mayDay]),
            ("Pfingsten", "de", [.pentecost]), ("Himmelfahrt", "de", [.ascension]),
            ("Mariä Himmelfahrt", "de", [.assumption]), ("zwischen den Jahren", "de", [.betweenTheYears]),
            ("Αγίου Πνεύματος", "el", [.orthodoxPentecost]), ("Καθαρά Δευτέρα", "el", [.cleanMonday]),
            ("Semana Santa", "es", [.holyWeek]), ("puente de mayo", "es", [.mayDayBridge]),
            ("puente de diciembre", "es", [.decemberBridge]), ("Toussaint", "fr", [.allSaints]),
            ("ゴールデンウィーク", "ja", [.goldenWeek]), ("GW", "ja", [.goldenWeek]), ("お盆", "ja", [.obon]),
            ("年末年始", "ja", [.yearEndHolidays]), ("正月", "ja", [.shogatsu]), ("シルバーウィーク", "ja", [.silverWeek]),
            ("추석", "ko", [.chuseok]), ("midsommar", "sv", [.midsummer]), ("Kurban Bayramı", "tr", [.eidAlAdha]),
            ("Tết", "vi", [.tet]), ("春节", "zh-Hans", [.springFestival]),
            ("黄金周", "zh-Hans", [.labourDayChina, .nationalDayChina]),
        ] as [(String, String, Set<TripQueryHoliday>)]
    )
    func holidayWords(query: String, languageTag: String, holidays: Set<TripQueryHoliday>) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.holidays == holidays, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.minDurationDays == nil && p.maxDurationDays == nil, "\(query)")
    }

    @Test("another country's holiday word is not active in the app's language")
    func holidayWordsStayHome() {
        #expect(parse("Pfingsten").holidays.isEmpty)
        #expect(parse("お盆", languageTag: "de").holidays == [.obon])  // kana adds Japanese
        #expect(parse("GW", languageTag: "de").holidays.isEmpty)
    }

    // MARK: - Search fixtures

    private func trip(_ place: String, from start: Date, to end: Date?) -> TripSearchDocument {
        let days = end.map {
            (utcCal.dateComponents([.day], from: utcCal.startOfDay(for: start), to: utcCal.startOfDay(for: $0)).day ?? 0) + 1
        }
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
            durationDays: days, isComplete: end != nil)
    }

    private func found(_ documents: [TripSearchDocument], _ query: String, languageTag: String = "en") -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
            now: now, calendar: utcCal, languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    /// 0 Thanksgiving 2024 weekend, 1 Pentecost 2024, 2 15 August 2024,
    /// 3 Golden Week 2019, 4 a June 2024 week, 5 ongoing since 1 July 2026.
    private var trips: [TripSearchDocument] {
        [
            trip("Valdoria", from: date(2024, 11, 29), to: date(2024, 12, 1)),
            trip("Marenza", from: date(2024, 5, 17), to: date(2024, 5, 20)),
            trip("Kostavo", from: date(2024, 8, 12), to: date(2024, 8, 18)),
            trip("Port Ellis", from: date(2019, 4, 27), to: date(2019, 5, 2)),
            trip("Valdoria", from: date(2024, 6, 3), to: date(2024, 6, 9)),
            trip("Marenza", from: date(2026, 7, 1), to: nil),
        ]
    }

    @Test("holidays keep the trips overlapping their days, with years and places")
    func holidaySearch() {
        #expect(found(trips, "thanksgiving") == [0])
        #expect(found(trips, "Valdoria thanksgiving 2024") == [0])
        #expect(found(trips, "thanksgiving 2023").isEmpty)
        #expect(found(trips, "Pfingsten 2024", languageTag: "de") == [1])
        #expect(found(trips, "2019年のGW", languageTag: "ja") == [3])
        #expect(found(trips, "Port Ellis GW", languageTag: "ja") == [3])
    }

    // MARK: - Calendar days

    @Test(
        "a day with its month, in each language's order",
        arguments: [
            ("15 august 2024", "en", 2024), ("august 15th, 2024", "en", 2024), ("the 15th of august", "en", nil),
            ("august 15", "en", nil), ("15. August 2024", "de", 2024), ("15 de agosto de 2024", "es", 2024),
            ("15 août 2024", "fr", 2024), ("2024年8月15日", "ja", 2024), ("8月15日", "ja", nil),
            ("2024년 8월 15일", "ko", 2024), ("ngày 15 tháng 8 năm 2024", "vi", 2024), ("2024-08-15", "en", 2024),
        ] as [(String, String, Int?)]
    )
    func dayParse(query: String, languageTag: String, year: Int?) {
        let p = parse(query, languageTag: languageTag)
        #expect(
            p.dates.clauses == [TripQueryParser.DateClause(
                years: year.map { [$0] } ?? [], days: [TripQueryParser.DateDay(month: 8, day: 15)])],
            "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    private func days(_ p: TripQueryParser.ParsedQuery) -> Set<TripQueryParser.DateDay> {
        p.dates.clauses.reduce([]) { $0.union($1.days) }
    }

    @Test("a day's other spellings: 号, Swedish 15:e")
    func daySpellings() {
        #expect(days(parse("8月15号", languageTag: "zh-Hans")) == [TripQueryParser.DateDay(month: 8, day: 15)])
        #expect(days(parse("15:e augusti", languageTag: "sv")) == [TripQueryParser.DateDay(month: 8, day: 15)])
    }

    @Test("numbers that are no day of that month, and slashed dates, are not days")
    func notDays() {
        #expect(days(parse("february 30")).isEmpty)
        #expect(days(parse("8/15")).isEmpty)
        #expect(days(parse("august 2024")).isEmpty)
        // A duration keeps its number.
        #expect(days(parse("3 days in august")).isEmpty)
        #expect(parse("3 days in august").minDurationDays == 3)
    }

    @Test("a day keeps the trips that cover it")
    func daySearch() {
        #expect(found(trips, "15 august 2024") == [2])
        #expect(found(trips, "august 15") == [2])
        #expect(found(trips, "15 august 2023").isEmpty)
        #expect(found(trips, "Kostavo 2024年8月15日", languageTag: "ja") == [2])
    }

    @Test("a day is a date clause: or joins it with other dates, a loose year joins its years")
    func dayClauses() {
        let documents = [
            trip("Valdoria", from: date(2024, 8, 14), to: date(2024, 8, 16)),
            trip("Marenza", from: date(2023, 6, 10), to: date(2023, 6, 12)),
            trip("Kostavo", from: date(2025, 8, 15), to: date(2025, 8, 15)),
        ]
        #expect(found(documents, "15 august 2024 or june 2023") == [0, 1])
        #expect(found(documents, "15 august 2024 or 2025") == [0, 2])
        #expect(found(documents, "15 august") == [0, 2])
        #expect(found(documents, "christmas or 15 august 2025") == [2])
    }

    @Test("or between dates of their own keeps each side's pairing, list and Siri")
    func crossedDates() {
        let documents = [
            trip("Valdoria", from: date(2024, 12, 23), to: date(2024, 12, 27)),
            trip("Marenza", from: date(2025, 12, 23), to: date(2025, 12, 27)),
            trip("Kostavo", from: date(2024, 8, 14), to: date(2024, 8, 16)),
            trip("Port Ellis", from: date(2025, 8, 14), to: date(2025, 8, 16)),
            trip("Valdoria", from: date(2020, 3, 1), to: date(2020, 3, 5)),
        ]
        for typing in [true, false] {
            func found(_ query: String) -> [Int] {
                TripQueryParser.searchTrips(
                    index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
                    now: now, calendar: utcCal, languageTag: "en")
                    .filter { $0.strength == .strong }.map(\.documentIndex)
            }
            #expect(found("christmas 2024 or 15 august 2025") == [0, 3], "\(typing)")
            #expect(found("christmas 2023 or 15 august 2025") == [3], "\(typing)")
            #expect(found("last 6 months or 2020") == [4], "\(typing)")
            // A side of bare years joins the other side's dates.
            #expect(found("christmas 2024 or 2025") == [0, 1], "\(typing)")
            // A side without dates keeps the single AND reading.
            #expect(found("christmas or Valdoria") == [0], "\(typing)")
            // A split no trip matches stays empty (the single reading would
            // cross the years: this trip has 24 December 2024 and 1 January 2025).
            let spanning = [trip("Kostavo", from: date(2024, 12, 24), to: date(2025, 1, 2))]
            let none = TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: spanning), query: "christmas 2025 or 1 january 2024",
                allowsTrailingPartial: typing, now: now, calendar: utcCal, languageTag: "en")
            #expect(none.isEmpty, "\(typing)")
            // An undated side takes the other side's year.
            let septembers = [
                trip("Valdoria", from: date(2024, 8, 14), to: date(2024, 8, 16)),
                trip("Marenza", from: date(2023, 9, 10), to: date(2023, 9, 12)),
                trip("Kostavo", from: date(2024, 9, 10), to: date(2024, 9, 12)),
            ]
            let inherited = TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: septembers), query: "15 august 2024 or september",
                allowsTrailingPartial: typing, now: now, calendar: utcCal, languageTag: "en")
                .filter { $0.strength == .strong }.map(\.documentIndex)
            #expect(inherited == [0, 2], "\(typing)")
        }
    }

    @Test("months and holidays restrict a day on one side; or makes them alternatives")
    func dayRestrictions() {
        let documents = [
            trip("Valdoria", from: date(2024, 8, 14), to: date(2024, 8, 16)),
            trip("Marenza", from: date(2024, 7, 10), to: date(2024, 7, 12)),
        ]
        #expect(found(documents, "15 august july").isEmpty)
        // The engine pass, which sees `july` as text, keeps the restriction.
        let summer = [trip("Valdoria", from: date(2024, 7, 1), to: date(2024, 8, 31))]
        #expect(found(summer, "15 august july").isEmpty)
        #expect(found(summer, "15 august") == [0])
        // A season clause governs the day and its year (now 14 July 2026).
        let seasons = [
            trip("Valdoria", from: date(2025, 8, 14), to: date(2025, 8, 16)),
            trip("Marenza", from: date(2025, 6, 10), to: date(2025, 6, 12)),
            trip("Kostavo", from: date(2024, 8, 14), to: date(2024, 8, 16)),
        ]
        #expect(found(seasons, "15 august last summer") == [0])
        #expect(found(seasons, "15 august 2024 last summer").isEmpty)
        #expect(found(seasons, "15 june last winter").isEmpty)
        #expect(found(documents, "15 august in august") == [0])
        #expect(found(documents, "christmas 15 august").isEmpty)
        #expect(found(documents, "15 august or july") == [0, 1])
    }

    @Test("a numeric date its month lacks admits no trip; a spelt one stays text")
    func invalidDates() {
        let documents = [trip("Valdoria", from: date(2024, 2, 27), to: date(2024, 3, 2))]
        #expect(found(documents, "Valdoria 2024-02-30").isEmpty)
        #expect(found(documents, "Valdoria 2024年2月30日", languageTag: "ja").isEmpty)
        #expect(found(documents, "Valdoria 2月30日", languageTag: "ja").isEmpty)
        #expect(found(documents, "Valdoria 2024年の2月30日", languageTag: "ja").isEmpty)
        #expect(found(documents, "2024年の2月30日", languageTag: "ja").isEmpty)
        #expect(found(documents, "Valdoria 2024-02-28") == [0])
        #expect(found(documents, "Valdoria 2024年2月29日", languageTag: "ja") == [0])
    }

    @Test("年末年始 is named by its December")
    func yearEndYear() {
        let documents = [
            trip("Valdoria", from: date(2024, 12, 30), to: date(2025, 1, 2)),
            trip("Marenza", from: date(2025, 12, 31), to: date(2026, 1, 1)),
        ]
        #expect(found(documents, "2024年の年末年始", languageTag: "ja") == [0])
        #expect(found(documents, "年末年始", languageTag: "ja") == [0, 1])
    }

    // MARK: - Lengths

    @Test(
        "length words and Han and Hangul lengths",
        arguments: [
            ("day trips", "en", 1 as Int?, 1 as Int?), ("Tagesausflüge", "de", nil, 1), ("日帰り", "ja", nil, 1),
            ("당일치기", "ko", nil, 1), ("long trips", "en", 8, nil), ("長期旅行", "ja", 8, nil),
            ("3日間", "ja", 3, 3), ("2泊3日", "ja", 3, 3), ("2泊", "ja", 3, 3), ("1週間以上", "ja", 7, nil),
            ("2박 3일", "ko", 3, 3), ("3天2晚", "zh-Hans", 3, 3), ("两周", "zh-Hans", 12, 16),
            ("十二泊", "ja", 13, 13), ("十五日間", "ja", 15, 15), ("二十一日間", "ja", 21, 21),
            ("장기 여행", "ko", 8, nil), ("장기여행", "ko", 8, nil), ("단기 여행", "ko", nil, 3),
            ("长期旅行", "zh-Hans", 8, nil), ("短期旅遊", "zh-Hant", nil, 3),
            ("chuyến đi dài ngày", "vi", 8, nil), ("du lịch ngắn ngày", "vi", nil, 3),
        ] as [(String, String, Int?, Int?)]
    )
    func lengths(query: String, languageTag: String, min: Int?, max: Int?) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.minDurationDays == min || (min == 1 && p.minDurationDays == nil), "\(query)")
        #expect(p.maxDurationDays == max, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("a bare Han day is a date, not a length")
    func hanDayIsDate() {
        let p = parse("15日", languageTag: "ja")
        #expect(p.minDurationDays == nil && p.maxDurationDays == nil)
    }

    @Test("long is 8 days or more, as \"longer than a week\"")
    func longBoundary() {
        let documents = [7, 8, 9].map { trip("Valdoria", from: date(2024, 6, 1), to: date(2024, 6, $0)) }
        #expect(found(documents, "long trips") == [1, 2])
        #expect(found(documents, "longer than a week") == [1, 2])
    }

    @Test("a season's own months are strong matches, the month on either side similar")
    func seasonEdges() {
        let documents = [
            trip("Valdoria", from: date(2024, 11, 20), to: date(2024, 11, 24)),  // 0 November
            trip("Valdoria", from: date(2025, 1, 10), to: date(2025, 1, 14)),    // 1 January
            trip("Valdoria", from: date(2025, 3, 5), to: date(2025, 3, 8)),      // 2 March
            trip("Valdoria", from: date(2025, 4, 5), to: date(2025, 4, 8)),      // 3 April
            trip("Valdoria", from: date(2025, 5, 28), to: date(2025, 6, 2)),     // 4 late May into June
        ]
        func strengths(_ query: String) -> [Int: TripSearchStrength] {
            Dictionary(uniqueKeysWithValues: TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                now: date(2025, 7, 1), calendar: utcCal, languageTag: "en").map { ($0.documentIndex, $0.strength) })
        }
        for query in ["winter 2024", "last winter", "in winter"] {
            #expect(strengths(query) == [1: .strong, 0: .similar, 2: .similar], "\(query)")
        }
        #expect(strengths("spring 2025") == [2: .strong, 3: .strong, 4: .strong])
        // A day bound to a season keeps the season's edges.
        #expect(strengths("12 january last winter") == [1: .strong])
        #expect(strengths("6 march last winter") == [2: .similar])
        #expect(strengths("6 april last winter").isEmpty)
        // A trip into the season's own months is strong.
        #expect(strengths("summer 2025") == [4: .strong])
        // A month has no neighbours.
        #expect(strengths("november 2024") == [0: .strong])
    }

    @Test("a long weekend keeps its weekend day in every pass, list and Siri")
    func weekendInEveryPass() {
        let documents = [
            trip("Valdoria", from: date(2024, 6, 11), to: date(2024, 6, 13)),  // Tuesday to Thursday
            trip("Valdoria", from: date(2024, 6, 14), to: date(2024, 6, 16)),  // Friday to Sunday
        ]
        for typing in [true, false] {
            for query in ["Valdoria long weekend", "Valdoria weekend"] {
                let matches = TripQueryParser.searchTrips(
                    index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
                    now: now, calendar: utcCal, languageTag: "en")
                #expect(matches.filter { $0.strength == .strong }.map(\.documentIndex) == [1], "\(query) \(typing)")
            }
        }
    }

    @Test("an ongoing trip's weekend day counts to today")
    func ongoingWeekend() {
        // Started Saturday 4 July 2026, still under way on 14 July.
        let ongoing = TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: ["Weekend in Valdoria"]),
                TripSearchField(kind: .place, displayValues: ["Valdoria"]),
            ],
            startDate: date(2026, 7, 4), endDate: nil, startYear: 2026, startMonth: 7,
            durationDays: nil, isComplete: false)
        #expect(found([ongoing], "Valdoria weekend") == [0])
    }

    @Test("weekend trips have a weekend day")
    func weekendTrips() {
        let documents = [
            trip("Valdoria", from: date(2024, 6, 7), to: date(2024, 6, 9)),  // Friday to Sunday
            trip("Marenza", from: date(2024, 6, 11), to: date(2024, 6, 13)),  // Tuesday to Thursday
        ]
        #expect(found(documents, "weekend trips") == [0])
        #expect(found(documents, "long weekend") == [0])
        #expect(parse("weekend").requiresWeekend)
    }

    // MARK: - Recent spans and this month

    @Test(
        "recent spans start that far back from today",
        arguments: [
            ("last 6 months", "en", (2026, 1, 14)), ("past year", "en", (2025, 7, 14)),
            ("last 2 weeks", "en", (2026, 6, 30)), ("letzten 3 Monate", "de", (2026, 4, 14)),
            ("6 derniers mois", "fr", (2026, 1, 14)), ("últimos 30 días", "es", (2026, 6, 14)),
            ("過去3ヶ月", "ja", (2026, 4, 14)), ("최근 6개월", "ko", (2026, 1, 14)), ("近半年", "zh-Hans", (2026, 1, 14)),
        ] as [(String, String, (Int, Int, Int))]
    )
    func spans(query: String, languageTag: String, start: (Int, Int, Int)) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.recentStart == utcCal.date(from: day(start.0, start.1, start.2)), "\(query)")
        #expect(p.minDurationDays == nil, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("calendar phrases stay calendar phrases")
    func calendarPhrases() {
        #expect(parse("last year").recentStart == nil)
        #expect(parse("last year").years == [2025])
        #expect(parse("this month").dates.clauses == [TripQueryParser.DateClause(months: [.init(month: 7)], years: [2026])])
        #expect(parse("summer before last").dates.clauses.first?.years == [2024])
        #expect(parse("vorletzten Sommer", languageTag: "de").dates.clauses.first?.years == [2024])
    }

    @Test("a span keeps the trips that reach into it, the ongoing one included")
    func spanSearch() {
        #expect(found(trips, "last 6 months") == [5])
        #expect(found(trips, "last 3 years") == [0, 1, 2, 4, 5])
    }

    // MARK: - Ongoing trips

    @Test("an ongoing trip's days run to today for dates and holidays, not for lengths")
    func ongoing() {
        let documents = [trip("Valdoria", from: date(2025, 12, 20), to: nil)]
        func found(_ query: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                now: date(2026, 1, 10), calendar: utcCal, languageTag: "en")
                .filter { $0.strength != .partial }.map(\.documentIndex)
        }
        #expect(found("january 2026") == [0])
        #expect(found("new year 2026") == [0])
        #expect(found("6 january") == [0])
        #expect(found("february 2026").isEmpty)
        #expect(found("long trips").isEmpty)
    }
}
