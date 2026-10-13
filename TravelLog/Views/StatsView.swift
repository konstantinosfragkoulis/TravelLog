//
//  StatsView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import WidgetKit
import os.log

private let logger = Logger(subsystem: "com.travellog.app", category: "StatsView")

nonisolated struct StatsRefreshIdentity: Equatable, Sendable {
    let storeToken: Int
    let day: DateComponents
    let calendar: Calendar

    init(storeToken: Int, now: Date, timeZone: TimeZone = .current, calendar: Calendar = .current) {
        self.storeToken = storeToken
        // Gregorian is only a stable civil-day invalidation key, not the
        // calendar used to select memories. Keep the local date components:
        // zones 24 hours apart can share a midnight instant on different dates.
        var snapshot = calendar
        snapshot.timeZone = timeZone
        self.calendar = snapshot
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        day = gregorian.dateComponents([.year, .month, .day], from: now)
    }

    func needsRefresh(comparedTo completed: Self?) -> Bool {
        self != completed
    }
}

/// What one Stats refresh does with a fresh compute.
nonisolated enum StatsRefreshDecision: Equatable, Sendable {
    /// Complete aggregates and no owed pending-edit save: apply, mark the
    /// token current and persist the snapshot.
    case applyAndMarkCurrent
    /// Complete committed aggregates while a pending-edit save still failed:
    /// apply, but keep the token unfinished, persist nothing and retry.
    case applyAndRetry
    /// A degraded read, cold page or not: keep what is on screen (the last
    /// complete aggregates, or zero placeholders with sharing off) and retry.
    case rejectAndRetry

    init(computeDegraded: Bool?, pendingSaveOwed: Bool) {
        if computeDegraded == true {
            self = .rejectAndRetry
        } else if pendingSaveOwed {
            self = .applyAndRetry
        } else {
            self = .applyAndMarkCurrent
        }
    }
}

/// The acceptance bookkeeping one Stats page keeps across refreshes:
/// the identity last computed completely, and the
/// snapshot-clear generation of the complete aggregates on screen. A clear
/// that moves the generation revokes both, before any up-to-date fast path,
/// so neither a completed identity nor a pre-clear result keeps deleted
/// totals on screen or shareable.
nonisolated struct StatsRefreshLedger: Equatable, Sendable {
    /// Identity of the last complete, current computation; nil while unfinished.
    private(set) var lastCompleted: StatsRefreshIdentity?
    /// Snapshot-clear generation of the complete aggregates on screen; nil
    /// while the page is cold. Only these may be shared.
    private(set) var acceptedGeneration: Int?

    nonisolated enum Start: Equatable, Sendable {
        /// This identity was computed completely at the current generation.
        case upToDate
        /// Compute. `revoked`: return to the cold page first.
        case refresh(revoked: Bool)
    }

    nonisolated enum Conclusion: Equatable, Sendable {
        /// The store generations or civil day moved mid-compute; the
        /// restarted refresh owns the new identity. Discard.
        case superseded
        /// A clear landed mid-compute: the result describes the pre-clear
        /// store. Discard it, return to the cold page when `revoked`, and
        /// compute again.
        case clearedDuringCompute(revoked: Bool)
        /// A current result; the decision says what the page does with it.
        case decided(StatsRefreshDecision)

        /// Whether the refresh stays unfinished and must run again.
        var needsRetry: Bool {
            switch self {
            case .superseded, .decided(.applyAndMarkCurrent): false
            case .clearedDuringCompute, .decided(.applyAndRetry), .decided(.rejectAndRetry): true
            }
        }
    }

    /// No complete aggregates have been accepted and nothing is current.
    var isCold: Bool { lastCompleted == nil && acceptedGeneration == nil }

    func hasCompleteAggregates(currentGeneration: Int) -> Bool {
        acceptedGeneration != nil && acceptedGeneration == currentGeneration
    }

    /// A clear since acceptance revokes the aggregates and the completed
    /// identity. Returns true when the caller must show the cold page.
    mutating func revokeIfCleared(currentGeneration: Int) -> Bool {
        guard let accepted = acceptedGeneration, accepted != currentGeneration else { return false }
        acceptedGeneration = nil
        lastCompleted = nil
        return true
    }

    /// Revocation first, then the fast path: a revoked identity is never
    /// up to date.
    mutating func begin(_ token: StatsRefreshIdentity, currentGeneration: Int) -> Start {
        let revoked = revokeIfCleared(currentGeneration: currentGeneration)
        guard token.needsRefresh(comparedTo: lastCompleted) else { return .upToDate }
        return .refresh(revoked: revoked)
    }

    /// Complete aggregates of `generation` (a cold-launch snapshot) are on screen.
    mutating func acceptHydrated(generation: Int) {
        acceptedGeneration = generation
    }

    /// Judge a finished compute of `token` that captured `generation` before
    /// reading. A generation change wins over an identity change, so the
    /// displayed aggregates are revoked even when the store also moved.
    mutating func conclude(
        _ token: StatsRefreshIdentity,
        computedAt generation: Int,
        currentToken: StatsRefreshIdentity,
        currentGeneration: Int,
        computeDegraded: Bool?,
        pendingSaveOwed: Bool
    ) -> Conclusion {
        guard generation == currentGeneration else {
            return .clearedDuringCompute(revoked: revokeIfCleared(currentGeneration: currentGeneration))
        }
        guard token == currentToken else { return .superseded }
        let decision = StatsRefreshDecision(computeDegraded: computeDegraded, pendingSaveOwed: pendingSaveOwed)
        switch decision {
        case .rejectAndRetry:
            break
        case .applyAndRetry:
            acceptedGeneration = generation
        case .applyAndMarkCurrent:
            acceptedGeneration = generation
            lastCompleted = token
        }
        return .decided(decision)
    }
}

/// `.task(id:)` key of the Stats refresh: the refresh identity plus the
/// observed snapshot-clear generation, so a clear restarts the refresh even
/// when no store type Stats renders changed.
nonisolated struct StatsRefreshTaskKey: Equatable, Sendable {
    let identity: StatsRefreshIdentity
    let clearGeneration: Int
}

