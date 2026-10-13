//
//  TripsListView.swift
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

struct TripsListView: View {
    @Query(sort: \Trip.startDate, order: .reverse)
    var trips: [Trip]

    /// Calendar-detected upcoming trips (V14 future lane). The status is a
    /// hardcoded raw string because `#Predicate` inside a `@Query`
    /// initializer can't evaluate `PlannedTripStatus.upcoming.rawValue` —
    /// same pattern as the `DataSource.photoImport` dedup predicate.
    @Query(
        filter: #Predicate<PlannedTrip> { $0.statusRaw == "upcoming" },
        sort: \PlannedTrip.startDate
    )
    var upcomingPlannedTrips: [PlannedTrip]

    /// Home place names feed the journey chainer's return-leg detection
    /// ("Trip to Agios Dimitrios" at the end of an island hop is the ticket home,
    /// not a destination).
    @Query var homes: [Home]

    /// A temporary home that has not ended names a return leg like a Home
    /// (`PlannedTripChainer.storeInputs`). Read only by the journeys recompute.
    @Query var temporaryHomes: [TemporaryHome]

    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State var isProcessing = false
    @State var tripToDelete: Trip?
    @State var saveFailed = false
    /// Undo affordance for trip demotion: set after a "This Wasn't a Trip"
    /// apply; drives the undo alert. Apply silently, offer undo.
    @State var demotedTripName: String?
    /// The demoted trip's favourite, freed at demote so the rescue cannot
    /// resurrect the parked record; Undo pins it again.
    @State var demotedFavouriteID: UUID?
    /// Show when Undo has no token, including after relaunch.
    @State var undoUnavailable = false
    /// Show when Undo did not finish; its token and the favourite stay for a retry.
    @State var undoFailed = false

    /// Trip pushed programmatically by `applyPendingTripRoute()` (App
    /// Intents open-trip requests). Drives `navigationDestination(item:)`.
    @State private var routedTrip: Trip?

    /// App Intents search requests reveal the field with their query.
    @State private var searchFieldPresented = false
    @State var correctionTipLearned = DismissTripTip.hasLearnedCorrection
    @State var mergeSourceTrip: Trip?
    @State var mergeTargetTrip: Trip?

    // MARK: - Cached trips-derived state (perf)
    //
    // Cache heavy derivations behind debounced store generations and user inputs.
    // After the first recompute, body must avoid raw @Query reads that invalidate on unrelated saves.
    @State var cachedSlices = TripSlices()
    @State var cachedYears: [Int] = []
    @State var cachedCountries: [(code: String, count: Int)] = []
    @State var cachedHasAnyTrips = false
    /// False until the first slice recompute lands. While false the body reads
    /// the live `@Query` directly (so a cold first frame isn't blank); once true
    /// it renders only from the caches above (dropping the `trips` dependency).
    @State var hasLoadedSlices = false
    @State var cachedJourneys: [DisplayedJourney] = []
    @State var hasLoadedJourneys = false
    /// Advances when only the clock can change Upcoming: a leg ends or starts, the app activates, or the time or zone changes.
    @State var journeysClockTick = 0
    /// The Temporary Homes section's value cards, loaded off-main by their own task:
    /// the upcoming, active and recently ended ones (`TemporaryHomeCards.sections`).
    @State var cachedTemporaryHomeCards: [TemporaryHomeCards.Card] = []
    /// The cards that ended longer ago, shown below the trips.
    @State var cachedPastTemporaryHomeCards: [TemporaryHomeCards.Card] = []
    /// True while any card exists, ended ones included (their figures move
    /// with stays and trips too), or the cards' read failed: only then do
    /// stays and trips reload the cards, so a list without one observes neither for them.
    @State var temporaryHomeCardsFollowEvidence = false
    /// Advances at the earliest `nextReloadAt` among the cards: a start, an
    /// end or a hint threshold passes with no store write.
    @State var temporaryHomeCardsClockTick = 0
    /// The temporary homes the debounced query matches by label or place;
    /// `query` says which query they answer.
    @State var cachedSearchTemporaryHomeIDs: (query: String, ids: Set<UUID>) = ("", [])
    /// The temporary-home suggestion of each open trip, for its row's line.
    /// Rebuilt when the trips, the temporary homes or the clock change, never in a row body.
    @State var cachedTemporaryHomeSuggestions: [UUID: TemporaryHomeSuggestion.Candidate] = [:]
    /// Trips the suggestion asks about, or once asked about and the user
    /// answered Not Now: the "Not a trip?" tip never anchors on them.
    @State var cachedSuggestedTripIDs: Set<UUID> = []
    /// True while an open trip is near or past the suggestion's day threshold
    /// (`suggestionFollowsStays`): only then do stay changes rerun the suggestions.
    @State var temporaryHomeSuggestionFollowsStays = false
    /// The inputs the last suggestion pass read: a trigger over the same ones is skipped.
    @State var temporaryHomeSuggestionPassKey: SuggestionPassKey?
    /// The form "Set Up a Temporary Home…" opens, prefilled from the trip,
    /// and the one a card's Extend or End opens: owned here, so a reload
    /// that moves the card to another section keeps it.
    @State var temporaryHomeSheetMode: TemporaryHomeFormSheet.Mode?
    /// The local day and zone relative search dates read; refreshed on the same events.
    @State var searchClock = TripsListView.makeSearchClock()

