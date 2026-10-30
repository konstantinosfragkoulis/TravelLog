//
//  TripQueryParser.swift
//  TravelLog
//
//  Deterministic natural-language query parsing and the shared local search
//  resolver over a `TripSearchIndex` (list, Siri and Shortcuts use it).
//
//  `parse` first keeps the multiword names the trips have whole (`Cape
//  May`, `Spring Hill`, `Ha Long`; `protectNames`), so no syntax reads a
//  word of them. `searchTrips(index:query:...)` orders the local passes: a
//  corpus-aware PLACE reading of the ambiguous words (bare month and season
//  words, holiday words: a town called May, Natal) first, matched against
//  geographic fields only; then the `TripSearch`
//  engine over every field; then the STRUCTURED intent: duration phrases ("longer than a week", "weekend trips", "long trips", "five days",
//  "2 weeks", "plus d'une semaine", "day trips", "2泊3日"), seasons
//  ("summer 2024", "last summer", "Sommer 2024", "summer before last"),
//  relative dates ("last year", "πέρσι", "two years ago", "前年", "this
//  month"), recent spans ("last 6 months", "過去3ヶ月"), numeric CJK and
//  Vietnamese months ("1月", "tháng 1"), calendar days ("15 august 2024",
//  "2024年8月15日"), holidays ("Thanksgiving", "Pfingsten", "GW"), year
//  lists, ranges and bounds ("2023-2024", "between 2019 and
//  2021", "since 2025", "before 2018"), plus residual
//  place terms with the engine's typo tolerance ("greece longer than a
//  week"). When nothing matches every word, a partial pass drops dates and
//  numbers, then keeps the trips matching the most remaining words.
//
//  Scope notes (deliberate):
//    - Vocabulary is English plus the app language (`TripQueryVocabulary`),
//      duration grammar and year bounds included, plus the user's other
//      preferred languages and the language of a Greek, Hangul or kana
//      query (`queryLanguageTags`).
//    - A year bound is the set of years it admits within 1900...2099, so it
//      pairs with months and seasons like any loose year and keeps the
//      overlap semantics: "since 2025" is every trip touching 2025 or
//      later, "after 2020" every trip touching 2021 or later.
//    - Seasons are northern-hemisphere month sets. The month on either side
//      of a season (November and March for winter) admits a trip as a
//      similar match (`DateClause.shoulders`): a season's edges are fuzzy.
//    - "or" between places or year bounds unions the sides' readings
//      (`disjunctionMatches`); year bounds otherwise intersect.
//    - A misspelt month, season or weekend word that matches no trip reads
//      as the word it misspells (`correctDateTypos`, the search corpus).
//    - Dates use `TripFilters.yearCalendar` (Gregorian, device zone): the
//      document's `startYear` / `startMonth`, and its end date read in the
//      same calendar.
//    - A month or season paired with its year (`summer 2024`, `last
//      winter`, `2024年7月`) is one clause; clauses OR-combine ("summer
//      2024 or winter 2025"). Unpaired months and years join every clause.
//    - Ongoing trips have `durationDays == nil` and are excluded by
//      duration filters; for dates, holidays, days and recent spans their
//      days run from the start to `now` (`ParsedQuery.today`).
//    - A holiday or calendar day matches a trip whose days overlap it; a
//      holiday's year is its anchor day's (`TripQueryHoliday`). A calendar
//      day is a date clause of its own (`DateClause.days`), so "or" and
//      loose years combine with it like with months; a numeric date its
//      month lacks (`2024-02-30`) admits no trip.
//    - Lengths: a day trip is 1 day, short 3 or fewer, long 8+ (as
//      "longer than a week"), a weekend 2-3 days and a long
//      weekend 3-4 with a weekend day. Slashed or dotted numeric dates are
//      not read (their day/month order depends on the locale); ISO dates
//      are.
//    - Pure values only: no SwiftData, safe from any executor.
//

import Foundation
import os

