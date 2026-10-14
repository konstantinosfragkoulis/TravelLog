//
//  CalendarEnricher.swift
//  TravelLog
//

@preconcurrency import EventKit
import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WeatherKit
import WidgetKit
import os.log

/// Owns the app's single `EKEventStore` (Apple's guidance: one per app) and
/// is the only place raw EventKit types are touched. `EKEventStore` /
/// `EKEvent` / `EKCalendar` are not `Sendable`, so every read happens inside
/// this actor's isolation domain and only `CalendarEventSnapshot` values
/// leave it — the same discipline `TripSnapshot` / `PhotoImportStateSnapshot`
/// apply to their frameworks.
///
/// Two lanes, one grant:
/// - **Future lane**: scan upcoming events, detect likely trips, persist
///   `PlannedTrip` rows.
/// - **Past lane**: per-window event lookups that corroborate flights and
///   give the classification prompt context. Titles take no
///   calendar input (`CalendarTripNaming`).
///
/// Like every enrichment lane, this is best-effort and never gates the core
/// `LocationPing → Stay → Trip` pipeline: a denied or unavailable Calendar
/// permission degrades to exactly the current behavior.
///
/// ## Privacy
///
/// `EKEvent.notes` routinely contains third-party PII (names, emails,
/// dial-ins). It may ride on the in-memory snapshot so detection heuristics
/// can scan it for keywords, but it must NEVER be persisted — not on
/// `PlannedTrip`, not in a prompt log, nowhere. Attendees/organizer are not
/// even snapshotted.
@ModelActor
actor CalendarEnricher {
    let logger = Logger(subsystem: "com.travellog.app", category: "CalendarEnricher")

    /// The one `EKEventStore`. Created eagerly with the actor (cheap before
    /// any permission is granted; queries simply return nothing).
    let eventStore = EKEventStore()

    /// `predicateForEvents(withStart:end:calendars:)` silently caps the span
    /// at 4 years — longer windows must be chunked. 1,460 days stays safely
    /// under the cap including leap years.
    static let maxQuerySpanSeconds: TimeInterval = 1_460 * 24 * 60 * 60

    // MARK: - Authorization

    /// Current calendar-events authorization. Class-method lookup — safe from
    /// any isolation domain, no store instance involved.
    nonisolated static var authorizationStatus: EKAuthorizationStatus {
        #if DEBUG
        // The lookup is a synchronous XPC round trip to the simulator's
        // calendar daemon, which has stalled indefinitely under many parallel
        // test cases (a `.timeLimit` cannot interrupt it). Suites that never
        // exercise EventKit bind a fixed status instead.
        if let status = TestScope.authorizationStatus { return status }
        #endif
        return EKEventStore.authorizationStatus(for: .event)
    }

    #if DEBUG
    nonisolated enum TestScope {
        @TaskLocal static var authorizationStatus: EKAuthorizationStatus?
        /// Live calendars for selection resolution, standing in for
        /// EventKit. While bound, event queries are counted and return
        /// nothing instead of touching the calendar daemon.
        @TaskLocal static var liveCalendars: [CalendarChoice]?
        /// Makes the scan's Home read fail, as a thrown fetch would.
        @TaskLocal static var failHomeFetch = false
    }
    #endif

    /// True when events can actually be read.
    nonisolated static var hasReadAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// Persistent revocation-cycle state. The observed-grant latch lets an
    /// access loss be recognized even when no future detections exist; the
    /// completed latch keeps cleanup to one successful pass per revoke/regrant.
    nonisolated static var defaults: UserDefaults {
        #if DEBUG
        if let suite = ForwardGeocoder.TestScope.defaultsSuiteName { return UserDefaults(suiteName: suite)! }
        #endif
        return .standard
    }

    private nonisolated static let readAccessObservedKey =
        "calendarReadAccessObserved_v1"
    private nonisolated static let revocationCleanupCompletedKey =
        "calendarRevocationCleanupCompleted_v1"

    /// Requests Full Access to calendar events (iOS 17+ API; there is no
    /// read-only tier — full access is the minimum that permits reading).
    /// Returns the resulting read capability.
    func requestFullAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            logger.info("Calendar full-access request completed: granted=\(granted)")
            return granted
        } catch {
            logger.error("Calendar full-access request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Event queries

    /// All event instances overlapping `[start, end]`, as `Sendable`
    /// snapshots. Recurring events arrive pre-expanded (one snapshot per
    /// occurrence). Spans longer than EventKit's 4-year predicate cap are
    /// chunked transparently; an instance straddling a chunk boundary is
    /// de-duplicated on `(localIdentifier, startDate)` — the same composite
    /// identity `PlannedTrip` uses.
    ///
    /// Returns `[]` without touching the store when read access is missing.
    func eventsOverlapping(start: Date, end: Date) -> [CalendarEventSnapshot] {
        guard Self.hasReadAccess, start < end else { return [] }

        // Respect the user's calendar selection in Settings at this
        // single choke point — every lane (future scan, classification hints,
        // flight corroboration) inherits it. An explicit selection none of whose
        // calendars resolves reads nothing; it never widens to every calendar.
        let selection = resolveCalendarScope()
        guard selection.scope != .noneAvailable else { return [] }
        return events(start: start, end: end, calendars: selection.calendars)
    }

    #if DEBUG
    private(set) var eventQueryCountForTesting = 0
    #endif

    /// The EventKit query itself. `calendars` nil = all calendars.
    func events(start: Date, end: Date, calendars: [EKCalendar]?) -> [CalendarEventSnapshot] {
        guard start < end else { return [] }
        #if DEBUG
        eventQueryCountForTesting += 1
        if TestScope.liveCalendars != nil { return [] }
        #endif

        var snapshots: [CalendarEventSnapshot] = []
        var seen = Set<String>()

        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(chunkStart.addingTimeInterval(Self.maxQuerySpanSeconds), end)
            let predicate = eventStore.predicateForEvents(
                withStart: chunkStart, end: chunkEnd, calendars: calendars
            )
            for event in eventStore.events(matching: predicate) {
                guard let snapshot = CalendarEventSnapshot(event: event) else { continue }
                let key = "\(snapshot.localIdentifier)|\(snapshot.startDate.timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted {
                    snapshots.append(snapshot)
                }
            }
            chunkStart = chunkEnd
        }
        return snapshots
    }

    // MARK: - Future lane: scan, detect, reconcile

    /// How far ahead the future-lane scan looks. Comfortably under the 4-year
    /// predicate cap — no chunking in practice.
    static let scanWindowSeconds: TimeInterval = 180 * 24 * 60 * 60

    /// An `.upcoming` row whose source event stopped appearing in scans is
    /// deleted once `lastSeenAt` is older than this (tolerates out-of-order
    /// sync delivery — same grace-period rationale as
    /// `PhotoAnnotationDeduplicator.removeOrphans`).
    static let staleGraceSeconds: TimeInterval = 3 * 24 * 60 * 60

    /// How stale a row's `lastSeenAt` must be before a scan refreshes it.
    /// The field only feeds the stale sweep above (which has a 3-DAY
    /// grace), so per-scan precision is wasted — and writing `now` on
    /// every scan made every foreground transition a real save plus a
    /// CloudKit export while any upcoming detection existed.
    static let lastSeenRefreshSeconds: TimeInterval = 12 * 60 * 60

    /// Whether the current scan cycle's mutating passes (reconcile,
    /// forecast) actually persisted anything — read by `scanUpcomingTrips`
    /// to skip the widget-timeline reload on no-change scans. Reset at the
    /// start of each foreground scan. Overlapping scans can race this
    /// benignly (worst case: one extra reload, or one deferred to the next
    /// changed scan).
    var scanCycleMadeChanges = false
    /// Revocation epoch for work that suspends outside this actor. A wipe
    /// increments it before clearing anything; older work may not persist
    /// cache entries or reconcile PlannedTrip rows afterward.
    var calendarDataEpoch: UInt64 = 0
    var geocoderAuthority = ForwardGeocoder.RequestAuthority()
    /// A change notification landed while a scan was in flight — the
    /// finishing scan re-runs once instead of dropping it.
    private var needsRescan = false

    /// Single-flight guard for the foreground scan. The BG
    /// variant (`scanUpcomingTripsUngated`) deliberately does NOT share it:
    /// that path is temporally isolated and cancellation-driven.
    private var scanInFlight = false
    /// Actor-local single-flight guard while the revocation cleanup awaits the
    /// shared mutation gate.
    private var revocationCleanupInFlight = false
    /// Foreground throttle state for `scanUpcomingTripsIfDue`. The flag starts
    /// set so the first scan of each process always runs.
    private var lastScanCompletedAt: Date?
    private var storeChangedSinceScan = true
    #if DEBUG
    private(set) var scanCountForTesting = 0
    #endif

    /// An `.upcoming` row whose dates passed without a matching real `Trip`
    /// flips to `.expired` after this grace (trips assemble from pings with
    /// some lag — don't expire while the match could still form).
    static let expiryGraceSeconds: TimeInterval = 2 * 24 * 60 * 60

    /// Persisted titles are truncated to this length (raw notes never
    /// persist at all).
    static let maxPersistedTitleLength = 200

    /// Debounce for `.EKEventStoreChanged` bursts — verbatim reuse of
    /// `PhotoService.changeDebounceTask`'s idiom (Exchange/Google CalDAV
    /// sync can burst several notifications for one logical change).
    private static let changeDebounceNanoseconds: UInt64 = 300_000_000

    private var changeObserverToken: (any NSObjectProtocol)?
    private var changeDebounceTask: Task<Void, Never>?

    /// Foreground/reactive scan entry point. EventKit reads and detection
    /// scoring run OUTSIDE the gate; only the store reconciliation holds it
    /// (the `enrichOpportunistically` shape). Gate discipline lives
    /// INSIDE — do NOT wrap calls in `PipelineGate.run` (non-reentrant;
    /// nested unit would deadlock).
    ///
    /// Self-guarding: exits immediately without read access. Safe to spam.
    func scanUpcomingTrips() async {
        #if DEBUG
        scanCountForTesting += 1
        #endif
        guard Self.hasReadAccess else {
            await cleanFuturePlannedTripsAfterRevocationIfNeeded()
            return
        }
        recordReadAccessObservation()
        // Single-flight (same idiom as `WeatherEnricher.passInFlight`): the
        // check-and-set is synchronous — no `await` before it — so actor
        // reentrancy cannot interleave two scans. Overlapping foreground
        // scans would run duplicate MKLocalSearch/FM/forecast work and
        // clobber each other's `scanCycleMadeChanges`, making the
        // widget-reload decision non-deterministic.
        guard !scanInFlight else {
            // An EKEventStoreChanged debounce that fires mid-scan would
            // otherwise be swallowed whole — the in-flight scan already
            // collected its detections, so the new change would go
            // unreconciled until the next unrelated trigger. Remember it;
            // the in-flight scan re-runs below.
            needsRescan = true
            return
        }
        scanInFlight = true
        defer { scanInFlight = false }
        // A reconcile that could not complete must not stamp the activation
        // throttle, or the retry waits out the interval.
        var everyReconcileApplied = true
        repeat {
            needsRescan = false
            let now = Date.now
            let expectedEpoch = calendarDataEpoch
            scanCycleMadeChanges = false
            // Resolve the selection once per collection. An explicit
            // selection with no live calendar is not an empty calendar: the
            // stale sweep would delete this user's (and other devices')
            // upcoming rows on no evidence, so skip reconcile and forecasts.
            let selection = resolveCalendarScope()
            guard selection.scope != .noneAvailable else {
                logger.info("Calendar selection has no available calendar; skipping this scan.")
                continue
            }
            runThinHistoryProbeIfNeeded(now: now)
            let analysis = await collectDetections(
                now: now, calendars: selection.calendars,
                allowFMTieBreaker: true,
                allowNetworkResolution: true,
                expectedEpoch: expectedEpoch
            )
            guard expectedEpoch == calendarDataEpoch,
                  !Task.isCancelled else { return }
            // An incomplete analysis is no evidence about any row: skip the
            // reconcile and leave the activation throttle due for a retry.
            var applied = false
            if analysis.isComplete {
                applied = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) { [weak self] in
                    await self?.applyScan(
                        detections: analysis.detections,
                        rejectedGeocodes: analysis.rejectedGeocodes,
                        deferredGroundingSnapshots: analysis.deferredGroundingSnapshots,
                        now: now,
                        expectedEpoch: expectedEpoch
                    ) ?? false
                }
            }
            if !applied { everyReconcileApplied = false }
            guard expectedEpoch == calendarDataEpoch else { return }
            await refreshForecastsIfNeeded(
                now: now, expectedEpoch: expectedEpoch)
            // Keep the Upcoming Trip widget in step with fresh detections — but
            // only when this cycle actually persisted something: a reload spawns
            // the widget extension, and foreground scans fire on every
            // scenePhase transition, which made no-change scans burn WidgetKit
            // budget for nothing. (The BG path is covered by the refresh
            // handler's existing reloadAll.)
            if scanCycleMadeChanges {
                WidgetCenter.shared.reloadTimelines(ofKind: "UpcomingTripWidget")
            }
        } while needsRescan
        if everyReconcileApplied {
            recordCompletedScan(at: .now)
        } else {
            storeChangedSinceScan = true
        }
    }

    /// Activation entry point: skips the scan when no calendar change was
    /// observed and the last completed pass is recent. Without read access
    /// it always runs, so a revocation's cleanup is never throttled. Other
    /// triggers call `scanUpcomingTrips()` directly.
    func scanUpcomingTripsIfDue(minInterval: TimeInterval = 30 * 60, now: Date = .now) async {
        guard Self.activationScanIsDue(
            hasReadAccess: Self.hasReadAccess, storeChangedSinceScan: storeChangedSinceScan,
            lastScanCompletedAt: lastScanCompletedAt, now: now, minInterval: minInterval
        ) else { return }
        await scanUpcomingTrips()
    }

    /// The activation throttle rule (test seam).
    nonisolated static func activationScanIsDue(
        hasReadAccess: Bool, storeChangedSinceScan: Bool,
        lastScanCompletedAt: Date?, now: Date, minInterval: TimeInterval
    ) -> Bool {
        guard hasReadAccess, !storeChangedSinceScan, let lastScanCompletedAt else { return true }
        return now.timeIntervalSince(lastScanCompletedAt) >= minInterval
    }

    private func recordCompletedScan(at date: Date) {
        lastScanCompletedAt = date
        storeChangedSinceScan = false
    }

    #if DEBUG
    func recordCompletedScanForTesting(at date: Date) {
        recordCompletedScan(at: date)
    }

    /// The throttle decision over the actor's real state, with read access assumed.
    func activationScanIsDueForTesting(now: Date, minInterval: TimeInterval = 30 * 60) -> Bool {
        Self.activationScanIsDue(
            hasReadAccess: true, storeChangedSinceScan: storeChangedSinceScan,
            lastScanCompletedAt: lastScanCompletedAt, now: now, minInterval: minInterval)
    }

    /// Runs the real change handler, then cancels its debounced rescan so
    /// only the throttle flag is observed.
    func simulateStoreChangeForTesting() {
        storeDidChange()
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
    }
    #endif

    /// BG-refresh variant: the SCAN is ungated, the reconcile is not.
    ///
    /// The expensive part — EventKit enumeration and detection — runs outside
    /// the gate so a BG-refresh expiration doesn't find this work QUEUED
    /// behind an unrelated unit, burning the handler's budget waiting rather
    /// than doing.
    ///
    /// The `applyScan` write, however, takes its own small gate unit: the
    /// CloudKit push handler runs `PlannedTripDeduplicator` inside the gate on
    /// a separate context, deleting and rewriting exactly these rows, and a
    /// gate only serializes its own participants. The unit is store-local and
    /// fast, so it cannot starve a background wake-ping save; losing
    /// cancellation granularity for the duration of one local reconcile is the
    /// cheaper trade.
    func scanUpcomingTripsUngated() async {
        guard Self.hasReadAccess else {
            await cleanFuturePlannedTripsAfterRevocationIfNeeded()
            return
        }
        recordReadAccessObservation()
        let now = Date.now
        let expectedEpoch = calendarDataEpoch
        // Same rule as the foreground scan: no reconcile off a selection
        // that resolves to no calendar.
        let selection = resolveCalendarScope()
        guard selection.scope != .noneAvailable else { return }
        let analysis = await collectDetections(
            now: now, calendars: selection.calendars,
            allowFMTieBreaker: false,
            allowNetworkResolution: false,
            expectedEpoch: expectedEpoch
        )
        // A BG-refresh expiration cancels the handler's pipeline Task while
        // this scan may be mid-flight. Don't reconcile off a partially
        // resolved detection set — the next scan (foreground or BG) redoes
        // the whole thing, and applyScan's stale-grace means skipped rows
        // are never swept for it.
        guard !Task.isCancelled,
              expectedEpoch == calendarDataEpoch,
              analysis.isComplete else { return }
        // Gated reconcile: see the doc above.
        await PipelineGate.shared.run(touching: [.plannedTrip]) { [weak self] in
            await self?.applyScan(
                detections: analysis.detections,
                rejectedGeocodes: analysis.rejectedGeocodes,
                deferredGroundingSnapshots: analysis.deferredGroundingSnapshots,
                now: now,
                expectedEpoch: expectedEpoch
            )
        }
        // NO forecast pass and NO Tier-2 forward geocoding here,
        // deliberately: both make network calls (WeatherKit / MKLocalSearch
        // at a 2 s throttle — up to ~50 s for a cold 25-event budget), which
        // is wrong for the ~30 s BG-refresh budget/cancellation model this
        // ungated variant exists for. Foreground scans (frequent) own
        // forecasts and network resolution; the offline Tier-1 probe and the
        // persistent cache still apply here for free. Same reasoning
        // excludes the FM tie-breaker: NPU calls don't belong in the
        // BG-refresh budget either. (Already-cached judgment verdicts still
        // apply — reusing them costs nothing.)
    }

    // One schedule covers detections and near-misses sharing the quotas.
    // Resume at the first event denied enabled work, while still checking
    // later cache hits. No miss, event text or outcome is persisted here.
    var scanWorkCursor = 0

    /// In-memory copy of the persisted cache — the actor-state source of
    /// truth, lazily hydrated from UserDefaults. Held as actor state (not
    /// re-read per scan) so `deleteAllCalendarData` can empty what an
    /// in-flight scan will persist at its end: a scan suspends for tens of
    /// seconds across its geocode/FM awaits, and a plain local copy would
    /// write the just-wiped cache straight back — the exact hazard
    /// `ForwardGeocoder.clearCache` exists for. Resurrecting derived calendar
    /// data would break the "Delete Calendar Data" promise.
    var judgmentCacheStorage: [String: CachedJudgment]?

    #if DEBUG
    // Instance-scoped so parallel calendar suites cannot see each other's fault.
    nonisolated(unsafe) var failTripCandidateFetchForTesting = false
    var failNextScanSaveForTesting = false

    func failNextScanSave() {
        failNextScanSaveForTesting = true
    }
    #endif

    /// In-memory failure backoff for forecast fetches —
    /// ephemeral by design, like `WeatherEnricher.failedFetchAt`: cleared on
    /// relaunch, an acceptable cadence for a fresh attempt.
    var failedForecastAt: [UUID: Date] = [:]
    // MARK: - Delete calendar-derived data

    nonisolated struct CalendarDataDeletionResult: Sendable, Equatable {
        let succeeded: Bool
        let deletedCount: Int
    }

    /// Pure revocation decision seam. Existing calendar rows cover upgrades
    /// from builds that predate the observed-grant latch. A `.notDetermined`
    /// device never read Calendar, so rows it holds arrived by CloudKit sync
    /// from another device and are not its own detections to clean.
    nonisolated static func shouldCleanAfterRevocation(
        previouslyGranted: Bool,
        hasCalendarRows: Bool,
        authorizationDetermined: Bool,
        cleanupAlreadyCompleted: Bool
    ) -> Bool {
        !cleanupAlreadyCompleted
            && (previouslyGranted || (hasCalendarRows && authorizationDetermined))
    }

    /// A trip that starts exactly at `now` has begun and is not revocation
    /// cleanup material.
    nonisolated static func isNotYetStarted(startDate: Date, now: Date) -> Bool {
        startDate > now
    }

    private nonisolated enum PlannedTripDeletionScope: Sendable {
        case all
        case notYetStarted(Date)
    }

    private func recordReadAccessObservation() {
        let defaults = Self.defaults
        if !defaults.bool(forKey: Self.readAccessObservedKey) {
            defaults.set(true, forKey: Self.readAccessObservedKey)
        }
        defaults.removeObject(forKey: Self.revocationCleanupCompletedKey)
    }

    /// Removes future Calendar detections once when a previously available
    /// calendar becomes unreadable. Historical PlannedTrip rows, real trips,
    /// generated titles, calendar selection, and caches are intentionally left
    /// untouched.
    private func cleanFuturePlannedTripsAfterRevocationIfNeeded() async {
        guard !revocationCleanupInFlight else { return }

        let defaults = Self.defaults
        let determined = Self.authorizationStatus != .notDetermined
        let hasRows = determined && ((try? modelContext.fetchCount(
            FetchDescriptor<PlannedTrip>())) ?? 0) > 0
        guard Self.shouldCleanAfterRevocation(
            previouslyGranted: defaults.bool(forKey: Self.readAccessObservedKey),
            hasCalendarRows: hasRows,
            authorizationDetermined: determined,
            cleanupAlreadyCompleted: defaults.bool(
                forKey: Self.revocationCleanupCompletedKey)
        ) else { return }

        revocationCleanupInFlight = true
        beginCalendarDataRevocation()
        let now = Date.now
        let result = await PipelineGate.shared.runReturning(
            touching: [.plannedTrip]
        ) {
            await self.deletePlannedTripRows(scope: .notYetStarted(now))
        }
        revocationCleanupInFlight = false

        guard result.succeeded else { return }
        defaults.set(true, forKey: Self.revocationCleanupCompletedKey)
        if result.deletedCount > 0 {
            WidgetCenter.shared.reloadTimelines(ofKind: "UpcomingTripWidget")
        }
    }

    /// Starts a Calendar privacy revocation before any store/cache phase.
    /// Both Delete Calendar Data and Delete Everything use this same barrier,
    /// so work already suspended in EventKit/FM/WeatherKit cannot repopulate
    /// data after either wipe.
    func beginCalendarDataRevocation() {
        geocoderAuthority.revoke()
        geocoderAuthority = ForwardGeocoder.RequestAuthority()
        calendarDataEpoch &+= 1
        needsRescan = false
        storeChangedSinceScan = true
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
    }

    func classificationRequestAuthority() -> ForwardGeocoder.RequestAuthority { geocoderAuthority }

    /// Deletes every `PlannedTrip` row and the calendar-derived UserDefaults
    /// crumbs (thin-history probe state and forward-geocode cache). The user's
    /// `selectedCalendarIDs` preference is deliberately preserved so a later
    /// scan keeps the same consent scope. Underlying `Trip`/`Stay` data — which
    /// came from real location pings, never calendar text — is untouched here;
    /// the caller clears AI titles separately (titles are the one surface
    /// calendar context can have influenced, and they regenerate from stays
    /// alone when Calendar access is revoked). Store mutation only — the
    /// caller wraps it in a `PipelineGate` unit.
    func deleteAllCalendarData() async -> CalendarDataDeletionResult {
        beginCalendarDataRevocation()
        let result = deletePlannedTripRows(scope: .all)
        guard result.succeeded else { return result }
        StatsSnapshotStore.clear()

        Self.clearThinHistoryProbeState(in: Self.defaults)
        // Preserve the user's calendar scope. An absent/empty selection means
        // “scan every calendar,” so deleting this preference would silently
        // widen future reads to calendars the user explicitly excluded.
        // Delete Calendar Data removes derived rows/caches, not consent scope.
        clearFMJudgmentCache()
        // Through the actor, NOT a bare removeObject: the geocoder's
        // in-memory copy would otherwise write the old cache right back.
        await ForwardGeocoder.shared.clearCache()

        logger.info("Deleted \(result.deletedCount) PlannedTrip row(s) and calendar preferences.")
        return result
    }

    /// Shared SwiftData delete/save/rollback path for manual deletion and the
    /// narrower automatic revocation cleanup.
    private func deletePlannedTripRows(
        scope: PlannedTripDeletionScope
    ) -> CalendarDataDeletionResult {
        do {
            let allRows = try modelContext.fetch(FetchDescriptor<PlannedTrip>())
            let rows: [PlannedTrip]
            switch scope {
            case .all:
                rows = allRows
            case .notYetStarted(let now):
                rows = allRows.filter {
                    Self.isNotYetStarted(startDate: $0.startDate, now: now)
                }
            }
            for row in rows {
                modelContext.delete(row)
            }
            #if DEBUG
            if failNextCalendarDataDeleteForTesting {
                failNextCalendarDataDeleteForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            if !rows.isEmpty {
                try modelContext.save()
            }
            return CalendarDataDeletionResult(
                succeeded: true,
                deletedCount: rows.count)
        } catch {
            modelContext.rollback()
            logger.error("Calendar data deletion failed: \(error.localizedDescription)")
            return CalendarDataDeletionResult(succeeded: false, deletedCount: 0)
        }
    }

    #if DEBUG
    private var failNextCalendarDataDeleteForTesting = false

    func failNextCalendarDataDelete() {
        failNextCalendarDataDeleteForTesting = true
    }

    func calendarDataEpochForTesting() -> UInt64 {
        calendarDataEpoch
    }
    #endif

    // MARK: - `.EKEventStoreChanged` reactive scan

    /// Registers for calendar-database change notifications. Idempotent.
    /// The notification carries zero diff information — the only viable
    /// response is a debounced re-scan. Called from `AppDelegate` at launch
    /// when access already exists, and from Settings right after a grant.
    func startObservingStoreChanges() {
        guard Self.hasReadAccess, changeObserverToken == nil else { return }
        changeObserverToken = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.storeDidChange() }
        }
        logger.info("Observing EKEventStoreChanged.")
    }

    private func storeDidChange() {
        storeChangedSinceScan = true
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.changeDebounceNanoseconds)
            await self?.runDebouncedScan()
        }
    }

    /// The elapsed debounce hands its scan off before awaiting it: a later
    /// notification then cancels only its own timer and, finding the scan in
    /// flight, queues the rescan this scan runs. Cancelling the scan instead
    /// would drop that rescan. Checked on the actor, so no notification can
    /// land between the check and the hand-off.
    private func runDebouncedScan() async {
        guard !Task.isCancelled else { return }
        changeDebounceTask = nil
        await scanUpcomingTrips()
    }
}

