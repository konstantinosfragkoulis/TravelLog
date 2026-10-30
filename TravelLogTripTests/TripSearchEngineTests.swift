//
//  TripSearchEngineTests.swift
//  TravelLogTests
//
//  The tiered search engine over plain documents: normalization and ICU
//  transforms, term construction, tiers and per-field-kind gating, numeric and
//  date rules, aliases, region and foreign country words, evidence, field
//  restriction, spelling suggestions, and a logged (never asserted) benchmark.
//  Documents are built through the memberwise API; nothing touches SwiftData,
//  so the suite is not @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct TripSearchEngineTests {

    // MARK: - Fixtures

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func doc(
        title: [String] = [],
        titleIsUserNamed: Bool = false,
        place: [String] = [],
        region: [String] = [],
        countries: [String] = [],
        transit: [String] = [],
        start: Date = day(2024, 11, 4),
        end: Date? = nil,
        languageTag: String = "en",
        id: UUID = UUID(),
        normalizer: TripSearchNormalizer? = nil
    ) -> TripSearchDocument {
        TripSearchDocument(
            tripID: id,
            fields: [
                TripSearchField(kind: .title, displayValues: title, isUserNamed: titleIsUserNamed),
                TripSearchField(kind: .place, displayValues: place),
                TripSearchField(kind: .region, displayValues: region),
                TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(
                    for: countries, languageTag: languageTag)),
                TripSearchField(kind: .date, displayValues: TripSearchDocument.dateWords(
                    start: start, end: end, languageTag: languageTag, calendar: calendar)),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: start,
            endDate: end,
            startYear: calendar.component(.year, from: start),
            startMonth: calendar.component(.month, from: start),
            durationDays: nil,
            isComplete: true,
            countryCodes: Set(countries),
            normalizer: normalizer)
    }

    private static func run(
        _ query: String,
        _ docs: [TripSearchDocument],
        languageTag: String = "en",
        typing: Bool = false
    ) -> [TripSearchMatch] {
        let index = TripSearchIndex(documents: docs)
        return TripSearch.match(
            terms: TripSearch.terms(query, languageTag: languageTag, allowsTrailingPartial: typing),
            in: index)
    }

    /// Matched document indices.
    private static func hits(
        _ query: String,
        _ docs: [TripSearchDocument],
        languageTag: String = "en",
        typing: Bool = false
    ) -> [Int] {
        run(query, docs, languageTag: languageTag, typing: typing).map(\.documentIndex)
    }

    private static func strengths(
        _ query: String,
        _ docs: [TripSearchDocument],
        languageTag: String = "en",
        typing: Bool = false
    ) -> [Int: TripSearchStrength] {
        Dictionary(uniqueKeysWithValues: run(query, docs, languageTag: languageTag, typing: typing)
            .map { ($0.documentIndex, $0.strength) })
    }

    // MARK: - Normalization

    @Test("CJK segmentation reuses one tokenizer safely across calls and threads")
    func segmentCJKReuse() async {
        #expect(TripSearchText.segmentCJK("東京旅行") == ["東京", "旅行"])
        #expect(TripSearchText.segmentCJK("京都") == ["京都"])
        #expect(TripSearchText.segmentCJK("東京旅行") == ["東京", "旅行"])
        #expect(TripSearchText.segmentCJK("") == [""])
        let results = await withTaskGroup(of: [String].self) { group in
            for offset in 0..<64 {
                group.addTask { TripSearchText.segmentCJK(offset.isMultiple(of: 2) ? "東京旅行" : "京都の秋") }
            }
            return await group.reduce(into: [[String]]()) { $0.append($1) }
        }
        #expect(results.filter { $0 == ["東京", "旅行"] }.count == 32)
        #expect(results.filter { $0 == TripSearchText.segmentCJK("京都の秋") }.count == 32)
    }

    @Test("Fold table", arguments: [
        ("Đà Lạt", ["da lat"]),
        ("Ða Lat", ["da lat"]),
        ("Tromsø", ["tromso", "tromsoe"]),
        ("Łódź", ["lodz"]),
        ("Ærøskøbing", ["aeroskobing", "aeroeskoebing"]),
        ("Straße", ["strasse"]),
        ("İstanbul", ["istanbul"]),
        ("Diyarbakır", ["diyarbakir"]),
        ("ＴＯＫＹＯ", ["tokyo"]),
        ("２０２４", ["2024"]),
        ("Xi’an", ["xi'an"]),
        ("Αθήνα", ["αθηνα", "athena", "athina"]),
        ("Ιωάννινα", ["ιωαννινα", "ioannina"]),
        ("東京", ["東京"]),
        ("パリ", ["パリ", "pari"]),
        ("도쿄", ["도쿄", "dokyo"]),
        ("Москва", ["москва", "moskva"]),
        ("  Paris ", ["paris"]),
    ])
    func foldTable(value: String, expected: [String]) {
        #expect(TripSearch.normalizedSearchForms(value) == expected)
    }

    @Test("A builder-local normalizer produces the same document as the global memo")
    func normalizerParity() {
        let id = UUID()
        let normalizer = TripSearchNormalizer()
        let a = Self.doc(title: ["Ιωάννινα"], place: ["Đà Lạt", "New York City"], countries: ["GR"], id: id)
        let b = Self.doc(title: ["Ιωάννινα"], place: ["Đà Lạt", "New York City"], countries: ["GR"], id: id,
                         normalizer: normalizer)
        #expect(a == b)
        #expect(a.words.contains { $0.text == "newyorkcity" && $0.isCompound })
    }

    // MARK: - Terms

    @Test("Terms: alternatives, segmentation, particles, separators, numeric and trailing flags")
    func termConstruction() {
        let greek = TripSearch.terms("Ιωάννινα", languageTag: "en")
        #expect(greek.count == 1)
        #expect(greek[0].alternatives.contains(["ioannina"]))
        #expect(greek[0].alternatives.contains(["ιωαννινα"]))

        #expect(TripSearch.terms("東京旅行", languageTag: "ja")[0].alternatives.contains(["東京", "旅行"]))
        #expect(TripSearch.terms("京都の旅", languageTag: "ja")[0].alternatives.contains(["京都", "旅"]))
        let korean = TripSearch.terms("서울의", languageTag: "ko")[0]
        #expect(korean.aliasAlternatives.contains(["서울"]))
        #expect(korean.aliasAlternatives.contains(["seoul"]))
        #expect(!korean.alternatives.contains(["서울"]))
        #expect(TripSearch.terms("Ιταλίας", languageTag: "el")[0].alternatives.contains(["ιταλια"]))
        #expect(TripSearch.terms("nyc", languageTag: "en")[0].cityAlternatives == [["newyork"]])

        #expect(TripSearch.terms("Xi’an", languageTag: "en").map(\.raw) == ["Xi", "an"])
        let plus = TripSearch.terms("10+", languageTag: "en")
        #expect(plus.map(\.raw) == ["10"])
        #expect(plus[0].isNumeric)
        #expect(TripSearch.terms("２０２４", languageTag: "en")[0].isNumeric)

        #expect(TripSearch.terms("paris lon", languageTag: "en").map(\.isTrailingPartial) == [false, true])
        #expect(TripSearch.terms("paris lon ", languageTag: "en").map(\.isTrailingPartial) == [false, false])
        #expect(TripSearch.terms("paris lon", languageTag: "en", allowsTrailingPartial: false)
            .allSatisfy { !$0.isTrailingPartial })
    }

    @Test("Zero terms from a non-empty query match nothing; empty terms match everything")
    func zeroTermQueries() {
        #expect(TripSearch.terms("+ & 🏖️", languageTag: "en").isEmpty)
        #expect(!TripSearch.matches(query: "🏖️", in: ["Beach"], languageTag: "en"))
        #expect(!TripSearch.matches(query: "🇬🇷", in: ["Greece"], languageTag: "en"))
        #expect(TripSearch.matches(query: "  ", in: ["Beach"], languageTag: "en"))
        let docs = [Self.doc(place: ["Paris"]), Self.doc(place: ["Rome"])]
        let all = TripSearch.match(terms: [], in: TripSearchIndex(documents: docs))
        #expect(all.map(\.documentIndex) == [0, 1])
        #expect(all.allSatisfy { $0.strength == .strong })
    }

    // MARK: - Numbers and dates

    @Test("Years are exact: 2024, 24 and 202 prefix; never fuzzy")
    func numericRules() {
        let docs = [
            Self.doc(place: ["Lisbon"], start: Self.day(2023, 6)),
            Self.doc(place: ["Porto"], start: Self.day(2024, 6)),
            Self.doc(place: ["Faro"], start: Self.day(2025, 6)),
            Self.doc(place: ["Braga"], start: Self.day(2023, 12, 28), end: Self.day(2024, 1, 3)),
            Self.doc(place: ["Evora"], start: Self.day(2013, 6)),
        ]
        #expect(Self.strengths("2024", docs) == [1: .strong, 3: .strong])
        #expect(Self.hits("24", docs) == [1, 3])
        #expect(Self.hits("2013", docs) == [4])
        #expect(Self.hits("2019", docs).isEmpty)
        #expect(Self.hits("202", docs) == [0, 1, 2, 3])
        #expect(Self.hits("２０２４", docs) == [1, 3])
    }

    @Test("Digits prefix words that are not all digits: 30 finds 30th, 4 finds 4x4")
    func numericPrefixesOrdinals() {
        let docs = [
            Self.doc(title: ["30th birthday"], place: ["Lisbon"]),
            Self.doc(title: ["Mom's 50th"], place: ["Porto"]),
            Self.doc(title: ["4x4 safari"], place: ["Nairobi"]),
            Self.doc(place: ["10 Downing Street"]),
        ]
        #expect(Self.strengths("30", docs) == [0: .strong])
        #expect(Self.hits("3", docs) == [0])
        #expect(Self.hits("50", docs) == [1])
        #expect(Self.hits("4", docs) == [2])
        // Numeric words still need 3+ digits, and compounds ("10downing") and
        // date words ("2024") are never prefixed.
        #expect(Self.hits("1", docs).isEmpty)
        #expect(Self.hits("2", docs).isEmpty)
        #expect(Self.hits("10", docs) == [3])
    }

    @Test("CJK and Vietnamese month words match exactly, never by containment",
          arguments: [
            ("ja", "1月", 0), ("ja", "11月", 1),
            ("zh-Hans", "一月", 0), ("zh-Hans", "十一月", 1), ("zh-Hans", "1月", 0),
            ("ko", "1월", 0), ("ko", "11월", 1),
            ("vi", "tháng 1", 0), ("vi", "tháng 11", 1),
          ])
    func cjkMonthWords(languageTag: String, query: String, expected: Int) {
        let docs = [
            Self.doc(place: ["Kyoto"], start: Self.day(2024, 1), languageTag: languageTag),
            Self.doc(place: ["Osaka"], start: Self.day(2024, 11), languageTag: languageTag),
        ]
        #expect(Self.hits(query, docs, languageTag: languageTag) == [expected])
    }

    @Test("Date words carry ASCII years plus localized year and month words")
    func dateWordsHelper() {
        let ja = TripSearchDocument.dateWords(start: Self.day(2024, 1), end: nil, languageTag: "ja", calendar: Self.calendar)
        #expect(ja.contains("2024"))
        #expect(ja.contains("2024年"))
        #expect(ja.contains("1月"))
        let en = TripSearchDocument.dateWords(start: Self.day(2023, 12, 28), end: Self.day(2024, 1, 3),
                                              languageTag: "en", calendar: Self.calendar)
        #expect(en == ["2023", "December", "Dec", "2024", "January", "Jan"])
        #expect(TripSearchDocument.dateWords(start: Self.day(2024, 1), end: nil, languageTag: "ko",
                                             calendar: Self.calendar).contains("2024"))
    }

    @Test("Month words are never fuzzy: Juli finds July, never June")
    func dateWordsNeverFuzzy() {
        let june = [Self.doc(place: ["Hamburg"], start: Self.day(2024, 6), languageTag: "de")]
        #expect(Self.hits("Juli", june, languageTag: "de").isEmpty)
        let both = june + [Self.doc(place: ["Bremen"], start: Self.day(2024, 7), languageTag: "de")]
        #expect(Self.hits("Juli", both, languageTag: "de") == [1])
    }

    // MARK: - Scripts

    @Test("Native script finds Latin-stored places")
    func crossScript() {
        #expect(Self.strengths("Μύκονος", [Self.doc(place: ["Mykonos"])]) == [0: .strong])
        #expect(Self.strengths("Ιωάννινα", [Self.doc(place: ["Ioánnina"])]) == [0: .strong])
        #expect(Self.strengths("Κρήτη", [Self.doc(region: ["Crete"])]) == [0: .similar])
        #expect(Self.strengths("도쿄", [Self.doc(place: ["Tokyo"])]) == [0: .similar])
        #expect(Self.hits("Αθήνα", [Self.doc(place: ["Mykonos"])]).isEmpty)
    }

    @Test("A 4-letter romanization of a non-Latin word fuzzes only by a final vowel swap")
    func shortRomanizationsDoNotFuzz() {
        #expect(Self.hits("파리", [Self.doc(place: ["Palm Springs"], languageTag: "ko")], languageTag: "ko").isEmpty)
        #expect(Self.hits("로마", [Self.doc(place: ["Lima"], languageTag: "ko")], languageTag: "ko").isEmpty)
        let cancun = [Self.doc(place: ["Cancún"], region: ["Quintana Roo"], languageTag: "el")]
        #expect(Self.hits("Ρόδος", cancun, languageTag: "el").isEmpty)
        #expect(Self.hits("Ρόδο", cancun, languageTag: "el").isEmpty)
        // Exact and prefix matches of the romanization still count.
        #expect(Self.strengths("파리", [Self.doc(place: ["Paliouri"], languageTag: "ko")], languageTag: "ko")
            == [0: .strong])
        // Typed in Latin letters, a 4-letter typo still fuzzes.
        #expect(Self.strengths("pals", [Self.doc(place: ["Palm Springs"])]) == [0: .similar])
        // roma for ローマ swaps only its final vowel: Rome is similar.
        let rome = [Self.doc(place: ["Rome"], countries: ["IT"], languageTag: "ja"),
                    Self.doc(place: ["Lima"], countries: ["PE"], languageTag: "ja")]
        #expect(Self.strengths("ローマ", rome, languageTag: "ja") == [0: .similar])
    }

    @Test("A Hangul particle stem is an exact word, never a prefix or infix")
    func hangulStemIsExact() {
        let docs = [
            Self.doc(place: ["Malaga"], countries: ["ES"], languageTag: "ko"),
            Self.doc(place: ["Antigua Guatemala"], countries: ["GT"], languageTag: "ko"),
            Self.doc(place: ["Braga"], countries: ["PT"], languageTag: "ko"),
            Self.doc(place: ["Rio de Janeiro"], countries: ["BR"], languageTag: "ko"),
            Self.doc(place: ["Lilongwe"], countries: ["MW"], languageTag: "ko"),
            Self.doc(place: ["Seoul"], countries: ["KR"], languageTag: "ko"),
        ]
        #expect(!Self.hits("말라가", docs, languageTag: "ko").contains(1))
        #expect(!Self.hits("말라가", docs, languageTag: "ko").contains(4))
        #expect(!Self.hits("브라가", docs, languageTag: "ko").contains(3))
        #expect(Self.strengths("서울의", docs, languageTag: "ko") == [5: .strong])
        let native = [Self.doc(place: ["말라가"], languageTag: "ko"), Self.doc(place: ["말라위"], languageTag: "ko")]
        #expect(Self.hits("말라가", native, languageTag: "ko") == [0])
    }

    @Test("Greek genitives match the nominative strongly", arguments: [
        ("Ιταλίας", 0), ("Ρώμης", 0), ("Παρισιού", 1), ("Ιωαννίνων", 2), ("Χανιών", 3), ("Γερμανίας", 4),
    ])
    func greekGenitives(query: String, expected: Int) {
        let docs = [
            Self.doc(place: ["Ρώμη"], countries: ["IT"], start: Self.day(2024, 7), languageTag: "el"),
            Self.doc(place: ["Παρίσι"], countries: ["FR"], start: Self.day(2024, 1), languageTag: "el"),
            Self.doc(place: ["Ιωάννινα"], countries: ["GR"], start: Self.day(2023, 8, 4), languageTag: "el"),
            Self.doc(place: ["Χανιά"], countries: ["GR"], start: Self.day(2022, 3), languageTag: "el"),
            Self.doc(place: ["Berlin"], countries: ["DE"], start: Self.day(2021, 3), languageTag: "el"),
        ]
        #expect(Self.strengths(query, docs, languageTag: "el") == [expected: .strong])
        #expect(Self.strengths("Ιουλίου", docs, languageTag: "el") == [0: .strong])
        #expect(Self.strengths("Ιανουαρίου 2024", docs, languageTag: "el") == [1: .strong])
        #expect(Self.strengths("Ελλάδας", docs, languageTag: "el") == [2: .strong, 3: .strong])
        #expect(TripSearch.spellingSuggestion(for: "Ελλάδας", in: TripSearchIndex(documents: docs),
                                              languageTag: "el") == nil)
    }

    @Test("Katakana names with and without the middle dot find each other")
    func katakanaMiddleDot() {
        let docs = [Self.doc(place: ["サン・フランシスコ"], languageTag: "ja"),
                    Self.doc(place: ["サンフランシスコ"], languageTag: "ja"),
                    Self.doc(place: ["ロサンゼルス"], languageTag: "ja")]
        #expect(Self.strengths("サンフランシスコ", docs, languageTag: "ja") == [0: .strong, 1: .strong])
        #expect(Self.strengths("サン・フランシスコ", docs, languageTag: "ja") == [0: .strong, 1: .strong])
    }

    @Test("Japanese titles match by word inside the title")
    func japaneseTitle() {
        let docs = [Self.doc(title: ["東京の春"], place: ["Tokyo"], languageTag: "ja"),
                    Self.doc(title: ["京都の秋"], place: ["Kyoto"], languageTag: "ja")]
        #expect(Self.hits("東京の春", docs, languageTag: "ja") == [0])
        #expect(Self.hits("春", docs, languageTag: "ja") == [0])
        #expect(Self.hits("東京", docs, languageTag: "ja") == [0])
        #expect(Self.hits("jing", docs, languageTag: "ja").isEmpty)
    }

    // MARK: - Precision

    @Test("Short tokens match word starts only")
    func shortTokens() {
        let austriaUS = [Self.doc(place: ["Vienna"], countries: ["AT"], start: Self.day(2024, 8)),
                         Self.doc(place: ["White Plains"], countries: ["US"])]
        #expect(Self.hits("us", austriaUS) == [1])
        let italyUS = [Self.doc(place: ["Rome"], countries: ["IT"]),
                       Self.doc(title: ["United States"], place: ["Denver"], countries: ["US"])]
        #expect(Self.hits("it", italyUS) == [0])
        let berlin = [Self.doc(place: ["Berlin"], countries: ["DE"]),
                      Self.doc(place: ["Lisbon"], countries: ["PT"], start: Self.day(2024, 10))]
        #expect(Self.hits("ber", berlin) == [0])
    }

    @Test("Exact words gate fuzz across the corpus")
    func gating() {
        let hongKong = [Self.doc(place: ["Hong Kong"], countries: ["HK"]),
                        Self.doc(place: ["Long Beach"], countries: ["US"]),
                        Self.doc(place: ["Ha Long"], countries: ["VN"])]
        #expect(Self.hits("hong kong", hongKong) == [0])
        #expect(Self.hits("long", hongKong) == [1, 2])
        #expect(Self.hits("home", [Self.doc(place: ["Rome"])]).isEmpty)
        #expect(Self.strengths("samus", [Self.doc(place: ["Samus"]), Self.doc(place: ["Samos"])]) == [0: .strong])
        #expect(Self.strengths("samus", [Self.doc(place: ["Samos"])]) == [0: .similar])
        #expect(Self.hits("brat", [Self.doc(place: ["Bratislava"]), Self.doc(place: ["Berat"])]) == [0])
        #expect(Self.hits("toxxo", [Self.doc(place: ["Tokyo"])]).isEmpty)
        #expect(Self.hits("abc", [Self.doc(place: ["Abd"])]).isEmpty)
    }

    @Test("An exact hit gates fuzz only in its own field kind")
    func perFieldGating() {
        let roma = [Self.doc(place: ["Bucharest"], countries: ["RO"]), Self.doc(place: ["Rome"], countries: ["IT"])]
        #expect(Self.strengths("roma", roma) == [0: .strong, 1: .similar])
        let romantic = [Self.doc(title: ["Romantic weekend"], place: ["Vienna"], countries: ["AT"]),
                        Self.doc(place: ["Rome"], countries: ["IT"])]
        #expect(Self.strengths("roma", romantic) == [0: .strong, 1: .similar])
        let milano = [Self.doc(title: ["Milano fashion week"], place: ["Turin"], countries: ["IT"]),
                      Self.doc(place: ["Milan"], countries: ["IT"])]
        #expect(Self.strengths("milano", milano) == [0: .strong, 1: .similar])
        #expect(Self.hits("brat", [Self.doc(place: ["Bratislava"]), Self.doc(place: ["Berat"])]) == [0])
        let hongKong = [Self.doc(place: ["Hong Kong"], countries: ["HK"]),
                        Self.doc(place: ["Long Beach"], countries: ["US"]),
                        Self.doc(place: ["Ha Long"], countries: ["VN"])]
        #expect(Self.hits("hong kong", hongKong) == [0])
        #expect(Self.strengths("samus", [Self.doc(place: ["Samus"]), Self.doc(place: ["Samos"])]) == [0: .strong])
        #expect(Self.hits("home", [Self.doc(place: ["Rome"])]).isEmpty)
        // A title that repeats its place gates as the place; one that does not stays open.
        let samos = [Self.doc(title: ["Samus Weekend"], place: ["Samus"]), Self.doc(place: ["Samos"])]
        #expect(Self.strengths("samos", samos) == [1: .strong])
        let berat = [Self.doc(place: ["Bratislava"]), Self.doc(title: ["Berat and Gjirokastër"], place: ["Berat"])]
        #expect(Self.hits("brat", berat) == [0])
        let titledMilan = [milano[0], Self.doc(title: ["Milan getaway"], place: ["Milan"], countries: ["IT"])]
        let milan = Self.run("milano", titledMilan)
        #expect(milan.map(\.strength) == [.strong, .similar])
        #expect(milan.last?.evidence == [TripSearchEvidence(kind: .place, text: "Milan")])
        // Field restriction also restricts which kinds gate.
        let index = TripSearchIndex(documents: milano)
        let terms = TripSearch.terms("milano", languageTag: "en", allowsTrailingPartial: false)
        #expect(TripSearch.match(terms: terms, in: index, fields: [.title]).map(\.documentIndex) == [0])
        let places = TripSearch.match(terms: terms, in: index, fields: [.place, .region, .country])
        #expect(places.map(\.documentIndex) == [1])
        #expect(places.first?.strength == .similar)
    }

    @Test("A term's alias, city, country-code or joined hit also gates its fuzz")
    func termLevelGating() {
        let grecia = [Self.doc(place: ["Athens"], countries: ["GR"]), Self.doc(place: ["Gràcia"], countries: ["ES"])]
        #expect(Self.strengths("grecia", grecia) == [0: .strong])
        let italia = [Self.doc(place: ["Rome"], countries: ["IT"]),
                      Self.doc(title: ["Italica ruins"], place: ["Santiponce"], countries: ["ES"])]
        #expect(Self.strengths("italia", italia) == [0: .strong])
        let mount = [Self.doc(place: ["Mt Cook Village"], countries: ["NZ"]),
                     Self.doc(place: ["Chamonix"], countries: ["FR"]),
                     Self.doc(title: ["Mont Blanc hike"], place: ["Courmayeur"], countries: ["IT"])]
        #expect(Self.strengths("mount", mount) == [0: .strong])
        // "grecia" names Greece (es, it), so it never fuzzes, even without a Greece trip.
        #expect(Self.strengths("grecia", [grecia[1]]).isEmpty)
    }

    @Test("A recognized country name never fuzzes; a typo of one still does")
    func recognizedNamesDoNotFuzz() {
        let docs = [Self.doc(place: ["Chicago"], countries: ["US"]),
                    Self.doc(place: ["Chiang Mai"], countries: ["TH"])]
        #expect(Self.hits("china", docs).isEmpty)
        #expect(Self.hits("china", docs, typing: true).isEmpty)
        let withChina = docs + [Self.doc(place: ["Beijing"], countries: ["CN"])]
        #expect(Self.strengths("china", withChina, typing: true) == [2: .strong])
        #expect(Self.hits("italia", [Self.doc(title: ["Italica ruins"], place: ["Santiponce"], countries: ["ES"])])
            .isEmpty)
        let greece = [Self.doc(place: ["Athens"], countries: ["GR"]), Self.doc(place: ["Rome"], countries: ["IT"])]
        #expect(Self.hits("grece", greece, typing: true) == [0])
        #expect(Self.strengths("itlay", greece) == [1: .similar])
        #expect(Self.strengths("itlay", greece, typing: true) == [1: .similar])
    }

    @Test("Typo budget by length", arguments: [
        ("provance", ["Provence-Alpes-Côte d'Azur"], true),
        ("barselonna", ["Barcelona"], true),
        ("ioanmia", ["Ioánnina"], true),
        ("marakech", ["Marrakech"], true),
        ("londno", ["London"], true),
        ("barclna", ["Barcelona"], true),
        ("amstdam", ["Amsterdam"], true),
        ("toxxo", ["Tokyo"], false),
        ("lodn", ["Oldn"], false),
    ])
    func typoBudget(query: String, place: [String], matches: Bool) {
        let result = Self.strengths(query, [Self.doc(place: place)])
        #expect(result == (matches ? [0: .similar] : [:]))
    }

    @Test("Two edits reach only long words; a word that matches as typed does not also fuzz while typing")
    func fuzzPrecision() {
        let romania = [Self.doc(place: ["Vienna"], countries: ["AT"]), Self.doc(place: ["Bucharest"], countries: ["RO"])]
        #expect(Self.hits("romantic", romania).isEmpty)
        let florence = [Self.doc(place: ["Florence"], countries: ["IT"]), Self.doc(place: ["Lyon"], countries: ["FR"])]
        #expect(Self.strengths("florance", florence) == [0: .similar])
        let vienna = [Self.doc(place: ["Vienna"], countries: ["AT"]), Self.doc(place: ["Hanoi"], countries: ["VN"])]
        #expect(Self.strengths("vienna", vienna, typing: true) == [0: .strong])
        let porto = [Self.doc(place: ["Porto"], countries: ["PT"]), Self.doc(place: ["Lisbon"], countries: ["PT"])]
        #expect(Self.strengths("porto", porto, typing: true) == [0: .strong])
        // Without a match as typed, the typing tolerance stays.
        #expect(Self.strengths("vienn", [vienna[1]], typing: true) == [0: .similar])
    }

    @Test("A long foreign name with no exact hit reaches the shorter English place", arguments: [
        ("Lissabon", "de", "Lisbon", "PT"), ("Warszawa", "sv", "Warsaw", "PL"),
        ("Βερολίνο", "el", "Berlin", "DE"), ("런던", "ko", "London", "GB"), ("ミコノス", "ja", "Mykonos", "GR"),
    ])
    func longForeignNames(query: String, languageTag: String, place: String, country: String) {
        let docs = [Self.doc(place: [place], countries: [country], languageTag: languageTag),
                    Self.doc(place: ["Oslo"], countries: ["NO"], languageTag: languageTag)]
        #expect(Self.strengths(query, docs, languageTag: languageTag) == [0: .similar])
    }

    @Test("mailand does not find Thailand; romantic in a title does not find Romania")
    func longWordFirstLetter() {
        let docs = [Self.doc(place: ["Bangkok"], countries: ["TH"], languageTag: "de"),
                    Self.doc(place: ["Milan"], countries: ["IT"], languageTag: "de")]
        #expect(Self.hits("Mailand", docs, languageTag: "de").isEmpty)
        let romantic = [Self.doc(title: ["Romantic weekend"], place: ["Paris"], countries: ["FR"]),
                        Self.doc(place: ["Bucharest"], countries: ["RO"])]
        #expect(Self.strengths("romantic", romantic) == [0: .strong])
    }

    @Test("provance finds both Provence and Province as similar")
    func provanceBothAdmins() {
        let docs = [Self.doc(region: ["Provence-Alpes-Côte d'Azur"], countries: ["FR"]),
                    Self.doc(region: ["Lima Province"], countries: ["PE"])]
        #expect(Self.strengths("provance", docs) == [0: .similar, 1: .similar])
    }

    @Test("san fransico: exact word plus one long typo is similar")
    func twoWordTypo() {
        #expect(Self.strengths("san fransico", [Self.doc(place: ["San Francisco"])]) == [0: .similar])
    }

    @Test("Barcelona stays visible while typing; a trailing space ends fuzzy prefix")
    func typingSequence() {
        let docs = [Self.doc(place: ["Barcelona"], countries: ["ES"]), Self.doc(place: ["Lisbon"], countries: ["PT"])]
        for query in ["b", "ba", "bar", "barc", "barcl", "barcle", "barcleo", "barcleon", "barcleona"] {
            #expect(Self.hits(query, docs, typing: true).contains(0), "\(query)")
        }
        #expect(Self.hits("barcl ", docs, typing: true).isEmpty)
        #expect(Self.hits("barcl", docs, typing: false).isEmpty)
    }

    // MARK: - Folds, compounds, abbreviations

    @Test("Compounds, joined words and folded letters are strong", arguments: [
        ("newyork", "New York"), ("newyorkcity", "New York City"), ("hongkong", "Hong Kong"),
        ("dalat", "Đà Lạt"), ("da lat", "Đà Lạt"), ("bang kok", "Bangkok"),
        ("tromso", "Tromsø"), ("lodz", "Łódź"), ("aeroskobing", "Ærøskøbing"), ("thu duc", "Thu Đuc"),
        ("xian", "Xi’an"), ("xi'an", "Xi’an"),
        ("st tropez", "Saint-Tropez"), ("st-tropez", "Saint-Tropez"), ("saint moritz", "St. Moritz"),
        ("mt fuji", "Mount Fuji"), ("mount cook", "Mt Cook"), ("ft lauderdale", "Fort Lauderdale"),
    ])
    func strongVariants(query: String, place: String) {
        #expect(Self.strengths(query, [Self.doc(place: [place])]) == [0: .strong])
    }

    @Test("Abbreviation aliases are exact only")
    func abbreviationPrecision() {
        #expect(Self.hits("saint", [Self.doc(place: ["Stuttgart"])]).isEmpty)
        #expect(Self.hits("mount", [Self.doc(place: ["Mtskheta"])]).isEmpty)
    }

    @Test("City abbreviations", arguments: [
        ("nyc", "New York"), ("ny", "New York"), ("la", "Los Angeles"), ("sf", "San Francisco"),
        ("dc", "Washington"), ("hk", "Hong Kong"), ("kl", "Kuala Lumpur"), ("cdmx", "Mexico City"),
        ("bcn", "Barcelona"),
    ])
    func cityAbbreviations(query: String, place: String) {
        let docs = [Self.doc(place: [place]), Self.doc(place: ["Oslo"], countries: ["NO"])]
        #expect(Self.strengths(query, docs) == [0: .strong])
    }

    @Test("la keeps its literal prefix meaning; nyc needs the adjacent words")
    func cityAbbreviationBoundaries() {
        let docs = [Self.doc(place: ["Los Angeles"]), Self.doc(place: ["La Paz"]), Self.doc(place: ["Oslo"])]
        #expect(Self.hits("la", docs) == [0, 1])
        #expect(Self.hits("nyc", [Self.doc(place: ["New Delhi"], region: ["York"])]).isEmpty)
    }

    @Test("City abbreviations match place words only, not a state of the same name")
    func cityAbbreviationsArePlaces() {
        let washington = [Self.doc(place: ["Washington"], region: ["District of Columbia"], countries: ["US"]),
                          Self.doc(place: ["Seattle"], region: ["Washington"], countries: ["US"])]
        #expect(Self.strengths("dc", washington) == [0: .strong])
        let newYork = [Self.doc(place: ["New York"], region: ["New York"], countries: ["US"]),
                       Self.doc(place: ["Buffalo"], region: ["New York"], countries: ["US"])]
        #expect(Self.strengths("nyc", newYork) == [0: .strong])
    }

    // MARK: - Countries and regions

    @Test("Curated country aliases are strong and specific", arguments: [
        ("uk", 0), ("britain", 0), ("great britain", 0), ("usa", 1), ("america", 1), ("turkey", 2),
        ("uae", 3), ("czech republic", 4), ("holland", 5), ("bosnia and herzegovina", 6),
    ])
    func curatedAliases(query: String, expected: Int) {
        let docs = [
            Self.doc(place: ["London"], countries: ["GB"]),
            Self.doc(place: ["White Plains"], countries: ["US"]),
            Self.doc(place: ["Istanbul"], countries: ["TR"]),
            Self.doc(place: ["Dubai"], countries: ["AE"]),
            Self.doc(place: ["Prague"], countries: ["CZ"]),
            Self.doc(place: ["Amsterdam"], countries: ["NL"]),
            Self.doc(place: ["Sarajevo"], countries: ["BA"]),
        ]
        #expect(Self.strengths(query, docs) == [expected: .strong])
    }

    @Test("Connecting words of country names are not place words")
    func countryStopWords() {
        let docs = [Self.doc(place: ["White Plains"], countries: ["US"]),
                    Self.doc(place: ["Sarajevo"], countries: ["BA"]),
                    Self.doc(place: ["Douglas"], countries: ["IM"]),
                    Self.doc(place: ["Port of Spain"], countries: ["TT"])]
        let index = TripSearchIndex(documents: docs)
        #expect(!index.strictPlaceWords(of: 0).contains("of"))
        #expect(!index.strictPlaceWords(of: 1).contains("and"))
        #expect(index.strictPlaceWords(of: 3).contains("of"))
        #expect(index.strictPlaceWords(withPrefix: "and").isEmpty)
        #expect(Self.hits("and", docs).isEmpty)
        #expect(Self.hits("of", docs) == [3])
        #expect(Self.strengths("united states of america", docs) == [0: .strong])
        #expect(Self.strengths("isle of man", docs) == [2: .strong])
        #expect(Self.strengths("trinidad and tobago", docs) == [3: .strong])
        #expect(TripSearch.matches(query: "bosnia and herzegovina", in: ["Sarajevo", "Bosnia & Herzegovina"],
                                   languageTag: "en"))
    }

    @Test("A leading article of a country name stays matchable while typing (pickers)", arguments: [
        ("fr", "RE", "La"), ("fr", "RE", "La "), ("fr", "RE", "La R"),
        ("da", "AE", "De"), ("da", "AE", "De "), ("da", "AE", "De F"),
        ("nb", "AE", "De"), ("da", "VG", "De"),
    ])
    func leadingCountryArticle(languageTag: String, code: String, query: String) {
        // The pickers' shape: one document per code, names only in `.country`.
        let document = TripSearchDocument(
            tripID: UUID(),
            fields: [TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(
                for: [code], languageTag: languageTag))],
            startDate: .distantPast, endDate: nil, startYear: 0, startMonth: 0,
            durationDays: nil, isComplete: true, countryCodes: [code])
        let terms = TripSearch.terms(query, languageTag: languageTag)
        #expect(TripSearch.match(terms: terms, in: TripSearchIndex(documents: [document])).count == 1)
    }

    @Test("Colloquial Korean and Japanese country words", arguments: [
        ("한국", "ko", "KR", ["서울"]), ("남한", "ko", "KR", ["서울"]), ("米国", "ja", "US", ["ニューヨーク"]),
    ])
    func colloquialCountryWords(query: String, languageTag: String, country: String, place: [String]) {
        let docs = [Self.doc(place: place, countries: [country], languageTag: languageTag),
                    Self.doc(place: ["Paris"], countries: ["FR"], languageTag: languageTag)]
        #expect(Self.strengths(query, docs, languageTag: languageTag) == [0: .strong])
    }

    @Test("North America in the app language", arguments: [
        ("Βόρεια Αμερική", "el"), ("Nordamerika", "de"), ("Amérique du Nord", "fr"), ("North America", "en"),
    ])
    func northAmericaLocalized(query: String, languageTag: String) {
        let docs = [Self.doc(place: ["White Plains"], countries: ["US"], languageTag: languageTag),
                    Self.doc(place: ["Paris"], countries: ["FR"], languageTag: languageTag)]
        #expect(Self.strengths(query, docs, languageTag: languageTag) == [0: .strong])
    }

    @Test("Country aliases index ISO, English, app language and curated names only")
    func countryAliasSet() {
        let gb = TripSearch.countryAliases(for: ["gb"], languageTag: "en")
        #expect(gb.prefix(2) == ["GB", "United Kingdom"])
        #expect(gb.contains("UK") && gb.contains("Britain"))
        #expect(TripSearch.countryAliases(for: ["BA"], languageTag: "en").contains("Bosnia and Herzegovina"))
        #expect(!TripSearch.countryAliases(for: ["IS"], languageTag: "en").contains("Island"))
        #expect(TripSearch.countryAliases(for: ["IS"], languageTag: "de").contains("Island"))
        #expect(TripSearch.countryAliases(for: ["GR"], languageTag: "el").contains("Ελλάδα"))
        #expect(!TripSearch.countryAliases(for: ["DE"], languageTag: "en").contains("Đức"))
    }

    @Test("Curated aliases: England, Greek names of the UK and the US, Ellada")
    func curatedAliases() {
        func codes(_ query: String) -> Set<String> {
            TripSearch.terms(query, languageTag: "en", allowsTrailingPartial: false).first?.countryCodes ?? []
        }
        #expect(codes("England") == ["GB"])
        #expect(codes("Αγγλία") == ["GB"])
        #expect(codes("ΗΠΑ") == ["US"])
        #expect(codes("Αμερική") == ["US"])
        #expect(codes("Ellada") == ["GR"])
        #expect(TripSearch.countryAliases(for: ["GB"], languageTag: "en").contains("England"))
        #expect(TripSearchPlaceNames.searchNames(
            stored: [:], extras: TripSearchAliases.placeNameExtras["istanbul|TR"] ?? []) == ["Κωνσταντινούπολη"])
    }

    private static let regionCorpus = [
        doc(place: ["Athens"], countries: ["GR"]),        // 0
        doc(place: ["Tokyo"], countries: ["JP"]),         // 1
        doc(place: ["Bangkok"], countries: ["TH"]),       // 2
        doc(place: ["Kingston"], countries: ["JM"]),      // 3
        doc(place: ["Oslo"], countries: ["NO"]),          // 4
        doc(place: ["Helsinki"], countries: ["FI"]),      // 5
        doc(place: ["Istanbul"], countries: ["TR"]),      // 6
        doc(place: ["Limassol"], countries: ["CY"]),      // 7
        doc(place: ["Reykjavik"], countries: ["IS"]),     // 8
        doc(place: ["Mexico City"], countries: ["MX"]),   // 9
    ]

    @Test("Region words match destination countries", arguments: [
        ("europe", "en", [0, 4, 5, 6, 7, 8]),
        ("Ευρώπη", "el", [0, 4, 5, 6, 7, 8]),
        ("southeast asia", "en", [2]),
        ("caribbean", "en", [3]),
        ("scandinavia", "en", [4]),
        ("nordic", "en", [4, 5, 8]),
        ("middle east", "en", [6, 7]),
        ("asia", "en", [1, 2, 6, 7]),
        ("north america", "en", [3, 9]),
        ("latin america", "en", [3, 9]),
    ])
    func regionWords(query: String, languageTag: String, expected: [Int]) {
        let result = Self.run(query, Self.regionCorpus, languageTag: languageTag)
        #expect(result.map(\.documentIndex) == expected)
        #expect(result.allSatisfy { $0.strength == .strong })
    }

    private static let regionShortFormCorpus = [
        doc(place: ["Kathmandu"], countries: ["NP"]),     // 0
        doc(place: ["Delhi"], countries: ["IN"]),         // 1
        doc(place: ["Seoul"], countries: ["KR"]),         // 2
        doc(place: ["Tokyo"], countries: ["JP"]),         // 3
        doc(place: ["Prague"], countries: ["CZ"]),        // 4
        doc(place: ["Vienna"], countries: ["AT"]),        // 5
        doc(place: ["Budapest"], countries: ["HU"]),      // 6
        doc(place: ["Warsaw"], countries: ["PL"]),        // 7
        doc(place: ["Marrakech"], countries: ["MA"]),     // 8
        doc(place: ["Accra"], countries: ["GH"]),         // 9
        doc(place: ["Cape Town"], countries: ["ZA"]),     // 10
        doc(place: ["Nairobi"], countries: ["KE"]),       // 11
        doc(place: ["Dubai"], countries: ["AE"]),         // 12
        doc(place: ["Lisbon"], countries: ["PT"]),        // 13
        doc(place: ["Oslo"], countries: ["NO"]),          // 14
        doc(place: ["Libreville"], countries: ["GA"]),    // 15
    ]

    @Test("English short region names match their regions, not the direction word", arguments: [
        ("south asia", [0, 1]), ("east asia", [2, 3]), ("west asia", [12]),
        ("north africa", [8]), ("west africa", [9]), ("east africa", [11]), ("central africa", [15]),
        ("central europe", [4, 5, 6, 7]), ("east europe", [4, 6, 7]), ("west europe", [5]),
        ("north europe", [14]), ("south europe", [13]),
    ])
    func regionShortForms(query: String, expected: [Int]) {
        let result = Self.run(query, Self.regionShortFormCorpus)
        #expect(result.map(\.documentIndex) == expected)
        #expect(result.allSatisfy { $0.strength == .strong })
    }

    @Test("A region phrase matches by its codes only; a country phrase keeps its words", arguments: [
        ("west africa", [1]), ("east africa", [5]), ("south america", [4]),
        ("south korea", [6]), ("bosnia and herzegovina", [7]),
    ])
    func regionPhrasesMatchByCode(query: String, expected: [Int]) {
        let docs = [
            Self.doc(place: ["Cape Town"], region: ["Western Cape"], countries: ["ZA"]),     // 0
            Self.doc(place: ["Accra"], region: ["Greater Accra"], countries: ["GH"]),        // 1
            Self.doc(place: ["East London"], region: ["Eastern Cape"], countries: ["ZA"]),   // 2
            Self.doc(place: ["Charleston"], region: ["South Carolina"], countries: ["US"]),  // 3
            Self.doc(place: ["Lima"], countries: ["PE"]),                                   // 4
            Self.doc(place: ["Nairobi"], countries: ["KE"]),                                // 5
            // Named by the user: a country phrase still finds its words there.
            Self.doc(title: ["South Korea diary"], titleIsUserNamed: true, place: ["Busan"]),       // 6
            Self.doc(title: ["Bosnia & Herzegovina"], titleIsUserNamed: true, place: ["Mostar"]),   // 7
        ]
        let result = Self.run(query, docs)
        #expect(result.map(\.documentIndex) == expected)
        #expect(result.allSatisfy { $0.strength == .strong })
    }

    @Test("Region and foreign-name recognition is exact: negatives", arguments: [
        "north", "island", "duc", "anh", "dog", "kato", "tai", "lap", "europ", "scandinav",
    ])
    func regionNegatives(query: String) {
        let docs = Self.regionCorpus + [
            Self.doc(place: ["Berlin"], countries: ["DE"]),
            Self.doc(place: ["London"], countries: ["GB"]),
            Self.doc(place: ["Amsterdam"], countries: ["NL"]),
        ]
        #expect(Self.hits(query, docs).isEmpty)
    }

    @Test("kato finds Kato Paphos, not the Netherlands")
    func katoPaphos() {
        let docs = [Self.doc(place: ["Kato Paphos"], countries: ["CY"]), Self.doc(place: ["Amsterdam"], countries: ["NL"])]
        #expect(Self.hits("kato", docs) == [0])
    }

    @Test("Country names in other languages match exactly", arguments: [
        ("Deutschland", 0), ("日本", 1), ("Ελλάδα", 2), ("hellas", 2), ("Allemagne", 0), ("Japón", 1),
    ])
    func foreignCountryNames(query: String, expected: Int) {
        let docs = [Self.doc(place: ["Berlin"], countries: ["DE"]),
                    Self.doc(place: ["Tokyo"], countries: ["JP"]),
                    Self.doc(place: ["Athens"], countries: ["GR"])]
        #expect(Self.strengths(query, docs) == [expected: .strong])
    }

    // MARK: - Evidence and strength

    @Test("Transit places are similar with transit evidence; transit countries are not indexed")
    func transitEvidence() {
        let whitePlains = [Self.doc(place: ["White Plains"], countries: ["US"], transit: ["Frankfurt", "Hesse"])]
        #expect(Self.hits("germany", whitePlains).isEmpty)
        let result = Self.run("frankfurt", whitePlains)
        #expect(result == [TripSearchMatch(documentIndex: 0, strength: .similar,
                                           evidence: [TripSearchEvidence(kind: .transit, text: "Frankfurt")])])
    }

    @Test("Evidence: place over transit, region, country code, none when the title matched")
    func evidencePriority() {
        let bali = Self.run("Bali", [Self.doc(title: ["Honeymoon"], place: ["Bali"], countries: ["ID"])])
        #expect(bali == [TripSearchMatch(documentIndex: 0, strength: .strong,
                                         evidence: [TripSearchEvidence(kind: .place, text: "Bali")])])
        let both = Self.run("paris", [Self.doc(place: ["Paris"], transit: ["Paris"])])
        #expect(both.first?.evidence == [TripSearchEvidence(kind: .place, text: "Paris")])
        #expect(both.first?.strength == .strong)
        let titled = Self.run("paris", [Self.doc(title: ["Paris Weekend"], place: ["Paris"])])
        #expect(titled.first?.evidence == [])
        let region = Self.run("tuscany", [Self.doc(place: ["Siena"], region: ["Tuscany"])])
        #expect(region.first?.evidence == [TripSearchEvidence(kind: .region, text: "Tuscany")])
        let europe = Self.run("europe", [Self.doc(place: ["Athens"], countries: ["GR"])])
        #expect(europe.first?.evidence == [TripSearchEvidence(kind: .country, text: "GR")])
        let year = Self.run("2024 bali", [Self.doc(place: ["Bali"], start: Self.day(2024, 5))])
        #expect(year.first?.evidence.map(\.kind) == [.date, .place])
    }

    // MARK: - Field restriction and index API

    @Test("Field-restricted matching ignores other fields for matching and gating")
    func fieldRestriction() {
        let docs = [Self.doc(title: ["Japan in Spring"], place: ["Kyoto"], start: Self.day(2024, 4)),
                    Self.doc(place: ["Winter Park"], countries: ["US"])]
        let index = TripSearchIndex(documents: docs)
        let geographic: Set<TripSearchFieldKind> = [.place, .region, .country]
        let spring = TripSearch.terms("spring", languageTag: "en", allowsTrailingPartial: false)
        #expect(TripSearch.match(terms: spring, in: index, fields: geographic).isEmpty)
        #expect(TripSearch.match(terms: spring, in: index).map(\.documentIndex) == [0])
        let prak = TripSearch.terms("winter prak", languageTag: "en", allowsTrailingPartial: false)
        let result = TripSearch.match(terms: prak, in: index, fields: geographic)
        #expect(result.map(\.documentIndex) == [1])
        #expect(result.first?.strength == .similar)
    }

    @Test("Index exposes whole words, strict place words, prefix lookup and a generation")
    func indexAPI() {
        let docs = [Self.doc(title: ["Ski Week"], place: ["Winter Park"], countries: ["US"]),
                    Self.doc(place: ["Mayfair"], transit: ["Frankfurt"])]
        let index = TripSearchIndex(documents: docs)
        #expect(index.strictPlaceWords(of: 0).isSuperset(of: ["winter", "park", "us", "united", "states"]))
        #expect(!index.strictPlaceWords(of: 0).contains("winterpark"))
        #expect(!index.strictPlaceWords(of: 0).contains("ski"))
        #expect(index.wholeWords(of: 0).contains("ski"))
        #expect(index.wholeWords(of: 1).contains("frankfurt"))
        #expect(index.containsWord("Park"))
        #expect(!index.containsWord("winterpark"))
        #expect(index.strictPlaceWords(withPrefix: "win") == ["winter"])
        #expect(index.strictPlaceWords(withPrefix: "fra").isEmpty)
        #expect(TripSearchIndex(documents: docs).generation != index.generation)
        #expect(!index.isEmpty && TripSearchIndex(documents: []).isEmpty)
    }

    @Test("Strength helpers for plain string parts")
    func partsHelpers() {
        #expect(TripSearch.strength(query: "paris", in: ["Paris", "France"], languageTag: "en") == .strong)
        #expect(TripSearch.strength(query: "pariss", in: ["Paris"], languageTag: "en") == .similar)
        #expect(TripSearch.strength(query: "rome", in: ["Paris"], languageTag: "en") == nil)
        #expect(TripSearch.matchesStrongly(query: "paris", in: ["Paris"], languageTag: "en"))
        #expect(!TripSearch.matchesStrongly(query: "pariss", in: ["Paris"], languageTag: "en"))
        #expect(TripSearch.matches(query: "pariss", in: ["Paris"], languageTag: "en"))
        let terms = TripSearch.terms("koniz", languageTag: "en")
        #expect(TripSearch.matches(terms: terms, in: ["Köniz Airport"]))
    }

    @Test("Documents and matching work off the main actor")
    func offMain() async {
        let result = await Task.detached {
            let docs = [Self.doc(place: ["Paris"]), Self.doc(place: ["Rome"])]
            return Self.hits("rome", docs)
        }.value
        #expect(result == [1])
    }

    // MARK: - Spelling suggestions

    private static let suggestionCorpus = [
        doc(place: ["Ioánnina"], countries: ["GR"]),
        doc(place: ["Barcelona"], countries: ["ES"]),
        doc(place: ["Amsterdam"], countries: ["NL"]),
        doc(place: ["Reykjavik"], countries: ["IS"]),
        doc(place: ["Tokyo"], countries: ["JP"]),
    ]

    @Test("Did you mean: two-typo corrections in corpus casing", arguments: [
        ("ioanmia", "Ioánnina"), ("barsalona", "Barcelona"), ("amstredam", "Amsterdam"),
        ("reykjavek", "Reykjavik"), ("Barsalona 2024", "Barcelona 2024"),
    ])
    func spellingSuggestions(query: String, expected: String) {
        let index = TripSearchIndex(documents: Self.suggestionCorpus + [
            Self.doc(place: ["Girona"], countries: ["ES"], start: Self.day(2024, 5)),
            Self.doc(place: ["Barcelona"], countries: ["ES"], start: Self.day(2024, 9)),
        ])
        #expect(TripSearch.spellingSuggestion(for: query, in: index, languageTag: "en") == expected)
    }

    @Test("Did you mean: nothing within budget, strong results, numbers, short words")
    func spellingSuggestionNegatives() {
        let index = TripSearchIndex(documents: Self.suggestionCorpus)
        let far = TripSearchIndex(documents: [Self.doc(place: ["Lisbon"]), Self.doc(place: ["Paris"])])
        #expect(TripSearch.spellingSuggestion(for: "toxxo", in: far, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "tokyo", in: index, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "2031", in: index, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "tko", in: index, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "zzzzzz", in: index, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "barsalona", in: TripSearchIndex(documents: []),
                                              languageTag: "en") == nil)
        // A two-edit candidate must share the first three letters.
        #expect(TripSearch.spellingSuggestion(for: "toxxo", in: index, languageTag: "en") == nil)
        // The caller's verifier can veto.
        #expect(TripSearch.spellingSuggestion(for: "barsalona", in: index, languageTag: "en",
                                              accepts: { _ in false }) == nil)
        // A real country the user has not visited is not a typo for one they have.
        let neighbours = TripSearchIndex(documents: [Self.doc(place: ["Sydney"], countries: ["AU"]),
                                                     Self.doc(place: ["Bratislava"], countries: ["SK"])])
        #expect(TripSearch.spellingSuggestion(for: "Austria", in: neighbours, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "Slovenia", in: neighbours, languageTag: "en") == nil)
        #expect(TripSearch.spellingSuggestion(for: "Austrlia", in: neighbours, languageTag: "en") == "Australia")
    }

    @Test("Did you mean: a correctly spelled place is not corrected to a visited one", arguments: [
        ("Amsterdam", "Rotterdam", "NL"), ("Salzburg", "Hamburg", "DE"), ("Budapest", "Bucharest", "RO"),
        ("Split", "Madrid", "ES"), ("Naples", "Nantes", "FR"), ("Turin", "Tunis", "TN"),
    ])
    func spellingSuggestionRealPlaces(query: String, visited: String, country: String) {
        let index = TripSearchIndex(documents: [Self.doc(place: [visited], countries: [country])])
        #expect(TripSearch.spellingSuggestion(for: query, in: index, languageTag: "en") == nil)
    }

    @Test("Did you mean: first letter fixed, and a known word is never replaced")
    func spellingSuggestionKnownWords() {
        let provence = TripSearchIndex(documents: [Self.doc(place: ["Nice"], region: ["Provence"], countries: ["FR"])])
        #expect(TripSearch.spellingSuggestion(for: "Florence", in: provence, languageTag: "en") == nil)
        let bergen = TripSearchIndex(documents: [Self.doc(place: ["Bergen"], countries: ["NO"])])
        #expect(TripSearch.spellingSuggestion(for: "Berlin", in: bergen, languageTag: "en") == "Bergen")
        #expect(TripSearch.spellingSuggestion(for: "Berlin", in: bergen, languageTag: "en",
                                              isKnownWord: { $0.lowercased() == "berlin" }) == nil)
        #expect(TripSearch.spellingSuggestion(for: "Bergn", in: bergen, languageTag: "en",
                                              isKnownWord: { _ in false }) == "Bergen")
    }

    // MARK: - Benchmark (logged, never asserted)

    @Test("Benchmark: 1,000 documents, 20 queries")
    func benchmark() {
        let cities = ["Paris", "Lyon", "Nice", "Rome", "Florence", "Venice", "Milan", "Barcelona", "Madrid",
                      "Seville", "Lisbon", "Porto", "Berlin", "Munich", "Hamburg", "Vienna", "Prague", "Budapest",
                      "Athens", "Ioánnina", "Mykonos", "Paxos", "Tokyo", "Kyoto", "Osaka", "Seoul",
                      "Bangkok", "Hanoi", "Da Nang", "New York", "White Plains", "Chicago", "San Francisco",
                      "Los Angeles", "Mexico City", "Reykjavik", "Oslo", "Stockholm", "Copenhagen", "Helsinki"]
        let regions = ["Ile-de-France", "Lazio", "Tuscany", "Catalonia", "Bavaria", "Attica", "Kanto",
                       "California", "New York", "Capital Region"]
        let countries = ["FR", "IT", "ES", "PT", "DE", "AT", "CZ", "HU", "GR", "JP", "KR", "TH", "VN", "US",
                         "MX", "IS", "NO", "SE", "DK", "FI"]
        var state: UInt64 = 0x5EA2C4
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(limit))
        }
        // Synthetic names widen the vocabulary to the few thousand words of a large library.
        let syllables = ["ka", "lo", "ser", "vi", "tan", "mor", "el", "du", "rin", "sa", "po", "gra", "ne", "bur", "ta"]
        let synthetic = (0..<1500).map { _ in
            (0..<(2 + next(3))).map { _ in syllables[next(syllables.count)] }.joined().capitalized
        }
        let pool = cities + synthetic
        let normalizer = TripSearchNormalizer()
        let clock = ContinuousClock()
        var docs: [TripSearchDocument] = []
        let buildDocs = clock.measure {
            for index in 0..<1000 {
                let places = (0..<(1 + next(4))).map { _ in pool[next(pool.count)] }
                docs.append(Self.doc(
                    title: ["\(places[0]) \(["Getaway", "in Spring", "Weekend", "Road Trip"][next(4)])"],
                    place: places,
                    region: [regions[next(regions.count)]],
                    countries: [countries[next(countries.count)]],
                    transit: index % 7 == 0 ? ["Frankfurt", pool[next(pool.count)]] : [],
                    start: Self.day(2016 + next(10), 1 + next(12)),
                    normalizer: normalizer))
            }
        }
        var index = TripSearchIndex(documents: [])
        let buildIndex = clock.measure { index = TripSearchIndex(documents: docs) }
        let queries = ["2024", "24", "Μύκονος", "Κρήτη", "us", "it", "ber", "hong kong", "home", "paris",
                       "provance", "st tropez", "newyork", "tromso", "barselonna", "toxxo", "barcl", "uk",
                       "europe", "frankfurt"]
        var total = 0
        let matchTime = clock.measure {
            for query in queries {
                let terms = TripSearch.terms(query, languageTag: "en")
                total += TripSearch.match(terms: terms, in: index).count
            }
        }
        let foreignNames = clock.measure { _ = TripSearchAliases.makeForeignCountryNames() }
        let regionNames = clock.measure { _ = TripSearchAliases.makeRegionTable(languageTag: "sv") }
        print("TripSearch vocabulary tables: country names \(foreignNames), regions \(regionNames)")
        print("TripSearch benchmark: documents \(buildDocs), index \(buildIndex) (\(index.vocabulary.count) words), "
              + "20 queries \(matchTime), average \(matchTime / queries.count), results \(total)")
        #expect(total > 0)
    }
}
