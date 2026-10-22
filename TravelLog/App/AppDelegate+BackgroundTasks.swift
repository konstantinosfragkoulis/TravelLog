//
//  AppDelegate+BackgroundTasks.swift
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

extension AppDelegate {

    /// Background task identifier for periodic pipeline processing.
    /// Must match the entry in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let bgTaskIdentifier = "com.travellog.dailyPipeline"

    /// Match the foreground classifier's bounded default. Background refresh
    /// drains additional chunks in separate `PipelineGate` units so a live SLC
    /// save can run between them.
    nonisolated static let backgroundClassificationChunkSize = 60

    /// The refresh's ~30-second budget stops at the first bite without
    /// progress (for example under thermal pressure) and leaves the rest for
    /// the next trigger.
    nonisolated static let backgroundClassificationPatience = 1

    /// Background identifier for user-initiated photo import across foreground/background transitions.
    /// `nonisolated` so the `PhotoImportService` model actor can read it.
    /// `BGContinuedProcessingTask` identifiers MUST start with the host bundle ID;
    /// otherwise submission fails with `notPermitted`, unlike the more lenient refresh identifier.
    nonisolated static let bgImportIdentifier = "com.kfragkoulis.TravelLog.photoImport"

    /// Post-import geocode `BGProcessingTask` supplies an execution assertion after
    /// background import completes; a detached drain alone can be suspended.
    /// `nonisolated` so the `PhotoImportService` model actor can schedule it.
    nonisolated static let geocodeBackfillIdentifier = "com.kfragkoulis.TravelLog.geocodeBackfill"

    // MARK: - Background Task

    /// Register periodic background clustering/classification for accumulated SLC pings.
    /// Refresh timing is discretionary (requested every ~12 hours), with a ~30-second runtime budget.
    func registerBackgroundTask() {
        // `using: .main` is REQUIRED, not optional. Under Swift 6 + the project's
        // `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, this launch-handler closure
        // (and `handleBackgroundRefresh`) are `@MainActor`-isolated. With
        // `using: nil` BGTaskScheduler invokes the handler on a private serial
        // queue, and the closure's inserted MainActor isolation check
        // (`swift_task_checkIsolated` → `dispatch_assert_queue(main)`) then traps
        // with "BUG IN CLIENT OF LIBDISPATCH: Block was not expected to execute
        // on queue". Pinning the handler to the main queue satisfies the
        // isolation; the handler only attaches the task to async work and returns
        // immediately (the pipeline itself runs off-main in @ModelActors), so it
        // never blocks the main thread.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleBackgroundRefresh(refreshTask)
        }
        logger.debug("Background refresh task registered.")

