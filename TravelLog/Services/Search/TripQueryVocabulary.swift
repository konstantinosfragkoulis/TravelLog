//
//  TripQueryVocabulary.swift
//  TravelLog
//
//  Input vocabulary for `TripQueryParser` in the 18 app languages: month,
//  season, weekend and relative-date words, anchor frames ("last <season>",
//  "l'été dernier"), year bounds and spans ("since 2020", "entre 2019 et
//  2021"), "years ago" and duration comparatives ("plus d'une semaine"),
//  and filler words dropped from place text.
//
//  Month words come from a Gregorian `Calendar` in the language's locale
//  (format and standalone, wide and short), so Greek genitive `Ιουλίου`
//  and nominative `Ιούλιος` both work. Only symbols without digits,
//  whitespace or Han characters become words; `1月`, `7월`, `tháng 7` and
//  `一月` are numeric patterns the parser matches with the regexes below.
//  Everything else is a hand table that needs native review.
//
//  Words are RAW (case, diacritics, apostrophes as typed). The parser
//  prepares vocabulary and query identically: case, diacritic and width
//  folding (after `apostropheSuffixes` are stripped), words split
//  on whitespace, punctuation and symbols (so `l'été` is `l été` and
//  `week-end` is `week end`), each word through
//  `TripSearch.normalizedSearchForms`, Han and kana words split into
//  CFStringTokenizer segments.
//
//  Scope notes (deliberate):
//    - English is always active; `active(languageTag:)` merges it with the
//      app language, and the parser adds the user's other preferred
//      languages and the language of a Greek, Hangul or kana query
//      (`secondary(_:)`). Short month forms are only ever active for
//      English and the app language (they collide across languages:
//      `set`, `out`, `ago`, `mar`, `gen`).
//    - Seasons are northern-hemisphere month sets.
//    - Filler words were screened against `Geocoder.sqlite` place names.
//      Articles and prepositions that start or complete real places (`la`
//      in La Paz, `den` in Den Haag, `da` in Da Nang, `van` is a city) are
//      `ambiguousFunctionWords`, never unconditional filler, and frames
//      spell them out instead ("el _ pasado").
//    - Localized duration grammar covers counts, units and comparatives
//      (`mehr als 3 Tage`, `plus d'une semaine`); number words beyond
//      English stop at ten. Han and Hangul durations are not parsed.
//    - Year bounds keep the bare year's overlap semantics: `since 2020`
//      is every trip touching 2020 or later, `after 2020` starts at 2021,
//      `before 2018` ends at 2017, `until 2018` includes 2018, and a span
//      (`between 2019 and 2021`) includes both ends. Han and Hangul `以`
//      forms (`以降`, `以前`, `以后`, `이후`, `이전`) include the year, as
//      their formal definitions do; `より前`, `之前`, `之后`, `전` do not.
//

import Foundation
import os