    /// Count heuristic, non-user-edited trips during slice recompute without a body-level query dependency.
    @State var cachedHeuristicBacklog = 0

    /// True while the FM-upgrade card's "Enhance" action is running
    /// `reclassifyAll()`. Shows the card's inline progress state and blocks a
    /// second tap.
    @State var isEnhancing = false

    /// Device-local: the user tapped "Not Now" on the FM-upgrade card, or a
    /// successful enhance completed. One-shot — the card never returns once
    /// set (the permanent re-offer lives in Settings). Not iCloud-synced;
    /// dismissal is a per-device UI choice.
    @AppStorage("fmUpgradeCardDismissed_v1")
    var fmUpgradeCardDismissed = false

    /// Device-local sort preference; defaults to newest first.
    @AppStorage("tripsSortOrder")
    var sortOrderRaw: String = TripSortOrder.dateNewest.rawValue

    /// Type-safe accessor over `sortOrderRaw`. An unknown raw value (e.g.
    /// from a future build that added a case the current binary doesn't
    /// know about) falls back to the default rather than crashing.
    var sortOrder: TripSortOrder {
        TripSortOrder(rawValue: sortOrderRaw) ?? .dateNewest
    }

    /// Run photo-count prewarm only when the active sort or filter consumes counts.
    var needsPhotoCounts: Bool {
        sortOrder.usesPhotoCount || filters.requiresPhotos
    }

    @State var filters: TripFilters = TripFilters.loadFromDefaults()

    /// User's free-text search query. Empty = show all trips.
    @State var searchQuery: String = ""

    /// Outcome of the AI fallback for the most recently dispatched query.
    /// Nil means "no AI search has been issued for the current query".
    @State var aiOutcome: TripSearchAI.Outcome?

    /// True while an AI search is in flight — UI shows a progress row.
    @State var aiSearching: Bool = false

    /// True from the moment a flight is scheduled until it starts or is
    /// dropped, so the progress row covers the AI debounce instead of a blank.
    @State var aiPending: Bool = false

    /// A query the keyboard Search key submitted: its AI flight skips the debounce.
    @State private var aiImmediateQuery: String?

    /// Last result count posted to VoiceOver; nil once the field clears.
    @State private var lastAnnouncedResultCount: Int?

    /// Waits out `resultCountAnnouncementDelay` before announcing; a keystroke cancels it.
    @State private var announceTask: Task<Void, Never>?

    /// The trimmed field once it has been quiet for `emptyStateDelay`; the
    /// no-results card and its zero count wait for it. Nil while typing.
    @State var emptyStateQuery: String?

    /// Waits out `emptyStateDelay`; a keystroke cancels and restarts it.
    @State private var emptyStateTask: Task<Void, Never>?

    /// The `.trip` store token behind the query-independent caches (years,
    /// countries, emptiness, backlog), so a keystroke does not rebuild them.
    @State var derivedStoreToken: Int?
    /// The store token and first-page IDs last successfully prefetched.
    @State var lastPrefetchedTripToken: Int?
    @State var lastPrefetchedTripIDs: [UUID]?

    /// One "Did you mean" result per (query, index generation, language).
    @State var suggestionMemo: SuggestionMemo?

    /// The Upcoming journeys matching the debounced query, refiltered by the
    /// slice task before its AI decision; `query` says which query they answer.
    @State var cachedSearchJourneys: (query: String, journeys: [DisplayedJourney]) = ("", [])

    /// The query string the AI fallback was last fired for. Used to
    /// avoid re-running for the same query (e.g. when the user toggles
    /// off and back on the search field without typing).
    @State var lastAIQuery: String = ""

    /// Debounce AI fallback until the user pauses typing.
    @State var aiDebounceTask: Task<Void, Never>?

    /// Track the scheduled query to prevent duplicate AI calls during store/filter/sort recomputes.
    /// Pair with task cancellation so cancelled flights never block retries.
    @State var aiScheduledQuery = ""

    /// Monotonic ownership token for `aiSearching`: bumped at every flight
    /// launch; only the task holding the current value may write the flag.
    @State var aiSearchGeneration = 0

    /// Debounced query drives expensive fuzzy filtering and AI eligibility.
    @State var debouncedSearchQuery: String = ""

    /// Debounce task for `debouncedSearchQuery`. Cancelled/rescheduled per
    /// keystroke so the filter runs once the user pauses, not per character.
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Local search waits this long after the last keystroke; the index makes each pass cheap.
    static let localSearchDebounce: Duration = .milliseconds(100)

    /// The AI fallback waits longer, so a pause mid-word does not spend a model call.
    static let aiSearchDebounce: Duration = .milliseconds(500)

