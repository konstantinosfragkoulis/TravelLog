//
//  AppDelegate.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import UIKit
import SwiftData
import BackgroundTasks
import UserNotifications
import WidgetKit
import CoreLocation
import CoreData
import os.log

/// Handles app lifecycle events critical for background location tracking.
/// Set up the location pipeline synchronously on every launch after onboarding;
/// `LaunchOptionsKey.location` is deprecated in iOS 26, so pending delegate events
/// must be handled regardless of launch reason within the ~10-second SLC window.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let logger = Logger(subsystem: "com.travellog.app", category: "AppDelegate")

    /// Shared Sendable recorder; `nonisolated` permits access from background handlers
    /// and the photo-import actor.
    nonisolated static let pingRecorder: PingRecorder = PingRecorder(modelContainer: modelContainer)

    /// The shared VisitRecorder, initialized with the model container.
    /// `nonisolated` for the same reasons as `pingRecorder`.
    nonisolated static let visitRecorder: VisitRecorder = VisitRecorder(modelContainer: modelContainer)

    /// The shared StayClusterer, initialized with the model container.
    /// `nonisolated` for the same reasons as `pingRecorder`.
    nonisolated static let stayClusterer: StayClusterer = StayClusterer(modelContainer: modelContainer)

    /// The shared TripClassifier, initialized with the model container.
    /// `nonisolated` for the same reasons as `pingRecorder`.
    nonisolated static let tripClassifier: TripClassifier = TripClassifier(modelContainer: modelContainer)

    /// Writes each generated title's variant in the app language from the
    /// bundled place-name table, in its own short gated units.
    nonisolated static let tripTitleLocalizationService =
        TripTitleLocalizationService(modelContainer: modelContainer)

    /// JSON export-file restore (Settings → Import Trip Data). Store-
    /// mutating commits run inside `PipelineGate` like every pipeline unit.
    nonisolated static let tripDataImporter: TripDataImporter = TripDataImporter(modelContainer: modelContainer)

    /// Shared photo-import lifecycle actor used by the background handler and Settings.
    /// `nonisolated` because both callers run outside MainActor.
    nonisolated static let photoImportService: PhotoImportService = PhotoImportService(modelContainer: modelContainer)

    /// Enriches finalized stays via WeatherKit, lazily from views and opportunistically in background.
    nonisolated static let weatherEnricher: WeatherEnricher = WeatherEnricher(modelContainer: modelContainer)

    /// Deterministic geometry-based transit inference needs no Motion permission or recency window.
    nonisolated static let transitInferer: TransitInferer = TransitInferer(modelContainer: modelContainer)

    /// Annual recap generation, triggered on foreground open after December 1.
    nonisolated static let yearWrappedGenerator: YearWrappedGenerator = YearWrappedGenerator(modelContainer: modelContainer)

    /// The shared CalendarEnricher (V14). Owns the app's single `EKEventStore`;
    /// all EventKit reads happen inside its isolation domain and only
    /// `Sendable` `CalendarEventSnapshot`s leave it. Writes `PlannedTrip`
    /// rows (future lane) and serves per-window event lookups (past lane).
    nonisolated static let calendarEnricher: CalendarEnricher = CalendarEnricher(modelContainer: modelContainer)

    /// Shared trailing-edge coalescer for speculative CloudKit pushes and the
    /// authoritative completed-import maintenance pass. See
    /// `didReceiveRemoteNotification`.
    nonisolated static let remotePushCoalescer = RemotePushCoalescer()

    /// Closes the append-after-first-scrub window while the durable marker
    /// still forces newly parked or restored records to omit title artifacts,
    /// then finishes the revocation. Runs right after the live-title clear.
    nonisolated static func finishCalendarDataRevocation() -> Bool {
        do {
            try DissolvedTripQueue.scrubGeneratedTitles()
        } catch {
            return false
        }
        DissolvedTripQueue.finishGeneratedTitleRevocation()
        return true
    }

    /// Finishes a Delete Calendar Data operation interrupted between its
    /// device-local queue, SwiftData, cache, and live-title phases. Every
    /// phase is idempotent; the durable marker remains set on any failure so
    /// the next launch retries instead of claiming Calendar text was erased.
    nonisolated static func resumePendingCalendarDataRevocationIfNeeded() async {
        guard DissolvedTripQueue.generatedTitleRevocationIsPending() else {
            return
        }
        await calendarEnricher.beginCalendarDataRevocation()
        do {
            try DissolvedTripQueue.scrubGeneratedTitles()
        } catch {
            return
        }
        let calendarResult = await PipelineGate.shared.runReturning(
            touching: [.plannedTrip]
        ) {
            await calendarEnricher.deleteAllCalendarData()
        }
        guard calendarResult.succeeded else { return }
        let titleResult = await tripClassifier
            .clearThenRegenerateAllTitlesForCalendarWipe(
                finishRevocationAfterClear: finishCalendarDataRevocation)
        guard titleResult.cleared, titleResult.revocationFinished else { return }
        _ = await tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: nil)
        await MainActor.run {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")

        logger.info("App launched. Onboarding complete: \(onboardingComplete)")

        // Mirror per-app language before widget refresh: the extension is a separate process.
        // Reload only when the mirror changes to preserve WidgetKit budget;
        // per-app language changes relaunch the process.
        if let appGroupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier),
           AppLanguagePreference.mirrorCurrentToAppGroup(defaults: appGroupDefaults) {
            WidgetCenter.shared.reloadAllTimelines()
        }

        #if DEBUG
        Self.logMigrationDiagnostic()
        #endif

        // Register the background refresh task. Must happen BEFORE returning
        // from didFinishLaunchingWithOptions - iOS requirement.
        registerBackgroundTask()

        // Defer offline-geocoder warmup beyond first paint; the actor still handles all resolves.
        // Country polygons load lazily through `GlobeView.task`, outside the launch path.
        Task.detached(priority: .utility) {
            // A share sheet the last process never closed left its copies.
            TripShareStaging.removeStagedShares()
            try? await Task.sleep(for: .seconds(3))
            await GeocodeResolver.shared.prewarm()
        }

        // Use a process-lifetime memory-warning observer to throttle photo-import batches;
        // the UIApplicationDelegate callback is deprecated.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Bridge to the @ModelActor: NotificationCenter delivers on
            // .main, our actor lives on its own executor. A detached
            // Task is the minimum-overhead hop.
            Task {
                await Self.photoImportService.handleMemoryWarning()
            }
        }

        // Register the photo-library observer synchronously before views render to avoid missing changes.
        // Gate eager initialization on completed onboarding: touching PhotoKit before the photo
        // permission step can surface a system prompt before the user expects it.
        if onboardingComplete {
            _ = PhotoService.shared
        }

        // Calendar change notifications carry no diff; the enricher debounces and re-scans.
        // Register only with an existing grant to avoid touching EventKit pre-permission;
        // Settings starts the observer after a fresh grant.
        Task.detached(priority: .utility) {
            // The grant lookup is a synchronous XPC; keep it off the main thread.
            guard CalendarEnricher.hasReadAccess else { return }
            await Self.calendarEnricher.startObservingStoreChanges()
        }

        // Register for remote notifications so CloudKit can notify us
        // when changes arrive from other devices.
        if UserDefaults.standard.bool(forKey: Self.iCloudSyncEnabledKey) {
            application.registerForRemoteNotifications()
        }

        // A silent push schedules CloudKit import; it does not delimit it.
        // Re-run the one V16 convergence pass after Core Data confirms a
        // successful import has actually finished. The shared coalescer lets
        // this authoritative pass supersede pending speculative push work.
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }

            // An import posts once when it starts (no end date) and once when
            // it ends; one-shot backfill latches defer while one is running
            // and while the latest import to start is not the last success.
            // The flag clears after the stamps below, on every exit path.
            if event.type == .import, event.endDate == nil {
                Self.cloudImportInFlight.withLock { $0 = true }
                Self.lastCloudImportStartedAt.withLock { $0 = event.startDate }
            }
            defer {
                if event.type == .import, event.endDate != nil {
                    Self.cloudImportInFlight.withLock { $0 = false }
                }
            }

            if Self.shouldRecordCloudKitSyncFailure(
                eventType: event.type,
                endDate: event.endDate,
                succeeded: event.succeeded
            ), let endDate = event.endDate {
                let errorDescription = event.error.map {
                    String(describing: $0)
                } ?? String(
                    localized: "settings.icloud.sync-error.unknown-detail",
                    defaultValue: "CloudKit did not provide error details.",
                    comment: "Fallback detail when a failed asynchronous CloudKit event has no underlying error."
                )
                if let message = Self.cloudKitSyncFailureDescription(
                    eventType: event.type,
                    errorDescription: errorDescription,
                    timestamp: endDate
                ) {
                    UserDefaults.standard.set(message, forKey: Self.lastCloudKitErrorKey)
                }
            }

            guard Self.shouldRunPostCloudImportMaintenance(
                eventType: event.type,
                endDate: event.endDate,
                succeeded: event.succeeded,
                iCloudEnabled: UserDefaults.standard.bool(
                    forKey: Self.iCloudSyncEnabledKey)) else { return }

            // Only a completed import is stamped here; the push stamp stays in the
            // push handler so a newer push can mark a further import as pending.
            UserDefaults.standard.set(event.endDate ?? Date.now, forKey: Self.lastSuccessfulCloudImportAtKey)
            UserDefaults.standard.set(event.startDate, forKey: Self.lastSuccessfulCloudImportStartedAtKey)
            Task.detached(priority: .utility) {
                await Self.remotePushCoalescer.schedule(authoritative: true) {
                    await Self.runPostCloudImportMaintenance()
                }
            }
        }

        // Wire up the location service → ping recorder pipeline.
        // This must happen on EVERY launch (normal or background relaunch).
        //
        // CRITICAL: connectLocationPipeline() must run SYNCHRONOUSLY before
        // returning from didFinishLaunchingWithOptions. On background relaunch,
        // the CLLocationManager delegate fires with the pending SLC event almost
        // immediately. If the pipeline isn't connected yet, the location is
        // silently dropped (onLocationUpdate is nil). restoreLastH3Index() is
        // async but non-critical - worst case, the first hex visit after relaunch
        // always increments the count (minor inaccuracy vs. losing a location).
        connectLocationPipeline()
        // Fix this launch's sync mode before Settings can change the preference.
        _ = Self.storeSyncsWithCloudThisLaunch

        // Set notification delegate so banners display even when the app is foregrounded.
        UNUserNotificationCenter.current().delegate = self

        // Initialize pinned-trip storage before external KVS changes arrive;
        // a lazily registered observer can miss the session's first remote pin/unpin.
        _ = PinnedTripsStorage.shared

        Task { @MainActor in
            // Wire the durability sink before healing: persist each restoration record BEFORE
            // the save deleting its trip so termination cannot strand a dissolved trip.
            await Self.tripClassifier.setDissolvedRecordSink { records in
                try DissolvedTripQueue.append(records)
            }
            await Self.resumePendingCalendarDataRevocationIfNeeded()
            await Self.pingRecorder.restoreLastH3Index()

            // Defer maintenance beyond first paint; synchronous location setup keeps SLC ingest independent.
            // Each deduplicator owns a short gate unit to serialize shared-store writes with SLC saves
            // while allowing wake saves between passes. The fail-open `.all` bump still covers
            // photo maintenance outside the gate; legacy cloud IDs are backfilled even with sync off.
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(3))
                if UserDefaults.standard.bool(forKey: Self.iCloudSyncEnabledKey) {
                    await Self.deduplicateSyncedRows()
                }
                // Repair legacy missing map rows once per install in
                // local-only stores: one HexVisit-only gate unit, marker set
                // when the pass completes. The in-memory fallback container
                // (persistent store failed to open) must not run it: an empty
                // pass there would mark the real store repaired forever.
                if !Self.modelContainer.configurations.contains(where: \.isStoredInMemoryOnly) {
                    await PhotoImportPingDeduplicator.repairMissingHexVisitsOnce(
                        modelContainer: Self.modelContainer)
                }
                // Even without iCloud: onboarding replay can duplicate places locally.
                await Self.deduplicateWrappedAndPlaces()
                let homeTitlesInvalidated =
                    await Self.reconcileActiveHomeTitleFingerprint() ?? 0
                if homeTitlesInvalidated > 0 {
                    _ = await Self.tripClassifier.generateTitlesStage(
                        maxTripsPerCall: 10)
                    _ = await Self.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: 10)
                }
                // Sweep orphans even without iCloud, since local Trip deletion can leave annotations.
                // The 24-hour grace period protects rows awaiting their parent.
                let orphanSweep = await PipelineGate.shared.runReturning(touching: [.hiddenPhoto, .pinnedPhoto]) {
                    await PhotoAnnotationDeduplicator.sweepOrphans(
                        modelContainer: Self.modelContainer
                    )
                }
                // Gate photo maintenance on onboarding completion: constructing PhotoService early
                // surfaced the iOS 26 first-use photos permission prompt mid-onboarding.
                // Skipped cloud-ID caches rebuild on later authorized maintenance triggers.
                // Use the FIFO maintenance chain to prevent interleaving with debounced triggers.
                if onboardingComplete {
                    await PhotoService.shared.runCloudIDMaintenance(backfill: true, refresh: true)
                    // Rows the sweep moved onto a carry winner change that
                    // trip's hidden and pinned sets; the push and post-import
                    // passes invalidate every trip anyway.
                    if !orphanSweep.rekeyedOnto.isEmpty {
                        for tripID in orphanSweep.rekeyedOnto {
                            await PhotoService.shared.invalidateCache(for: tripID)
                        }
                        await PhotoService.shared.notifyChange()
                    }
                }
                // Cancel stale running import states AFTER dedup so the survivor is settled first.
                await Self.photoImportService.handleStaleStateOnLaunch()

                // Keep the fail-open `.all` bump for photo maintenance outside individually gated deduplicators.
                // Do not exclude `.trip` on background relaunch: this work's reach is untracked, and
                // ping dedup also declares `.trip`. Guard Spotlight at `StoreChangeTracker.flushPending`.
                await StoreChangeTracker.shared.bump(.all)

                // Defer heavy one-time backfills on background relaunch: long serial-gate holds can
                // exhaust the ~10-second SLC window before the wake ping saves.
                // Completion keys latch only after completed passes, so the next foreground launch resumes safely.
                // Foreground launch states are `.inactive`/`.active`; this return exits only the detached task.
                let launchedInForeground = await MainActor.run {
                    UIApplication.shared.applicationState != .background
                }
                guard launchedInForeground else {
                    Logger(subsystem: "com.travellog.app", category: "LaunchBackfill")
                        .info("Background relaunch — deferring one-time launch backfills to the next foreground launch.")
                    return
                }

                // Backup restore carries defaults but not Spotlight's index or stable EventKit identifiers.
                // Re-arm their latches once per detected restore; Wrapped verifies pending notifications separately.
                await Self.rearmRestoreSensitiveLatches(invalidateSpotlight: {
                    await SpotlightIndexer.shared.invalidateDonationToken()
                })
                // The first syncing launch after a local-only or unrecorded one
                // re-arms the dataset repairs below for the history CloudKit brings in.
                Self.rearmDatasetRepairsOnCloudTransition()

                // Finish Home / routine coverage reconciliations a kill or
                // failure left owed, in Settings' order (reconcile, titles, heal).
                await CoverageReconciliationQueue.drainIfNeeded()

                // Heal Spotlight only in foreground to preserve the SLC budget;
                // the content-token gate avoids redundant donations, and `.trip` changes trigger further healing.
                await SpotlightIndexer.shared.requestRefresh()

                // Backfill airport flags inside the gate to serialize Stay writes with live SLC ingest.
                // Keep this full-Stay scan below the background-relaunch guard to protect the wake-ping budget.
                if !UserDefaults.standard.bool(forKey: Self.airportBackfillDatasetKey) {
                    await PipelineGate.shared.run(touching: [.stay, .trip]) {
                        await Self.runAirportBackfillIfNeeded()
                    }
                }

                // Recompute destination-only country codes under the gate, only on foreground launch.
                // This precedes geocoding; the later metro refresh performs the authoritative
                // summary recompute after restored country data is available.
                if !UserDefaults.standard.bool(forKey: Self.tripCountryCodesRecomputeCompletedKey) {
                    await PipelineGate.shared.run(touching: [.trip]) {
                        await Self.runTripCountryCodesRecomputeIfNeeded()
                    }
                }

                // Re-geocode existing rows without changing the CloudKit schema.
                // The worker resolves ungated and applies bounded chunks in its OWN gate units,
                // so SLC saves can interleave. NEVER wrap it in an outer gate: the gate is non-reentrant.
                await Self.runOfflineGeocoderBackfillIfNeeded()

                // Restore missing Stay country data AFTER geocoding gets first chance to populate it
                // and BEFORE the summary refresh consumes restored fields.
                if !UserDefaults.standard.bool(forKey: Self.restoreWipedStayCountryCompletedKey) {
                    await PipelineGate.shared.run(touching: [.stay, .trip]) {
                        await Self.runRestoreWipedStayCountryIfNeeded()
                    }
                }

                // Refresh trip summaries AFTER geocoding populates metro names; completion is latched per device.
                await PipelineGate.shared.run(touching: [.trip]) {
                    await Self.runTripSummaryMetroRefreshIfNeeded()
                }

                // Clear country names stored as localities AFTER geocoding has written legitimate localities;
                // this prevents country names reaching display and title inputs.
                if !UserDefaults.standard.bool(forKey: Self.localityCountryNameSweepCompletedKey) {
                    await PipelineGate.shared.run(touching: [.stay, .locationPing, .hexVisit, .trip]) {
                        await Self.runLocalityCountryNameSweepIfNeeded()
                    }
                }

                // Resolve remaining unknown stay localities AFTER the country-name sweep makes them eligible.
                // The worker owns bounded gate units; rate-limited MapKit awaits run outside them
                // so SLC saves can interleave. An outer gate would deadlock the non-reentrant gate.
                await Self.runStayLocalityFallbackBackfillIfNeeded()
            }

            // If onboarding was completed, resume SLC monitoring
            // and schedule periodic background pipeline processing.
            if onboardingComplete {
                LocationService.shared.startMonitoring()
                Self.scheduleBackgroundRefresh()

                // Schedule the NEXT upcoming December 1 and latch only its year;
                // a past-dated trigger would strand the reminder. Current recaps remain available in foreground.
                // Gregorian like the generator's year windows; the device calendar's
                // year can differ (Buddhist, Japanese). The time zone stays the device's.
                let cal = Calendar(identifier: .gregorian)
                let currentYear = cal.component(.year, from: Date.now)
                let dec1ThisYear = cal.date(from: DateComponents(year: currentYear, month: 12, day: 1, hour: 9))
                let wrappedNotifYear = (dec1ThisYear.map { $0 > Date.now } ?? false) ? currentYear : currentYear + 1
                let notifKey = YearWrappedGenerator.scheduledNotificationKey(forYear: wrappedNotifYear)
                // Only for a year with early data (the generator's own rule), so a launch
                // after Delete All Data does not re-arm a recap of nothing; a later launch
                // schedules once data exists. One read-only gate unit: a wipe lands wholly
                // before the check or after the add and its latch.
                Task.detached(priority: .utility) {
                    await PipelineGate.shared.run(touching: []) {
                        guard (try? await Self.yearWrappedGenerator.hasEarlyData(
                            forYear: wrappedNotifYear)) == true else { return }
                        if !UserDefaults.standard.bool(forKey: notifKey) {
                            if YearWrappedGenerator.scheduleWrappedNotification(forYear: wrappedNotifYear) {
                                UserDefaults.standard.set(true, forKey: notifKey)
                            }
                        } else {
                            // Backups retain the latch but not OS notification requests; verify and re-arm.
                            // The target date is future and `add()` replaces by identifier, so a false-missing race is harmless.
                            let pending = await UNUserNotificationCenter.current()
                                .pendingNotificationRequests()
                            let identifier = "wrapped-\(wrappedNotifYear)"
                            if !pending.contains(where: { $0.identifier == identifier }) {
                                YearWrappedGenerator.scheduleWrappedNotification(forYear: wrappedNotifYear)
                            }
                        }
                    }
                }

                // Generate Wrapped only in foreground: FM generation and its save compete with
                // the ~10-second SLC wake-ping budget. The generator enforces its data threshold.
                let currentMonth = cal.component(.month, from: Date.now)
                if currentMonth >= 12, UIApplication.shared.applicationState != .background {
                    Task.detached(priority: .background) {
                        // Gate the generator's save against concurrent YearWrapped dedup;
                        // the gate publishes `.yearWrapped` changes.
                        await PipelineGate.shared.run(touching: [.yearWrapped]) {
                            _ = await Self.yearWrappedGenerator.generateIfNeeded(forYear: currentYear)
                        }
                    }
                }
            }
        }

        return true
    }

    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // CloudKit pushes request automatic import; maintenance deduplicates and refreshes caches.
        // Order: deduplicate, invalidate per-trip caches, then rebuild cloud-to-local translation
        // so invalidation cannot wipe the rebuilt cross-device hide/pin mappings.
        // Stamp EVERY push before coalescing: a push newer than the last completed import
        // means another import is pending, so one-shot backfill latches defer.
        UserDefaults.standard.set(Date.now, forKey: Self.lastRemoteImportAtKey)

        // Coalesce push bursts into one trailing maintenance pass.
        // Await it within the background fetch window; a push superseded by a newer push
        // returns `.newData`, one superseded by completed-import maintenance waits for it.
        await Self.remotePushCoalescer.schedule {
            let iCloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudSyncEnabledKey)

            if iCloudEnabled {
                await Self.deduplicateSyncedRows()
                await Self.deduplicateWrappedAndPlaces()
                let homeTitlesInvalidated =
                    await Self.reconcileActiveHomeTitleFingerprint() ?? 0
                // Heal synced home corrections AFTER PlacesDeduplicator re-points overrides;
                // healing must evaluate the post-collapse home set.
                await HomeAreaHealing.healIfNeeded()
                if homeTitlesInvalidated > 0 {
                    _ = await Self.tripClassifier.generateTitlesStage(
                        maxTripsPerCall: 10)
                    _ = await Self.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: 10)
                }
                // Sweep orphan annotation rows whose parent Trip has been
                // deleted on another device. The sweep has its own 24-hour
                // grace period so it cannot destroy rows that simply arrived
                // ahead of their Trip in this same sync cycle.
                await PipelineGate.shared.run(touching: [.hiddenPhoto, .pinnedPhoto]) {
                    await PhotoAnnotationDeduplicator.removeOrphans(
                        modelContainer: Self.modelContainer
                    )
                }
            }

            // Step 2: per-trip caches first. Cloud→local cache is preserved.
            await PhotoService.shared.invalidateTripCaches()

            // Rebuild cloud-to-local mappings through FIFO maintenance when iCloud is enabled;
            // await completion before notifying views.
            if iCloudEnabled {
                await PhotoService.shared.runCloudIDMaintenance(backfill: false, refresh: true)
            }

            // Notify views after cache refresh so they re-fetch while foregrounded;
            // this mirrors the change-token bump for PhotoKit library changes.
            await PhotoService.shared.notifyChange()

            // CloudKit import bypasses the gate and pushes carry no changed-type information;
            // bump all generations so Stats, Map, and Spotlight cannot remain stale.
            // Widgets reload after the completed import merges, not on the push.
            await StoreChangeTracker.shared.bump(.all)
        }

        return .newData
    }

    // MARK: - Background new-hex widget reload throttle

    /// Minimum spacing between widget reloads triggered by background SLC
    /// batches that entered a new hex. A drive enters a new cell every few
    /// minutes; unthrottled, that spent WidgetKit's daily budget mid-trip.
    /// The next new-hex wake after the interval, or any foreground batch,
    /// reloads.
    nonisolated static let hexWidgetReloadMinInterval: TimeInterval = 15 * 60

    nonisolated private static let hexWidgetReloadLast =
        OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// A new hex whose reload the slot suppressed. The next saved batch
    /// repays it: a foreground batch at once, a background one when the slot
    /// is due, so the last hex of a drive is not stranded until the widget's
    /// own refresh.
    nonisolated static let hexWidgetReloadPending =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Pure reload decision for a saved live batch (test seam). Returns
    /// whether to reload now and whether a reload stays owed.
    nonisolated static func hexWidgetReloadDecision(
        insertedNewHex: Bool, pending: Bool, batchIsSLC: Bool, claimSlot: () -> Bool
    ) -> (reload: Bool, pending: Bool) {
        guard insertedNewHex || pending else { return (false, false) }
        if !batchIsSLC || claimSlot() { return (true, false) }
        return (false, true)
    }

    /// True when enough time has passed since the last background new-hex
    /// reload; claims the slot atomically.
    nonisolated static func claimHexWidgetReloadSlot(now: Date = .now) -> Bool {
        hexWidgetReloadLast.withLock { last in
            guard Self.widgetReloadDue(last: last, now: now,
                                       minInterval: hexWidgetReloadMinInterval) else {
                return false
            }
            last = now
            return true
        }
    }

    #if DEBUG
    /// Test-only: the slot is process-global, so tests reset it first.
    nonisolated static func resetWidgetReloadSlotsForTesting() {
        hexWidgetReloadLast.withLock { $0 = nil }
        hexWidgetReloadPending.withLock { $0 = false }
    }
    #endif

    /// Pure throttle rule (test seam).
    nonisolated static func widgetReloadDue(
        last: Date?, now: Date, minInterval: TimeInterval
    ) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= minInterval
    }

    // MARK: - Location Pipeline

    nonisolated static let foregroundFastPathMinimumIntervalSeconds: TimeInterval = 180

    nonisolated static func foregroundFastPathDelay(
        lastCompletedAt: Date?,
        now: Date
    ) -> TimeInterval {
        guard let lastCompletedAt else { return 0 }
        return max(
            0,
            foregroundFastPathMinimumIntervalSeconds
                - now.timeIntervalSince(lastCompletedAt))
    }

    private static var foregroundFastPathDriverTask: Task<Void, Never>?
    private static var foregroundFastPathPending = false
    private static var lastForegroundFastPathCompletion: Date?

    /// Connect LocationService's output to PingRecorder's input.
    @MainActor
    private func connectLocationPipeline() {
        LocationService.shared.onLocationUpdate = {
            [recorder = Self.pingRecorder, visits = Self.visitRecorder] candidates in
            guard !candidates.isEmpty else { return }
            let activeAtDelivery = UIApplication.shared.applicationState == .active

            // Gate live ingest to serialize cross-context writes and overlapping SLC duplicate checks.
            // Heavy backfills defer on background relaunch; remaining gate holders are bounded chunks
            // so the wake-ping save fits the SLC budget.
            // Recorder and classifier submissions MUST remain separate top-level gate units:
            // PipelineGate is non-reentrant, so the fast-path pass must never run inside this recorder unit.
            // Background callbacks stay save-only; transit inference and titles run in the Trips-tab pipeline.
            await PipelineGate.shared.run(touching: []) {
                // Publish exactly what the batch's saves wrote, before the gate
                // releases, so the next unit never reads an uninvalidated home index.
                let changes = await recorder.processLocations(candidates)
                await StoreChangeTracker.shared.bump(changes)
                // A Visit callback whose save failed is retried on the next
                // trigger, a fix included: the platform need not redeliver it.
                // A no-op while nothing is owed.
                if await visits.retryFailedObservations() {
                    await StoreChangeTracker.shared.bump(.visit)
                }
            }

            guard activeAtDelivery else { return }
            Self.requestForegroundFastPath()
        }
        LocationService.shared.onVisitObservation = {
            [recorder = Self.visitRecorder] observation in

            // Visit callbacks are a save-only gate unit: no geocoding, H3/hex,
            // notification, clustering, classification, or fast-path request.
            // Keeping this separate from cluster/classify units preserves the
            // short Core Location callback durability path. The recorder keeps
            // a callback whose read or save failed and replays it first.
            await PipelineGate.shared.run(touching: [.visit]) {
                await recorder.record(observation)
            }
        }
        logger.debug("Location pipeline connected.")
    }

    private static func requestForegroundFastPath() {
        foregroundFastPathPending = true
        guard foregroundFastPathDriverTask == nil else { return }

        foregroundFastPathDriverTask = Task { @MainActor in
            await driveForegroundFastPath()
        }
    }

    private static func driveForegroundFastPath() async {
        while foregroundFastPathPending {
            let delay = foregroundFastPathDelay(
                lastCompletedAt: lastForegroundFastPathCompletion,
                now: .now)
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }

            guard UIApplication.shared.applicationState == .active else {
                foregroundFastPathPending = false
                break
            }

            // One pass consumes every request received before gate submission.
            // Requests arriving during the pass arm one trailing pass.
            foregroundFastPathPending = false
            let pendingLocalities = await PipelineGate.shared.runReturning(
                touching: []
            ) { () -> StayClusterer.PendingLocalities? in
                let stillActive = await MainActor.run {
                    UIApplication.shared.applicationState == .active
                }
                guard stillActive else { return nil }
                // At home a ping extends a trip-less stay: publish what this pass
                // wrote, before the gate releases, instead of a static `.trip`.
                let clustering = await Self.stayClusterer.clusterUnprocessedPingsReportingChanges()
                await StoreChangeTracker.shared.bump(clustering.changes)
                return clustering.pendingLocalities
            }

            guard let pendingLocalities else {
                foregroundFastPathPending = false
                break
            }
            await Self.stayClusterer.enrichPendingLocalities(pendingLocalities)
            let stillActive = await MainActor.run { UIApplication.shared.applicationState == .active }
            guard stillActive, !Task.isCancelled else { break }
            _ = await Self.tripClassifier.classifyAndAssembleTripsWithGates()
            lastForegroundFastPathCompletion = .now
        }

        foregroundFastPathDriverTask = nil
    }

}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Display notification banners even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Route Wrapped notification taps through WrappedPresenter for RootView presentation.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        let info = request.content.userInfo

        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        if request.content.categoryIdentifier == YearWrappedGenerator.wrappedNotificationCategory,
           let year = info["year"] as? Int {
            await MainActor.run {
                WrappedPresenter.shared.requestYear(year)
            }

            // Ensure Wrapped exists before presentation. Gate generation against other YearWrapped
            // mutations on separate contexts; the gate publishes `.yearWrapped` changes.
            let outcome = await PipelineGate.shared.runReturning(
                touching: [.yearWrapped]
            ) {
                await Self.yearWrappedGenerator.generateIfNeeded(forYear: year)
            }
            await MainActor.run {
                WrappedPresenter.shared.finishPreparing(
                    forYear: year,
                    outcome: outcome)
            }
        }
    }
}

