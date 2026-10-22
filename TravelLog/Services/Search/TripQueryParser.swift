//
//  TripQueryParser.swift
//  TravelLog
//
//  Deterministic natural-language query parsing and the shared local search
//  resolver over a `TripSearchIndex` (list, Siri and Shortcuts use it).
//
//  `searchTrips(index:query:...)` orders the local passes: a corpus-aware
//  PLACE reading of ambiguous words (bare month/season words, a "long" that
//  follows place text, articles next to place text such as `la` in La Paz)
//  first, matched against geographic fields only; then the `TripSearch`
//  engine over every field; then the STRUCTURED intent the Foundation Models
//  search path (`SearchTripsTool.Arguments`) would otherwise be needed for:
//  duration phrases ("longer than a week", "weekend trips", "five days",
//  "2 weeks"), seasons ("summer 2024", "last summer", "Sommer 2024"),
//  relative dates ("last year", "πέρσι"), numeric CJK and Vietnamese months
//  ("1月", "tháng 1"), year lists and ranges ("2023-2024"), plus residual
//  place terms with the engine's typo tolerance ("greece longer than a
//  week"). When nothing matches every word, a partial pass drops dates and
//  numbers, then keeps the trips matching the most remaining words.
//
//  On non-Apple-Intelligence devices this is the only natural-language
//  search there is; on FM devices it answers the common shapes instantly
//  and the model is consulted only when this finds no strong or similar
//  match.
//
//  Scope notes (deliberate):
//    - Vocabulary is English plus the app language (`TripQueryVocabulary`);
//      duration grammar and number words are English only.
//    - Seasons are northern-hemisphere month sets.
//    - Dates use `TripFilters.yearCalendar` (Gregorian, device zone): the
//      document's `startYear` / `startMonth`, and its end date read in the
//      same calendar.
//    - A month or season paired with its year (`summer 2024`, `last
//      winter`, `2024年7月`) is one clause; clauses OR-combine ("summer
//      2024 or winter 2025"). Unpaired months and years join every clause.
//    - Ongoing trips have `durationDays == nil` and are excluded by
//      duration filters, identical to `SearchTripsTool`'s semantics.
//    - Pure values only: no SwiftData, safe from any executor.
//

import Foundation
import os

