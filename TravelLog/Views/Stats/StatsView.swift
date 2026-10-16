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

/// What starts a Stats refresh, and when its first pass runs.
nonisolated enum StatsRefreshPacing {
    /// The store types Stats actually renders. A calendar scan (`.plannedTrip`),
    /// photo-import-state churn, or a Wrapped write no longer restarts the
    /// aggregate rebuild — only these do.
    /// `.home`: the pinned "% of home explored" row and the country rows'
    /// `isHome` badge both derive from the active Home, which otherwise only
    /// changes on a move. `.temporaryHome`: days away and the country rows'
    /// caption derive from temporary homes.
    /// `.locationPing` is left out on purpose: every live ping batch bumps
    /// it, and only the ping total and tracking-since read pings, so the
    /// live cadence must not rerun a full compute. Those two values catch up
    /// at the next refresh. Every writer that inserts or deletes pings
    /// outside the live recorder (imports, dedup, trip deletion, discard,
    /// wipe, CloudKit) also declares `.stay` or `.all`.
    static let observedChanges: StoreChange = [.stay, .trip, .hexVisit, .home, .temporaryHome]

    /// Trailing debounce of a warm recompute that only store generations
    /// started: a burst (classification passes, geocode pages, import
    /// chunks) restarts the task once per tracker flush, and only the last
    /// restart computes.
    static let warmDebounce: Duration = .milliseconds(2500)

    /// The wait before a refresh task's first pass, or nil to start at once.
    /// Waits only when the task restarted while the page stayed up, complete
    /// current aggregates of the current clear generation are on screen,
    /// the civil day and zone match the last complete compute, and only the
    /// store token moved. A cold or unfinished page, a revocation, a clear,
    /// a day change and an appearance compute at once.
    static func delayBeforeFirstPass(
        current: StatsRefreshIdentity,
        observedClearGeneration: Int,
        currentClearGeneration: Int,
        ledger: StatsRefreshLedger,
        restartedOnScreen: Bool
    ) -> Duration? {
        guard restartedOnScreen,
              observedClearGeneration == currentClearGeneration,
              ledger.hasCompleteAggregates(currentGeneration: currentClearGeneration),
              let completed = ledger.lastCompleted,
              current.day == completed.day,
              current.calendar == completed.calendar,
              current.storeToken != completed.storeToken
        else { return nil }
        return warmDebounce
    }
}