nonisolated enum TripQueryVocabulary {

    // MARK: - Public shape

    /// A phrase around a season or month slot: `letzten _`, `_ dernier`,
    /// `la _ scorsa`. The parser matches `before`, the slot word and
    /// `after` as consecutive words; CJK frames (`この_`) need no spaces.
    struct Frame: Sendable, Hashable {
        let before: String
        let after: String

        init(before: String, after: String) {
            self.before = before
            self.after = after
        }

        /// `"letzten _"` → before `letzten`, after empty.
        init(_ template: String) {
            let parts = template.components(separatedBy: TripQueryVocabulary.slot)
            before = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            after = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
    }

    /// A phrase with one or two slots: `il y a _ ans`, `between _ and _`,
    /// `plus d'_`. `parts` are the literal words around the slots.
    struct Pattern: Sendable, Hashable {
        let parts: [String]

        init(_ template: String) {
            parts = template.components(separatedBy: TripQueryVocabulary.slot)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var slotCount: Int { parts.count - 1 }
    }

    /// One language's vocabulary, or English merged with the app language.
    struct Language: Sendable, Equatable {
        /// Source tags, English first when merged.
        var tags: [String]
        /// Month word → month number (1...12). Keys may contain spaces
        /// (Vietnamese `tháng bảy`); match multiword keys longest first.
        var months: [String: Int]
        /// Season word → northern-hemisphere months.
        var seasons: [String: Set<Int>]
        /// Season word → the season's last month, for "last <season>".
        var seasonFinalMonth: [String: Int]
        /// Season words that are too ambiguous to stand alone (Swedish and
        /// Norwegian `vår` is also "our", Chinese `夏` is inside `夏威夷`):
        /// they count only inside a frame, next to a year, or as a
        /// recent/current form.
        var anchorRequiredSeasonWords: Set<String>
        /// Season words that alone mean "last <season>" (Swedish `somras`
        /// in `i somras`, Korean `지난여름`, Japanese `昨夏`).
        var recentSeasonWords: Set<String>
        /// Season words that alone mean "this <season>" (Korean `올여름`).
        var currentSeasonWords: Set<String>
        var weekendWords: Set<String>
        var lastYearPhrases: [String]
        var thisYearPhrases: [String]
        var lastMonthPhrases: [String]
        /// "the year before last": `vorletztes Jahr`, `πρόπερσι`, Chinese
        /// `前年`, Japanese `一昨年` (Japanese `前年` is "the previous year").
        var yearBeforeLastPhrases: [String]
        /// "<count> years ago" over a count slot: `_ years ago`, `vor _
        /// Jahren`, `il y a _ ans`. Han and Hangul forms (`2年前`, `2년 전`)
        /// are `NumericPattern.yearsAgo`.
        var yearsAgo: [Pattern]
        /// Year bounds over a year slot (see the scope notes): the year and
        /// later, later years only, earlier years only, the year and earlier.
        var sinceYear: [Pattern]
        var afterYear: [Pattern]
        var beforeYear: [Pattern]
        var untilYear: [Pattern]
        /// Two year slots, both inclusive: `between _ and _`, `entre _ et _`.
        var yearSpans: [Pattern]
        /// Duration comparatives over a quantity slot (a count and a unit):
        /// strictly longer, strictly shorter, at least, at most.
        var longerThan: [Pattern]
        var shorterThan: [Pattern]
        var atLeast: [Pattern]
        var atMost: [Pattern]
        /// Duration unit words and their length in days (`Woche` 7).
        var durationUnits: [String: Int]
        /// Count words before a unit or in "years ago": articles count one
        /// (`une`, `eine`), then number words to ten. English number words
        /// are `englishNumberWords`.
        var countWords: [String: Int]
        /// "last <season or month>": `letzten _`, `_ dernier`, `_ trước`.
        var lastFrames: [Frame]
        /// "this <season or month>": `diesen _`, `cet _`, `この_`.
        var thisFrames: [Frame]
        /// "in/during <season or month>": `im _`, `en el _`, `τον _`. An
        /// in-frame anchors months without choosing a year.
        var inFrames: [Frame]
        /// Words allowed between a season or month and a year
        /// (`summer of 2024`, `verano de 2024`, `καλοκαίρι του 2024`).
        var yearConnectors: Set<String>
        /// Trip nouns dropped as noise (`Reise`, `ταξίδι`, `旅行`).
        var tripNouns: Set<String>
        /// Trip-length adjectives before a trip noun or weekend word
        /// (`long trips`, `kurze Reise`, `μικρό ταξίδι`) and after one
        /// (Spanish `viaje largo`, `fin de semana largo`): long trips are 8+
        /// days, short ones 3 or fewer, a long weekend 3 to 4.
        var longWords: Set<String>
        var shortWords: Set<String>
        var longWordsAfterNoun: Set<String>
        var shortWordsAfterNoun: Set<String>
        /// Weekend words that alone mean a long weekend (Swedish `långhelg`).
        var longWeekendWords: Set<String>
        /// "or" between places or year bounds (`Paris or Rome`, `πριν το
        /// 2015 ή μετά το 2020`): the parser unions each side's matches.
        /// Also filler. Dutch `of` is left out: it is English "of".
        var disjunctionWords: Set<String>
        /// Words and phrases for a kind of trip (`islands`, `abroad`,
        /// `εσωτερικού`, `yurt dışı`): consumed syntax that keeps the trips
        /// with that `TripSearchFacet`. Next to place text they are tried as
        /// place words first (Rhode Island, International Falls).
        var facetWords: [String: TripSearchFacet]
        /// Prepositions, articles, possessives and query verbs dropped as
        /// noise. Screened against place names.
        var functionWords: Set<String>
        /// Grammatical words the place screen kept OUT of `functionWords`
        /// because they start or complete real place names (`la` in La
        /// Paz, `den` in Den Haag, `van` is a Turkish city, Vietnamese
        /// `đi` in Dĩ An). Treat them like ambiguous date words: the
        /// place reading keeps them as whole-word place text, and only
        /// when that finds nothing may the filler reading drop them.
        var ambiguousFunctionWords: Set<String>
        /// Multiword filler matched as phrases before tokenization,
        /// longest first (`chuyến đi`, `du lịch`, `ne zaman`).
        var fillerPhrases: [String]
        /// Endings written after an apostrophe: Turkish cases (`Roma'da`,
        /// `İzmir'e`) and the English possessive (`Rome's`). The parser
        /// strips `'suffix` before other prep.
        var apostropheSuffixes: Set<String>
        /// Holiday words and phrases (`Christmas`, `Πάσχα`, `Silvester`) and
        /// the holidays they name: a date filter on the holiday's days
        /// (`TripQueryHoliday`). An Easter word names the Easter of the
        /// language's tradition (`easterReadings`).
        var holidayWords: [String: Set<TripQueryHoliday>] = [:]
        /// Ordinals before a trip noun (`first trip`, `letzte Reise`,
        /// `τελευταίο ταξίδι`) and after one (Vietnamese `chuyến đi đầu
        /// tiên`): only the earliest or latest matching trip is kept.
        var firstWords: Set<String> = []
        var lastWords: Set<String> = []
        var firstWordsAfterNoun: Set<String> = []
        var lastWordsAfterNoun: Set<String> = []
        /// "via <place>" (`via Munich`, `layover in`, `μέσω`): the place must
        /// be a transit stop of the trip. `viaWordsAfterPlace` follow the
        /// place (Turkish `Münih üzerinden`, Japanese `ミュンヘン経由`).
        var viaWords: Set<String> = []
        var viaWordsAfterPlace: Set<String> = []

        /// Single-token noise: trip nouns plus function words.
        var filler: Set<String> { tripNouns.union(functionWords) }

        func merged(with other: Language) -> Language {
            var result = self
            result.tags += other.tags.filter { !tags.contains($0) }
            result.months.merge(other.months) { mine, _ in mine }
            result.seasons.merge(other.seasons) { mine, _ in mine }
            result.seasonFinalMonth.merge(other.seasonFinalMonth) { mine, _ in mine }
            result.anchorRequiredSeasonWords.formUnion(other.anchorRequiredSeasonWords)
            result.recentSeasonWords.formUnion(other.recentSeasonWords)
            result.currentSeasonWords.formUnion(other.currentSeasonWords)
            result.weekendWords.formUnion(other.weekendWords)
            result.lastYearPhrases = Self.unique(lastYearPhrases + other.lastYearPhrases)
            result.thisYearPhrases = Self.unique(thisYearPhrases + other.thisYearPhrases)
            result.lastMonthPhrases = Self.unique(lastMonthPhrases + other.lastMonthPhrases)
            result.yearBeforeLastPhrases = Self.unique(yearBeforeLastPhrases + other.yearBeforeLastPhrases)
            result.yearsAgo = Self.unique(yearsAgo + other.yearsAgo)
            result.sinceYear = Self.unique(sinceYear + other.sinceYear)
            result.afterYear = Self.unique(afterYear + other.afterYear)
            result.beforeYear = Self.unique(beforeYear + other.beforeYear)
            result.untilYear = Self.unique(untilYear + other.untilYear)
            result.yearSpans = Self.unique(yearSpans + other.yearSpans)
            result.longerThan = Self.unique(longerThan + other.longerThan)
            result.shorterThan = Self.unique(shorterThan + other.shorterThan)
            result.atLeast = Self.unique(atLeast + other.atLeast)
            result.atMost = Self.unique(atMost + other.atMost)
            result.durationUnits.merge(other.durationUnits) { mine, _ in mine }
            result.countWords.merge(other.countWords) { mine, _ in mine }
            result.lastFrames = Self.unique(lastFrames + other.lastFrames)
            result.thisFrames = Self.unique(thisFrames + other.thisFrames)
            result.inFrames = Self.unique(inFrames + other.inFrames)
            result.yearConnectors.formUnion(other.yearConnectors)
            result.tripNouns.formUnion(other.tripNouns)
            result.longWords.formUnion(other.longWords)
            result.shortWords.formUnion(other.shortWords)
            result.longWordsAfterNoun.formUnion(other.longWordsAfterNoun)
            result.shortWordsAfterNoun.formUnion(other.shortWordsAfterNoun)
            result.longWeekendWords.formUnion(other.longWeekendWords)
            result.disjunctionWords.formUnion(other.disjunctionWords)
            result.facetWords.merge(other.facetWords) { mine, _ in mine }
            result.functionWords.formUnion(other.functionWords)
            result.ambiguousFunctionWords.formUnion(other.ambiguousFunctionWords)
            result.fillerPhrases = Self.unique(fillerPhrases + other.fillerPhrases)
                .sorted { $0.count > $1.count }
            result.apostropheSuffixes.formUnion(other.apostropheSuffixes)
            result.holidayWords.merge(other.holidayWords) { mine, _ in mine }
            result.firstWords.formUnion(other.firstWords)
            result.lastWords.formUnion(other.lastWords)
            result.firstWordsAfterNoun.formUnion(other.firstWordsAfterNoun)
            result.lastWordsAfterNoun.formUnion(other.lastWordsAfterNoun)
            result.viaWords.formUnion(other.viaWords)
            result.viaWordsAfterPlace.formUnion(other.viaWordsAfterPlace)
            return result
        }

        private static func unique<T: Hashable>(_ values: [T]) -> [T] {
            var seen = Set<T>()
            return values.filter { seen.insert($0).inserted }
        }
    }

    /// Every app language, matching `AppLanguagePreference.supportedTags`.
    static let supportedTags: [String] = [
        "da", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nb", "nl",
        "pt-BR", "pt-PT", "sv", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// The slot marker in frame templates.
    static let slot = "_"

    /// One language's vocabulary. Unknown tags return English.
    static func language(_ tag: String) -> Language {
        let key = tables[tag] == nil ? "en" : tag
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let built = build(key)
        cache.withLock { $0[key] = built }
        return built
    }

    /// English merged with the app language: the parser's active set.
    static func active(languageTag: String) -> Language {
        let key = "active:" + languageTag
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let english = language("en")
        let built = languageTag == "en" || tables[languageTag] == nil
            ? english
            : english.merged(with: language(languageTag))
        cache.withLock { $0[key] = built }
        return built
    }

    /// A further query language (`TripQueryParser.queryLanguageTags`: a
    /// preferred language, or the language of the query's script) without
    /// its short month forms, which collide across languages (`mar`, `set`,
    /// `ago`) and so stay with English and the app language.
    static func secondary(_ tag: String) -> Language {
        let key = "secondary:" + tag
        if let cached = cache.withLock({ $0[key] }) { return cached }
        var language = language(tag)
        if tables[tag] != nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: tag)
            func words(_ lists: [[String]]) -> Set<String> {
                Set(lists.flatMap { $0.prefix(12) }.map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
                })
            }
            let wide = words([calendar.monthSymbols, calendar.standaloneMonthSymbols])
            let extras = Set(tables[tag]?.extraMonths.keys.map { $0 } ?? [])
            for word in words([calendar.shortMonthSymbols, calendar.shortStandaloneMonthSymbols])
            where !wide.contains(word) && !extras.contains(word) {
                language.months[word] = nil
            }
        }
        let built = language
        cache.withLock { $0[key] = built }
        return built
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [String: Language]())

    // MARK: - English durations

    /// English number words one to thirty, with hyphenated and spaced
    /// tens (`twenty-one`, `twenty one`). `a` / `an` are deliberately
    /// absent: the grammar handles "a week" explicitly and a bare `a`
    /// must stay filler.
    static let englishNumberWords: [String: Int] = {
        let ones = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = [
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
            "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        var words: [String: Int] = [:]
        for (index, word) in ones.enumerated() { words[word] = index + 1 }
        for (index, word) in teens.enumerated() { words[word] = index + 10 }
        words["twenty"] = 20
        for (index, word) in ones.enumerated() {
            words["twenty-" + word] = 21 + index
            words["twenty " + word] = 21 + index
        }
        words["thirty"] = 30
        return words
    }()

    /// Duration unit words and their length in days (English is always
    /// active; other languages list theirs in `Language.durationUnits`).
    static let englishDurationUnits: [String: Int] = [
        "day": 1, "days": 1, "week": 7, "weeks": 7,
        "fortnight": 14, "fortnights": 14,
    ]

    /// Duration unit words that start an app-language weekend word
    /// (`woche` → wochenende, Dutch `week` → weekend; `weken` starts none).
    /// Like the English units, trailing completion never turns them, or
    /// their prefix after a count, into a weekend.
    static let weekDurationNouns: Set<String> = ["woche", "wochen", "week"]

    /// Articles that count one before a duration unit (`eine woche`,
    /// `een week`, `a week`).
    static let countArticles: Set<String> = ["a", "an", "ein", "eine", "einen", "einer", "een"]

    // MARK: - Numeric month patterns

    /// Chinese month numerals, longest first so `十一月` never reads as
    /// `一月`. Used for zh-Hans (whose calendar symbols are these), and
    /// harmlessly for zh-Hant and ja where they also occur.
    static let hanMonthNumerals: [(word: String, month: Int)] = [
        ("十一月", 11), ("十二月", 12),
        ("一月", 1), ("二月", 2), ("三月", 3), ("四月", 4), ("五月", 5),
        ("六月", 6), ("七月", 7), ("八月", 8), ("九月", 9), ("十月", 10),
    ]

    /// Han numerals one to ten, for `NumericPattern.yearsAgo`.
    static let hanNumerals: [String: Int] = [
        "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// ICU patterns for the numeric date forms Calendar symbols do not
    /// cover as words. Apply after width folding (fullwidth digits) and
    /// before CJK segmentation; no `\b` because CJK has no word breaks.
    enum NumericPattern {
        /// `2024年`, `2024 년`: capture 1 is the year.
        static let cjkYear = "((?:19|20)[0-9]{2})\\s*(?:年|년)"
        /// `7月`, `7 월`: capture 1 is the month; the lookbehind keeps
        /// `11月` from matching as `1月`.
        static let cjkMonth = "(?<![0-9])(1[0-2]|0?[1-9])\\s*(?:月|월)"
        /// `tháng 7`, `thg 7` after diacritic folding: capture 1 is the
        /// month; the lookahead keeps `tháng 1` out of `tháng 12`.
        static let vietnameseMonth = "(?<![\\p{L}])(?:thang|thg)\\s*(1[0-2]|0?[1-9])(?![0-9])"
        /// `2023-2024`, `2023 – 2024`, `2023 to 2024`: captures 1 and 2
        /// are the years (the parser fills spans of at most 10 years).
        static let yearRange =
            "(?<![0-9])((?:19|20)[0-9]{2})(?:\\s*[-–—]\\s*|\\s+(?:to|through|thru|until|till)\\s+)((?:19|20)[0-9]{2})(?![0-9])"
        /// `10+ days`, `2+ weeks`: capture 1 is the count, capture 2 the
        /// unit (`+` is a separator, so this runs before tokenization).
        static let plusDuration = "(?<![0-9])([0-9]+)\\s*\\+\\s*(days?|weeks?|fortnights?)(?![\\p{L}])"
        /// `2年前`, `两年前`, `2년 전`: capture 1 is the count, digits (one or
        /// two, so `2019年前` is no count) or one Han numeral.
        static let yearsAgo = "(?<![0-9])([0-9]{1,2}|[一二两兩三四五六七八九十])\\s*(?:年|년)\\s*(?:前|전)"
    }

    // MARK: - Tables

    private enum Season: CaseIterable {
        case spring, summer, autumn, winter

        var months: Set<Int> {
            switch self {
            case .spring: [3, 4, 5]
            case .summer: [6, 7, 8]
            case .autumn: [9, 10, 11]
            case .winter: [12, 1, 2]
            }
        }

        var finalMonth: Int {
            switch self {
            case .spring: 5
            case .summer: 8
            case .autumn: 11
            case .winter: 2
            }
        }
    }

    private struct Table {
        var seasons: [Season: [String]]
        var anchorRequired: [Season: [String]] = [:]
        var recent: [Season: [String]] = [:]
        var current: [Season: [String]] = [:]
        var weekend: [String]
        var lastYear: [String]
        var thisYear: [String]
        var lastMonth: [String]
        var yearBeforeLast: [String] = []
        var yearsAgo: [String] = []
        var since: [String] = []
        var after: [String] = []
        var before: [String] = []
        var until: [String] = []
        var spans: [String] = []
        var longer: [String] = []
        var shorter: [String] = []
        var atLeast: [String] = []
        var atMost: [String] = []
        var units: [String: Int] = [:]
        var counts: [String: Int] = [:]
        var last: [String] = []
        var this: [String] = []
        var inside: [String] = []
        var yearConnectors: [String] = []
        var tripNouns: [String]
        var long: [String] = []
        var short: [String] = []
        var longAfterNoun: [String] = []
        var shortAfterNoun: [String] = []
        var longWeekend: [String] = []
        var disjunctions: [String] = []
        var facets: [TripSearchFacet: [String]] = [:]
        var functionWords: [String]
        var ambiguousFunctionWords: [String] = []
        var fillerPhrases: [String] = []
        var apostropheSuffixes: [String] = []
        /// Month words Calendar does not produce (colloquial Greek,
        /// Austrian `Jänner`, Vietnamese word numerals, English `sept`).
        var extraMonths: [String: Int] = [:]
    }

    private static func build(_ tag: String) -> Language {
        let table = tables[tag] ?? tables["en"]!
        var seasons: [String: Set<Int>] = [:]
        var finalMonth: [String: Int] = [:]
        func add(_ words: [Season: [String]]) -> Set<String> {
            var added = Set<String>()
            for (season, list) in words {
                for word in list {
                    seasons[word] = season.months
                    finalMonth[word] = season.finalMonth
                    added.insert(word)
                }
            }
            return added
        }
        _ = add(table.seasons)
        let anchorRequired = add(table.anchorRequired)
        let recent = add(table.recent)
        let current = add(table.current)

        var language = Language(
            tags: [tag],
            months: monthWords(tag, extras: table.extraMonths),
            seasons: seasons,
            seasonFinalMonth: finalMonth,
            anchorRequiredSeasonWords: anchorRequired,
            recentSeasonWords: recent,
            currentSeasonWords: current,
            weekendWords: Set(table.weekend + table.longWeekend),
            lastYearPhrases: table.lastYear,
            thisYearPhrases: table.thisYear,
            lastMonthPhrases: table.lastMonth,
            yearBeforeLastPhrases: table.yearBeforeLast,
            yearsAgo: table.yearsAgo.map(Pattern.init),
            sinceYear: table.since.map(Pattern.init),
            afterYear: table.after.map(Pattern.init),
            beforeYear: table.before.map(Pattern.init),
            untilYear: table.until.map(Pattern.init),
            yearSpans: table.spans.map(Pattern.init),
            longerThan: table.longer.map(Pattern.init),
            shorterThan: table.shorter.map(Pattern.init),
            atLeast: table.atLeast.map(Pattern.init),
            atMost: table.atMost.map(Pattern.init),
            durationUnits: table.units,
            countWords: table.counts,
            lastFrames: table.last.map(Frame.init),
            thisFrames: table.this.map(Frame.init),
            inFrames: table.inside.map(Frame.init),
            yearConnectors: Set(table.yearConnectors),
            tripNouns: Set(table.tripNouns),
            longWords: Set(table.long),
            shortWords: Set(table.short),
            longWordsAfterNoun: Set(table.longAfterNoun),
            shortWordsAfterNoun: Set(table.shortAfterNoun),
            longWeekendWords: Set(table.longWeekend),
            disjunctionWords: Set(table.disjunctions),
            facetWords: Dictionary(
                table.facets.flatMap { facet, words in words.map { ($0, facet) } }, uniquingKeysWith: { first, _ in first }),
            functionWords: Set(table.functionWords),
            ambiguousFunctionWords: Set(table.ambiguousFunctionWords),
            fillerPhrases: table.fillerPhrases.sorted { $0.count > $1.count },
            apostropheSuffixes: Set(table.apostropheSuffixes)
        )
        addSearchWords(tag, to: &language)
        return language
    }

    /// Calendar month symbols usable as words, plus derived inflections
    /// (Greek accusative, Turkish locative) and the table's extras.
    private static func monthWords(_ tag: String, extras: [String: Int]) -> [String: Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: tag)
        var words: [String: Int] = [:]
        let lists = [
            calendar.monthSymbols, calendar.standaloneMonthSymbols,
            calendar.shortMonthSymbols, calendar.shortStandaloneMonthSymbols,
        ]
        for list in lists {
            for (index, symbol) in list.enumerated() where index < 12 {
                let word = symbol.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
                guard isLexicalMonthWord(word), words[word] == nil else { continue }
                words[word] = index + 1
            }
        }
        if tag == "el" {
            // Accusative (`τον Ιούλιο`): the standalone nominative without
            // its final sigma.
            for (index, symbol) in calendar.standaloneMonthSymbols.enumerated()
            where index < 12 && symbol.hasSuffix("ος") {
                words[String(symbol.dropLast()), default: index + 1] = index + 1
            }
        }
        if tag == "tr" {
            for (index, symbol) in calendar.monthSymbols.enumerated() where index < 12 {
                words[turkishLocative(symbol), default: index + 1] = index + 1
            }
        }
        for (word, month) in extras where words[word] == nil { words[word] = month }
        return words
    }

    private static func isLexicalMonthWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return !word.unicodeScalars.contains { scalar in
            CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || scalar.properties.isIdeographic
        }
    }

    /// `Temmuz` → `Temmuzda`, `Ocak` → `Ocakta`, `Eylül` → `Eylülde`:
    /// vowel harmony on the last vowel, consonant assimilation after a
    /// voiceless final.
    private static func turkishLocative(_ word: String) -> String {
        let lower = word.lowercased(with: Locale(identifier: "tr"))
        let back: Set<Character> = ["a", "ı", "o", "u"]
        let front: Set<Character> = ["e", "i", "ö", "ü"]
        let lastVowel = lower.last { back.contains($0) || front.contains($0) }
        let vowel = (lastVowel.map { back.contains($0) } ?? true) ? "a" : "e"
        let voiceless: Set<Character> = ["f", "s", "t", "k", "ç", "ş", "h", "p"]
        let consonant = (lower.last.map { voiceless.contains($0) } ?? false) ? "t" : "d"
        return word + consonant + vowel
    }

    // Native review needed for every table below.
    private static let tables: [String: Table] = [
        "en": Table(
            seasons: [
                .spring: ["spring"], .summer: ["summer"],
                .autumn: ["autumn", "fall"], .winter: ["winter"],
            ],
            weekend: ["weekend", "weekends"],
            lastYear: ["last year"],
            thisYear: ["this year"],
            lastMonth: ["last month"],
            yearBeforeLast: ["the year before last", "year before last"],
            yearsAgo: ["_ years ago", "_ year ago"],
            since: ["since _", "from _ on", "from _ onwards", "from _ onward", "_ onwards", "_ onward", "_ and later", "_ or later"],
            after: ["after _"],
            before: ["before _", "prior to _"],
            until: ["until _", "till _", "through _", "_ and earlier", "_ or earlier"],
            spans: ["between _ and _", "from _ until _", "from _ through _"],
            longer: ["longer than _", "more than _", "over _"],
            shorter: ["shorter than _", "less than _", "fewer than _", "under _"],
            atLeast: ["at least _", "_ or more", "_ or longer"],
            atMost: ["at most _", "up to _", "_ or less", "_ or fewer", "_ or shorter"],
            last: ["last _"],
            this: ["this _"],
            inside: ["in _", "during _"],
            yearConnectors: ["of"],
            tripNouns: [
                "trip", "trips", "travel", "travels", "vacation", "vacations",
                "holiday", "holidays", "getaway", "getaways", "journey", "journeys",
                "visit", "visits",
            ],
            long: ["long"],
            short: ["short"],
            disjunctions: ["or"],
            facets: [
                .island: ["island", "islands", "isle", "isles"],
                .abroad: ["abroad", "overseas", "international", "foreign"],
                .domestic: ["domestic"],
            ],
            functionWords: [
                "visited", "went", "go", "show", "me", "all",
                "my", "i", "where", "when", "did", "was", "were",
                "in", "to", "the", "a", "an", "of", "on", "at", "from", "with",
                "during", "and", "or",
            ],
            apostropheSuffixes: ["s"],
            extraMonths: ["sept": 9]
        ),
        "da": Table(
            seasons: [
                .spring: ["forår", "foråret"], .summer: ["sommer", "sommeren"],
                .autumn: ["efterår", "efteråret"], .winter: ["vinter", "vinteren"],
            ],
            // `i sommers`, `i vinters`: last summer, last winter.
            recent: [.summer: ["sommers"], .winter: ["vinters"]],
            weekend: ["weekend", "weekenden", "weekender"],
            lastYear: ["sidste år", "forrige år", "i fjor"],
            thisYear: ["i år", "dette år"],
            lastMonth: ["sidste måned", "forrige måned"],
            yearsAgo: ["for _ år siden"],
            since: ["siden _", "fra _"],
            after: ["efter _"],
            before: ["før _", "inden _"],
            until: ["indtil _", "til og med _"],
            spans: ["mellem _ og _", "fra _ til _", "_ til _"],
            longer: ["længere end _", "mere end _", "over _"],
            shorter: ["kortere end _", "mindre end _", "under _"],
            atLeast: ["mindst _", "_ eller mere", "_ eller længere"],
            atMost: ["højst _", "max _", "_ eller mindre", "_ eller kortere"],
            units: ["dag": 1, "dage": 1, "dages": 1, "døgn": 1, "uge": 7, "uger": 7, "ugers": 7],
            counts: [
                "en": 1, "et": 1, "to": 2, "tre": 3, "fire": 4, "fem": 5, "seks": 6,
                "syv": 7, "otte": 8, "ni": 9, "ti": 10,
            ],
            last: ["sidste _", "forrige _"],
            this: ["denne _", "dette _"],
            inside: ["i _", "om _", "i løbet af _"],
            tripNouns: [
                "rejse", "rejser", "rejsen", "ferie", "ferier", "ferien", "ferietur",
                "tur", "ture", "turen", "udflugt", "udflugter", "besøg", "miniferie",
                "storbyferie",
            ],
            long: ["lang", "lange"],
            short: ["kort", "korte"],
            disjunctions: ["eller"],
            facets: [
                .abroad: ["udlandet", "udlandsrejse", "udlandsrejser"],
                .domestic: ["indenrigs"],
            ],
            functionWords: [
                "til", "i", "på", "fra", "med", "og", "eller", "det", "en", "et",
                "min", "mit", "mine", "vores", "alle", "mig", "hvor", "hvornår",
                "jeg", "har", "været", "besøgte", "under",
            ],
            ambiguousFunctionWords: ["den", "de", "vi", "vis", "var"]
        ),
        "de": Table(
            seasons: [
                .spring: ["Frühling", "Frühjahr"], .summer: ["Sommer"],
                .autumn: ["Herbst"], .winter: ["Winter"],
            ],
            weekend: ["Wochenende", "Wochenenden"],
            lastYear: [
                "letztes Jahr", "letzten Jahr", "letzten Jahres", "vergangenes Jahr",
                "vergangenen Jahr", "vergangenen Jahres", "voriges Jahr", "vorigen Jahr",
                "vorigen Jahres", "Vorjahr",
            ],
            thisYear: ["dieses Jahr", "diesem Jahr", "dieses Jahres", "diesen Jahres", "heuer"],
            lastMonth: ["letzten Monat", "letzter Monat", "vergangenen Monat", "vorigen Monat", "Vormonat"],
            yearBeforeLast: ["vorletztes Jahr", "vorletzten Jahr", "vorletzten Jahres"],
            yearsAgo: ["vor _ Jahren", "vor _ Jahr"],
            since: ["seit _", "ab _"],
            after: ["nach _"],
            before: ["vor _"],
            until: ["bis _"],
            spans: ["zwischen _ und _", "von _ bis _", "_ bis _"],
            longer: ["länger als _", "mehr als _", "über _"],
            shorter: ["kürzer als _", "weniger als _", "unter _"],
            atLeast: ["mindestens _", "_ oder mehr", "_ oder länger"],
            atMost: ["höchstens _", "maximal _", "bis zu _", "_ oder weniger", "_ oder kürzer"],
            units: ["Tag": 1, "Tage": 1, "Tagen": 1, "Woche": 7, "Wochen": 7],
            counts: [
                "ein": 1, "eine": 1, "einen": 1, "einer": 1, "einem": 1, "zwei": 2,
                "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8,
                "neun": 9, "zehn": 10,
            ],
            last: [
                "letzten _", "letzter _", "letztes _", "letzte _",
                "vergangenen _", "vergangener _", "vergangenes _",
                "vorigen _", "voriger _", "voriges _",
            ],
            this: ["diesen _", "dieser _", "dieses _", "diese _"],
            inside: ["im _", "in _"],
            tripNouns: [
                "Reise", "Reisen", "Urlaub", "Urlaube", "Urlaubs", "Ferien", "Ausflug",
                "Ausflüge", "Kurztrip", "Städtereise", "Städtetrip", "Rundreise",
                "Besuch", "Besuche",
            ],
            long: ["lang", "lange", "langer", "langen", "langes"],
            short: ["kurz", "kurze", "kurzer", "kurzen", "kurzes"],
            disjunctions: ["oder"],
            facets: [
                .island: ["Insel", "Inseln"],
                .abroad: ["Ausland", "Auslandsreise", "Auslandsreisen"],
                .domestic: ["Inland", "Inlandsreise", "Inlandsreisen"],
            ],
            functionWords: [
                "nach", "in", "im", "ins", "zu", "zum", "zur", "am", "auf", "aus",
                "von", "vom", "mit", "und", "oder", "der", "die", "das", "dem", "ein",
                "eine", "einen",
                "einem", "einer", "mein", "meine", "meinen", "meinem", "meiner",
                "unser", "unsere", "unseren", "unserem", "alle", "zeig", "zeige",
                "mir", "wo", "wann", "ich", "wir", "war", "gewesen", "besucht",
                "während", "wohin", "gereist", "gefahren", "geflogen", "welche",
            ],
            // `bin` is a whole word of Qasr Bin Ghashir and Bin Xian.
            ambiguousFunctionWords: ["den", "des", "bei", "waren", "bin"],
            extraMonths: ["Jänner": 1]
        ),
        "el": Table(
            seasons: [
                .spring: ["άνοιξη", "άνοιξης"],
                .summer: ["καλοκαίρι", "καλοκαιριού", "καλοκαίρια"],
                .autumn: ["φθινόπωρο", "φθινοπώρου", "φθινόπωρα"],
                .winter: ["χειμώνας", "χειμώνα", "χειμώνες"],
            ],
            weekend: ["Σαββατοκύριακο", "Σαββατοκύριακα", "Σαββατοκύριακου", "ΣΚ", "Σ/Κ"],
            lastYear: [
                "πέρσι", "πέρυσι", "περσινό", "περσινή", "περσινού", "περσινής",
                "περσινά", "τον περασμένο χρόνο", "την περασμένη χρονιά",
            ],
            thisYear: [
                "φέτος", "εφέτος", "φετινό", "φετινή", "φετινού", "φετινής", "φετινά",
                "αυτή τη χρονιά", "αυτή την χρονιά",
            ],
            lastMonth: ["τον περασμένο μήνα", "τον προηγούμενο μήνα", "περασμένο μήνα"],
            yearBeforeLast: ["πρόπερσι", "πρόπερυσι"],
            yearsAgo: [
                "πριν _ χρόνια", "πριν από _ χρόνια", "πριν _ χρόνο", "πριν από _ χρόνο",
                "_ χρόνια πριν", "πριν _ έτη",
            ],
            since: ["από το _", "από _"],
            after: ["μετά το _", "μετά από το _"],
            before: ["πριν το _", "πριν από το _", "πριν _"],
            until: ["μέχρι το _", "έως το _", "ως το _"],
            spans: [
                "από το _ έως το _", "από το _ μέχρι το _", "από το _ ως το _",
                "μεταξύ _ και _", "μεταξύ του _ και του _", "_ έως _",
            ],
            longer: [
                "πάνω από _", "περισσότερο από _", "περισσότερες από _",
                "μεγαλύτερα από _", "μεγαλύτερο από _",
            ],
            shorter: ["κάτω από _", "λιγότερο από _", "λιγότερες από _", "μικρότερα από _"],
            atLeast: ["τουλάχιστον _"],
            atMost: ["το πολύ _", "έως _", "μέχρι _"],
            units: [
                "μέρα": 1, "μέρες": 1, "μερών": 1, "ημέρα": 1, "ημέρες": 1, "ημερών": 1,
                "εβδομάδα": 7, "εβδομάδες": 7, "εβδομάδας": 7, "εβδομάδων": 7,
                "βδομάδα": 7, "βδομάδες": 7,
            ],
            counts: [
                "ένα": 1, "έναν": 1, "μία": 1, "μια": 1, "δύο": 2, "τρία": 3, "τρεις": 3,
                "τέσσερα": 4, "τέσσερις": 4, "πέντε": 5, "έξι": 6, "επτά": 7, "εφτά": 7,
                "οκτώ": 8, "οχτώ": 8, "εννέα": 9, "εννιά": 9, "δέκα": 10,
            ],
            last: [
                "το περασμένο _", "την περασμένη _", "τον περασμένο _",
                "περασμένο _", "περασμένη _",
                "το προηγούμενο _", "την προηγούμενη _", "τον προηγούμενο _",
                "προηγούμενο _", "προηγούμενη _",
            ],
            this: ["αυτό το _", "αυτή την _", "αυτή τη _", "αυτόν τον _", "αυτό τον _"],
            inside: ["το _", "την _", "τη _", "τον _"],
            yearConnectors: ["του"],
            tripNouns: [
                "ταξίδι", "ταξίδια", "ταξιδιού", "ταξιδιών", "διακοπές", "διακοπών",
                "εκδρομή", "εκδρομές", "εκδρομής", "επίσκεψη", "επισκέψεις",
                "απόδραση", "αποδράσεις", "τριήμερο", "τετραήμερο", "ταξιδάκι",
            ],
            long: ["μεγάλο", "μεγάλα", "μεγάλη", "μεγάλες", "μεγάλου", "μεγάλων"],
            short: [
                "σύντομο", "σύντομα", "σύντομη", "σύντομες", "μικρό", "μικρά", "μικρή", "μικρές",
            ],
            disjunctions: ["ή"],
            facets: [
                .island: ["νησί", "νησιά", "νησιού", "νησιών"],
                .abroad: ["εξωτερικό", "εξωτερικού"],
                .domestic: ["εσωτερικό", "εσωτερικού"],
            ],
            functionWords: [
                "μου", "μας", "το", "τα", "τη", "την", "τον", "του", "της", "των",
                "ο", "η", "οι", "τις", "τους", "στο", "στη", "στην", "στον", "στα",
                "στις", "στους", "σε", "για", "από", "με", "και", "ή", "όλα", "όλες",
                "όλοι", "δείξε", "δείξτε", "πού", "πότε", "πήγα", "πήγαμε",
                "ταξίδεψα", "ταξιδέψαμε", "προς", "ήμουν", "ήμασταν", "έχω", "έχουμε",
                "πάει", "βρέθηκα", "βρεθήκαμε",
            ],
            extraMonths: [
                // Colloquial nominative and accusative/genitive forms.
                "Γενάρης": 1, "Γενάρη": 1, "Φλεβάρης": 2, "Φλεβάρη": 2,
                "Μάρτης": 3, "Μάρτη": 3, "Απρίλης": 4, "Απρίλη": 4,
                "Μάης": 5, "Μάη": 5, "Ιούνης": 6, "Ιούνη": 6, "Ιούλης": 7, "Ιούλη": 7,
                "Σεπτέμβρης": 9, "Σεπτέμβρη": 9,
                "Οκτώβρης": 10, "Οκτώβρη": 10, "Οχτώβρης": 10, "Οχτώβρη": 10,
                "Νοέμβρης": 11, "Νοέμβρη": 11, "Δεκέμβρης": 12, "Δεκέμβρη": 12,
            ]
        ),
        "es": Table(
            seasons: [
                .spring: ["primavera"], .summer: ["verano"],
                .autumn: ["otoño"], .winter: ["invierno"],
            ],
            weekend: ["fin de semana", "fines de semana", "finde"],
            lastYear: ["el año pasado", "año pasado", "el pasado año"],
            thisYear: ["este año"],
            lastMonth: ["el mes pasado", "mes pasado"],
            yearBeforeLast: ["el año antepasado", "año antepasado"],
            yearsAgo: ["hace _ años", "hace _ año"],
            since: ["desde _", "desde el _", "a partir de _", "a partir del _"],
            after: ["después de _", "después del _"],
            before: ["antes de _", "antes del _"],
            until: ["hasta _", "hasta el _"],
            spans: ["entre _ y _", "de _ a _", "del _ al _", "desde _ hasta _", "_ a _"],
            longer: ["más de _", "más largo que _", "más largos que _"],
            shorter: ["menos de _", "más corto que _", "más cortos que _"],
            atLeast: ["al menos _", "por lo menos _", "como mínimo _", "_ o más"],
            atMost: ["como máximo _", "hasta _", "_ o menos"],
            units: ["día": 1, "días": 1, "semana": 7, "semanas": 7],
            counts: [
                "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
                "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
            ],
            last: [
                "_ pasado", "_ pasada", "el _ pasado", "la _ pasada",
                "el pasado _", "la pasada _",
            ],
            this: ["este _", "esta _"],
            inside: [
                "en _", "en el _", "en la _", "de _", "durante el _", "durante la _",
                "durante _", "en el mes de _",
            ],
            yearConnectors: ["de", "del"],
            tripNouns: [
                "viaje", "viajes", "vacaciones", "escapada", "escapadas",
                "excursión", "excursiones", "visita", "visitas",
            ],
            longAfterNoun: ["largo", "larga", "largos", "largas"],
            shortAfterNoun: ["corto", "corta", "cortos", "cortas"],
            disjunctions: ["o", "u"],
            facets: [
                .island: ["isla", "islas"],
                .abroad: ["extranjero"],
                .domestic: ["nacionales"],
            ],
            functionWords: [
                "a", "en", "hacia", "por", "un", "unos", "unas",
                "y", "e", "mi", "mis", "nuestro", "nuestra", "nuestros",
                "nuestras", "todos", "todas", "muestra", "muéstrame", "dónde",
                "cuándo", "durante", "fui", "fuimos", "estuve", "estuvimos",
                "visité", "visitamos", "he", "hemos", "estado", "ido",
            ],
            ambiguousFunctionWords: [
                "el", "la", "los", "las", "lo", "de", "del", "al", "o", "u", "una",
                "para", "con",
            ]
        ),
        "fr": Table(
            seasons: [
                .spring: ["printemps"], .summer: ["été"],
                .autumn: ["automne"], .winter: ["hiver"],
            ],
            weekend: ["week-end", "week-ends", "fin de semaine"],
            lastYear: ["l'année dernière", "l'an dernier", "l'année passée", "l'an passé"],
            thisYear: ["cette année"],
            lastMonth: ["le mois dernier", "le mois passé"],
            yearsAgo: ["il y a _ ans", "il y a _ an"],
            since: ["depuis _", "à partir de _", "dès _"],
            after: ["après _"],
            before: ["avant _"],
            until: ["jusqu'en _", "jusqu'à _"],
            spans: ["entre _ et _", "de _ à _", "_ à _"],
            longer: ["plus de _", "plus d'_", "plus long que _", "plus longs que _"],
            shorter: ["moins de _", "moins d'_", "plus court que _", "plus courts que _"],
            atLeast: ["au moins _", "_ ou plus"],
            atMost: ["au plus _", "au maximum _", "jusqu'à _", "_ ou moins"],
            units: ["jour": 1, "jours": 1, "semaine": 7, "semaines": 7],
            counts: [
                "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6,
                "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
            ],
            last: ["_ dernier", "_ passé", "le _ dernier", "le _ passé"],
            this: ["cet _", "ce _"],
            inside: [
                "en _", "au _", "de _", "d'_", "pendant l'_", "pendant le _", "durant l'_",
                "durant le _", "au mois de _", "au mois d'_",
            ],
            tripNouns: [
                "voyage", "voyages", "vacances", "séjour", "séjours", "excursion",
                "excursions", "escapade", "escapades", "périple", "visite", "visites",
            ],
            long: ["long", "longue", "longs", "longues"],
            short: ["court", "courte", "courts", "courtes"],
            disjunctions: ["ou"],
            facets: [
                .island: ["île", "îles"],
                .abroad: ["étranger"],
            ],
            functionWords: [
                // `l`, `d`, `j`, `qu` are elision residues (`l'été` → `l été`).
                "l", "d", "j", "qu",
                "à", "au", "aux", "dans", "pour", "vers", "chez", "un", "une", "et",
                "ce", "mes", "notre", "nos", "tous", "toutes", "montre", "moi", "où",
                "quand", "je", "ai", "nous", "avons", "suis", "sommes", "allé",
                "allée", "allés", "allées", "visité", "avec", "pendant", "en",
            ],
            ambiguousFunctionWords: ["de", "du", "des", "le", "la", "les", "mon", "ma", "durant"],
            // `j'ai été à Rome` is "I have been to Rome", not summer.
            fillerPhrases: ["ai été", "as été", "a été", "avons été", "avez été", "ont été"]
        ),
        "it": Table(
            seasons: [
                .spring: ["primavera"], .summer: ["estate"],
                .autumn: ["autunno"], .winter: ["inverno"],
            ],
            weekend: ["fine settimana", "finesettimana", "weekend", "week-end"],
            lastYear: ["l'anno scorso", "anno scorso", "l'anno passato", "lo scorso anno"],
            thisYear: ["quest'anno", "questo anno"],
            lastMonth: ["il mese scorso", "mese scorso", "lo scorso mese"],
            yearsAgo: ["_ anni fa", "_ anno fa"],
            since: ["dal _", "a partire dal _"],
            after: ["dopo il _", "dopo _"],
            before: ["prima del _", "prima _"],
            until: ["fino al _"],
            spans: ["tra il _ e il _", "fra il _ e il _", "tra _ e _", "fra _ e _", "dal _ al _"],
            longer: ["più di _", "oltre _", "più lunghi di _", "più lungo di _"],
            shorter: ["meno di _", "più corti di _", "più corto di _"],
            atLeast: ["almeno _", "_ o più"],
            atMost: ["al massimo _", "fino a _", "_ o meno"],
            units: ["giorno": 1, "giorni": 1, "settimana": 7, "settimane": 7],
            counts: [
                "un": 1, "una": 1, "uno": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5,
                "sei": 6, "sette": 7, "otto": 8, "nove": 9, "dieci": 10,
            ],
            last: [
                "_ scorso", "_ scorsa", "_ passato", "_ passata",
                "il _ scorso", "la _ scorsa", "il _ passato", "la _ passata",
                "lo scorso _", "la scorsa _", "scorso _", "scorsa _",
            ],
            this: ["quest'_", "questa _", "questo _"],
            inside: [
                "in _", "d'_", "di _", "a _", "nell'_", "durante l'_",
                "durante la _", "durante il _", "nel mese di _",
            ],
            yearConnectors: ["del"],
            tripNouns: [
                "viaggio", "viaggi", "vacanza", "vacanze", "gita", "gite",
                "soggiorno", "soggiorni", "escursione", "escursioni", "visita", "visite",
            ],
            long: ["lungo", "lunga", "lunghi", "lunghe"],
            short: ["breve", "brevi"],
            longAfterNoun: ["lungo", "lunga", "lunghi", "lunghe"],
            shortAfterNoun: ["breve", "brevi", "corto", "corta", "corti", "corte"],
            disjunctions: ["o", "oppure"],
            facets: [
                .island: ["isola", "isole"],
                .abroad: ["estero"],
            ],
            functionWords: [
                // `l`, `d`, `dell`, `nell`, `dall`, `sull` are elision residues.
                "l", "d", "dell", "nell", "dall", "sull",
                "allo", "alla", "ai", "agli", "alle", "nello", "nella",
                "nei", "negli", "nelle", "per", "dallo", "dalla", "dagli",
                "dalle", "dello", "della", "degli", "delle", "gli", "un", "uno",
                "e", "ed", "mio", "mia", "miei", "nostro", "nostra",
                "nostri", "nostre", "tutti", "tutte", "mostra", "mostrami", "mi",
                "dove", "quando", "durante", "sono", "siamo", "stato", "stata",
                "stati", "andato", "andata", "andati", "visitato", "visitata",
                "abbiamo", "fatto",
            ],
            // `ho` ("I have") is Ho (Ghana) and starts Ho Chi Minh City.
            ambiguousFunctionWords: [
                "il", "lo", "la", "le", "al", "ad", "da", "dal", "dai", "di", "del",
                "con", "una", "mie", "o", "ho",
            ]
        ),
        "ja": Table(
            seasons: [
                .spring: ["春", "春季", "春休み"], .summer: ["夏", "夏季", "夏休み"],
                .autumn: ["秋", "秋季"], .winter: ["冬", "冬季", "冬休み"],
            ],
            recent: [.spring: ["昨春"], .summer: ["昨夏"], .autumn: ["昨秋"], .winter: ["昨冬"]],
            current: [.spring: ["今春"], .summer: ["今夏"], .autumn: ["今秋"], .winter: ["今冬"]],
            weekend: ["週末", "土日"],
            lastYear: ["去年", "昨年", "前年"],
            thisYear: ["今年"],
            lastMonth: ["先月"],
            // Japanese `前年` is "the previous year": from today, last year.
            yearBeforeLast: ["一昨年", "おととし"],
            since: ["_以降", "_から", "_以来"],
            after: ["_より後", "_よりあと"],
            before: ["_より前", "_よりまえ"],
            until: ["_以前", "_まで"],
            spans: ["_から_まで", "_から_"],
            this: ["この_"],
            tripNouns: [
                "旅行", "旅", "旅程", "観光", "休暇", "休み", "バケーション",
                "ツアー", "トリップ", "出張",
            ],
            disjunctions: ["または"],
            facets: [
                .abroad: ["海外"],
                .domestic: ["国内"],
            ],
            functionWords: [
                "の", "と", "へ", "に", "で", "を", "は", "が", "も", "から", "まで",
                "私", "私の", "僕", "僕の", "全部", "すべて", "全て", "見せて",
                "行った", "訪問",
            ]
        ),
        "ko": Table(
            seasons: [
                .spring: ["봄", "봄에", "봄철", "봄여행"],
                .summer: ["여름", "여름에", "여름철", "여름휴가", "여름여행"],
                .autumn: ["가을", "가을에", "가을철", "가을여행"],
                .winter: ["겨울", "겨울에", "겨울철", "겨울휴가", "겨울여행"],
            ],
            recent: [.spring: ["지난봄"], .summer: ["지난여름"], .autumn: ["지난가을"], .winter: ["지난겨울"]],
            current: [.spring: ["올봄"], .summer: ["올여름"], .autumn: ["올가을"], .winter: ["올겨울"]],
            weekend: ["주말", "주말에", "주말여행"],
            lastYear: ["작년", "지난해", "지난 해", "작년에", "지난해에"],
            thisYear: ["올해", "금년", "올해에"],
            lastMonth: ["지난달", "지난 달", "지난달에"],
            yearBeforeLast: ["재작년", "지지난해", "재작년에"],
            since: ["_ 이후", "_부터", "_ 이후로"],
            after: ["_ 후", "_ 이후에"],
            before: ["_ 전", "_ 이전에"],
            until: ["_ 이전", "_까지"],
            spans: ["_부터 _까지"],
            last: ["지난 _"],
            this: ["이번 _", "올 _"],
            tripNouns: ["여행", "여행지", "휴가", "방문", "투어", "트립", "출장"],
            disjunctions: ["또는"],
            facets: [
                .island: ["섬"],
                .abroad: ["해외"],
                .domestic: ["국내"],
            ],
            functionWords: [
                "에", "에서", "로", "으로", "의", "와", "과", "및", "나의", "우리",
                "우리의", "모든", "전체", "보여줘", "동안", "갔던", "다녀온",
            ],
            // `제` and `내` ("my") start 제주 and 내장산.
            ambiguousFunctionWords: ["제", "내"]
        ),
        "nb": Table(
            seasons: [
                .spring: ["våren"], .summer: ["sommer", "sommeren"],
                .autumn: ["høst", "høsten"], .winter: ["vinter", "vinteren"],
            ],
            anchorRequired: [.spring: ["vår"]],
            weekend: ["helg", "helgen", "helga", "helger", "weekend", "weekenden", "langhelg", "langhelgen"],
            lastYear: ["i fjor", "forrige år"],
            thisYear: ["i år", "dette året", "dette år"],
            lastMonth: ["forrige måned", "sist måned"],
            yearBeforeLast: ["i forfjor", "forfjor"],
            yearsAgo: ["for _ år siden"],
            since: ["siden _", "fra _"],
            after: ["etter _"],
            before: ["før _"],
            until: ["til og med _", "frem til _"],
            spans: ["mellom _ og _", "fra _ til _", "_ til _"],
            longer: ["lengre enn _", "mer enn _", "over _"],
            shorter: ["kortere enn _", "mindre enn _", "under _"],
            atLeast: ["minst _", "_ eller mer", "_ eller lengre"],
            atMost: ["høyst _", "maks _", "_ eller mindre", "_ eller kortere"],
            units: ["dag": 1, "dager": 1, "døgn": 1, "uke": 7, "uker": 7],
            counts: [
                "en": 1, "ei": 1, "ett": 1, "to": 2, "tre": 3, "fire": 4, "fem": 5,
                "seks": 6, "sju": 7, "syv": 7, "åtte": 8, "ni": 9, "ti": 10,
            ],
            last: ["forrige _", "sist _"],
            this: ["denne _", "dette _"],
            inside: ["i _", "om _", "i løpet av _"],
            tripNouns: [
                "reise", "reiser", "reisen", "ferie", "ferier", "ferien", "ferietur",
                "tur", "turer", "turen", "utflukt", "utflukter", "besøk", "miniferie",
                "storbyferie",
            ],
            long: ["lang", "lange"],
            short: ["kort", "korte"],
            longWeekend: ["langhelg", "langhelgen"],
            disjunctions: ["eller"],
            facets: [
                .abroad: ["utlandet", "utenlands"],
                .domestic: ["innenlands"],
            ],
            functionWords: [
                "til", "i", "på", "fra", "med", "og", "eller", "det", "en", "et",
                "ei", "min", "mitt", "mi", "mine", "vårt", "våre", "alle", "meg",
                "hvor", "når", "jeg", "har", "vært", "besøkte", "under",
            ],
            // `var` ("was") folds to `vår`, which is already anchor-only.
            ambiguousFunctionWords: ["den", "de", "vi", "vis"]
        ),
        "nl": Table(
            seasons: [
                .spring: ["lente", "voorjaar"], .summer: ["zomer"],
                .autumn: ["herfst", "najaar"], .winter: ["winter"],
            ],
            weekend: ["weekend", "weekendje", "weekenden", "weekendjes", "weekendje weg", "weekend weg"],
            lastYear: ["vorig jaar", "verleden jaar", "afgelopen jaar", "het afgelopen jaar"],
            thisYear: ["dit jaar"],
            lastMonth: ["vorige maand", "afgelopen maand", "verleden maand"],
            yearBeforeLast: ["eervorig jaar"],
            yearsAgo: ["_ jaar geleden"],
            since: ["sinds _", "vanaf _"],
            after: ["na _"],
            before: ["voor _"],
            until: ["tot en met _", "t/m _"],
            spans: ["tussen _ en _", "van _ tot _", "van _ tot en met _", "_ tot _"],
            longer: ["langer dan _", "meer dan _"],
            shorter: ["korter dan _", "minder dan _"],
            atLeast: ["minstens _", "ten minste _", "_ of meer", "_ of langer"],
            atMost: ["hoogstens _", "maximaal _", "_ of minder", "_ of korter"],
            units: ["dag": 1, "dagen": 1, "week": 7, "weken": 7],
            counts: [
                "een": 1, "één": 1, "twee": 2, "drie": 3, "vier": 4, "vijf": 5, "zes": 6,
                "zeven": 7, "acht": 8, "negen": 9, "tien": 10,
            ],
            last: [
                "vorige _", "vorig _", "afgelopen _", "de afgelopen _",
                "het afgelopen _", "verleden _",
            ],
            this: ["deze _", "dit _"],
            inside: [
                "in de _", "in het _", "in _", "tijdens de _", "tijdens het _", "tijdens _",
            ],
            yearConnectors: ["van"],
            tripNouns: [
                "reis", "reizen", "reisje", "reisjes", "vakantie", "vakanties",
                "vakantiereis", "uitje", "uitjes", "uitstapje", "uitstapjes", "tripje",
                "stedentrip", "stedentripje", "stedentrips", "citytrip", "citytrips",
                "bezoek", "bezoekje",
            ],
            long: ["lang", "lange"],
            short: ["kort", "korte"],
            facets: [
                .island: ["eiland", "eilanden"],
                .abroad: ["buitenland"],
                .domestic: ["binnenland"],
            ],
            functionWords: [
                "naar", "in", "op", "te", "met", "bij", "uit", "door", "tijdens",
                "het", "een", "en", "of", "mijn", "onze", "ons", "alle", "laat",
                "zien", "waar", "wanneer", "ik", "we", "wij", "geweest", "bezocht",
            ],
            ambiguousFunctionWords: ["de", "den", "van", "ben", "waren", "toon"]
        ),
        "pt-BR": Table(
            seasons: [
                .spring: ["primavera"], .summer: ["verão"],
                .autumn: ["outono"], .winter: ["inverno"],
            ],
            weekend: ["fim de semana", "fins de semana"],
            lastYear: ["o ano passado", "ano passado", "no ano passado"],
            thisYear: ["este ano", "neste ano", "esse ano"],
            lastMonth: ["o mês passado", "mês passado", "no mês passado"],
            yearBeforeLast: ["o ano retrasado", "ano retrasado", "no ano retrasado"],
            yearsAgo: ["há _ anos", "há _ ano", "_ anos atrás", "faz _ anos"],
            since: ["desde _", "a partir de _"],
            after: ["depois de _"],
            before: ["antes de _"],
            until: ["até _"],
            spans: ["entre _ e _", "de _ a _", "_ a _"],
            longer: ["mais de _", "mais longa que _", "mais longas que _"],
            shorter: ["menos de _", "mais curta que _", "mais curtas que _"],
            atLeast: ["pelo menos _", "no mínimo _", "_ ou mais"],
            atMost: ["no máximo _", "até _", "_ ou menos"],
            units: ["dia": 1, "dias": 1, "semana": 7, "semanas": 7],
            counts: [
                "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "quatro": 4, "cinco": 5,
                "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10,
            ],
            last: [
                "_ passado", "_ passada", "o _ passado", "a _ passada",
                "no _ passado", "na _ passada",
            ],
            this: [
                "este _", "esta _", "neste _", "nesta _",
                "esse _", "essa _", "nesse _", "nessa _",
            ],
            inside: [
                "no _", "na _", "em _", "de _", "durante o _", "durante a _", "durante _",
                "no mês de _",
            ],
            yearConnectors: ["de"],
            tripNouns: [
                "viagem", "viagens", "férias", "passeio", "passeios", "excursão",
                "excursões", "visita", "visitas",
            ],
            longAfterNoun: ["longa", "longas", "longo", "longos"],
            shortAfterNoun: ["curta", "curtas", "curto", "curtos"],
            longWeekend: ["fim de semana prolongado", "feriado prolongado"],
            disjunctions: ["ou"],
            facets: [
                .island: ["ilha", "ilhas"],
                .abroad: ["exterior"],
            ],
            functionWords: [
                "a", "à", "ao", "aos", "em", "no", "nos", "nas", "pra", "pro", "por",
                "pelo", "pela", "pelos", "pelas", "com", "os", "um", "uma", "uns",
                "umas", "e",
                "ou", "meu", "minha", "meus", "minhas", "nosso", "nossa", "nossos",
                "nossas", "todos", "todas", "mostre", "mostrar", "onde", "quando",
                "durante", "fui", "fomos", "estive", "estivemos", "visitei", "visitamos",
            ],
            ambiguousFunctionWords: ["o", "as", "às", "do", "da", "dos", "das", "na", "de", "para"]
        ),
        "pt-PT": Table(
            seasons: [
                .spring: ["primavera"], .summer: ["verão"],
                .autumn: ["outono"], .winter: ["inverno"],
            ],
            weekend: ["fim de semana", "fim-de-semana", "fins de semana", "fins-de-semana"],
            lastYear: ["o ano passado", "ano passado", "no ano passado"],
            thisYear: ["este ano", "neste ano"],
            lastMonth: ["o mês passado", "mês passado", "no mês passado"],
            yearsAgo: ["há _ anos", "há _ ano", "_ anos atrás"],
            since: ["desde _", "a partir de _"],
            after: ["depois de _"],
            before: ["antes de _"],
            until: ["até _"],
            spans: ["entre _ e _", "de _ a _", "_ a _"],
            longer: ["mais de _", "mais longa que _", "mais longas que _"],
            shorter: ["menos de _", "mais curta que _", "mais curtas que _"],
            atLeast: ["pelo menos _", "no mínimo _", "_ ou mais"],
            atMost: ["no máximo _", "até _", "_ ou menos"],
            units: ["dia": 1, "dias": 1, "semana": 7, "semanas": 7],
            counts: [
                "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "quatro": 4, "cinco": 5,
                "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10,
            ],
            last: [
                "_ passado", "_ passada", "o _ passado", "a _ passada",
                "no _ passado", "na _ passada",
            ],
            this: ["este _", "esta _", "neste _", "nesta _"],
            inside: [
                "no _", "na _", "em _", "de _", "durante o _", "durante a _", "durante _",
                "no mês de _",
            ],
            yearConnectors: ["de"],
            tripNouns: [
                "viagem", "viagens", "férias", "passeio", "passeios", "excursão",
                "excursões", "visita", "visitas",
            ],
            longAfterNoun: ["longa", "longas", "longo", "longos"],
            shortAfterNoun: ["curta", "curtas", "curto", "curtos"],
            longWeekend: ["fim de semana prolongado", "fim-de-semana prolongado"],
            disjunctions: ["ou"],
            facets: [
                .island: ["ilha", "ilhas"],
                .abroad: ["estrangeiro"],
            ],
            functionWords: [
                "a", "à", "ao", "aos", "em", "no", "nos", "nas", "por", "pelo",
                "pela", "pelos", "pelas", "com", "os", "um", "uma", "uns", "umas", "e",
                "ou", "meu", "minha", "meus", "minhas", "nosso", "nossa", "nossos",
                "nossas", "todos", "todas", "mostre", "mostrar", "onde", "quando",
                "durante", "fui", "fomos", "estive", "estivemos", "visitei", "visitámos",
            ],
            ambiguousFunctionWords: ["o", "as", "às", "do", "da", "dos", "das", "na", "de", "para"]
        ),
        "sv": Table(
            seasons: [
                .spring: ["våren"], .summer: ["sommar", "sommaren"],
                .autumn: ["höst", "hösten"], .winter: ["vinter", "vintern"],
            ],
            anchorRequired: [.spring: ["vår"]],
            recent: [.spring: ["våras"], .summer: ["somras"], .autumn: ["höstas"], .winter: ["vintras"]],
            weekend: ["helg", "helgen", "helger", "weekend", "veckoslut", "långhelg", "långhelgen"],
            lastYear: ["förra året", "i fjol"],
            thisYear: ["i år", "detta år", "det här året"],
            lastMonth: ["förra månaden"],
            yearBeforeLast: ["i förfjol", "förrförra året"],
            yearsAgo: ["för _ år sedan"],
            since: ["sedan _", "från _"],
            after: ["efter _"],
            before: ["före _", "innan _"],
            until: ["till och med _", "fram till _"],
            spans: ["mellan _ och _", "från _ till _", "_ till _"],
            longer: ["längre än _", "mer än _", "över _"],
            shorter: ["kortare än _", "mindre än _", "under _"],
            atLeast: ["minst _", "_ eller mer", "_ eller längre"],
            atMost: ["högst _", "max _", "_ eller mindre", "_ eller kortare"],
            units: ["dag": 1, "dagar": 1, "dygn": 1, "vecka": 7, "veckor": 7],
            counts: [
                "en": 1, "ett": 1, "två": 2, "tre": 3, "fyra": 4, "fem": 5, "sex": 6,
                "sju": 7, "åtta": 8, "nio": 9, "tio": 10,
            ],
            last: ["förra _"],
            this: ["denna _", "den här _"],
            inside: ["i _", "på _", "under _"],
            tripNouns: [
                "resa", "resor", "resan", "resorna", "semester", "semestern",
                "semestrar", "semesterresa", "utflykt", "utflykter", "besök",
            ],
            long: ["lång", "långa"],
            short: ["kort", "korta"],
            longWeekend: ["långhelg", "långhelgen"],
            disjunctions: ["eller"],
            facets: [
                .abroad: ["utomlands", "utlandet"],
                .domestic: ["inrikes"],
            ],
            functionWords: [
                "till", "i", "på", "från", "med", "och", "eller", "det", "en", "ett",
                "min", "mitt", "mina", "vårt", "våra", "alla", "visa", "mig", "när",
                "jag", "åkte", "reste", "besökte", "under", "har", "varit",
            ],
            // `var` ("was", "where") folds to `vår`, already anchor-only.
            ambiguousFunctionWords: ["den", "de", "vi"]
        ),
        "tr": Table(
            seasons: [
                .spring: ["ilkbahar", "bahar", "ilkbaharda", "baharda"],
                .summer: ["yaz", "yazın"],
                .autumn: ["sonbahar", "güz", "sonbaharda"],
                .winter: ["kış", "kışın"],
            ],
            // Possessive forms used after a year (`2024 yazı`, `2024
            // yazında`); `yazı` is also "writing", so they never stand alone.
            anchorRequired: [
                .spring: ["ilkbaharı", "baharı", "ilkbaharında", "baharında"],
                .summer: ["yazı", "yazında"],
                .autumn: ["sonbaharı", "sonbaharında"], .winter: ["kışı", "kışında"],
            ],
            weekend: ["hafta sonu", "haftasonu", "hafta sonları", "hafta sonunda", "haftasonunda"],
            lastYear: ["geçen yıl", "geçen sene", "geçtiğimiz yıl"],
            thisYear: ["bu yıl", "bu sene"],
            lastMonth: ["geçen ay", "geçtiğimiz ay"],
            yearBeforeLast: ["evvelki yıl", "evvelsi yıl", "evvelsi sene"],
            yearsAgo: ["_ yıl önce", "_ sene önce"],
            // After the apostrophe suffixes are stripped: `2020'den beri`.
            since: ["_ beri", "_ yılından beri", "_ itibaren", "_ yılından itibaren"],
            after: ["_ sonra", "_ yılından sonra"],
            before: ["_ önce", "_ yılından önce"],
            until: ["_ kadar", "_ yılına kadar"],
            spans: ["_ ile _ arası", "_ ile _ arasında", "_ ve _ arası", "_ ve _ arasında"],
            longer: ["_ fazla", "_ uzun"],
            shorter: ["_ az", "_ kısa"],
            atLeast: ["en az _"],
            atMost: ["en fazla _", "en çok _"],
            units: [
                "gün": 1, "günlük": 1, "günden": 1, "hafta": 7, "haftalık": 7, "haftadan": 7,
            ],
            counts: [
                "bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7,
                "sekiz": 8, "dokuz": 9, "on": 10,
            ],
            // Combined frames (`geçen Temmuz ayında`), or `last` claims
            // `geçen Temmuz` and leaves `ayında` as a place word.
            last: ["geçen _", "geçtiğimiz _", "geçen _ ayında", "geçtiğimiz _ ayında", "geçen _ ayı"],
            this: ["bu _", "bu _ ayında", "bu _ ayı"],
            inside: ["_ ayında", "_ ayı"],
            tripNouns: [
                "gezi", "gezisi", "geziler", "gezim", "gezimiz", "gezide", "seyahat",
                "seyahati", "seyahatim", "seyahatimiz", "seyahatler", "seyahatte",
                "tatil", "tatili", "tatilim", "tatilimiz", "tatiller", "tatilde",
                "yolculuk", "yolculuğu", "ziyaret",
            ],
            long: ["uzun"],
            short: ["kısa"],
            disjunctions: ["veya", "yahut"],
            facets: [
                .island: ["ada", "adalar"],
                .abroad: ["yurt dışı", "yurtdışı"],
                .domestic: ["yurt içi", "yurtiçi"],
            ],
            functionWords: [
                "ve", "veya", "için", "sırasında", "bütün", "hepsi",
                "benim", "bizim", "göster", "nerede", "nereye", "gittim", "gittik",
                "gittiğim", "gittiğimiz",
            ],
            ambiguousFunctionWords: ["ile", "tüm"],
            fillerPhrases: ["ya da", "ne zaman", "bana göster"],
            apostropheSuffixes: [
                "a", "e", "ya", "ye", "da", "de", "ta", "te", "dan", "den", "tan", "ten",
                "daki", "deki", "taki", "teki", "na", "ne", "nda", "nde", "ndan", "nden",
                "ın", "in", "un", "ün", "nın", "nin", "nun", "nün",
                "ı", "i", "u", "ü", "yı", "yi", "yu", "yü",
            ]
        ),
        "vi": Table(
            // `mùa` forms only, except `hè`: bare `hạ`, `xuân`, `thu`, `đông`
            // are everyday place syllables (Hạ Long, Quảng Đông, Thu Duc),
            // while `hè` names no notable place and is the everyday form
            // (`hè 2024`, `nghỉ hè`).
            seasons: [
                .spring: ["mùa xuân"], .summer: ["mùa hè", "mùa hạ", "hè", "nghỉ hè"],
                .autumn: ["mùa thu"], .winter: ["mùa đông"],
            ],
            weekend: ["cuối tuần"],
            lastYear: ["năm ngoái", "năm trước", "năm rồi", "năm vừa qua", "năm vừa rồi"],
            thisYear: ["năm nay"],
            lastMonth: ["tháng trước", "tháng rồi", "tháng vừa qua"],
            yearBeforeLast: ["năm kia"],
            yearsAgo: ["_ năm trước", "_ năm về trước", "cách đây _ năm"],
            since: ["từ _", "từ năm _", "kể từ _", "kể từ năm _"],
            after: ["sau _", "sau năm _"],
            before: ["trước _", "trước năm _"],
            until: ["đến _", "đến năm _"],
            spans: ["từ _ đến _", "từ năm _ đến năm _", "giữa _ và _", "_ đến _"],
            longer: ["hơn _", "trên _", "dài hơn _", "lâu hơn _", "nhiều hơn _"],
            shorter: ["dưới _", "ít hơn _", "ngắn hơn _"],
            atLeast: ["ít nhất _", "tối thiểu _"],
            atMost: ["tối đa _", "nhiều nhất _"],
            units: ["ngày": 1, "tuần": 7],
            // `năm` (five) is left out: it is also "year".
            counts: [
                "một": 1, "hai": 2, "ba": 3, "bốn": 4, "sáu": 6, "bảy": 7, "tám": 8,
                "chín": 9, "mười": 10,
            ],
            last: ["_ trước", "_ vừa qua", "_ vừa rồi"],
            this: ["_ này"],
            inside: ["vào _", "trong _"],
            yearConnectors: ["năm"],
            tripNouns: ["chuyến"],
            disjunctions: ["hoặc", "hay"],
            facets: [
                .island: ["đảo"],
                .abroad: ["nước ngoài"],
                .domestic: ["trong nước"],
            ],
            functionWords: ["tôi", "tới", "những", "các", "hoặc", "xem"],
            // Single syllables that are also place syllables after tone
            // folding (Đến/Đền, Ô Môn, Tai Po, Cửa Lò, Hồ Chí Minh, Dĩ An,
            // Chợ Lớn); inside the phrases below they are safe.
            ambiguousFunctionWords: [
                "đến", "ở", "tại", "vào", "và", "hay", "của", "mình", "đi", "cho", "trong",
            ],
            fillerPhrases: [
                "chuyến đi", "chuyến du lịch", "du lịch", "kỳ nghỉ", "nghỉ mát",
                "đi chơi", "của tôi", "của chúng tôi", "của mình", "chúng tôi",
                "tất cả", "cho tôi xem", "khi nào", "ở đâu",
            ],
            extraMonths: [
                "tháng giêng": 1, "tháng một": 1, "tháng hai": 2, "tháng ba": 3,
                "tháng tư": 4, "tháng bốn": 4, "tháng năm": 5, "tháng sáu": 6,
                "tháng bảy": 7, "tháng tám": 8, "tháng chín": 9, "tháng mười": 10,
                "tháng mười một": 11, "tháng mười hai": 12, "tháng chạp": 12,
            ]
        ),
        "zh-Hans": Table(
            seasons: [
                .spring: ["春天", "春季"], .summer: ["夏天", "夏季", "暑假"],
                .autumn: ["秋天", "秋季"], .winter: ["冬天", "冬季", "寒假"],
            ],
            anchorRequired: [.spring: ["春"], .summer: ["夏"], .autumn: ["秋"], .winter: ["冬"]],
            weekend: ["周末", "週末"],
            lastYear: ["去年"],
            thisYear: ["今年"],
            lastMonth: ["上个月", "上月"],
            yearBeforeLast: ["前年"],
            since: ["_以后", "_以来", "_起", "从_起", "自_起", "自_以来", "从_开始"],
            after: ["_之后"],
            before: ["_之前", "_前"],
            until: ["_以前"],
            spans: ["_到_", "_至_", "从_到_", "从_至_"],
            last: ["上个_"],
            this: ["这个_"],
            tripNouns: [
                "旅行", "旅游", "旅途", "之旅", "旅", "度假", "假期", "出游", "游玩",
                "行程", "出差",
            ],
            disjunctions: ["或", "或者"],
            facets: [
                .island: ["海岛"],
                .abroad: ["国外", "出国", "境外"],
                .domestic: ["国内"],
            ],
            functionWords: [
                "我的", "我", "的", "去", "在", "到", "和", "与", "所有", "全部",
                "显示", "期间", "我们", "我们的", "去过",
                // `份` completes a month (`7月份`).
                "份", "时候", "哪里", "哪儿", "哪些", "什么时候",
            ]
        ),
        "zh-Hant": Table(
            seasons: [
                .spring: ["春天", "春季"], .summer: ["夏天", "夏季", "暑假"],
                .autumn: ["秋天", "秋季"], .winter: ["冬天", "冬季", "寒假"],
            ],
            anchorRequired: [.spring: ["春"], .summer: ["夏"], .autumn: ["秋"], .winter: ["冬"]],
            weekend: ["週末", "周末"],
            lastYear: ["去年"],
            thisYear: ["今年"],
            lastMonth: ["上個月", "上月"],
            yearBeforeLast: ["前年"],
            since: ["_以後", "_以來", "_起", "從_起", "自_起", "自_以來", "從_開始"],
            after: ["_之後"],
            before: ["_之前", "_前"],
            until: ["_以前"],
            spans: ["_到_", "_至_", "從_到_", "從_至_"],
            last: ["上個_"],
            this: ["這個_"],
            tripNouns: [
                "旅行", "旅遊", "旅途", "之旅", "旅", "度假", "假期", "出遊", "遊玩",
                "行程", "出差",
            ],
            disjunctions: ["或", "或者"],
            facets: [
                .island: ["海島"],
                .abroad: ["國外", "出國", "境外"],
                .domestic: ["國內"],
            ],
            functionWords: [
                "我的", "我", "的", "去", "在", "到", "和", "與", "所有", "全部",
                "顯示", "期間", "我們", "我們的", "去過",
                "份", "時候", "哪裡", "哪些", "什麼時候",
            ]
        ),
    ]
}

