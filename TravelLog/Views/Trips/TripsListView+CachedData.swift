//
//  TripsListView+CachedData.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import TipKit
import UIKit
import SwiftData
import WidgetKit
import os.log

private let logger = Logger(subsystem: "com.travellog.app", category: "TripsListView")

extension TripsListView {

    /// Resolver results and the index they came from for a non-empty
    /// debounced query, shared with `SearchTripsIntent` through the index
    /// store. Nil while the store needs its off-main preparation; an empty
    /// query never reaches the store.
    private func searchResult(for query: String) -> TripSearchResult? {
        TripSearchIndexStore.shared.searchResult(
            trips,
            query: query,
            allowsTrailingPartial: Self.allowsTrailingPartial(rawQuery: debouncedSearchQuery))
    }

    /// Compute search, filter, sort, and partition once per recompute.
    struct TripSlices {
        /// The trimmed query these slices answer; empty when not searching.
        var query = ""
        var all: [Trip] = []          // post-search, post-filter (pre-sort), every strength
        var pinned: [Trip] = []       // strong matches only while searching
        var active: [Trip] = []
        var completed: [Trip] = []
        var similar: [Trip] = []      // close spellings and transit hits, pins ignored
        var partial: [Trip] = []      // some query words dropped, pins ignored
        var aiSuggested: [Trip] = []
        /// Strong plus similar matches after filters; zero lets the AI fallback run.
        var strictCount = 0
        /// Strong plus similar matches before filters.
        var preFilterCount = 0
        /// Any strong match before filters ("Did you mean" stays quiet then).
        var hasStrongMatch = false
        /// Match captions keyed by `persistentModelID`; read only for live rows.
        var captions: [PersistentIdentifier: MatchCaption] = [:]
        var spellingSuggestion: String?
        /// `TripSearchIndexStore.wipeRevision` when these slices settled; an
        /// older value means a wipe revoked the text they were derived from.
        var wipeRevision = 0
        /// Each start year's totals for its section header (date sorts only),
        /// over the strong completed rows these slices show, favorites included.
        var yearTotals: [Int: YearTotals] = [:]
        /// Each row's leading wash, built per section in row order so it
        /// blends with its neighbours'; read only for live rows.
        var washes: [PersistentIdentifier: RowWash] = [:]

        /// Cached rows may be deleted during tracker debounce; filter with isDeleted before reading model properties.
        func filteringDeleted() -> TripSlices {
            var copy = self
            copy.all = all.filter { !$0.isDeleted }
            copy.pinned = pinned.filter { !$0.isDeleted }
            copy.active = active.filter { !$0.isDeleted }
            copy.completed = completed.filter { !$0.isDeleted }
            copy.similar = similar.filter { !$0.isDeleted }
            copy.partial = partial.filter { !$0.isDeleted }
            copy.aiSuggested = aiSuggested.filter { !$0.isDeleted }
            return copy
        }
    }

    /// A year header's honest totals: the completed trips that started that
    /// year and their distinct calendar days (overlapping trips count a day once).
    nonisolated struct YearTotals: Equatable {
        var trips: Int
        var days: Int
    }

    /// Totals per start year (in `calendar`, the Gregorian year the year
    /// sections group by) for `trips`. Each trip's day labels come from
    /// `dayLabels` (the cache built once per trip-store change); one missing
    /// there (the cold first frame) falls back to its dates in the current zone.
    static func computeYearTotals(
        _ trips: [Trip],
        dayLabels: [PersistentIdentifier: [Date]],
        calendar: Calendar = TripFilters.yearCalendar,
        now: Date = .now
    ) -> [Int: YearTotals] {
        var counts: [Int: Int] = [:]
        var days: [Int: Set<Date>] = [:]
        for trip in trips {
            let year = calendar.component(.year, from: trip.startDate)
            counts[year, default: 0] += 1
            let labels = dayLabels[trip.persistentModelID]
                ?? Array(TravelDays.labels(
                    spans: [TravelDays.Span(start: trip.startDate, end: trip.endDate, firstZone: nil, lastZone: nil)],
                    now: now, fallbackZone: calendar.timeZone, checkCancellation: {}))
            days[year, default: []].formUnion(labels)
        }
        return counts.reduce(into: [:]) { result, entry in
            result[entry.key] = YearTotals(trips: entry.value, days: days[entry.key]?.count ?? 0)
        }
    }

    /// What the year headers' day labels were built from: the trips, and
    /// the zone a stay without one is read in.
    struct DayLabelsKey: Equatable {
        let tripToken: Int
        let fallbackZoneID: String
    }

    /// The day-label load's trigger: nil while the sort shows no year
    /// headers, so no other sort pays for it.
    var dayLabelsTaskKey: DayLabelsKey? {
        guard sortOrder == .dateNewest || sortOrder == .dateOldest else { return nil }
        return DayLabelsKey(
            tripToken: StoreChangeTracker.shared.token(for: .trip),
            fallbackZoneID: TimeZone.current.identifier)
    }