// MARK: - CalendarEventSnapshot

/// An immutable, `Sendable` copy of one `EKEvent` instance — the only shape
/// of calendar data allowed to cross out of `CalendarEnricher`'s isolation
/// domain. Detection/scoring/matching logic is written as pure functions over
/// these, which keeps it unit-testable without an `EKEventStore`.
nonisolated struct CalendarEventSnapshot: Sendable, Equatable {
    /// `calendarItemExternalIdentifier` — cross-device-durable for synced
    /// accounts (tracks the server-side UID); preferred dedup key. Not
    /// contractually guaranteed stable, hence always paired with a fallback.
    let externalIdentifier: String?

    /// `eventIdentifier` — per-device key; shared across a recurring event's
    /// non-detached occurrences, so identity is `(localIdentifier, startDate)`.
    let localIdentifier: String

    let title: String

    /// In-memory only — scanned for keyword signals, NEVER persisted
    /// (routinely contains third-party PII). See `CalendarEnricher`'s doc.
    let notes: String?

    /// Raw `EKEvent.location` free-form text (city, address, venue, URL, …).
    let locationText: String?

    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    /// True on every expanded occurrence of a recurring event.
    let hasRecurrenceRules: Bool

    /// True only for an occurrence the user individually edited.
    let isDetached: Bool

    let calendarTitle: String
    let calendarKind: CalendarKind

    init(
        externalIdentifier: String?,
        localIdentifier: String,
        title: String,
        notes: String?,
        locationText: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        hasRecurrenceRules: Bool,
        isDetached: Bool,
        calendarTitle: String,
        calendarKind: CalendarKind
    ) {
        self.externalIdentifier = externalIdentifier
        self.localIdentifier = localIdentifier
        self.title = title
        self.notes = notes
        self.locationText = locationText
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.hasRecurrenceRules = hasRecurrenceRules
        self.isDetached = isDetached
        self.calendarTitle = calendarTitle
        self.calendarKind = calendarKind
    }

    /// Adapter from a raw `EKEvent`. Fails (returns nil) for events without
    /// an `eventIdentifier` or dates — never observed for store-fetched
    /// events, but both properties are implicitly-unwrapped optionals and a
    /// trap here would take down a whole scan.
    init?(event: EKEvent) {
        guard
            let localIdentifier = event.eventIdentifier,
            let startDate = event.startDate,
            let endDate = event.endDate
        else { return nil }

        self.init(
            externalIdentifier: event.calendarItemExternalIdentifier,
            localIdentifier: localIdentifier,
            title: event.title ?? "",
            notes: event.notes,
            locationText: event.location,
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            hasRecurrenceRules: event.hasRecurrenceRules,
            isDetached: event.isDetached,
            calendarTitle: event.calendar?.title ?? "",
            calendarKind: CalendarKind(calendar: event.calendar)
        )
    }
}

// MARK: - CalendarKind

/// Coarse provenance of a calendar, for detection weighting (`.birthday` is
/// dropped outright; `.subscribed` is heavily de-weighted).
///
/// Note: EventKit has no "iCloud" calendar type — iCloud calendars are
/// `.calDAV` and are told apart from other CalDAV accounts (Google, Fastmail)
/// by their `EKSource`'s title, which iOS fixes to "iCloud".
nonisolated enum CalendarKind: String, Codable, Sendable {
    case local      = "local"
    case icloud     = "icloud"
    case exchange   = "exchange"
    case caldav     = "caldav"
    case subscribed = "subscribed"
    case birthday   = "birthday"
    case other      = "other"
}

nonisolated extension CalendarKind {
    init(calendar: EKCalendar?) {
        guard let calendar else {
            self = .other
            return
        }
        switch calendar.type {
        case .local:
            self = .local
        case .exchange:
            self = .exchange
        case .subscription:
            self = .subscribed
        case .birthday:
            self = .birthday
        case .calDAV:
            self = calendar.source?.title == "iCloud" ? .icloud : .caldav
        @unknown default:
            self = .other
        }
    }
}
