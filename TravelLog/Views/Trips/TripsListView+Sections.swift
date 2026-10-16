//
//  TripsListView+Sections.swift
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

    // MARK: - Filter Chip Row

    /// Keep filters inside the List so chips and trips scroll together without safe-area material overlap.
    /// Avoid `.safeAreaBar`: its reserved area caused scroll-top snapback on iOS 26.
    @ViewBuilder
    var filterChipSection: some View {
        Section {
            FilterChipBar(
                sortOrderRaw: $sortOrderRaw,
                filters: $filters,
                availableYears: availableYears,
                availableCountries: availableCountries
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Status

    @ViewBuilder
    var statusSection: some View {
        if isProcessing {
            Section {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text("Processing stays and assembling trips…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - FM Upgrade Card

    /// The view adds a no-pipeline-running guard to the pure upgrade-card visibility rules.
    @ViewBuilder
    var fmUpgradeSection: some View {
        // The availability query only runs once an upgrade was observed.
        let becameAt = FMCapability.becameAvailableAt()
        let visible = Self.computeFMUpgradeCardVisible(
            becameAvailableAt: becameAt,
            capabilityAvailable: becameAt != nil && FMCapability.current == .available,
            backlogCount: cachedHeuristicBacklog,
            dismissed: fmUpgradeCardDismissed,
            isSearching: !trimmedQuery.isEmpty,
            filtersActive: filters.isActive
        )
        if isEnhancing {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("Enhancing your travel history…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else if visible && !isProcessing {
            Section {
                fmUpgradeCard
            }
        }
    }

    private var fmUpgradeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Enhance Your Travel History")
                        .font(.subheadline.weight(.semibold))
                }
            }

            // Borderless capsule buttons preserve inline List row geometry.
            HStack(spacing: 10) {
                Button {
                    enhanceHistory()
                } label: {
                    Text("Enhance")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)

                Button {
                    dismissFMUpgradeCard()
                } label: {
                    Text("Not Now")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    /// Run EXACTLY the reclassification path the Settings "Reclassify All
    /// Trips" button uses (`TripClassifier.reclassifyAll` — queued behind
    /// in-flight pipeline runs, preserves user-edited trips / overrides /
    /// favorites / stable `Trip.id`). Mirror its post-run bookkeeping (tracker
    /// bump + widget reload — the widget process can't observe the tracker),
    /// then recompute slices immediately (local-mutation convention). Only a
    /// completed rebuild sets the dismissed flag (so the card doesn't flicker
    /// if a few trips legitimately stay heuristic); a failed one keeps the
    /// card and says so, and units it committed before failing still publish.
    private func enhanceHistory() {
        guard !isEnhancing else { return }
        isEnhancing = true
        Task {
            let outcome = await AppDelegate.tripClassifier.reclassifyAll()
            if outcome == .completed {
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
            }
            StoreChangeTracker.shared.bump([.trip, .stay])
            WidgetCenter.shared.reloadAllTimelines()
            let state = Self.computeFMUpgradeCardState(after: outcome)
            if state.dismiss { fmUpgradeCardDismissed = true }
            if state.showFailure { saveFailed = true }
            recomputeTripSlices()
            isEnhancing = false
        }
    }

    /// The one-shot card dismisses only after a committed rebuild; a failed
    /// one keeps the card and shows the shared save-error alert.
    static func computeFMUpgradeCardState(
        after outcome: TripClassifier.RebuildOutcome
    ) -> (dismiss: Bool, showFailure: Bool) {
        switch outcome {
        case .completed: (true, false)
        case .failed: (false, true)
        case .cancelled: (false, false)
        }
    }

    /// "Not Now": device-local dismiss, then recompute so the card
    /// disappears immediately (the permanent re-offer lives in Settings).
    private func dismissFMUpgradeCard() {
        fmUpgradeCardDismissed = true
        recomputeTripSlices()
    }

    // MARK: - Pinned Trips

    /// Chain calendar legs, including low-confidence legs; hide journeys whose best leg is low-confidence.
    /// Search and filters hide future journeys. Derive in the task without body-level query reads.
    /// Guard isDeleted before reading models that dedup may have removed.
    func computeDisplayedJourneys() -> [DisplayedJourney] {
        let now = Date.now
        let rows = upcomingPlannedTrips.filter { !$0.isDeleted && $0.currentUntil() >= now }
        let legs = rows.map {
            PlannedTripChainer.Leg(
                id: $0.id,
                title: $0.title,
                startDate: $0.startDate,
                endDate: $0.endDate,
                confidence: $0.confidence
            )
        }
        guard !legs.isEmpty else { return [] }
        // Home labels/localities/admin areas let "Trip to <home>" register
        // as a return leg even when no transport leg names the origin.
        var homeNames = homes
            .filter { !$0.isDeleted }
            .flatMap { [$0.label, $0.locality ?? "", $0.administrativeArea ?? ""] }
        // A temporary home that has not ended names a return leg too, the
        // rule `PlannedTripChainer.storeInputs` applies for the widget.
        homeNames += HomeAnchors.collapsingTwins(temporaryHomes.filter { !$0.isDeleted })
            .filter { ($0.endedAt ?? .distantFuture) >= now }
            .flatMap { [$0.label, $0.locality ?? "", $0.administrativeArea ?? ""] }
        // Suppress started journeys already represented by an ongoing trip; scans retire events only after their end.
        // Read trips in this task, never in body.
        let ongoingTripStartDates = trips
            .filter { !$0.isDeleted && !$0.isComplete }
            .map(\.startDate)
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: homeNames)
            .filter { $0.confidence != .low }
            .filter {
                !PlannedTripChainer.journeyIsSupersededByOngoingTrip(
                    journeyStart: $0.startDate,
                    journeyEnd: $0.endDate,
                    now: now,
                    ongoingTripStartDates: ongoingTripStartDates
                )
            }
            .prefix(3)
        let languageTag = AppLanguagePreference.currentTag()
        return journeys.map { journey in
            let ids = Set(journey.legIDs)
            let legs = rows.filter { ids.contains($0.id) }.map {
                JourneySearchLeg(
                    title: $0.title,
                    locationText: $0.locationText,
                    resolvedLocality: $0.resolvedLocality,
                    resolvedCountry: $0.resolvedCountry,
                    resolvedISOCountryCode: $0.resolvedISOCountryCode)
            }
            let parts = Self.journeySearchParts(
                journeyTitles: [journey.displayName, journey.fallbackTitle] + journey.destinations,
                legs: legs,
                languageTag: languageTag)
            let codes = Set(legs.compactMap { $0.resolvedISOCountryCode?.uppercased() }.filter { !$0.isEmpty })
            return DisplayedJourney(
                journey: journey,
                forecast: forecast(for: journey, in: rows),
                searchIndex: Self.journeySearchIndex(
                    parts: parts, startDate: journey.startDate, endDate: journey.endDate,
                    countryCodes: codes, languageTag: languageTag))
        }
    }

    @ViewBuilder
    var plannedTripsSection: some View {
        // Filter check FIRST: filters scope real, historical trips, so plans
        // hide. A settled query keeps only the journeys it matches strongly;
        // the debounced query gates it so rows and sections move together.
        if !filters.isActive {
            let journeys = trimmedQuery.isEmpty ? displayedJourneys : searchedJourneys
            if !journeys.isEmpty {
                Section {
                    ForEach(journeys) { displayed in
                        PlannedTripCard(journey: displayed.journey, forecast: displayed.forecast) {
                            dismissJourney(displayed.journey)
                        }
                    }
                    // Apple Weather attribution: the forecast card renders WeatherKit data.
                    if journeys.contains(where: { $0.forecast != nil }) {
                        WeatherAttributionFootnote()
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Upcoming")
                }
            }
        }
    }

    /// Temporary homes between Upcoming and Favorites. Without a query or a
    /// filter: the upcoming, active and recently ended cards. Under a query:
    /// the cards it matches by label or place, whatever the filters,
    /// which scope trips. Under filters alone: a compact link to each active
    /// one, so its management and end stay one tap away.
    @ViewBuilder
    var temporaryHomesSection: some View {
        if !trimmedQuery.isEmpty {
            temporaryHomeCardsSection(searchedTemporaryHomeCards)
        } else if filters.isActive {
            activeTemporaryHomeLinksSection
        } else {
            temporaryHomeCardsSection(cachedTemporaryHomeCards)
        }
    }

    @ViewBuilder
    private func temporaryHomeCardsSection(_ cards: [TemporaryHomeCards.Card]) -> some View {
        if !cards.isEmpty {
            Section {
                ForEach(cards) { card in
                    NavigationLink {
                        TemporaryHomeDetailView(cardID: card.id, card: card)
                    } label: {
                        TemporaryHomeCardRow(card: card) { temporaryHomeSheetMode = $0 }
                    }
                }
            } header: {
                temporaryHomesHeader
            }
        }
    }

    /// One line per active temporary home while filters scope the trips.
    @ViewBuilder
    private var activeTemporaryHomeLinksSection: some View {
        let active = cachedTemporaryHomeCards.filter { $0.state == .active }
        if !active.isEmpty {
            Section {
                ForEach(active) { card in
                    NavigationLink {
                        TemporaryHomeDetailView(cardID: card.id, card: card)
                    } label: {
                        Label(card.title, systemImage: "house.and.flag")
                    }
                }
            } header: {
                temporaryHomesHeader
            }
        }
    }

    private var temporaryHomesHeader: some View {
        Text(String(
            localized: "trips.temporary-homes.header",
            defaultValue: "Temporary Homes",
            comment: "Header of the Trips list section showing the user's temporary homes."
        ))
    }

    /// Temporary homes that ended longer ago, below the past trips: the same
    /// row and link, hidden under a query or a filter (a query shows its
    /// matches in the section above).
    @ViewBuilder
    var pastTemporaryHomesSection: some View {
        if !filters.isActive, trimmedQuery.isEmpty, !cachedPastTemporaryHomeCards.isEmpty {
            Section {
                ForEach(cachedPastTemporaryHomeCards) { card in
                    NavigationLink {
                        TemporaryHomeDetailView(cardID: card.id, card: card)
                    } label: {
                        TemporaryHomeCardRow(card: card) { temporaryHomeSheetMode = $0 }
                    }
                }
            } header: {
                Text(String(
                    localized: "trips.temporary-homes.past.header",
                    defaultValue: "Past Temporary Homes",
                    comment: "Header of the Trips list section, below the past trips, showing temporary homes that ended more than 30 days ago."
                ))
            }
        }
    }

    /// The journey's forecast: the first member row carrying one.
    /// Rows gain forecasts once resolved and within the ~10-day horizon.
    /// Takes the pre-filtered `rows` so it doesn't re-scan the @Query.
    private func forecast(for journey: PlannedJourney, in rows: [PlannedTrip]) -> PlannedTripForecast? {
        let ids = Set(journey.legIDs)
        return rows
            .first { ids.contains($0.id) && $0.forecastWeatherData != nil }?
            .forecast
    }

    /// Dismiss all journey legs permanently while source events stand.
    /// Pass Sendable IDs through PipelineGate to serialize against calendar-scan writes.
    private func dismissJourney(_ journey: PlannedJourney) {
        let ids = Set(journey.legIDs)
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
                await Self.dismissPlannedTrips(ids: ids)
            }
            // The tracker bump is 500 ms debounced; recompute NOW so the card
            // disappears immediately rather than lingering until the debounce
            // (after a failure this redraws the card the rollback kept).
            recomputePlannedJourneys()
            guard saved else {
                saveFailed = true
                return
            }
            // Reload UpcomingTripWidget so dismissed journeys disappear there too.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The actual dismissal, on the main context (same pattern as
    /// `mergeTrips`: static + ID-based so the gate closure captures only
    /// Sendable values; refetching tolerates rows a unit ahead of us in the
    /// gate's queue already deleted). Returns whether the dismissal is
    /// committed. `.upcoming` and `.expired` rows become `.dismissed`: a queued
    /// scan may have expired a leg meanwhile, and a same-identity extension
    /// would revive an expired leg the user dismissed. A `.matched` record stands.
    /// Container, read and save are injectable for PlannedTripDismissalTests.
    @discardableResult
    static func dismissPlannedTrips(
        ids: Set<UUID>,
        container: ModelContainer = AppDelegate.modelContainer,
        fetch: (ModelContext, Set<UUID>) throws -> [PlannedTrip] = { try TripsListView.fetchPlannedTrips(ids: $1, in: $0) },
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        let modelContext = container.mainContext
        // Rollback is context-wide; preserve earlier pending edits first. If
        // that fails they stay pending, and nothing is dismissed.
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let rows: [PlannedTrip]
        do {
            rows = try fetch(modelContext, ids)
        } catch {
            logger.error("Planned trip dismissal fetch failed: \(error.localizedDescription)")
            return false
        }
        let dismissible = rows.filter { $0.status == .upcoming || $0.status == .expired }
        // Nothing left to dismiss (rows deleted, matched or dismissed
        // meanwhile): the store already matches the request.
        guard !dismissible.isEmpty else { return true }
        for row in dismissible {
            row.status = .dismissed
        }
        do {
            try save(modelContext)
        } catch {
            modelContext.rollback()
            logger.error("Planned trip dismissal save failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    nonisolated static func fetchPlannedTrips(ids: Set<UUID>, in modelContext: ModelContext) throws -> [PlannedTrip] {
        let predicate = #Predicate<PlannedTrip> { ids.contains($0.id) }
        return try modelContext.fetch(FetchDescriptor<PlannedTrip>(predicate: predicate))
    }

    /// Section at the top of the list for user-starred trips. Pinned
    /// trips are HIDDEN from the Active / Past sections (`groupSearchResults`
    /// routes each row by its pin) so the user sees them once, at the top.
    /// State is iCloud-synced through `PinnedTripsStorage` — pinning on
    /// one device propagates to others (best-effort, seconds-to-minutes).
    @ViewBuilder
    func pinnedTripsSection(
        _ pinned: [Trip], captions: [PersistentIdentifier: MatchCaption], tipAnchorID: UUID?
    ) -> some View {
        if !pinned.isEmpty {
            Section {
                ForEach(pinned, id: \.persistentModelID) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        // Active trips that happen to be pinned still
                        // get the "live" indicator via ActiveTripRow.
                        // Completed trips use the standard row.
                        if trip.isComplete {
                            TripRow(trip: trip, caption: captions[trip.persistentModelID])
                        } else {
                            activeTripRow(trip, caption: captions[trip.persistentModelID])
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            tripToDelete = trip
                        }
                    }
                    .contextMenu { tripContextMenu(for: trip) }
                    .popoverTip(trip.id == tipAnchorID ? tripDiscoveryTip(for: trip) : nil)
                }
            } header: {
                Label {
                    Text("Favorites")
                } icon: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
    }

    // MARK: - Active Trips

    @ViewBuilder
    func activeTripsSection(
        _ active: [Trip], captions: [PersistentIdentifier: MatchCaption], tipAnchorID: UUID?
    ) -> some View {
        if !active.isEmpty {
            Section {
                ForEach(active, id: \.persistentModelID) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        activeTripRow(trip, caption: captions[trip.persistentModelID])
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            tripToDelete = trip
                        }
                    }
                    .contextMenu { tripContextMenu(for: trip) }
                    .popoverTip(trip.id == tipAnchorID ? tripDiscoveryTip(for: trip) : nil)
                }
            } header: {
                Text("Currently Traveling")
            }
        }
    }

    /// An open trip's row with its temporary-home line, if the cache has one.
    private func activeTripRow(_ trip: Trip, caption: MatchCaption?) -> some View {
        ActiveTripRow(
            trip: trip,
            caption: caption,
            suggestion: cachedTemporaryHomeSuggestions[trip.id],
            onSetUp: { setUpTemporaryHome($0) },
            onNotNow: { dismissTemporaryHomeSuggestion($0) })
    }

    // MARK: - Completed Trips

    @ViewBuilder
    func completedTripsSection(
        _ completed: [Trip], captions: [PersistentIdentifier: MatchCaption], tipAnchorID: UUID?
    ) -> some View {
        // Show onboarding only for an empty store; unmatched queries use the search-empty state.
        if completed.isEmpty && !isProcessing && !isSearching && !displayHasAnyTrips {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No trips yet.")
                        .font(.subheadline.bold())
                    Text("Trips are created when you travel outside your home radius. Your daily commute and routine places are automatically excluded.\n\nKeep the app running in the background and trips will appear here as you travel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !completed.isEmpty {
            Section {
                ForEach(completed, id: \.persistentModelID) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        TripRow(trip: trip, caption: captions[trip.persistentModelID])
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            tripToDelete = trip
                        }
                    }
                    .contextMenu { tripContextMenu(for: trip) }
                    .popoverTip(trip.id == tipAnchorID ? tripDiscoveryTip(for: trip) : nil)
                }
            } header: {
                Text(completed.count == 1
                     ? String(localized: "trips.past-count.one", defaultValue: "Past Trips (\(completed.count, format: .number.grouping(.never)))", comment: "Past Trips section header when it contains one trip.")
                     : String(localized: "trips.past-count.other", defaultValue: "Past Trips (\(completed.count, format: .number.grouping(.never)))", comment: "Past Trips section header when it contains multiple trips."))
            } footer: {
                // Usage help is noise under search results.
                if trimmedQuery.isEmpty {
                    Text("Pull to refresh. Swipe to delete. Trips are assembled from stays outside your home and routine places.")
                }
            }
        }
    }

    // MARK: - Search Results

    /// Everything below the strong results while searching: similar
    /// matches, the AI fallback (only without strong or similar matches),
    /// partial matches, matches the filters hide, and the empty state.
    @ViewBuilder
    func searchResultSections(_ slices: TripSlices) -> some View {
        similarMatchesSection(slices)
        aiSuggestionsSection(slices)
        aiSearchingSection(slices)
        partialMatchesSection(slices)
        hiddenByFiltersSection(slices)
        emptySearchSection(slices)
    }

    /// A tappable correction above the results when the settled query has no strong match.
    @ViewBuilder
    func didYouMeanSection(_ slices: TripSlices) -> some View {
        // A matching Upcoming journey or temporary home is spelled right, whatever the dictionary says.
        if resultsCurrent(slices), visibleSearchedNonTripCount == 0, let suggestion = slices.spellingSuggestion {
            Section {
                Button {
                    applySpellingSuggestion(suggestion)
                } label: {
                    Label(
                        String(localized: "trips.search.did-you-mean", defaultValue: "Did you mean “\(suggestion)”?", comment: "Tappable trip search suggestion with a corrected spelling of the query; tapping searches for it instead."),
                        systemImage: "magnifyingglass")
                }
            }
        }
    }

    @ViewBuilder
    private func similarMatchesSection(_ slices: TripSlices) -> some View {
        if !slices.similar.isEmpty {
            Section {
                ForEach(slices.similar, id: \.persistentModelID) { trip in
                    searchMatchRow(trip, caption: slices.captions[trip.persistentModelID])
                }
            } header: {
                Text(String(localized: "trips.search.similar.header", defaultValue: "Similar matches", comment: "Trip search section header for trips that match a close spelling of the query or a place the user only passed through."))
            } footer: {
                Text(String(localized: "trips.search.similar.footer", defaultValue: "Close spellings and places you passed through.", comment: "Trip search footer explaining why the similar matches section appears."))
            }
        }
    }

    @ViewBuilder
    private func partialMatchesSection(_ slices: TripSlices) -> some View {
        if !slices.partial.isEmpty {
            Section {
                ForEach(slices.partial, id: \.persistentModelID) { trip in
                    searchMatchRow(trip, caption: slices.captions[trip.persistentModelID])
                }
            } header: {
                Text(String(localized: "trips.search.partial.header", defaultValue: "Matching some of your words", comment: "Trip search section header for trips that match only some words of a multi-word query."))
            }
        }
    }

    /// Similar and partial rows: the same row, actions and menu as the
    /// strong sections, without discovery tips.
    private func searchMatchRow(_ trip: Trip, caption: MatchCaption?) -> some View {
        NavigationLink {
            TripDetailView(trip: trip)
        } label: {
            if trip.isComplete {
                TripRow(trip: trip, caption: caption)
            } else {
                ActiveTripRow(trip: trip, caption: caption)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                tripToDelete = trip
            }
        }
        .contextMenu { tripContextMenu(for: trip) }
    }

    /// Matches the active filters hide for the settled query.
    private func hiddenByFiltersCount(_ slices: TripSlices) -> Int {
        guard !slices.query.isEmpty, resultsCurrent(slices) else { return 0 }
        return Self.hiddenByFiltersCount(
            preFilterCount: slices.preFilterCount, strictCount: slices.strictCount, filtersActive: filters.isActive)
    }

    /// Clears every filter (search text and sort stay), naming what it reveals.
    private func hiddenByFiltersButton(_ count: Int) -> some View {
        Button(count == 1
               ? String(localized: "trips.search.hidden-by-filters.one", defaultValue: "\(count, format: .number.grouping(.never)) more match outside your filters", comment: "Trip search button that clears the filters when they hide one more matching trip.")
               : String(localized: "trips.search.hidden-by-filters.other", defaultValue: "\(count, format: .number.grouping(.never)) more matches outside your filters", comment: "Trip search button that clears the filters when they hide multiple matching trips.")) {
            filters = TripFilters()
        }
    }

    /// Under the results; the empty card carries its own copy of the button.
    @ViewBuilder
    private func hiddenByFiltersSection(_ slices: TripSlices) -> some View {
        let hidden = hiddenByFiltersCount(slices)
        if hidden > 0 && !searchEmptyStateVisible(slices) {
            Section {
                hiddenByFiltersButton(hidden)
            }
        }
    }

    // MARK: - AI Search

    /// The AI fallback runs only when the settled query has no strong or
    /// similar match and no visible Upcoming or temporary-home match; partial rows do not block it.
    private func aiFallbackEligible(_ slices: TripSlices) -> Bool {
        searchFieldSettled && isSearching && resultsCurrent(slices) && slices.strictCount == 0
            && visibleSearchedNonTripCount == 0
    }

    /// Label AI suggestions explicitly; show only after local search returns no strong or similar matches.
    @ViewBuilder
    private func aiSuggestionsSection(_ slices: TripSlices) -> some View {
        if aiFallbackEligible(slices) {
            let suggestions = slices.aiSuggested
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.persistentModelID) { trip in
                        NavigationLink {
                            TripDetailView(trip: trip)
                        } label: {
                            TripRow(trip: trip)
                        }
                    }
                } header: {
                    Label("AI suggestions", systemImage: "sparkles")
                } footer: {
                    Text("These results are inferred from your query and may not be exact matches.")
                }
            }
        }
    }

    /// Covers the AI debounce too (`aiPending`), so no blank gap precedes the flight.
    @ViewBuilder
    private func aiSearchingSection(_ slices: TripSlices) -> some View {
        if aiFallbackEligible(slices) && (aiSearching || aiPending) {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching with AI…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Empty Search State

    @ViewBuilder
    func emptyFilterSection(_ slices: TripSlices) -> some View {
        if !isSearching && filters.isActive && slices.all.isEmpty && displayHasAnyTrips && !isProcessing {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "trips.filter-empty.title", defaultValue: "No trips match the current filters.", comment: "Trips list empty-state title when active filters exclude all trips without a search query."))
                        .font(.subheadline.bold())
                    Button(String(localized: "trip-filter.chip.clear-filters", defaultValue: "Clear filters", comment: "Button that clears all trip filters while preserving search text and sort order.")) {
                        filters = TripFilters()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Only once the field, the local search and the AI fallback have all
    /// settled on the same query and the field has been quiet for
    /// `emptyStateDelay`, so it never flashes between keystrokes.
    private func searchEmptyStateVisible(_ slices: TripSlices) -> Bool {
        Self.emptyStateCardVisible(
            query: trimmedQuery, revealedQuery: emptyStateQuery, fieldSettled: searchFieldSettled,
            resultsCurrent: resultsCurrent(slices), resultsEmpty: slices.all.isEmpty,
            hasAnyTrips: displayHasAnyTrips, journeysEmpty: visibleSearchedNonTripCount == 0,
            aiSettled: aiSettledWithNoResults(aiSuggested: slices.aiSuggested))
    }

    @ViewBuilder
    private func emptySearchSection(_ slices: TripSlices) -> some View {
        if searchEmptyStateVisible(slices) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if filters.isActive {
                        Text(String(localized: "trips.search-empty.filtered-title", defaultValue: "No trips match \"\(searchQuery)\" with the current filters.", comment: "Trip search empty-state title with the query when filters are active."))
                            .font(.subheadline.bold())
                    } else {
                        Text("No trips match \"\(searchQuery)\".")
                            .font(.subheadline.bold())
                    }
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if filters.isActive {
                        let hidden = hiddenByFiltersCount(slices)
                        if hidden > 0 {
                            hiddenByFiltersButton(hidden)
                                .buttonStyle(.bordered)
                        } else {
                            Button(String(localized: "trip-filter.chip.clear-filters", defaultValue: "Clear filters", comment: "Button that clears all trip filters while preserving search text and sort order.")) {
                                filters = TripFilters()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    /// Show no matches only after local search and AI settle; pending debounce must not flash an empty state.
    func aiSettledWithNoResults(aiSuggested: [Trip]) -> Bool {
        if aiSearching || aiPending { return false }
        if !aiSuggested.isEmpty { return false }
        // If AI is going to run for the current query but hasn't yet,
        // suppress the empty message until it settles.
        let willRunAI = trimmedQuery.count >= 3
        if willRunAI && lastAIQuery != trimmedQuery { return false }
        return true
    }

    private var emptyMessage: String {
        switch aiOutcome {
        case .failed:
            return String(localized: "trips.search-empty.ai-failed-hint", defaultValue: "AI search couldn't run right now. Check the spelling, or try a place, country, or year.", comment: "Trip search empty-state hint when the AI fallback search failed to run.")
        case .empty:
            return String(localized: "trips.search-empty.ai-empty-hint", defaultValue: "Nothing matched, even with AI. Check the spelling, or try a place, country, or year.", comment: "Trip search empty-state hint when the AI fallback search also found nothing.")
        case .success, .unavailable, nil:
            return String(localized: "trips.search-empty.hint", defaultValue: "Check the spelling, or try a place, country, or year.", comment: "Trip search empty-state hint when nothing matched the query.")
        }
    }
}
