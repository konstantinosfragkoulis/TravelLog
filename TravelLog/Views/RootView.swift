//
//  RootView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import SwiftUI
import SwiftData
import UIKit
import CoreLocation
import Photos
import UserNotifications

/// The root view that decides whether to show onboarding or the main app.
///
/// Onboarding is shown if:
/// - No Home record exists (user hasn't completed setup)
///
/// Once onboarding completes, the main tab view is shown.
///
/// When there's a recoverable `PhotoImportState`
/// (paused, running > 7-day-stale auto-cancellation handled in AppDelegate,
/// or failed), a banner appears above `MainTabView` via
/// `.safeAreaInset(edge: .top)`. Banner offers `[Resume] [Discard]` for
/// resumable states and `[Try Again] [Dismiss]` for failure. Dismissal
/// persists the state-row ID into `@AppStorage` so the banner stays
/// hidden until a *new* state row (different UUID) appears.
struct RootView: View {

    @Query private var homes: [Home]
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \PhotoImportState.startedAt, order: .forward)
    private var importStates: [PhotoImportState]

    /// V11: all generated YearWrapped entries. Used to look up the requested
    /// year when `WrappedPresenter.shared.requestedYear` is set.
    @Query private var wrappedEntries: [YearWrapped]

    /// V11: shared cross-tab/notification signal for presenting Wrapped.
    /// Set by the notification delegate (on tap), by Settings → Memories,
    /// or by the "Wrapped is ready" banner.
    private var wrappedPresenter = WrappedPresenter.shared

    /// The "session" the user has explicitly dismissed, keyed as
    /// `"{state.id}|{state.startedAt}"`. The composite key matters because
    /// `PhotoImportService.start()` upserts the existing state row (same
    /// UUID, fresh `startedAt`) for a brand-new import — keying on UUID
    /// alone would leave the banner permanently hidden after one dismiss
    /// even for genuinely new sessions whose results the user hasn't
    /// seen. Including `startedAt` resets the dismissed state implicitly
    /// every new `start()`.
    @AppStorage("photoImportBannerDismissedSessionKey")
    private var dismissedKey: String = ""

    /// Heuristic threshold: `.running` rows with `lastUpdated` newer
    /// than this are assumed to be actively in-flight, and the banner
    /// stays hidden (Settings is the right UI). Older `.running` rows
    /// suggest a force-quit / crashed session that needs explicit
    /// recovery via the banner. 60s comfortably exceeds the typical
    /// per-batch interval (a few seconds) so an alive import won't
    /// trip this. Stale-detection is a UX hint, not a contract — the
    /// 7-day rule in `handleStaleStateOnLaunch` is the hard backstop.
    private static let runningStaleThreshold: TimeInterval = 60

    /// Best-effort device identity for the cross-device import guard —
    /// same source as `SettingsView.thisDeviceID`.
    private static let thisDeviceID: String =
        UIDevice.current.identifierForVendor?.uuidString ?? ""

    /// Tracking-warning banner state. `dismissed` is deliberately plain
    /// `@State` — NOT persisted — so a user who hasn't granted "Always" is
    /// re-informed on every process launch (silent non-tracking is the app's
    /// worst failure mode; once per launch is the agreed nag level). Defaults
    /// to `.authorizedAlways` so the healthy case never flashes a banner during
    /// the first frame; the real value arrives from the `.task` read plus the
    /// LocationService delegate notification.
    @State private var trackingBannerDismissed = false
    @State private var locationAuthStatus: CLAuthorizationStatus = .authorizedAlways

    /// Handles for the six activation-triggered background jobs, retained so
    /// leaving `.active` cancels them: rapid active/inactive cycling must not
    /// stack duplicates, and a foreground-started job must not keep running
    /// (and queueing gate units) after the app backgrounds. Every job is
    /// idempotent and self-guarding, so a cancelled-then-respawned job
    /// re-does at most what it would have anyway.
    @State private var activationTasks: [Task<Void, Never>] = []

    var body: some View {
        if onboardingComplete && !AppDelegate.containerMode.isPersistent {
            StorageUnavailableView()
        } else if onboardingComplete && !homes.isEmpty {
            MainTabView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if locationAuthStatus != .authorizedAlways && !trackingBannerDismissed {
                            TrackingWarningBanner(
                                status: locationAuthStatus,
                                onDismiss: { trackingBannerDismissed = true }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if let banner = currentBanner {
                            PhotoImportRecoveryBanner(
                                kind: banner.kind,
                                onDismiss: { dismissedKey = banner.sessionKey }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: currentBanner?.sessionKey)
                .animation(.easeInOut(duration: 0.25), value: trackingBannerDismissed)
                // Every-launch "not tracking" warning: outside onboarding,
                // the only other surface that says anything about a missing
                // "Always" grant is the Settings status dashboard — a user
                // who chose "While Using" could miss that recording is
                // foreground-only, while a denied user could believe
                // recording continues.
                // The banner re-arms per launch
                // (@State), updates live from the LocationService
                // delegate, and re-reads on foregrounding in case the
                // grant changed in Settings.app.
                .task {
                    refreshLocationStatus(LocationService.shared.authorizationStatus)
                }
                .onReceive(NotificationCenter.default.publisher(for: .locationAuthorizationChanged)) { notification in
                    if let rawValue = notification.userInfo?["status"] as? Int32,
                       let newStatus = CLAuthorizationStatus(rawValue: rawValue) {
                        refreshLocationStatus(newStatus)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    refreshLocationStatus(LocationService.shared.authorizationStatus)
                }
                // Each activation drains the ungeocoded-ping backlog; see
                // `triggerForegroundGeocodingRetry`.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase != .active {
                        ForegroundLocationStreamController.shared
                            .applicationWillResignActive()
                    }
                    // Leaving `.active` (or re-entering it) cancels the
                    // previous batch of activation jobs first — see
                    // `activationTasks`.
                    activationTasks.forEach { $0.cancel() }
                    activationTasks = []
                    if newPhase == .active {
                        ForegroundLocationStreamController.shared
                            .applicationDidBecomeActive()
                        StoreChangeTracker.shared.applicationDidBecomeActive()
                        activationTasks = [
                            Task { await reconcileAuthorizationStatuses() },
                            triggerForegroundGeocodingRetry(),
                            triggerOpportunisticWeather(),
                            triggerCalendarScan(),
                            triggerFMCapabilityRecording(),
                            triggerHomeAreaHealing(),
                        ]
                    } else if newPhase == .background {
                        // Reclaim the ~4-8 MB whole-world country-polygon cache
                        // when the app backgrounds — the globe isn't on screen,
                        // and it re-parses lazily on the next Stats open.
                        // GlobeView keeps its visited subset, so no gap.
                        CountryPolygonProvider.releaseCache()
                    }
                }
                // Launch-path FM-capability latch. `onChange` does
                // not fire for the initial `.active` value the view is born
                // with, so a device restored from a non-FM phone's backup
                // straight onto an FM phone would otherwise only arm the
                // upgrade experience after a background→foreground cycle. This
                // `.task` runs once on first appearance; `recordCurrentState`
                // is cheap + idempotent, so overlapping with the staggered
                // scenePhase call is harmless (the latch is one-shot).
                .task {
                    FMCapability.recordCurrentState()
                    await reconcileAuthorizationStatuses()
                    // Cold-launch parity: the same
                    // initial-`.active` blind spot applies to the
                    // periodic activation jobs above — on a fresh launch
                    // they'd otherwise wait for the first background→
                    // foreground cycle. All are staggered, throttled, and
                    // self-guarding, so overlap with a later real scenePhase
                    // trigger is harmless; the batch joins `activationTasks`
                    // so the same cancel discipline still owns it.
                    if scenePhase == .active {
                        ForegroundLocationStreamController.shared
                            .applicationDidBecomeActive()
                        StoreChangeTracker.shared.applicationDidBecomeActive()
                        activationTasks += [
                            triggerForegroundGeocodingRetry(),
                            triggerOpportunisticWeather(),
                            triggerCalendarScan(),
                            triggerHomeAreaHealing(),
                        ]
                    }
                }
                .fullScreenCover(
                    isPresented: Binding(
                        get: { wrappedPresenter.requestedYear != nil },
                        set: { if !$0 { wrappedPresenter.clear() } }
                    )
                ) {
                    if let year = wrappedPresenter.requestedYear,
                       let wrapped = wrappedEntries.first(where: { $0.year == year }) {
                        WrappedView(wrapped: wrapped) {
                            wrappedPresenter.clear()
                        }
                        // Re-key on the row id: if
                        // the deduplicator swaps the presented row for a
                        // same-year survivor while the cover is open, this
                        // tears the view down and rebuilds it from the
                        // survivor's snapshot, so pager and reveal state
                        // can't straddle two rows. Same-row content changes
                        // (dedup absorption, the calendar privacy scrub)
                        // keep the view and flow in through `init`.
                        .id(wrapped.id)
                    } else {
                        // Edge case: requested year doesn't exist yet (e.g.,
                        // notification tapped before generation completes).
                        // Show a loading state; AppDelegate's didReceive handler
                        // triggers generation in parallel, which will populate
                        // the @Query and re-render this sheet.
                        WrappedLoadingView(
                            year: wrappedPresenter.requestedYear,
                            failure: wrappedPresenter.preparationFailure
                        ) {
                            wrappedPresenter.clear()
                        }
                    }
                }
        } else {
            OnboardingView()
        }
    }

    private func reconcileAuthorizationStatuses() async {
        PhotoService.shared.refreshAuthorizationStatus()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        NotificationService.enableDefaultFeaturesIfAuthorized(
            settings.authorizationStatus)
        // The grant lookup is a synchronous EventKit XPC: keep it off main.
        if await Task.detached(operation: { CalendarEnricher.hasReadAccess }).value {
            await AppDelegate.calendarEnricher.startObservingStoreChanges()
        }
    }

    /// Single funnel for every tracking-banner status read. Besides
    /// updating the banner, it STARTS monitoring when the status is (or
    /// has just become) "Always" — the codebase's only other
    /// `startMonitoring()` callers are the app-launch path and
    /// onboarding completion, and location-permission changes do NOT
    /// relaunch the app (unlike Photos). Without this, a user who
    /// followed the banner to Settings and granted "Always" returned to
    /// an app whose banner vanished but whose SLC registration never
    /// happened this process — zero pings until the next cold launch.
    /// `startMonitoring` is idempotent
    /// and self-guarding, so the `isMonitoring` check is just noise
    /// avoidance.
    private func refreshLocationStatus(_ status: CLAuthorizationStatus) {
        if locationAuthStatus != status {
            trackingBannerDismissed = false
        }
        locationAuthStatus = status
        if status == .authorizedAlways && !LocationService.shared.isMonitoring {
            LocationService.shared.startMonitoring()
        }
    }

    /// Fire-and-forget detached task that drains the ungeocoded-ping
    /// backlog via the offline resolver. Cheap to spawn; the `IfNeeded`
    /// variant compares a backlog token (ungeocoded count + newest timestamp
    /// + incomplete hex counts + locality-nil stay cells) and skips the whole
    /// pass, the per-hex scans for permanently-unresolvable hexes included,
    /// when nothing changed since the last completed drain this launch; a
    /// stay-only change runs only the stay phase.
    private func triggerForegroundGeocodingRetry() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // De-clump from the cold-launch peak. These activation triggers all
            // funnel through the serial `PipelineGate`, so submitting them at
            // t=0 makes the gate chew through the backlog drain + weather fill
            // back-to-back right as first paint + the Trips pipeline are
            // competing for cores. Staggered delays spread the submissions out
            // (lower peak, slightly longer tail — same total work, which is
            // fine: it's all one-time, gated, and `.background`). The drain
            // itself is still self-guarding and its first-launch run is
            // preserved (just shifted a few seconds). A thrown
            // CancellationError means the app left `.active` (or a fresh
            // activation superseded this batch) — bail instead of swallowing
            // it.
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            // Gate discipline lives INSIDE the drain: it acquires
            // `PipelineGate` per bounded chunk, so an SLC wake-ping save
            // interleaves between chunks instead of queueing behind a
            // minutes-long post-import drain. Do NOT wrap this call in
            // PipelineGate.run — the gate is non-reentrant and the nested unit
            // would deadlock. Serialization with the cluster/classify pipeline
            // is preserved per chunk.
            await AppDelegate.pingRecorder.retryAllFailedGeocodingIfNeeded()
        }
    }

    /// Fire-and-forget daily-budgeted weather fill — closes the lazy-load
    /// coverage hole behind the passport/Wrapped hottest/coldest stats.
    /// Self-guarding: `enrichOpportunistically` exits immediately when the
    /// day's WeatherKit budget is spent or nothing needs enrichment.
    private func triggerOpportunisticWeather() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // Staggered last (see above). Weather is already the most
            // self-throttling trigger (daily WeatherKit budget), so it
            // tolerates the longest delay without any user-visible effect.
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            // Gate discipline lives INSIDE enrichOpportunistically: it plans
            // candidates in one PipelineGate unit, runs the WeatherKit calls
            // outside the gate, and applies results in a second unit — so a
            // background SLC wake's ping save is never queued behind tens of
            // seconds of network I/O. Do NOT wrap this call in
            // PipelineGate.run: the gate is non-reentrant and the nested unit
            // would deadlock.
            await AppDelegate.weatherEnricher.enrichOpportunistically()
        }
    }

    /// Fire-and-forget calendar scan for the future lane (planned-trip
    /// detection). Self-guarding: `scanUpcomingTrips` exits immediately when
    /// Calendar access is missing, so spamming this hook is harmless.
    private func triggerCalendarScan() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // Staggered behind geocoding/weather — the
            // scan is a local EventKit query + a small reconcile, but there's
            // no reason for it to compete with first paint either.
            do { try await Task.sleep(for: .seconds(13)) } catch { return }
            // Gate discipline lives INSIDE scanUpcomingTrips (only the store
            // reconcile holds the gate; the EventKit read runs outside). Do
            // NOT wrap this call in PipelineGate.run — the gate is
            // non-reentrant and the nested unit would deadlock. Skipped
            // when nothing changed since a recent completed pass.
            await AppDelegate.calendarEnricher.scanUpcomingTripsIfDue()
        }
    }

    /// Fire-and-forget FM-capability transition check. Classifies
    /// the current Foundation Models availability, persists it device-locally,
    /// and latches the unavailable to available transition (arming the
    /// healing + upgrade affordances). Self-guarding: `recordCurrentState`
    /// only latches once per device and simply overwrites the stored raw
    /// state otherwise, so spamming this hook is harmless.
    private func triggerFMCapabilityRecording() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // Staggered last of all — a UserDefaults read +
            // an availability classify is the cheapest of the activation
            // triggers, so it yields to first paint and the pipeline drains.
            // No PipelineGate involvement: this touches only UserDefaults.
            do { try await Task.sleep(for: .seconds(16)) } catch { return }
            FMCapability.recordCurrentState()
        }
    }

    /// Fire-and-forget home-area healing check, after any owed
    /// coverage reconciliation.
    /// The fingerprint covers user overrides AND the derived orbit-disc
    /// set, so this catches the case no UI action can: a disc that qualified
    /// (or expired) purely from newly-accreted evidence since the last
    /// launch. Self-guarding: `healIfNeeded` is a string compare when
    /// nothing moved, and healing itself is idempotent.
    private func triggerHomeAreaHealing() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // Staggered behind the initial pipeline pass so the
            // prime derives orbits from settled stays, not mid-pass state.
            do { try await Task.sleep(for: .seconds(19)) } catch { return }
            // Owed Home / routine coverage reconciliations go first, as in
            // Settings: healing must judge the reconciled stays.
            await CoverageReconciliationQueue.drainIfNeeded()
            await HomeAreaHealing.healIfNeeded()
        }
    }

    /// Resolve which banner (if any) should render. Returns nil when:
    ///   - no `PhotoImportState` row exists, or
    ///   - the row is `.idle` / `.completed` / `.cancelled`, or
    ///   - the row is `.running` with fresh `lastUpdated` (assumed
    ///     actively in-flight; Settings shows progress, no banner
    ///     needed), or
    ///   - the user already dismissed this specific session.
    private var currentBanner: (kind: BannerKind, sessionKey: String)? {
        // Use the oldest state row (matches the deduplicator's "keep
        // oldest" rule — see PhotoImportStateDeduplicator). After dedup
        // there should only ever be one, but `.first` is the right
        // pick pre-dedup too.
        guard let state = importStates.first else { return nil }
        let key = Self.sessionKey(for: state)
        if key == dismissedKey { return nil }
        switch state.status {
        case .running:
            // Cross-device guard (mirrors
            // SettingsView.isImportRunningOnAnotherDevice): a fresh `.running`
            // row synced from ANOTHER device must not offer Resume/Discard here
            // — acting on it would fight the import genuinely in flight over
            // there. 90 s = the stale threshold + CloudKit propagation slack;
            // past it, the origin device is presumed dead and local recovery is
            // legitimate.
            if !state.originDeviceID.isEmpty,
               state.originDeviceID != Self.thisDeviceID,
               Date().timeIntervalSince(state.lastUpdated) < 90 {
                return nil
            }
            // Stale-running heuristic: alive imports update lastUpdated
            // every batch (a few seconds). Anything > 60s stale on a
            // freshly-launched app is almost certainly force-quit /
            // crashed and needs explicit recovery.
            guard Date().timeIntervalSince(state.lastUpdated) > Self.runningStaleThreshold else {
                return nil
            }
            return (.resumable, key)
        case .paused:
            return (.resumable, key)
        case .failed:
            let message = state.lastError.map { photoImportLastErrorText($0) } ?? String(
                localized: "root.photo-import.error.unknown",
                defaultValue: "Unknown error",
                comment: "Fallback detail for a failed photo import with no recorded error."
            )
            return (.failed(message), key)
        case .idle, .completed, .cancelled:
            return nil
        }
    }

    /// Composite "session instance" key: `"{id.uuidString}|{startedAt}"`.
    /// Every fresh `PhotoImportService.start()` updates `startedAt`, so
    /// each new session produces a unique key even when the underlying
    /// `PhotoImportState` row is reused by `PhotoImportService.prepareNewState`.
    private static func sessionKey(for state: PhotoImportState) -> String {
        "\(state.id.uuidString)|\(state.startedAt.timeIntervalSince1970)"
    }
}