        // Register synchronously before didFinishLaunchingWithOptions returns, as BGTaskScheduler requires.
        // The handler attaches progress and expiration hooks to existing import work.
        // `using: .main` is REQUIRED for Swift 6 MainActor isolation; a private scheduler queue traps.
        // `handleBGImport` starts async work and returns promptly without blocking the main thread.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgImportIdentifier,
            using: .main
        ) { task in
            guard let importTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBGImport(importTask)
        }
        logger.debug("Photo-import BGContinuedProcessingTask registered.")

        // Post-import geocode handler requires `using: .main` for Swift 6 MainActor isolation.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.geocodeBackfillIdentifier,
            using: .main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleGeocodeBackfill(processingTask)
        }
        logger.debug("Geocode-backfill BGProcessingTask registered.")
    }

    /// Handle a background refresh: run the full pipeline, then re-schedule.
    ///
    /// Uses shared completion arbitration to ensure `setTaskCompleted` is called exactly once.
    /// The expiration handler and the normal completion path both try to call it,
    /// but only the first one succeeds. This prevents undefined behavior from
    /// double-calling `setTaskCompleted`.
    private static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        let logger = Logger(subsystem: "com.travellog.app", category: "BackgroundRefresh")

        // Renew the NEXT refresh first and await it before completion: this handler consumes
        // the request, and iOS 27 submission is asynchronous, so expiration could otherwise
        // suspend us before the renewal lands. Launch callers must preserve pending requests instead.
        let renewal = Task { await submitBackgroundRefreshRequest() }

        driveBackgroundRefresh(task, renewal: renewal) {
            logger.info("Background refresh started.")
            // Gate every store mutation against concurrent SLC saves.
            // The gate forwards cancellation into each unit; check cancellation between units
            // so expiration stops the sequence at the next boundary.
            try Task.checkCancellation()
            // Request a homecoming fix FIRST so it can arrive through gated ingest before suspension;
            // its dwell can confirm homecoming during this classify pass or the next trigger.
            if await tripClassifier.homecomingConfirmationDue() {
                LocationService.shared.requestCurrentLocation()
            }
            let clustering = await PipelineGate.shared.runReturning(touching: [.stay, .locationPing, .trip, .visit]) {
                await stayClusterer.clusterUnprocessedPingsReportingChanges()
            }
            await stayClusterer.enrichPendingLocalities(clustering.pendingLocalities)
            try Task.checkCancellation()
            // Drain the deterministic backlog in bounded 60-stay bites, the
            // foreground drain's bites and stop rule on a smaller budget.
            // Every bite owns its OWN gate units, with a cancellation
            // boundary between them, so a live SLC save never waits behind
            // an unbounded classify pass. Between bites, read the count on a
            // fresh MainActor-owned context. This is an advisory snapshot
            // outside the gate; another writer can change the backlog before
            // the next bite.
            var progress = ClassificationBacklogProgress(patience: backgroundClassificationPatience)
            classificationDrain: while true {
                try Task.checkCancellation()
                let bite = await tripClassifier.runBacklogBite(
                    maxStaysPerCall: backgroundClassificationChunkSize, reclassifyRecentStays: true)
                let remaining = unclassifiedStayBacklogCount()
                try Task.checkCancellation()
                guard let remaining else {
                    logger.error("Could not count the remaining classification backlog; stopping this refresh drain.")
                    break
                }
                switch progress.record(remaining: remaining, classified: bite.classified) {
                case .continueDrain:
                    continue
                case .complete:
                    break classificationDrain
                case .stalled:
                    logger.warning("Classification backlog made no progress; leaving \(remaining) stay(s) for the next trigger.")
                    break classificationDrain
                }
            }
            // Geocoding can change title prompt inputs and invalidate the
            // existing canonical/localized artifacts. Run its bounded bite
            // before both title stages so this wake can refill what it strips.
            let geocodeBiteFailed = await PipelineGate.shared.runReturning(
                touching: [.stay, .locationPing, .hexVisit]
            ) {
                let bite = await pingRecorder.retryFailedGeocoding(limit: 10)
                // A geocoded locality can clear a generated title or move a summary.
                await StoreChangeTracker.shared.bump(await pingRecorder.takeGeocodeTripChange())
                return bite.failed
            }
            try Task.checkCancellation()
            // Foundation Models/EventKit work stays OUTSIDE the global gate;
            // each result lands through its own short `.trip` CAS unit.
            _ = await tripClassifier.generateTitlesStage(maxTripsPerCall: 10)
            try Task.checkCancellation()
            _ = await tripTitleLocalizationService.generateLocalizedTitlesStage(
                maxTripsPerCall: 10)
            // Drain geometry-only transit backlog in bounded, separately gated batches;
            // SLC saves must interleave, and cancellation must respect the ~30-second refresh budget.
            try Task.checkCancellation()
            var transitRounds = 0
            while transitRounds < 20 {
                if Task.isCancelled { break }
                transitRounds += 1
                let batch = await PipelineGate.shared.runReturning(touching: [.stay]) {
                    await transitInferer.inferTransitForRecentStaysReportingChanges()
                }
                // A failed batch rolled back and would refetch the same rows; stop until the next wake.
                if batch.failed || batch.fetched < TransitInferer.inferenceBatchSize { break }
            }
            // The enricher owns plan/apply gate units with WeatherKit I/O outside them,
            // so wake-ping saves never wait on network I/O. An outer gate would deadlock.
            await weatherEnricher.enrichRecentStaysGated(limit: 10)
            // Keep the EventKit scan ungated so queueing cannot consume the refresh budget;
            // use offline-only resolution. BG refresh cannot run while foreground-active.
            // Reconciliation owns a short gate unit to serialize with CloudKit PlannedTrip dedup.
            // Do not wrap this call in a gate: the non-reentrant inner unit would deadlock.
            try Task.checkCancellation()
            await calendarEnricher.scanUpcomingTripsUngated()
            // The geocode bite rolled back after a failed read or save. Later stages still ran,
            // but the run must not report success.
            if geocodeBiteFailed { throw BackgroundGeocodeBiteFailure() }
            logger.info("Background refresh pipeline complete.")
        }
    }

    /// The refresh's geocode bite could not read or save; the run reports failure.
    private nonisolated struct BackgroundGeocodeBiteFailure: Error {}

    /// Wires one refresh run to its task. Expiration cancels `pipeline` and reports failure;
    /// natural completion reports whether the pipeline ran to its end uncancelled, so a run
    /// cut short by expiration is a failure whichever path completes the task.
    /// Returns the completion Task so tests can await the natural path.
    @discardableResult
    static func driveBackgroundRefresh(
        _ task: some BackgroundRefreshTaskHandle,
        renewal: Task<Void, Never>,
        renewalGraceSeconds: Double = 2,
        pipeline: @escaping () async throws -> Void
    ) -> Task<Void, Never> {
        let logger = Logger(subsystem: "com.travellog.app", category: "BackgroundRefresh")

        let completion = BackgroundTaskCompletion()

        let pipelineTask = Task { () -> Bool in
            do {
                try await pipeline()
                // Cancellation that lands after the last checkpoint still means expiration cut the run short.
                return !Task.isCancelled
            } catch {
                return false
            }
        }

        // If iOS cancels us early (e.g., system pressure), cancel the pipeline.
        task.expirationHandler = {
            logger.warning("Background refresh expired before completion.")
            completion.markExpired()
            pipelineTask.cancel()
            Task {
                // The renewal started at entry; give it a bounded chance to land before completing.
                await BackgroundTaskSubmitter.awaitRenewal(renewal, seconds: renewalGraceSeconds)
                if let success = completion.claim(ranToEnd: false) {
                    task.setTaskCompleted(success: success)
                }
            }
        }

        return Task {
            let ranToEnd = await pipelineTask.value
            await renewal.value // The renewal attempt (success or logged failure) finishes before this run completes.
            if let success = completion.claim(ranToEnd: ranToEnd) {
                task.setTaskCompleted(success: success)
            }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Fresh-context COUNT used by the bounded backlog drains (background refresh, foreground drain).
    /// The context is created and consumed entirely on MainActor; no `@Model`
    /// or `ModelContext` crosses the gate's `@Sendable` closure boundary.
    @MainActor
    static func unclassifiedStayBacklogCount() -> Int? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate<Stay> {
                $0.categoryRaw == "unclassified" && $0.userOverridden == false
            }
        )
        return try? context.fetchCount(descriptor)
    }

    /// Attach system progress and expiration hooks to the actor's separate import Task.
    /// System expiration and system-UI cancellation are indistinguishable: both cancel the Task
    /// and persist `.paused` for resume. Settings cancellation sets `cancelRequested` and
    /// persists non-resumable `.cancelled` instead.
    /// Shared completion arbitration ensures `setTaskCompleted` runs exactly once,
    /// regardless of whether expiration or natural completion wins.
    private static func handleBGImport(_ task: BGContinuedProcessingTask) {
        let logger = Logger(subsystem: "com.travellog.app", category: "PhotoImportBG")
        logger.info("BGContinuedProcessingTask handler invoked for photo import.")

        let completion = BackgroundTaskCompletion()

        let pipelineTask = Task {
            await photoImportService.runImportSession(progress: task.progress)
        }

        task.expirationHandler = {
            logger.warning("Photo-import BG task expired or cancelled via system UI.")
            completion.markExpired()
            pipelineTask.cancel()
            if let success = completion.claim(ranToEnd: false) {
                task.setTaskCompleted(success: success)
            }
        }

        Task {
            let outcome = await pipelineTask.value
            if let success = completion.claim(ranToEnd: outcome == .completed) {
                task.setTaskCompleted(success: success)
            }
            logger.info("Photo-import BG task handler complete.")
        }
    }

    /// Offline post-import geocode processing gets system-granted background runtime.
    /// Expiration, thermal pause or a failed unit reschedules; natural completion ends the chain
    /// when backlog is empty or unresolvable. Foreground and refresh drains remain idempotent
    /// and actor-serialized, with no network or external-power requirement.
    private static func handleGeocodeBackfill(_ task: BGProcessingTask) {
        Logger(subsystem: "com.travellog.app", category: "GeocodeBackfillBG")
            .info("Geocode-backfill BGProcessingTask started.")
        driveGeocodeBackfill(
            task,
            reschedule: { await scheduleGeocodeBackfill() },
            // The drain owns bounded gate units; an outer PipelineGate.run would deadlock.
            drain: { await pingRecorder.retryAllFailedGeocodingGated() })
    }

    /// Wires one geocode-backfill run to its task. Expiration is recorded synchronously before it
    /// cancels the drain, so a drain that already returned true cannot report success after
    /// expiration. Expiration renews the request itself; a natural run that did not complete
    /// reschedules unless expiration already did. Both may still submit if expiration lands while
    /// the natural path awaits its submit: duplicate submits replace the pending request.
    /// Returns the completion Task so tests can await the natural path.
    @discardableResult
    static func driveGeocodeBackfill(
        _ task: some BackgroundRefreshTaskHandle,
        renewalGraceSeconds: Double = 2,
        reschedule: @escaping @Sendable () async -> Void,
        drain: @escaping @Sendable () async -> Bool
    ) -> Task<Void, Never> {
        let logger = Logger(subsystem: "com.travellog.app", category: "GeocodeBackfillBG")

        let completion = BackgroundTaskCompletion()

        let drainTask = Task { await drain() }

        task.expirationHandler = {
            logger.warning("Geocode-backfill BG task expired before completion.")
            completion.markExpired()
            drainTask.cancel()
            // Keep the chain alive: the drain stops at the next chunk
            // boundary, leaving backlog behind. Submission is asynchronous on
            // iOS 27, so give the renewal a bounded head start before completing.
            let renewal = Task { await reschedule() }
            Task {
                await BackgroundTaskSubmitter.awaitRenewal(renewal, seconds: renewalGraceSeconds)
                if let success = completion.claim(ranToEnd: false) {
                    task.setTaskCompleted(success: success)
                }
            }
        }

        return Task {
            let ranToEnd = await drainTask.value
            if !ranToEnd && !completion.isExpired {
                // Failed unit, thermal pause or cancellation: backlog remains; try again
                // later (the earliestBeginDate also gives the SoC time to cool).
                await reschedule()
            }
            let succeeded = completion.claim(ranToEnd: ranToEnd)
            if let succeeded {
                task.setTaskCompleted(success: succeeded)
            }
            logger.info("Geocode-backfill BG task complete (ranToEnd=\(ranToEnd), succeeded=\(succeeded ?? false)).")
        }
    }

    /// Submit (or replace) the geocode-backfill processing request. 15 min
    /// earliest-begin: the just-finished import already heated the device,
    /// and the drain itself pauses at thermal `.serious`.
    nonisolated static func scheduleGeocodeBackfill() async {
        let request = BGProcessingTaskRequest(identifier: geocodeBackfillIdentifier)
        request.requiresNetworkConnectivity = false // offline SQLite resolver
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try await BackgroundTaskSubmitter.submit(request)
            Logger(subsystem: "com.travellog.app", category: "GeocodeBackfillBG")
                .debug("Scheduled geocode-backfill processing task.")
        } catch {
            // If submission is unavailable, foreground and BG-refresh drains remain fallbacks.
            Logger(subsystem: "com.travellog.app", category: "GeocodeBackfillBG")
                .error("Failed to schedule geocode backfill: \(error.localizedDescription)")
        }
    }

    /// Request a 12-hour minimum refresh interval; iOS decides the actual execution time.
    /// Submission replaces an existing request with the same identifier.
    /// Launch callers preserve pending requests, since repeated SLC relaunches would
    /// otherwise keep pushing the earliest-begin floor out indefinitely; the consuming
    /// BG handler submits its own renewal directly.
    static func scheduleBackgroundRefresh() {
        // Read the identifier HERE, on the isolated context; the completion
        // closure below is nonisolated, so it may only capture Sendable values
        // and must hop back to the main actor to touch anything isolated.
        let identifier = bgTaskIdentifier
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            guard !pending.contains(where: { $0.identifier == identifier }) else {
                Logger(subsystem: "com.travellog.app", category: "BackgroundRefresh")
                    .debug("Background refresh already pending; leaving its schedule untouched.")
                return
            }
            Task { @MainActor in
                await submitBackgroundRefreshRequest()
            }
        }
    }

    private static func submitBackgroundRefreshRequest() async {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60) // 12 hours

        do {
            try await BackgroundTaskSubmitter.submit(request)
            Logger(subsystem: "com.travellog.app", category: "BackgroundRefresh")
                .debug("Scheduled next background refresh.")
        } catch {
            Logger(subsystem: "com.travellog.app", category: "BackgroundRefresh")
                .error("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }
}