/// Aggregate statistics dashboard.
///
/// Order, top to bottom: On This Day banner (when a memory exists), the
/// Passport card, the globe, the per-year chart, countries, records, the
/// hex exploration card, collections, and a tracking-since footer. Every
/// number is a formatted read of the epoch-cached `StatsAggregator`
/// aggregates; the body computes nothing.
struct StatsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    // Lightweight counts - computed via fetchCount() instead of loading all objects.
    @State private var totalPings = 0
    @State private var totalStays = 0
    @State private var totalHexes = 0
    @State private var totalTrips = 0
    @State private var trackingSince: Date?

    // Exploration metrics — computed by `StatsAggregator` from one HexVisit
    // fetch (row counts are map-scale: hundreds, not thousands).
    @State private var newHexesThisYear = 0
    @State private var topHexCountries: [StatsAggregator.HexCountry] = []

    /// Past-year memories for today's date; empty hides the banner.
    @State private var onThisDayGroups: [OnThisDayYearGroup] = []

    /// Pre-TravelLog countries (KVS-synced checklist — see
    /// `RememberedCountriesStorage`). Counts toward the passport and the
    /// globe; never creates trips/stays/hexes.
    private let rememberedCountries = RememberedCountriesStorage.shared
    @State private var showEarlierTravelsPicker = false

    // **Epoch-cached aggregates**: rebuilt off-main by `StatsAggregator`
    // once per relevant `StoreChangeTracker` bump (the `statsChanges`
    // types), so saves elsewhere never rerun the reductions while Stats
    // sits installed in the TabView; the body just formats them.
    @State private var cachedPassportData = PassportData()
    @State private var cachedUniqueCountries: Set<String> = []
    @State private var cachedCountryStats: [CountryStat] = []
    @State private var cachedLastTrip: StatsAggregator.LastTrip?
    /// Airports / flight log / Places — computed by the same off-main pass
    /// (`CollectionsAggregator` inside `StatsAggregator.aggregate`).
    @State private var cachedCollections = CollectionsAggregator.Collections()
    /// Pinned "% of home explored" rows (countries hosting an active Home).
    @State private var cachedHomeHexCountries: [StatsAggregator.HexCountry] = []
    /// Distinct trip days — nil until a compute (or a post-upgrade snapshot)
    /// that carries them lands, which hides the Highlights row.
    @State private var cachedTravelDaysThisYear: Int?
    @State private var cachedTravelDaysTotal: Int?
    /// Per-year ledger for the "By Year" card; empty hides the card.
    @State private var cachedYearStats: [StatsAggregator.YearStat] = []
    /// Month of the year (1…12) with the most travel days, and that count.
    @State private var cachedFavoriteMonth: Int?
    @State private var cachedFavoriteMonthDays: Int?

    /// The store types Stats actually renders. A calendar scan (`.plannedTrip`),
    /// photo-import-state churn, or a Wrapped write no longer restarts the
    /// aggregate rebuild — only these do.
    /// `.home`: the pinned "% of home explored" row and the country rows'
    /// `isHome` badge both derive from the active Home, which otherwise only
    /// changes on a move. `.temporaryHome`: days away and the country rows'
    /// caption derive from temporary homes.
    private static let statsChanges: StoreChange = [.stay, .trip, .hexVisit, .locationPing, .home, .temporaryHome]

    /// The last completed identity (store generations and civil day) and the
    /// snapshot-clear generation of the complete aggregates on screen.
    /// Re-entering on that same day with unchanged data skips the rebuild;
    /// only accepted aggregates may be shared, and a deletion that moves the
    /// generation revokes them.
    @State private var ledger = StatsRefreshLedger()
    @State private var refreshDate = Date.now
    /// Latest snapshot-clear generation seen by `observeSnapshotClears`. Part
    /// of the refresh task key, so a clear restarts the refresh.
    @State private var observedClearGeneration = StatsSnapshotStore.clearGeneration
    /// Pending main-context edits were observed and their save has not been
    /// published yet. Survives failed or cancelled flushes and task restarts,
    /// so an autosave that commits them meanwhile is still published once.
    @State private var pendingEditPublicationOwed = false

    private var hasCompleteAggregates: Bool {
        ledger.hasCompleteAggregates(currentGeneration: StatsSnapshotStore.clearGeneration)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !onThisDayGroups.isEmpty {
                    OnThisDayBanner(groups: onThisDayGroups)
                }
                PassportCardView(data: passportDataForDisplay, canShare: hasCompleteAggregates)
                heroSection
                if !cachedYearStats.isEmpty {
                    StatsYearCard(years: cachedYearStats)
                }
                countriesSection
                recordsSection
                explorationSection
                collectionsSection
                footer
            }
            .padding()
        }
        .navigationTitle("Stats")
        // Observe only relevant generations, the civil day and snapshot
        // clears. Clock events update the date input; same-day appearances
        // keep the task ID equal.
        .task(id: StatsRefreshTaskKey(
            identity: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: Self.statsChanges), now: refreshDate),
            clearGeneration: observedClearGeneration
        )) {
            // A degraded read, a failed pending-edit save or a clear
            // mid-compute consumes no token, and nothing else reruns this
            // task while the page stays up on an idle store: retry it.
            var delay: Duration = .seconds(2)
            while await refreshAllStats() {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                delay = min(delay * 2, .seconds(60))
            }
        }
        .onAppear { refreshDate = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshDate = .now
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            refreshDate = .now
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshDate = .now }
        }
        .task {
            await observeSnapshotClears()
        }
        .task {
            await backfillHomeLocalities()
        }
    }

    /// A snapshot clear (Delete All Data, Delete Calendar Data, a calendar
    /// title wipe, a photo-import discard) revokes the aggregates on screen
    /// at once, even when it touched no store type Stats observes, and the
    /// changed task key recomputes them. Re-reads on every appearance, since
    /// a clear while the page was away posted to nobody.
    private func observeSnapshotClears() async {
        let clears = NotificationCenter.default.notifications(named: .statsSnapshotCleared)
        adoptSnapshotClearGeneration()
        for await _ in clears {
            adoptSnapshotClearGeneration()
        }
    }

    private func adoptSnapshotClearGeneration() {
        let generation = StatsSnapshotStore.clearGeneration
        if ledger.revokeIfCleared(currentGeneration: generation) { showColdPage() }
        if observedClearGeneration != generation { observedClearGeneration = generation }
    }

    /// Rebuild off-main when relevant store generations or the civil day change. Re-appearance
    /// reuses a completed snapshot or retries an unfinished refresh. Pending
    /// main-context edits are saved before the worker reads committed state.
    /// Returns true when this refresh is unfinished: a degraded read, a
    /// pending-edit save that failed, or a snapshot clear mid-compute.
    private func refreshAllStats() async -> Bool {
        // Skip only a completed refresh for the same store generations AND
        // civil day. A first or unfinished refresh always remains retryable.
        let now = Date.now
        let token = StatsRefreshIdentity(
            storeToken: StoreChangeTracker.shared.token(for: Self.statsChanges), now: now)
        let hydrationGeneration = StatsSnapshotStore.clearGeneration

        // A deletion since these aggregates were accepted revoked them (Delete
        // All Data, Delete Calendar Data, a photo-import discard, a calendar
        // title wipe). Return to the cold page before anything else, the
        // up-to-date fast path included, so a failing read afterwards can
        // neither show nor share the deleted totals.
        switch ledger.begin(token, currentGeneration: hydrationGeneration) {
        case .upToDate:
            return false
        case .refresh(let revoked):
            if revoked { showColdPage() }
        }

        // Capture once for both hydration and persistence. The process is
        // relaunched for a per-app language change, and the snapshot store
        // rejects any payload whose display strings came from another tag.
        let appLanguageTag = AppLanguagePreference.currentTag()

        // Cold-launch hydration: the first compute of the process takes 1–2 s
        // on device, so show the LAST computed aggregates immediately instead
        // of near-empty placeholders — deliberately stale for that second;
        // the fresh compute below replaces them silently.
        // First-run-only (`ledger.isCold`): once any fresh compute has
        // landed, disk state is never allowed to overwrite it. Skipped
        // once real data is on screen (`totalPings > 0` — a restart of this
        // task after a mid-compute token bump must not regress the page).
        // `onThisDayGroups` is NOT hydrated: memories are date-sensitive,
        // and a yesterday snapshot would flash yesterday's banner. The store
        // never returns a degraded snapshot, so hydration is complete data.
        if ledger.isCold, totalPings == 0,
           let snapshot = await Task.detached(priority: .userInitiated, operation: {
               StatsSnapshotStore.load(languageTag: appLanguageTag)
           }).value,
           !Task.isCancelled,
           hydrationGeneration == StatsSnapshotStore.clearGeneration {
            apply(snapshot, includingOnThisDay: false)
            ledger.acceptHydrated(generation: hydrationGeneration)
        }

        // Cancellation during hydration must not flush pending edits or
        // launch a fresh aggregation for an abandoned refresh.
        guard !Task.isCancelled else { return false }

        // The aggregator reads its OWN context, which sees committed state
        // only — flush any pending main-context edit (e.g. an autosave-
        // deferred rename) so the rebuild can't read past it. No-op when
        // nothing is pending. Publish this fallback save itself: the next
        // Trips appearance must not be needed to notify other readers. The
        // obligation is recorded before gate admission, so an autosave while
        // queued, a failed save or a cancellation still publishes once later.
        if modelContext.hasChanges { pendingEditPublicationOwed = true }
        if pendingEditPublicationOwed {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await Self.flushPendingStatsEdits()
            }
            switch outcome {
            case .saved:
                // The flush published its own token. Let that task compute
                // once, instead of starting obsolete work now.
                pendingEditPublicationOwed = false
                return false
            case .cancelled:
                // Superseded: the restarted task retries the owed flush.
                return false
            case .failed:
                // Committed data is still useful after an edit-save failure;
                // the decision below keeps this token retryable.
                break
            }
        }

        let container = modelContext.container
        // Captured BEFORE the compute: if Delete All Data lands while we are
        // aggregating, this result describes the pre-wipe store and must not
        // reach disk.
        let wipeGeneration = StatsSnapshotStore.clearGeneration
        // The loader owns its worker and propagates cancellation into fetch
        // and reduction checkpoints. Only a complete, current result may
        // update the view, consume its token, or reach the disk snapshot.
        guard let result = try? await StatsAggregator.load(container: container, now: now, calendar: token.calendar),
              !Task.isCancelled else { return false }

        // A clear mid-compute discards the pre-clear result, revokes what is
        // on screen and computes again. A degraded read never reaches the
        // page, the share card or disk, cold page included: the zero
        // placeholders stay, with sharing off, until a complete result lands.
        // A genuinely empty store is not degraded and still applies. The
        // ledger marks the token current only for a complete result with no
        // owed save, after a non-cancelled compute, so a superseded task
        // can't mark a stale token done.
        let conclusion = ledger.conclude(
            token,
            computedAt: wipeGeneration,
            currentToken: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: Self.statsChanges), now: .now),
            currentGeneration: StatsSnapshotStore.clearGeneration,
            computeDegraded: result.computeDegraded,
            pendingSaveOwed: pendingEditPublicationOwed)
        switch conclusion {
        case .superseded:
            return false
        case .clearedDuringCompute(let revoked):
            if revoked { showColdPage() }
            return conclusion.needsRetry
        case .decided(.rejectAndRetry):
            logger.error("Stats compute degraded (a fetch threw); keeping current aggregates and retrying.")
            return conclusion.needsRetry
        case .decided(.applyAndRetry):
            // Complete committed data, but without the unsaved edit: show it,
            // never mark the token or persist it, and retry the save.
            apply(result, includingOnThisDay: true)
            return conclusion.needsRetry
        case .decided(.applyAndMarkCurrent):
            apply(result, includingOnThisDay: true)
        }

        // Persist for the next cold launch's hydration. Off-main,
        // best-effort, after the UI already has the fresh values. Only a
        // complete result with no owed save reaches this point.
        guard let saveRequest = StatsSnapshotStore.reserveSave(generation: wipeGeneration) else { return false }
        Task.detached(priority: .background) {
            StatsSnapshotStore.save(
                result,
                request: saveRequest,
                languageTag: appLanguageTag
            )
        }
        return false
    }

    @MainActor
    private static func flushPendingStatsEdits() -> StatsPendingEditFlush.Outcome {
        // Includes an autosave while the gate unit was queued. The view
        // observed pending edits before enqueueing, so publish them once.
        StatsPendingEditFlush.flush(AppDelegate.modelContainer.mainContext) {
            StoreChangeTracker.shared.bump($0)
        }
    }

    /// Deletion revoked the aggregates on screen (the ledger already dropped
    /// them): back to the cold page (zero placeholders, sharing off) until a
    /// complete result lands.
    private func showColdPage() {
        apply(StatsAggregator.Aggregates(), includingOnThisDay: true)
    }

    /// The one place aggregate values land in view state — shared by the
    /// fresh-compute path and the cold-launch snapshot hydration.
    private func apply(_ result: StatsAggregator.Aggregates, includingOnThisDay: Bool) {
        totalPings = result.totalPings
        totalStays = result.totalStays
        totalHexes = result.totalHexes
        totalTrips = result.totalTrips
        trackingSince = result.trackingSince
        newHexesThisYear = result.newHexesThisYear
        topHexCountries = result.topHexCountries
        if includingOnThisDay {
            onThisDayGroups = result.onThisDayGroups
        }
        cachedUniqueCountries = result.uniqueCountries
        cachedCountryStats = result.countryStats
        cachedLastTrip = result.lastTrip
        cachedPassportData = result.passportData
        cachedCollections = result.collections
        cachedHomeHexCountries = result.homeHexCountries ?? []
        cachedTravelDaysThisYear = result.travelDaysThisYear
        cachedTravelDaysTotal = result.travelDaysTotal
        cachedYearStats = result.yearStats ?? []
        cachedFavoriteMonth = result.favoriteMonth
        cachedFavoriteMonthDays = result.favoriteMonthDays
    }

    /// Cached passport data with the one live overlay: the remembered-
    /// countries union must react to the KVS-synced checklist immediately
    /// (the storage is `@Observable`), not wait for a data epoch. O(codes).
    private var passportDataForDisplay: PassportData {
        var data = cachedPassportData
        data.countries = cachedUniqueCountries.union(rememberedCountries.codes).count
        return data
    }

    /// Geocode homes that are missing a locality (e.g. created before
    /// this field existed). Uses `resolveWithFallback` — the offline
    /// resolver runs first (sub-ms, no network), and Apple's
    /// `CLGeocoder` fills in the gap for the rare home placed in a
    /// long-tail area the bundled data can't name. Bounded by home
    /// count (typically 1-3), so well under the cache actor's
    /// 30 / 60-sec rate-limit budget.
    /// Homes whose locality backfill was already attempted this launch.
    /// Per-launch (not persisted) so an app restart, a resolver-data update or
    /// a network change all get a fresh try — the same cadence
    /// `PingRecorder.unresolvableStayIDs` uses for the identical problem.
    @MainActor private static var homeGeocodeAttemptedThisLaunch: Set<UUID> = []

    private func backfillHomeLocalities() async {
        // Heal both `locality` and `isoCountryCode`: a home whose
        // creation-time geocode failed could otherwise carry a locality but
        // a nil country code forever — silently suppressing country-welcome
        // notifications and the passport's "% of home explored" pin, with
        // no other backfill path in production.
        //
        // Value snapshots, then per-home ungated geocode + GATED apply with
        // re-fetch-by-id re-validation: `PlacesDeduplicator` hard-deletes
        // losing duplicate Homes on its own context on every CloudKit push,
        // and two-device onboarding (the moment duplicate ACTIVE homes
        // exist) is exactly when localities are still nil, so a live `Home`
        // held across the geocode await could be a deleted row by the write,
        // and trap. The gate unit serializes against the dedup chain's own
        // `[.home]` units, and the fresh fetch simply misses a row the
        // deduplicator removed mid-geocode.
        let targets: [(id: UUID, latitude: Double, longitude: Double)] =
            ((try? modelContext.fetch(FetchDescriptor<Home>())) ?? [])
                .filter { $0.locality == nil || $0.isoCountryCode == nil }
                // Skip homes this launch already failed to resolve. The
                // "still missing" test has no attempt counter and this runs on
                // EVERY Stats appearance, so a home the resolver simply cannot
                // place — mid-ocean, or any coordinate the offline layers miss
                // while MapKit is rate-limited — would re-run the whole lookup,
                // and every partial answer would re-take a `[.home]` gate unit
                // and re-bump the `.home` tracker, invalidating Stats
                // aggregates in a loop.
                .filter { !Self.homeGeocodeAttemptedThisLaunch.contains($0.id) }
                .map { ($0.id, $0.latitude, $0.longitude) }
        guard !targets.isEmpty else { return }

        for target in targets {
            Self.homeGeocodeAttemptedThisLaunch.insert(target.id)
            guard let r = await GeocodeResolver.shared.resolveWithFallback(
                latitude: target.latitude, longitude: target.longitude
            ) else { continue }

            // Sendable value captures only (the performMerge/performDelete
            // gate-closure pattern); the static worker refetches on the
            // main context.
            let homeID = target.id
            let locality = r.localityForStorage
            let adminArea = r.administrativeArea
            let country = r.country
            let iso = r.isoCountryCode
            let titleInputsChanged = await PipelineGate.shared.runReturning(
                touching: [.home, .trip]
            ) {
                await Self.applyHomeGeocode(
                    homeID: homeID, locality: locality,
                    administrativeArea: adminArea, country: country,
                    isoCountryCode: iso
                )
            }
            if titleInputsChanged {
                _ = await AppDelegate.tripClassifier.regenerateAllTitles()
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                await MainActor.run {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
    }

    /// The actual geocode apply, on the main context. Static + ID-based so
    /// the gate closure stays free of non-Sendable captures; the refetch
    /// tolerates the home having been deleted by a unit that ran ahead of
    /// this one in the gate's queue (guard returns — nothing half-written).
    private static func applyHomeGeocode(
        homeID: UUID, locality: String?, administrativeArea: String?,
        country: String?, isoCountryCode: String?
    ) -> Bool {
        let modelContext = AppDelegate.modelContainer.mainContext
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let id = homeID
        let predicate = #Predicate<Home> { $0.id == id }
        guard let home = try? modelContext.fetch(
            FetchDescriptor<Home>(predicate: predicate)
        ).first, !home.isDeleted,
              let titleInputsBefore = try? TripTitleStore
                .fetchActiveHomeTitleInputs(in: modelContext) else { return false }

        // Country-name guard (`Result.localityForStorage`) — a home in a
        // long-tail area must not show "Greece" as its city. Per-field nil
        // checks: never overwrite a value the user (or a better earlier
        // geocode) already provided.
        if home.locality == nil { home.locality = locality }
        if home.administrativeArea == nil { home.administrativeArea = administrativeArea }
        if home.country == nil { home.country = country }
        if home.isoCountryCode == nil { home.isoCountryCode = isoCountryCode }
        do {
            let changed = try TripTitleStore
                .invalidateAllGeneratedTitlesIfActiveHomesChanged(
                    from: titleInputsBefore,
                    in: modelContext)
            try modelContext.save()
            try? TripTitleStore.recordActiveHomeTitleFingerprint(
                in: modelContext)
            return changed
        } catch {
            modelContext.rollback()
            return false
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private var heroSection: some View {
        GlobeView(visitedCountryCodes: cachedUniqueCountries.union(rememberedCountries.codes))
    }

    // MARK: - Exploration

    /// The hex map's compulsion loop, in numbers: how much of the world the
    /// user has stood in, what's new this year, and where the exploration
    /// concentrates. Counts match the Map tab (same transit-only filter).
    @ViewBuilder
    private var explorationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exploration")
                .font(.headline)

            // The hex count leads, big; the area it stands for sits beside
            // it. EVERY derived number in this card wears the same ≈: the
            // km², both percentages (2-sig-fig rounded, and the land
            // denominator is itself an estimate) — consistency beats the
            // exact-vs-estimated distinction here.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(totalHexes, format: .number.grouping(.never))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        Image(systemName: "hexagon.fill")
                            .foregroundStyle(.teal)
                        Text("Hexes explored")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if totalHexes > 0 {
                    Text(verbatim: "≈ " + cachedPassportData.areaText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)

            if totalHexes > 0 {
                // World coverage — the honest, humbling denominators, as a
                // pair of quiet tiles (the country-progress rings' idiom).
                HStack(spacing: 10) {
                    coverageTile(
                        value: CountryCatalog.percentText(CountryCatalog.fractionOfEarth(hexCount: totalHexes)),
                        label: String(localized: "stats.exploration.of-the-world", defaultValue: "Of the world", comment: "Exploration tile caption for the share of the Earth's surface explored."),
                        icon: "globe", tint: .blue
                    )
                    coverageTile(
                        value: CountryCatalog.percentText(CountryCatalog.fractionOfLand(hexCount: totalHexes)),
                        label: String(localized: "stats.exploration.of-land", defaultValue: "Of land", comment: "Exploration tile caption for the share of the Earth's land explored."),
                        icon: "globe.europe.africa.fill", tint: .green
                    )
                }
            }

            if newHexesThisYear > 0 {
                // Tap → Map tab with this year's new hexes highlighted.
                // Highlight modes are ONLY enterable from these Stats rows
                // (see MapTabRouter); the chevron signals the navigation.
                Button {
                    MapTabRouter.shared.requestHighlight(.newThisYear)
                } label: {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text("+\(newHexesThisYear)")
                                .monospacedDigit()
                                .foregroundStyle(.tint)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.yellow)
                            Text("New this year")
                                .foregroundStyle(.primary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .accessibilityHint("Shows this year's new hexes on the map")
            }

            // Home countries pin FIRST (house badge + their coverage %),
            // then the top-by-hexes countries that aren't already pinned.
            // "% of home explored" is deliberately just presentation over
            // the per-country coverage: moving countries moves the pin,
            // and the old country keeps its row and its percentage.
            let pinnedCodes = Set(cachedHomeHexCountries.map(\.code))
            // The aggregator hands over SIX top countries; after dropping
            // the pinned home rows the card always shows up to 3 others —
            // a home country ranking top-3 no longer consumes a slot.
            let hexCountryRows = cachedHomeHexCountries
                + topHexCountries.filter { !pinnedCodes.contains($0.code) }.prefix(3)
            if !hexCountryRows.isEmpty {
                Divider()
                ForEach(hexCountryRows, id: \.code) { entry in
                    // Tap → Map tab with this country's hexes highlighted.
                    Button {
                        MapTabRouter.shared.requestHighlight(
                            .country(code: entry.code, name: entry.name)
                        )
                    } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(hexCountryDetail(entry))
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if pinnedCodes.contains(entry.code) {
                                    Image(systemName: "house.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(flagEmoji(for: entry.code) ?? "🏳️")
                                Text(hexCountryName(entry))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .accessibilityHint("Shows \(hexCountryName(entry)) hexes on the map")
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    /// "≈0.02%" over its denominator caption, on a faint tint tile.
    private func coverageTile(value: String, label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "≈" + value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Collections

    /// Airports visited / flight log / Places gazetteer — the collections
    /// the pipeline was already producing, surfaced. Rows push list views
    /// that receive the precomputed value (no per-view recompute).
    @ViewBuilder
    private var collectionsSection: some View {
        CollectionsSectionView(collections: cachedCollections)
    }

    // MARK: - Countries Section

    @ViewBuilder
    private var countriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Countries Visited")
                .font(.headline)

                // "How much of the world's map is stamped" — a filling ring
                // per honest denominator, since neither alone satisfies:
                // territories fold into their sovereign against the 193 UN
                // members (visiting Puerto Rico counts the US), and count
                // as themselves against the full ISO list.
                let visitedCodes = cachedUniqueCountries.union(rememberedCountries.codes)
                if !visitedCodes.isEmpty {
                    let unCount = CountryCatalog.unMemberCount(of: visitedCodes)
                    // Twin inset tiles — each ring gets its own quiet
                    // background so the pair reads as a distinct widget
                    // between the title and the flag wall.
                    HStack(spacing: 10) {
                        CountryProgressRing(
                            visited: unCount,
                            total: CountryCatalog.unMemberTotal,
                            caption: String(localized: "stats.country-progress.un-countries", defaultValue: "UN countries", comment: "Caption for passport progress against the total number of UN countries."),
                            tint: .blue
                        )
                        CountryProgressRing(
                            visited: visitedCodes.count,
                            total: CountryCatalog.isoCodeTotal,
                            caption: String(localized: "stats.country-progress.including-territories", defaultValue: "incl. territories", comment: "Caption for passport progress including territories."),
                            tint: .teal
                        )
                    }
                    .padding(.bottom, 4)
                }

                // **Tappable wrapped flag grid**: every flag visible, in
                // `countryStats` order (trip count desc, locale-aware name
                // tiebreak); each flag taps through `TripsTabRouter`.
                let stats = cachedCountryStats
                if !stats.isEmpty || !rememberedOnlyCodes.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 36), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(stats, id: \.code) { stat in
                            // A zero-trip country (home country, or a foreign
                            // country visited only as part of home-area life —
                            // the France-resident/Switzerland-worker case,
                            // by design) has nothing to
                            // filter to; its flag is static like the
                            // remembered ones.
                            if stat.tripCount > 0 {
                                Button {
                                    TripsTabRouter.shared.requestCountryFilter(stat.code)
                                } label: {
                                    Text(flagEmoji(for: stat.code) ?? "🏳️")
                                        .font(.title)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show trips in \(Self.countryDisplayName(stat))")
                            } else {
                                Text(flagEmoji(for: stat.code) ?? "🏳️")
                                    .font(.title)
                                    .accessibilityLabel(Self.countryDisplayName(stat))
                            }
                        }
                        // Remembered (pre-TravelLog) countries belong on the
                        // flag wall too — it reads as "everywhere I've been",
                        // not "everywhere TravelLog saw", so a remembered
                        // country counted in the passport shows its flag
                        // here too. No trips to filter to, so
                        // the flag is static; the row below still labels it.
                        ForEach(rememberedOnlyCodes.sorted(), id: \.self) { code in
                            Text(flagEmoji(for: code) ?? "🏳️")
                                .font(.title)
                                .accessibilityLabel(
                                    "\(AppLanguagePreference.currentLocale().localizedString(forRegionCode: code) ?? code), visited before TravelLog"
                                )
                        }
                    }
                }

                // **Tappable country rows**. Whole-row tap target —
                // `.contentShape(.rect)` makes the empty Spacer area
                // hittable too, matching Apple's NavigationLink-row
                // convention. Wrapped in a `Button` rather than
                // `.onTapGesture` so it picks up the system's row-tap
                // press feedback automatically.
                ForEach(stats, id: \.code) { stat in
                    // Zero-trip countries tap to an EMPTY trips filter, so
                    // those rows are static. The foreign zero-trip case is
                    // deliberate data, not a glitch: a demoted cross-border
                    // routine (France resident, Switzerland worker) stamps
                    // the passport without minting trips — the caption says
                    // where the country came from.
                    if stat.tripCount > 0 {
                        Button {
                            TripsTabRouter.shared.requestCountryFilter(stat.code)
                        } label: {
                            countryRow(for: stat)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the Trips tab filtered to \(Self.countryDisplayName(stat))")
                    } else {
                        // Static rows keep the Button's one-element VoiceOver
                        // shape.
                        countryRow(for: stat)
                            .accessibilityElement(children: .combine)
                    }
                }

                // Remembered (pre-TravelLog) countries — no trips to filter
                // to, so the rows are static.
                ForEach(rememberedOnlyCodes.sorted(), id: \.self) { code in
                    HStack {
                        Text(flagEmoji(for: code) ?? "🏳️")
                        Text(AppLanguagePreference.currentLocale().localizedString(forRegionCode: code) ?? code)
                            .font(.subheadline)
                        Spacer()
                        Text("before TravelLog")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Button {
                    showEarlierTravelsPicker = true
                } label: {
                    Label("Add countries from before TravelLog", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .sheet(isPresented: $showEarlierTravelsPicker) {
                RememberedCountriesPicker(trackedCodes: cachedUniqueCountries)
            }
    }

    /// One country row of the passport section. The caption names where the
    /// country CAME from: trips, home, a temporary home, or — the foreign
    /// zero-trip case — time near home (a demoted cross-border routine stamps
    /// the passport without minting trips, by design). Trip
    /// rows add the days spent there.
    private func countryRow(for stat: CountryStat) -> some View {
        HStack {
            Text(flagEmoji(for: stat.code) ?? "🏳️")
            Text(Self.countryDisplayName(stat))
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Group {
                if stat.isHome && stat.tripCount == 0 {
                    Text("home")
                } else if stat.isHome {
                    Text(stat.tripCount == 1
                         ? String(localized: "stats.country.trips-home.one", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trip · home", comment: "Country row caption for one trip to a home country.")
                         : String(localized: "stats.country.trips-home.other", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trips · home", comment: "Country row caption for multiple trips to a home country."))
                } else if stat.isTemporaryHome == true && stat.tripCount == 0 {
                    Text(String(localized: "stats.country.temporary-home", defaultValue: "temporary home", comment: "Country row caption for the country of a temporary home, such as a semester abroad, with no trips there."))
                } else if stat.isTemporaryHome == true {
                    Text(stat.tripCount == 1
                         ? String(localized: "stats.country.trips-temporary-home.one", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trip · temporary home", comment: "Country row caption for one trip to the country of a temporary home.")
                         : String(localized: "stats.country.trips-temporary-home.other", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trips · temporary home", comment: "Country row caption for multiple trips to the country of a temporary home."))
                } else if stat.tripCount == 0 {
                    Text("time near home")
                } else {
                    let trips = tripCountText(stat.tripCount)
                    if let days = stat.days, days > 0 {
                        Text(verbatim: "\(trips) · \(dayCountText(days))")
                    } else {
                        Text(trips)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func tripCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "stats.country.trips.one", defaultValue: "\(count, format: .number.grouping(.never)) trip", comment: "Country row caption for one trip.")
            : String(localized: "stats.country.trips.other", defaultValue: "\(count, format: .number.grouping(.never)) trips", comment: "Country row caption for multiple trips.")
    }

    private func dayCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "trip-detail.duration-days.one", defaultValue: "\(count, format: .number.grouping(.never)) day", comment: "Trip detail duration of one day.")
            : String(localized: "trip-detail.duration-days.other", defaultValue: "\(count, format: .number.grouping(.never)) days", comment: "Trip detail duration of multiple days.")
    }

    // MARK: - Records

    /// The superlatives as a grid of tiles: one value each, with what it
    /// belongs to underneath. Only tiles with data render; the year-by-
    /// year numbers moved to the chart card above.
    @ViewBuilder
    private var recordsSection: some View {
        let tiles = recordTiles
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "passport.section.records", defaultValue: "Records", comment: "Passport detail section title for travel records."))
                    .font(.headline)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(tiles) { tile in
                        RecordTile(tile: tile)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private var recordTiles: [RecordTileData] {
        var tiles: [RecordTileData] = []
        let passport = cachedPassportData

        if let name = passport.longestTripName, passport.longestTripDays > 0 {
            tiles.append(RecordTileData(
                id: "longest-trip", icon: "trophy.fill", tint: .yellow,
                title: String(localized: "stats.highlight.longest-trip", defaultValue: "Longest Trip", comment: "Statistics highlight title for the longest trip."),
                value: dayCountText(passport.longestTripDays),
                detail: name
            ))
        }

        if let km = passport.furthestKm, km > 0 {
            tiles.append(RecordTileData(
                id: "farthest", icon: "location.north.line.fill", tint: .purple,
                title: String(localized: "stats.highlight.farthest-from-home", defaultValue: "Farthest From Home", comment: "Statistics highlight title for the farthest place from home."),
                value: UnitsFormatter.formatDistance(kilometers: km),
                detail: passport.furthestPlace ?? String(localized: "stats.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in the farthest-from-home statistics highlight.")
            ))
        }

        if let place = passport.mostVisitedPlace, passport.mostVisitedTripCount > 0 {
            tiles.append(RecordTileData(
                id: "most-visited", icon: "star.fill", tint: .orange,
                title: String(localized: "stats.highlight.most-visited", defaultValue: "Most Visited", comment: "Statistics highlight title for the most visited place."),
                value: place,
                detail: tripCountText(passport.mostVisitedTripCount)
            ))
        }

        if let month = cachedFavoriteMonth, let days = cachedFavoriteMonthDays, days > 0,
           let name = monthName(month) {
            tiles.append(RecordTileData(
                id: "favorite-month", icon: "calendar", tint: .green,
                title: String(localized: "stats.highlight.favorite-month", defaultValue: "Favorite Month", comment: "Statistics record title for the month with the most travel days."),
                value: name,
                detail: days == 1
                    ? String(localized: "stats.record.travel-days.one", defaultValue: "\(days, format: .number.grouping(.never)) travel day", comment: "Record tile detail for one travel day.")
                    : String(localized: "stats.record.travel-days.other", defaultValue: "\(days, format: .number.grouping(.never)) travel days", comment: "Record tile detail for multiple travel days.")
            ))
        }

        if let daysTotal = cachedTravelDaysTotal, daysTotal > 0 {
            let thisYear = cachedTravelDaysThisYear ?? 0
            tiles.append(RecordTileData(
                id: "days-traveling", icon: "suitcase.fill", tint: .teal,
                title: String(localized: "stats.highlight.days-traveling", defaultValue: "Days Traveling", comment: "Statistics highlight title for travel days."),
                value: daysTotal.formatted(.number.grouping(.never)),
                detail: thisYear == 1
                    ? String(localized: "stats.record.this-year.one", defaultValue: "\(thisYear, format: .number.grouping(.never)) day this year", comment: "Record tile detail for one travel day in the current year.")
                    : String(localized: "stats.record.this-year.other", defaultValue: "\(thisYear, format: .number.grouping(.never)) days this year", comment: "Record tile detail for multiple travel days in the current year.")
            ))
        }

        if passport.trips > 0, let averageDays = passport.averageTripDays, averageDays > 0 {
            tiles.append(RecordTileData(
                id: "average-trip", icon: "chart.bar.fill", tint: .indigo,
                title: String(localized: "stats.highlight.average-trip", defaultValue: "Average Trip", comment: "Statistics record title for the average trip length."),
                value: averageDaysText(averageDays),
                detail: tripCountText(passport.trips)
            ))
        }

        if let recent = cachedLastTrip {
            tiles.append(RecordTileData(
                id: "last-trip", icon: "clock.fill", tint: .blue,
                title: String(localized: "stats.highlight.last-trip", defaultValue: "Last Trip", comment: "Statistics highlight title for the most recent trip."),
                value: recent.name,
                detail: recent.date.formatted(date: .abbreviated, time: .omitted)
            ))
        }

        return tiles
    }

    /// "4.2 days" — one decimal at most; the singular form only when the
    /// rounded text reads as exactly one.
    private func averageDaysText(_ average: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        let text = average.formatted(style)
        return text == 1.0.formatted(style)
            ? String(localized: "stats.record.average-days.one", defaultValue: "\(text) day", comment: "Average trip length of one day; the placeholder is an already formatted number.")
            : String(localized: "stats.record.average-days.other", defaultValue: "\(text) days", comment: "Average trip length in days; the placeholder is an already formatted number with up to one decimal.")
    }

    /// Standalone month name in the app language ("March", not "of March").
    private func monthName(_ month: Int) -> String? {
        Self.monthName(month, locale: AppLanguagePreference.currentLocale())
    }

    /// The ledger's month index is Gregorian regardless of the device calendar.
    static func monthName(_ month: Int, locale: Locale) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneMonthSymbols
        guard (1...symbols.count).contains(month) else { return nil }
        return symbols[month - 1].capitalized(with: locale)
    }

    /// Stored names are English ASCII for search; display in the app language.
    static func countryDisplayName(_ stat: CountryStat, locale: Locale = AppLanguagePreference.currentLocale()) -> String {
        localizedCountryName(iso: stat.code, fallback: stat.name, locale: locale) ?? stat.name
    }

    // MARK: - Footer

    /// The one diagnostic worth a line on the page. Ping, stay and hex
    /// totals live in the passport's Totals sheet.
    @ViewBuilder
    private var footer: some View {
        if let since = trackingSince {
            Text(String(localized: "stats.footer.tracking-since", defaultValue: "Tracking since \(since.formatted(date: .long, time: .omitted))", comment: "Stats page footer naming the first day of recorded location data."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    // MARK: - Computed Data

    /// Remembered countries the tracked data does NOT already cover.
    /// Reads the cached country set (the live KVS side stays reactive via
    /// `rememberedCountries.codes`, which is `@Observable`).
    private var rememberedOnlyCodes: Set<String> {
        rememberedCountries.codes.subtracting(cachedUniqueCountries)
    }

    /// "312 hexes · 4.2%" — hex count plus that country's coverage share
    /// (omitted when the catalog has no area for the code).
    private func hexCountryDetail(_ entry: StatsAggregator.HexCountry) -> String {
        guard let percent = CountryCatalog.coveragePercent(code: entry.code, hexCount: entry.count) else {
            return entry.count == 1
                ? String(localized: "stats.hex-country-detail.one", defaultValue: "\(entry.count, format: .number.grouping(.never)) hex", comment: "Country exploration detail for one hex when no coverage percentage is available.")
                : String(localized: "stats.hex-country-detail.other", defaultValue: "\(entry.count, format: .number.grouping(.never)) hexes", comment: "Country exploration detail for multiple hexes when no coverage percentage is available.")
        }
        // "≈" matches the world/land rows' honesty: the share uses the
        // GLOBAL mean res-6 cell area, which over/understates by latitude.
        let pctText = CountryCatalog.countryPercentText(percent)
        if pctText.hasPrefix("<") {
            return entry.count == 1
                ? String(localized: "stats.hex-country-detail.percent-floor.one", defaultValue: "\(entry.count, format: .number.grouping(.never)) hex · \(pctText)", comment: "Country exploration detail for one hex with a below-threshold coverage percentage.")
                : String(localized: "stats.hex-country-detail.percent-floor.other", defaultValue: "\(entry.count, format: .number.grouping(.never)) hexes · \(pctText)", comment: "Country exploration detail for multiple hexes with a below-threshold coverage percentage.")
        }
        return entry.count == 1
            ? String(localized: "stats.hex-country-detail.percent.one", defaultValue: "\(entry.count, format: .number.grouping(.never)) hex · ≈\(pctText)", comment: "Country exploration detail for one hex with an approximate coverage percentage.")
            : String(localized: "stats.hex-country-detail.percent.other", defaultValue: "\(entry.count, format: .number.grouping(.never)) hexes · ≈\(pctText)", comment: "Country exploration detail for multiple hexes with an approximate coverage percentage.")
    }

    /// A pinned home country can predate its first `HexVisit` (fresh move),
    /// leaving the aggregator's `name` nil — fall back to the locale's
    /// region name rather than showing a bare ISO code.
    private func hexCountryName(_ entry: StatsAggregator.HexCountry) -> String {
        AppLanguagePreference.currentLocale()
            .localizedString(forRegionCode: entry.code)
            ?? entry.name
            ?? entry.code
    }

}

// MARK: - Country Progress Ring

/// A circular gauge that fills 0 → 100% with the share of the world's
/// countries visited, rendered as its own inset "mini-widget" tile (a
/// subtle fill on top of the card material) so the pair reads as one
/// distinct item rather than blending into the flag wall above it. The
/// center shows the percentage; below the ring sit the raw "12 of 193"
/// and which denominator this ring measures.
private struct CountryProgressRing: View {
    let visited: Int
    let total: Int
    let caption: String
    let tint: Color

    private var fraction: Double {
        total > 0 ? min(1, Double(max(0, visited)) / Double(total)) : 0
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Track in the fill's own tint, faint — reads as one
                // colored gauge instead of a gray donut on a gray tile.
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                Text(CountryCatalog.percentText(fraction))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 84, height: 84)

            VStack(spacing: 1) {
                Text(visited == 1
                     ? String(localized: "stats.country-progress.count.one", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never))", comment: "Country progress count when one country is visited out of the total.")
                     : String(localized: "stats.country-progress.count.other", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never))", comment: "Country progress count when zero or multiple countries are visited out of the total."))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        // The tile wears its ring's tint, faint — a grey fill here read
        // as mud on the card material.
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visited == 1
                            ? String(localized: "stats.country-progress.accessibility.one", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) \(caption) visited, \(CountryCatalog.percentText(fraction))", comment: "Country progress accessibility label when one country is visited.")
                            : String(localized: "stats.country-progress.accessibility.other", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) \(caption) visited, \(CountryCatalog.percentText(fraction))", comment: "Country progress accessibility label when zero or multiple countries are visited."))
    }
}

// MARK: - Record Tile

private struct RecordTileData: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String?
}

/// One superlative: a caption title, the value large, and what it belongs
/// to beneath — on a faint tint tile like the country-progress rings.
private struct RecordTile: View {
    let tile: RecordTileData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tile.icon)
                    .font(.subheadline)
                    .foregroundStyle(tile.tint)
                Text(tile.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(tile.value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = tile.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tile.tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
