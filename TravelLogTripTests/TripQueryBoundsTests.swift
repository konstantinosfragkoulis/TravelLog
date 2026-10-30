//
//  TripQueryBoundsTests.swift
//  TravelLogTests
//
//  Relative years ("three years ago", "vorletztes Jahr", 一昨年, 前年),
//  year bounds and spans ("since 2023", "avant 2015", "between 2016 and
//  2018", 2015年之前) and localized trip-length comparatives ("plus d'une
//  semaine", "weniger als 3 Tage"). Pure parses and searches over
//  `TripSearchDocument`s with an injected `now` (2026-07-14, UTC).
//

import Testing
import Foundation
@testable import TravelLog

struct TripQueryBoundsTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    private func raws(_ terms: [TripSearchTerm]) -> [String] { terms.map(\.raw) }

    private func trip(
        _ place: String,
        year: Int,
        month: Int,
        day: Int = 1,
        durationDays: Int = 4,
        languageTag: String = "en"
    ) -> TripSearchDocument {
        let start = date(year, month, day)
        let end = utcCal.date(byAdding: .day, value: durationDays - 1, to: start)!
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(
                    kind: .date,
                    displayValues: TripSearchDocument.dateWords(
                        start: start, end: end, languageTag: languageTag, calendar: utcCal)),
            ],
            startDate: start,
            endDate: end,
            startYear: year,
            startMonth: month,
            durationDays: durationDays,
            isComplete: true)
    }

    private func search(
        _ trips: [TripSearchDocument],
        _ query: String,
        languageTag: String = "en"
    ) -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips),
            query: query,
            allowsTrailingPartial: false,
            now: date(2026, 7, 14),
            calendar: utcCal,
            languageTag: languageTag)
    }

    private func found(_ trips: [TripSearchDocument], _ query: String, languageTag: String = "en") -> [UUID] {
        search(trips, query, languageTag: languageTag).map { trips[$0.documentIndex].tripID }
    }

    // MARK: - Relative years

    @Test(
        "years ago and the year before last name one calendar year",
        arguments: [
            ("three years ago", "en", 2023), ("3 years ago", "en", 2023), ("a year ago", "en", 2025),
            ("twenty years ago", "en", 2006), ("the year before last", "en", 2024),
            ("vor 3 Jahren", "de", 2023), ("vor drei Jahren", "de", 2023), ("vor einem Jahr", "de", 2025),
            ("vorletztes Jahr", "de", 2024), ("il y a trois ans", "fr", 2023), ("hace tres años", "es", 2023),
            ("el año antepasado", "es", 2024), ("tre anni fa", "it", 2023), ("há três anos", "pt-BR", 2023),
            ("drie jaar geleden", "nl", 2023), ("för tre år sedan", "sv", 2023), ("for tre år siden", "da", 2023),
            ("i forfjor", "nb", 2024), ("üç yıl önce", "tr", 2023), ("πριν τρία χρόνια", "el", 2023),
            ("πρόπερσι", "el", 2024), ("ba năm trước", "vi", 2023), ("năm kia", "vi", 2024),
            ("3年前", "ja", 2023), ("三年前", "zh-Hans", 2023), ("3년 전", "ko", 2023), ("재작년", "ko", 2024),
            // Chinese 前年 is the year before last; Japanese 前年 the previous year.
            ("前年", "zh-Hans", 2024), ("前年", "zh-Hant", 2024), ("前年", "ja", 2025),
            ("一昨年", "ja", 2024), ("おととし", "ja", 2024),
        ] as [(String, String, Int)]
    )
    func relativeYears(query: String, languageTag: String, year: Int) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.years == [year], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.isClaimable, "\(query)")
        #expect(p.placeInterpretation == nil, "\(query)")
    }

    @Test("Han year phrases stay whole inside a sentence the segmenter splits differently")
    func hanYearPhrasesInContext() {
        let osaka = parse("一昨年の大阪旅行", languageTag: "ja")
        #expect(osaka.years == [2024])
        #expect(raws(osaka.placeTerms) == ["大阪"])
        #expect(parse("一昨年の夏", languageTag: "ja").months == [6, 7, 8])
        #expect(parse("一昨年の夏", languageTag: "ja").years == [2024])
        // 昨年 segments as 昨 / 年 alone and whole before の.
        #expect(parse("昨年の旅行", languageTag: "ja").years == [2025])
        #expect(parse("昨年の旅行", languageTag: "ja").placeTerms.isEmpty)
        let shanghai = parse("前年去上海的旅行", languageTag: "zh-Hans")
        #expect(shanghai.years == [2024])
        #expect(raws(shanghai.placeTerms) == ["上海"])
        // A four-digit year before 前 is a bound, not a count of years.
        #expect(parse("2019年前往上海", languageTag: "zh-Hans").years == [2019])
    }

    @Test("a years-ago phrase is consumed, so place words still match strongly")
    func yearsAgoWithPlace() {
        let rome = trip("Rome", year: 2023, month: 5)
        let romeLater = trip("Rome", year: 2025, month: 5)
        let lima = trip("Lima", year: 2023, month: 9)
        let trips = [rome, romeLater, lima]
        let matches = search(trips, "Rome trips three years ago")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.allSatisfy { $0.strength == .strong })
        #expect(found(trips, "Rom vor 3 Jahren", languageTag: "de") == [rome.tripID])
        #expect(found(trips, "three years ago") == [rome.tripID, lima.tripID])
    }

    // MARK: - Year bounds and spans

    @Test(
        "year bounds admit whole years: since and until include the year, after and before do not",
        arguments: [
            ("since 2023", "en", 2023, 2099), ("trips after 2023", "en", 2024, 2099),
            ("before 2015", "en", 1900, 2014), ("until 2015", "en", 1900, 2015),
            ("2015 or earlier", "en", 1900, 2015), ("from 2023 onwards", "en", 2023, 2099),
            ("between 2016 and 2018", "en", 2016, 2018), ("between 2018 and 2016", "en", 2016, 2018),
            ("between 1990 and 2018", "en", 1990, 2018),
            ("seit 2023", "de", 2023, 2099), ("vor 2015", "de", 1900, 2014), ("2016 bis 2018", "de", 2016, 2018),
            ("zwischen 2016 und 2018", "de", 2016, 2018), ("depuis 2023", "fr", 2023, 2099),
            ("avant 2015", "fr", 1900, 2014), ("entre 2016 et 2018", "fr", 2016, 2018),
            ("después de 2023", "es", 2024, 2099), ("entre 2016 y 2018", "es", 2016, 2018),
            ("prima del 2015", "it", 1900, 2014), ("tra il 2016 e il 2018", "it", 2016, 2018),
            ("desde 2023", "pt-PT", 2023, 2099), ("tussen 2016 en 2018", "nl", 2016, 2018),
            ("mellan 2016 och 2018", "sv", 2016, 2018), ("efter 2023", "da", 2024, 2099),
            ("før 2015", "nb", 1900, 2014), ("2023'ten beri", "tr", 2023, 2099),
            ("2016 ile 2018 arası", "tr", 2016, 2018), ("πριν το 2015", "el", 1900, 2014),
            ("μεταξύ 2016 και 2018", "el", 2016, 2018), ("từ 2016 đến 2018", "vi", 2016, 2018),
            ("2023年以降", "ja", 2023, 2099), ("2015年より前", "ja", 1900, 2014),
            ("2016年から2018年までの旅行", "ja", 2016, 2018), ("2023年以后", "zh-Hans", 2023, 2099),
            ("2015年之前", "zh-Hans", 1900, 2014), ("2015年以前", "zh-Hans", 1900, 2015),
            ("从2016年到2018年", "zh-Hans", 2016, 2018), ("2023년 이후", "ko", 2023, 2099),
            ("2015년 전", "ko", 1900, 2014), ("2016년부터 2018년까지", "ko", 2016, 2018),
        ] as [(String, String, Int, Int)]
    )
    func yearBounds(query: String, languageTag: String, low: Int, high: Int) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.years == Set(low...high), "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.isClaimable, "\(query)")
    }

    @Test("a bound past the year range admits nothing, and bound words without a year stay place text")
    func boundEdges() {
        let trips = [trip("Oslo", year: 1999, month: 3), trip("Lima", year: 2026, month: 3)]
        #expect(found(trips, "before 1900").isEmpty)
        #expect(found(trips, "after 2099").isEmpty)
        #expect(raws(parse("between rome and lima").placeTerms) == ["between", "rome", "lima"])
        // Bounds intersect, so disjoint ones admit nothing; with "or" the
        // search reads each side alone (TripQueryDisjunctionTests).
        #expect(parse("after 2019 and before 2023").years == Set(2020...2022))
        #expect(parse("since 2016 until 2018").years == Set(2016...2018))
        #expect(parse("before 2015 after 2020").years == [2100])
        #expect(found(trips, "before 2000 after 2020").isEmpty)
        #expect(parse("before 2015 or after 2020").disjunctionSides == ["before 2015", "after 2020"])
        #expect(found(trips, "before 2000 or after 2020") == trips.map(\.tripID))
        #expect(parse("between 2010 and 2011 or between 2014 and 2015").disjunctionSides
            == ["between 2010 and 2011", "between 2014 and 2015"])
        // Two years without a span word stay a list.
        #expect(parse("2016 and 2018").years == [2016, 2018])
    }

    @Test("bounds match by overlap, pair with month words and combine with places")
    func boundsSearch() {
        let early = trip("Oslo", year: 2014, month: 6)
        let newYear = trip("Paris", year: 2022, month: 12, day: 28, durationDays: 7)
        let summer = trip("Paris", year: 2023, month: 7)
        let spring = trip("Lima", year: 2025, month: 3)
        let trips = [early, newYear, summer, spring]

        #expect(found(trips, "since 2023") == [newYear.tripID, summer.tripID, spring.tripID])
        #expect(found(trips, "after 2022") == [newYear.tripID, summer.tripID, spring.tripID])
        #expect(found(trips, "before 2023") == [early.tripID, newYear.tripID])
        #expect(found(trips, "until 2014") == [early.tripID])
        #expect(found(trips, "between 2015 and 2022") == [newYear.tripID])
        #expect(found(trips, "summer since 2020") == [summer.tripID])
        #expect(found(trips, "Paris since 2023") == [newYear.tripID, summer.tripID])
        let matches = search(trips, "trips to Paris between 2023 and 2024")
        #expect(matches.map(\.documentIndex) == [1, 2])
        #expect(matches.allSatisfy { $0.strength == .strong })

        // No Lima trip before 2020: the partial tier drops the year, as for a bare year.
        let partial = search(trips, "Lima before 2020")
        #expect(partial.map(\.documentIndex) == [3])
        #expect(partial.allSatisfy { $0.strength == .partial })
    }

    @Test("every bound, span, years-ago and comparative pattern has its slots and a word", arguments: TripQueryVocabulary.supportedTags)
    func patternShapes(tag: String) {
        let language = TripQueryVocabulary.language(tag)
        let single = language.sinceYear + language.afterYear + language.beforeYear + language.untilYear
            + language.yearsAgo + language.longerThan + language.shorterThan + language.atLeast + language.atMost
        for pattern in single {
            #expect(pattern.slotCount == 1, "\(tag) \(pattern.parts)")
            #expect(pattern.parts.contains { !$0.isEmpty }, "\(tag) \(pattern.parts)")
        }
        for pattern in language.yearSpans {
            #expect(pattern.slotCount == 2, "\(tag) \(pattern.parts)")
            #expect(!pattern.parts[1].isEmpty, "\(tag) \(pattern.parts)")
        }
        #expect(language.durationUnits.values.allSatisfy { $0 == 1 || $0 == 7 }, "\(tag)")
        #expect(language.countWords.values.allSatisfy { (1...10).contains($0) }, "\(tag)")
    }

    // MARK: - Trip length

    @Test(
        "localized duration comparatives, counts and units",
        arguments: [
            ("under 3 days", "en", nil, 2), ("fewer than 4 days", "en", nil, 3),
            ("länger als eine Woche", "de", 8, nil), ("weniger als 3 Tage", "de", nil, 2),
            ("mindestens 2 Wochen", "de", 14, nil), ("drei Tage", "de", 3, 3), ("eine Woche", "de", 6, 8),
            ("plus d'une semaine", "fr", 8, nil), ("moins de 4 jours", "fr", nil, 3),
            ("au moins 10 jours", "fr", 10, nil), ("más de una semana", "es", 8, nil),
            ("menos de 3 días", "es", nil, 2), ("più di una settimana", "it", 8, nil),
            ("mais de uma semana", "pt-BR", 8, nil), ("langer dan een week", "nl", 8, nil),
            ("längre än en vecka", "sv", 8, nil), ("mere end en uge", "da", 8, nil),
            ("mer enn en uke", "nb", 8, nil), ("bir haftadan uzun", "tr", 8, nil),
            ("πάνω από μία εβδομάδα", "el", 8, nil), ("hơn một tuần", "vi", 8, nil),
        ] as [(String, String, Int?, Int?)]
    )
    func localizedDurations(query: String, languageTag: String, min: Int?, max: Int?) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.minDurationDays == min, "\(query)")
        #expect(p.maxDurationDays == max, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("a localized comparative leaves only the place words")
    func localizedDurationSearch() {
        let longVienna = trip("Wien", year: 2024, month: 5, durationDays: 10, languageTag: "de")
        let shortVienna = trip("Wien", year: 2025, month: 5, durationDays: 3, languageTag: "de")
        let trips = [longVienna, shortVienna]
        let matches = search(trips, "Reisen nach Wien länger als eine Woche", languageTag: "de")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.allSatisfy { $0.strength == .strong })
        #expect(found(trips, "Wien weniger als 4 Tage", languageTag: "de") == [shortVienna.tripID])
    }

    @Test(
        "length words next to a trip noun or weekend word bound the trip's length",
        arguments: [
            ("long trips", "en", 8, nil), ("short trips", "en", nil, 3), ("a long weekend", "en", 3, 4),
            ("long holidays", "en", 8, nil), ("short visit", "en", nil, 3),
            ("lange Reisen", "de", 8, nil), ("kurzer Urlaub", "de", nil, 3), ("langes Wochenende", "de", 3, 4),
            ("μεγάλα ταξίδια", "el", 8, nil), ("μικρή εκδρομή", "el", nil, 3), ("σύντομο ταξίδι", "el", nil, 3),
            ("viajes largos", "es", 8, nil), ("viaje corto", "es", nil, 3), ("fin de semana largo", "es", 3, 4),
            ("longs voyages", "fr", 8, nil), ("court séjour", "fr", nil, 3), ("long week-end", "fr", 3, 4),
            ("lungo viaggio", "it", 8, nil), ("viaggio lungo", "it", 8, nil), ("vacanza breve", "it", nil, 3),
            ("lange reizen", "nl", 8, nil), ("korte vakantie", "nl", nil, 3), ("lang weekend", "nl", 3, 4),
            ("viagem longa", "pt-BR", 8, nil), ("viagens curtas", "pt-PT", nil, 3),
            ("fim de semana prolongado", "pt-BR", 3, 4),
            ("långa resor", "sv", 8, nil), ("kort resa", "sv", nil, 3), ("långhelg", "sv", 3, 4),
            ("lang reise", "nb", 8, nil), ("langhelg", "nb", 3, 4), ("lange rejser", "da", 8, nil),
            ("uzun tatil", "tr", 8, nil), ("kısa gezi", "tr", nil, 3),
        ] as [(String, String, Int?, Int?)]
    )
    func lengthWords(query: String, languageTag: String, min: Int?, max: Int?) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.minDurationDays == min, "\(query)")
        #expect(p.maxDurationDays == max, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.isClaimable, "\(query)")
    }

    @Test("a length word away from a trip noun, or after place text, stays a place word")
    func lengthWordsAsPlaces() {
        #expect(raws(parse("short hills").placeTerms) == ["short", "hills"])
        #expect(parse("short hills").maxDurationDays == nil)
        #expect(raws(parse("key largo", languageTag: "es").placeTerms) == ["key", "largo"])
        #expect(raws(parse("Lange Wapper", languageTag: "nl").placeTerms) == ["lange", "wapper"])

        let afterPlace = parse("paris short trips")
        #expect(raws(afterPlace.placeTerms) == ["paris"])
        #expect(afterPlace.maxDurationDays == 3)
        #expect(afterPlace.placeInterpretation == nil)

        // A name some trip has that ends in a length word stays whole; a
        // length word after it is still a length (Long Beach long weekend).
        let corpus = TripSearchIndex(documents: [trip("Short Hills", year: 2024, month: 5)])
        let named = TripQueryParser.parse(
            "short hills short trips", now: date(2026, 7, 14), calendar: utcCal, languageTag: "en", corpus: corpus)
        #expect(raws(named.placeTerms) == ["short", "hills"])
        #expect(named.maxDurationDays == 3)
        #expect(named.namePhrases == ["short hills"])
    }

    @Test("long and short trips filter by length, consumed like other duration syntax")
    func lengthWordSearch() {
        let berlin = trip("Berlin", year: 2020, month: 2, durationDays: 2)
        let rome = trip("Rome", year: 2021, month: 5, durationDays: 12)
        let lima = trip("Lima", year: 2022, month: 5, durationDays: 4)
        let trips = [berlin, rome, lima]
        #expect(found(trips, "short trips") == [berlin.tripID])
        #expect(found(trips, "long trips") == [rome.tripID])
        #expect(found(trips, "a long weekend") == [lima.tripID])
        #expect(found(trips, "Rome long trips") == [rome.tripID])
        #expect(found(trips, "Berlin long trips").isEmpty || search(trips, "Berlin long trips").allSatisfy { $0.strength == .partial })
        #expect(found(trips, "short trips under 3 days") == [berlin.tripID])
        #expect(found(trips, "viaje corto", languageTag: "es") == [berlin.tripID])
    }
}
