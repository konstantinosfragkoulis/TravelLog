//
//  TripQueryVocabularyTests.swift
//  TravelLogTests
//
//  The parser's localized input vocabulary: Calendar-derived month words
//  for every app language, season/weekend/relative tables, the numeric
//  CJK and Vietnamese month patterns, and the place-name screen on filler
//  words. Words are compared the way the parser loads them (apostrophes
//  and hyphens as spaces, then `TripSearch.normalizedSearchForms`).
//

import Testing
import Foundation
@testable import TravelLog

struct TripQueryVocabularyTests {

    private static let tags = TripQueryVocabulary.supportedTags

    /// Native normalized form, prepared like the parser prepares both sides.
    private static func key(_ word: String) -> String {
        let spaced = word
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "’", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let form = TripSearch.normalizedSearchForms(spaced).first ?? spaced
        return form.split(separator: " ").joined(separator: " ")
    }

    private static func keys(_ words: some Sequence<String>) -> Set<String> {
        Set(words.map(key))
    }

    private static func regexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - Months

    @Test("every lexical Calendar month symbol maps to its month", arguments: tags)
    func calendarMonthSymbols(tag: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: tag)
        let months = TripQueryVocabulary.language(tag).months
        let lists = [
            calendar.monthSymbols, calendar.standaloneMonthSymbols,
            calendar.shortMonthSymbols, calendar.shortStandaloneMonthSymbols,
        ]
        for list in lists {
            for (index, symbol) in list.prefix(12).enumerated() {
                let word = symbol.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
                let numeric = word.unicodeScalars.contains {
                    CharacterSet.decimalDigits.contains($0) || CharacterSet.whitespaces.contains($0)
                        || $0.properties.isIdeographic
                }
                if numeric {
                    #expect(months[word] == nil, "\(tag) \(word) belongs to the numeric patterns")
                } else {
                    #expect(months[word] == index + 1, "\(tag) \(word)")
                }
            }
        }
    }

    @Test("numeric month symbols are covered by the patterns", arguments: tags)
    func numericMonthSymbolsMatchPatterns(tag: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: tag)
        for (index, symbol) in (calendar.monthSymbols + calendar.shortMonthSymbols).enumerated() {
            let month = index % 12 + 1
            let folded = Self.key(symbol)
            if symbol.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
                let captured = Self.regexCapture(TripQueryVocabulary.NumericPattern.cjkMonth, in: symbol)
                    ?? Self.regexCapture(TripQueryVocabulary.NumericPattern.vietnameseMonth, in: folded)
                #expect(captured.flatMap { Int($0) } == month, "\(tag) \(symbol)")
            } else if symbol.unicodeScalars.contains(where: \.properties.isIdeographic) {
                let numeral = TripQueryVocabulary.hanMonthNumerals.first { symbol.contains($0.word) }
                #expect(numeral?.month == month, "\(tag) \(symbol)")
            }
        }
    }

    @Test("Greek genitive, nominative, accusative and colloquial months")
    func greekMonthForms() {
        let months = TripQueryVocabulary.language("el").months
        #expect(months["Ιουλίου"] == 7)
        #expect(months["Ιούλιος"] == 7)
        #expect(months["Ιούλιο"] == 7)
        #expect(months["Ιούλη"] == 7)
        #expect(months["Μαΐου"] == 5)
        #expect(months["Μάης"] == 5)
        #expect(months["Αύγουστο"] == 8)
        #expect(months["Οχτώβρη"] == 10)
    }

    @Test("Turkish locative months follow vowel harmony")
    func turkishLocativeMonths() {
        let months = TripQueryVocabulary.language("tr").months
        #expect(months["Temmuzda"] == 7)
        #expect(months["Ocakta"] == 1)
        #expect(months["Mayısta"] == 5)
        #expect(months["Eylülde"] == 9)
        #expect(months["Ekimde"] == 10)
        #expect(months["Aralıkta"] == 12)
    }

    @Test("Vietnamese word-numeral months match longest first")
    func vietnameseWordMonths() {
        let months = TripQueryVocabulary.language("vi").months
        #expect(months["tháng bảy"] == 7)
        #expect(months["tháng mười"] == 10)
        #expect(months["tháng mười một"] == 11)
        #expect(months["tháng giêng"] == 1)
        #expect(months.keys.contains { $0.contains(where: \.isNumber) } == false)
    }

    @Test("short month forms are active only for English and the app language")
    func shortFormsStayLocal() {
        let greek = Self.keys(TripQueryVocabulary.active(languageTag: "el").months.keys)
        #expect(!greek.contains("set"))
        #expect(!greek.contains("ago"))
        let italian = Self.keys(TripQueryVocabulary.active(languageTag: "it").months.keys)
        #expect(italian.contains("set"))
        #expect(italian.contains("jan"))
    }

    // MARK: - Numeric patterns

    @Test("CJK and Vietnamese numeric patterns never read 11 or 12 as 1")
    func numericPatterns() {
        typealias Pattern = TripQueryVocabulary.NumericPattern
        #expect(Self.regexCapture(Pattern.cjkYear, in: "2024年1月") == "2024")
        #expect(Self.regexCapture(Pattern.cjkYear, in: "2024 년") == "2024")
        #expect(Self.regexCapture(Pattern.cjkMonth, in: "11月") == "11")
        #expect(Self.regexCapture(Pattern.cjkMonth, in: "2024年1月") == "1")
        #expect(Self.regexCapture(Pattern.cjkMonth, in: "1월에") == "1")
        #expect(Self.regexCapture(Pattern.cjkMonth, in: "12월") == "12")
        #expect(Self.regexCapture(Pattern.vietnameseMonth, in: Self.key("tháng 12")) == "12")
        #expect(Self.regexCapture(Pattern.vietnameseMonth, in: Self.key("thg 1")) == "1")
        #expect(Self.regexCapture(Pattern.vietnameseMonth, in: Self.key("tháng 13")) == nil)
    }

    @Test("Chinese month numerals list every longer numeral before its suffix")
    func hanNumeralsLongestFirst() {
        let numerals = TripQueryVocabulary.hanMonthNumerals
        #expect(Set(numerals.map(\.month)) == Set(1...12))
        for (index, entry) in numerals.enumerated() {
            for later in numerals[(index + 1)...] {
                #expect(!later.word.hasSuffix(entry.word), "\(later.word) must precede \(entry.word)")
            }
        }
        let first = numerals.first { "十一月".hasSuffix($0.word) }
        #expect(first?.month == 11)
    }

    // MARK: - Seasons

    @Test("every language names all four seasons with consistent months", arguments: tags)
    func seasonsCoverYear(tag: String) {
        let language = TripQueryVocabulary.language(tag)
        let sets: [Set<Int>] = [[3, 4, 5], [6, 7, 8], [9, 10, 11], [12, 1, 2]]
        let finals = [5, 8, 11, 2]
        for (months, final) in zip(sets, finals) {
            let words = language.seasons.filter { $0.value == months }.map(\.key)
            let standalone = words.filter { !language.anchorRequiredSeasonWords.contains($0) }
            #expect(!standalone.isEmpty, "\(tag) has no usable word for \(months.sorted())")
            for word in words {
                #expect(language.seasonFinalMonth[word] == final, "\(tag) \(word)")
            }
        }
        #expect(Set(language.seasons.values).isSubset(of: Set(sets)))
    }

    @Test(
        "season words map to their months",
        arguments: [
            ("el", "καλοκαίρι", 6), ("el", "καλοκαιριού", 6), ("el", "καλοκαίρια", 6),
            ("el", "χειμώνα", 12), ("el", "άνοιξη", 3), ("el", "φθινόπωρο", 9),
            ("de", "Sommer", 6), ("de", "Frühling", 3), ("de", "Frühjahr", 3),
            ("de", "Herbst", 9), ("de", "Winter", 12),
            ("fr", "été", 6), ("fr", "printemps", 3), ("it", "estate", 6),
            ("es", "otoño", 9), ("pt-BR", "verão", 6), ("pt-PT", "inverno", 12),
            ("nl", "voorjaar", 3), ("nl", "najaar", 9), ("da", "efteråret", 9),
            ("nb", "høsten", 9), ("sv", "sommaren", 6), ("sv", "somras", 6),
            ("tr", "yaz", 6), ("tr", "kışın", 12), ("vi", "mùa hè", 6),
            ("vi", "mùa đông", 12), ("ja", "夏", 6), ("ja", "冬", 12), ("ko", "여름", 6),
            ("ko", "지난겨울", 12), ("zh-Hans", "夏天", 6), ("zh-Hans", "冬季", 12),
            ("zh-Hant", "春天", 3), ("en", "fall", 9),
        ]
    )
    func seasonWords(tag: String, word: String, firstMonth: Int) {
        let language = TripQueryVocabulary.language(tag)
        let expected: Set<Int> = switch firstMonth {
        case 3: [3, 4, 5]
        case 6: [6, 7, 8]
        case 9: [9, 10, 11]
        default: [12, 1, 2]
        }
        #expect(language.seasons[word] == expected, "\(tag) \(word)")
    }

    @Test("ambiguous season words need an anchor or the mùa form")
    func anchoredSeasonRules() {
        let vietnamese = TripQueryVocabulary.language("vi")
        // `hè` left this list: it names no notable place.
        for bare in ["hạ", "xuân", "thu", "đông"] {
            #expect(vietnamese.seasons[bare] == nil)
        }
        #expect(vietnamese.seasons["hè"] == [6, 7, 8])
        #expect(vietnamese.seasons["nghỉ hè"] == [6, 7, 8])
        // Turkish locative possessives stay anchor-only like `yazı`.
        let turkish = TripQueryVocabulary.language("tr")
        for word in ["yazı", "yazında", "kışında", "baharında", "ilkbaharında", "sonbaharında"] {
            #expect(turkish.anchorRequiredSeasonWords.contains(word), "\(word)")
        }
        #expect(TripQueryVocabulary.language("sv").anchorRequiredSeasonWords.contains("vår"))
        #expect(TripQueryVocabulary.language("nb").anchorRequiredSeasonWords.contains("vår"))
        #expect(!TripQueryVocabulary.language("sv").filler.contains("vår"))
        // `var` ("was") folds to `vår`, so it cannot be filler either.
        #expect(!TripQueryVocabulary.language("sv").ambiguousFunctionWords.contains("var"))
        #expect(TripQueryVocabulary.language("zh-Hans").anchorRequiredSeasonWords == ["春", "夏", "秋", "冬"])
        #expect(TripQueryVocabulary.language("sv").recentSeasonWords == ["våras", "somras", "höstas", "vintras"])
        #expect(TripQueryVocabulary.language("ko").currentSeasonWords.contains("올여름"))
    }

    // MARK: - Collisions

    @Test("no word has two meanings within English plus the app language", arguments: tags)
    func noCollisionsInActiveSet(tag: String) {
        let active = TripQueryVocabulary.active(languageTag: tag)
        var monthByKey: [String: Int] = [:]
        for (word, month) in active.months {
            let key = Self.key(word)
            if let existing = monthByKey[key] {
                #expect(existing == month, "\(tag) \(word) is month \(existing) and \(month)")
            }
            monthByKey[key] = month
        }
        let months = Set(monthByKey.keys)
        var seasonByKey: [String: Set<Int>] = [:]
        for (word, set) in active.seasons {
            let key = Self.key(word)
            if let existing = seasonByKey[key] {
                #expect(existing == set, "\(tag) \(word) names two seasons")
            }
            seasonByKey[key] = set
        }
        let seasons = Set(seasonByKey.keys)
        let weekend = Self.keys(active.weekendWords)
        let filler = Self.keys(active.filler)
        let ambiguous = Self.keys(active.ambiguousFunctionWords)
        #expect(months.isDisjoint(with: seasons), "\(tag) \(months.intersection(seasons))")
        #expect(months.isDisjoint(with: weekend), "\(tag) \(months.intersection(weekend))")
        #expect(seasons.isDisjoint(with: weekend), "\(tag) \(seasons.intersection(weekend))")
        let dateWords = months.union(seasons).union(weekend)
        #expect(filler.isDisjoint(with: dateWords), "\(tag) \(filler.intersection(dateWords))")
        #expect(ambiguous.isDisjoint(with: dateWords), "\(tag) \(ambiguous.intersection(dateWords))")
        #expect(filler.isDisjoint(with: ambiguous), "\(tag) \(filler.intersection(ambiguous))")
    }

    // MARK: - Filler screen

    /// Words that start or complete real place names (Geocoder.sqlite
    /// screen): never unconditional filler in any active set.
    private static let placeWords = [
        "den", "san", "sankt", "la", "el", "le", "les", "los", "las", "al", "do", "da",
        "ha", "lan", "mai", "van", "de", "del", "di", "des", "bei", "para", "una",
        "mon", "ma", "vis", "var", "vi", "ben", "waren", "ile", "tum", "minh", "cua",
        "tai", "o", "bin", "ho",
    ]

    @Test("screened place words are never unconditional filler", arguments: tags)
    func fillerScreen(tag: String) {
        let filler = Self.keys(TripQueryVocabulary.active(languageTag: tag).filler)
        let legacyEnglish = Self.keys(TripQueryVocabulary.language("en").filler)
        for word in Self.placeWords where !legacyEnglish.contains(word) {
            #expect(!filler.contains(word), "\(tag) drops place word \(word)")
        }
    }

    @Test(
        "screened grammatical words move to the place-first set",
        arguments: [
            ("nl", "van"), ("nl", "de"), ("de", "den"), ("es", "la"), ("es", "el"),
            ("fr", "le"), ("it", "al"), ("pt-BR", "do"), ("pt-PT", "da"), ("da", "vis"),
            ("da", "var"),
            ("sv", "vi"), ("tr", "ile"), ("vi", "mình"), ("vi", "đi"), ("ko", "제"),
            ("de", "bin"), ("it", "ho"),
        ]
    )
    func ambiguousFunctionWords(tag: String, word: String) {
        let language = TripQueryVocabulary.language(tag)
        #expect(language.ambiguousFunctionWords.contains(word))
        #expect(!language.filler.contains(word))
    }

    @Test("every language has trip nouns or filler phrases", arguments: tags)
    func tripNounsPresent(tag: String) {
        let language = TripQueryVocabulary.language(tag)
        #expect(!language.tripNouns.isEmpty || !language.fillerPhrases.isEmpty)
    }

    @Test("English keeps the legacy parser vocabulary exactly")
    func englishLegacyParity() {
        let english = TripQueryVocabulary.language("en")
        #expect(english.filler == [
            "trip", "trips", "travel", "travels", "vacation", "vacations",
            "holiday", "holidays", "getaway", "getaways", "journey", "journeys",
            "visit", "visits", "visited", "went", "go", "show", "me", "all",
            "my", "i", "where", "when", "did", "was", "were",
            "in", "to", "the", "a", "an", "of", "on", "at", "from", "with",
            "during", "and", "or",
        ])
        #expect(Set(english.seasons.keys) == ["spring", "summer", "autumn", "fall", "winter"])
        let legacyMonths = [
            "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
            "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
            "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
            "october": 10, "oct": 10, "november": 11, "nov": 11,
            "december": 12, "dec": 12,
        ]
        var englishMonths: [String: Int] = [:]
        for (word, month) in english.months { englishMonths[Self.key(word)] = month }
        #expect(englishMonths == legacyMonths)
        #expect(english.anchorRequiredSeasonWords.isEmpty)
        #expect(english.apostropheSuffixes == ["s"])
    }

    // MARK: - Frames and relative phrases

    @Test("frame templates split around the slot")
    func frameTemplates() {
        #expect(TripQueryVocabulary.Frame("letzten _") == .init(before: "letzten", after: ""))
        #expect(TripQueryVocabulary.Frame("_ dernier") == .init(before: "", after: "dernier"))
        #expect(TripQueryVocabulary.Frame("la _ scorsa") == .init(before: "la", after: "scorsa"))
        #expect(TripQueryVocabulary.Frame("この_") == .init(before: "この", after: ""))
        let french = TripQueryVocabulary.language("fr")
        #expect(french.lastFrames.contains(.init(before: "", after: "dernier")))
        #expect(french.thisFrames.contains(.init(before: "cet", after: "")))
    }

    @Test("Turkish last and this frames also take the `ayında` and `ayı` month suffix")
    func turkishCombinedFrames() {
        let turkish = TripQueryVocabulary.language("tr")
        for before in ["geçen", "geçtiğimiz"] {
            #expect(turkish.lastFrames.contains(.init(before: before, after: "ayında")), "\(before)")
        }
        #expect(turkish.lastFrames.contains(.init(before: "geçen", after: "ayı")))
        #expect(turkish.thisFrames.contains(.init(before: "bu", after: "ayında")))
        #expect(turkish.thisFrames.contains(.init(before: "bu", after: "ayı")))
    }

    @Test("week duration nouns are normalized keys that start a German or Dutch weekend word")
    func weekDurationNounsStartWeekendWords() {
        let weekendKeys = ["de", "nl"].flatMap { Self.keys(TripQueryVocabulary.language($0).weekendWords) }
        for noun in TripQueryVocabulary.weekDurationNouns {
            #expect(Self.key(noun) == noun, "\(noun)")
            #expect(weekendKeys.contains { $0.hasPrefix(noun) && $0 != noun }, "\(noun)")
        }
    }

    @Test("every language has last-year and this-year phrases", arguments: tags)
    func relativeYears(tag: String) {
        let language = TripQueryVocabulary.language(tag)
        #expect(!language.lastYearPhrases.isEmpty)
        #expect(!language.thisYearPhrases.isEmpty)
        #expect(!language.lastMonthPhrases.isEmpty)
        #expect(!language.weekendWords.isEmpty)
    }

    @Test("merged vocabulary keeps English first and adds the app language")
    func mergedVocabulary() {
        let active = TripQueryVocabulary.active(languageTag: "de")
        #expect(active.tags == ["en", "de"])
        #expect(active.months["Mai"] == 5)
        #expect(active.months["May"] == 5)
        #expect(active.weekendWords.isSuperset(of: ["weekend", "Wochenende"]))
        #expect(TripQueryVocabulary.active(languageTag: "en") == TripQueryVocabulary.language("en"))
        #expect(TripQueryVocabulary.active(languageTag: "xx") == TripQueryVocabulary.language("en"))
    }

    // MARK: - Durations

    @Test("English number words cover one to thirty")
    func englishNumbers() {
        let words = TripQueryVocabulary.englishNumberWords
        #expect(Set(words.values) == Set(1...30))
        #expect(words["one"] == 1)
        #expect(words["twelve"] == 12)
        #expect(words["twenty-one"] == 21)
        #expect(words["twenty one"] == 21)
        #expect(words["thirty"] == 30)
        #expect(words["a"] == nil)
        #expect(words["an"] == nil)
        #expect(TripQueryVocabulary.englishDurationUnits["fortnight"] == 14)
    }

    // MARK: - Real normalization

    @Test("the vocabulary covers exactly the app languages")
    func supportedTagsMatchApp() {
        #expect(Set(Self.tags) == AppLanguagePreference.supportedTags)
    }

    /// The parser also matches month and season words by their Latin forms
    /// of 4+ characters (`kalokairi`, `ioulios`); those must not collide with
    /// another role's native word in the same active set.
    @Test("Latin forms of month and season words keep one meaning", arguments: tags)
    func latinFormsDoNotCollide(tag: String) {
        let active = TripQueryVocabulary.active(languageTag: tag)
        func latinForms(_ word: String) -> [String] {
            TripSearch.normalizedSearchForms(word.replacingOccurrences(of: "-", with: " "))
                .dropFirst()
                .filter { $0.count >= 4 }
        }
        let others = Self.keys(active.filler).union(Self.keys(active.ambiguousFunctionWords))
            .union(Self.keys(active.weekendWords))
        var meaning: [String: String] = [:]
        for (word, month) in active.months { meaning[Self.key(word)] = "month \(month)" }
        for (word, months) in active.seasons { meaning[Self.key(word)] = "season \(months.sorted())" }
        for (word, month) in active.months {
            for form in latinForms(word) {
                #expect(!others.contains(form), "\(tag) \(word) → \(form)")
                if let existing = meaning[form] {
                    #expect(existing == "month \(month)", "\(tag) \(word) → \(form) is \(existing)")
                }
            }
        }
        for (word, months) in active.seasons {
            for form in latinForms(word) {
                #expect(!others.contains(form), "\(tag) \(word) → \(form)")
                if let existing = meaning[form] {
                    #expect(existing == "season \(months.sorted())", "\(tag) \(word) → \(form) is \(existing)")
                }
            }
        }
    }

    @Test("folded native forms stay distinct from English words in the active set")
    func greekMonthsFoldDistinctly() {
        let months = Self.keys(TripQueryVocabulary.active(languageTag: "el").months.keys)
        #expect(months.contains(Self.key("Ιουλίου")))
        #expect(months.contains(Self.key("july")))
        #expect(Self.key("Ιουλίου") == "ιουλιου")
    }

    // MARK: - Isolation

    @Test("lookups are nonisolated and agree off the main actor")
    func nonisolatedLookup() async {
        let detached = await Task.detached {
            TripQueryVocabulary.active(languageTag: "el")
        }.value
        #expect(detached == TripQueryVocabulary.active(languageTag: "el"))
    }
}