/// Aggregate statistics dashboard.
///
/// Order, top to bottom: On This Day banner (when a memory exists), the
/// Passport card, This Year (with the By Year bars), Countries (globe, top
/// countries, All Countries), Travel Patterns, Records, Collections,
/// Exploration and the saved Wrapped recaps. Cards with nothing to show
/// are left out. Every number is a formatted read of the epoch-cached
/// `StatsAggregator` aggregates or of the `StatsOverview` derived from them
/// in `apply`; the body computes nothing.
struct StatsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    // Lightweight counts - computed via fetchCount() instead of loading all objects.
    @State private var totalPings = 0
    @State private var totalStays = 0
    @State private var totalHexes = 0
    @State private var totalTrips = 0

    /// Past-year memories for today's date; empty hides the banner.
    @State private var onThisDayGroups: [OnThisDayYearGroup] = []

    /// Pre-TravelLog countries (KVS-synced checklist — see
    /// `RememberedCountriesStorage`). Counts toward the passport and the
    /// globe; never creates trips/stays/hexes.
    private let rememberedCountries = RememberedCountriesStorage.shared

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
    /// This Year, By Year, Travel Patterns, the Collections subtitles and
    /// Exploration's years and country coverage, derived once per applied
    /// aggregate.
    @State private var overview = StatsOverview()

    /// The store types Stats renders (`StatsRefreshPacing.observedChanges`;
    /// live pings excluded).
    private static let statsChanges = StatsRefreshPacing.observedChanges

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
    /// The refresh task has started since the page last appeared, so a new
    /// start is a key change while on screen and may be debounced. Reset on
    /// disappearance and after this page's own pending-edit publication,
    /// whose restart computes at once.
    @State private var refreshRestartsOnScreen = false

    private var hasCompleteAggregates: Bool {
        ledger.hasCompleteAggregates(currentGeneration: StatsSnapshotStore.clearGeneration)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !onThisDayGroups.isEmpty {
                    OnThisDayBanner(groups: onThisDayGroups)
                }
                PassportCardView(data: passportDataForDisplay, canShare: hasCompleteAggregates)
                if overview.hasYearData {
                    StatsYearCard(overview: overview, rememberedCodes: rememberedCountries.codes)
                }
                StatsCountriesCard(countryStats: cachedCountryStats, trackedCodes: cachedUniqueCountries)
                StatsPatternsCard(overview: overview, averageTripDays: cachedPassportData.averageTripDays)
                StatsRecordsCard(passport: cachedPassportData, lastTrip: cachedLastTrip)
                CollectionsSectionView(collections: cachedCollections, summary: overview.collections)
                StatsExplorationCard(
                    totalHexes: totalHexes,
                    areaText: cachedPassportData.areaText,
                    exploration: overview.exploration)
                SavedWrappedCard()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stats")
        // Observe only relevant generations, the civil day and snapshot
        // clears. Clock events update the date input; same-day appearances
        // keep the task ID equal.
        .task(id: StatsRefreshTaskKey(
            identity: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: Self.statsChanges), now: refreshDate),
            clearGeneration: observedClearGeneration
        )) {
            await runRefreshTask()
        }
        .onDisappear { refreshRestartsOnScreen = false }
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

    /// One run of the refresh task. A warm restart caused only by store
    /// bumps first waits out the burst (cancelled by the next key change);
    /// a cold page, a clear and a day change compute at once. Revocation
    /// never waits: `observeSnapshotClears` revokes on its own task.
    private func runRefreshTask() async {
        let restartedOnScreen = refreshRestartsOnScreen
        refreshRestartsOnScreen = true
        if let wait = StatsRefreshPacing.delayBeforeFirstPass(
            current: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: Self.statsChanges), now: .now),
            observedClearGeneration: observedClearGeneration,
            currentClearGeneration: StatsSnapshotStore.clearGeneration,
            ledger: ledger,
            restartedOnScreen: restartedOnScreen
        ) {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
        }
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
                // once, instead of starting obsolete work now, and without
                // the warm debounce.
                pendingEditPublicationOwed = false
                refreshRestartsOnScreen = false
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
        if includingOnThisDay {
            onThisDayGroups = result.onThisDayGroups
        }
        cachedUniqueCountries = result.uniqueCountries
        cachedCountryStats = result.countryStats
        cachedLastTrip = result.lastTrip
        cachedPassportData = result.passportData
        cachedCollections = result.collections
        overview = StatsOverview(result, now: .now, calendar: .current)
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
    /// resolver runs first (sub-ms, no network), and MapKit
    /// reverse geocoding fills in the gap for the rare home placed in a
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

    // MARK: - Shared formatting

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
}

// MARK: - Saved Wrapped

/// Saved recaps, one row per year as in Settings > Memories; hidden until
/// one exists. Its own view so a Wrapped write re-renders only this card.
private struct SavedWrappedCard: View {
    @Query(sort: \YearWrapped.year, order: .reverse)
    private var entries: [YearWrapped]

    var body: some View {
        let presented = YearWrapped.presented(entries)
        if !presented.isEmpty {
            StatsSection(title: String(localized: "Memories")) {
                ForEach(presented, id: \.year) { entry in
                    Button {
                        WrappedPresenter.shared.requestYear(entry.year)
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(AppTheme.accent)
                            Text("\(String(entry.year)) Wrapped")
                                .foregroundStyle(.primary)
                            Spacer()
                            if YearWrapped.isNew(year: entry.year, in: entries) {
                                AppChip(label: Text("New"), style: .selected, small: true)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