// MARK: - Holidays and other query words

/// A holiday a query can name (`Christmas 2023`, `Πάσχα`, `Silvester`): a
/// trip matches when it overlaps the holiday's days (`days(in:)`) in a year
/// the query admits. The days are the ones people travel around, not only
/// the feast day: Christmas Eve to the second day of Christmas, New Year's
/// Eve and Day, Good Friday to Easter Monday (the public-holiday span in most
/// countries, Greece included), the Assumption on 15 August.
nonisolated enum TripQueryHoliday: String, Sendable, Hashable, CaseIterable {
    case christmas
    case newYear
    case newYearsEve
    /// Gregorian computus (Catholic and Protestant churches).
    case westernEaster
    /// Julian computus (Orthodox churches), as a Gregorian date.
    case orthodoxEaster
    /// 15 August (Greek `Δεκαπενταύγουστος`, Italian `Ferragosto`).
    case assumption

    /// The first and last day (inclusive, Gregorian) of the holiday whose
    /// main day falls in `year`: New Year 2024 is 31 December 2023 to
    /// 1 January 2024.
    func days(in year: Int) -> (first: DateComponents, last: DateComponents) {
        func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: m, day: d) }
        switch self {
        case .christmas: return (day(year, 12, 24), day(year, 12, 26))
        case .newYear: return (day(year - 1, 12, 31), day(year, 1, 1))
        case .newYearsEve: return (day(year, 12, 31), day(year, 12, 31))
        case .westernEaster: return Self.span(around: Self.westernEaster(year))
        case .orthodoxEaster: return Self.span(around: Self.orthodoxEaster(year))
        case .assumption: return (day(year, 8, 15), day(year, 8, 15))
        }
    }

    /// Easter Sunday by the Gregorian computus (the anonymous Gregorian
    /// algorithm, as in Meeus).
    static func westernEaster(_ year: Int) -> DateComponents {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return DateComponents(year: year, month: month, day: day)
    }

    /// Easter Sunday by the Julian computus (Meeus), converted to the
    /// Gregorian calendar (the Julian calendar runs 13 days behind from
    /// 1900 to 2099, the years the parser reads).
    static func orthodoxEaster(_ year: Int) -> DateComponents {
        let a = year % 4, b = year % 7, c = year % 19
        let d = (19 * c + 15) % 30
        let e = (2 * a + 4 * b - d + 34) % 7
        let month = (d + e + 114) / 31
        let day = (d + e + 114) % 31 + 1
        return shifted(DateComponents(year: year, month: month, day: day), by: 13)
    }

    /// Good Friday to Easter Monday.
    private static func span(around easter: DateComponents) -> (first: DateComponents, last: DateComponents) {
        (shifted(easter, by: -2), shifted(easter, by: 1))
    }

    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func shifted(_ day: DateComponents, by days: Int) -> DateComponents {
        guard let date = gregorian.date(from: day),
              let moved = gregorian.date(byAdding: .day, value: days, to: date) else { return day }
        return gregorian.dateComponents([.year, .month, .day], from: moved)
    }
}

