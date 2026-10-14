//
//  TripQueryVocabulary.swift
//  TravelLog
//
//  Input vocabulary for `TripQueryParser` in the 18 app languages: month,
//  season, weekend and relative-date words, anchor frames ("last <season>",
//  "l'été dernier") and filler words dropped from place text.
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
//      app language. Short month forms are therefore only ever active for
//      English and the app language (they collide across languages:
//      `set`, `out`, `ago`, `mar`, `gen`).
//    - Seasons are northern-hemisphere month sets.
//    - Filler words were screened against `Geocoder.sqlite` place names.
//      Articles and prepositions that start or complete real places (`la`
//      in La Paz, `den` in Den Haag, `da` in Da Nang, `van` is a city) are
//      `ambiguousFunctionWords`, never unconditional filler, and frames
//      spell them out instead ("el _ pasado").
//    - Localized duration grammar is out of scope; number words are
//      English only.
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
            result.lastFrames = Self.unique(lastFrames + other.lastFrames)
            result.thisFrames = Self.unique(thisFrames + other.thisFrames)
            result.inFrames = Self.unique(inFrames + other.inFrames)
            result.yearConnectors.formUnion(other.yearConnectors)
            result.tripNouns.formUnion(other.tripNouns)
            result.functionWords.formUnion(other.functionWords)
            result.ambiguousFunctionWords.formUnion(other.ambiguousFunctionWords)
            result.fillerPhrases = Self.unique(fillerPhrases + other.fillerPhrases)
                .sorted { $0.count > $1.count }
            result.apostropheSuffixes.formUnion(other.apostropheSuffixes)
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

    /// Duration unit words and their length in days.
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
        var last: [String] = []
        var this: [String] = []
        var inside: [String] = []
        var yearConnectors: [String] = []
        var tripNouns: [String]
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

        return Language(
            tags: [tag],
            months: monthWords(tag, extras: table.extraMonths),
            seasons: seasons,
            seasonFinalMonth: finalMonth,
            anchorRequiredSeasonWords: anchorRequired,
            recentSeasonWords: recent,
            currentSeasonWords: current,
            weekendWords: Set(table.weekend),
            lastYearPhrases: table.lastYear,
            thisYearPhrases: table.thisYear,
            lastMonthPhrases: table.lastMonth,
            lastFrames: table.last.map(Frame.init),
            thisFrames: table.this.map(Frame.init),
            inFrames: table.inside.map(Frame.init),
            yearConnectors: Set(table.yearConnectors),
            tripNouns: Set(table.tripNouns),
            functionWords: Set(table.functionWords),
            ambiguousFunctionWords: Set(table.ambiguousFunctionWords),
            fillerPhrases: table.fillerPhrases.sorted { $0.count > $1.count },
            apostropheSuffixes: Set(table.apostropheSuffixes)
        )
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
            last: ["last _"],
            this: ["this _"],
            inside: ["in _", "during _"],
            yearConnectors: ["of"],
            tripNouns: [
                "trip", "trips", "travel", "travels", "vacation", "vacations",
                "holiday", "holidays", "getaway", "getaways", "journey", "journeys",
                "visit", "visits",
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
            last: ["sidste _", "forrige _"],
            this: ["denne _", "dette _"],
            inside: ["i _", "om _", "i løbet af _"],
            tripNouns: [
                "rejse", "rejser", "rejsen", "ferie", "ferier", "ferien", "ferietur",
                "tur", "ture", "turen", "udflugt", "udflugter", "besøg", "miniferie",
                "storbyferie",
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
            lastYear: ["去年", "昨年"],
            thisYear: ["今年"],
            lastMonth: ["先月"],
            this: ["この_"],
            tripNouns: [
                "旅行", "旅", "旅程", "観光", "休暇", "休み", "バケーション",
                "ツアー", "トリップ", "出張",
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
            last: ["지난 _"],
            this: ["이번 _", "올 _"],
            tripNouns: ["여행", "여행지", "휴가", "방문", "투어", "트립", "출장"],
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
            last: ["forrige _", "sist _"],
            this: ["denne _", "dette _"],
            inside: ["i _", "om _", "i løpet av _"],
            tripNouns: [
                "reise", "reiser", "reisen", "ferie", "ferier", "ferien", "ferietur",
                "tur", "turer", "turen", "utflukt", "utflukter", "besøk", "miniferie",
                "storbyferie",
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
            last: ["förra _"],
            this: ["denna _", "den här _"],
            inside: ["i _", "på _", "under _"],
            tripNouns: [
                "resa", "resor", "resan", "resorna", "semester", "semestern",
                "semestrar", "semesterresa", "utflykt", "utflykter", "besök",
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
            last: ["_ trước", "_ vừa qua", "_ vừa rồi"],
            this: ["_ này"],
            inside: ["vào _", "trong _"],
            yearConnectors: ["năm"],
            tripNouns: ["chuyến"],
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
            last: ["上个_"],
            this: ["这个_"],
            tripNouns: [
                "旅行", "旅游", "旅途", "之旅", "旅", "度假", "假期", "出游", "游玩",
                "行程", "出差",
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
            last: ["上個_"],
            this: ["這個_"],
            tripNouns: [
                "旅行", "旅遊", "旅途", "之旅", "旅", "度假", "假期", "出遊", "遊玩",
                "行程", "出差",
            ],
            functionWords: [
                "我的", "我", "的", "去", "在", "到", "和", "與", "所有", "全部",
                "顯示", "期間", "我們", "我們的", "去過",
                "份", "時候", "哪裡", "哪些", "什麼時候",
            ]
        ),
    ]
}
