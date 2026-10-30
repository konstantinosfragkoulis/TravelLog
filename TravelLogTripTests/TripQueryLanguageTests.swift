//
//  TripQueryLanguageTests.swift
//  TravelLogTests
//
//  The vocabulary languages a query is read in (`queryLanguageTags`): the
//  app language, the user's other preferred languages and the language of a
//  Greek, Hangul or kana query, so a Greek speaker using the app in English
//  still finds trips by `Αύγουστος 2025`. Further languages add no short
//  month forms; region words come from every supported language. Pure
//  parses and searches with an injected `now` (2026-07-14, UTC).
//

import Testing
import Foundation
@testable import TravelLog

struct TripQueryLanguageTests {

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

    private func found(_ trips: [TripSearchDocument], _ query: String, languageTag: String = "en") -> [UUID] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
            .map { trips[$0.documentIndex].tripID }
    }

    // MARK: - Language tags

    @Test(
        "the app language, then preferred languages in order, then the query's script",
        arguments: [
            ("Αύγουστος 2025", "en", [], ["en", "el"]),
            ("Αύγουστος 2025", "el", [], ["el"]),
            ("paris", "en", ["en", "de", "el"], ["en", "de", "el"]),
            ("paris", "fr", ["fr", "de"], ["fr", "de"]),
            ("Ρώμη", "en", ["de"], ["en", "de", "el"]),
            ("서울 여름", "en", [], ["en", "ko"]),
            ("きょうと", "en", [], ["en", "ja"]),
            // Han alone could be Chinese or Japanese: only a preferred language decides.
            ("东京 2024", "en", [], ["en"]),
            ("东京 2024", "en", ["zh-Hans"], ["en", "zh-Hans"]),
            ("paris", "en", ["xx", "en"], ["en"]),
        ] as [(String, String, [String], [String])]
    )
    func languageTags(query: String, app: String, preferred: [String], expected: [String]) {
        #expect(TripQueryParser.queryLanguageTags(query, languageTag: app, preferredTags: preferred) == expected)
    }

    @Test("preferred languages normalize to supported app tags, in order, once each")
    func preferredTags() {
        #expect(AppLanguagePreference.preferredTags(["el-GR", "en-US", "zh-Hans-CN", "pt", "xx-YY", "el"])
            == ["el", "en", "zh-Hans"])
        #expect(AppLanguagePreference.preferredTags(["pt-BR", "zh-TW", "nb-NO"]) == ["pt-BR", "zh-Hant", "nb"])
        #expect(AppLanguagePreference.preferredTags([]).isEmpty)
    }

    // MARK: - Script languages

    @Test("Greek date words work with the app in English")
    func greekDatesWithEnglishApp() {
        let august = parse("Αύγουστος 2025")
        #expect(august.dates.effectiveClauses.map(\.years) == [[2025]])
        #expect(august.months == [8])
        #expect(august.placeTerms.isEmpty)
        #expect(parse("πέρσι").years == [2025])
        let weekend = parse("Σαββατοκύριακο")
        #expect(weekend.minDurationDays == 2 && weekend.maxDurationDays == 3)

        let summer = trip("Lisbon", year: 2025, month: 8)
        let earlier = trip("Lisbon", year: 2024, month: 8)
        let spring = trip("Oslo", year: 2025, month: 4)
        let trips = [summer, earlier, spring]
        #expect(found(trips, "Αύγουστος 2025") == [summer.tripID])
        #expect(found(trips, "Lisbon πέρσι το καλοκαίρι") == [summer.tripID])
    }

    @Test("Greek ή is or and the article η is not, though both fold to η")
    func greekOrBesideArticle() {
        let athens = trip("Αθήνα", year: 2024, month: 5)
        let rome = trip("Ρώμη", year: 2024, month: 6)
        let lisbon = trip("Λισαβόνα", year: 2024, month: 7)
        let trips = [athens, rome, lisbon]
        func strong(_ query: String, languageTag: String, typing: Bool = false) -> [UUID] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: trips), query: query, allowsTrailingPartial: typing,
                now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
                .filter { $0.strength == .strong }
                .map { trips[$0.documentIndex].tripID }
        }
        // Capitals often drop the accent, so an unaccented capital `Η` stays "or".
        let queries = [
            "Αθήνα ή Ρώμη", "Αθήνα ή η Ρώμη", "η Αθήνα ή η Ρώμη",
            "Αθήνα \u{03B7}\u{0301} η Ρώμη", "ΑΘΗΝΑ Η ΡΩΜΗ", "ΑΘΗΝΑ Ή ΡΩΜΗ",
        ]
        for languageTag in ["el", "en"] {
            for query in queries {
                for typing in [false, true] {
                    #expect(strong(query, languageTag: languageTag, typing: typing) == [athens.tripID, rome.tripID],
                            "\(query) \(languageTag) \(typing)")
                }
            }
        }
        #expect(parse("Αθήνα ή η Ρώμη").disjunctionSides == ["αθηνα", "η ρωμη"])
        #expect(parse("η Αθήνα ή η Ρώμη").disjunctionSides == ["η αθηνα", "η ρωμη"])
        #expect(parse("ΑΘΗΝΑ Η ΡΩΜΗ").disjunctionSides == ["αθηνα", "ρωμη"])
        #expect(parse("ΑΘΗΝΑ Ή ΡΩΜΗ Η ΛΙΣΑΒΟΝΑ").disjunctionSides == ["αθηνα", "ρωμη", "λισαβονα"])
        #expect(parse("Αθήνα η Ρώμη").disjunctionSides.isEmpty)
        #expect(parse("η Αθήνα και η Ρώμη").disjunctionSides.isEmpty)
        #expect(parse("Η ΑΘΗΝΑ ΚΑΙ Η ΡΩΜΗ").disjunctionSides.isEmpty)
        // French `où` ("where") folds to `ou` ("or") the same way, and keeps its accent in capitals.
        #expect(parse("Paris ou Rome", languageTag: "fr").disjunctionSides == ["paris", "rome"])
        #expect(parse("PARIS OU ROME", languageTag: "fr").disjunctionSides == ["paris", "rome"])
        #expect(parse("Paris où Rome", languageTag: "fr").disjunctionSides.isEmpty)
        #expect(parse("PARIS OÙ ROME", languageTag: "fr").disjunctionSides.isEmpty)
    }

    // MARK: - Further languages

    @Test("a further language adds its full month names but not its short forms")
    func secondaryLanguagesDropShortMonths() {
        #expect(TripQueryVocabulary.language("es").months["mar"] == 3)
        #expect(TripQueryVocabulary.secondary("es").months["mar"] == nil)
        #expect(TripQueryVocabulary.secondary("es").months["marzo"] == 3)
        #expect(TripQueryVocabulary.secondary("it").months["set"] == nil)
        #expect(TripQueryVocabulary.secondary("it").months["settembre"] == 9)
        #expect(TripQueryVocabulary.secondary("el").months["Αυγ"] == nil)
        #expect(TripQueryVocabulary.secondary("el").months["Αύγουστος"] == 8)
        // Table extras are words, not short forms.
        #expect(TripQueryVocabulary.secondary("el").months["Αύγουστο"] == 8)
        #expect(TripQueryVocabulary.secondary("el").months["Γενάρη"] == 1)
        // A Greek short form is place text under an English app.
        #expect(parse("Αυγ 2025").months.isEmpty)
    }

    // MARK: - Region words

    @Test("region words of every supported language are recognized, exactly")
    func regionWordsInEveryLanguage() {
        func codes(_ query: String, _ tag: String = "en") -> Set<String> {
            TripSearch.terms(query, languageTag: tag, allowsTrailingPartial: false).first?.countryCodes ?? []
        }
        #expect(codes("Ευρώπη").contains("FR"))
        #expect(codes("Europa").contains("DE"))
        #expect(codes("Südamerika").contains("BR"))
        #expect(codes("Europ").isEmpty)
        // Another language's region word never widens a country alias.
        #expect(codes("America") == ["US"])
        #expect(codes("América", "es").contains("MX"))
    }
}