nonisolated enum TripQueryParser {

    // MARK: - Parsed result

    /// The one trip (ties all kept) a query picks among its best matches
    /// (`ordinalMatches`): by start date ("first trip", "3rd trip to
    /// Lisbon", "last trip", "previous trip") or, among completed trips, by
    /// a measure ("longest trip", "farthest trip", "trip with the most
    /// countries"). "last" is the latest trip, an ongoing one included;
    /// "previous", and "last" with a time word ("last time in Oslo" while
    /// there again), the latest completed one.
    enum Ordinal: Hashable {
        case first, nth(Int), last, previous
        case longest, shortest, farthest, mostCountries
    }

    /// A month a date clause admits, `yearOffset` years after the clause's
    /// year: winter 2024 is December 2024 and January and February 2025.
    struct DateMonth: Hashable {
        var month: Int
        var yearOffset = 0
    }

    /// Months (empty = any month) in one of `years` (empty = any year),
    /// matched together, so `summer 2024 or winter 2025` never pairs one
    /// clause's months with the other clause's year. A clause of calendar
    /// `days` (`15 august 2024`) admits the trips covering one of them in
    /// one of its years; months, when it has some, restrict the days like
    /// years do (`15 august july` admits nothing).
    struct DateClause: Equatable {
        var months: Set<DateMonth> = []
        var years: Set<Int> = []
        var days: Set<DateDay> = []
        /// A season's neighbouring months (`Season.shoulderMonths`), which
        /// admit a trip as a similar match only (`DateFilter.widened`).
        var shoulders: Set<DateMonth> = []

        /// By month; a clause of days never matches by month.
        func matches(year: Int, month: Int) -> Bool {
            if !days.isEmpty { return false }
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
        var looseShoulders: Set<DateMonth> = []

        var isEmpty: Bool { clauses.isEmpty && looseMonths.isEmpty && looseYears.isEmpty }

        /// Every year any clause or loose part names.
        var years: Set<Int> { clauses.reduce(looseYears) { $0.union($1.years) } }

        /// Every month-of-year any clause or loose part names.
        var months: Set<Int> {
            Set(looseMonths.map(\.month)).union(clauses.flatMap { $0.months.map(\.month) })
        }

        /// Whether a clause names calendar days.
        var hasDays: Bool { clauses.contains { !$0.days.isEmpty } }

        /// Within one reading the month and season clauses govern its days
        /// (`15 august last summer` is 15 August 2025): they restrict each
        /// day clause, their years paired with the day's, instead of
        /// standing beside it. False when the years exclude each other.
        mutating func bindDays() -> Bool {
            let others = clauses.filter { $0.days.isEmpty }
            guard hasDays, !others.isEmpty else { return true }
            let months = others.reduce(into: Set<DateMonth>()) { $0.formUnion($1.months) }
            let shoulders = others.reduce(into: Set<DateMonth>()) { $0.formUnion($1.shoulders) }
            let years = others.reduce(into: Set<Int>()) { $0.formUnion($1.years) }
            var satisfiable = true
            clauses = clauses.filter { !$0.days.isEmpty }.map { clause in
                var clause = clause
                clause.months.formUnion(months)
                clause.shoulders.formUnion(shoulders)
                if clause.years.isEmpty {
                    clause.years = years
                } else if !years.isEmpty {
                    clause.years.formIntersection(years)
                    if clause.years.isEmpty { satisfiable = false }
                }
                return clause
            }
            return satisfiable
        }

        var effectiveClauses: [DateClause] {
            guard !clauses.isEmpty else { return [DateClause(months: looseMonths, years: looseYears)] }
            return clauses.map {
                DateClause(months: $0.months.union(looseMonths), years: $0.years.union(looseYears), days: $0.days)
            }
        }

        func matches(year: Int, month: Int) -> Bool {
            isEmpty || effectiveClauses.contains { $0.matches(year: year, month: month) }
        }

        /// The filter with each season's shoulder months admitted, or nil
        /// when no season has any.
        var widened: DateFilter? {
            guard !looseShoulders.isEmpty || clauses.contains(where: { !$0.shoulders.isEmpty }) else { return nil }
            var result = self
            result.looseMonths.formUnion(looseShoulders)
            result.looseShoulders = []
            result.clauses = clauses.map { clause in
                var clause = clause
                clause.months.formUnion(clause.shoulders)
                clause.shoulders = []
                return clause
            }
            return result
        }
    }

    /// A day of the year (`15 august`, `8月15日`), in a `DateClause`.
    struct DateDay: Hashable {
        var month: Int
        var day: Int
    }

    /// See `ParsedQuery.monthPlaceAlternatives`.
    struct MonthPlace: Equatable {
        /// The month or season word as typed, and its name key
        /// (`TripSearchIndex.namePhrase`).
        var word: String
        var key: String
        /// The `<month> <year>` clause the place reading replaces.
        var clause: DateClause
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
        /// True when a word besides place text and filter syntax is left
        /// (`to` of `to Split`, a trip noun, a length word). A function
        /// word right before a date or other filter, or after one at the
        /// end, belongs to it (`in 2024`, Korean `2024년에`).
        var hasOwnWords = false
        /// `hasOwnWords` of the place reading, whose restored words are place
        /// text (`para` of Portuguese `para Natal em 2024` is the place's).
        var placeReadingHasOwnWords = false

        /// Bare month/season words are genuinely ambiguous: `winter` can be a
        /// date filter or part of `Winter Park`. The structured parse keeps
        /// their month contribution in `months`; this parallel representation
        /// lets corpus-aware search try them as place words first.
        var ambiguousDateTokens: [String] = []

        /// Raw text of `placeTerms` that must match a WHOLE word. The
        /// ambiguous words moved in by `placeInterpretation` use this: prefix
        /// or typo tolerance would let "Mayfair" satisfy a bare "may" and
        /// silently mask the date reading entirely.
        var strictWholeWordTerms: Set<String> = []

        /// Names some trip has as adjacent words of one value (`Cape May`,
        /// `Spring Hill`) that the name pass kept whole before any syntax
        /// could read a word of them (`TripSearchIndex.namePhrase`). A full
        /// match has each in one value of a field other than dates, so `Cape
        /// May` never matches Cape Town in May.
        var namePhrases: [String] = []
        /// A month or season word of a `<month> <year>` clause that is also
        /// the whole name of some trip's place (a town called May): the date
        /// reading stands and trips to that place, the clause read as its
        /// years and every other constraint kept, are offered as partial
        /// matches (suggestions, never answers).
        var monthPlaceAlternatives: [MonthPlace] = []

        /// Terms for the ambiguous date and holiday words, in query order.
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
        /// The query's sides around "or" words (`disjunctionWords`) that this
        /// reading would AND or mix: two or more place terms ("Paris or
        /// Rome"), year bounds ("before 2015 or after 2020") or holidays
        /// ("Christmas 2023 or Easter 2024"). Empty otherwise.
        var disjunctionSides: [String] = []
        /// The sides are split only for their dates (`disjunctionMatches`
        /// keeps them apart when each side has its own).
        var temporalDisjunction = false
        /// The query's words without the syntax this reading consumes as its
        /// own filters (dates, bounds, lengths, weekends, facets): what an
        /// "or" side lacking place words borrows, typed in front of its own
        /// ("Ha Long trips" of "Ha Long trips before 2015").
        var borrowableText = ""
        /// `borrowableText` of the place reading, which keeps the words it
        /// restores as place text (`placeInterpretation`).
        var placeReadingBorrowableText = ""
        /// The kinds of trip asked for ("islands", "abroad"): consumed
        /// syntax; a trip must have every one (`TripSearchDocument.facets`).
        var facets: Set<TripSearchFacet> = []

        /// Holidays the trip must overlap (any of them), in the years the
        /// dates admit (`TripQueryHoliday.windows(in:)`): "Christmas 2023",
        /// "Πάσχα". A holiday word is also tried as a place word first
        /// (`ambiguousHolidays`): Natal, Christmas Island.
        var holidays: Set<TripQueryHoliday> = []
        var ambiguousHolidays: Set<TripQueryHoliday> = []
        /// The first day of a recent span that ends today (`last 6 months`,
        /// `past year`, `過去3ヶ月`): the trip's days must reach into it.
        var recentStart: Date?
        /// The parse's now. An ongoing trip's days run to it for dates,
        /// holidays, days and spans; its duration stays unknown.
        var today: Date?
        /// Weekend words: the trip must have a weekend day (the calendar's
        /// weekend, Saturday and Sunday in most locales).
        var requiresWeekend = false
        /// A numeric date its month lacks (`2024-02-30`): no trip matches,
        /// whatever else the query admits.
        var admitsNothing = false
        /// The ambiguous holiday phrases, normalized: the place reading also
        /// takes a trip whose whole title is one (a trip called "Noel").
        var holidayTitles: Set<String> = []
        /// The query's `'suffix` endings, for titles compared with `holidayTitles`.
        var titleApostropheSuffixes: NSRegularExpression?
        /// "first trip", "last trip to Valdoria", `τελευταίο ταξίδι`,
        /// "longest trip": only that fully matching trip is kept.
        var ordinal: Ordinal?
        /// Kinds a trip must not have ("without flying", `ohne Flug`):
        /// consumed syntax, like `facets`.
        var excludedFacets: Set<TripSearchFacet> = []
        /// "via Munich", "layover in Frankfurt", `μέσω Μονάχου`: these place
        /// terms must match a transit stop of the trip (the transit field).
        var viaTerms: [TripSearchTerm] = []
        /// The via word as typed, and whether it follows the place (Turkish
        /// `üzerinden`): an "or" side of bare names takes it (`via Nice or
        /// Split`).
        var viaWordText: String?
        var viaWordFollowsPlace = false
        /// The words besides the via place, without filter syntax, when the
        /// via place is the last place: an "or" side of bare names after it
        /// takes them with the via word (`Tokyo via Seoul or Taipei`).
        var viaDestinationText: String?
        /// `viaDestinationText` of the place reading (see `borrowableText`).
        var placeReadingViaDestinationText: String?

        /// Whether every place word is the via place (`via Nice`).
        var isViaGroup: Bool { !viaTerms.isEmpty && placeTerms.map(\.raw) == viaTerms.map(\.raw) }

        /// Whether the query is place names with no via word and no words
        /// of its own (`to Split`), its filters aside (`Lima in 2024`): an
        /// "or" side that takes a via side's scope.
        var isBareNames: Bool { viaTerms.isEmpty && !hasOwnWords && !placeTerms.isEmpty }

        var hasStructuredFilter: Bool { hasFilterBesidesOrdinal || ordinal != nil }

        /// Dates, lengths, facets or holidays: what an "or" side lends.
        var hasFilterBesidesOrdinal: Bool {
            !dates.isEmpty || minDurationDays != nil || maxDurationDays != nil || !facets.isEmpty
                || !excludedFacets.isEmpty || !holidays.isEmpty || recentStart != nil || admitsNothing
        }

        /// Whether this parse should claim the query at all. A query with
        /// no structured filter and no dropped noise is just place words,
        /// exactly what the engine pass already tried, so re-running it
        /// here would change nothing.
        var isClaimable: Bool {
            hasStructuredFilter || (droppedNoise && !placeTerms.isEmpty)
        }

        /// The filters this reading hides from the engine pass (consumed
        /// syntax) as a reading of their own, which the engine pass's matches
        /// must satisfy too; holidays apart (`matchesConsumedSyntax`). Built
        /// in one place so no consumed filter is left out.
        var consumedConstraints: ParsedQuery {
            var constraints = ParsedQuery()
            constraints.dates = consumedDates
            constraints.minDurationDays = consumedMinDurationDays
            constraints.maxDurationDays = consumedMaxDurationDays
            constraints.facets = facets
            constraints.excludedFacets = excludedFacets
            constraints.recentStart = recentStart
            constraints.today = today
            constraints.requiresWeekend = requiresWeekend
            constraints.admitsNothing = admitsNothing
            return constraints
        }

        /// An "or" side without dates, lengths, bounds or facets takes
        /// `source`'s, in every reading of it and as consumed syntax, so the
        /// engine pass respects them too.
        mutating func inheritFilters(from source: ParsedQuery) {
            dates = source.dates
            unambiguousDates = source.dates
            consumedDates = source.dates
            minDurationDays = source.minDurationDays
            maxDurationDays = source.maxDurationDays
            consumedMinDurationDays = source.minDurationDays
            consumedMaxDurationDays = source.maxDurationDays
            facets = source.facets
            excludedFacets = source.excludedFacets
            holidays = source.holidays
            ambiguousHolidays = []
            recentStart = source.recentStart
            requiresWeekend = source.requiresWeekend
            admitsNothing = source.admitsNothing
            consumedSyntax = true
        }

        /// Alternate reading in which the ambiguous date and holiday words are
        /// place text (a town called May, Natal), tried first.
        /// Nil means the query contains no such ambiguity. Unambiguous
        /// filters (duration, years, anchored months) remain active.
        var placeInterpretation: ParsedQuery? {
            guard !ambiguousDateTokens.isEmpty else { return nil }
            var alternative = self
            alternative.dates = unambiguousDates
            alternative.holidays.subtract(ambiguousHolidays)
            alternative.ambiguousHolidays = []
            alternative.borrowableText = placeReadingBorrowableText
            alternative.viaDestinationText = placeReadingViaDestinationText
            alternative.hasOwnWords = placeReadingHasOwnWords
            alternative.placeTerms.append(contentsOf: ambiguousTerms)
            alternative.strictWholeWordTerms = Set(ambiguousTerms.map(\.raw))
            alternative.ambiguousDateTokens = []
            alternative.ambiguousTerms = []
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
        let single = searchTripsSingle(
            index: index, query: query, allowsTrailingPartial: allowsTrailingPartial,
            now: now, calendar: calendar, languageTag: languageTag)
        return disjunctionMatches(
            index: index, query: query, allowsTrailingPartial: allowsTrailingPartial,
            now: now, calendar: calendar, languageTag: languageTag) ?? single
    }

    /// "Paris or Rome 2024", "before 2015 or after 2020": the union of each
    /// side's full matches (`ParsedQuery.disjunctionSides`). Each side is
    /// read as it resolves (its place reading when that finds trips, so
    /// "Rhode Island" and "Ha Long" are places). A side without place terms
    /// takes those of the nearest side that has them (with their via scope),
    /// and one without dates, lengths, bounds or facets those of the nearest
    /// side that has them, so "Paris or Rome 2024" is Paris 2024 or Rome
    /// 2024 and "Paris before 2015 or after 2020" is Paris either way. A
    /// side no trip matches adds none ("Paris or Atlantis"). Nil, leaving
    /// today's reading, when there is no such "or", a side has nothing to
    /// search ("Or Yehuda", "Paris or"), or no side matches. A comma list
    /// stays AND.
    private static func disjunctionMatches(
        index: TripSearchIndex,
        query: String,
        allowsTrailingPartial: Bool,
        now: Date,
        calendar: Calendar,
        languageTag: String
    ) -> [TripSearchMatch]? {
        guard !index.isEmpty, mayContainDisjunction(query, languageTag: languageTag) else { return nil }
        let whole = parse(query, now: now, calendar: calendar, languageTag: languageTag, corpus: index)
        let sides = whole.disjunctionSides
        guard sides.count >= 2 else { return nil }
        // The word being typed is on the last side.
        let typing = allowsTrailingPartial && !TripSearchText.endsWithSeparator(query)
        let parses = sides.enumerated().map { offset, side in
            parse(
                side, now: now, calendar: calendar, languageTag: languageTag, corpus: index,
                typing: typing && offset == sides.count - 1)
        }
        // Years an undated side of a date split takes from the others, as
        // unpaired months take a clause's (`15 august 2024 or september`).
        var inheritedYears: [Set<Int>] = Array(repeating: [], count: parses.count)
        if whole.temporalDisjunction {
            // Split for dates only: each side needs dates of its own beyond
            // bare years. A side with no dates keeps the single AND reading
            // (`christmas or Valdoria`); a side of bare years joins the
            // others' dates, as loose years join clauses (`christmas 2024 or
            // 2025`), except beside a span (`last 6 months or 2020`).
            func lacksOwnDates(_ side: ParsedQuery) -> Bool {
                side.dates.clauses.isEmpty && side.dates.looseMonths.isEmpty && side.holidays.isEmpty
                    && side.recentStart == nil && !side.admitsNothing
            }
            let hasSpan = parses.contains { $0.recentStart != nil }
            guard parses.allSatisfy({ !lacksOwnDates($0) || (hasSpan && !$0.dates.looseYears.isEmpty) })
            else { return nil }
            for (offset, side) in parses.enumerated() where side.dates.years.isEmpty && side.recentStart == nil {
                inheritedYears[offset] = parses.indices.filter { $0 != offset }
                    .reduce(into: Set<Int>()) { $0.formUnion(parses[$1].dates.years) }
            }
        }
        let readings = parses.map { parsed -> (parsed: ParsedQuery, placeReading: Bool) in
            guard let reading = parsed.placeInterpretation,
                  !filter(index: index, parsed: reading, calendar: calendar, placeReading: true).isEmpty
            else { return (parsed, false) }
            return (reading, true)
        }
        // What each side with place words lends: its text without its own
        // filter syntax, as its resolved reading reads it ("ha long trips"
        // of "Ha Long trips before 2015", "cape may" of "Cape May before 2015").
        let placeWords = readings.map { $0.parsed.placeTerms.isEmpty ? "" : $0.parsed.borrowableText }
        // One ordinal for the whole query ("last trip to Paris or Rome"):
        // it picks from the union, not from each side.
        let ordinals = Set(readings.compactMap(\.parsed.ordinal))
        let sharedOrdinal = ordinals.count == 1 ? ordinals.first : nil
        var best: [Int: TripSearchMatch] = [:]
        for (offset, side) in sides.enumerated() {
            let own = readings[offset]
            // Nearest first, the following side before the preceding one.
            let others = (1..<readings.count).flatMap { distance in
                [offset + distance, offset - distance].filter(readings.indices.contains)
            }
            let source = own.parsed.placeTerms.isEmpty ? others.first(where: { !placeWords[$0].isEmpty }) : nil
            let places = source.map { placeWords[$0] }
            // The shared ordinal applies to the union; it lends nothing.
            var filters = own.parsed.hasFilterBesidesOrdinal
                ? nil : others.lazy.map({ readings[$0].parsed }).first(where: \.hasFilterBesidesOrdinal)
            guard !own.parsed.placeTerms.isEmpty || own.parsed.hasStructuredFilter || places != nil || filters != nil
            else { return nil }
            // The side resolves like a query of its own: shared place words
            // typed in front of it (so "after 2020" of "Cape May before 2015
            // or after 2020" is "cape may after 2020", word for word), shared
            // filters added to every reading of it (re-reading another side's
            // filter words next to its own could combine them).
            // Words lent by the side being typed go last, still being typed,
            // when they end in the typed word (not in that side's filter syntax).
            let typedSide = sides.count - 1
            let takesTypedWord = typing && source == typedSide
                && placeWords[typedSide].split(separator: " ").last == sides[typedSide].split(separator: " ").last
            var text = places.map { takesTypedWord ? side + " " + $0 : $0 + " " + side } ?? side
            var typesText = typing && (offset == typedSide || takesTypedWord)
            // Bare names joined to a via side take its via word (`via Nice or
            // Split`), and after a destination via a stop that destination too
            // (`Tokyo via Seoul or Taipei`, and each bare side after that one);
            // a side with its own words (`to Split`) is its own scope and ends
            // that run. The via word goes next to the side's place words, its
            // filters lent like shared ones (`Tokyo via Seoul or 2024 Taipei`).
            // Its place is still being typed only when it ends the side
            // (`via Nice or Austria 2024` has finished Austria).
            let destination = readings[..<offset].last(where: { !$0.parsed.isBareNames })
                .flatMap { $0.parsed.isViaGroup || $0.parsed.viaDestinationText == nil ? nil : $0.parsed }
            if own.parsed.isBareNames,
               let via = destination ?? others.lazy.map({ readings[$0].parsed }).first(where: \.isViaGroup),
               let word = via.viaWordText {
                let place = own.parsed.borrowableText
                text = via.viaWordFollowsPlace ? place + " " + word : word + " " + place
                if let words = destination?.viaDestinationText { text = words + " " + text }
                if own.parsed.hasFilterBesidesOrdinal { filters = own.parsed }
                typesText = typesText && place.split(separator: " ").last == side.split(separator: " ").last
            }
            let matches = searchTripsSingle(
                index: index, query: text,
                allowsTrailingPartial: typesText,
                now: now, calendar: calendar, languageTag: languageTag
            ) { parsed in
                if let filters { parsed.inheritFilters(from: filters) }
                if !inheritedYears[offset].isEmpty {
                    parsed.dates.looseYears.formUnion(inheritedYears[offset])
                    parsed.unambiguousDates.looseYears.formUnion(inheritedYears[offset])
                    parsed.consumedDates.looseYears.formUnion(inheritedYears[offset])
                }
                // Lent place words keep their via scope (`via Seoul before
                // 2015 or after 2020` is via Seoul either way).
                if let source { parsed.viaTerms = readings[source].parsed.viaTerms }
                if sharedOrdinal != nil { parsed.ordinal = nil }
            }
            .filter { $0.strength != .partial }
            // A side no trip matches adds none ("Paris or Atlantis").
            for match in matches {
                if let existing = best[match.documentIndex], existing.strength <= match.strength { continue }
                best[match.documentIndex] = match
            }
        }
        // A date split no trip matches stays empty: the single reading would
        // cross the sides' years (`christmas 2025 or 1 january 2024`).
        guard !best.isEmpty else { return whole.temporalDisjunction ? [] : nil }
        return ordinalMatches(
            best.values.sorted { $0.documentIndex < $1.documentIndex }, ordinal: sharedOrdinal, index: index)
    }

    /// A cheap test before the second parse: some "or" word of the query's
    /// languages is a word of it (or, in a Han, kana or Hangul word, inside it).
    private static func mayContainDisjunction(_ query: String, languageTag: String) -> Bool {
        let words = lexicon(for: queryLanguageTags(query, languageTag: languageTag)).disjunctions
        let folded = fold(query)
        let keys = Set(TripSearchText.rawTokens(folded).compactMap { TripSearch.normalizedSearchForms($0.text).first })
        return words.contains { word in
            keys.contains(word) || (word.unicodeScalars.contains(where: TripSearchText.isCJK) && folded.contains(word))
        }
    }

    /// One reading of the whole query (see `searchTrips`). `adjust` edits
    /// every parse of it before it resolves (an "or" side's shared terms).
    private static func searchTripsSingle(
        index: TripSearchIndex,
        query: String,
        allowsTrailingPartial: Bool,
        now: Date,
        calendar: Calendar,
        languageTag: String,
        adjust: (inout ParsedQuery) -> Void = { _ in }
    ) -> [TripSearchMatch] {
        guard !index.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard allowsTrailingPartial, !TripSearchText.endsWithSeparator(query) else {
            return resolve(
                index: index, query: query, now: now, calendar: calendar, languageTag: languageTag, typing: false,
                adjust: adjust)
        }
        // A typed filler kept as a place prefix (`rome in` → India) or a
        // completion can leave only partial matches where the finished
        // words match fully, and a filler that also matches a title word
        // (`japan in` → Autumn in Kyoto) can narrow the finished reading's
        // trips; then the finished reading wins. The second resolve runs
        // only when the typed reading has no full match or kept a filler.
        var typedParse = parse(query, now: now, calendar: calendar, languageTag: languageTag, corpus: index, typing: true)
        adjust(&typedParse)
        let typed = resolve(index: index, parsed: typedParse, query: query, calendar: calendar, languageTag: languageTag)
        let typedFull = fullMatches(typed)
        guard typedFull.isEmpty || typedParse.typedFillerIsPlace else { return typed }
        let finished = resolve(
            index: index, query: query, now: now, calendar: calendar, languageTag: languageTag, typing: false,
            adjust: adjust)
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
        typing: Bool,
        adjust: (inout ParsedQuery) -> Void
    ) -> [TripSearchMatch] {
        var parsed = parse(query, now: now, calendar: calendar, languageTag: languageTag, corpus: index, typing: typing)
        adjust(&parsed)
        return resolve(index: index, parsed: parsed, query: query, calendar: calendar, languageTag: languageTag)
    }

    private static func resolve(
        index: TripSearchIndex,
        parsed: ParsedQuery,
        query: String,
        calendar: Calendar,
        languageTag: String
    ) -> [TripSearchMatch] {
        ordinalMatches(
            resolveEveryMatch(index: index, parsed: parsed, query: query, calendar: calendar, languageTag: languageTag),
            ordinal: parsed.ordinal, index: index)
    }

    /// The `ordinal` pick among the best full matches: the strong ones when
    /// there are any, so a newer trip that only passed through a place never
    /// beats an older visit. By start date, over logical trips (UUID twins,
    /// one `tripID`, are one entry dated by the earliest start of every
    /// indexed row, matched or not, completed only when every row is): the earliest; the trips of rank n, trips
    /// sharing a start sharing a rank and using up as many ranks as they are
    /// trips (the matches as partial when there are fewer); the latest; the
    /// latest completed (the matches as partial when none is: a first visit
    /// under way has no previous one). By a measure, among completed
    /// logical trips that have it, every trip with the extreme value at its
    /// own strength (an ongoing trip has no final length), each measured
    /// once by its earliest-starting row; the matches as partial when no
    /// trip qualifies. Every row of a picked trip is returned.
    /// Without a full match, the matches as they are.
    static func ordinalMatches(_ matches: [TripSearchMatch], ordinal: Ordinal?, index: TripSearchIndex) -> [TripSearchMatch] {
        guard let ordinal else { return matches }
        let strong = matches.filter { $0.strength == .strong }
        let full = strong.isEmpty ? matches.filter { $0.strength == .similar } : strong
        guard !full.isEmpty else { return matches }
        func document(_ match: TripSearchMatch) -> TripSearchDocument { index.documents[match.documentIndex] }
        let suggestions = full.map {
            TripSearchMatch(documentIndex: $0.documentIndex, strength: .partial, evidence: $0.evidence)
        }
        // Every indexed row of a candidate trip, matched or not: a twin the
        // match tiers dropped still dates the trip and can keep it ongoing.
        let candidates = Set(full.map { document($0).tripID })
        var twins: [UUID: [Int]] = [:]
        for (position, row) in index.documents.enumerated() where candidates.contains(row.tripID) {
            twins[row.tripID, default: []].append(position)
        }
        let trips = Dictionary(grouping: full) { document($0).tripID }.values.map { rows in
            let all = (twins[document(rows[0]).tripID] ?? rows.map(\.documentIndex)).sorted {
                (index.documents[$0].startDate, $0) < (index.documents[$1].startDate, $1)
            }
            return (rows: rows.sorted { $0.documentIndex < $1.documentIndex },
                    start: index.documents[all[0]].startDate,
                    isComplete: all.allSatisfy { index.documents[$0].isComplete },
                    earliest: all[0])
        }
        func starting(
            _ pick: Date?, among pool: [(rows: [TripSearchMatch], start: Date, isComplete: Bool, earliest: Int)]
        ) -> [TripSearchMatch] {
            pool.filter { $0.start == pick }.flatMap { $0.rows }.sorted { $0.documentIndex < $1.documentIndex }
        }
        let measure: (TripSearchDocument) -> Double?
        var largest = true
        switch ordinal {
        case .first:
            return starting(trips.map { $0.start }.min(), among: trips)
        case .nth(let rank):
            var before = 0
            for start in Set(trips.map { $0.start }).sorted() {
                before += trips.filter { $0.start == start }.count
                if before >= rank { return starting(start, among: trips) }
            }
            return suggestions
        case .last:
            return starting(trips.map { $0.start }.max(), among: trips)
        case .previous:
            let completed = trips.filter { $0.isComplete }
            guard !completed.isEmpty else { return suggestions }
            return starting(completed.map { $0.start }.max(), among: completed)
        case .longest, .shortest:
            measure = { $0.durationDays.map(Double.init) }
            largest = ordinal == .longest
        case .farthest:
            measure = { $0.farthestKm }
        case .mostCountries:
            measure = { $0.countryCodes.isEmpty ? nil : Double($0.countryCodes.count) }
        }
        let measured = trips.compactMap { trip in
            trip.isComplete ? measure(index.documents[trip.earliest]).map { (rows: trip.rows, value: $0) } : nil
        }
        let values = measured.map(\.value)
        guard let best = largest ? values.max() : values.min() else { return suggestions }
        return measured.filter { $0.value == best }.flatMap { $0.rows }.sorted { $0.documentIndex < $1.documentIndex }
    }

    private static func resolveEveryMatch(
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
        var fuzzyTerms = markingStops(
            TripSearch.terms(parsed.fuzzyText, languageTag: languageTag, allowsTrailingPartial: false), parsed)
        if !fuzzyTerms.isEmpty {
            if parsed.fuzzyTextEndsInTypedWord { fuzzyTerms[fuzzyTerms.count - 1].isTrailingPartial = true }
            fuzzy = TripSearch.match(terms: fuzzyTerms, in: index)
            if parsed.consumedSyntax || parsed.requiresWeekend {
                fuzzy = fuzzy.filter {
                    matchesConsumedSyntax(index.documents[$0.documentIndex], parsed: parsed, calendar: calendar)
                }
            }
            if let via = viaDocuments(parsed, index: index) { fuzzy = fuzzy.filter { via.contains($0.documentIndex) } }
            if let names = nameDocuments(parsed, index: index) {
                fuzzy = fuzzy.filter { names.contains($0.documentIndex) }
            }
            // A bare month or season word the engine matched as text (typed
            // `summer` finding Summerland, `may` in Mayfair) outside those
            // months is a similar match: the date reading stays the main one.
            if !parsed.ambiguousDateTokens.isEmpty, !parsed.dates.isEmpty {
                fuzzy = fuzzy.map { match in
                    guard match.strength == .strong,
                          !matchesFilters(index.documents[match.documentIndex], parsed: parsed, calendar: calendar)
                    else { return match }
                    return TripSearchMatch(documentIndex: match.documentIndex, strength: .similar, evidence: match.evidence)
                }
            }
        }

        var merged = parsed.isClaimable
            ? merge(fuzzy, filter(index: index, parsed: parsed, calendar: calendar))
            : fuzzy
        if merged.isEmpty {
            merged = partialMatches(parsed, index: index, query: query, calendar: calendar, languageTag: languageTag)
        }
        return withMonthPlaces(merged, parsed: parsed, index: index, calendar: calendar, languageTag: languageTag)
    }

    /// `matches` plus, as partial matches, the trips to a place whose whole
    /// name is the month or season word of a `<month> <year>` clause: that
    /// clause read as its years, every other constraint (holidays,
    /// durations, kinds, places, other clauses) kept
    /// (`ParsedQuery.monthPlaceAlternatives`). A suggestion: Siri and
    /// Shortcuts never take it as an answer.
    private static func withMonthPlaces(
        _ matches: [TripSearchMatch],
        parsed: ParsedQuery,
        index: TripSearchIndex,
        calendar: Calendar,
        languageTag: String
    ) -> [TripSearchMatch] {
        guard !parsed.monthPlaceAlternatives.isEmpty else { return matches }
        var best = byDocument(matches)
        for alternative in parsed.monthPlaceAlternatives {
            var reading = parsed
            guard let clause = reading.dates.clauses.firstIndex(of: alternative.clause) else { continue }
            reading.dates.clauses[clause] = DateClause(years: alternative.clause.years)
            let word = TripSearch.terms(alternative.word, languageTag: languageTag, allowsTrailingPartial: false)
            reading.placeTerms += word
            reading.strictWholeWordTerms.formUnion(word.map(\.raw))
            for match in filter(index: index, parsed: reading, calendar: calendar, placeReading: true)
            where best[match.documentIndex] == nil
                && hasWholeDestinationName(alternative.key, index.documents[match.documentIndex]) {
                best[match.documentIndex] = TripSearchMatch(
                    documentIndex: match.documentIndex, strength: .partial, evidence: match.evidence)
            }
        }
        return best.values.sorted { $0.documentIndex < $1.documentIndex }
    }

    /// Whether a place, region or country value of `document` is the name
    /// `key` whole (`TripSearchIndex.NamePhrase.isCompleteDestination`).
    private static func hasWholeDestinationName(_ key: String, _ document: TripSearchDocument) -> Bool {
        document.nameValues.contains { value in
            value.kind.buildsCompounds && value.words.joined(separator: " ") == key
                && !(value.isAlternate && value.words.count == 1
                    && TripSearchDocument.isAlternateNoise(value.words[0], inName: value.words))
        }
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
        let loose = markingStops(parsed.placeTerms.filter { !parsed.strictWholeWordTerms.contains($0.raw) }, parsed)
        let engine = loose.isEmpty ? nil : (placeReading
            ? TripSearch.match(terms: loose, in: index, fields: [.place, .region, .country])
            : TripSearch.match(terms: loose, in: index))
        let via = viaDocuments(parsed, index: index)
        let names = nameDocuments(parsed, index: index)
        // A trip only a season's shoulder month admits is a similar match.
        let widened = parsed.dates.widened.map { dates -> ParsedQuery in
            var widened = parsed
            widened.dates = dates
            return widened
        }
        var result: [TripSearchMatch] = []
        for offset in 0..<(engine?.count ?? index.documents.count) {
            var match = engine?[offset] ?? TripSearchMatch(documentIndex: offset, strength: .strong, evidence: [])
            let position = match.documentIndex
            let document = index.documents[position]
            if !matchesFilters(document, parsed: parsed, calendar: calendar) {
                guard let widened, matchesFilters(document, parsed: widened, calendar: calendar) else { continue }
                match = TripSearchMatch(documentIndex: position, strength: .similar, evidence: match.evidence)
            }
            if let via, !via.contains(position) { continue }
            if !strict.isEmpty {
                var words = placeReading ? index.strictPlaceWords(of: position) : index.wholeWords(of: position)
                if placeReading, !parsed.holidayTitles.isEmpty,
                   let title = document.fields.first(where: { $0.kind == .title })?.displayValues.first
                       .flatMap({ normalizedTitle($0, apostropheSuffixes: parsed.titleApostropheSuffixes) }),
                   parsed.holidayTitles.contains(title) {
                    words.formUnion(title.split(separator: " ").map(String.init))
                }
                guard strict.allSatisfy({ isWholeWordMatch($0, words: words, codes: document.countryCodes) })
                else { continue }
            }
            if let names, !names.contains(position) { continue }
            result.append(match)
        }
        return result
    }

    /// The documents with every protected name phrase in one value, or nil
    /// when the query has none (`ParsedQuery.namePhrases`).
    private static func nameDocuments(_ parsed: ParsedQuery, index: TripSearchIndex) -> Set<Int>? {
        guard !parsed.namePhrases.isEmpty else { return nil }
        var result: Set<Int>?
        for key in parsed.namePhrases {
            let documents = Set((index.namePhrase(key)?.documents ?? []).map(Int.init))
            result = result.map { $0.intersection(documents) } ?? documents
        }
        return result
    }

    /// `terms` with the via places (`ParsedQuery.viaTerms`) marked as the
    /// stops they name: matched at a stop, a via place is a strong match.
    private static func markingStops(_ terms: [TripSearchTerm], _ parsed: ParsedQuery) -> [TripSearchTerm] {
        guard !parsed.viaTerms.isEmpty else { return terms }
        let stops = Set(parsed.viaTerms.map(\.raw))
        return terms.map { term in
            var term = term
            term.namesStop = stops.contains(term.raw)
            return term
        }
    }

    /// The documents with a transit stop matching every via term ("via
    /// Munich"), or nil when the query has none.
    private static func viaDocuments(_ parsed: ParsedQuery, index: TripSearchIndex) -> Set<Int>? {
        guard !parsed.viaTerms.isEmpty else { return nil }
        return Set(TripSearch.match(terms: parsed.viaTerms, in: index, fields: [.transit]).map(\.documentIndex))
    }

    /// Folded text without the `'suffix` endings the query's languages
    /// strip (English `Year's`, Turkish `Roma'da`); queries and the titles
    /// they are compared with as a whole go through it alike.
    static func stripApostropheSuffixes(_ folded: String, _ suffixes: NSRegularExpression?) -> String {
        guard let suffixes else { return folded }
        return suffixes.stringByReplacingMatches(
            in: folded, range: NSRange(folded.startIndex..., in: folded), withTemplate: "")
    }

    /// A title or phrase as one normalized string of words (`Noël` → `noel`,
    /// `New Year's Eve` → `new year eve` where `'s` is a stripped suffix).
    static func normalizedTitle(_ text: String, apostropheSuffixes: NSRegularExpression?) -> String? {
        let words = TripSearchText.rawTokens(stripApostropheSuffixes(fold(text), apostropheSuffixes))
            .compactMap { TripSearch.normalizedSearchForms($0.text).first }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The trip's first and last day (start of day in `calendar`); an
    /// ongoing trip's run to `today` when the parse has one.
    static func dayRange(
        _ document: TripSearchDocument, today: Date?, calendar: Calendar
    ) -> (first: Date, last: Date) {
        let first = calendar.startOfDay(for: document.startDate)
        let end = document.endDate ?? ongoingEnd(document, today: today) ?? document.startDate
        return (first, max(first, calendar.startOfDay(for: end)))
    }

    /// The last day of an ongoing trip (no end date): `today`, once it has
    /// started. An undated plan (`Upcoming` starts one at `distantPast`)
    /// has no days to extend.
    private static func ongoingEnd(_ document: TripSearchDocument, today: Date?) -> Date? {
        guard document.endDate == nil, let today, yearUniverse.contains(document.startYear) else { return nil }
        return max(today, document.startDate)
    }

    /// Whether the trip's days (start to end, in `calendar`) overlap one of
    /// `holidays` in a year of `years` (any year when empty).
    static func overlapsHoliday(
        _ document: TripSearchDocument,
        _ holidays: Set<TripQueryHoliday>,
        years: Set<Int>,
        calendar: Calendar,
        today: Date? = nil
    ) -> Bool {
        guard !holidays.isEmpty else { return false }
        let (first, last) = dayRange(document, today: today, calendar: calendar)
        let lastYear = calendar.component(.year, from: last)
        let startYear = calendar.component(.year, from: first)
        // A New Year's main day is in the year after its eve; a year-end
        // window (`年末年始`) runs into the year after its anchor.
        for year in (startYear - 1)...(lastYear + 1) where years.isEmpty || years.contains(year) {
            for holiday in holidays {
                for window in holiday.windows(in: year) {
                    guard let start = calendar.date(from: window.first), let end = calendar.date(from: window.last)
                    else { continue }
                    if first <= end, last >= start { return true }
                }
            }
        }
        return false
    }

    /// Whether the trip's days cover a day of a day clause, in one of its
    /// years (any year when it has none).
    static func coversDay(
        _ document: TripSearchDocument,
        _ dates: DateFilter,
        calendar: Calendar,
        today: Date? = nil
    ) -> Bool {
        guard dates.hasDays else { return false }
        let (first, last) = dayRange(document, today: today, calendar: calendar)
        let startYear = calendar.component(.year, from: first)
        let lastYear = calendar.component(.year, from: last)
        for clause in dates.effectiveClauses where !clause.days.isEmpty {
            for day in clause.days {
                // A season's month counts from its own year (`15 january
                // last winter` is in the January after that December).
                let offsets = clause.months.isEmpty ? [0] : clause.months.filter { $0.month == day.month }.map(\.yearOffset)
                for year in startYear...lastYear
                where offsets.contains(where: { clause.years.isEmpty || clause.years.contains(year - $0) }) {
                    guard let date = calendar.date(from: DateComponents(year: year, month: day.month, day: day.day)),
                          calendar.component(.day, from: date) == day.day
                    else { continue }
                    if first <= date, last >= date { return true }
                }
            }
        }
        return false
    }

    /// Whether an engine-pass match satisfies the syntax the engine never
    /// saw (`ParsedQuery.consumedConstraints`), and the holidays in the
    /// years of every date, a bare year the engine matches as text
    /// included ("christmas 2024").
    static func matchesConsumedSyntax(
        _ document: TripSearchDocument, parsed: ParsedQuery, calendar: Calendar
    ) -> Bool {
        var constraints = parsed.consumedConstraints
        // Unpaired months restrict a day (`15 august july`) though the
        // engine sees them as text.
        if constraints.dates.hasDays { constraints.dates.looseMonths.formUnion(parsed.dates.looseMonths) }
        if !parsed.holidays.isEmpty {
            constraints.holidays = parsed.holidays
            constraints.dates.looseYears.formUnion(parsed.dates.years)
        }
        return matchesFilters(document, parsed: constraints, calendar: calendar)
    }

    /// Date clauses and durations only (no place terms). Durations
    /// AND-combine with the dates and require a non-nil duration; the date
    /// clauses OR-combine, each pairing its own months and years. A season
    /// that crosses New Year wraps the way a human means it: "winter 2024" is
    /// Dec 2024 to Feb 2025. A clause matches any civil month covered through
    /// the end date, not only the start (read in the document's calendar).
    static func matchesFilters(
        _ document: TripSearchDocument,
        parsed: ParsedQuery,
        calendar: Calendar = TripFilters.yearCalendar
    ) -> Bool {
        guard !parsed.admitsNothing else { return false }
        if let minDays = parsed.minDurationDays {
            guard let days = document.durationDays, days >= minDays else { return false }
        }
        if let maxDays = parsed.maxDurationDays {
            guard let days = document.durationDays, days <= maxDays else { return false }
        }
        guard parsed.facets.isSubset(of: document.facets), parsed.excludedFacets.isDisjoint(with: document.facets)
        else { return false }
        // An ongoing trip's days run to today here too.
        if parsed.requiresWeekend, !hasWeekendDay(document, today: parsed.today, calendar: calendar) { return false }
        if let recentStart = parsed.recentStart {
            let (first, last) = dayRange(document, today: parsed.today, calendar: calendar)
            guard last >= recentStart, parsed.today.map({ first <= $0 }) ?? true else { return false }
        }
        if !parsed.holidays.isEmpty {
            guard overlapsHoliday(document, parsed.holidays, years: parsed.dates.years, calendar: calendar, today: parsed.today)
            else { return false }
            // The years name the holiday's window ("new year 2024" is 31
            // December 2023 too), not calendar years of their own; months
            // and days restrict it alike ("or" between them is two readings).
            if parsed.dates.months.isEmpty, !parsed.dates.hasDays { return true }
        }
        guard !parsed.dates.isEmpty else { return true }
        if coversDay(document, parsed.dates, calendar: calendar, today: parsed.today) { return true }
        if parsed.dates.matches(year: document.startYear, month: document.startMonth) { return true }
        guard let end = document.endDate ?? ongoingEnd(document, today: parsed.today) else { return false }
        let components = calendar.dateComponents([.year, .month], from: end)
        guard let year = components.year, let month = components.month else { return false }
        if parsed.dates.matches(year: year, month: month) { return true }
        let firstMonth = document.startYear * 12 + document.startMonth - 1
        let lastMonth = year * 12 + month - 1
        guard firstMonth < lastMonth else { return false }
        // Compare month intervals rather than walking potentially decades-long trips.
        return parsed.dates.effectiveClauses.contains { clause in
            guard clause.days.isEmpty else { return false }
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

    /// Whether one of the trip's first days (a week at most) is a weekend
    /// day of `calendar`.
    private static func hasWeekendDay(_ document: TripSearchDocument, today: Date?, calendar: Calendar) -> Bool {
        let (first, last) = dayRange(document, today: today, calendar: calendar)
        let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return (0..<min(max(days, 1), 7)).contains { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map(calendar.isDateInWeekend) ?? false
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
        reduced.namePhrases = parsed.namePhrases
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
    /// relative-date and filler vocabulary; English is always active too
    /// (see `queryLanguageTags`). With the searched `corpus`, a misspelt
    /// date word that matches no trip reads as the word it misspells
    /// (`correctDateTypos`).
    static func parse(
        _ query: String,
        now: Date = .now,
        calendar: Calendar = TripFilters.yearCalendar,
        languageTag: String = AppLanguagePreference.currentTag(),
        corpus: TripSearchIndex? = nil
    ) -> ParsedQuery {
        parse(query, now: now, calendar: calendar, languageTag: languageTag, corpus: corpus, typing: false)
    }

    /// `typing` (with a corpus) when the last word is still being typed: it
    /// enables trailing completion (`summ` → summer) and keeps a trailing
    /// filler word that starts a place name (`war` → Warsaw).
    private static func parse(
        _ query: String,
        now: Date,
        calendar: Calendar,
        languageTag: String,
        corpus: TripSearchIndex?,
        typing: Bool
    ) -> ParsedQuery {
        let typing = typing ? corpus : nil
        var tags = queryLanguageTags(query, languageTag: languageTag)
        var lexicon = lexicon(for: tags)
        var working = stripApostropheSuffixes(fold(query), lexicon.apostropheSuffixes)
        if tags.contains("sv"), working.contains(":"), let ordinals = Regexes.swedishOrdinalDays {
            working = ordinals.stringByReplacingMatches(
                in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "$1$2")
        }
        var queryUnits = units(of: working, protecting: lexicon.protectedPhrases)
        // Names first: a known multiword name is place text before any of
        // its words can read as syntax (`Cape May`, `Spring Hill`).
        let names = protectNames(&queryUnits, lexicon: lexicon, corpus: corpus, languageTag: languageTag)
        // Greeklish date and kind words (`kalokairi 2025`, `pasxa`) read as
        // the Greek words they spell, Greek vocabulary active.
        if foldGreeklish(&queryUnits, lexicon: lexicon, corpus: corpus), !tags.contains("el") {
            tags.append("el")
            lexicon = Self.lexicon(for: tags)
        }
        var scan = Scan(units: queryUnits, lexicon: lexicon, now: now, calendar: calendar)
        scan.nameSpans = names
        scan.parsed.namePhrases = names.compactMap(\.key)
        scan.disjunctionPositions = disjunctionPositions(queryUnits, query: query, lexicon: lexicon)
        if let index = typing { scan.completeTypedWord(index: index) }
        // First: a place a via word marks is a place, never a date, holiday
        // or kind word (`via Natal`).
        scan.consumeVia(corpus: corpus)
        if let corpus { scan.correctDateTypos(corpus: corpus, languageTag: languageTag) }
        // Holiday phrases before the words inside them (`Labor Day weekend`,
        // `puente de mayo`, `zwischen den Jahren`).
        scan.consumeHolidays()
        scan.consumeYearsAgo()
        // Before durations: `last 2 weeks` is a span, not a trip length.
        scan.consumeRecentSpans()
        scan.consumeDurations()
        scan.consumeSuperlatives()
        scan.consumeLengthWords()
        scan.consumeWeekends()
        scan.consumeFacets()
        scan.consumeYearBounds()
        // Before month-year pairs: `15 august 2024` is one day.
        scan.consumeDayDates()
        scan.consumeDatesWithYear(corpus: corpus)
        scan.consumeFrames()
        scan.consumeRelativePhrases()
        scan.consumeRecentSeasons()
        // After the frames: "last summer" is a date, "last trip" an ordinal.
        scan.consumeOrdinals(typing: typing, corpus: corpus)
        // Before bare date words: French `ai été` is "have been", not summer.
        scan.consumeFillerPhrases()
        scan.consumeBareDateWords()
        scan.classifyRemaining(typing: typing, corpus: corpus)
        return scan.result(languageTag: languageTag, isTyping: typing != nil)
    }

    /// A name the name pass kept whole: its units and, for a name some trip
    /// has, its `TripSearchIndex.namePhrase` key (nil for a country or
    /// region alias such as Canary Islands).
    fileprivate struct NameSpan {
        let range: Range<Int>
        let key: String?
    }

    /// The name pass. Leftmost-longest, each window of two or more open
    /// words that holds a syntax word (a month, season, weekend, length,
    /// facet, holiday, via, count or filler word) is marked place text when
    /// it is a country or region alias (`British Isles`), or when some
    /// trip's place, region or country has it as adjacent words of one
    /// value and it is either that whole value or holds a word that is not
    /// syntax (`Cape May`, `Spring Hill`, `Ha Long`; `Weekend Island` only
    /// as a whole name). One syntax word alone is never kept here (a town
    /// called May leaves `May 2024` a date; the place reading still tries
    /// a bare `may` first), and an interior run of syntax words of a longer
    /// name (`long weekend` of Long Weekend Island) is no name.
    private static func protectNames(
        _ units: inout [Unit], lexicon: Lexicon, corpus: TripSearchIndex?, languageTag: String
    ) -> [NameSpan] {
        func eligible(_ position: Int) -> Bool {
            position < units.count && units[position].special == nil && units[position].role == .open
        }
        var spans: [NameSpan] = []
        var start = 0
        while start < units.count {
            var end = start
            while end < units.count, end - start < TripSearchIndex.maxNameWords, eligible(end) { end += 1 }
            var claimed: NameSpan?
            if end - start >= 2 {
                for upper in stride(from: end, through: start + 2, by: -1) {
                    let range = start..<upper
                    guard range.contains(where: { lexicon.isSyntax(units[$0].key) }) else { continue }
                    let distinctive = range.contains { !lexicon.isSyntax(units[$0].key) }
                    let last = units[upper - 1].key
                    let endsInFunction = lexicon.filler.contains(last) || lexicon.ambiguousFunction.contains(last)
                    if let corpus, let phrase = corpus.namePhrase(nameKey(units, range)), phrase.isDestination,
                       phrase.isCompleteDestination || (distinctive && !endsInFunction) {
                        claimed = NameSpan(range: range, key: nameKey(units, range))
                        break
                    }
                    if upper - start <= 3 {
                        let terms = TripSearch.terms(
                            units[range].map(\.text).joined(separator: " "), languageTag: languageTag,
                            allowsTrailingPartial: false)
                        if terms.count == 1, !terms[0].countryCodes.isEmpty {
                            claimed = NameSpan(range: range, key: nil)
                            break
                        }
                    }
                }
            }
            if let claimed {
                for position in claimed.range { units[position].role = .place }
                spans.append(claimed)
                start = claimed.range.upperBound
            } else {
                start += 1
            }
        }
        return spans
    }

    /// Units' keys as a name phrase key: words joined by spaces, the
    /// segments of one Han or kana token joined as written (`夏威夷`).
    private static func nameKey(_ units: [Unit], _ range: Range<Int>) -> String {
        var key = ""
        for position in range {
            if position > range.lowerBound, units[position].token != units[position - 1].token { key += " " }
            key += units[position].key
        }
        return key
    }

    /// Greek vocabulary words people write in Latin letters (months,
    /// seasons, weekends, holidays, trip kinds, relative years, trip
    /// nouns, ordinals, superlatives) by Greeklish skeleton
    /// (`TripSearchText.greeklishSkeletons`), each with its Greek parser
    /// key, each word of a phrase on its own (`polles xwres`); a skeleton
    /// two words share is left out.
    private static let greeklishVocabulary: [String: String] = {
        let greek = TripQueryVocabulary.secondary("el")
        let words = Array(greek.months.keys) + Array(greek.seasons.keys) + Array(greek.weekendWords)
            + Array(greek.holidayWords.keys) + Array(greek.facetWords.keys) + greek.lastYearPhrases
            + greek.thisYearPhrases + greek.yearBeforeLastPhrases + Array(greek.tripNouns)
            + Array(greek.ordinalWords.keys) + Array(greek.superlativeWords.keys)
        var table: [String: String?] = [:]
        for word in words {
            guard let form = TripSearch.normalizedSearchForms(fold(word)).first else { continue }
            for key in form.split(separator: " ").map(String.init) {
                for skeleton in TripSearchText.greeklishSkeletons(key) {
                    if let existing = table[skeleton], existing != key { table[skeleton] = .some(nil) } else { table[skeleton] = key }
                }
            }
        }
        return table.compactMapValues { $0 }
    }()

    /// Rewrites each Latin word of four or more letters that no vocabulary
    /// word and no trip has as typed, and whose Greeklish skeleton is a Greek
    /// vocabulary word's, to that Greek word. True when one changed.
    private static func foldGreeklish(_ units: inout [Unit], lexicon: Lexicon, corpus: TripSearchIndex?) -> Bool {
        var changed = false
        for position in units.indices where units[position].special == nil && units[position].role == .open {
            let key = units[position].key
            guard key.count >= 4, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }),
                  !lexicon.contextKeys.contains(key), !lexicon.filler.contains(key),
                  corpus?.containsWord(key) != true
            else { continue }
            for skeleton in TripSearchText.greeklishSkeletons(key) {
                guard let greek = greeklishVocabulary[skeleton] else { continue }
                units[position].key = greek
                changed = true
                break
            }
        }
        return changed
    }

    /// Lowercased, diacritic- and width-folded working text (fullwidth
    /// digits become ASCII, `tháng` becomes `thang`).
    private static func fold(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// A word lowercased and width-folded with its accents kept, composed
    /// (`Ή` and a decomposed `ή` spell `ή`, apart from the article `η`).
    private static func accentSpelling(_ word: String) -> String {
        word.lowercased().folding(options: [.widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// The units that are "or" words: those with an "or" key, except one
    /// the query spells like a lookalike (`Lexicon.disjunctionLookalikes`),
    /// so in `Αθήνα ή η Ρώμη` only `ή` is "or" and `η` stays an article.
    /// Capitals often drop accents, so a capital without one (`ΑΘΗΝΑ Η
    /// ΡΩΜΗ`) can't be told apart and stays "or", as every "or" key reads.
    /// Folding keeps the order of the words, so the query's words with an
    /// "or" key give that key's units their spellings in turn.
    private static func disjunctionPositions(_ units: [Unit], query: String, lexicon: Lexicon) -> Set<Int> {
        enum Spelling { case or, lookalike }
        var spellings: [String: [Spelling]] = [:]
        if !lexicon.disjunctionLookalikes.isEmpty {
            for token in TripSearchText.rawTokens(query) {
                guard let key = TripSearch.normalizedSearchForms(token.text).first, lexicon.disjunctions.contains(key)
                else { continue }
                let spelling = accentSpelling(token.text)
                spellings[key, default: []].append(
                    !lexicon.disjunctionLookalikes.contains(spelling)
                        || token.text != token.text.lowercased() && spelling == fold(token.text) ? .or : .lookalike)
            }
        }
        var seen: [String: Int] = [:]
        var positions = Set<Int>()
        for (position, unit) in units.enumerated() where unit.special == nil && lexicon.disjunctions.contains(unit.key) {
            let occurrence = seen[unit.key, default: 0]
            seen[unit.key] = occurrence + 1
            let spelling: Spelling = spellings[unit.key].flatMap { occurrence < $0.count ? $0[occurrence] : nil } ?? .or
            if spelling == .or { positions.insert(position) }
        }
        return positions
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
            /// `2年前`, `2년 전`: this many years before the current one.
            case yearsAgo(Int)
            /// `8月15日`, `ngày 15 tháng 8`: a day without its year.
            case monthDay(month: Int, day: Int)
            /// `2024-08-15`.
            case date(year: Int, month: Int, day: Int)
            /// `2泊3日`, `3日間`, `1週間以上`: trip-length bounds.
            case length(min: Int?, max: Int?)
            /// `過去3ヶ月`, `최근 6개월`: a recent span of `count` units.
            case recentSpan(count: Int, unit: TripQueryVocabulary.SpanUnit)
            /// `3回目`, `第3次`, `3번째`: the nth time (an ordinal on its own).
            case ordinal(Int)
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
        /// Joined to the next word by a hyphen (`ile-de-france`).
        var joinsNext = false
        /// A period right after the word (German ordinal `3. Reise`).
        var dotFollows = false
    }

    /// Numeric patterns first (CJK has no word breaks and `+` / `-` are
    /// separators), then raw tokens of the gaps, Han and kana split into
    /// segments so `去年の夏` reads as 去年 / の / 夏. `protecting` phrases
    /// stay one unit wherever they occur (the segmenter reads `一昨年の`
    /// as 一昨 / 年 / の).
    private static func units(of working: String, protecting: [(text: String, key: String)] = []) -> [Unit] {
        var specials: [(range: Range<String.Index>, special: Unit.Special)] = []
        func scan(_ regex: NSRegularExpression?, _ make: ([String]) -> Unit.Special?) {
            guard let regex else { return }
            for match in regex.matches(in: working, range: NSRange(working.startIndex..., in: working)) {
                guard let range = Range(match.range, in: working),
                      !specials.contains(where: { $0.range.overlaps(range) })
                else { continue }
                // A group that took no part is empty, so the others keep their places.
                let groups = (1..<match.numberOfRanges).map { group in
                    Range(match.range(at: group), in: working).map { String(working[$0]) } ?? ""
                }
                if let special = make(groups) { specials.append((range, special)) }
            }
        }
        scan(Regexes.isoDate) { groups in
            guard groups.count == 3, let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2])
            else { return nil }
            return .date(year: year, month: month, day: day)
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
        scan(Regexes.yearsAgo) { groups in
            guard let count = groups.first else { return nil }
            return cjkCount(count).map { Unit.Special.yearsAgo($0) }
        }
        scan(Regexes.cjkOrdinal) { groups in
            // Japanese and Hangul in capture 1, Chinese in capture 2.
            guard let count = groups.first(where: { !$0.isEmpty }), let rank = Int(count) ?? TripQueryVocabulary.hanNumerals[count],
                  rank >= 1 else { return nil }
            return .ordinal(rank)
        }
        let numerals = TripQueryVocabulary.hanMonthNumerals
        scan(Regexes.hanMonth) { groups in
            numerals.first { $0.word == groups.first }.map { Unit.Special.month($0.month) }
        }
        scan(Regexes.recentSpan) { groups in
            guard groups.count == 2 else { return nil }
            let unit: TripQueryVocabulary.SpanUnit
            switch groups[1] {
            case "年", "년": unit = .year
            case "週間", "周", "週", "주": unit = .week
            case "日", "天", "일": unit = .day
            default: unit = .month
            }
            if groups[0] == "半" { return unit == .year ? .recentSpan(count: 6, unit: .month) : nil }
            return cjkCount(groups[0]).map { .recentSpan(count: $0, unit: unit) }
        }
        scan(Regexes.cjkMonthDay) { groups in
            guard groups.count == 2, let month = Int(groups[0]), let day = Int(groups[1]) else { return nil }
            return .monthDay(month: month, day: day)
        }
        scan(Regexes.vietnameseDay) { groups in
            guard groups.count == 2, let day = Int(groups[0]), let month = Int(groups[1]) else { return nil }
            return .monthDay(month: month, day: day)
        }
        scan(Regexes.cjkDuration) { groups in cjkLength(groups) }
        scan(Regexes.cjkYear) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.year($0) } }
        scan(Regexes.cjkMonth) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.month($0) } }
        scan(Regexes.vietnameseMonth) { groups in groups.first.flatMap { Int($0) }.map { Unit.Special.month($0) } }
        specials.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result: [Unit] = []
        var token = 0
        func addWords(_ text: Substring) {
            let text = String(text)
            let scalars = text.unicodeScalars
            for raw in TripSearchText.rawTokens(text) {
                // A hyphen right after the word with a word right after it.
                var joinsNext = false
                if raw.range.upperBound < scalars.endIndex, ["-", "\u{2010}"].contains(scalars[raw.range.upperBound]) {
                    let next = scalars.index(after: raw.range.upperBound)
                    joinsNext = next < scalars.endIndex && !TripSearchText.separators.contains(scalars[next])
                }
                let dotFollows = raw.range.upperBound < scalars.endIndex && scalars[raw.range.upperBound] == "."
                var pieces: [(text: String, key: String)] = []
                for piece in protectedSplit(raw.text, protecting) {
                    if let key = piece.key {
                        pieces.append((piece.text, key))
                    } else {
                        pieces += unitKeys(TripSearch.normalizedSearchForms(piece.text).first ?? "").map { ($0, $0) }
                    }
                }
                guard !pieces.isEmpty else { continue }
                if pieces.count == 1 {
                    result.append(Unit(text: raw.text, key: pieces[0].key, token: token))
                } else {
                    result.append(contentsOf: pieces.map { Unit(text: $0.text, key: $0.key, token: token) })
                }
                result[result.count - 1].joinsNext = joinsNext
                result[result.count - 1].dotFollows = dotFollows
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

    /// Digits or a Han number to 99 (`三`, `十二`, `二十`, `二十一`).
    private static func cjkCount(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        let numerals = TripQueryVocabulary.hanNumerals
        guard !text.isEmpty, text.allSatisfy({ numerals[String($0)] != nil }) else { return nil }
        let digits = text.map { numerals[String($0)]! }
        switch digits.count {
        case 1: return digits[0]
        case 2 where digits[0] == 10 && digits[1] < 10: return 10 + digits[1]
        case 2 where digits[1] == 10 && digits[0] < 10: return digits[0] * 10
        case 3 where digits[1] == 10 && digits[0] < 10 && digits[2] < 10: return digits[0] * 10 + digits[2]
        default: return nil
        }
    }

    /// A Han or Hangul length (`NumericPattern.cjkDuration`): nights are one
    /// day short of the trip (`2泊` is 3 days, `2泊3日` exactly 3), day counts
    /// are exact, weeks keep the English tolerance of a seventh, and
    /// `以上` / `以下` make the count a bound. A bare `日` / `일` is a date.
    private static func cjkLength(_ groups: [String]) -> Unit.Special? {
        // Missing optional groups come back empty or absent.
        let parts = groups + Array(repeating: "", count: max(0, 4 - groups.count))
        guard let count = cjkCount(parts[0]), count > 0 else { return nil }
        let unit = parts[1], following = cjkCount(parts[2]), bound = parts[3]
        let days: Int
        var tolerance = 0
        switch unit {
        case "泊", "박": days = following ?? count + 1
        case "日", "일": guard !bound.isEmpty else { return nil }; days = count
        case "日間", "일간", "天": days = count
        default:
            days = clampedProduct(count, 7)
            tolerance = count
        }
        switch bound {
        case "以上", "이상": return .length(min: days, max: nil)
        case "以下", "이하": return .length(min: nil, max: days)
        default: return .length(min: days - tolerance, max: days + tolerance)
        }
    }

    /// `text` cut around its leftmost protected phrase (longest first at a
    /// position), recursively; protected pieces carry their key.
    private static func protectedSplit(
        _ text: String,
        _ phrases: [(text: String, key: String)]
    ) -> [(text: String, key: String?)] {
        guard !phrases.isEmpty, text.unicodeScalars.contains(where: { TripSearchText.isHanOrKana($0.value) })
        else { return [(text, nil)] }
        var best: (range: Range<String.Index>, key: String)?
        for phrase in phrases {
            guard let range = text.range(of: phrase.text) else { continue }
            if best.map({ range.lowerBound < $0.range.lowerBound }) ?? true { best = (range, phrase.key) }
        }
        guard let best else { return [(text, nil)] }
        var result: [(text: String, key: String?)] = []
        if best.range.lowerBound > text.startIndex { result.append((String(text[..<best.range.lowerBound]), nil)) }
        result.append((String(text[best.range]), best.key))
        if best.range.upperBound < text.endIndex {
            result += protectedSplit(String(text[best.range.upperBound...]), phrases)
        }
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
        static let yearsAgo = compile(Pattern.yearsAgo)
        static let cjkOrdinal = compile(Pattern.cjkOrdinal)
        static let hanMonth = compile(
            "(" + TripQueryVocabulary.hanMonthNumerals.map(\.word).joined(separator: "|") + ")")
        static let cjkYear = compile(Pattern.cjkYear)
        static let cjkMonth = compile(Pattern.cjkMonth)
        static let vietnameseMonth = compile(Pattern.vietnameseMonth)
        static let isoDate = compile(Pattern.isoDate)
        static let cjkMonthDay = compile(Pattern.cjkMonthDay)
        static let vietnameseDay = compile(Pattern.vietnameseDay)
        static let cjkDuration = compile(Pattern.cjkDuration)
        static let recentSpan = compile(Pattern.recentSpan)
        /// Swedish `15:e`, `1:a`: a day number's ending after a colon.
        static let swedishOrdinalDays = compile("(?<![0-9])([0-9]{1,2}):(e|a)(?![\\p{L}])")

        static func compile(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        static func prewarm() {
            _ = [
                yearRange, plusDuration, yearsAgo, cjkOrdinal, hanMonth, cjkYear, cjkMonth, vietnameseMonth,
                isoDate, cjkMonthDay, vietnameseDay, cjkDuration, recentSpan,
            ]
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
        let now: Date
        let calendar: Calendar
        let nowYear: Int
        let nowMonth: Int
        var parsed = ParsedQuery()
        /// Ambiguous date and holiday words by unit position.
        var ambiguous: [(position: Int, text: String)] = []
        /// Bounds of the length words, applied after every other duration.
        var lengthMin: Int?
        var lengthMax: Int?
        /// Positions of the length words.
        var lengthPositions: Set<Int> = []
        var holidayUnits: [(range: Range<Int>, holidays: Set<TripQueryHoliday>)] = []
        /// Names the name pass kept whole (`protectNames`).
        var nameSpans: [NameSpan] = []
        /// A known name a via word took whole; units right after a via word
        /// without one, and right before a trailing one (a run of place words).
        var viaNames: [Range<Int>] = []
        var viaAfterPositions: [Int] = []
        var viaBeforePositions: [Int] = []
        var yearBoundCount = 0
        /// Units that are "or" words (`TripQueryParser.disjunctionPositions`).
        var disjunctionPositions: Set<Int> = []

        init(units: [Unit], lexicon: Lexicon, now: Date, calendar: Calendar) {
            self.units = units
            self.lexicon = lexicon
            self.now = now
            self.calendar = calendar
            nowYear = calendar.component(.year, from: now)
            nowMonth = calendar.component(.month, from: now)
            parsed.today = now
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
                guard key.count == 4, key.allSatisfy(\.isASCII), let year = Int(key), yearUniverse.contains(year)
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
            let clause = DateClause(months: word.datedMonths, years: Set(years), shoulders: word.shoulderMonths)
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
            let shoulders = word.shoulderMonths
            parsed.dates.looseMonths.formUnion(months)
            parsed.dates.looseShoulders.formUnion(shoulders)
            guard anchored else { return }
            parsed.unambiguousDates.looseMonths.formUnion(months)
            parsed.unambiguousDates.looseShoulders.formUnion(shoulders)
            parsed.consumedDates.looseMonths.formUnion(months)
            parsed.consumedDates.looseShoulders.formUnion(shoulders)
        }

        /// The year of the most recent completed season.
        func lastYear(of season: Season) -> Int {
            if season.wraps {
                // Winters are labeled by their first month's year; the winter
                // that ended Feb `y` is winter `y-1`. Mid-winter (Jan/Feb), the
                // last COMPLETED one ended the previous February.
                return nowMonth >= 3 ? nowYear - 1 : nowYear - 2
            }
            return nowMonth > season.finalMonth ? nowYear : nowYear - 1
        }

        func thisYear(of season: Season) -> Int {
            season.wraps && nowMonth <= season.finalMonth ? nowYear - 1 : nowYear
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
                  lexicon.units[key] == nil,
                  !TripQueryVocabulary.weekDurationNouns.contains(key),
                  !(isCount(at: last - 1) && isDurationUnitPrefix(key)),
                  !index.containsWord(key), index.strictPlaceWords(withPrefix: key).isEmpty,
                  let completion = lexicon.completion(for: key)
            else { return }
            units[last].key = completion
        }

        /// A misspelt month, season or weekend word (`Agust`, `Septmber`,
        /// `wekend`, `Aprl`) reads as the word it misspells: a word of 5+
        /// letters (4 with one letter dropped) that is not vocabulary, filler,
        /// a duration unit or a word of any trip, within one edit (two when
        /// both words have 8+ letters) of
        /// single-word date keys of 4+ letters with the same first letter
        /// and exactly one meaning, and that the engine matches in no trip
        /// at any tier. A corrected bare month stays ambiguous like a typed
        /// one, so the place reading still runs first.
        mutating func correctDateTypos(corpus: TripSearchIndex, languageTag: String) {
            var distance = EditDistance()
            for position in units.indices where isOpenWord(position) {
                let key = units[position].key
                let scalars = key.unicodeScalars.map(\.value)
                guard scalars.count >= 4, key.allSatisfy(\.isLetter), !lexicon.isVocabulary(key),
                      !lexicon.filler.contains(key), lexicon.units[key] == nil, !corpus.containsWord(key)
                else { continue }
                var hit: (key: String, meaning: String)?
                var ambiguous = false
                for (candidate, meaning) in lexicon.completions {
                    let other = candidate.unicodeScalars.map(\.value)
                    guard other.count >= 4, other.first == scalars.first,
                          scalars.count >= 5 || other.count == scalars.count + 1 else { continue }
                    let limit = min(scalars.count, other.count) >= 8 ? 2 : 1
                    guard distance.within(scalars[...], other[...], limit: limit) != nil else { continue }
                    if let hit, hit.meaning != meaning { ambiguous = true; break }
                    if hit == nil { hit = (candidate, meaning) }
                }
                guard let hit, !ambiguous else { continue }
                let terms = TripSearch.terms(units[position].text, languageTag: languageTag, allowsTrailingPartial: false)
                guard TripSearch.match(terms: terms, in: corpus).isEmpty else { continue }
                units[position].key = hit.key
            }
        }

        /// A count: digits that are not a year, a number word or an article.
        func isCount(at position: Int) -> Bool {
            guard isOpenWord(position) else { return false }
            let key = units[position].key
            if !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) { return years(at: position) == nil }
            return TripQueryVocabulary.countArticles.contains(key)
                || TripQueryVocabulary.englishNumberWords[key] != nil
                || lexicon.counts[key] != nil
        }

        func isDurationUnitPrefix(_ key: String) -> Bool {
            lexicon.units.keys.contains { $0.hasPrefix(key) }
                || TripQueryVocabulary.weekDurationNouns.contains { $0.hasPrefix(key) }
        }

        /// A count at `position`: digits, an English number word (one or
        /// two words), `a` / `an`, or an app-language count word.
        func count(at position: Int) -> (value: Int, length: Int)? {
            guard isOpenWord(position) else { return nil }
            let key = units[position].key
            if !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) { return (Int(key) ?? Int.max, 1) }
            if key == "a" || key == "an" { return (1, 1) }
            if isOpenWord(position + 1),
               let pair = TripQueryVocabulary.englishNumberWords[key + " " + units[position + 1].key] {
                return (pair, 2)
            }
            return (TripQueryVocabulary.englishNumberWords[key] ?? lexicon.counts[key]).map { ($0, 1) }
        }

        /// One year (a bare 4-digit word or `2024年`) as a pattern slot.
        func singleYear(at position: Int) -> (length: Int, value: Int)? {
            guard let years = years(at: position), years.count == 1 else { return nil }
            return (1, years[0])
        }

        /// `parts` around slots read by `slot`, starting at `position`: the
        /// slot values and the number of words matched.
        func match<Value>(
            _ parts: [[String]],
            at position: Int,
            slot: (Int) -> (length: Int, value: Value)?
        ) -> (values: [Value], length: Int)? {
            var cursor = position
            var values: [Value] = []
            for (offset, part) in parts.enumerated() {
                guard matches(part, at: cursor) else { return nil }
                cursor += part.count
                guard offset < parts.count - 1 else { break }
                guard let hit = slot(cursor) else { return nil }
                values.append(hit.value)
                cursor += hit.length
            }
            return (values, cursor - position)
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
            guard let count = count(at: position), isOpenWord(position + count.length),
                  let unit = lexicon.units[units[position + count.length].key]
            else { return nil }
            let days = clampedProduct(count.value, unit)
            return (days, unit >= 7 ? days / 7 : 0, count.length + 1)
        }

        /// A comparative (`longer than _`, `_ or more`, `plus d'_`, German
        /// `über _`) starting at `position`, longest first.
        func comparative(at position: Int) -> (kind: DurationBound, days: Int, length: Int)? {
            guard isOpenWord(position) else { return nil }
            for pattern in lexicon.durationPatterns.candidates(units[position].key, slotFirst: count(at: position) != nil) {
                guard let hit = match(pattern.parts, at: position, slot: { start in
                    quantity(at: start).map { ($0.length, $0.days) }
                }) else { continue }
                return (pattern.kind, hit.values[0], hit.length)
            }
            return nil
        }

        /// Duration phrases in the FM tool's min/max semantics. Returns the
        /// number of words consumed at `position`.
        mutating func duration(at position: Int) -> Int? {
            guard isOpenWord(position) else { return nil }
            if let bound = comparative(at: position) {
                let days = bound.days
                switch bound.kind {
                case .longer:
                    // `n == Int.max` parses fine ("more than 9223372036854775807
                    // days") and `n + 1` would trap: clamp instead of overflowing.
                    setMin(days == Int.max ? days : days + 1)
                case .shorter: setMax(days - 1)
                case .atLeast: setMin(days)
                case .atMost: setMax(days)
                }
                return bound.length
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
            if let dayTrip = longest(lexicon.dayTrips, at: position) {
                setMax(1)
                return dayTrip.keys.count
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

        /// Length words are trip lengths only next to a trip noun or weekend
        /// word, in the order their language puts adjectives ("long trips",
        /// "kurze Reise", Spanish "viaje largo"): long is 8+ days (as "longer
        /// than a week"), short 3 or fewer, a long
        /// weekend 3 to 4. Elsewhere they are place text (Long
        /// Beach, Short Hills, Key Largo), and a known name ending in one
        /// stays whole (`protectNames`: "Ha Long trips").
        mutating func consumeLengthWords() {
            for position in units.indices where isOpenWord(position) {
                if let phrase = longest(lexicon.lengthPhrases, at: position) {
                    for offset in 1..<max(phrase.keys.count, 1) where isOpenWord(position + offset) {
                        units[position + offset].role = .filler
                        lengthPositions.insert(position + offset)
                    }
                    applyLength(phrase.value, at: position, weekend: nil)
                    continue
                }
                let key = units[position].key
                if let isLong = lexicon.lengthBefore[key], isOpenWord(position + 1) {
                    if let weekend = longest(lexicon.weekends, at: position + 1) {
                        applyLength(isLong, at: position, weekend: (position + 1)..<(position + 1 + weekend.keys.count))
                    } else if lexicon.tripNouns.contains(units[position + 1].key) {
                        applyLength(isLong, at: position, weekend: nil)
                    } else {
                        continue
                    }
                } else if let isLong = lexicon.lengthAfter[key], position > 0 {
                    if isOpenWord(position - 1), lexicon.tripNouns.contains(units[position - 1].key) {
                        applyLength(isLong, at: position, weekend: nil)
                    } else if let start = (max(0, position - 4)..<position).first(where: { start in
                        longest(lexicon.weekends, at: start).map { start + $0.keys.count == position } ?? false
                    }) {
                        applyLength(isLong, at: position, weekend: start..<position)
                    }
                }
            }
        }

        /// A long weekend hides its weekend word from `consumeWeekends`; a
        /// short one is just a weekend.
        mutating func applyLength(_ isLong: Bool, at position: Int, weekend: Range<Int>?) {
            units[position].role = .filler
            lengthPositions.insert(position)
            parsed.droppedNoise = true
            parsed.consumedSyntax = true
            if let weekend {
                guard isLong else { return }
                mark(weekend, .removed)
                parsed.requiresWeekend = true
                lengthMin = max(lengthMin ?? 3, 3)
                lengthMax = min(lengthMax ?? 4, 4)
            } else if isLong {
                lengthMin = max(lengthMin ?? 8, 8)
            } else {
                lengthMax = min(lengthMax ?? 3, 3)
            }
        }

        /// "two years ago", "vor 2 Jahren", "il y a deux ans": the calendar
        /// year that many years back, like "last year" for one.
        mutating func consumeYearsAgo() {
            for position in units.indices where isOpenWord(position) {
                let candidates = lexicon.agoPatterns.candidates(units[position].key, slotFirst: count(at: position) != nil)
                for pattern in candidates {
                    guard let hit = match(pattern.parts, at: position, slot: { count(at: $0).map { ($0.length, $0.value) } })
                    else { continue }
                    addLooseYears([nowYear - min(hit.values[0], nowYear)], consumed: true)
                    mark(position..<(position + hit.length), .removed)
                    parsed.consumedSyntax = true
                    break
                }
            }
        }

        /// "since 2025", "before 2018", "between 2019 and 2021" and their
        /// translations: the admitted years as loose years (see the scope
        /// notes), so they pair with month words and keep overlap matching.
        /// Bounds intersect ("after 2019 and before 2023"); disjoint ones
        /// admit nothing. "before 2015 or after 2020" is two readings joined
        /// by "or" (`disjunctionSides`).
        mutating func consumeYearBounds() {
            var admitted = Set<Int>()
            var bounded = false
            for position in units.indices where units[position].role == .open {
                let candidates = lexicon.yearPatterns.candidates(units[position].key, slotFirst: singleYear(at: position) != nil)
                for pattern in candidates {
                    guard let hit = match(pattern.parts, at: position, slot: singleYear) else { continue }
                    let year = hit.values[0]
                    let range: ClosedRange<Int>?
                    switch pattern.kind {
                    case .since: range = year...yearUniverse.upperBound
                    case .after: range = year < yearUniverse.upperBound ? (year + 1)...yearUniverse.upperBound : nil
                    case .before: range = year > yearUniverse.lowerBound ? yearUniverse.lowerBound...(year - 1) : nil
                    case .until: range = yearUniverse.lowerBound...year
                    case .span: range = min(year, hit.values[1])...max(year, hit.values[1])
                    }
                    let years = range.map { Set($0) } ?? []
                    admitted = bounded ? admitted.intersection(years) : years
                    bounded = true
                    yearBoundCount += 1
                    mark(position..<(position + hit.length), .removed)
                    parsed.consumedSyntax = true
                    break
                }
            }
            guard bounded else { return }
            // An empty bound ("before 1900") admits a year no trip has.
            addLooseYears(admitted.isEmpty ? [yearUniverse.upperBound + 1] : admitted.sorted(), consumed: true)
        }

        /// Facet words ("islands", "abroad", "yurt dışı"); see `ParsedQuery.facets`.
        /// One inside a known name or alias stays place text (`protectNames`:
        /// Rhode Island, Canary Islands), as does one hyphen-joined to a word
        /// (`Île-de-France`). A "without" word next to a kind word (`no
        /// flights`, `ohne Flug`, `飛行機なし`), or a word that says both
        /// (Turkish `uçaksız`), excludes that kind (`ParsedQuery.excludedFacets`).
        mutating func consumeFacets() {
            // A kind word after a "without" word, an article or determiner
            // between them (`without a layover`, `ohne einen Zwischenstopp`).
            func kindAfterWithout(at position: Int) -> (gap: Int, entry: PhraseTable<TripSearchFacet>.Entry)? {
                if let entry = longest(lexicon.facets, at: position) { return (0, entry) }
                guard isOpenWord(position), lexicon.filler.contains(units[position].key),
                      !lexicon.tripNouns.contains(units[position].key),
                      let entry = longest(lexicon.facets, at: position + 1) else { return nil }
                return (1, entry)
            }
            for position in units.indices {
                let kind = longest(lexicon.facets, at: position)
                var length = kind?.keys.count ?? 0
                var excluded: TripSearchFacet?
                if let without = longest(lexicon.withoutBefore, at: position),
                   let next = kindAfterWithout(at: position + without.keys.count) {
                    length = without.keys.count + next.gap + next.entry.keys.count
                    excluded = next.entry.value
                } else if let phrase = longest(lexicon.withoutFacets, at: position) {
                    length = phrase.keys.count
                    excluded = phrase.value
                } else if let kind, let without = longest(lexicon.withoutAfter, at: position + length) {
                    length += without.keys.count
                    excluded = kind.value
                }
                guard length > 0 else { continue }
                let range = position..<(position + length)
                guard !isHyphenJoined(range) else { continue }
                mark(range, .removed)
                if let excluded {
                    parsed.excludedFacets.insert(excluded)
                } else if let kind {
                    parsed.facets.insert(kind.value)
                }
                parsed.consumedSyntax = true
            }
        }

        /// Whether the words at `range` are hyphen-joined to a word outside it.
        func isHyphenJoined(_ range: Range<Int>) -> Bool {
            (range.lowerBound > 0 && units[range.lowerBound - 1].joinsNext)
                || (range.upperBound < units.count && units[range.upperBound - 1].joinsNext)
        }

        /// Holiday words ("Christmas", "Πάσχα", "Silvester"); see
        /// `ParsedQuery.holidays`. One inside a known name or alias stays
        /// place text (`protectNames`: Christmas Island), and `result` makes
        /// every other one ambiguous, so the place reading tries it first
        /// (Natal).
        mutating func consumeHolidays() {
            for position in units.indices {
                guard let entry = longest(lexicon.holidays, at: position) else { continue }
                let range = position..<(position + entry.keys.count)
                guard !isHyphenJoined(range) else { continue }
                mark(range, .removed)
                parsed.holidays.formUnion(entry.value)
                parsed.consumedSyntax = true
                holidayUnits.append((range, entry.value))
            }
        }

        /// "first trip", "my last trip to Valdoria", "3rd Portland trip",
        /// `τελευταίο ταξίδι`, Vietnamese `chuyến đi đầu tiên`: an ordinal
        /// word next to a trip noun (one word may sit between: a function
        /// word, Japanese `最初の旅行`, or one word some trip has as a place
        /// that is no count or syntax, `last Paris trip` but not `last 3
        /// trips` or `last minute trip`), or next to a word that stands in
        /// for one (`ordinalHeads`: `last time in Oslo`, `letztes Mal`,
        /// `最後の東京`, Vietnamese `lần cuối cùng`). "last" with a time word
        /// is the previous visit. A numeric ordinal (`3rd`, `3e`, German `3.`)
        /// reads as its word; a Han or Hangul counter (`3回目`, `第3次`) is an
        /// ordinal on its own. While typing, the typed last word may be the
        /// start of a trip noun (`last tri`) when no trip's place starts with it.
        mutating func consumeOrdinals(typing: TripSearchIndex?, corpus: TripSearchIndex?) {
            func isTripNoun(_ position: Int) -> Bool {
                isOpenWord(position) && (lexicon.tripNouns.contains(units[position].key) || isTypedTripNoun(position))
            }
            func isTypedTripNoun(_ position: Int) -> Bool {
                guard let index = typing, position == units.count - 1, isOpenWord(position) else { return false }
                let key = units[position].key
                return key.count >= 3 && lexicon.tripNouns.contains { $0.hasPrefix(key) }
                    && index.strictPlaceWords(withPrefix: key).isEmpty
            }
            func isHead(_ position: Int) -> Bool {
                isOpenWord(position) && lexicon.ordinalHeads.contains(units[position].key)
            }
            func isGap(_ position: Int) -> Bool {
                guard isOpenWord(position) else { return false }
                let key = units[position].key
                if isFunctionWord(position) { return !lexicon.tripNouns.contains(key) }
                return !lexicon.isSyntax(key) && !isCount(at: position)
                    && corpus?.containsWord(key, in: [.place, .region, .country, .transit]) == true
            }
            func before(at position: Int) -> (length: Int, ordinal: Ordinal)? {
                if let entry = longest(lexicon.ordinalsBefore, at: position) { return (entry.keys.count, entry.value) }
                guard isOpenWord(position) else { return nil }
                let key = units[position].key
                let digits = key.prefix { $0.isASCII && $0.isNumber }
                let suffix = digits.count == key.count && units[position].dotFollows ? "." : String(key.dropFirst(digits.count))
                guard (1...2).contains(digits.count), lexicon.ordinalSuffixes.contains(suffix),
                      let rank = Int(digits), rank >= 1 else { return nil }
                return (1, rank == 1 ? .first : .nth(rank))
            }
            for position in units.indices {
                var taken: (range: Range<Int>, ordinal: Ordinal, head: Int?)?
                if case .ordinal(let rank)? = units[position].special, units[position].role == .open {
                    taken = (position..<(position + 1), rank == 1 ? .first : .nth(rank), nil)
                } else if let word = before(at: position) {
                    let next = position + word.length
                    if isHead(next) {
                        taken = (position..<next, word.ordinal, next)
                    } else if isTripNoun(next) || (isGap(next) && isTripNoun(next + 1)) {
                        taken = (position..<next, word.ordinal, nil)
                    }
                } else if let entry = longest(lexicon.ordinalsAfter, at: position) {
                    let range = position..<(position + entry.keys.count)
                    if isHead(position - 1) {
                        taken = (range, entry.value, position - 1)
                    } else if isTripNoun(position - 1) || (isGap(position - 1) && isTripNoun(position - 2)) {
                        taken = (range, entry.value, nil)
                    }
                }
                guard let taken, !isHyphenJoined(taken.range) else { continue }
                mark(taken.range, .removed)
                // A head that is no filler (`time`, `Mal`) is the ordinal's own word.
                var ordinal = taken.ordinal
                if let head = taken.head, !lexicon.filler.contains(units[head].key) {
                    mark(head..<(head + 1), .removed)
                    if ordinal == .last { ordinal = .previous }
                }
                if taken.head == nil, isTypedTripNoun(units.count - 1) {
                    mark((units.count - 1)..<units.count, .filler)
                    parsed.droppedNoise = true
                }
                parsed.ordinal = ordinal
                parsed.consumedSyntax = true
            }
        }

        /// Superlatives with or without a trip noun ("longest trip",
        /// `längste Reise`, `一番長い旅行`, Spanish `viaje más largo`):
        /// before the length words, which share their words (`長い`,
        /// `largo`); a comparative (`longer than a week`) is a duration and
        /// was read first.
        mutating func consumeSuperlatives() {
            for position in units.indices {
                guard let entry = longest(lexicon.superlatives, at: position) else { continue }
                let range = position..<(position + entry.keys.count)
                guard !isHyphenJoined(range) else { continue }
                mark(range, .removed)
                parsed.ordinal = entry.value
                parsed.consumedSyntax = true
            }
        }

        /// "via Munich", "layover in Frankfurt", Turkish `Münih üzerinden`:
        /// the place next to the via word must be a transit stop (see
        /// `ParsedQuery.viaTerms`). Runs before every other syntax: the via
        /// word takes the longest known name next to it whole (`viaName`),
        /// else one word (`viaClaims`) that `result` extends by the place
        /// words after it. A via word inside a known name stays place text
        /// (`protectNames`: Via Appia), as does one hyphen-joined to a word,
        /// and one that starts a whole duration comparative (German `über
        /// eine Woche` is "more than a week").
        mutating func consumeVia(corpus: TripSearchIndex?) {
            for position in units.indices {
                if let entry = longest(lexicon.viaBefore, at: position) {
                    let word = position..<(position + entry.keys.count)
                    let next = word.upperBound
                    guard next < units.count, !isHyphenJoined(word), comparative(at: position) == nil else { continue }
                    // A bare layover word (`Umstieg`, `escala`, also the layover
                    // kind) claims only the place right after it; its own phrase
                    // forms carry the locative (`Umstieg in`): `Flug mit Umstieg
                    // nach Bangkok` flies to Bangkok.
                    let isBare = longest(lexicon.facets, at: position)?.keys == entry.keys
                    if let name = viaName(after: next, skippingFunctionWord: !isBare, corpus: corpus) {
                        mark(name, .place)
                        viaNames.append(name)
                    } else if !isBare, isFunctionWord(next), isOpenWord(next + 1), !isFunctionWord(next + 1),
                              viaClaims(next + 1, corpus: corpus) {
                        mark((next + 1)..<(next + 2), .place)
                        viaAfterPositions.append(next + 1)
                    } else if !isFunctionWord(next), viaClaims(next, corpus: corpus) {
                        mark(next..<(next + 1), .place)
                        viaAfterPositions.append(next)
                    } else {
                        continue
                    }
                    mark(word, .removed)
                    parsed.viaWordText = text(word)
                    parsed.viaWordFollowsPlace = false
                } else if let entry = longest(lexicon.viaAfter, at: position), position > 0 {
                    let word = position..<(position + entry.keys.count)
                    guard !isHyphenJoined(word) else { continue }
                    if let name = viaName(before: position, corpus: corpus) {
                        mark(name, .place)
                        viaNames.append(name)
                    } else if viaClaims(position - 1, corpus: corpus) {
                        mark((position - 1)..<position, .place)
                        viaBeforePositions.append(position - 1)
                    } else {
                        continue
                    }
                    mark(word, .removed)
                    parsed.viaWordText = text(word)
                    parsed.viaWordFollowsPlace = true
                }
            }
            if !viaNames.isEmpty || !viaAfterPositions.isEmpty || !viaBeforePositions.isEmpty {
                parsed.droppedNoise = true
            }
        }

        /// The known name a via word takes whole, starting at `start` (or
        /// after one function word there): a name the name pass kept, else
        /// the longest run of open words that some trip's place, region,
        /// country or transit has in one value, as that whole value (`Van`,
        /// `Christmas Island`), as one word that is no syntax, or as two or
        /// more words with one that is no syntax (`Three Rivers`, `La Paz`).
        func viaName(after start: Int, skippingFunctionWord: Bool = true, corpus: TripSearchIndex?) -> Range<Int>? {
            for offset in skippingFunctionWord ? [0, 1] : [0] {
                let first = start + offset
                if offset == 1, !(start < units.count && isFunctionWord(start) && isOpenWord(start)) { break }
                if let span = nameSpans.first(where: { $0.range.lowerBound == first }) { return span.range }
                var end = first
                while end < units.count, end - first < TripSearchIndex.maxNameWords, isOpenWord(end) { end += 1 }
                if end > first, let name = knownViaName((first..<end).map { first..<($0 + 1) }.reversed(), corpus: corpus) {
                    return name
                }
            }
            return nil
        }

        /// `viaName(after:)` for a via word after the place, ending before `end`.
        func viaName(before end: Int, corpus: TripSearchIndex?) -> Range<Int>? {
            if let span = nameSpans.first(where: { $0.range.upperBound == end }) { return span.range }
            var start = end
            while start > 0, end - start < TripSearchIndex.maxNameWords, isOpenWord(start - 1) { start -= 1 }
            guard start < end else { return nil }
            return knownViaName((start..<end).map { $0..<end }, corpus: corpus)
        }

        /// The first of `candidates` (longest first) that names a stop or
        /// place under `viaName`'s rules.
        func knownViaName(_ candidates: [Range<Int>], corpus: TripSearchIndex?) -> Range<Int>? {
            guard let corpus else { return nil }
            for range in candidates {
                guard let phrase = corpus.namePhrase(TripQueryParser.nameKey(units, range)),
                      phrase.isDestination || phrase.isTransit else { continue }
                if phrase.isCompleteDestination || phrase.isCompleteTransit { return range }
                let distinctive = range.contains { !lexicon.isSyntax(units[$0].key) }
                if distinctive, !isFunctionWord(range.upperBound - 1), !isFunctionWord(range.lowerBound) || range.count > 1 {
                    return range
                }
            }
            return nil
        }

        func isFunctionWord(_ position: Int) -> Bool {
            lexicon.filler.contains(units[position].key) || lexicon.ambiguousFunction.contains(units[position].key)
        }

        /// Whether a via word claims the single word at `position` as a place:
        /// not a count, and not query vocabulary that no trip has as a place
        /// word (`über Weihnachten` is "over Christmas").
        func viaClaims(_ position: Int, corpus: TripSearchIndex?) -> Bool {
            guard isOpenWord(position), !isCount(at: position) else { return false }
            let key = units[position].key
            guard lexicon.isVocabulary(key) else { return true }
            return corpus?.containsWord(key, in: [.transit, .place, .region, .country]) == true
        }

        mutating func consumeWeekends() {
            for position in units.indices {
                guard let entry = longest(lexicon.weekends, at: position) else { continue }
                mark(position..<(position + entry.keys.count), .kept)
                let isLong = lexicon.longWeekends.contains(entry.keys)
                parsed.requiresWeekend = true
                setMin(isLong ? 3 : 2, consumed: false)
                setMax(isLong ? 4 : 3, consumed: false)
            }
        }

        /// "last 6 months", "past year", `letzten 3 Wochen`, `6 derniers
        /// mois`: a span that ends today (`ParsedQuery.recentStart`). A
        /// calendar phrase (`last year`, `last month`) stays one.
        mutating func consumeRecentSpans() {
            for position in units.indices where isOpenWord(position) {
                guard longest(lexicon.relative, at: position) == nil else { continue }
                let candidates = lexicon.spanPatterns.candidates(units[position].key, slotFirst: count(at: position) != nil)
                for pattern in candidates {
                    guard let hit = match(pattern.parts, at: position, slot: { count(at: $0).map { ($0.length, $0.value) } })
                    else { continue }
                    setRecentSpan(count: hit.values.first ?? 1, unit: pattern.kind)
                    mark(position..<(position + hit.length), .removed)
                    parsed.consumedSyntax = true
                    break
                }
            }
        }

        /// The span of `count` units back from today, from the start of its
        /// first day; two spans keep the longer.
        mutating func setRecentSpan(count: Int, unit: TripQueryVocabulary.SpanUnit) {
            let component: Calendar.Component = switch unit {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            // Past 1900 a span admits every trip anyway.
            guard count > 0,
                  let start = calendar.date(byAdding: component, value: -min(count, 200 * 366), to: now)
            else { return }
            let day = calendar.startOfDay(for: start)
            parsed.recentStart = min(parsed.recentStart ?? day, day)
        }

        /// `15 august 2024`, `august 15th`, `15. August`, `15 de agosto de
        /// 2024`, `the 4th of july`, `2024年8月15日`, `2024-08-15`: a calendar
        /// day (`ParsedQuery.days`). A year right after it (or a Han or
        /// Hangul year right before) is the day's. Slashed and dotted numeric
        /// dates are not read: their day and month order depends on the locale.
        mutating func consumeDayDates() {
            for position in units.indices where units[position].role == .open {
                switch units[position].special {
                case .date(let year, let month, let day)?:
                    addDay(month: month, day: day, year: year, range: position..<(position + 1), numeric: true)
                    continue
                case .monthDay(let month, let day)?:
                    if let year = singleYear(at: position - 1) {
                        addDay(
                            month: month, day: day, year: year.value, range: (position - 1)..<(position + 1), numeric: true)
                    } else {
                        var cursor = position + 1
                        let year = dayYear(at: &cursor)
                        addDay(month: month, day: day, year: year, range: position..<cursor, numeric: true)
                    }
                    continue
                default:
                    break
                }
                if let day = dayNumber(at: position) {
                    var cursor = position + 1
                    if isOpenWord(cursor), TripQueryParser.dayMonthConnectors.contains(units[cursor].key),
                       longest(lexicon.months, at: cursor + 1) != nil {
                        cursor += 1
                    }
                    if let month = longest(lexicon.months, at: cursor) {
                        cursor += month.keys.count
                        let year = dayYear(at: &cursor)
                        addDay(month: month.value, day: day, year: year, range: position..<cursor)
                        continue
                    }
                }
                if let month = longest(lexicon.months, at: position),
                   let day = dayNumber(at: position + month.keys.count) {
                    var cursor = position + month.keys.count + 1
                    let year = dayYear(at: &cursor)
                    addDay(month: month.value, day: day, year: year, range: position..<cursor)
                }
            }
        }

        /// A day of the month: one or two digits, with an ordinal ending
        /// (`15th`, `1er`, `15η`).
        func dayNumber(at position: Int) -> Int? {
            guard isOpenWord(position) else { return nil }
            let key = units[position].key
            let digits = key.prefix { $0.isASCII && $0.isNumber }
            guard (1...2).contains(digits.count), let day = Int(digits), (1...31).contains(day),
                  TripQueryParser.dayOrdinalEndings.contains(String(key.dropFirst(digits.count)))
            else { return nil }
            return day
        }

        /// The year right after a day (`, 2024`, `de 2024`), advancing `cursor`.
        func dayYear(at cursor: inout Int) -> Int? {
            if isOpenWord(cursor), lexicon.yearConnectors.contains(units[cursor].key),
               let year = singleYear(at: cursor + 1) {
                cursor += 2
                return year.value
            }
            guard let year = singleYear(at: cursor) else { return nil }
            cursor += 1
            return year.value
        }

        /// A day as a clause of its own, its year paired. A day its month
        /// lacks is no day: word forms stay text (`february 30`), a numeric
        /// date (`2024-02-30`, `2月30日`) admits no trip rather than vanish.
        mutating func addDay(month: Int, day: Int, year: Int?, range: Range<Int>, numeric: Bool = false) {
            // 29 February is a day of leap years.
            var components = DateComponents(year: year ?? 2024, month: month, day: day)
            components.calendar = Calendar(identifier: .gregorian)
            if components.isValidDate {
                let clause = DateClause(years: year.map { [$0] } ?? [], days: [DateDay(month: month, day: day)])
                parsed.dates.clauses.append(clause)
                parsed.unambiguousDates.clauses.append(clause)
                parsed.consumedDates.clauses.append(clause)
            } else if numeric {
                parsed.admitsNothing = true
            } else {
                return
            }
            mark(range, .removed)
            parsed.consumedSyntax = true
        }

        /// `<month or season> <year>` and `<year> <month or season>`, with an
        /// optional connector (`summer of 2024`, `verano de 2024`). Explicit
        /// temporal syntax; a place word between them (`Winter Park 2025`)
        /// prevents it.
        mutating func consumeDatesWithYear(corpus: TripSearchIndex?) {
            for position in units.indices {
                if let slot = slot(at: position, allowAnchorRequired: true) {
                    var yearPosition = position + slot.length
                    if isOpenWord(yearPosition), lexicon.yearConnectors.contains(units[yearPosition].key),
                       years(at: yearPosition + 1) != nil {
                        yearPosition += 1
                    }
                    if let years = years(at: yearPosition) {
                        addClause(slot.value, years: years)
                        offerMonthPlace(position..<(position + slot.length), corpus: corpus)
                        mark(position..<(yearPosition + 1), .removed)
                        parsed.consumedSyntax = true
                        continue
                    }
                }
                if let years = years(at: position), let slot = slot(at: position + 1, allowAnchorRequired: true) {
                    addClause(slot.value, years: years)
                    offerMonthPlace((position + 1)..<(position + 1 + slot.length), corpus: corpus)
                    mark(position..<(position + 1 + slot.length), .removed)
                    parsed.consumedSyntax = true
                }
            }
        }

        /// A clause's month or season word that is the whole name of some
        /// trip's place (`ParsedQuery.monthPlaceAlternatives`).
        mutating func offerMonthPlace(_ range: Range<Int>, corpus: TripSearchIndex?) {
            let key = TripQueryParser.nameKey(units, range)
            guard let corpus, corpus.namePhrase(key)?.isCompleteDestination == true,
                  let clause = parsed.dates.clauses.last else { return }
            parsed.monthPlaceAlternatives.append(MonthPlace(word: text(range), key: key, clause: clause))
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
            case (.beforeLast, .season(let season)):
                addClause(word, years: [lastYear(of: season) - 1])
            case (.beforeLast, .month(let month)):
                addClause(word, years: [(nowMonth > month ? nowYear : nowYear - 1) - 1])
            }
        }

        mutating func consumeRelativePhrases() {
            for position in units.indices {
                guard let entry = longest(lexicon.relative, at: position) else { continue }
                switch entry.value {
                case .lastYear:
                    addLooseYears([nowYear - 1], consumed: true)
                case .yearBeforeLast:
                    addLooseYears([nowYear - 2], consumed: true)
                case .thisYear:
                    addLooseYears([nowYear], consumed: true)
                case .lastMonth:
                    addClause(
                        .month(nowMonth == 1 ? 12 : nowMonth - 1),
                        years: [nowMonth == 1 ? nowYear - 1 : nowYear])
                case .thisMonth:
                    addClause(.month(nowMonth), years: [nowYear])
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
                ambiguous.append((position, text(range)))
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
                    ambiguous.append((position, text(range)))
                    mark(range, .kept)
                } else if let month = longest(lexicon.months, at: position) {
                    let range = position..<(position + month.keys.count)
                    addLooseMonths(.month(month.value), anchored: false)
                    ambiguous.append((position, text(range)))
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
        mutating func classifyRemaining(typing: TripSearchIndex?, corpus: TripSearchIndex?) {
            let lastToken = units.map(\.token).max()
            let names = soleKnownNames(corpus: corpus)
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
                case .yearsAgo(let count):
                    addLooseYears([nowYear - count], consumed: true)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .monthDay(let month, let day):
                    addDay(month: month, day: day, year: nil, range: position..<(position + 1), numeric: true)
                    continue
                case .date(let year, let month, let day):
                    addDay(month: month, day: day, year: year, range: position..<(position + 1), numeric: true)
                    continue
                case .length(let min, let max):
                    if let min { setMin(min) }
                    if let max { setMax(max) }
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .recentSpan(let count, let unit):
                    setRecentSpan(count: count, unit: unit)
                    units[position].role = .removed
                    parsed.consumedSyntax = true
                    continue
                case .ordinal:
                    // `consumeOrdinals` reads every one.
                    units[position].role = .removed
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
                guard isFiller || isFunction, !names.contains(position) else {
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
            }
        }

        /// A filler or function word that is an "or" side (or the query)
        /// on its own and the whole name of some trip's place or stop (Dutch
        /// `van`, the town Van): that side names the place (`Nice or Van`,
        /// whose sides an earlier via word then scopes). Beside any other
        /// word it stays a function word (`reizen van 2024`, `all of my
        /// trips` with a town called Of).
        func soleKnownNames(corpus: TripSearchIndex?) -> Set<Int> {
            guard let corpus else { return [] }
            var names = Set<Int>()
            var side: [Int] = []
            func close() {
                if side.count == 1, let position = side.first, units[position].role == .open,
                   units[position].special == nil,
                   let phrase = corpus.namePhrase(units[position].key),
                   phrase.isCompleteDestination || phrase.isCompleteTransit {
                    names.insert(position)
                }
                side = []
            }
            for position in units.indices {
                if units[position].role == .open, disjunctionPositions.contains(position) {
                    close()
                } else {
                    side.append(position)
                }
            }
            close()
            return names
        }

        mutating func result(languageTag: String, isTyping: Bool) -> ParsedQuery {
            // A day and the month or season clauses beside it are one date.
            for keyPath in [\ParsedQuery.dates, \.unambiguousDates, \.consumedDates] {
                if !parsed[keyPath: keyPath].bindDays() { parsed.admitsNothing = true }
            }
            // A holiday word may name a place (Natal, a town called Easter):
            // the place reading tries it as a whole word first.
            for (range, holidays) in holidayUnits {
                ambiguous.append((range.lowerBound, text(range)))
                parsed.ambiguousHolidays.formUnion(holidays)
                if let title = TripQueryParser.normalizedTitle(text(range), apostropheSuffixes: lexicon.apostropheSuffixes) {
                    parsed.holidayTitles.insert(title)
                    parsed.titleApostropheSuffixes = lexicon.apostropheSuffixes
                }
            }
            if let lengthMin { setMin(lengthMin) }
            if let lengthMax { setMax(lengthMax) }
            ambiguous.sort { $0.position < $1.position }

            // The words left without this reading's own filter syntax; the
            // place reading keeps the words it restores as place text.
            let filterPositions = Set(units.indices.filter { units[$0].role == .removed || units[$0].role == .kept })
                .union(lengthPositions)
            let restored = Set(ambiguous.map(\.position)).union(holidayUnits.flatMap { Array($0.range) })
            func words(dropping dropped: Set<Int>) -> String {
                units.indices.filter { !dropped.contains($0) }.map { units[$0].text }.joined(separator: " ")
            }
            // The function words a filter owns (`in` of `in 2024`, Korean
            // `에` of `2024년에`): a run of them right before filter syntax, or
            // after it at the end of the query. One written onto the place
            // before it is the place's (Japanese `リマへ`, to Lima). In the
            // place reading the restored words are place text, so `para` of
            // `para Natal` is the place's own.
            func isFunctionFiller(_ position: Int) -> Bool {
                guard position >= 0, position < units.count, units[position].role == .filler,
                      !lengthPositions.contains(position) else { return false }
                let key = units[position].key
                return !lexicon.tripNouns.contains(key) && (isFunctionWord(position) || lexicon.yearConnectors.contains(key))
            }
            func filterOwned(restoring restoredPlaces: Set<Int>) -> Set<Int> {
                func isFilterSyntax(_ position: Int) -> Bool {
                    position >= 0 && position < units.count && !restoredPlaces.contains(position)
                        && (units[position].role == .removed || units[position].role == .kept)
                }
                var owned = Set<Int>()
                var start = 0
                while start < units.count {
                    guard isFunctionFiller(start) else {
                        start += 1
                        continue
                    }
                    var end = start
                    while isFunctionFiller(end) { end += 1 }
                    let placeSuffix = start > 0 && units[start - 1].token == units[start].token
                        && (units[start - 1].role == .place || restoredPlaces.contains(start - 1))
                    if !placeSuffix, isFilterSyntax(end) || (end == units.count && isFilterSyntax(start - 1)) {
                        owned.formUnion(start..<end)
                    }
                    start = end
                }
                return owned
            }
            let functionOwned = filterOwned(restoring: [])
            let placeReadingFunctionOwned = filterOwned(restoring: restored)
            // Words of its own (`hasOwnWords`): filler no filter owns, length words included.
            parsed.hasOwnWords = units.indices.contains { units[$0].role == .filler && !functionOwned.contains($0) }
            parsed.placeReadingHasOwnWords = units.indices.contains {
                units[$0].role == .filler && !placeReadingFunctionOwned.contains($0)
            }
            let owned = filterPositions.union(functionOwned)
            let placeReadingOwned = filterPositions.subtracting(restored).union(placeReadingFunctionOwned)
            parsed.borrowableText = words(dropping: owned)
            parsed.placeReadingBorrowableText = words(dropping: placeReadingOwned)

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
            // A known name a via word took, or the place words right after a
            // via word (or right before a trailing one): a run of place units
            // from the word it claimed, so a connector (`para Roma`) ends it.
            func inViaSpan(_ position: Int) -> Bool {
                position >= 0 && position < units.count && units[position].role == .place
            }
            var viaPositions = viaNames.flatMap { Array($0) }
            for start in viaAfterPositions {
                var position = start
                while inViaSpan(position) {
                    viaPositions.append(position)
                    position += 1
                }
            }
            for end in viaBeforePositions {
                var position = end
                var run: [Int] = []
                while inViaSpan(position) {
                    run.insert(position, at: 0)
                    position -= 1
                }
                viaPositions += run
            }
            if !viaPositions.isEmpty {
                parsed.viaTerms = TripSearch.terms(
                    viaPositions.map { units[$0].text }.joined(separator: " "),
                    languageTag: languageTag, allowsTrailingPartial: false)
                if isTyping, viaPositions.last == units.count - 1, units[units.count - 1].token == lastToken,
                   !parsed.viaTerms.isEmpty {
                    parsed.viaTerms[parsed.viaTerms.count - 1].isTrailingPartial = true
                }
                if viaPositions.max() == places.last {
                    let via = Set(viaPositions)
                    parsed.viaDestinationText = words(dropping: owned.union(via))
                    parsed.placeReadingViaDestinationText = words(dropping: placeReadingOwned.union(via))
                }
            }

            // Sides of an "or" word this reading dropped as filler, when the
            // reading would AND what it separates (see `disjunctionSides`).
            // A holiday, a calendar day or a recent span pairs with nothing
            // in the clause model: "or" next to one may separate two dates
            // (`christmas 2024 or 15 august 2025`, `last 6 months or 2020`).
            let pairsAlone = parsed.placeTerms.count >= 2 || yearBoundCount >= 2 || holidayUnits.count >= 2
            let temporal = !holidayUnits.isEmpty || parsed.dates.hasDays || parsed.recentStart != nil
            if pairsAlone || temporal {
                var sides: [[String]] = [[]]
                for (position, unit) in units.enumerated() {
                    if unit.role == .filler, disjunctionPositions.contains(position) {
                        sides.append([])
                    } else if position > 0, units[position - 1].token == unit.token,
                              unit.text.unicodeScalars.contains(where: { TripSearchText.isHanOrKana($0.value) }),
                              let last = sides[sides.count - 1].last {
                        // Segments of one Han or kana word stay one word (`リマへ`).
                        sides[sides.count - 1][sides[sides.count - 1].count - 1] = last + unit.text
                    } else {
                        sides[sides.count - 1].append(unit.text)
                    }
                }
                if sides.count >= 2, sides.allSatisfy({ !$0.isEmpty }) {
                    parsed.disjunctionSides = sides.map { $0.joined(separator: " ") }
                    parsed.temporalDisjunction = !pairsAlone
                }
            }

            for entry in ambiguous {
                let terms = TripSearch.terms(entry.text, languageTag: languageTag, allowsTrailingPartial: false)
                parsed.ambiguousTerms.append(contentsOf: terms)
                parsed.ambiguousDateTokens.append(entry.text)
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

    /// The years a parsed year can name; year bounds stop at its ends.
    private static let yearUniverse = 1900...2099

    /// Words between a day and its month (`4th of July`, `15 de agosto`).
    private static let dayMonthConnectors: Set<String> = ["of", "de", "del"]

    /// Endings a day number may carry, as keys (`15th`, `1er`, `15η`).
    /// Swedish `15:e` reads as `15e` (`swedishOrdinalDays`).
    private static let dayOrdinalEndings: Set<String> = ["", "st", "nd", "rd", "th", "er", "e", "o", "a", "η"]

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

        /// A season's neighbouring months; a month has none.
        var shoulderMonths: Set<DateMonth> {
            switch self {
            case .month: []
            case .season(let season): season.shoulderMonths
            }
        }
    }

    private struct Season: Sendable {
        enum Kind: Sendable { case plain, anchorRequired, recent, current }
        let months: Set<Int>
        let finalMonth: Int
        let kind: Kind

        /// Whether the season crosses New Year (winter).
        var wraps: Bool { months.contains { $0 > finalMonth } }

        /// Seasons are labeled by their first month's year: a season that
        /// crosses New Year (winter) puts the months up to its final month
        /// in the following year.
        var datedMonths: Set<DateMonth> {
            Set(months.map { DateMonth(month: $0, yearOffset: wraps && $0 <= finalMonth ? 1 : 0) })
        }

        /// The month before the season and the month after it, dated like
        /// `datedMonths` (winter 2024: November 2024 and March 2025).
        var shoulderMonths: Set<DateMonth> {
            guard let first = months.first(where: { !months.contains($0 == 1 ? 12 : $0 - 1) }) else { return [] }
            let finalOffset = wraps ? 1 : 0
            return [
                DateMonth(month: first == 1 ? 12 : first - 1, yearOffset: first == 1 ? -1 : 0),
                DateMonth(month: finalMonth == 12 ? 1 : finalMonth + 1, yearOffset: finalOffset + (finalMonth == 12 ? 1 : 0)),
            ]
        }
    }

    private enum RelativePhrase: Sendable { case lastYear, thisYear, lastMonth, thisMonth, yearBeforeLast }

    private enum YearBound: Sendable { case since, after, before, until, span }

    private enum DurationBound: Sendable { case longer, shorter, atLeast, atMost }

    private enum AgoUnit: Sendable { case years }

    /// A vocabulary pattern in key space: the literal words around its slots.
    private struct PatternKeys<Kind: Sendable>: Sendable {
        let parts: [[String]]
        let kind: Kind
    }

    /// Patterns by their first word, most slots and words first; patterns
    /// that open with a slot apart.
    private struct PatternSet<Kind: Sendable>: Sendable {
        private var byFirstWord: [String: [PatternKeys<Kind>]] = [:]
        private var slotFirst: [PatternKeys<Kind>] = []

        init(_ patterns: [PatternKeys<Kind>] = []) {
            let ordered = patterns.sorted {
                ($0.parts.count, $0.parts.joined().count) > ($1.parts.count, $1.parts.joined().count)
            }
            for pattern in ordered {
                if let first = pattern.parts.first?.first {
                    byFirstWord[first, default: []].append(pattern)
                } else {
                    slotFirst.append(pattern)
                }
            }
        }

        /// The patterns that can start at a word with `key`; those opening
        /// with a slot only when a slot value starts there.
        func candidates(_ key: String, slotFirst includeSlotFirst: Bool) -> [PatternKeys<Kind>] {
            let words = byFirstWord[key] ?? []
            return includeSlotFirst ? words + slotFirst : words
        }
    }

    private enum FrameKind: Sendable { case last, this, inside, beforeLast }

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
        /// "years ago" patterns, year bounds and duration comparatives,
        /// most slots and words first.
        var agoPatterns = PatternSet<AgoUnit>()
        var yearPatterns = PatternSet<YearBound>()
        var durationPatterns = PatternSet<DurationBound>()
        /// Recent spans ending today (`last _ months`, `past year`).
        var spanPatterns = PatternSet<TripQueryVocabulary.SpanUnit>()
        /// Day-trip words (`day trip`, `Tagesausflug`, `日帰り`).
        var dayTrips = PhraseTable<Bool>()
        /// Length phrases that need no trip noun (true: long).
        var lengthPhrases = PhraseTable<Bool>()
        /// Duration unit words (days) and count words, English included.
        var units: [String: Int] = [:]
        var counts: [String: Int] = [:]
        /// Han and kana year phrases (`一昨年`, `前年`) kept whole in the
        /// query, longest first, with their key.
        var protectedPhrases: [(text: String, key: String)] = []
        var yearConnectors: Set<String> = []
        /// Trip nouns, and length words before and after one (true: long).
        var tripNouns: Set<String> = []
        var lengthBefore: [String: Bool] = [:]
        var lengthAfter: [String: Bool] = [:]
        /// Key sequences of the weekend words that mean a long weekend.
        var longWeekends: Set<[String]> = []
        /// "or" words (`TripQueryVocabulary.Language.disjunctionWords`), also filler.
        var disjunctions: Set<String> = []
        /// Other filler and function words with an "or" word's key, spelt
        /// apart from every "or" word (`accentSpelling`): the Greek article
        /// `η` beside `ή`, French `où` beside `ou`.
        var disjunctionLookalikes: Set<String> = []
        var facets = PhraseTable<TripSearchFacet>()
        var holidays = PhraseTable<Set<TripQueryHoliday>>()
        /// Ordinal words before and after a trip noun, the words that stand
        /// in for one, and numeric ordinal endings (`3rd`).
        var ordinalsBefore = PhraseTable<Ordinal>()
        var ordinalsAfter = PhraseTable<Ordinal>()
        var ordinalHeads: Set<String> = []
        var ordinalSuffixes: Set<String> = []
        var superlatives = PhraseTable<Ordinal>()
        /// "without" words before and after a kind word, and words for
        /// "without a kind".
        var withoutBefore = PhraseTable<Bool>()
        var withoutAfter = PhraseTable<Bool>()
        var withoutFacets = PhraseTable<TripSearchFacet>()
        /// "via" words before the place, and after it (Turkish, Japanese).
        var viaBefore = PhraseTable<Bool>()
        var viaAfter = PhraseTable<Bool>()
        var filler: Set<String> = []
        var ambiguousFunction: Set<String> = []
        /// `'suffix` endings stripped before tokenizing (Turkish `Roma'da`,
        /// English `Rome's`).
        var apostropheSuffixes: NSRegularExpression?
        /// Every single vocabulary key, for the Han season context rule.
        var contextKeys: Set<String> = []
        /// Single-word season, weekend and month keys for trailing completion.
        var completions: [(key: String, meaning: String)] = []

        /// Every word some syntax reads: vocabulary, filler, counts, units,
        /// length, ordinal and "or" words (the name pass's collisions).
        var syntaxKeys: Set<String> = []

        func isVocabulary(_ key: String) -> Bool {
            contextKeys.contains(key) || ambiguousFunction.contains(key)
        }

        /// Whether some syntax could read the word (`syntaxKeys`, digits).
        func isSyntax(_ key: String) -> Bool {
            syntaxKeys.contains(key) || (!key.isEmpty && key.allSatisfy(\.isNumber))
        }

        /// The one meaning `prefix` completes to, as its shortest key.
        func completion(for prefix: String) -> String? {
            let candidates = completions.filter { $0.key.hasPrefix(prefix) && $0.key != prefix }
            guard !candidates.isEmpty, Set(candidates.map(\.meaning)).count == 1 else { return nil }
            return candidates.min { ($0.key.count, $0.key) < ($1.key.count, $1.key) }?.key
        }
    }

    private static let lexicons = OSAllocatedUnfairLock(initialState: [String: Lexicon]())

    /// The vocabulary languages a query is read in, most trusted first: the
    /// app language, then the user's other preferred languages in order
    /// (English is always active), then the language of a script in the
    /// query that only one vocabulary writes: Greek, Hangul, kana. A Greek
    /// speaker using the app in English still types `Αύγουστος 2025`. Han
    /// alone could be Chinese or Japanese, so only a preferred language adds
    /// those.
    static func queryLanguageTags(
        _ query: String,
        languageTag: String,
        preferredTags: [String] = currentPreferredTags()
    ) -> [String] {
        var tags = [languageTag]
        func add(_ tag: String) {
            guard tag != "en", !tags.contains(tag), TripQueryVocabulary.supportedTags.contains(tag) else { return }
            tags.append(tag)
        }
        preferredTags.forEach(add)
        var greek = false, hangul = false, kana = false
        for scalar in query.unicodeScalars where scalar.value >= 0x0370 {
            if !greek, TripSearchText.isGreek(scalar) { greek = true; add("el") }
            if !hangul, TripSearchText.isHangulSyllable(scalar) { hangul = true; add("ko") }
            if !kana, (0x3040...0x30FF).contains(scalar.value) { kana = true; add("ja") }
        }
        return tags
    }

    /// `AppLanguagePreference.preferredTags()`, normalized once per change of
    /// `Locale.preferredLanguages` rather than on every parse.
    static func currentPreferredTags() -> [String] {
        let raw = Locale.preferredLanguages
        return preferredTagMemo.withLock { memo in
            if let memo, memo.raw == raw { return memo.tags }
            let tags = AppLanguagePreference.preferredTags(raw)
            memo = (raw, tags)
            return tags
        }
    }

    private static let preferredTagMemo = OSAllocatedUnfairLock<(raw: [String], tags: [String])?>(initialState: nil)

    /// Builds the lexicons for English, `languageTag` and the user's
    /// preferred languages and compiles the numeric regexes, so the first
    /// query on the main actor pays for none of them. Call it from an
    /// off-main index build. A lexicon a query's script adds is built on
    /// its first use and cached like these.
    nonisolated static func prewarm(languageTag: String) {
        _ = lexicon(for: ["en"])
        _ = lexicon(for: [languageTag])
        _ = lexicon(for: queryLanguageTags("", languageTag: languageTag))
        Regexes.prewarm()
    }

    /// The active vocabulary of `tags` (see `queryLanguageTags`): English
    /// and the app language, merged with each further language in order, an
    /// earlier language winning a word both define. Further languages add
    /// no short month forms (`TripQueryVocabulary.secondary(_:)`).
    private static func lexicon(for tags: [String]) -> Lexicon {
        let key = tags.joined(separator: "+")
        if let cached = lexicons.withLock({ $0[key] }) { return cached }
        var language = TripQueryVocabulary.active(languageTag: tags.first ?? "en")
        for tag in tags.dropFirst() {
            language = language.merged(with: TripQueryVocabulary.secondary(tag))
        }
        let built = makeLexicon(language)
        lexicons.withLock { $0[key] = built }
        return built
    }

    /// Key sequences of one vocabulary word or phrase: the native form; for
    /// a Han or kana word the segmenter splits, also the whole word (alone
    /// `まで` segments as ま / で, inside `までの旅行` it stays whole); plus
    /// the Latin forms of 4+ characters when `latin` is set.
    private static func keySequences(_ phrase: String, latin: Bool) -> [[String]] {
        let forms = TripSearch.normalizedSearchForms(fold(phrase))
        guard let native = forms.first else { return [] }
        var result = [unitKeys(native)]
        if let whole = wholeHanWord(native), result[0] != [whole] { result.append([whole]) }
        if latin {
            for form in forms.dropFirst() {
                let keys = unitKeys(form)
                if keys.joined().count >= 4, !result.contains(keys) { result.append(keys) }
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// The single word of `native` when it contains Han or kana.
    private static func wholeHanWord(_ native: String) -> String? {
        let words = TripSearchText.words(native)
        guard words.count == 1, let word = words.first,
              word.unicodeScalars.contains(where: { TripSearchText.isHanOrKana($0.value) })
        else { return nil }
        return word
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
                if language.longWeekendWords.contains(word) { lexicon.longWeekends.insert(keys) }
            }
        }
        for word in language.tripNouns {
            if let keys = keySequences(word, latin: false).first, keys.count == 1 { lexicon.tripNouns.insert(keys[0]) }
        }
        let lengths: [(words: Set<String>, isLong: Bool, after: Bool)] = [
            (language.longWords, true, false), (language.shortWords, false, false),
            (language.longWordsAfterNoun, true, true), (language.shortWordsAfterNoun, false, true),
        ]
        for (words, isLong, after) in lengths {
            for word in words {
                guard let keys = keySequences(word, latin: false).first, keys.count == 1 else { continue }
                if after {
                    if lexicon.lengthAfter[keys[0]] == nil { lexicon.lengthAfter[keys[0]] = isLong }
                } else if lexicon.lengthBefore[keys[0]] == nil {
                    lexicon.lengthBefore[keys[0]] = isLong
                }
            }
        }
        let relative: [(phrases: [String], meaning: RelativePhrase)] = [
            (language.lastYearPhrases, .lastYear), (language.thisYearPhrases, .thisYear),
            (language.lastMonthPhrases, .lastMonth), (language.yearBeforeLastPhrases, .yearBeforeLast),
            (language.thisMonthPhrases, .thisMonth),
        ]
        for (phrases, meaning) in relative {
            for phrase in phrases {
                for keys in keySequences(phrase, latin: false) {
                    lexicon.relative.add(keys, meaning)
                    note(keys)
                }
                // Year phrases only: `上月` (last month) is also a town.
                if meaning != .lastMonth, meaning != .thisMonth, let whole = keySequences(phrase, latin: false).last, whole.count == 1,
                   wholeHanWord(whole[0]) != nil, whole[0].count >= 2 {
                    lexicon.protectedPhrases.append((fold(phrase), whole[0]))
                }
            }
        }


        lexicon.ambiguousFunction = Set(language.ambiguousFunctionWords.compactMap { keySequences($0, latin: false).first?.first })
        let frames: [(frames: [TripQueryVocabulary.Frame], kind: FrameKind)] = [
            (language.lastFrames, .last), (language.thisFrames, .this), (language.inFrames, .inside),
            (language.beforeLastFrames, .beforeLast),
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

        // Every key spelling of a pattern (a Han or kana part also as one
        // word). A pattern needs a literal word, and two slots need one
        // between them (`2019 2021` stays a year list).
        func patternKeys(_ pattern: TripQueryVocabulary.Pattern) -> [[[String]]] {
            var spellings: [[[String]]] = [[]]
            for part in pattern.parts {
                let options = part.trimmingCharacters(in: .whitespaces).isEmpty ? [[]] : keySequences(part, latin: false)
                spellings = spellings.flatMap { prefix in options.map { prefix + [$0] } }
            }
            return spellings.filter { parts in
                guard parts.contains(where: { !$0.isEmpty }), parts.count < 3 || !parts[1].isEmpty else { return false }
                note(parts.flatMap { $0 })
                return true
            }
        }
        lexicon.agoPatterns = PatternSet(language.yearsAgo.flatMap(patternKeys).map { PatternKeys(parts: $0, kind: .years) })
        let years: [(patterns: [TripQueryVocabulary.Pattern], kind: YearBound)] = [
            (language.sinceYear, .since), (language.afterYear, .after), (language.beforeYear, .before),
            (language.untilYear, .until), (language.yearSpans, .span),
        ]
        lexicon.yearPatterns = PatternSet(years.flatMap { list in
            list.patterns.flatMap(patternKeys).map { PatternKeys(parts: $0, kind: list.kind) }
        })
        // Han bound words too (`之前去` segments as 之 / 前去).
        for pattern in years.flatMap(\.patterns) {
            for part in pattern.parts where part.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                guard let whole = wholeHanWord(TripSearch.normalizedSearchForms(fold(part)).first ?? ""),
                      whole.count >= 2, !lexicon.protectedPhrases.contains(where: { $0.key == whole })
                else { continue }
                lexicon.protectedPhrases.append((fold(part), whole))
            }
        }
        lexicon.protectedPhrases.sort { $0.text.count > $1.text.count }
        let durations: [(patterns: [TripQueryVocabulary.Pattern], kind: DurationBound)] = [
            (language.longerThan, .longer), (language.shorterThan, .shorter),
            (language.atLeast, .atLeast), (language.atMost, .atMost),
        ]
        lexicon.durationPatterns = PatternSet(durations.flatMap { list in
            list.patterns.flatMap(patternKeys).map { PatternKeys(parts: $0, kind: list.kind) }
        })
        for (word, days) in TripQueryVocabulary.englishDurationUnits.merging(language.durationUnits, uniquingKeysWith: { mine, _ in mine }) {
            if let keys = keySequences(word, latin: false).first, keys.count == 1, lexicon.units[keys[0]] == nil {
                lexicon.units[keys[0]] = days
            }
        }
        lexicon.spanPatterns = PatternSet(language.recentSpans.flatMap { unit, patterns in
            patterns.flatMap(patternKeys).map { PatternKeys(parts: $0, kind: unit) }
        })
        for (word, isLong) in language.lengthPhrases {
            for keys in keySequences(word, latin: false) {
                lexicon.lengthPhrases.add(keys, isLong)
                note(keys)
            }
        }
        for word in language.dayTripWords {
            for keys in keySequences(word, latin: false) {
                lexicon.dayTrips.add(keys, true)
                note(keys)
            }
        }
        for (word, value) in language.countWords {
            if let keys = keySequences(word, latin: false).first, keys.count == 1, lexicon.counts[keys[0]] == nil {
                lexicon.counts[keys[0]] = value
            }
        }

        for word in language.yearConnectors {
            if let key = keySequences(word, latin: false).first, key.count == 1 {
                lexicon.yearConnectors.insert(key[0])
                note(key)
            }
        }
        for word in language.filler {
            for keys in keySequences(word, latin: false) {
                if keys.count == 1 {
                    lexicon.filler.insert(keys[0])
                } else {
                    lexicon.fillerPhrases.add(keys, true)
                }
                note(keys)
            }
        }
        for (word, facet) in language.facetWords {
            for keys in keySequences(word, latin: false) {
                lexicon.facets.add(keys, facet)
                note(keys)
            }
        }
        for (words, after) in [(language.withoutWords, false), (language.withoutWordsAfter, true)] {
            for word in words {
                for keys in keySequences(word, latin: false) {
                    if after { lexicon.withoutAfter.add(keys, true) } else { lexicon.withoutBefore.add(keys, true) }
                }
            }
        }
        for (word, facet) in language.withoutFacetWords {
            for keys in keySequences(word, latin: false) {
                lexicon.withoutFacets.add(keys, facet)
                note(keys)
            }
        }
        for (word, holidays) in language.holidayWords {
            for keys in keySequences(word, latin: false) {
                lexicon.holidays.add(keys, holidays)
                note(keys)
            }
        }
        for (words, after) in [(language.ordinalWords, false), (language.ordinalWordsAfterNoun, true)] {
            for (word, ordinal) in words {
                for keys in keySequences(word, latin: false) {
                    if after { lexicon.ordinalsAfter.add(keys, ordinal) } else { lexicon.ordinalsBefore.add(keys, ordinal) }
                }
            }
        }
        for word in language.ordinalHeads {
            if let keys = keySequences(word, latin: false).first, keys.count == 1 { lexicon.ordinalHeads.insert(keys[0]) }
        }
        lexicon.ordinalSuffixes = Set(language.ordinalSuffixes.map { $0 == "." ? $0 : keySequences($0, latin: false).first?.first ?? $0 })
        for (word, ordinal) in language.superlativeWords {
            for keys in keySequences(word, latin: false) {
                lexicon.superlatives.add(keys, ordinal)
                note(keys)
            }
        }
        for (words, after) in [(language.viaWords, false), (language.viaWordsAfterPlace, true)] {
            for word in words {
                for keys in keySequences(word, latin: false) {
                    if after { lexicon.viaAfter.add(keys, true) } else { lexicon.viaBefore.add(keys, true) }
                    note(keys)
                }
            }
        }
        for word in language.disjunctionWords {
            if let keys = keySequences(word, latin: false).first, keys.count == 1 {
                lexicon.disjunctions.insert(keys[0])
                lexicon.filler.insert(keys[0])
                note(keys)
            }
        }
        let disjunctionSpellings = Set(language.disjunctionWords.map(accentSpelling))
        for word in language.filler.union(language.ambiguousFunctionWords) {
            guard let keys = keySequences(word, latin: false).first, keys.count == 1,
                  lexicon.disjunctions.contains(keys[0]), !disjunctionSpellings.contains(accentSpelling(word))
            else { continue }
            lexicon.disjunctionLookalikes.insert(accentSpelling(word))
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
        var syntax = singles.union(lexicon.filler).union(lexicon.ambiguousFunction).union(lexicon.tripNouns)
            .union(lexicon.units.keys).union(lexicon.counts.keys).union(lexicon.lengthBefore.keys)
            .union(lexicon.lengthAfter.keys).union(lexicon.yearConnectors).union(lexicon.disjunctions)
            .union(TripQueryVocabulary.countArticles)
            .union(TripQueryVocabulary.englishNumberWords.keys.flatMap { $0.split(separator: " ").map(String.init) })
        for word in Array(language.ordinalWords.keys) + Array(language.ordinalWordsAfterNoun.keys) + language.ordinalHeads {
            syntax.formUnion(keySequences(word, latin: false).flatMap { $0 })
        }
        lexicon.syntaxKeys = syntax
        return lexicon
    }
}