    /// The progress row waits this part of the AI debounce, so typing
    /// through a query with no match does not blink it on every keystroke.
    static let aiPendingDelay: Duration = .milliseconds(250)

    /// The no-results card gets the progress row's quiet period after the
    /// local debounce, so typing through a query with no match (or with no
    /// AI fallback to wait for) does not blink it on every keystroke.
    static let emptyStateDelay: Duration = localSearchDebounce + aiPendingDelay

    /// VoiceOver hears the result count once typing pauses, not per keystroke.
    static let resultCountAnnouncementDelay: Duration = .milliseconds(600)

    var body: some View {
        tripsListCore
        .background {
            TemporaryHomeSuggestionStayObserver(isActive: temporaryHomeSuggestionFollowsStays) {
                recomputeTemporaryHomeSuggestions()
            }
        }
        .task(id: journeysRecomputeKey) {
            // Read before the recompute's own clock, so no instant between the two is skipped.
            let now = Date.now
            recomputePlannedJourneys()
            // No store write marks a leg ending or a journey starting: sleep to the
            // next such instant, then advance the clock key to recompute.
            guard let boundary = Self.nextJourneyClockBoundary(
                legs: upcomingPlannedTrips.filter { !$0.isDeleted }
                    .map { (start: $0.startDate, currentUntil: $0.currentUntil()) },
                now: now) else { return }
            // One second past it: the leg filter keeps `currentUntil() >= now`
            // and supersession needs `journeyStart <= now`.
            do { try await Task.sleep(for: .seconds(boundary.timeIntervalSince(now) + 1)) } catch { return }
            journeysClockTick &+= 1
        }
        .task(id: temporaryHomeCardsRecomputeKey) {
            // Read before the load's own clock, so no instant between the two is skipped.
            let now = Date.now
            await recomputeTemporaryHomeCards()
            guard !Task.isCancelled else { return }
            // No store write marks a start, an end or a hint threshold passing:
            // sleep to the earliest one, then advance the cards' clock to reload.
            guard let boundary = Self.nextTemporaryHomeCardsReload(
                (cachedTemporaryHomeCards + cachedPastTemporaryHomeCards).map(\.nextReloadAt),
                now: now) else { return }
            // One second past it, as the journeys clock does.
            do { try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow) + 1)) } catch { return }
            temporaryHomeCardsClockTick &+= 1
        }
        .sheet(item: $temporaryHomeSheetMode) { mode in
            TemporaryHomeFormSheet(mode: mode)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            journeysClockTick &+= 1
            refreshSearchClock()
        }
        // UIKit posts it at local midnight (queued while the app is suspended).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            journeysClockTick &+= 1
            refreshSearchClock()
        }
        // All-day legs end at local midnight (`currentUntil(timeZone: .current)`).
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            journeysClockTick &+= 1
            refreshSearchClock()
        }
    }

    /// Split the modifier chain to stay within the Swift type-checker's budget.
    @ViewBuilder
    private var tripsListCore: some View {
        let slices = displaySlices
        // Discovery tips ("Not a trip?", merge) anchor on the first
        // non-favourite trip: a favourite is the user's own verdict that it
        // is a trip, so suggesting it might not be one reads as a mistake.
        // "Not a trip?" also skips a trip the temporary-home suggestion asks
        // about, answered or not: demoting a semester is the wrong fix.
        let skipsSuggested = !correctionTipLearned
        let tipAnchorID = [slices.active, slices.completed].lazy.joined()
            .first(where: { !$0.isDeleted && !($0.stays ?? []).isEmpty
                && !PinnedTripsStorage.shared.isPinned($0.id)
                && !(skipsSuggested && cachedSuggestedTripIDs.contains($0.id)) })?.id
        List {
            filterChipSection
            statusSection
            fmUpgradeSection
            didYouMeanSection(slices)
            plannedTripsSection
            temporaryHomesSection
            pinnedTripsSection(slices.pinned, captions: slices.captions, tipAnchorID: tipAnchorID)
            activeTripsSection(slices.active, captions: slices.captions, tipAnchorID: tipAnchorID)
            completedTripsSection(slices.completed, captions: slices.captions, tipAnchorID: tipAnchorID)
            pastTemporaryHomesSection
            emptyFilterSection(slices)
            searchResultSections(slices)
        }
        .navigationTitle("Trips")
        .task {
            for await status in DismissTripTip().statusUpdates {
                guard !Task.isCancelled else { return }
                if case .invalidated = status {
                    DismissTripTip.hasLearnedCorrection = true
                    correctionTipLearned = true
                }
            }
        }
        .searchable(
            text: $searchQuery,
            isPresented: $searchFieldPresented,
            prompt: Text("Search by name, country, city, or date")
        )
        .onSubmit(of: .search) {
            submitSearch()
        }
        // Cancel debounce and FM work when the list disappears.
        .onDisappear {
            aiDebounceTask?.cancel()
            searchDebounceTask?.cancel()
            announceTask?.cancel()
            // Clear the spinner here because cancelled tasks may exit before resetting it.
            aiSearching = false
            aiPending = false
        }
        .onAppear {
            // A retained list may return on a later day, after its observers were gone.
            refreshSearchClock()
            // Restart debounce on return to catch the last keystroke; flushing on disappearance would relaunch AI work.
            if debouncedSearchQuery != searchQuery {
                scheduleSearchDebounce()
            } else if !trimmedQuery.isEmpty, trimmedQuery != lastAIQuery {
                // Clear the cancelled flight's immediate state. The
                // reappearing slice task reruns AI eligibility after its
                // fresh local result lands.
                handleSearchQueryChanged()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            announceTask?.cancel()
            scheduleSearchDebounce()
            scheduleEmptyStateReveal()
        }
        .onChange(of: debouncedSearchQuery) { _, _ in
            handleSearchQueryChanged()
        }
        .onChange(of: filters) { _, new in
            new.saveToDefaults()
            aiDebounceTask?.cancel()
            aiOutcome = nil
            lastAIQuery = ""
            aiScheduledQuery = ""
            aiSearchGeneration += 1
            aiSearching = false
            aiPending = false
        }
        // Country routing preserves other filters; initial observation also handles cold-launch requests.
        .onChange(of: TripsTabRouter.shared.requestedCountryCode, initial: true) { _, _ in
            applyPendingCountryFilter()
        }
        // Initial trip-route observation handles intents delivered before the view installs its observer.
        .onChange(of: TripsTabRouter.shared.requestedTripID, initial: true) { _, _ in
            applyPendingTripRoute()
        }
        .onChange(of: TripsTabRouter.shared.requestedSearchQuery, initial: true) { _, _ in
            applyPendingSearchRequest()
        }
        .navigationDestination(item: $routedTrip) { trip in
            TripDetailView(trip: trip)
        }
        .task {
            await runFullPipeline()
        }
        // Observe the slice key instead of raw query updates.
        .task(id: slicesRecomputeKey) {
            let recomputedQuery = trimmedQuery
            // Upcoming and the temporary homes answer the query first, so the AI decision below sees them.
            refilterSearchedJourneys()
            refilterSearchedTemporaryHomes()
            // A large first index build runs off-main; the last settled
            // slices stay on screen meanwhile. A publish advances the store
            // generation in the key, which reruns this task.
            if recomputeTripSlices() {
                prefetchFirstPageIfNeeded()
            } else {
                await TripSearchIndexStore.shared.prepare(trips, container: modelContext.container)
                guard !Task.isCancelled else { return }
                if recomputeTripSlices() { prefetchFirstPageIfNeeded() }
            }
            // A superseded task must not schedule AI from an old local
            // result. Also wait for the raw field to settle onto the same
            // semantic query before treating this recompute as current.
            guard !Task.isCancelled,
                  recomputedQuery == trimmedQuery,
                  cachedSlices.query == recomputedQuery,
                  recomputedQuery == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            // Partial rows do not block the AI fallback (strong, similar and
            // a visible Upcoming or temporary-home match do).
            handleRecomputedSearch(
                query: recomputedQuery,
                localResultsEmpty: cachedSlices.strictCount == 0 && visibleSearchedNonTripCount == 0)
            scheduleResultCountAnnouncement()
        }
        // Warm the search index when the field activates, before the first keystroke.
        .task(id: searchFieldPresented) {
            guard searchFieldPresented else { return }
            // The parser lexicon and alias tables build off-main, so the
            // first query does not pay for them.
            let languageTag = AppLanguagePreference.currentTag()
            Task.detached(priority: .utility) {
                TripSearch.prewarmVocabulary(languageTag: languageTag)
                TripQueryParser.prewarm(languageTag: languageTag)
            }
            await TripSearchIndexStore.shared.prepare(trips, container: modelContext.container)
            guard !Task.isCancelled else { return }
            // UITextChecker is main-only; its first check loads the dictionaries.
            _ = Self.isKnownWord("trip", languageTag: languageTag)
        }
        // Prewarm only for photo-count consumers; include that mode in the task key so toggling it triggers work.
        // requiresPhotos keeps uncached trips visible until their counts arrive.
        .task(id: PhotoPrewarmKey(storeToken: StoreChangeTracker.shared.token(for: .trip), needsPhotoCounts: needsPhotoCounts, photoEpoch: PhotoService.shared.cacheInvalidationEpoch)) {
            guard needsPhotoCounts else { return }
            // `trips` is read INSIDE the task body (not in the `.task(id:)`
            // expression), so it does not re-register a body `@Query` dependency.
            await PhotoService.shared.prewarmPhotoCounts(for: trips)
        }
        .refreshable {
            await runFullPipeline()
        }
        .alert("Moved to Home Area", isPresented: Binding(
            get: { demotedTripName != nil },
            set: { if !$0 { demotedTripName = nil; demotedFavouriteID = nil } }
        )) {
            Button("Undo") {
                undoDemotion()
                demotedTripName = nil
            }
            Button("OK", role: .cancel) {
                demotedTripName = nil
                demotedFavouriteID = nil
            }
        } message: {
            Text("“\(demotedTripName ?? "")” is no longer a trip. Future visits there will count as home. Manage this under Settings › Home Area Places.")
        }
        .alert("Nothing to Undo", isPresented: $undoUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That correction can't be undone from here anymore. You can remove the taught place under Settings › Home Area Places, and the trip will be rebuilt.")
        }
        // A failed Undo keeps its token and the trip's Removed Trips record, photo choices included, so offer it again.
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $undoFailed
        ) {
            Button("Undo") { undoDemotion() }
            Button("OK", role: .cancel) { demotedFavouriteID = nil }
        }
        .alert("Delete Trip?", isPresented: Binding(
            get: { tripToDelete != nil },
            set: { if !$0 { tripToDelete = nil } }
        )) {
            // Full cascade and trip-only removal are permanent and sync; trip-only removal preserves raw history.
            Button("Delete Trip & Location History", role: .destructive) {
                // Remote deletion can invalidate the alert’s model; isDeleted is the only safe read then.
                if let trip = tripToDelete, !trip.isDeleted {
                    performDelete(trip)
                }
                tripToDelete = nil
            }
            Button("Remove Trip, Keep Map History", role: .destructive) {
                if let trip = tripToDelete, !trip.isDeleted {
                    performRemoveKeepData(trip)
                }
                tripToDelete = nil
            }
            Button("Cancel", role: .cancel) { tripToDelete = nil }
        } message: {
            if let trip = tripToDelete, !trip.isDeleted {
                let stayCount = trip.stays?.count ?? 0
                let pingCount = (trip.stays ?? []).reduce(0) { $0 + $1.pingCount }
                if stayCount == 1 {
                    Text(pingCount == 1
                         ? String(localized: "trips.delete-detail.stay-one.ping.one", defaultValue: "Deleting everything permanently removes this trip, its \(stayCount, format: .number.grouping(.never)) stay and \(pingCount, format: .number.grouping(.never)) location ping, its hidden/pinned photo choices, and clears map hexes with no other visits. Stats and Passport lose this evidence too. Keeping map history removes only the trip entry; the places stay on your exploration map but won't become a trip again. Photos in your library are never affected. Neither can be undone, and both apply on all your devices. If this outing was ordinary life rather than a trip, \"This Wasn't a Trip\" teaches the app instead.", comment: "Trip deletion explanation for one stay and one location ping.")
                         : String(localized: "trips.delete-detail.stay-one.ping.other", defaultValue: "Deleting everything permanently removes this trip, its \(stayCount, format: .number.grouping(.never)) stay and \(pingCount, format: .number.grouping(.never)) location pings, its hidden/pinned photo choices, and clears map hexes with no other visits. Stats and Passport lose this evidence too. Keeping map history removes only the trip entry; the places stay on your exploration map but won't become a trip again. Photos in your library are never affected. Neither can be undone, and both apply on all your devices. If this outing was ordinary life rather than a trip, \"This Wasn't a Trip\" teaches the app instead.", comment: "Trip deletion explanation for one stay and multiple location pings."))
                } else {
                    Text(pingCount == 1
                         ? String(localized: "trips.delete-detail.stay-other.ping.one", defaultValue: "Deleting everything permanently removes this trip, its \(stayCount, format: .number.grouping(.never)) stays and \(pingCount, format: .number.grouping(.never)) location ping, its hidden/pinned photo choices, and clears map hexes with no other visits. Stats and Passport lose this evidence too. Keeping map history removes only the trip entry; the places stay on your exploration map but won't become a trip again. Photos in your library are never affected. Neither can be undone, and both apply on all your devices. If this outing was ordinary life rather than a trip, \"This Wasn't a Trip\" teaches the app instead.", comment: "Trip deletion explanation for multiple stays and one location ping.")
                         : String(localized: "trips.delete-detail.stay-other.ping.other", defaultValue: "Deleting everything permanently removes this trip, its \(stayCount, format: .number.grouping(.never)) stays and \(pingCount, format: .number.grouping(.never)) location pings, its hidden/pinned photo choices, and clears map hexes with no other visits. Stats and Passport lose this evidence too. Keeping map history removes only the trip entry; the places stay on your exploration map but won't become a trip again. Photos in your library are never affected. Neither can be undone, and both apply on all your devices. If this outing was ordinary life rather than a trip, \"This Wasn't a Trip\" teaches the app instead.", comment: "Trip deletion explanation for multiple stays and multiple location pings."))
                }
            } else {
                Text("Permanently removes this trip and its underlying location data.")
            }
        }
        .alert("Merge Trips?", isPresented: Binding(
            get: { mergeSourceTrip != nil && mergeTargetTrip != nil },
            set: { if !$0 { mergeSourceTrip = nil; mergeTargetTrip = nil } }
        )) {
            Button("Merge", role: .destructive) {
                // Check model liveness as in the Delete alert.
                if let source = mergeSourceTrip, let target = mergeTargetTrip,
                   !source.isDeleted, !target.isDeleted {
                    performMerge(source: source, into: target)
                }
                mergeSourceTrip = nil
                mergeTargetTrip = nil
            }
            Button("Cancel", role: .cancel) {
                mergeSourceTrip = nil
                mergeTargetTrip = nil
            }
        } message: {
            if let source = mergeSourceTrip, let target = mergeTargetTrip,
               !source.isDeleted, !target.isDeleted {
                Text("Stays from \"\(source.displayName)\" will be merged into \"\(target.displayName)\".")
            } else {
                Text("Stays from one trip will be merged into the other.")
            }
        }
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $saveFailed
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Debounce heavy search and AI eligibility; clearing the field updates immediately.
    @MainActor
    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debouncedSearchQuery = searchQuery
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.localSearchDebounce)
            if Task.isCancelled { return }
            debouncedSearchQuery = searchQuery
        }
    }

    /// Restarts the empty card's quiet period on every keystroke. Not
    /// cancelled on disappear, so a pause that began before a tab switch
    /// still reveals the card on return.
    @MainActor
    private func scheduleEmptyStateReveal() {
        emptyStateTask?.cancel()
        emptyStateQuery = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyStateTask = Task { @MainActor in
            try? await Task.sleep(for: Self.emptyStateDelay)
            if Task.isCancelled { return }
            emptyStateQuery = query
        }
    }

    /// Keyboard Search key: settle the local search now and let an eligible
    /// AI fallback start without its debounce.
    @MainActor
    private func submitSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        aiImmediateQuery = query
        // The Search key ends typing: no quiet period for the empty card.
        emptyStateTask?.cancel()
        emptyStateQuery = query
        searchDebounceTask?.cancel()
        if debouncedSearchQuery != searchQuery {
            // The slice recompute for it schedules AI and consumes the flag.
            debouncedSearchQuery = searchQuery
        } else if !aiSearching, query == aiScheduledQuery, query != lastAIQuery,
                  aiDebounceTask?.isCancelled == false, query == trimmedQuery, cachedSlices.query == query {
            // A flight is waiting out its debounce (its progress row may not
            // show yet): start it now instead.
            aiDebounceTask?.cancel()
            aiPending = false
            handleRecomputedSearch(
                query: query, localResultsEmpty: cachedSlices.strictCount == 0 && visibleSearchedNonTripCount == 0)
        } else {
            aiImmediateQuery = nil
        }
    }

    /// Search for the tapped correction at once.
    @MainActor
    func applySpellingSuggestion(_ suggestion: String) {
        searchQuery = suggestion
        searchDebounceTask?.cancel()
        debouncedSearchQuery = suggestion
    }

    /// Announces once typing pauses; the function re-checks settledness.
    @MainActor
    private func scheduleResultCountAnnouncement() {
        announceTask?.cancel()
        announceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resultCountAnnouncementDelay)
            if Task.isCancelled { return }
            announceResultCountIfNeeded()
        }
    }

    /// Posts one VoiceOver announcement when a settled query's visible
    /// result count changes. Zero waits for the AI fallback to settle.
    @MainActor
    private func announceResultCountIfNeeded() {
        let query = trimmedQuery
        guard !query.isEmpty else {
            lastAnnouncedResultCount = nil
            return
        }
        let slices = cachedSlices
        guard searchFieldSettled, slices.query == query, !aiPending, !aiSearching else { return }
        let count = Self.searchResultCount(
            visibleTrips: slices.all.count, strictCount: slices.strictCount,
            aiSuggested: slices.aiSuggested.count, visibleJourneys: visibleSearchedNonTripCount)
        // Zero also waits for the empty card's quiet period.
        if count == 0, emptyStateQuery != query || !aiSettledWithNoResults(aiSuggested: slices.aiSuggested) { return }
        guard count != lastAnnouncedResultCount else { return }
        lastAnnouncedResultCount = count
        AccessibilityNotification.Announcement(Self.resultCountAnnouncement(count)).post()
    }

    @MainActor
    private func handleSearchQueryChanged() {
        aiDebounceTask?.cancel()
        aiPending = false
        if aiImmediateQuery != trimmedQuery { aiImmediateQuery = nil }

        // Clear results that referred to a stale query — important so
        // the suggestions section doesn't briefly show last query's
        // results next to the new query's local matches.
        if trimmedQuery != lastAIQuery {
            aiOutcome = nil
            lastAIQuery = ""
            aiScheduledQuery = ""
        }

        // Clearing the field resets the AI state immediately. Eligibility
        // for non-empty queries runs only after the matching local slice
        // recompute has completed.
        guard !trimmedQuery.isEmpty else {
            aiSearching = false
            lastAIQuery = ""
            lastAnnouncedResultCount = nil
            return
        }
    }

    /// Schedule a debounced AI fallback from a completed local recompute.
    /// `localResultsEmpty` is that recompute's result, so this gate never
    /// re-enters the local search pipeline.
    @MainActor
    private func handleRecomputedSearch(query: String, localResultsEmpty: Bool) {
        guard query == trimmedQuery else { return }
        let immediate = aiImmediateQuery == query
        if immediate { aiImmediateQuery = nil }
        switch Self.aiFallbackStep(query: query, localResultsEmpty: localResultsEmpty, lastAIQuery: lastAIQuery) {
        case .clear:
            // Local hits or a short query make any pending fallback moot —
            // cancel it, don't just hide the spinner (an orphaned flight
            // would still commit, and a superseded one never clears it).
            aiDebounceTask?.cancel()
            aiSearching = false
            aiPending = false
            return
        case .keep:
            return
        case .schedule:
            break
        }
        // Single flight per settled query: a recompute caused by store /
        // filter / sort churn while this query's call is pending or running
        // must not relaunch it (see `aiScheduledQuery`).
        if query == aiScheduledQuery, aiDebounceTask?.isCancelled == false { return }

        let queryToSearch = query

        // Check FM capability before showing the spinner; record unavailable as settled so empty-state copy can appear.
        guard FMCapability.current == .available,
              FMLanguagePolicy.searchFMAllowed(
                supportsLocale: { _ in FMCapability.supportsCurrentLocale() }
              ) else {
            aiOutcome = .unavailable
            lastAIQuery = queryToSearch
            aiSearching = false
            aiPending = false
            return
        }

        // Candidates are scoped by the active filters before the tool's 40-match cap; when no live trip
        // survives the filters there is nothing to search, so settle as empty without a debounce or spinner.
        if filters.isActive,
           filters.apply(to: trips.filter { !$0.isDeleted }, photoService: PhotoService.shared).isEmpty {
            aiOutcome = .empty
            lastAIQuery = queryToSearch
            aiSearching = false
            aiPending = false
            return
        }

        aiDebounceTask?.cancel()
        aiScheduledQuery = queryToSearch
        aiSearchGeneration += 1
        let generation = aiSearchGeneration
        // FM is available, the query has 3+ characters and the field has
        // settled on it: the progress row covers the debounce, at once for
        // the Search key, otherwise after `aiPendingDelay` so it never
        // blinks between keystrokes.
        if immediate { aiPending = true }
        aiDebounceTask = Task {
            // Debounce: wait long enough for the user to stop typing, unless
            // the Search key submitted this query.
            if !immediate {
                try? await Task.sleep(for: Self.aiPendingDelay)
                if Task.isCancelled { return }
                await MainActor.run {
                    if generation == aiSearchGeneration, queryToSearch == trimmedQuery { aiPending = true }
                }
                try? await Task.sleep(for: Self.aiSearchDebounce - Self.aiPendingDelay)
            }
            if Task.isCancelled { return }
            // Snapshot live models on MainActor after debounce; filter isDeleted before all other reads.
            // Only Sendable values cross into TripSearchAI.
            let tripSnapshots = await MainActor.run {
                Self.aiCandidateSnapshots(trips: trips, filters: filters, photoService: PhotoService.shared)
            }
            if Task.isCancelled { return }
            let shouldSearch = await MainActor.run {
                guard generation == aiSearchGeneration else { return false }
                guard queryToSearch == trimmedQuery else {
                    aiPending = false
                    return false
                }
                // Trips deleted during the debounce can empty the scoped candidates; nothing to search then.
                guard !tripSnapshots.isEmpty else {
                    aiOutcome = .empty
                    lastAIQuery = queryToSearch
                    aiSearching = false
                    aiPending = false
                    announceResultCountIfNeeded()
                    return false
                }
                // Generation-gated: a cancelled predecessor's late exit must
                // not flip the spinner owned by its replacement (cancellation
                // is cooperative — the FM call can outlive the cancel).
                aiSearching = true
                aiPending = false
                return true
            }
            guard shouldSearch else { return }
            let outcome = await TripSearchAI.search(query: queryToSearch, snapshots: tripSnapshots)
            if Task.isCancelled {
                // Cancellation can arrive after the debounce check; only the owning flight may clear its spinner.
                await MainActor.run {
                    if generation == aiSearchGeneration { aiSearching = false }
                }
                return
            }
            await MainActor.run {
                // Commit lastAIQuery atomically with the outcome only while the query still matches.
                // Cancelled flights must leave no committed query that could block a retry.
                if queryToSearch == trimmedQuery, generation == aiSearchGeneration {
                    aiOutcome = outcome
                    lastAIQuery = queryToSearch
                }
                if generation == aiSearchGeneration {
                    aiSearching = false
                    // Success recomputes the slices, which announce the count themselves.
                    if case .success = outcome {} else { announceResultCountIfNeeded() }
                }
            }
        }
    }

    /// The next instant Upcoming can change with no store write: a leg's
    /// `currentUntil()` (it leaves the list) or a leg's start (a started journey
    /// hides behind an ongoing trip and its card says "now"). Nil when none is ahead.
    nonisolated static func nextJourneyClockBoundary(
        legs: [(start: Date, currentUntil: Date)], now: Date
    ) -> Date? {
        legs.flatMap { [$0.start, $0.currentUntil] }.filter { $0 > now }.min()
    }

    /// The next instant a card changes with no store write (each card's
    /// `nextReloadAt`), or nil when none is ahead of `now`.
    nonisolated static func nextTemporaryHomeCardsReload(_ reloadAts: [Date?], now: Date) -> Date? {
        reloadAts.compactMap { $0 }.filter { $0 > now }.min()
    }

    /// Inclusive civil-day count for an ongoing trip, shared with the widget's
    /// rule: departure stay zone at the start, latest stay zone now, capped by
    /// the same 3,651-day work bound as Stats.
    nonisolated static func ongoingDisplayDay(for trip: Trip, now: Date) -> Int {
        let stays = trip.stays ?? []
        let first = stays.min {
            $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
        }
        let last = stays.max {
            $0.endTime == $1.endTime ? $0.id.uuidString > $1.id.uuidString : $0.endTime < $1.endTime
        }
        return max(1, min(3_651, Trip.inclusiveDays(
            from: trip.startDate, in: StayTimeZone.resolve(first?.timeZoneIdentifier),
            to: now, in: StayTimeZone.resolve(last?.timeZoneIdentifier))))
    }

    /// Shortest time the processing banner stays visible once shown, so a
    /// brief pass cannot flash a row into and out of the list.
    private static let minimumProcessingBannerDuration: Duration = .milliseconds(750)

    /// Count pending work only as a banner hint; this must never gate the pipeline itself.
    private func pipelineHasVisibleWork() async -> Bool {
        if await AppDelegate.tripClassifier.baselinePassPending() { return true }
        let pendingPings = (try? modelContext.fetchCount(FetchDescriptor<LocationPing>(
            predicate: #Predicate { $0.isProcessed == false }))) ?? 0
        if pendingPings > 0 { return true }
        let pendingVisits = (try? modelContext.fetchCount(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.isProcessed == false }))) ?? 0
        if pendingVisits > 0 { return true }
        let unclassified = (try? modelContext.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }))) ?? 0
        return unclassified > 0
    }

    private func runFullPipeline() async {
        let showBanner = await pipelineHasVisibleWork()
        let shownAt = ContinuousClock.now
        if showBanner { withAnimation { isProcessing = true } }

        // Serialize store writes with background geocoding and other view pipelines through PipelineGate.
        let pendingLocalities = await PipelineGate.shared.runReturning(touching: []) {
            // Layer 2: Cluster any new pings into stays
            let clustering = await AppDelegate.stayClusterer.clusterUnprocessedPingsReportingChanges()

            // Layer 2.5: Infer transit modes for recent stays (foreground-only;
            // CoreMotion background queries are unreliable per Apple DTS).
            // Runs BEFORE classification because transit modes are signal for
            // TripClassifier's sanity checks (e.g., flight → previous stay
            // is transit-or-departure).
            let transit = await AppDelegate.transitInferer.inferTransitForRecentStaysReportingChanges()

            // Publish before releasing this gate unit, including partial work
            // retained across cancellation or a failed later save. Counts of
            // newly-created rows miss extensions and category-only changes.
            if clustering.needsPublication || transit.needsPublication {
                await StoreChangeTracker.shared.bump([.stay, .trip, .locationPing, .visit])
            }
            return clustering.pendingLocalities
        }
        await AppDelegate.stayClusterer.enrichPendingLocalities(pendingLocalities)

        _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates()

        _ = await AppDelegate.tripClassifier.generateTitlesStage(
            maxTripsPerCall: 5)
        _ = await AppDelegate.tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: 5)

        if showBanner {
            let elapsed = ContinuousClock.now - shownAt
            if elapsed < Self.minimumProcessingBannerDuration {
                try? await Task.sleep(for: Self.minimumProcessingBannerDuration - elapsed)
            }
            withAnimation { isProcessing = false }
        }
    }

    /// Consume the country route once, replacing only country filters and preserving all other dimensions.
    private func applyPendingCountryFilter() {
        guard let code = TripsTabRouter.shared.requestedCountryCode else { return }
        var updated = filters
        updated.countryCodes = [code]
        filters = updated   // triggers the persist `.onChange` above
        // A Stats country tap asks for that country, not the old query within it.
        searchQuery = ""
        TripsTabRouter.shared.clear()
    }

    /// Resolve the routed trip ID; stale IDs silently leave the user on the Trips tab.
    private func applyPendingTripRoute() {
        guard let id = TripsTabRouter.shared.requestedTripID else { return }
        TripsTabRouter.shared.clearTripRequest()
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let trip = try? modelContext.fetch(descriptor).first else { return }
        routedTrip = trip
    }

    /// Consume `TripsTabRouter.shared.requestedSearchQuery` if non-nil:
    /// reveal the search field pre-filled with the requested query. The
    /// `searchQuery` `.onChange` observer takes it from there through the
    /// normal debounce pipeline.
    private func applyPendingSearchRequest() {
        guard let query = TripsTabRouter.shared.requestedSearchQuery else { return }
        TripsTabRouter.shared.clearSearchRequest()
        searchQuery = query
        searchFieldPresented = true
    }
}