nonisolated enum TripQueryParser {

    // MARK: - Parsed result

    /// A month a date clause admits, `yearOffset` years after the clause's
    /// year: winter 2024 is December 2024 and January and February 2025.
    struct DateMonth: Hashable {
        var month: Int
        var yearOffset = 0
    }

    /// Months (empty = any month) in one of `years` (empty = any year),
    /// matched together, so `summer 2024 or winter 2025` never pairs one
    /// clause's months with the other clause's year.
    struct DateClause: Equatable {
        var months: Set<DateMonth> = []
        var years: Set<Int> = []

        func matches(year: Int, month: Int) -> Bool {
            if months.isEmpty { return years.isEmpty || years.contains(year) }
            if years.isEmpty { return months.contains { $0.month == month } }
            return months.contains { $0.month == month && years.contains(year - $0.yearOffset) }
        }
    }

    /// The date intent of one reading: clauses that syntax paired (`summer
    /// 2024`, `last winter`), ORed, plus the months and years no syntax
    /// paired. Loose parts join every clause (`summer 2024 or 2025`, `july
    /// 2024 or august`, `summer or winter 2025`); without a clause they form
    /// the only one. A loose season keeps its own year offsets, so loose
    /// July next to `winter 2024` no longer turns off winter's wrap.
    struct DateFilter: Equatable {
        var clauses: [DateClause] = []
        var looseMonths: Set<DateMonth> = []
        var looseYears: Set<Int> = []

        var isEmpty: Bool { clauses.isEmpty && looseMonths.isEmpty && looseYears.isEmpty }

        /// Every year any clause or loose part names.
        var years: Set<Int> { clauses.reduce(looseYears) { $0.union($1.years) } }

        /// Every month-of-year any clause or loose part names.
        var months: Set<Int> {
            Set(looseMonths.map(\.month)).union(clauses.flatMap { $0.months.map(\.month) })
        }

        var effectiveClauses: [DateClause] {
            guard !clauses.isEmpty else { return [DateClause(months: looseMonths, years: looseYears)] }
            return clauses.map {
                DateClause(months: $0.months.union(looseMonths), years: $0.years.union(looseYears))
            }
        }

        func matches(year: Int, month: Int) -> Bool {
            isEmpty || effectiveClauses.contains { $0.matches(year: year, month: month) }
        }
    }

    struct ParsedQuery: Equatable {
        /// Every date clause and loose date word (the structured pass).
        var dates = DateFilter()
        /// `dates` without the ambiguous words (bare month and season words,
        /// recent-season words such as Swedish `våras`), which the place
        /// reading turns into place text. Explicit clauses, anchored months
        /// and every year stay.
        var unambiguousDates = DateFilter()
        /// The date syntax hidden from the engine pass (explicit clauses,
        /// anchored months, numeric and relative years). The engine pass
        /// must respect it because it no longer sees those words.
        var consumedDates = DateFilter()

        /// Years the trip may fall in, over every clause (descriptive).
        var years: Set<Int> { dates.years }
        /// Months-of-year the trip may fall in, over every clause (descriptive).
        var months: Set<Int> { dates.months }
        /// Month constraints established by unambiguous syntax (`last winter`,
        /// `this May`, `last month`, `7月`). A place interpretation keeps these
        /// while removing only the contribution of bare ambiguous words.
        var anchoredMonths: Set<Int> { consumedDates.months }

        var minDurationDays: Int?
        var maxDurationDays: Int?
        /// Residual non-noise words as engine terms (all must hit).
        var placeTerms: [TripSearchTerm] = []
        /// True when filler words ("trips", "to", "show me") were dropped.
        var droppedNoise = false

        /// Bare month/season words are genuinely ambiguous: `winter` can be a
        /// date filter or part of `Winter Park`. The structured parse keeps
        /// their month contribution in `months`; this parallel representation
        /// lets corpus-aware search try them as place words first.
        var ambiguousDateTokens: [String] = []

        /// Raw text of `placeTerms` that must match a WHOLE word. The
        /// ambiguous words moved in by `placeInterpretation` use this, and so
        /// does every term of a "long" place reading: prefix or typo
        /// tolerance would let "Mayfair" satisfy a bare "may" and silently
        /// mask the date reading entirely.
        var strictWholeWordTerms: Set<String> = []

        /// True when a "long" dropped before a trip noun followed place text
        /// ("Ha Long trips"). The place reading restores it and matches every
        /// term as a whole word, so a typo neighbour cannot return Long Beach
        /// alone ("Hong Kong long trips"); when nothing matches, the filler
        /// reading runs and its typo tolerance can still list Long Beach.
        var longFollowsPlace = false

        /// Articles and prepositions that also start or complete place names
        /// (`la` in La Paz, `de` in Rio de Janeiro), found next to place text.
        /// Dropped as noise here; the place reading restores them as whole words.
        var ambiguousFunctionTokens: [String] = []

        /// Terms for the ambiguous date and function words, in query order.
        var ambiguousTerms: [TripSearchTerm] = []

        /// What the engine pass sees: the query without the words consumed
        /// by date or duration syntax (so `1月` cannot find `11月` as text).
        var fuzzyText = ""
        /// Whether the last word of `fuzzyText` is the word being typed.
        var fuzzyTextEndsInTypedWord = false
        /// True when the word being typed is a filler kept as place text
        /// because a place starts with it (`war` → Warsaw).
        var typedFillerIsPlace = false
        /// Duration constraints of the consumed syntax (see `consumedDates`).
        var consumedMinDurationDays: Int?
        var consumedMaxDurationDays: Int?
        var consumedSyntax = false

        var hasStructuredFilter: Bool {
            !dates.isEmpty || minDurationDays != nil || maxDurationDays != nil
        }

        /// Whether this parse should claim the query at all. A query with
        /// no structured filter and no dropped noise is just place words,
        /// exactly what the engine pass already tried, so re-running it
        /// here would change nothing.
        var isClaimable: Bool {
            hasStructuredFilter || (droppedNoise && !placeTerms.isEmpty)
        }

        /// Alternate reading in which the ambiguous words are place text.
        /// Nil means the query contains no such ambiguity. Unambiguous
        /// filters (duration, years, anchored months) remain active.
        var placeInterpretation: ParsedQuery? {
            guard !ambiguousDateTokens.isEmpty || !ambiguousFunctionTokens.isEmpty || longFollowsPlace
            else { return nil }
            var alternative = self
            alternative.dates = unambiguousDates
            alternative.placeTerms.append(contentsOf: ambiguousTerms)
            alternative.strictWholeWordTerms = Set(ambiguousTerms.map(\.raw))
            alternative.ambiguousDateTokens = []
            alternative.ambiguousFunctionTokens = []
            alternative.ambiguousTerms = []
            if longFollowsPlace {
                alternative.placeTerms.append(TripSearchTerm(raw: "long", alternatives: [["long"]]))
                alternative.strictWholeWordTerms = Set(alternative.placeTerms.map(\.raw))
                alternative.longFollowsPlace = false
            }
            return alternative
        }
    }

    // MARK: - Resolver

    /// Most words the partial fallback considers; longer queries (pasted
    /// text) get no fallback, which bounds the engine passes per keystroke.
    static let maxFallbackTerms = 8

    /// The shared local search. Order = index order; each match carries its
    /// strength. An empty or whitespace query returns nothing (callers show
    /// every trip without searching). `allowsTrailingPartial` is true only
    /// while the user is still typing the last word (the list, when the
    /// field does not end in a separator); Siri and Shortcuts pass false.
    static func searchTrips(
        index: TripSearchIndex,
        query: String,
        allowsTrailingPartial: Bool,
        now: Date = .now,
        calendar: Calendar = TripFilters.yearCalendar,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> [TripSearchMatch] {
        guard !index.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard allowsTrailingPartial, !TripSearchText.endsWithSeparator(query) else {
            return resolve(index: index, query: query, now: now, calendar: calendar, languageTag: languageTag, typing: false)
        }
        // A typed filler kept as a place prefix (`rome in` → India) or a
        // completion can leave only partial matches where the finished
        // words match fully, and a filler that also matches a title word
        // (`japan in` → Autumn in Kyoto) can narrow the finished reading's
        // trips; then the finished reading wins. The second resolve runs
        // only when the typed reading has no full match or kept a filler.
        let typedParse = parse(query, now: now, calendar: calendar, languageTag: languageTag, typing: index)
        let typed = resolve(index: index, parsed: typedParse, query: query, calendar: calendar, languageTag: languageTag)
        let typedFull = fullMatches(typed)
        guard typedFull.isEmpty || typedParse.typedFillerIsPlace else { return typed }
        let finished = resolve(index: index, query: query, now: now, calendar: calendar, languageTag: languageTag, typing: false)
        let finishedFull = fullMatches(finished)
        if typedFull.isEmpty { return finishedFull.isEmpty ? typed : finished }
        return typedFull.isStrictSubset(of: finishedFull) ? finished : typed
    }

    /// Documents with a strong or similar match.
    private static func fullMatches(_ matches: [TripSearchMatch]) -> Set<Int> {
        Set(matches.filter { $0.strength != .partial }.map(\.documentIndex))
    }

    private static func resolve(
        index: TripSearchIndex,
        query: String,
        now: Date,
        calendar: Calendar,
        languageTag: String,
        typing: Bool
    ) -> [TripSearchMatch] {
        let parsed = parse(query, now: now, calendar: calendar, languageTag: languageTag, typing: typing ? index : nil)
        return resolve(index: index, parsed: parsed, query: query, calendar: calendar, languageTag: languageTag)
    }

    private static func resolve(
        index: TripSearchIndex,
        parsed: ParsedQuery,
        query: String,
        calendar: Calendar,
        languageTag: String
    ) -> [TripSearchMatch] {
        if let reading = parsed.placeInterpretation {
            let places = placeReading(reading, index: index, calendar: calendar)
            if !places.isEmpty { return places }
        }

        var fuzzy: [TripSearchMatch] = []
        var fuzzyTerms = TripSearch.terms(parsed.fuzzyText, languageTag: languageTag, allowsTrailingPartial: false)
        if !fuzzyTerms.isEmpty {
            if parsed.fuzzyTextEndsInTypedWord { fuzzyTerms[fuzzyTerms.count - 1].isTrailingPartial = true }
            fuzzy = TripSearch.match(terms: fuzzyTerms, in: index)
            if parsed.consumedSyntax {
                var constraints = ParsedQuery()
                constraints.dates = parsed.consumedDates
                constraints.minDurationDays = parsed.consumedMinDurationDays
                constraints.maxDurationDays = parsed.consumedMaxDurationDays
                fuzzy = fuzzy.filter {
                    matchesFilters(index.documents[$0.documentIndex], parsed: constraints, calendar: calendar)
                }
            }
        }

        let merged = parsed.isClaimable
            ? merge(fuzzy, filter(index: index, parsed: parsed, calendar: calendar))
            : fuzzy
        if !merged.isEmpty { return merged }
        return partialMatches(parsed, index: index, query: query, calendar: calendar, languageTag: languageTag)
    }

    /// The structured pass: documents satisfying a date clause (winter
    /// wraps per year), the durations and every place term. Strict terms
    /// must be whole words of the document; the others go through the engine
    /// over every field, whose strength and evidence the match keeps.
    static func filter(
        index: TripSearchIndex,
        parsed: ParsedQuery,
        calendar: Calendar = TripFilters.yearCalendar,
        placeReading: Bool = false
    ) -> [TripSearchMatch] {
        let strict = parsed.placeTerms.filter { parsed.strictWholeWordTerms.contains($0.raw) }
        let loose = parsed.placeTerms.filter { !parsed.strictWholeWordTerms.contains($0.raw) }
        let engine = loose.isEmpty ? nil : (placeReading
            ? TripSearch.match(terms: loose, in: index, fields: [.place, .region, .country])
            : TripSearch.match(terms: loose, in: index))
        var result: [TripSearchMatch] = []
        for offset in 0..<(engine?.count ?? index.documents.count) {
            let match = engine?[offset] ?? TripSearchMatch(documentIndex: offset, strength: .strong, evidence: [])
            let position = match.documentIndex
            let document = index.documents[position]
            guard matchesFilters(document, parsed: parsed, calendar: calendar) else { continue }
            if !strict.isEmpty {
                let words = placeReading ? index.strictPlaceWords(of: position) : index.wholeWords(of: position)
                guard strict.allSatisfy({ isWholeWordMatch($0, words: words, codes: document.countryCodes) })
                else { continue }
            }
            result.append(match)
        }
        return result
    }

    /// Date clauses and durations only (no place terms). Like
    /// `SearchTripsTool.matches`, durations AND-combine with the dates and
    /// require a non-nil duration; the date clauses OR-combine, each pairing
    /// its own months and years. A season that crosses New Year wraps the way
    /// a human means it: "winter 2024" is Dec 2024 to Feb 2025. Unlike the
    /// tool, which tests the start only, a clause matches any civil month
    /// covered through the end date (read in the document's calendar).
    static func matchesFilters(
        _ document: TripSearchDocument,
        parsed: ParsedQuery,
        calendar: Calendar = TripFilters.yearCalendar
    ) -> Bool {
        if let minDays = parsed.minDurationDays {
            guard let days = document.durationDays, days >= minDays else { return false }
        }
        if let maxDays = parsed.maxDurationDays {
            guard let days = document.durationDays, days <= maxDays else { return false }
        }
        guard !parsed.dates.isEmpty else { return true }
        if parsed.dates.matches(year: document.startYear, month: document.startMonth) { return true }
        guard let end = document.endDate else { return false }
        let components = calendar.dateComponents([.year, .month], from: end)
        guard let year = components.year, let month = components.month else { return false }
        if parsed.dates.matches(year: year, month: month) { return true }
        let firstMonth = document.startYear * 12 + document.startMonth - 1
        let lastMonth = year * 12 + month - 1
        guard firstMonth < lastMonth else { return false }
        // Compare month intervals rather than walking potentially decades-long trips.
        return parsed.dates.effectiveClauses.contains { clause in
            if clause.months.isEmpty {
                return clause.years.isEmpty || clause.years.contains { year in
                    year * 12 <= lastMonth && year * 12 + 11 >= firstMonth
                }
            }
            return clause.months.contains { dateMonth in
                if clause.years.isEmpty {
                    let offset = (dateMonth.month - document.startMonth + 12) % 12
                    return firstMonth + offset <= lastMonth
                }
                return clause.years.contains { year in
                    let candidate = (year + dateMonth.yearOffset) * 12 + dateMonth.month - 1
                    return candidate >= firstMonth && candidate <= lastMonth
                }
            }
        }
    }

    /// Step 2 of the resolver: the ambiguous words as place text, matched on
    /// place, region and country only (never titles or dates, which would
    /// let "Japan in Spring" claim `spring`). Loose terms keep the engine's
    /// typo tolerance; strict terms must be whole words.
    private static func placeReading(
        _ reading: ParsedQuery,
        index: TripSearchIndex,
        calendar: Calendar
    ) -> [TripSearchMatch] {
        let result = filter(index: index, parsed: reading, calendar: calendar,
                            placeReading: true)
        guard !result.isEmpty else { return [] }
        // Evidence over every field, so a word the title also shows gets no caption.
        let evidence = byDocument(TripSearch.match(terms: reading.placeTerms, in: index))
        return result.map { match in
            var match = match
            if let full = evidence[match.documentIndex] { match.evidence = full.evidence }
            return match
        }
    }

    /// Step 7: nothing matched every word. First drop dates, durations and
    /// numbers and match the remaining words; failing that, keep the trips
    /// that match the most remaining words (at least one). All partial.
    private static func partialMatches(
        _ parsed: ParsedQuery,
        index: TripSearchIndex,
        query: String,
        calendar: Calendar,
        languageTag: String
    ) -> [TripSearchMatch] {
        let count = TripSearch.terms(query, languageTag: languageTag, allowsTrailingPartial: false).count
        guard (2...maxFallbackTerms).contains(count) else { return [] }
        var reduced = ParsedQuery()
        reduced.placeTerms = parsed.placeTerms.filter { !$0.isNumeric }
        reduced.strictWholeWordTerms = parsed.strictWholeWordTerms
        guard !reduced.placeTerms.isEmpty else { return [] }

        func partial(_ matches: [TripSearchMatch]) -> [TripSearchMatch] {
            matches.map { TripSearchMatch(documentIndex: $0.documentIndex, strength: .partial, evidence: $0.evidence) }
        }
        let dropped = parsed.hasStructuredFilter || reduced.placeTerms.count != parsed.placeTerms.count
        if dropped {
            let remaining = filter(index: index, parsed: reduced, calendar: calendar)
            if !remaining.isEmpty { return partial(remaining) }
        }

        guard reduced.placeTerms.count >= 2 else { return [] }
        var hits: [Int: (count: Int, evidence: [TripSearchEvidence])] = [:]
        for term in reduced.placeTerms {
            var single = reduced
            single.placeTerms = [term]
            for match in filter(index: index, parsed: single, calendar: calendar) {
                let previous = hits[match.documentIndex] ?? (0, [])
                hits[match.documentIndex] = (previous.count + 1, previous.evidence + match.evidence)
            }
        }
        guard let best = hits.values.map(\.count).max() else { return [] }
        return hits.filter { $0.value.count == best }
            .map { TripSearchMatch(documentIndex: $0.key, strength: .partial, evidence: $0.value.evidence) }
            .sorted { $0.documentIndex < $1.documentIndex }
    }

    /// Union by document, keeping the better strength; equal strengths keep
    /// the structured evidence (place words, no filler). Index order.
    private static func merge(_ fuzzy: [TripSearchMatch], _ structured: [TripSearchMatch]) -> [TripSearchMatch] {
        var best = byDocument(fuzzy)
        for match in structured {
            if let existing = best[match.documentIndex], existing.strength < match.strength { continue }
            best[match.documentIndex] = match
        }
        return best.values.sorted { $0.documentIndex < $1.documentIndex }
    }

    private static func byDocument(_ matches: [TripSearchMatch]) -> [Int: TripSearchMatch] {
        Dictionary(matches.map { ($0.documentIndex, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A term as whole words: every sub-token of one literal or alias
    /// alternative is a word, or its region/country codes intersect.
    private static func isWholeWordMatch(_ term: TripSearchTerm, words: Set<String>, codes: Set<String>) -> Bool {
        term.alternatives.contains { !$0.isEmpty && $0.allSatisfy(words.contains) }
            || term.aliasAlternatives.contains { !$0.isEmpty && $0.allSatisfy(words.contains) }
            || !term.countryCodes.isDisjoint(with: codes)
    }

    // MARK: - Parsing

    /// Localized parse. `languageTag` selects the month, season, weekend,
    /// relative-date and filler vocabulary; English is always active too.
    static func parse(
        _ query: String,
        now: Date = .now,
        calendar: Calendar = TripFilters.yearCalendar,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> ParsedQuery {
        parse(query, now: now, calendar: calendar, languageTag: languageTag, typing: nil)
    }

    /// `typing` is the index when the last word is still being typed: it
    /// enables trailing completion (`summ` → summer) and keeps a trailing
    /// filler word that starts a place name (`war` → Warsaw).
    private static func parse(
        _ query: String,
        now: Date,
        calendar: Calendar,
        languageTag: String,
        typing: TripSearchIndex?
    ) -> ParsedQuery {
        let lexicon = lexicon(for: languageTag)
        var working = fold(query)
        if let suffixes = lexicon.apostropheSuffixes {
            working = suffixes.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "")
        }
        var scan = Scan(
            units: units(of: working),
            lexicon: lexicon,
            nowYear: calendar.component(.year, from: now),
            nowMonth: calendar.component(.month, from: now))
        if let index = typing { scan.completeTypedWord(index: index) }
        scan.consumeDurations()
        scan.consumeLongFiller()
        scan.consumeWeekends()
        scan.consumeDatesWithYear()
        scan.consumeFrames()
        scan.consumeRelativePhrases()
        scan.consumeRecentSeasons()
        // Before bare date words: French `ai été` is "have been", not summer.
        scan.consumeFillerPhrases()
        scan.consumeBareDateWords()
        scan.classifyRemaining(typing: typing)
        return scan.result(languageTag: languageTag, isTyping: typing != nil)
    }

    /// Lowercased, diacritic- and width-folded working text (fullwidth
    /// digits become ASCII, `tháng` becomes `thang`).
    private static func fold(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Units

    /// One word of the working text: a raw token, one CFStringTokenizer
    /// segment of a Han or kana token, or a numeric date pattern.
    private struct Unit {
        enum Special: Equatable {
            case year(Int)
            case years([Int])
            case month(Int)
            case minDays(Int)
        }

        enum Role: Equatable {
            case open
            /// Place text (a residual term).
            case place
            /// Consumed; the engine pass still sees the word.
            case kept
            /// Noise; the engine pass sees it only when the parse does not
            /// claim the query (then the structured pass covers the rest).
            case filler
            /// Consumed by date or duration syntax; hidden from the engine pass.
            case removed
        }

        let text: String
        /// Native normalized form (`TripSearch.normalizedSearchForms`).
        var key: String
        let token: Int
        var special: Special?
        var role: Role = .open
    }

    /// Numeric patterns first (CJK has no word breaks and `+` / `-` are
    /// separators), then raw tokens of the gaps, Han and kana split into
    /// segments so `去年の夏` reads as 去年 / の / 夏.
    private static func units(of working: String) -> [Unit] {
        var specials: [(range: Range<String.Index>, special: Unit.Special)] = []
        func scan(_ regex: NSRegularExpression?, _ make: ([String]) -> Unit.Special?) {
            guard let regex else { return }
            for match in regex.matches(in: working, range: NSRange(working.startIndex..., in: working)) {
                guard let range = Range(match.range, in: working),
                      !specials.contains(where: { $0.range.overlaps(range) })
                else { continue }
                let groups = (1..<match.numberOfRanges).compactMap { group in
                    Range(match.range(at: group), in: working).map { String(working[$0]) }
                }
                if let special = make(groups) { specials.append((range, special)) }
            }
        }
        scan(Regexes.yearRange) { groups in
            guard groups.count == 2, let first = Int(groups[0]), let second = Int(groups[1]) else { return nil }
            let low = min(first, second), high = max(first, second)
            return .years(high - low <= 10 ? Array(low...high) : [low, high])
        }
        scan(Regexes.plusDuration) { groups in
            guard groups.count == 2, let unit = durationUnitDays(groups[1]) else { return nil }
            let count = Int(groups[0]) ?? Int.max
            return .minDays(clampedProduct(count, unit))
        }
        let numerals = TripQueryVocabulary.hanMonthNumerals
        scan(Regexes.hanMonth) { groups in
            numerals.first { $0.word == groups.first }.map { Unit.Special.month($0.month) }
        }
        scan(Regexes.cjkYear) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.year($0) } }
        scan(Regexes.cjkMonth) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.month($0) } }
        scan(Regexes.vietnameseMonth) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.month($0) } }
        specials.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result: [Unit] = []
        var token = 0
        func addWords(_ text: Substring) {
            for raw in TripSearchText.rawTokens(String(text)) {
                let pieces = unitKeys(TripSearch.normalizedSearchForms(raw.text).first ?? "")
                guard !pieces.isEmpty else { continue }
                if pieces.count == 1 {
                    result.append(Unit(text: raw.text, key: pieces[0], token: token))
                } else {
                    result.append(contentsOf: pieces.map { Unit(text: $0, key: $0, token: token) })
                }
                token += 1
            }
        }
        var cursor = working.startIndex
        for (range, special) in specials {
            addWords(working[cursor..<range.lowerBound])
            result.append(Unit(text: String(working[range]), key: "", token: token, special: special, role: .open))
            token += 1
            cursor = range.upperBound
        }
        addWords(working[cursor...])
        return result
    }

    /// Words of a normalized form, Han and kana words split into segments.
    private static func unitKeys(_ normalized: String) -> [String] {
        TripSearchText.words(normalized).flatMap { word -> [String] in
            guard word.unicodeScalars.contains(where: { TripSearchText.isHanOrKana($0.value) }) else { return [word] }
            return TripSearchText.segmentCJK(word)
        }
    }

    /// The numeric date patterns, compiled once (compiling them per parse
    /// cost most of a keystroke's resolver time).
    private enum Regexes {
        typealias Pattern = TripQueryVocabulary.NumericPattern
        static let yearRange = compile(Pattern.yearRange)
        static let plusDuration = compile(Pattern.plusDuration)
        static let hanMonth = compile(
            "(" + TripQueryVocabulary.hanMonthNumerals.map(\.word).joined(separator: "|") + ")")
        static let cjkYear = compile(Pattern.cjkYear)
        static let cjkMonth = compile(Pattern.cjkMonth)
        static let vietnameseMonth = compile(Pattern.vietnameseMonth)

        static func compile(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        static func prewarm() {
            _ = [yearRange, plusDuration, hanMonth, cjkYear, cjkMonth, vietnameseMonth]
        }
    }

    private static func durationUnitDays(_ key: String) -> Int? {
        TripQueryVocabulary.englishDurationUnits[key]
    }

    private static func clampedProduct(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int.max : product
    }

    // MARK: - Scan

    private struct Scan {
        var units: [Unit]
        let lexicon: Lexicon
        let nowYear: Int
        let nowMonth: Int
        var parsed = ParsedQuery()
        /// Ambiguous words by unit position (date words, then function words).
        var ambiguous: [(position: Int, text: String, isFunction: Bool)] = []
        var functionCandidates: [Int] = []
        var unitBeforeLong: Int?

        init(units: [Unit], lexicon: Lexicon, nowYear: Int, nowMonth: Int) {
            self.units = units
            self.lexicon = lexicon
            self.nowYear = nowYear
            self.nowMonth = nowMonth
        }

        // MARK: Matching helpers

        func isOpenWord(_ position: Int) -> Bool {
            position >= 0 && position < units.count
                && units[position].role == .open && units[position].special == nil
        }

        func matches(_ keys: [String], at position: Int) -> Bool {
            guard position + keys.count <= units.count else { return false }
            for (offset, key) in keys.enumerated() {
                guard isOpenWord(position + offset), units[position + offset].key == key else { return false }
            }
            return true
        }

        func longest<Value: Sendable>(_ table: PhraseTable<Value>, at position: Int) -> PhraseTable<Value>.Entry? {
            guard isOpenWord(position) else { return nil }
            return table.candidates(units[position].key).first { matches($0.keys, at: position) }
        }

        func text(_ range: Range<Int>) -> String {
            units[range].map(\.text).joined(separator: " ")
        }

        mutating func mark(_ range: Range<Int>, _ role: Unit.Role) {
            for position in range { units[position].role = role }
        }

        /// Years of a bare 4-digit word, a `2024年` pattern or a range.
        func years(at position: Int) -> [Int]? {
            guard position >= 0, position < units.count, units[position].role == .open else { return nil }
            switch units[position].special {
            case .year(let year): return [year]
            case .years(let years): return years
            case nil:
                let key = units[position].key
                guard key.count == 4, key.allSatisfy(\.isASCII), let year = Int(key), (1900...2099).contains(year)
                else { return nil }
                return [year]
            default: return nil
            }
        }

        /// A month or season word usable as a slot (bare and recent/current
        /// season forms excluded as noted by the caller).
        func slot(at position: Int, allowAnchorRequired: Bool) -> (length: Int, value: DateWord)? {
            // A numeric month (`7월`, `tháng 7`) is the only month form some
            // languages have, so frames take it too (`지난 7월`, `tháng 7 này`).
            if position >= 0, position < units.count, units[position].role == .open,
               case .month(let month)? = units[position].special {
                return (1, .month(month))
            }
            if let season = longest(lexicon.seasons, at: position),
               season.value.kind == .plain || (allowAnchorRequired && season.value.kind == .anchorRequired) {
                return (season.keys.count, .season(season.value))
            }
            if let month = longest(lexicon.months, at: position) {
                return (month.keys.count, .month(month.value))
            }
            return nil
        }

        // MARK: Filter setters

        mutating func setMin(_ value: Int, consumed: Bool = true) {
            parsed.minDurationDays = max(parsed.minDurationDays ?? value, value)
            if consumed { parsed.consumedMinDurationDays = max(parsed.consumedMinDurationDays ?? value, value) }
        }

        mutating func setMax(_ value: Int, consumed: Bool = true) {
            parsed.maxDurationDays = min(parsed.maxDurationDays ?? value, value)
            if consumed { parsed.consumedMaxDurationDays = min(parsed.consumedMaxDurationDays ?? value, value) }
        }

        /// A month or season word that syntax paired with its years. An
        /// ambiguous clause (a recent-season word) stays visible to the
        /// engine pass and is dropped by the place reading.
        mutating func addClause(_ word: DateWord, years: [Int], ambiguous: Bool = false) {
            let clause = DateClause(months: word.datedMonths, years: Set(years))
            parsed.dates.clauses.append(clause)
            guard !ambiguous else { return }
            parsed.unambiguousDates.clauses.append(clause)
            parsed.consumedDates.clauses.append(clause)
        }

        /// Years no month word is paired with. Every reading keeps them;
        /// `consumed` ones are hidden from the engine pass, which must
        /// then respect them.
        mutating func addLooseYears(_ years: [Int], consumed: Bool) {
            parsed.dates.looseYears.formUnion(years)
            parsed.unambiguousDates.looseYears.formUnion(years)
            if consumed { parsed.consumedDates.looseYears.formUnion(years) }
        }

        /// A month or season word no year is paired with. `anchored` ones
        /// (`in summer`, `7月`) are consumed syntax; bare words are
        /// ambiguous, so the place reading drops them.
        mutating func addLooseMonths(_ word: DateWord, anchored: Bool) {
            let months = word.datedMonths
            parsed.dates.looseMonths.formUnion(months)
            guard anchored else { return }
            parsed.unambiguousDates.looseMonths.formUnion(months)
            parsed.consumedDates.looseMonths.formUnion(months)
        }

        /// The year of the most recent completed season.
        func lastYear(of season: Season) -> Int {
            if season.months == [12, 1, 2] {
                // Winters are labeled by their December year; the winter that
                // ended Feb `y` is winter `y-1`. Mid-winter (Jan/Feb), the
                // last COMPLETED one ended the previous February.
                return nowMonth >= 3 ? nowYear - 1 : nowYear - 2
            }
            return nowMonth > season.finalMonth ? nowYear : nowYear - 1
        }

        func thisYear(of season: Season) -> Int {
            season.months == [12, 1, 2] && nowMonth <= 2 ? nowYear - 1 : nowYear
        }

        // MARK: Phases

        /// `summ` → summer while typing, when the prefix names exactly one
        /// season, weekend or month and no trip has a word or place that
        /// starts with it. A duration unit is a finished word: `a week`
        /// never becomes `a weekend`, nor `eine Woche` `Wochenende`; after
        /// a count, neither does a unit's prefix (`eine Woch`, `2 wee`).
        mutating func completeTypedWord(index: TripSearchIndex) {
            guard let last = units.indices.last, isOpenWord(last),
                  units[last].token == units.map(\.token).max() else { return }
            let key = units[last].key
            guard key.count >= 3, key.allSatisfy(\.isLetter), !lexicon.isVocabulary(key),
                  TripQueryVocabulary.englishDurationUnits[key] == nil,
                  !TripQueryVocabulary.weekDurationNouns.contains(key),
                  !(isCount(at: last - 1) && isDurationUnitPrefix(key)),
                  !index.containsWord(key), index.strictPlaceWords(withPrefix: key).isEmpty,
                  let completion = lexicon.completion(for: key)
            else { return }
            units[last].key = completion
        }

        /// A count: digits that are not a year, an English number word or an article.
        func isCount(at position: Int) -> Bool {
            guard isOpenWord(position) else { return false }
            let key = units[position].key
            if !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) { return years(at: position) == nil }
            return TripQueryVocabulary.countArticles.contains(key)
                || TripQueryVocabulary.englishNumberWords[key] != nil
        }

        func isDurationUnitPrefix(_ key: String) -> Bool {
            TripQueryVocabulary.englishDurationUnits.keys.contains { $0.hasPrefix(key) }
                || TripQueryVocabulary.weekDurationNouns.contains { $0.hasPrefix(key) }
        }

        mutating func consumeDurations() {
            var position = 0
            while position < units.count {
                if let length = duration(at: position) {
                    mark(position..<(position + length), .removed)
                    parsed.consumedSyntax = true
                    position += length
                } else {
                    position += 1
                }
            }
        }

        /// A number (digits, English words, `a` / `an`) and a unit word:
        /// total days and the ± tolerance (a seventh for weeks and
        /// fortnights, none for days).
        func quantity(at position: Int) -> (days: Int, tolerance: Int, length: Int)? {
            guard isOpenWord(position) else { return nil }
            var count: Int?
            var length = 1
            let key = units[position].key
            if !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) {
                count = Int(key) ?? Int.max
            } else if key == "a" || key == "an" {
                count = 1
            } else if isOpenWord(position + 1),
                      let pair = TripQueryVocabulary.englishNumberWords[key + " " + units[position + 1].key] {
                count = pair
                length = 2
            } else {
                count = TripQueryVocabulary.englishNumberWords[key]
            }
            guard let count, isOpenWord(position + length),
                  let unit = durationUnitDays(units[position + length].key)
            else { return nil }
            let days = clampedProduct(count, unit)
            return (days, unit >= 7 ? days / 7 : 0, length + 1)
        }

        /// Duration phrases in the FM tool's min/max semantics. Returns the
        /// number of words consumed at `position`.
        mutating func duration(at position: Int) -> Int? {
            func comparative(_ prefixes: [[String]]) -> (days: Int, length: Int)? {
                for prefix in prefixes where matches(prefix, at: position) {
                    if let amount = quantity(at: position + prefix.count) {
                        return (amount.days, prefix.count + amount.length)
                    }
                }
                return nil
            }
            // `n == Int.max` parses fine ("more than 9223372036854775807 days")
            // and `n + 1` would trap: clamp instead of overflowing.
            if let hit = comparative([["longer", "than"], ["more", "than"], ["over"]]) {
                setMin(hit.days == Int.max ? hit.days : hit.days + 1)
                return hit.length
            }
            if let hit = comparative([["shorter", "than"], ["less", "than"], ["under"]]) {
                setMax(hit.days - 1)
                return hit.length
            }
            if let hit = comparative([["at", "least"]]) {
                setMin(hit.days)
                return hit.length
            }
            if let hit = comparative([["at", "most"], ["up", "to"]]) {
                setMax(hit.days)
                return hit.length
            }
            if let amount = quantity(at: position) {
                let tail = position + amount.length
                if matches(["or", "more"], at: tail) || matches(["or", "longer"], at: tail) {
                    setMin(amount.days)
                    return amount.length + 2
                }
                if matches(["or", "less"], at: tail) || matches(["or", "fewer"], at: tail)
                    || matches(["or", "shorter"], at: tail) {
                    setMax(amount.days)
                    return amount.length + 2
                }
            }
            if matches(["week", "long"], at: position) {
                setMin(6)
                setMax(8)
                return 2
            }
            if matches(["weeklong"], at: position) {
                setMin(6)
                setMax(8)
                return 1
            }
            if matches(["day", "trip"], at: position) || matches(["day", "trips"], at: position) {
                setMax(1)
                return 2
            }
            if let amount = quantity(at: position) {
                setMin(amount.days - amount.tolerance)
                setMax(amount.days > Int.max - amount.tolerance ? Int.max : amount.days + amount.tolerance)
                return amount.length
            }
            if matches(["fortnight"], at: position) || matches(["fortnights"], at: position) {
                setMin(12)
                setMax(16)
                return 1
            }
            return nil
        }

        /// "long" is filler only before a trip noun or "weekend"; elsewhere it
        /// is place text (Long Beach, Ha Long). Remember the word before it:
        /// after place text ("Ha Long trips") the place reading tries "long" first.
        mutating func consumeLongFiller() {
            for position in units.indices where isOpenWord(position) && units[position].key == "long" {
                guard isOpenWord(position + 1), longTargets.contains(units[position + 1].key) else { continue }
                units[position].role = .filler
                parsed.droppedNoise = true
                unitBeforeLong = units[..<position].lastIndex { $0.role != .removed }
            }
        }

        mutating func consumeWeekends() {
            for position in units.indices {
                guard let entry = longest(lexicon.weekends, at: position) else { continue }
                mark(position..<(position + entry.keys.count), .kept)
                setMin(2, consumed: false)
                setMax(3, consumed: false)
            }
        }

        /// `<month or season> <year>` and `<year> <month or season>`, with an
        /// optional connector (`summer of 2024`, `verano de 2024`). Explicit
        /// temporal syntax; a place word between them (`Winter Park 2025`)
        /// prevents it.
        mutating func consumeDatesWithYear() {
            for position in units.indices {
                if let slot = slot(at: position, allowAnchorRequired: true) {
                    var yearPosition = position + slot.length
                    if isOpenWord(yearPosition), lexicon.yearConnectors.contains(units[yearPosition].key),
                       years(at: yearPosition + 1) != nil {
                        yearPosition += 1
                    }
                    if let years = years(at: yearPosition) {
                        addClause(slot.value, years: years)
                        mark(position..<(yearPosition + 1), .removed)
                        parsed.consumedSyntax = true
                        continue
                    }
                }
                if let years = years(at: position), let slot = slot(at: position + 1, allowAnchorRequired: true) {
                    addClause(slot.value, years: years)
                    mark(position..<(position + 1 + slot.length), .removed)
                    parsed.consumedSyntax = true
                }
            }
        }

        /// `last <season or month>`, `this <season or month>` and
        /// `in <season or month>` in every word order the vocabulary lists.
        /// Last and this frames claim their slots first, so an earlier
        /// in-frame cannot strand a suffix anchor (`pendant l'été dernier`).
        mutating func consumeFrames() {
            for anchored in [true, false] {
                for position in units.indices {
                    for frame in lexicon.frames
                    where (frame.kind != .inside) == anchored && matches(frame.before, at: position) {
                        let slotPosition = position + frame.before.count
                        guard let slot = slot(at: slotPosition, allowAnchorRequired: true),
                              matches(frame.after, at: slotPosition + slot.length)
                        else { continue }
                        apply(frame.kind, slot.value)
                        mark(position..<(slotPosition + slot.length + frame.after.count), .removed)
                        parsed.consumedSyntax = true
                        break
                    }
                }
            }
        }

        mutating func apply(_ kind: FrameKind, _ word: DateWord) {
            switch (kind, word) {
            case (.inside, _):
                addLooseMonths(word, anchored: true)
                parsed.droppedNoise = true
            case (.last, .season(let season)):
                addClause(word, years: [lastYear(of: season)])
            case (.this, .season(let season)):
                addClause(word, years: [thisYear(of: season)])
            case (.last, .month(let month)):
                // An anchor makes a month name unambiguously temporal. `last
                // May` means the most recent completed May; `this May` means May
                // in the current calendar year even when queried later.
                addClause(word, years: [nowMonth > month ? nowYear : nowYear - 1])
            case (.this, .month):
                addClause(word, years: [nowYear])
            }
        }

        mutating func consumeRelativePhrases() {
            for position in units.indices {
                guard let entry = longest(lexicon.relative, at: position) else { continue }
                switch entry.value {
                case .lastYear:
                    addLooseYears([nowYear - 1], consumed: true)
                case .thisYear:
                    addLooseYears([nowYear], consumed: true)
                case .lastMonth:
                    addClause(
                        .month(nowMonth == 1 ? 12 : nowMonth - 1),
                        years: [nowMonth == 1 ? nowYear - 1 : nowYear])
                }
                mark(position..<(position + entry.keys.count), .removed)
                parsed.consumedSyntax = true
            }
        }

        /// Words that alone mean last or this season (Swedish `i somras`,
        /// Korean `지난여름`). Still place-first: `våras` is Puerto Varas.
        mutating func consumeRecentSeasons() {
            for position in units.indices {
                guard let entry = longest(lexicon.seasons, at: position),
                      entry.value.kind == .recent || entry.value.kind == .current else { continue }
                let range = position..<(position + entry.keys.count)
                let year = entry.value.kind == .recent ? lastYear(of: entry.value) : thisYear(of: entry.value)
                addClause(.season(entry.value), years: [year], ambiguous: true)
                ambiguous.append((position, text(range), false))
                mark(range, .kept)
            }
        }

        /// Bare season and month words: a filter, and also an ambiguous word
        /// the place reading tries first. Singular only: plural forms
        /// ("Palm Springs", "Idaho Falls") are overwhelmingly place names and
        /// are not in the vocabulary. A one-character Han season (夏, 春)
        /// counts only as a whole segment next to date or filler words, never
        /// inside a name such as 夏威夷 or 秋田.
        mutating func consumeBareDateWords() {
            for position in units.indices {
                if let season = longest(lexicon.seasons, at: position), season.value.kind == .plain {
                    if season.keys.count == 1, isSingleHan(units[position].key),
                       !hasDateContext(around: position) { continue }
                    let range = position..<(position + season.keys.count)
                    addLooseMonths(.season(season.value), anchored: false)
                    ambiguous.append((position, text(range), false))
                    mark(range, .kept)
                } else if let month = longest(lexicon.months, at: position) {
                    let range = position..<(position + month.keys.count)
                    addLooseMonths(.month(month.value), anchored: false)
                    ambiguous.append((position, text(range), false))
                    mark(range, .kept)
                }
            }
        }

        func isSingleHan(_ key: String) -> Bool {
            key.unicodeScalars.count == 1 && key.unicodeScalars.allSatisfy { TripSearchText.isHanOrKana($0.value) }
        }

        /// Neighbours inside the same raw token are date syntax or vocabulary.
        func hasDateContext(around position: Int) -> Bool {
            for neighbour in [position - 1, position + 1] where neighbour >= 0 && neighbour < units.count {
                guard units[neighbour].token == units[position].token else { continue }
                let unit = units[neighbour]
                if unit.special != nil || unit.key.allSatisfy(\.isNumber) || lexicon.contextKeys.contains(unit.key) {
                    continue
                }
                return false
            }
            return true
        }

        mutating func consumeFillerPhrases() {
            for position in units.indices {
                guard let entry = longest(lexicon.fillerPhrases, at: position) else { continue }
                mark(position..<(position + entry.keys.count), .filler)
                parsed.droppedNoise = true
            }
        }

        /// Numeric patterns, bare years, filler and function words; the rest
        /// is place text.
        mutating func classifyRemaining(typing: TripSearchIndex?) {
            let lastToken = units.map(\.token).max()
            for position in units.indices where units[position].role == .open {
                switch units[position].special {
                case .year(let year):
                    addLooseYears([year], consumed: true)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .years(let years):
                    addLooseYears(years, consumed: true)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .month(let month):
                    addLooseMonths(.month(month), anchored: true)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .minDays(let days):
                    setMin(days)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case nil:
                    break
                }
                let key = units[position].key
                if let years = years(at: position) {
                    // A bare year stays visible to the engine pass, whose
                    // end-date words find trips spanning New Year.
                    addLooseYears(years, consumed: false)
                    units[position].role = .kept
                    continue
                }
                // A year connector before a year is noise (`năm 2024`, `of 2024`).
                let isFiller = lexicon.filler.contains(key)
                    || (lexicon.yearConnectors.contains(key) && years(at: position + 1) != nil)
                let isFunction = lexicon.ambiguousFunction.contains(key)
                guard isFiller || isFunction else {
                    units[position].role = .place
                    continue
                }
                // A filler word being typed may be the start of a place (`war` → Warsaw).
                if let index = typing, position == units.count - 1, units[position].token == lastToken,
                   !index.strictPlaceWords(withPrefix: key).isEmpty {
                    units[position].role = .place
                    parsed.typedFillerIsPlace = true
                    continue
                }
                units[position].role = .filler
                parsed.droppedNoise = true
                if isFunction { functionCandidates.append(position) }
            }
        }

        mutating func result(languageTag: String, isTyping: Bool) -> ParsedQuery {
            let ambiguousDatePositions = Set(ambiguous.map(\.position))
            for position in functionCandidates {
                let nextToPlace = [position - 1, position + 1].contains { neighbour in
                    neighbour >= 0 && neighbour < units.count
                        && (units[neighbour].role == .place || ambiguousDatePositions.contains(neighbour))
                }
                if nextToPlace { ambiguous.append((position, units[position].text, true)) }
            }
            ambiguous.sort { $0.position < $1.position }

            if let before = unitBeforeLong, units[before].role == .place {
                parsed.longFollowsPlace = true
            }

            let lastToken = units.map(\.token).max()
            let places = units.indices.filter { units[$0].role == .place }
            parsed.placeTerms = TripSearch.terms(
                places.map { units[$0].text }.joined(separator: " "),
                languageTag: languageTag,
                allowsTrailingPartial: false)
            if isTyping, let last = places.last, last == units.count - 1, units[last].token == lastToken,
               !parsed.placeTerms.isEmpty {
                parsed.placeTerms[parsed.placeTerms.count - 1].isTrailingPartial = true
            }

            for entry in ambiguous {
                let terms = TripSearch.terms(entry.text, languageTag: languageTag, allowsTrailingPartial: false)
                parsed.ambiguousTerms.append(contentsOf: terms)
                if entry.isFunction {
                    parsed.ambiguousFunctionTokens.append(entry.text)
                } else {
                    parsed.ambiguousDateTokens.append(entry.text)
                }
            }

            // The engine pass sees every word except consumed date and
            // duration syntax, and except noise when the query is claimed
            // (so `trips in 2024` still finds the trip spanning New Year);
            // a Han token keeps its remaining segments joined.
            let hidesFiller = parsed.isClaimable
            func isHidden(_ unit: Unit) -> Bool {
                unit.role == .removed || (hidesFiller && unit.role == .filler)
            }
            var tokens: [String] = []
            var currentToken: Int?
            for unit in units {
                let piece = isHidden(unit) ? "" : unit.text
                if unit.token == currentToken {
                    tokens[tokens.count - 1] += piece
                } else {
                    tokens.append(piece)
                    currentToken = unit.token
                }
            }
            parsed.fuzzyText = tokens.filter { !$0.isEmpty }.joined(separator: " ")
            if isTyping, let lastToken {
                parsed.fuzzyTextEndsInTypedWord = !units.contains { $0.token == lastToken && isHidden($0) }
            }
            return parsed
        }
    }

    /// Trip nouns after which "long" is a duration word, not place text.
    private static let longTargets: Set<String> = [
        "weekend", "weekends", "trip", "trips", "vacation", "vacations", "holiday", "holidays",
        "getaway", "getaways", "journey", "journeys", "travel", "travels", "visit", "visits",
    ]

    // MARK: - Lexicon

    /// A month or season word in a slot.
    private enum DateWord {
        case month(Int)
        case season(Season)

        /// The word's months with their offsets from the clause year.
        var datedMonths: Set<DateMonth> {
            switch self {
            case .month(let month): [DateMonth(month: month)]
            case .season(let season): season.datedMonths
            }
        }
    }

    private struct Season: Sendable {
        enum Kind: Sendable { case plain, anchorRequired, recent, current }
        let months: Set<Int>
        let finalMonth: Int
        let kind: Kind

        /// Seasons are labeled by their first month's year: a season that
        /// crosses New Year (winter) puts the months up to its final month
        /// in the following year.
        var datedMonths: Set<DateMonth> {
            let wraps = months.contains { $0 > finalMonth }
            return Set(months.map { DateMonth(month: $0, yearOffset: wraps && $0 <= finalMonth ? 1 : 0) })
        }
    }

    private enum RelativePhrase: Sendable { case lastYear, thisYear, lastMonth }

    private enum FrameKind: Sendable { case last, this, inside }

    private struct FrameKeys: Sendable {
        let before: [String]
        let after: [String]
        let kind: FrameKind
    }

    /// Multiword vocabulary keyed by its first word, longest entries first.
    private struct PhraseTable<Value: Sendable>: Sendable {
        struct Entry: Sendable {
            let keys: [String]
            let value: Value
        }

        private var entries: [String: [Entry]] = [:]

        mutating func add(_ keys: [String], _ value: Value) {
            guard let first = keys.first, !(entries[first] ?? []).contains(where: { $0.keys == keys }) else { return }
            entries[first, default: []].append(Entry(keys: keys, value: value))
            entries[first]?.sort { $0.keys.count > $1.keys.count }
        }

        func candidates(_ key: String) -> [Entry] { entries[key] ?? [] }
    }

    /// `TripQueryVocabulary.active(languageTag:)` in the parser's key space:
    /// every word folded and normalized like the query, Han and kana split
    /// into segments. Month and season words also match their Latin forms
    /// of 4+ characters (`kalokairi`, `ioulios`); filler matches its native
    /// form only (Greek `και` must not drop the city Kai).
    private struct Lexicon: Sendable {
        var months = PhraseTable<Int>()
        var seasons = PhraseTable<Season>()
        var weekends = PhraseTable<Bool>()
        var relative = PhraseTable<RelativePhrase>()
        var fillerPhrases = PhraseTable<Bool>()
        var frames: [FrameKeys] = []
        var yearConnectors: Set<String> = []
        var filler: Set<String> = []
        var ambiguousFunction: Set<String> = []
        /// `'suffix` endings stripped before tokenizing (Turkish `Roma'da`,
        /// English `Rome's`).
        var apostropheSuffixes: NSRegularExpression?
        /// Every single vocabulary key, for the Han season context rule.
        var contextKeys: Set<String> = []
        /// Single-word season, weekend and month keys for trailing completion.
        var completions: [(key: String, meaning: String)] = []

        func isVocabulary(_ key: String) -> Bool {
            contextKeys.contains(key) || ambiguousFunction.contains(key)
        }

        /// The one meaning `prefix` completes to, as its shortest key.
        func completion(for prefix: String) -> String? {
            let candidates = completions.filter { $0.key.hasPrefix(prefix) && $0.key != prefix }
            guard !candidates.isEmpty, Set(candidates.map(\.meaning)).count == 1 else { return nil }
            return candidates.min { ($0.key.count, $0.key) < ($1.key.count, $1.key) }?.key
        }
    }

    private static let lexicons = OSAllocatedUnfairLock(initialState: [String: Lexicon]())

    /// Builds the lexicons for English and `languageTag` and compiles the
    /// numeric regexes, so the first query on the main actor pays for
    /// neither. Call it from an off-main index build.
    nonisolated static func prewarm(languageTag: String) {
        _ = lexicon(for: "en")
        _ = lexicon(for: languageTag)
        Regexes.prewarm()
    }

    private static func lexicon(for languageTag: String) -> Lexicon {
        if let cached = lexicons.withLock({ $0[languageTag] }) { return cached }
        let built = makeLexicon(TripQueryVocabulary.active(languageTag: languageTag))
        lexicons.withLock { $0[languageTag] = built }
        return built
    }

    /// Key sequences of one vocabulary word or phrase: the native form, plus
    /// the Latin forms of 4+ characters when `latin` is set.
    private static func keySequences(_ phrase: String, latin: Bool) -> [[String]] {
        let forms = TripSearch.normalizedSearchForms(fold(phrase))
        guard let native = forms.first else { return [] }
        var result = [unitKeys(native)]
        if latin {
            for form in forms.dropFirst() {
                let keys = unitKeys(form)
                if keys.joined().count >= 4, !result.contains(keys) { result.append(keys) }
            }
        }
        return result.filter { !$0.isEmpty }
    }

    private static func makeLexicon(_ language: TripQueryVocabulary.Language) -> Lexicon {
        var lexicon = Lexicon()
        var singles = Set<String>()
        func note(_ keys: [String]) { singles.formUnion(keys) }

        for (word, month) in language.months {
            for keys in keySequences(word, latin: true) {
                lexicon.months.add(keys, month)
                note(keys)
                if keys.count == 1 { lexicon.completions.append((keys[0], "month \(month)")) }
            }
        }
        for (word, months) in language.seasons {
            let kind: Season.Kind = language.anchorRequiredSeasonWords.contains(word) ? .anchorRequired
                : language.recentSeasonWords.contains(word) ? .recent
                : language.currentSeasonWords.contains(word) ? .current
                : .plain
            let season = Season(months: months, finalMonth: language.seasonFinalMonth[word] ?? 12, kind: kind)
            for keys in keySequences(word, latin: true) {
                lexicon.seasons.add(keys, season)
                note(keys)
                if keys.count == 1, kind == .plain {
                    lexicon.completions.append((keys[0], "season \(months.sorted())"))
                }
            }
        }
        for word in language.weekendWords {
            for keys in keySequences(word, latin: false) {
                lexicon.weekends.add(keys, true)
                note(keys)
                if keys.count == 1 { lexicon.completions.append((keys[0], "weekend")) }
            }
        }
        let relative: [(phrases: [String], meaning: RelativePhrase)] = [
            (language.lastYearPhrases, .lastYear), (language.thisYearPhrases, .thisYear),
            (language.lastMonthPhrases, .lastMonth),
        ]
        for (phrases, meaning) in relative {
            for phrase in phrases {
                for keys in keySequences(phrase, latin: false) {
                    lexicon.relative.add(keys, meaning)
                    note(keys)
                }
            }
        }

        lexicon.ambiguousFunction = Set(language.ambiguousFunctionWords.compactMap { keySequences($0, latin: false).first?.first })
        let frames: [(frames: [TripQueryVocabulary.Frame], kind: FrameKind)] = [
            (language.lastFrames, .last), (language.thisFrames, .this), (language.inFrames, .inside),
        ]
        for (list, kind) in frames {
            for frame in list {
                let before = keySequences(frame.before, latin: false).first ?? []
                let after = keySequences(frame.after, latin: false).first ?? []
                let words = before + after
                // `de _` alone would read Rio de Janeiro as "in January": a
                // frame made only of place-prone words is no anchor.
                guard !words.isEmpty, !words.allSatisfy(lexicon.ambiguousFunction.contains) else { continue }
                lexicon.frames.append(FrameKeys(before: before, after: after, kind: kind))
                note(words)
            }
        }
        lexicon.frames.sort { ($0.before.count + $0.after.count) > ($1.before.count + $1.after.count) }

        for word in language.yearConnectors {
            if let key = keySequences(word, latin: false).first, key.count == 1 {
                lexicon.yearConnectors.insert(key[0])
                note(key)
            }
        }
        for word in language.filler {
            guard let keys = keySequences(word, latin: false).first else { continue }
            if keys.count == 1 {
                lexicon.filler.insert(keys[0])
            } else {
                lexicon.fillerPhrases.add(keys, true)
            }
            note(keys)
        }
        for phrase in language.fillerPhrases {
            for keys in keySequences(phrase, latin: false) {
                lexicon.fillerPhrases.add(keys, true)
                note(keys)
            }
        }
        if !language.apostropheSuffixes.isEmpty {
            let suffixes = Set(language.apostropheSuffixes.map(fold))
                .sorted { ($0.count, $0) > ($1.count, $1) }
                .map(NSRegularExpression.escapedPattern(for:))
            lexicon.apostropheSuffixes = try? NSRegularExpression(
                pattern: "['’](?:" + suffixes.joined(separator: "|") + ")(?![\\p{L}\\p{N}])")
        }
        lexicon.contextKeys = singles
        return lexicon
    }
}