    /// Every completed trip's travel-day labels, the rule `Trip.durationDays`
    /// and Stats share (each end read in its boundary stay's zone), from the
    /// worker's own context: projected trip and stay fields only, so no
    /// trip's `stays` relationship (weather and ping payloads) is faulted.
    /// A failed fetch throws; it is never read as "no stays".
    nonisolated static func loadTripDayLabels(
        container: ModelContainer, now: Date, fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) throws -> [PersistentIdentifier: [Date]] {
        let context = ModelContext(container)
        var tripDescriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isComplete })
        tripDescriptor.propertiesToFetch = [\.startDate, \.endDate]
        let trips = try context.fetch(tripDescriptor)
        try checkCancellation()
        guard !trips.isEmpty else { return [:] }
        var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.trip != nil })
        stayDescriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.timeZoneIdentifier, \.trip]
        let stays = try context.fetch(stayDescriptor)
        try checkCancellation()
        let spans = try TravelDays.projectedSpans(trips: trips, boundaryStays: stays, checkCancellation: checkCancellation)
        var labels: [PersistentIdentifier: [Date]] = [:]
        labels.reserveCapacity(spans.count)
        for (id, span) in spans {
            labels[id] = Array(try TravelDays.labels(
                spans: [span], now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation))
        }
        return labels
    }

    nonisolated enum DayLabelsOutcome: Sendable {
        case loaded([PersistentIdentifier: [Date]])
        case failed(any Error)
        case superseded
    }

    /// `loadTripDayLabels` on a detached worker the caller's task owns (the
    /// `TemporaryHomeCards.loadDetached` pattern): cancelling the task
    /// cancels the worker, which stops at its next check. Only values cross.
    nonisolated static func loadTripDayLabelsDetached(
        container: ModelContainer, now: Date, fallbackZone: TimeZone
    ) async -> DayLabelsOutcome {
        let worker = Task.detached(priority: .utility) {
            try loadTripDayLabels(container: container, now: now, fallbackZone: fallbackZone) {
                try Task.checkCancellation()
            }
        }
        do {
            let labels = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return Task.isCancelled ? .superseded : .loaded(labels)
        } catch {
            return Task.isCancelled || error is CancellationError ? .superseded : .failed(error)
        }
    }

    /// Loads the year headers' day labels off the main actor for `key`, then
    /// refreshes the shown totals. Publishes only while the trips and zone
    /// still match `key`; a failure keeps the previous labels and leaves the
    /// key unacknowledged, so the next trigger retries.
    @MainActor
    func reloadTripDayLabels(for key: DayLabelsKey?) async {
        guard let key, key != dayLabelsLoadedKey else { return }
        let outcome = await Self.loadTripDayLabelsDetached(
            container: modelContext.container, now: .now,
            fallbackZone: TimeZone(identifier: key.fallbackZoneID) ?? .current)
        switch outcome {
        case .superseded:
            return
        case .failed(let error):
            logger.error("Trip day labels load failed: \(error.localizedDescription)")
            return
        case .loaded(let labels):
            guard !Task.isCancelled, key == dayLabelsTaskKey else { return }
            cachedTripDayLabels = labels
            dayLabelsLoadedKey = key
            refreshYearTotals()
        }
    }

    // MARK: - Gap questions

    /// What the questions were built from: the trips, this device's
    /// answers, and the stays only while a question shows (no idle
    /// observation of stays otherwise).
    struct GapQuestionsKey: Equatable {
        let tripToken: Int
        let stayToken: Int
        let answersRevision: Int
    }

    var gapQuestionsTaskKey: GapQuestionsKey {
        GapQuestionsKey(
            tripToken: StoreChangeTracker.shared.token(for: .trip),
            stayToken: cachedGapQuestions.isEmpty ? 0 : StoreChangeTracker.shared.token(for: .stay),
            answersRevision: TripGapAnswersRevision.shared.value)
    }

    /// Loads the questions off the main actor for `key` (the day labels'
    /// pattern) and publishes them only while the key still matches. A
    /// failure keeps the previous questions; the next trigger retries.
    @MainActor
    func reloadGapQuestions(for key: GapQuestionsKey) async {
        let container = modelContext.container
        let confirmed = TripGapAnswers.confirmed()
        let worker = Task.detached(priority: .utility) {
            try TripGapQuestionIndex.load(container: container, confirmed: confirmed) {
                try Task.checkCancellation()
            }
        }
        do {
            let index = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, key == gapQuestionsTaskKey else { return }
            cachedGapQuestions = index
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            logger.error("Trip gap questions load failed: \(error.localizedDescription)")
        }
    }

    /// The shown slices' year totals again, from the current labels (no
    /// search, filter or sort rerun).
    @MainActor
    func refreshYearTotals() {
        guard hasLoadedSlices else { return }
        let slices = cachedSlices.filteringDeleted()
        cachedSlices.yearTotals = yearTotals(completed: slices.completed, pinned: slices.pinned)
    }

    /// Totals for the year headers, only under date sorts and only once the
    /// day labels have loaded (until then the headers show the year alone).
    func yearTotals(completed: [Trip], pinned: [Trip]) -> [Int: YearTotals] {
        guard sortOrder == .dateNewest || sortOrder == .dateOldest, dayLabelsLoadedKey != nil else { return [:] }
        return Self.computeYearTotals(completed + pinned.filter(\.isComplete), dayLabels: cachedTripDayLabels)
    }

    /// Display groups of one sorted result list, each in sort order.
    nonisolated struct SearchResultGroups<Item> {
        var pinned: [Item] = []
        var active: [Item] = []
        var completed: [Item] = []
        var similar: [Item] = []
        var partial: [Item] = []
    }

    /// Pure grouping seam: strong rows split into Favorites, Currently
    /// Traveling and Past Trips as without a query; similar and partial rows
    /// get their own groups whatever their pin, so a weak match never sits
    /// among exact ones.
    nonisolated static func groupSearchResults<Item>(
        _ sorted: [(item: Item, strength: TripSearchStrength, isComplete: Bool, isPinned: Bool)]
    ) -> SearchResultGroups<Item> {
        var groups = SearchResultGroups<Item>()
        for row in sorted {
            switch row.strength {
            case .similar:
                groups.similar.append(row.item)
            case .partial:
                groups.partial.append(row.item)
            case .strong:
                if row.isPinned {
                    groups.pinned.append(row.item)
                } else if row.isComplete {
                    groups.completed.append(row.item)
                } else {
                    groups.active.append(row.item)
                }
            }
        }
        return groups
    }

    /// The secondary line that says why a row matched.
    nonisolated struct MatchCaption: Equatable {
        enum Kind: Equatable { case includes, passedThrough }
        let kind: Kind
        let value: String

        var text: String {
            switch kind {
            case .includes:
                String(localized: "trips.search.match.includes", defaultValue: "Includes \(value)", comment: "Trip search row caption naming the destination, region or place that matched the query and is not visible in the trip title.")
            case .passedThrough:
                String(localized: "trips.search.match.passed-through", defaultValue: "Passed through \(value)", comment: "Trip search row caption naming the transit stop (for example a layover city) that matched the query.")
            }
        }

        var systemImage: String {
            kind == .includes ? "mappin" : "airplane"
        }
    }

    /// Pure caption seam: the first place or region evidence, else the first
    /// transit one. Title, date and country hits are already visible in the
    /// row (name, dates, flags), so they get no caption.
    nonisolated static func matchCaption(for evidence: [TripSearchEvidence]) -> MatchCaption? {
        if let place = evidence.first(where: { $0.kind == .place || $0.kind == .region }) {
            return MatchCaption(kind: .includes, value: place.text)
        }
        if let transit = evidence.first(where: { $0.kind == .transit }) {
            return MatchCaption(kind: .passedThrough, value: transit.text)
        }
        return nil
    }

    /// The last word may still be typing (prefix matching) unless the raw
    /// debounced text ends in whitespace, punctuation or a symbol.
    nonisolated static func allowsTrailingPartial(rawQuery: String) -> Bool {
        !TripSearchText.endsWithSeparator(rawQuery)
    }

    /// Matches the active filters hide, offered as a one-tap reset.
    nonisolated static func hiddenByFiltersCount(preFilterCount: Int, strictCount: Int, filtersActive: Bool) -> Int {
        filtersActive ? max(0, preFilterCount - strictCount) : 0
    }

    /// Pure "Did you mean" seam. Quiet while the query has a strong match;
    /// otherwise a corrected query the resolver itself answers strongly.
    /// `isKnownWord` keeps correctly spelled words (an unvisited Berlin) as typed.
    static func spellingSuggestion(
        query: String,
        hasStrongMatch: Bool,
        index: TripSearchIndex,
        languageTag: String,
        isKnownWord: ((String) -> Bool)?
    ) -> String? {
        guard !hasStrongMatch, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TripSearch.spellingSuggestion(
            for: query,
            in: index,
            languageTag: languageTag,
            accepts: { corrected in
                TripQueryParser.searchTrips(
                    index: index, query: corrected, allowsTrailingPartial: false, languageTag: languageTag)
                    .contains { $0.strength == .strong }
            },
            isKnownWord: isKnownWord)
    }

    /// Spell-checker dictionaries for `languageTags`: the exact identifier,
    /// then the bare language, then any region of it. Languages without a
    /// dictionary are skipped.
    nonisolated static func spellCheckLanguages(for languageTags: [String], available: [String]) -> [String] {
        var result: [String] = []
        for tag in languageTags {
            let wanted = tag.replacingOccurrences(of: "-", with: "_")
            let language = Locale(identifier: tag).language.languageCode?.identifier ?? tag
            let match = available.first { $0 == wanted }
                ?? available.first { $0 == language }
                ?? available.first { Locale(identifier: $0).language.languageCode?.identifier == language }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    /// The dictionaries of English and the app language written in `word`'s
    /// script. A dictionary accepts any word of a script it does not check
    /// (en passes every Greek word), so a Greek or Cyrillic word gets only a
    /// same-script dictionary, and none when the app language has another
    /// script. Mixed or other scripts get none.
    nonisolated static func spellCheckLanguages(forWord word: String, languageTag: String, available: [String]) -> [String] {
        guard let script = spellCheckScript(of: word) else { return [] }
        let tags = ["en", languageTag].filter {
            Locale.Language(identifier: Locale.Language(identifier: $0).maximalIdentifier).script?.identifier == script
        }
        return spellCheckLanguages(for: tags, available: available)
    }

    /// ISO 15924 code of the letters of `word`: Latn, Grek or Cyrl, nil for
    /// any other or a mix. Combining accents, digits and marks do not count.
    nonisolated static func spellCheckScript(of word: String) -> String? {
        var script: String?
        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            let letter: String
            switch scalar.value {
            case 0x0300...0x036F: continue
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF: letter = "Latn"
            case 0x0370...0x03FF, 0x1F00...0x1FFF: letter = "Grek"
            case 0x0400...0x052F: letter = "Cyrl"
            default: return nil
            }
            if let script, script != letter { return nil }
            script = letter
        }
        return script
    }

    /// True when a system dictionary of English or the app language in the
    /// word's script spells `word` this way, lowercase or capitalized
    /// ("berlin" is Berlin).
    static func isKnownWord(_ word: String, languageTag: String) -> Bool {
        let languages = spellCheckLanguages(
            forWord: word, languageTag: languageTag, available: UITextChecker.availableLanguages)
        guard !languages.isEmpty, !word.isEmpty else { return false }
        let checker = UITextChecker()
        let forms = [word, word.capitalized(with: Locale(identifier: languageTag))]
        return languages.contains { language in
            forms.contains { form in
                checker.rangeOfMisspelledWord(
                    in: form, range: NSRange(location: 0, length: (form as NSString).length),
                    startingAt: 0, wrap: false, language: language).location == NSNotFound
            }
        }
    }

    /// VoiceOver text for a settled result count.
    static func resultCountAnnouncement(_ count: Int) -> String {
        switch count {
        case 0:
            String(localized: "trips.search.result-count.zero", defaultValue: "No matching trips", comment: "VoiceOver announcement when a trip search settles with no results.")
        case 1:
            String(localized: "trips.search.result-count.one", defaultValue: "\(count, format: .number.grouping(.never)) matching trip", comment: "VoiceOver announcement when a trip search settles with one result.")
        default:
            String(localized: "trips.search.result-count.other", defaultValue: "\(count, format: .number.grouping(.never)) matching trips", comment: "VoiceOver announcement when a trip search settles with multiple results.")
        }
    }

    /// Search fields of one planned leg for the Upcoming filter.
    nonisolated struct JourneySearchLeg {
        var title: String
        var locationText: String?
        var resolvedLocality: String?
        var resolvedCountry: String?
        var resolvedISOCountryCode: String?
    }

    /// Strings an Upcoming journey answers to: its titles and destinations,
    /// each leg's title, location and resolved place, and the country names
    /// of each leg's resolved code.
    nonisolated static func journeySearchParts(
        journeyTitles: [String],
        legs: [JourneySearchLeg],
        languageTag: String
    ) -> [String] {
        var parts = journeyTitles
        for leg in legs {
            parts.append(leg.title)
            parts += [leg.locationText, leg.resolvedLocality, leg.resolvedCountry].compactMap { $0 }
            if let code = leg.resolvedISOCountryCode, !code.isEmpty {
                parts += TripSearch.countryAliases(for: [code], languageTag: languageTag)
            }
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One-document index for an Upcoming journey: its parts as places, its
    /// dates as date words and year/month, so the list's resolver reads it
    /// the way it reads a past trip. Without a start date no date matches.
    nonisolated static func journeySearchIndex(
        parts: [String],
        startDate: Date?,
        endDate: Date?,
        countryCodes: Set<String> = [],
        languageTag: String,
        calendar: Calendar = TripFilters.yearCalendar
    ) -> TripSearchIndex {
        var fields = [TripSearchField(kind: .place, displayValues: parts)]
        var start = DateComponents()
        if let startDate {
            fields.append(TripSearchField(kind: .date, displayValues: TripSearchDocument.dateWords(
                start: startDate, end: endDate, languageTag: languageTag, calendar: calendar)))
            start = calendar.dateComponents([.year, .month], from: startDate)
        }
        return TripSearchIndex(documents: [TripSearchDocument(
            tripID: UUID(),
            fields: fields,
            startDate: startDate ?? .distantPast,
            endDate: endDate,
            startYear: start.year ?? 0,
            startMonth: start.month ?? 0,
            durationDays: nil,
            isComplete: false,
            countryCodes: countryCodes)])
    }

    /// Upcoming shows only strong matches: a typo hit on a future plan reads
    /// as noise. Same resolver and trailing-partial flag as the trip list, so
    /// "trip to kyoto" or "kyoto 2026" keeps a planned Kyoto trip.
    nonisolated static func journeyMatchesSearch(
        _ query: String,
        index: TripSearchIndex,
        allowsTrailingPartial: Bool,
        languageTag: String
    ) -> Bool {
        TripQueryParser.searchTrips(
            index: index, query: query, allowsTrailingPartial: allowsTrailingPartial, languageTag: languageTag)
            .contains { $0.strength == .strong }
    }

    /// `journeyMatchesSearch(_:index:allowsTrailingPartial:languageTag:)` over
    /// a journey built from `parts` and its dates.
    nonisolated static func journeyMatchesSearch(
        _ query: String,
        parts: [String],
        startDate: Date? = nil,
        endDate: Date? = nil,
        allowsTrailingPartial: Bool = true,
        languageTag: String
    ) -> Bool {
        journeyMatchesSearch(
            query,
            index: journeySearchIndex(parts: parts, startDate: startDate, endDate: endDate, languageTag: languageTag),
            allowsTrailingPartial: allowsTrailingPartial,
            languageTag: languageTag)
    }

    /// Result count VoiceOver hears: every visible trip row, the matching
    /// Upcoming journeys, and AI suggestions only while they can show (no
    /// strong, similar or journey match).
    nonisolated static func searchResultCount(
        visibleTrips: Int, strictCount: Int, aiSuggested: Int, visibleJourneys: Int
    ) -> Int {
        visibleTrips + visibleJourneys + (strictCount == 0 && visibleJourneys == 0 ? aiSuggested : 0)
    }

    /// What a settled local result means for the AI fallback.
    nonisolated enum AIFallbackStep: Equatable {
        /// Local hits or a query under 3 characters: drop any flight and its progress row.
        case clear
        /// This query's AI answer is already in.
        case keep
        /// Schedule a flight.
        case schedule
    }

    nonisolated static func aiFallbackStep(query: String, localResultsEmpty: Bool, lastAIQuery: String) -> AIFallbackStep {
        guard localResultsEmpty, query.count >= 3 else { return .clear }
        return query == lastAIQuery ? .keep : .schedule
    }

    /// Pure seam for what stays on screen while the index store needs its
    /// off-main preparation: nil keeps the settled slices. Search slices
    /// settled before a wipe (`TripSearchIndexStore.invalidateAll`) give way
    /// to empty ones, so no row, suggestion, empty state or AI derived from
    /// the wiped text stays current during the rebuild. Unsearched slices
    /// carry no search text and stay.
    static func slicesWhilePreparing(_ cached: TripSlices, wipeRevision: Int) -> TripSlices? {
        guard !cached.query.isEmpty, cached.wipeRevision < wipeRevision else { return nil }
        var revoked = TripSlices()
        revoked.wipeRevision = wipeRevision
        return revoked
    }

    /// Pure seam for the no-results card: the field, the local search and the
    /// AI fallback have settled on `query`, and the field has been quiet for
    /// `emptyStateDelay` on it (`revealedQuery`), so it never flashes between
    /// keystrokes.
    nonisolated static func emptyStateCardVisible(
        query: String, revealedQuery: String?, fieldSettled: Bool, resultsCurrent: Bool,
        resultsEmpty: Bool, hasAnyTrips: Bool, journeysEmpty: Bool, aiSettled: Bool
    ) -> Bool {
        !query.isEmpty && revealedQuery == query && fieldSettled && resultsCurrent && resultsEmpty
            && hasAnyTrips && journeysEmpty && aiSettled
    }

    /// One chained planned journey plus its resolved forecast — both computed
    /// once by `recomputePlannedJourneys()` so the body never reads the
    /// `upcomingPlannedTrips` / `homes` @Query (which would republish it on
    /// unrelated saves). `id` mirrors the journey's stable id.
    struct DisplayedJourney: Identifiable {
        let journey: PlannedJourney
        let forecast: PlannedTripForecast?
        /// The legs' resolved countries, first-seen order, for the row's flags.
        var countryCodes: [String] = []
        /// The row's leading wash, from the journeys shown with it.
        var wash: RowWash?
        /// `journeySearchIndex` snapshot, built with the journey so a query
        /// change only refilters and search never rereads the rows.
        let searchIndex: TripSearchIndex
        var id: UUID { journey.id }
    }

    struct SuggestionMemo {
        let query: String
        let indexGeneration: UInt64
        let languageTag: String
        /// Its `accepts` check runs the resolver, whose relative dates move with the clock.
        let clock: SearchClock
        let suggestion: String?
    }

    /// The local day and zone that relative search dates ("this year",
    /// "last month", Swedish `i somras`) are read in.
    nonisolated struct SearchClock: Equatable {
        let day: Int
        let timeZoneIdentifier: String
    }

    /// The search clock at `now` in `timeZone`: its day turns over at that
    /// zone's midnight, like the index store's memo.
    nonisolated static func makeSearchClock(now: Date = .now, timeZone: TimeZone = .current) -> SearchClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return SearchClock(
            day: TripSearchIndexStore.memoDay(now, calendar: calendar),
            timeZoneIdentifier: timeZone.identifier)
    }

    /// The clock the slice key observes: nil without a query, so an idle
    /// list never recomputes on a clock change (no idle observation).
    nonisolated static func sliceSearchClock(query: String, clock: SearchClock) -> SearchClock? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clock
    }

    /// Recompute key must include the trip generation and every user input consumed by slices and pickers.
    struct SliceRecomputeKey: Equatable {
        let storeToken: Int
        let debouncedQuery: String
        let searchActive: Bool
        let filters: TripFilters
        let sortRaw: String
        let pinnedIDs: Set<UUID>
        let photoGeneration: Int
        let aiSuccessIDs: [UUID]
        /// Index store generation, stay token and trailing-partial flag, only
        /// while searching (zero and false otherwise), so the list body
        /// observes the store only while a query is active. Documents index
        /// stay places, so a stay-only save must revalidate them.
        let searchGeneration: Int
        let searchStayToken: Int
        let allowsTrailingPartial: Bool
        /// The local day and zone while searching (nil otherwise): relative
        /// dates move at midnight and with the zone, with no store write.
        let searchClock: SearchClock?
        /// The zone the Gregorian start years are read in, searching or not:
        /// year filters and the year picker move with it, with no store
        /// write. A new day alone changes no start year, so only the zone.
        let yearZoneID: String
    }

    /// What the year picker's options were derived from: the trips and the
    /// zone their start years are read in.
    struct YearPickerKey: Equatable {
        let tripToken: Int
        let yearZoneID: String
    }

    /// Journeys follow their stores and the clock; the slice task refilters them per query.
    struct JourneysRecomputeKey: Equatable {
        let storeToken: Int
        let clockTick: Int
    }

    /// Temporary-home cards follow their rows, the journeys' clock and their
    /// own; stays and trips (`evidenceToken`) count only while a card exists.
    struct TemporaryHomeCardsRecomputeKey: Equatable {
        let storeToken: Int
        let evidenceToken: Int
        let clockTick: Int
        let cardsClockTick: Int
    }

    /// Prewarm when trips change or sort/filter begins consuming photo counts.
    struct PhotoPrewarmKey: Equatable {
        let storeToken: Int
        let needsPhotoCounts: Bool
        /// Observe whole-library invalidation so cleared counts trigger prewarm even without a trip-store change.
        let photoEpoch: Int
    }

    /// Slices for the debounced query and the index that answered it (nil
    /// without a query), or nil while the index store needs its off-main
    /// preparation (the caller keeps the last settled slices).
    private func computeDisplaySlices() -> (slices: TripSlices, index: TripSearchIndex?)? {
        let query = trimmedQuery
        guard !query.isEmpty else { return (computeSlices(query: "", matches: nil), nil) }
        guard let result = searchResult(for: query) else { return nil }
        return (computeSlices(query: query, matches: result.matches), result.index)
    }

    /// Search, then filters, then sort, then grouping.
    /// Pinned trips must be excluded from Active/Past; uncached photo counts sort as zero until prewarm publishes.
    private func computeSlices(query: String, matches: [(trip: Trip, match: TripSearchMatch)]?) -> TripSlices {
        var slices = TripSlices()
        slices.query = query
        var strengths: [PersistentIdentifier: TripSearchStrength] = [:]
        let candidates: [Trip]
        if let matches {
            for (trip, match) in matches {
                let id = trip.persistentModelID
                strengths[id] = match.strength
                if let caption = Self.matchCaption(for: match.evidence) { slices.captions[id] = caption }
            }
            candidates = matches.map(\.trip)
            slices.preFilterCount = matches.count(where: { $0.match.strength != .partial })
            slices.hasStrongMatch = matches.contains { $0.match.strength == .strong }
        } else {
            candidates = trips
        }
        // Query snapshots can still include just-deleted rows; filter before deriving slices.
        slices.all = filters.apply(to: candidates, photoService: PhotoService.shared).filter { !$0.isDeleted }
        let sorted = TripSorter.sort(slices.all, by: sortOrder, photoService: PhotoService.shared)
        let pinnedIDs = PinnedTripsStorage.shared.pinnedIDs
        let groups = Self.groupSearchResults(sorted.map { trip in
            (item: trip,
             strength: strengths[trip.persistentModelID] ?? .strong,
             isComplete: trip.isComplete,
             isPinned: pinnedIDs.contains(trip.id))
        })
        slices.pinned = groups.pinned
        slices.active = groups.active
        slices.completed = groups.completed
        slices.similar = groups.similar
        slices.partial = groups.partial
        slices.yearTotals = yearTotals(completed: groups.completed, pinned: groups.pinned)
        slices.strictCount = slices.all.count - groups.partial.count
        // Partial rows do not block the AI fallback; its rows skip trips the partial section already shows.
        if !query.isEmpty && slices.strictCount == 0 {
            let shown = Set(groups.partial.map(\.persistentModelID))
            slices.aiSuggested = aiSuggestedTrips.filter { !shown.contains($0.persistentModelID) }
        }
        slices.washes = Self.rowWashes(slices, yearSections: sortOrder == .dateNewest || sortOrder == .dateOldest)
        return slices
    }

    /// The Upcoming rows with their washes, for the rows shown together.
    static func withWashes(_ journeys: [DisplayedJourney]) -> [DisplayedJourney] {
        let washes = RowWash.section(journeys.map(\.countryCodes))
        return zip(journeys, washes).map { journey, wash in
            var journey = journey
            journey.wash = wash
            return journey
        }
    }

    /// Every trip row's wash, section by section as the body lays them out:
    /// Active, Favorites, the year sections (or one Past Trips section), and
    /// the search sections.
    static func rowWashes(_ slices: TripSlices, yearSections: Bool) -> [PersistentIdentifier: RowWash] {
        var sections: [[Trip]] = [slices.active, slices.pinned]
        if yearSections {
            sections += groupedByYear(slices.completed).map(\.trips)
        } else {
            sections.append(slices.completed)
        }
        sections += [slices.similar, slices.partial, slices.aiSuggested]
        var washes: [PersistentIdentifier: RowWash] = [:]
        for rows in sections where !rows.isEmpty {
            washes.merge(RowWash.section(rows, key: \.persistentModelID, codes: \.countryCodeList)) { first, _ in first }
        }
        return washes
    }

    /// Resolve AI IDs against live trips, then apply the same chip filters and sort as the main list.
    private var aiSuggestedTrips: [Trip] {
        if case let .success(ids) = aiOutcome {
            let idSet = Set(ids)
            let matched = trips.filter { !$0.isDeleted && idSet.contains($0.id) }
            let filtered = filters.apply(to: matched, photoService: PhotoService.shared)
            return TripSorter.sort(filtered, by: sortOrder, photoService: PhotoService.shared)
        }
        return []
    }

    /// "Did you mean" for settled slices without a strong match, memoized per
    /// (query, index generation, language) so filter and sort churn reuse it.
    /// `index` is the one the search just used, so no second store survey runs.
    private func spellingSuggestion(for slices: TripSlices, index: TripSearchIndex?) -> String? {
        guard !slices.query.isEmpty, !slices.hasStrongMatch, let index else { return nil }
        let languageTag = AppLanguagePreference.currentTag()
        if let memo = suggestionMemo, memo.query == slices.query,
           memo.indexGeneration == index.generation, memo.languageTag == languageTag, memo.clock == searchClock {
            return memo.suggestion
        }
        let suggestion = Self.spellingSuggestion(
            query: slices.query,
            hasStrongMatch: false,
            index: index,
            languageTag: languageTag,
            isKnownWord: { Self.isKnownWord($0, languageTag: languageTag) })
        suggestionMemo = SuggestionMemo(
            query: slices.query, indexGeneration: index.generation, languageTag: languageTag,
            clock: searchClock, suggestion: suggestion)
        return suggestion
    }

    @MainActor
    static func aiCandidateSnapshots(trips: [Trip], filters: TripFilters, photoService: PhotoService) -> [TripSnapshot] {
        let liveNonDeletedTrips = trips.filter { !$0.isDeleted }
        return filters.apply(to: liveNonDeletedTrips, photoService: photoService).map { TripSnapshot(from: $0) }
    }

    /// Year options use unfiltered trips so selecting a year never removes other options.
    var availableYears: [Int] {
        hasLoadedSlices ? cachedYears : Self.computeAvailableYears(startDates: trips.map(\.startDate))
    }

    /// Countries present in the user's trips, with the number of trips
    /// each appears in. Sorted by frequency (most-visited first), then
    /// by ISO code for stability. Feeds the country picker. Cache-or-live,
    /// same as `availableYears`.
    var availableCountries: [(code: String, count: Int)] {
        hasLoadedSlices ? cachedCountries : Self.computeAvailableCountries(countryCodeStrings: trips.map(\.countryCodes))
    }

    /// Cache unfiltered emptiness to distinguish onboarding from no search matches without a body query read.
    var displayHasAnyTrips: Bool {
        hasLoadedSlices ? cachedHasAnyTrips : !trips.isEmpty
    }

    /// Pure year-picker derivation test seam.
    static func computeAvailableYears(startDates: [Date], calendar: Calendar = TripFilters.yearCalendar) -> [Int] {
        let years = Set(startDates.map { calendar.component(.year, from: $0) })
        return years.sorted(by: >)
    }

    /// Pure derivation of the country picker's options. Each element is a raw
    /// `Trip.countryCodes` string (comma-separated ISO codes). Per-trip
    /// deduplication so a trip visiting Greece twice doesn't count Greece
    /// twice; sorted by frequency (desc) then ISO code (asc) for stability.
    static func computeAvailableCountries(countryCodeStrings: [String]) -> [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for codes in countryCodeStrings {
            var seen = Set<String>()
            for raw in codes.split(separator: ",") {
                let code = String(raw)
                guard !code.isEmpty, seen.insert(code).inserted else { continue }
                counts[code, default: 0] += 1
            }
        }
        return counts
            .map { (code: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.code < rhs.code
            }
    }

    // MARK: - FM upgrade card

    /// Minimum heuristic-classified trips before the one-time FM-upgrade card offers itself.
    static let fmUpgradeBacklogThreshold = 3

    /// Exclude user-edited trips from the heuristic backlog; pure count seam for tests.
    static func computeHeuristicBacklogCount(_ trips: [(classifiedByAI: Bool, userEdited: Bool)]) -> Int {
        trips.reduce(0) { $0 + (!$1.classifiedByAI && !$1.userEdited ? 1 : 0) }
    }

    /// The first rows in display order (Favorites, Currently Traveling, Past
    /// Trips), without duplicates, up to `limit`.
    nonisolated static func firstPagePrefetchIDs(
        pinned: [Trip], active: [Trip], completed: [Trip], limit: Int = 20
    ) -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for trip in pinned + active + completed {
            guard ids.count < limit else { break }
            if seen.insert(trip.id).inserted { ids.append(trip.id) }
        }
        return ids
    }

    /// Pure card-visibility seam: require an observed FM upgrade, current availability, sufficient backlog,
    /// no dismissal, and no search/filter scope; the view separately excludes active pipeline work.
    static func computeFMUpgradeCardVisible(
        becameAvailableAt: Date?,
        capabilityAvailable: Bool,
        backlogCount: Int,
        dismissed: Bool,
        isSearching: Bool,
        filtersActive: Bool
    ) -> Bool {
        guard becameAvailableAt != nil else { return false }
        guard capabilityAvailable else { return false }
        guard backlogCount >= fmUpgradeBacklogThreshold else { return false }
        guard !dismissed else { return false }
        guard !isSearching, !filtersActive else { return false }
        return true
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Use the same debounced query as the local search filter.
    var trimmedQuery: String {
        debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchFieldSettled: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery
    }

    /// The rendered slices answer the debounced query (a pending store
    /// preparation keeps the previous query's slices on screen).
    func resultsCurrent(_ slices: TripSlices) -> Bool {
        slices.query == trimmedQuery
    }

    // MARK: - Cache-or-live accessors + recompute keys

    /// The slices the body renders: the cache once loaded, else a live
    /// computation for the cold first frame. Always run through
    /// `filteringDeleted()` so a background/remote delete that landed after the
    /// last recompute can't render (and trap on) a deleted row.
    /// The cold frame never searches: a query cannot be debounced before the
    /// first recompute, and the index store is read only from tasks.
    var displaySlices: TripSlices {
        let slices = hasLoadedSlices ? cachedSlices
            : (trimmedQuery.isEmpty ? computeSlices(query: "", matches: nil) : TripSlices())
        return slices.filteringDeleted()
    }

    /// The planned journeys the body renders: cache once loaded, else live.
    /// These are value snapshots, so no liveness filtering is needed.
    var displayedJourneys: [DisplayedJourney] {
        hasLoadedJourneys ? cachedJourneys : Self.withWashes(computeDisplayedJourneys())
    }

    /// Upcoming while searching: the journeys task's strong matches for the
    /// debounced query, none until it has answered that query.
    var searchedJourneys: [DisplayedJourney] {
        cachedSearchJourneys.query == trimmedQuery ? cachedSearchJourneys.journeys : []
    }

    /// The searched journeys Upcoming actually shows (filters hide it). They
    /// count as results for the empty state, the AI fallback, "Did you mean"
    /// and the VoiceOver count.
    private var visibleSearchedJourneys: [DisplayedJourney] {
        filters.isActive ? [] : searchedJourneys
    }

    /// The temporary-home cards the debounced query matches, current then
    /// past, none until the search task has answered that query. Filters
    /// scope trips, so they do not hide these.
    var searchedTemporaryHomeCards: [TemporaryHomeCards.Card] {
        let query = trimmedQuery
        guard !query.isEmpty, cachedSearchTemporaryHomeIDs.query == query else { return [] }
        let ids = cachedSearchTemporaryHomeIDs.ids
        return (cachedTemporaryHomeCards + cachedPastTemporaryHomeCards).filter { ids.contains($0.id) }
    }

    /// Visible answers to the query that are not trip rows: Upcoming
    /// journeys and temporary homes. They count as results for the empty
    /// state, the AI fallback, "Did you mean" and the VoiceOver count.
    var visibleSearchedNonTripCount: Int {
        visibleSearchedJourneys.count + searchedTemporaryHomeCards.count
    }

    /// The `.success` ids of the current AI outcome, or `[]`. Folded into the
    /// slice key so the AI-suggestions slice recomputes when the outcome lands.
    private var aiOutcomeSuccessIDs: [UUID] {
        if case let .success(ids) = aiOutcome { return ids }
        return []
    }

    var slicesRecomputeKey: SliceRecomputeKey {
        SliceRecomputeKey(
            storeToken: StoreChangeTracker.shared.token(for: .trip),
            debouncedQuery: debouncedSearchQuery,
            searchActive: isSearching,
            filters: filters,
            sortRaw: sortOrderRaw,
            pinnedIDs: PinnedTripsStorage.shared.pinnedIDs,
            // Observe photo-count changes only while the active sort/filter consumes counts.
            photoGeneration: needsPhotoCounts ? PhotoService.shared.photoCacheGeneration : 0,
            aiSuccessIDs: aiOutcomeSuccessIDs,
            // Read the store only while searching (no idle observation).
            searchGeneration: trimmedQuery.isEmpty ? 0 : TripSearchIndexStore.shared.generation,
            searchStayToken: trimmedQuery.isEmpty ? 0 : StoreChangeTracker.shared.token(for: .stay),
            allowsTrailingPartial: trimmedQuery.isEmpty ? false : Self.allowsTrailingPartial(rawQuery: debouncedSearchQuery),
            searchClock: Self.sliceSearchClock(query: trimmedQuery, clock: searchClock),
            yearZoneID: searchClock.timeZoneIdentifier
        )
    }

    /// Track PlannedTrip, Home, temporary home and Trip changes so a started journey hides when a real ongoing trip forms,
    /// and the clock tick so a leg that ends or starts with no store write still recomputes.
    var journeysRecomputeKey: JourneysRecomputeKey {
        JourneysRecomputeKey(
            storeToken: StoreChangeTracker.shared.token(for: [.plannedTrip, .home, .temporaryHome, .trip]),
            clockTick: journeysClockTick)
    }

    /// Track temporary-home changes and the clock ticks, so a card whose dates pass with no store write still reloads.
    var temporaryHomeCardsRecomputeKey: TemporaryHomeCardsRecomputeKey {
        Self.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: temporaryHomeCardsFollowEvidence,
            clockTick: journeysClockTick,
            cardsClockTick: temporaryHomeCardsClockTick)
    }

    /// The cards' reload key. Stays and trips are read only while a card can
    /// change with them (no idle observation).
    static func makeTemporaryHomeCardsRecomputeKey(
        followEvidence: Bool, clockTick: Int, cardsClockTick: Int,
        tracker: StoreChangeTracker = .shared
    ) -> TemporaryHomeCardsRecomputeKey {
        TemporaryHomeCardsRecomputeKey(
            storeToken: tracker.token(for: .temporaryHome),
            evidenceToken: followEvidence ? tracker.token(for: [.stay, .trip]) : 0,
            clockTick: clockTick,
            cardsClockTick: cardsClockTick)
    }

    /// Whether stays and trips reload the cards after a load of `cardCount`
    /// cards: any card, ended ones included, since a late stay or a
    /// deleted trip moves an ended card's days and trips too. With none the
    /// list observes neither for them.
    nonisolated static func temporaryHomeCardsFollowEvidence(cardCount: Int) -> Bool {
        cardCount > 0
    }

    /// Recompute every trips-derived cache in one pass, off the raw `@Query`
    /// republish treadmill. Reads `trips` here (in a `.task`, not the body) so
    /// it never registers a body-level `@Query` dependency. False while the
    /// index store needs its off-main preparation (the search surveyed once).
    @MainActor
    @discardableResult
    func recomputeTripSlices() -> Bool {
        let wipeRevision = TripSearchIndexStore.shared.wipeRevision
        // Before either path: a small library rebuilds on main at once and
        // never prepares, and the slices below read the AI outcome.
        if hasLoadedSlices, cachedSlices.wipeRevision < wipeRevision {
            resetSearchStateAfterWipe()
        }
        let computed = computeDisplaySlices()
        if let computed {
            var slices = computed.slices
            slices.spellingSuggestion = spellingSuggestion(for: slices, index: computed.index)
            slices.wipeRevision = wipeRevision
            cachedSlices = slices
        } else if !hasLoadedSlices {
            // Nothing settled yet to keep: show the unsearched list meanwhile.
            cachedSlices = computeSlices(query: "", matches: nil)
            cachedSlices.wipeRevision = wipeRevision
        } else if let revoked = Self.slicesWhilePreparing(cachedSlices, wipeRevision: wipeRevision) {
            cachedSlices = revoked
        }
        // Query-independent: rebuilt only when the trips change, not per keystroke.
        let token = StoreChangeTracker.shared.token(for: .trip)
        // Start years also move with the zone they are read in.
        let yearPickerKey = YearPickerKey(
            tripToken: token, yearZoneID: TripFilters.yearCalendar.timeZone.identifier)
        if !hasLoadedSlices || yearPickerKey != derivedYearPickerKey {
            cachedYears = Self.computeAvailableYears(startDates: trips.map(\.startDate))
            derivedYearPickerKey = yearPickerKey
        }
        if !hasLoadedSlices || token != derivedStoreToken {
            cachedCountries = Self.computeAvailableCountries(countryCodeStrings: trips.map(\.countryCodes))
            cachedHasAnyTrips = !trips.isEmpty
            cachedHeuristicBacklog = Self.computeHeuristicBacklogCount(
                trips.map { ($0.classifiedByAI, $0.userEdited) }
            )
            recomputeTemporaryHomeSuggestions()
            derivedStoreToken = token
        }
        hasLoadedSlices = true
        return computed != nil
    }

    /// Faults in the first rows' stays (and title variants outside English)
    /// in one bounded fetch on the main context when the store or page changes,
    /// instead of one row at a time as they scroll in.
    @MainActor
    func prefetchFirstPageIfNeeded() {
        let token = StoreChangeTracker.shared.token(for: .trip)
        let slices = cachedSlices.filteringDeleted()
        let ids = Self.firstPagePrefetchIDs(
            pinned: slices.pinned, active: slices.active, completed: slices.completed)
        guard token != lastPrefetchedTripToken || ids != lastPrefetchedTripIDs else { return }
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { ids.contains($0.id) })
        var keyPaths: [PartialKeyPath<Trip>] = [\Trip.stays]
        if AppLanguagePreference.currentTag() != "en" { keyPaths.append(\Trip.localizedTitles) }
        descriptor.relationshipKeyPathsForPrefetching = keyPaths
        do {
            _ = try modelContext.fetch(descriptor)
            lastPrefetchedTripToken = token
            lastPrefetchedTripIDs = ids
        } catch {
            return
        }
    }

    /// A wipe revoked the text the AI outcome and the "Did you mean" memo
    /// came from: drop them and any flight, so the kept query reruns from
    /// scratch once the index is rebuilt.
    @MainActor
    private func resetSearchStateAfterWipe() {
        aiDebounceTask?.cancel()
        aiOutcome = nil
        lastAIQuery = ""
        aiScheduledQuery = ""
        aiSearchGeneration += 1
        aiSearching = false
        aiPending = false
        suggestionMemo = nil
    }

    /// Re-reads the search clock on activation, appearance and time or zone
    /// changes. A new local day or zone while a query is on screen revokes
    /// the AI answer, any flight in progress and the "Did you mean" memo,
    /// all derived from the old dates (the same revocation a wipe needs);
    /// the slice key then reruns the local search, which may schedule a
    /// fresh AI flight for the same text.
    @MainActor
    func refreshSearchClock() {
        let clock = Self.makeSearchClock()
        guard clock != searchClock else { return }
        searchClock = clock
        guard !trimmedQuery.isEmpty else { return }
        resetSearchStateAfterWipe()
    }

    /// Rebuild the journeys on their store token; the query only refilters them.
    @MainActor
    func recomputePlannedJourneys() {
        cachedJourneys = Self.withWashes(computeDisplayedJourneys())
        hasLoadedJourneys = true
        refilterSearchedJourneys()
    }

    /// Reload the temporary-home cards on their own context, off the main
    /// actor. With no temporary home this is one fetch and no section. A
    /// superseded load stops its worker and changes nothing.
    @MainActor
    func recomputeTemporaryHomeCards() async {
        let now = Date.now
        let outcome = await TemporaryHomeCards.loadDetached(
            container: modelContext.container, now: now, fallbackZone: .current)
        switch outcome {
        case .superseded:
            return
        case .loaded(let cards):
            let sections = TemporaryHomeCards.sections(cards, now: now)
            cachedTemporaryHomeCards = sections.current
            cachedPastTemporaryHomeCards = sections.past
            // Flipping this changes the key, so the first card costs one more load.
            temporaryHomeCardsFollowEvidence = Self.temporaryHomeCardsFollowEvidence(cardCount: cards.count)
        case .failed(let error):
            // A failed read is not "no temporary home": show no section, never
            // a half-built card, and let the next stay or trip change retry.
            logger.error("Temporary home cards load failed: \(error.localizedDescription)")
            cachedTemporaryHomeCards = []
            cachedPastTemporaryHomeCards = []
            temporaryHomeCardsFollowEvidence = true
        }
        // The rows behind the search matches and the suggestions may have
        // changed with the cards (this task follows temporary homes and the clock).
        refilterSearchedTemporaryHomes()
        recomputeTemporaryHomeSuggestions()
    }

    /// The cached journeys the debounced query matches strongly: at most three
    /// one-document resolver runs, so every slice recompute can afford it.
    @MainActor
    func refilterSearchedJourneys() {
        guard hasLoadedJourneys else {
            recomputePlannedJourneys()
            return
        }
        let query = trimmedQuery
        guard !query.isEmpty else {
            cachedSearchJourneys = ("", [])
            return
        }
        let languageTag = AppLanguagePreference.currentTag()
        let allowsTrailingPartial = Self.allowsTrailingPartial(rawQuery: debouncedSearchQuery)
        cachedSearchJourneys = (query, Self.withWashes(cachedJourneys.filter {
            Self.journeyMatchesSearch(
                query, index: $0.searchIndex, allowsTrailingPartial: allowsTrailingPartial, languageTag: languageTag)
        }))
    }

    /// The temporary homes the debounced query matches strongly by label or
    /// place: one one-document resolver run per declaration, read here (in
    /// a task) so the body never reads the `temporaryHomes` query.
    @MainActor
    func refilterSearchedTemporaryHomes() {
        let query = trimmedQuery
        guard !query.isEmpty else {
            cachedSearchTemporaryHomeIDs = ("", [])
            return
        }
        let languageTag = AppLanguagePreference.currentTag()
        let allowsTrailingPartial = Self.allowsTrailingPartial(rawQuery: debouncedSearchQuery)
        let rows = HomeAnchors.collapsingTwins(temporaryHomes.filter { !$0.isDeleted })
        cachedSearchTemporaryHomeIDs = (query, Set(rows.filter {
            Self.journeyMatchesSearch(
                query,
                parts: Self.temporaryHomeSearchParts(
                    label: $0.label, locality: $0.locality, country: $0.country,
                    isoCountryCode: $0.isoCountryCode, languageTag: languageTag),
                allowsTrailingPartial: allowsTrailingPartial,
                languageTag: languageTag)
        }.map(\.id)))
    }

    /// Strings a temporary home answers to: its label, its city, its stored
    /// country and the country names of its code, read the way Upcoming
    /// reads a leg (`journeySearchParts`).
    nonisolated static func temporaryHomeSearchParts(
        label: String, locality: String?, country: String?, isoCountryCode: String?, languageTag: String
    ) -> [String] {
        journeySearchParts(
            journeyTitles: [label],
            legs: [JourneySearchLeg(
                title: "", locationText: nil, resolvedLocality: locality,
                resolvedCountry: country, resolvedISOCountryCode: isoCountryCode)],
            languageTag: languageTag)
    }

    /// Why the list evaluates a trip's temporary-home suggestion: an open
    /// trip for its row's line, a completed one only so the demotion tip
    /// can skip it.
    nonisolated enum SuggestionScope: Equatable { case row, tipOnly }

    /// The scope a trip's stored dates put it in: every open trip, and a
    /// completed trip of 27 or more days (the completed rule's 28, with a
    /// day of slack for zones). Nil reads no stay. Pure.
    nonisolated static func suggestionScope(
        isComplete: Bool, startDate: Date, endDate: Date?, timeZone: TimeZone = .current
    ) -> SuggestionScope? {
        guard isComplete, let endDate else { return .row }
        return Trip.inclusiveDays(from: startDate, in: timeZone, to: endDate, in: timeZone) >= 27 ? .tipOnly : nil
    }

    /// What one evaluated trip shows: a line on its row only for an
    /// ongoing candidate of an open trip; the demotion tip skips it whenever
    /// a candidate exists or the user answered Not Now to one, so dismissing
    /// the question never brings "Not a trip?" back for that trip. Pure.
    nonisolated static func suggestionOutcome(
        scope: SuggestionScope, isDismissed: Bool, candidateIsOngoing: Bool?
    ) -> (showsLine: Bool, skipsTip: Bool) {
        if isDismissed { return (false, true) }
        guard let candidateIsOngoing else { return (false, false) }
        return (scope == .row && candidateIsOngoing, true)
    }

    /// What one suggestion pass reads: the trips and stays by their store
    /// tokens, the declarations, which of them cover now, the civil day and
    /// its zone (`TemporaryHomeSuggestion.CacheKey.zone`), whether the tip is
    /// learned and the Not Now answers. Three triggers ask for a pass; for
    /// one update only the first one runs.
    nonisolated struct SuggestionPassKey: Equatable {
        let trips: Int
        let stays: Int
        let declarations: Int
        let covering: Set<UUID>
        let day: Date
        let zone: String
        let tipLearned: Bool
        let dismissals: [String]
    }

    nonisolated static func suggestionPassKey(
        trips: Int, stays: Int, declarations: [HomeAnchor], now: Date, timeZone: TimeZone = .current,
        tipLearned: Bool, dismissals: [String]
    ) -> SuggestionPassKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return SuggestionPassKey(
            trips: trips, stays: stays,
            declarations: TemporaryHomeSuggestion.declarationsFingerprint(declarations),
            covering: Set(declarations.filter { $0.isTemporary && $0.covers(now) }.map(\.id)),
            day: calendar.startOfDay(for: now), zone: timeZone.identifier,
            tipLearned: tipLearned, dismissals: dismissals)
    }

    /// Rebuild the open trips' suggestion lines and the trips the demotion
    /// tip skips. Asked for when the trips change (the slice recompute's
    /// query-independent pass), after each card load (temporary homes,
    /// evidence and the clock) and on stay changes while an open trip is
    /// long enough; never per keystroke or per row. A pass over the inputs
    /// the last one read is skipped, and each trip answers from
    /// `TemporaryHomeSuggestion`'s cache while its own inputs hold.
    @MainActor
    func recomputeTemporaryHomeSuggestions() {
        let now = Date.now
        let homes = HomeAnchors.collapsingTwins(temporaryHomes.filter { !$0.isDeleted })
        let dismissals = UserDefaults.standard.stringArray(
            forKey: TemporaryHomeSuggestion.dismissalsKey) ?? []
        let passKey = Self.suggestionPassKey(
            trips: StoreChangeTracker.shared.token(for: .trip),
            stays: StoreChangeTracker.shared.token(for: .stay),
            declarations: homes.map { HomeAnchor($0) }, now: now,
            tipLearned: correctionTipLearned, dismissals: dismissals)
        guard passKey != temporaryHomeSuggestionPassKey else { return }
        temporaryHomeSuggestionPassKey = passKey
        // Answered Not Now: the tip skips the trip whatever its scope is now.
        let dismissedIDs = Set(dismissals.compactMap(UUID.init(uuidString:)))
        var lines: [UUID: TemporaryHomeSuggestion.Candidate] = [:]
        var suggested = dismissedIDs
        var followsStays = false
        for trip in trips where !trip.isDeleted {
            if !followsStays, Self.suggestionFollowsStays(
                isComplete: trip.isComplete, startDate: trip.startDate, now: now) {
                followsStays = true
            }
            guard let scope = Self.suggestionScope(
                isComplete: trip.isComplete, startDate: trip.startDate, endDate: trip.endDate) else { continue }
            // A completed trip is evaluated only for the tip; once it is learned, never.
            if scope == .tipOnly, correctionTipLearned { continue }
            let dismissed = dismissedIDs.contains(trip.id)
            let candidate = dismissed ? nil
                : TemporaryHomeSuggestion.candidate(for: trip, temporaryHomes: homes, now: now)
            let outcome = Self.suggestionOutcome(
                scope: scope, isDismissed: dismissed, candidateIsOngoing: candidate?.isOngoing)
            if outcome.skipsTip { suggested.insert(trip.id) }
            if outcome.showsLine, let candidate { lines[trip.id] = candidate }
        }
        cachedTemporaryHomeSuggestions = lines
        cachedSuggestedTripIDs = suggested
        if followsStays != temporaryHomeSuggestionFollowsStays {
            temporaryHomeSuggestionFollowsStays = followsStays
        }
    }

    /// Whether a trip makes the list rerun the suggestions on stay changes:
    /// an open trip of 13 or more civil days, the ongoing rule's 14
    /// less a day of slack for zones, whether or not any card exists. Its
    /// evidence (share of time, overnights) moves with stays alone. Pure.
    nonisolated static func suggestionFollowsStays(
        isComplete: Bool, startDate: Date, now: Date, timeZone: TimeZone = .current
    ) -> Bool {
        !isComplete && Trip.inclusiveDays(from: startDate, in: timeZone, to: now, in: timeZone)
            >= TemporaryHomeSuggestion.ongoingMinimumDays - 1
    }

    /// The stay token the suggestions follow: 0 while no trip needs it, so an
    /// idle list observes no stay change.
    static func suggestionStayToken(followsStays: Bool, tracker: StoreChangeTracker = .shared) -> Int {
        followsStays ? tracker.token(for: .stay) : 0
    }

    /// "Set Up" on a row's line: the form, prefilled from the evidence.
    func setUpTemporaryHome(_ candidate: TemporaryHomeSuggestion.Candidate) {
        temporaryHomeSheetMode = .add(prefill: candidate.prefill)
    }

    /// "Not Now": device-local, and the line goes at once. The trip stays
    /// skipped by the demotion tip.
    func dismissTemporaryHomeSuggestion(_ candidate: TemporaryHomeSuggestion.Candidate) {
        TemporaryHomeSuggestion.dismiss(candidate.tripID)
        cachedTemporaryHomeSuggestions[candidate.tripID] = nil
        cachedSuggestedTripIDs.insert(candidate.tripID)
    }
}