/// The two banner flavours produced by `RootView.currentBanner`.
enum BannerKind {
    case resumable
    case failed(String)
}

/// Returning users must never be routed into onboarding merely because the
/// emergency in-memory container is empty. Keep the failure explicit and
/// full-screen while the preserved on-disk store remains untouched.
private struct StorageUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(String(
                    localized: "root.storage-error.title",
                    defaultValue: "Travel Data Unavailable",
                    comment: "Full-screen title when Travel Log could not open persistent storage."
                ))
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark")
            }
        } description: {
            Text(String(
                localized: "root.storage-error.detail",
                defaultValue: "Your saved travel data is safe but unavailable for this session. Restart Travel Log or free up storage, then try again.",
                comment: "Full-screen explanation when the persistent store is preserved but unavailable for the current session."
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

/// Every-launch warning shown over MainTabView while location
/// authorization is anything other than "Always". When-In-Use records
/// one activation fix while the app is open but cannot run SLC in the
/// background; the remaining states cannot record. Dismissal lasts one
/// process launch by design.
private struct TrackingWarningBanner: View {
    let status: CLAuthorizationStatus
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText)
                    .font(.subheadline.bold())
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch status {
                case .restricted:
                    // Nothing the user can do — no false-hope button.
                    EmptyView()
                case .notDetermined:
                    // Reachable post-onboarding: "Allow Once" expires back
                    // to notDetermined. Settings has no toggle to offer in
                    // this state — the system prompt is the only path, and
                    // re-requesting is allowed here.
                    Button("Continue") {
                        LocationService.shared.requestWhenInUseAuthorization()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                default:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            if status != .notDetermined {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var headlineText: String {
        switch status {
        case .authorizedWhenInUse:
            return String(
                localized: "root.tracking-warning.when-in-use.title",
                defaultValue: "Trips are recorded only while the app is open",
                comment: "Tracking warning headline when location access is limited to while using the app."
            )
        default:
            return String(
                localized: "root.tracking-warning.title.not-recording",
                defaultValue: "Trips aren't being recorded",
                comment: "Tracking warning headline when location access does not allow trip recording."
            )
        }
    }

    private var detailText: String {
        switch status {
        case .authorizedWhenInUse:
            return String(
                localized: "root.tracking-warning.when-in-use.detail",
                defaultValue: "Choose “Always” in Settings → Travel Log → Location to enable background tracking.",
                comment: "Tracking warning instructions for enabling background tracking from while-using location access."
            )
        case .restricted:
            return String(
                localized: "root.tracking-warning.detail.restricted",
                defaultValue: "Location access is restricted on this device, possibly by parental controls or a management profile.",
                comment: "Tracking warning detail when location access is restricted by the device."
            )
        case .notDetermined:
            return String(
                localized: "root.tracking-warning.detail.not-determined",
                defaultValue: "Location access hasn't been set up, so Travel Log can't record your trips.",
                comment: "Tracking warning detail before the user has chosen a location permission."
            )
        default:
            // .denied covers both an app-level denial AND device-wide
            // Location Services being off — "check … make sure" phrasing
            // stays truthful for both (the app-specific Settings page
            // surfaces the global state too).
            return String(
                localized: "root.tracking-warning.detail.off",
                defaultValue: "Location access is off. Check Settings → Travel Log → Location and make sure it's set to “Always”.",
                comment: "Tracking warning instructions when location access is off."
            )
        }
    }
}

/// The recovery banner itself. Renders a translucent material strip
/// above the tab bar with one or two action buttons. Action handlers
/// are async and route through `AppDelegate.photoImportService`.
private struct PhotoImportRecoveryBanner: View {
    let kind: BannerKind
    let onDismiss: () -> Void

    @State private var isWorking = false
    @State private var showDiscardConfirmation = false
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var importErrorIsMissingPhotoPermission = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText)
                    .font(.subheadline.bold())
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    ForEach(Array(actionButtons.enumerated()), id: \.offset) { _, button in
                        button
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .disabled(isWorking)
        .alert("Discard import?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) { Task { await runDiscard() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All trips and stays reconstructed from photos will be removed. Live-tracked data is preserved.")
        }
        .alert(String(localized: "root.photo-import.failed.title", defaultValue: "Photo import failed", comment: "Recovery banner title for a failed photo import."), isPresented: $showImportError) {
            if importErrorIsMissingPhotoPermission && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
    }

    private var iconName: String {
        switch kind {
        case .resumable: "tray.and.arrow.down.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch kind {
        case .resumable: .accentColor
        case .failed: .orange
        }
    }

    private var headlineText: String {
        switch kind {
        case .resumable:
            String(localized: "root.photo-import.resumable.title", defaultValue: "Photo import paused", comment: "Recovery banner title for a paused photo import.")
        case .failed:
            String(localized: "root.photo-import.failed.title", defaultValue: "Photo import failed", comment: "Recovery banner title for a failed photo import.")
        }
    }

    private var detailText: String? {
        switch kind {
        case .resumable:
            String(localized: "root.photo-import.resumable.detail", defaultValue: "Resume to continue scanning your photo library, or discard the partial results.", comment: "Recovery banner detail for a resumable photo import.")
        case .failed(let msg): msg.isEmpty ? nil : msg
        }
    }

    private var actionButtons: [AnyView] {
        switch kind {
        case .resumable:
            [
                AnyView(
                    Button { Task { await runResume() } } label: {
                        if isWorking { ProgressView().controlSize(.small) }
                        else { Text("Resume") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                ),
                AnyView(
                    Button(role: .destructive) {
                        showDiscardConfirmation = true
                    } label: {
                        Text("Discard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                )
            ]
        case .failed:
            [
                AnyView(
                    // Try Again re-resumes from the persisted watermark.
                    Button { Task { await runResume() } } label: {
                        if isWorking { ProgressView().controlSize(.small) }
                        else { Text("Try Again") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                ),
                AnyView(
                    Button {
                        onDismiss()
                    } label: {
                        Text("Dismiss")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                )
            ]
        }
    }

    private func runResume() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppDelegate.photoImportService.resume()
        } catch let error as PhotoImportError {
            importErrorMessage = error.userFacingMessage
            if case .noPhotoPermission = error {
                importErrorIsMissingPhotoPermission = true
            } else {
                importErrorIsMissingPhotoPermission = false
            }
            showImportError = true
        } catch {
            importErrorMessage = error.localizedDescription
            importErrorIsMissingPhotoPermission = false
            showImportError = true
        }
    }

    private func runDiscard() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppDelegate.photoImportService.discard()
            // After discard succeeds the state row is gone, so the
            // @Query feed empties and the banner unmounts.
            await PostDiscardReconcile.run()
        } catch {
            // Most likely .alreadyRunning if the user managed to discard
            // mid-handler. Banner stays visible; user can wait + retry.
        }
    }

}

/// After a discard (which deletes stays and releases merged live pings):
/// re-cluster the released pings, re-judge, then heal, so a learned orbit
/// disc the evidence loss de-qualifies frees the `.home` stays it claimed
/// (the shrink arm's stale-coverage snapshot handles the disc's footprint).
/// Shared by both discard surfaces (recovery banner + Settings).
@MainActor
enum PostDiscardReconcile {
    static func run() async {
        let clustering = await PipelineGate.shared.runReturning(touching: [.locationPing, .stay, .trip, .visit]) {
            await AppDelegate.stayClusterer.clusterUnprocessedPingsReportingChanges()
        }
        await AppDelegate.stayClusterer.enrichPendingLocalities(clustering.pendingLocalities)
        _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates(
            maxStaysPerCall: nil)
        _ = await AppDelegate.tripClassifier.generateTitlesStage(
            maxTripsPerCall: nil)
        _ = await AppDelegate.tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: nil)
        StoreChangeTracker.shared.bump([.stay, .trip])
        await HomeAreaHealing.healIfNeeded()
    }
}

// MARK: - Wrapped Loading View (V11)

/// Brief loading state shown when the user opens a Wrapped notification
/// before generation has completed.
private struct WrappedLoadingView: View {
    let year: Int?
    let failure: WrappedPresenter.PreparationFailure?
    let onDismiss: () -> Void

    /// The terminal reason for the year on screen; a stale year's is ignored.
    private var terminalReason: WrappedPresenter.PreparationFailure.Reason? {
        guard let year, let failure, failure.year == year else { return nil }
        return failure.reason
    }

    private var terminalText: String? {
        guard let terminalReason else { return nil }
        let yearText = year.map {
            $0.formatted(.number.grouping(.never))
        } ?? ""
        switch terminalReason {
        case .insufficientData:
            return String(
                localized: "wrapped.notification.insufficient-data",
                defaultValue: "Not enough travel recorded in \(yearText) yet",
                comment: "Terminal state when notification-triggered Wrapped generation finishes without a row; the argument is the year."
            )
        case .failed:
            return String(
                localized: "wrapped.notification.preparation-failed",
                defaultValue: "Couldn't prepare your \(yearText) Wrapped. Try again later.",
                comment: "Terminal state when notification-triggered Wrapped generation fails to read, build or save the recap; the argument is the year."
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(.systemIndigo), Color(.systemPurple), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                if let terminalText {
                    Text(terminalText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Preparing your year…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 50)
            .padding(.trailing, 16)
        }
        .preferredColorScheme(.dark)
    }
}