nonisolated extension TripQueryVocabulary {

    private enum HolidayName { case christmas, newYear, newYearsEve, easter, assumption }

    /// Which Easter a language's Easter word names. Greek is Orthodox;
    /// English, used by both traditions, names either; the other app
    /// languages name the Gregorian Easter.
    private enum EasterReading { case western, orthodox, either }

    private struct WordTable {
        var easter: EasterReading = .western
        var holidays: [HolidayName: [String]] = [:]
        var first: [String] = []
        var last: [String] = []
        var firstAfterNoun: [String] = []
        var lastAfterNoun: [String] = []
        var via: [String] = []
        var viaAfterPlace: [String] = []
        var facets: [TripSearchFacet: [String]] = [:]
    }

    private static func addSearchWords(_ tag: String, to language: inout Language) {
        var table = WordTable()
        if let holidays = holidayTables[tag] { table.easter = holidays.easter; table.holidays = holidays.holidays }
        if let ordinals = ordinalTables[tag] {
            table.first = ordinals.first
            table.last = ordinals.last
            table.firstAfterNoun = ordinals.firstAfterNoun
            table.lastAfterNoun = ordinals.lastAfterNoun
        }
        if let via = viaTables[tag] { table.via = via.via; table.viaAfterPlace = via.viaAfterPlace }
        for facets in [flightFacetTables[tag], countryCountFacetTables[tag]].compactMap({ $0?.facets }) {
            table.facets.merge(facets) { mine, _ in mine }
        }
        let easter: Set<TripQueryHoliday> = switch table.easter {
        case .western: [.westernEaster]
        case .orthodox: [.orthodoxEaster]
        case .either: [.westernEaster, .orthodoxEaster]
        }
        for (name, words) in table.holidays {
            let holidays: Set<TripQueryHoliday> = switch name {
            case .christmas: [.christmas]
            case .newYear: [.newYear]
            case .newYearsEve: [.newYearsEve]
            case .easter: easter
            case .assumption: [.assumption]
            }
            for word in words where language.holidayWords[word] == nil { language.holidayWords[word] = holidays }
        }
        language.firstWords = Set(table.first)
        language.lastWords = Set(table.last)
        language.firstWordsAfterNoun = Set(table.firstAfterNoun)
        language.lastWordsAfterNoun = Set(table.lastAfterNoun)
        language.viaWords = Set(table.via)
        language.viaWordsAfterPlace = Set(table.viaAfterPlace)
        for (facet, words) in table.facets {
            for word in words where language.facetWords[word] == nil { language.facetWords[word] = facet }
        }
    }

    // Native review needed for every table below.

    /// Holiday words; an Easter word names the Easter of `easter`.
    private static let holidayTables: [String: WordTable] = [
        "en": WordTable(easter: .either, holidays: [.christmas: ["christmas", "xmas", "christmas eve", "christmas day"], .newYear: ["new year", "new years"], .newYearsEve: ["new year eve", "new years eve", "nye"], .easter: ["easter"]]),
        "da": WordTable(holidays: [.christmas: ["julen", "juleaften"], .newYear: ["nytår", "nytåret"], .newYearsEve: ["nytårsaften"], .easter: ["påske", "påsken"]]),
        "de": WordTable(holidays: [.christmas: ["Weihnachten", "Heiligabend"], .newYear: ["Neujahr"], .newYearsEve: ["Silvester"], .easter: ["Ostern"], .assumption: ["Mariä Himmelfahrt"]]),
        "el": WordTable(easter: .orthodox, holidays: [.christmas: ["Χριστούγεννα", "Χριστουγέννων"], .newYear: ["Πρωτοχρονιά", "Πρωτοχρονιάς"], .newYearsEve: ["παραμονή Πρωτοχρονιάς"], .easter: ["Πάσχα", "Λαμπρή"], .assumption: ["Δεκαπενταύγουστος", "Δεκαπενταύγουστο", "Δεκαπενταύγουστου"]]),
        "es": WordTable(holidays: [.christmas: ["Navidad", "Navidades", "Nochebuena"], .newYear: ["Año Nuevo"], .newYearsEve: ["Nochevieja"], .easter: ["Semana Santa", "Pascua"]]),
        "fr": WordTable(holidays: [.christmas: ["Noël"], .newYear: ["nouvel an", "jour de l'an"], .newYearsEve: ["Saint-Sylvestre"], .easter: ["Pâques"], .assumption: ["Assomption"]]),
        "it": WordTable(holidays: [.christmas: ["Natale"], .newYear: ["Capodanno"], .easter: ["Pasqua"], .assumption: ["Ferragosto"]]),
        "ja": WordTable(holidays: [.christmas: ["クリスマス"], .newYear: ["正月", "お正月", "元日"], .newYearsEve: ["大晦日"], .easter: ["イースター", "復活祭"]]),
        "ko": WordTable(holidays: [.christmas: ["크리스마스", "성탄절"], .newYear: ["새해", "신정"], .easter: ["부활절"]]),
        "nb": WordTable(holidays: [.christmas: ["jula", "julen", "julaften"], .newYear: ["nyttår", "nyttåret"], .newYearsEve: ["nyttårsaften"], .easter: ["påske", "påsken"]]),
        "nl": WordTable(holidays: [.christmas: ["Kerstmis", "kerst"], .newYear: ["Nieuwjaar", "oud en nieuw"], .newYearsEve: ["oudejaarsavond"], .easter: ["Pasen"]]),
        "pt-BR": WordTable(holidays: [.christmas: ["Natal"], .newYear: ["Ano Novo"], .newYearsEve: ["Réveillon"], .easter: ["Páscoa"]]),
        "pt-PT": WordTable(holidays: [.christmas: ["Natal"], .newYear: ["Ano Novo"], .newYearsEve: ["passagem de ano"], .easter: ["Páscoa"]]),
        "sv": WordTable(holidays: [.christmas: ["julen", "julafton"], .newYear: ["nyår", "nyåret", "nyårsdagen"], .newYearsEve: ["nyårsafton"], .easter: ["påsk", "påsken"]]),
        "tr": WordTable(holidays: [.christmas: ["Noel"], .newYear: ["yılbaşı"], .easter: ["Paskalya"]]),
        "vi": WordTable(holidays: [.christmas: ["Giáng Sinh", "Noel"], .newYear: ["Tết Dương lịch"], .easter: ["Lễ Phục Sinh", "Phục Sinh"]]),
        "zh-Hans": WordTable(holidays: [.christmas: ["圣诞节", "圣诞"], .newYear: ["元旦"], .newYearsEve: ["跨年"], .easter: ["复活节"]]),
        "zh-Hant": WordTable(holidays: [.christmas: ["聖誕節", "聖誕"], .newYear: ["元旦"], .newYearsEve: ["跨年"], .easter: ["復活節"]]),
    ]

    /// Ordinal words before and after a trip noun.
    private static let ordinalTables: [String: WordTable] = [
        "en": WordTable(first: ["first", "earliest"], last: ["last", "latest", "most recent", "previous"]),
        "da": WordTable(first: ["første"], last: ["seneste", "sidste"]),
        "de": WordTable(first: ["erste", "erster", "erstes", "ersten"], last: ["letzte", "letzter", "letztes", "letzten", "neueste", "neuesten", "jüngste", "jüngsten"]),
        "el": WordTable(first: ["πρώτο", "πρώτη", "πρώτα"], last: ["τελευταίο", "τελευταία", "τελευταίες", "πιο πρόσφατο", "πιο πρόσφατη"]),
        "es": WordTable(first: ["primer", "primera"], last: ["último", "última"], lastAfterNoun: ["más reciente"]),
        "fr": WordTable(first: ["premier", "première"], last: ["dernier", "dernière"], lastAfterNoun: ["le plus récent", "la plus récente"]),
        "it": WordTable(first: ["primo", "prima"], last: ["ultimo", "ultima"], lastAfterNoun: ["più recente"]),
        "ja": WordTable(first: ["最初", "初めて"], last: ["最後", "前回", "最近"]),
        "ko": WordTable(first: ["첫"], last: ["마지막", "최근"]),
        "nb": WordTable(first: ["første"], last: ["siste", "seneste"]),
        "nl": WordTable(first: ["eerste"], last: ["laatste", "recentste", "meest recente"]),
        "pt-BR": WordTable(first: ["primeiro", "primeira"], last: ["último", "última"], lastAfterNoun: ["mais recente"]),
        "pt-PT": WordTable(first: ["primeiro", "primeira"], last: ["último", "última"], lastAfterNoun: ["mais recente"]),
        "sv": WordTable(first: ["första"], last: ["senaste", "sista"]),
        "tr": WordTable(first: ["ilk"], last: ["son", "en son"]),
        "vi": WordTable(firstAfterNoun: ["đầu tiên"], lastAfterNoun: ["gần nhất", "cuối cùng", "gần đây nhất"]),
        "zh-Hans": WordTable(first: ["第一次"], last: ["最近一次", "上次", "最后一次"]),
        "zh-Hant": WordTable(first: ["第一次"], last: ["最近一次", "上次", "最後一次"]),
    ]

    /// "via" words before and after the place.
    private static let viaTables: [String: WordTable] = [
        "en": WordTable(via: ["via", "layover in", "layover at", "stopover in", "connection in", "connecting in", "passing through"]),
        "da": WordTable(via: ["via", "mellemlanding i"]),
        "de": WordTable(via: ["über", "via", "Umstieg in", "Zwischenstopp in"]),
        "el": WordTable(via: ["μέσω", "ανταπόκριση σε", "ανταπόκριση στο", "ανταπόκριση στη", "στάση σε", "στάση στο", "στάση στη"]),
        "es": WordTable(via: ["vía", "via", "escala en", "pasando por"]),
        "fr": WordTable(via: ["via", "en passant par", "escale à", "correspondance à"]),
        "it": WordTable(via: ["via", "passando per", "scalo a"]),
        "ja": WordTable(viaAfterPlace: ["経由"]),
        "ko": WordTable(viaAfterPlace: ["경유"]),
        "nb": WordTable(via: ["via", "mellomlanding i"]),
        "nl": WordTable(via: ["via", "overstap in", "tussenstop in"]),
        "pt-BR": WordTable(via: ["via", "passando por", "escala em", "conexão em"]),
        "pt-PT": WordTable(via: ["via", "passando por", "escala em", "ligação em"]),
        "sv": WordTable(via: ["via", "mellanlandning i", "byte i"]),
        "tr": WordTable(viaAfterPlace: ["üzerinden", "aktarmalı"]),
        "vi": WordTable(via: ["qua", "quá cảnh tại", "quá cảnh ở"]),
        "zh-Hans": WordTable(viaAfterPlace: ["经停", "转机"]),
        "zh-Hant": WordTable(viaAfterPlace: ["經停", "轉機"]),
    ]

    /// Flight and long-haul trip words.
    private static let flightFacetTables: [String: WordTable] = [
        "en": WordTable(facets: [.flight: ["flight", "flights", "flew", "by plane", "by air"], .longHaul: ["long haul", "longhaul", "intercontinental"]]),
        "da": WordTable(facets: [.flight: ["fly", "flyrejse", "flyrejser"], .longHaul: ["langdistance"]]),
        "de": WordTable(facets: [.flight: ["Flug", "Flüge", "Flugreise", "Flugreisen", "geflogen"], .longHaul: ["Langstrecke", "Langstreckenflug", "Langstreckenflüge", "Fernreise", "Fernreisen"]]),
        "el": WordTable(facets: [.flight: ["πτήση", "πτήσεις", "πτήσης", "πτήσεων", "αεροπλάνο", "με αεροπλάνο"], .longHaul: ["υπερατλαντικό", "υπερατλαντικά", "υπερατλαντική", "υπερατλαντικές"]]),
        "es": WordTable(facets: [.flight: ["vuelo", "vuelos", "en avión", "avión"], .longHaul: ["larga distancia"]]),
        "fr": WordTable(facets: [.flight: ["vol", "vols", "en avion", "avion"], .longHaul: ["long-courrier", "long courrier", "longs courriers"]]),
        "it": WordTable(facets: [.flight: ["volo", "voli", "in aereo", "aereo"], .longHaul: ["lungo raggio"]]),
        "ja": WordTable(facets: [.flight: ["飛行機", "フライト"], .longHaul: ["長距離"]]),
        "ko": WordTable(facets: [.flight: ["비행", "항공편", "비행기"], .longHaul: ["장거리"]]),
        "nb": WordTable(facets: [.flight: ["fly", "flyreise", "flyreiser"], .longHaul: ["langdistanse"]]),
        "nl": WordTable(facets: [.flight: ["vlucht", "vluchten", "gevlogen"], .longHaul: ["lange afstand", "langeafstandsvlucht", "verre reis", "verre reizen"]]),
        "pt-BR": WordTable(facets: [.flight: ["voo", "voos", "de avião", "avião"], .longHaul: ["longa distância", "longo curso"]]),
        "pt-PT": WordTable(facets: [.flight: ["voo", "voos", "de avião", "avião"], .longHaul: ["longa distância", "longo curso"]]),
        "sv": WordTable(facets: [.flight: ["flyg", "flygresa", "flygresor", "flyget"], .longHaul: ["långdistans", "långresa", "långresor"]]),
        "tr": WordTable(facets: [.flight: ["uçuş", "uçuşlar", "uçakla"], .longHaul: ["uzun mesafe"]]),
        "vi": WordTable(facets: [.flight: ["chuyến bay", "máy bay"], .longHaul: ["đường dài"]]),
        "zh-Hans": WordTable(facets: [.flight: ["航班", "飞机"], .longHaul: ["长途飞行", "长途"]]),
        "zh-Hant": WordTable(facets: [.flight: ["航班", "飛機"], .longHaul: ["長途飛行", "長途"]]),
    ]

    /// Multi-country and single-country trip words.
    private static let countryCountFacetTables: [String: WordTable] = [
        "en": WordTable(facets: [.multiCountry: ["multi country", "multicountry", "multiple countries", "several countries", "many countries"], .singleCountry: ["single country", "one country"]]),
        "da": WordTable(facets: [.multiCountry: ["flere lande"], .singleCountry: ["ét land"]]),
        "de": WordTable(facets: [.multiCountry: ["mehrere Länder", "mehreren Ländern"], .singleCountry: ["einem Land"]]),
        "el": WordTable(facets: [.multiCountry: ["πολλές χώρες", "πολλών χωρών", "πολλαπλές χώρες"], .singleCountry: ["μία χώρα", "μια χώρα"]]),
        "es": WordTable(facets: [.multiCountry: ["varios países"], .singleCountry: ["un solo país"]]),
        "fr": WordTable(facets: [.multiCountry: ["plusieurs pays"], .singleCountry: ["un seul pays"]]),
        "it": WordTable(facets: [.multiCountry: ["più paesi", "vari paesi"], .singleCountry: ["un solo paese"]]),
        "ja": WordTable(facets: [.multiCountry: ["複数国"]]),
        "ko": WordTable(facets: [.multiCountry: ["여러 나라"], .singleCountry: ["한 나라"]]),
        "nb": WordTable(facets: [.multiCountry: ["flere land"], .singleCountry: ["ett land"]]),
        "nl": WordTable(facets: [.multiCountry: ["meerdere landen"], .singleCountry: ["één land"]]),
        "pt-BR": WordTable(facets: [.multiCountry: ["vários países"], .singleCountry: ["um só país", "um único país"]]),
        "pt-PT": WordTable(facets: [.multiCountry: ["vários países"], .singleCountry: ["um só país", "um único país"]]),
        "sv": WordTable(facets: [.multiCountry: ["flera länder"], .singleCountry: ["ett land"]]),
        "tr": WordTable(facets: [.multiCountry: ["birden fazla ülke", "çok ülkeli"], .singleCountry: ["tek ülke"]]),
        "vi": WordTable(facets: [.multiCountry: ["nhiều nước", "nhiều quốc gia"], .singleCountry: ["một nước", "một quốc gia"]]),
        "zh-Hans": WordTable(facets: [.multiCountry: ["多国"], .singleCountry: ["单一国家"]]),
        "zh-Hant": WordTable(facets: [.multiCountry: ["多國"], .singleCountry: ["單一國家"]]),
    ]
}
