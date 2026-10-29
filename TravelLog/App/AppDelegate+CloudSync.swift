//
//  AppDelegate+CloudSync.swift
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

    /// Dedup of rows that duplicate through sync, shared by launch, the
    /// completed import and the push; each runs it only with iCloud on (local
    /// writers upsert import states, calendar plans and home overrides).
    /// Every deduplicator takes its own short gate unit, never nested, so wake
    /// saves interleave between them, and every unit runs even after an
    /// earlier one failed. True when all of them completed.
    @discardableResult
    nonisolated static func deduplicateSyncedRows() async -> Bool {
        var completed: Bool = await PipelineGate.shared.runReturning(touching: [.hexVisit]) {
            await HexVisitDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        }
        // Trip ghost sweep BEFORE the annotation dedup: a carry re-keys
        // hidden/pinned rows onto the winner, and the annotation pass then
        // collapses any (trip, photo) pair the user had marked on both rows.
        completed = await PipelineGate.shared.runReturning(touching: [.trip, .hiddenPhoto, .pinnedPhoto]) {
            await TripDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        completed = await PipelineGate.shared.runReturning(touching: [.hiddenPhoto, .pinnedPhoto]) {
            await PhotoAnnotationDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        completed = await PipelineGate.shared.runReturning(touching: [.photoImportState]) {
            await PhotoImportStateDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        // `.trip` too: reconciliation repairs and deletes emptied open trips. Its Stay
        // reconciliation defers while a local import runs.
        completed = await PipelineGate.shared.runReturning(
            touching: [.locationPing, .stay, .trip, .hexVisit]) {
            await PhotoImportPingDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        completed = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
            await PlannedTripDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        completed = await PipelineGate.shared.runReturning(touching: [.homeAreaOverride]) {
            await HomeAreaOverrideDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        // Owns one short gate unit per bounded Trip batch.
        completed = await TripTitleVariantDeduplicator.deduplicateAll(
            modelContainer: Self.modelContainer) && completed
        return completed
    }

    /// YearWrapped and Places dedup, each in its own gate unit: two devices
    /// can generate the same recap or onboard the same places before sync
    /// propagates. Proximity guards keep distinct places apart. Both units run
    /// even if the first failed. True when both completed.
    @discardableResult
    nonisolated static func deduplicateWrappedAndPlaces() async -> Bool {
        var completed: Bool = await PipelineGate.shared.runReturning(touching: [.yearWrapped]) {
            await YearWrappedDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        }
        completed = await PipelineGate.shared.runReturning(touching: [.home, .routinePlace, .trip, .homeAreaOverride]) {
            await PlacesDeduplicator.deduplicateAll(
                modelContainer: Self.modelContainer)
        } && completed
        return completed
    }

    /// Authoritative post-merge maintenance. A silent push merely asks Core
    /// Data to import; every operation that depends on imported rows must run
    /// again after the successful completed-import event. The speculative push
    /// pass remains a latency optimization, never the sole correctness path.
    nonisolated static func runPostCloudImportMaintenance() async {
        let iCloudEnabled = UserDefaults.standard.bool(
            forKey: Self.iCloudSyncEnabledKey)
        guard iCloudEnabled else { return }

        // Map cells a photo discard kept for want of local evidence: judged once
        // a completed import reaches past their grace, whether or not this one
        // merged rows. Holds no token: a cell that cannot be judged stays queued.
        await PhotoImportService.sweepPhantomHexCells(modelContainer: Self.modelContainer)

        // Skip when no authored row landed since the last completed pass; the token
        // then moves past this device's own saves.
        let history = postImportHistoryWindow()
        guard history.mustRun else {
            Logger(subsystem: "com.travellog.app", category: "PostImportMaintenance")
                .info("Completed import merged no rows; post-import maintenance skipped.")
            recordPostImportHistoryToken(history.latest)
            return
        }

        // Each unit reports a failed required read or save, a skip or a deferral; an unfinished
        // pass drops the token. Rescue, classification and title work inside healing have
        // their own triggers and do not hold the token.
        var completed = await deduplicateSyncedRows()
        completed = await deduplicateWrappedAndPlaces() && completed
        completed = await Self.reconcileActiveHomeTitleFingerprint() != nil && completed
        completed = await HomeAreaHealing.healIfNeeded() && completed
        completed = await PipelineGate.shared.runReturning(touching: [.hiddenPhoto, .pinnedPhoto]) {
            await PhotoAnnotationDeduplicator.removeOrphans(
                modelContainer: Self.modelContainer)
        } && completed
        // Titles a device on an older build wrote; before Stage 5 so it titles
        // whatever the check left untitled. Only trips the history window
        // touched, unless the pass has no bounded window.
        let titleRepairScope = history.titleRepairScope
        completed = await PipelineGate.shared.runReturning(touching: [.trip]) {
            Self.reconcileStoredTitles(
                modelContainer: Self.modelContainer, scope: titleRepairScope)
        } && completed

        await PhotoService.shared.invalidateTripCaches()
        await PhotoService.shared.runCloudIDMaintenance(
            backfill: false,
            refresh: true)
        await PhotoService.shared.notifyChange()
        await StoreChangeTracker.shared.bump(.all)
        _ = await tripClassifier.generateTitlesStage(maxTripsPerCall: 10)
        _ = await tripTitleLocalizationService.generateLocalizedTitlesStage(
            maxTripsPerCall: 10)
        // The in-process bump cannot reach the widget extension. Unthrottled:
        // a merged import is the one remote reload that must not be dropped.
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        // The title stages, photo refresh and widget reload have their own triggers.
        finishPostImportPass(history, completed: completed && !Task.isCancelled)
    }

    /// Newest persistent-history token the completed-import pass accounted for,
    /// JSON, with the schema version it was read under. Device-local. Absent,
    /// unreadable or from another schema means a full pass.
    nonisolated static let postImportHistoryTokenKey = "postImportHistoryToken_v1"
    nonisolated static let postImportHistorySchemaKey = "postImportHistorySchema_v1"
    /// When the last full pass completed: one whose title unit checked every
    /// titled trip (no other unit is scoped by the history window). A day
    /// without one runs a full pass whatever the history says: a backstop
    /// under the check, not its guarantee.
    nonisolated static let postImportLastFullPassAtKey = "postImportLastFullPassAt_v1"
    nonisolated static let postImportFullPassInterval: TimeInterval = 24 * 60 * 60

    /// Re-arms every restore-sensitive latch while a backup restore is still
    /// pending, and acknowledges the sentinel only after all of them are
    /// durable: an interruption before the acknowledgement repeats the re-arm
    /// on the next launch. The restored history token is dropped first, so no
    /// check can read it after the sentinel is rewritten. Every uninterrupted
    /// call also finishes first-run and incomplete sentinel setup. Returns
    /// true when a restore was consumed.
    @discardableResult
    nonisolated static func rearmRestoreSensitiveLatches(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        invalidateSpotlight: @Sendable () async throws -> Void
    ) async -> Bool {
        if RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager) {
            defaults.removeObject(forKey: postImportHistoryTokenKey)
            CalendarEnricher.defaults.set(
                true, forKey: CalendarEnricher.selectionRevalidationPendingKey)
            do {
                try await invalidateSpotlight()
            } catch {
                Logger(subsystem: "com.travellog.app", category: "RestoreSentinel")
                    .error("Restore re-arm interrupted; the restore stays pending: \(error.localizedDescription)")
                return false
            }
        }
        return RestoreSentinel.consumeRestoreDetection(
            defaults: defaults, fileManager: fileManager)
    }

    /// Which trips the completed-import pass checks for stored titles that
    /// no longer stand (`TripTitleStore.titleStands`).
    nonisolated enum StoredTitleCheckScope: Equatable, Sendable {
        /// Every titled trip: the pass has no bounded history window, is the
        /// daily full pass, or the window touched too many rows to fetch one by one.
        case all
        /// Trip and Stay rows the window inserted or updated. A stay stands
        /// for the trip it belongs to when the unit runs, so a title that
        /// arrived ahead of its stays is checked when they land.
        case changed(trips: Set<PersistentIdentifier>, stays: Set<PersistentIdentifier>)
    }

    /// Above this many changed Trip and Stay rows, one batched scan of every
    /// titled trip is cheaper than fetching each row.
    nonisolated static let storedTitleCheckRowLimit = 64

    /// What `postImportHistoryWindow` decided: whether the pass runs, the
    /// token it records after completing, and its stored-title check scope.
    nonisolated struct PostImportHistoryWindow: Sendable {
        let mustRun: Bool
        let latest: DefaultHistoryToken?
        let titleRepairScope: StoredTitleCheckScope
    }

    #if DEBUG
    /// `postImportHistoryWindow` without the stored-title check scope.
    nonisolated static func postImportHistoryCheck(
        modelContainer: ModelContainer = AppDelegate.modelContainer,
        defaults: UserDefaults = .standard,
        isPersistentStore: Bool = AppDelegate.containerMode.isPersistent,
        fileManager: FileManager = .default,
        now: Date = .now
    ) -> (mustRun: Bool, latest: DefaultHistoryToken?) {
        let window = postImportHistoryWindow(
            modelContainer: modelContainer, defaults: defaults,
            isPersistentStore: isPersistentStore, fileManager: fileManager, now: now)
        return (window.mustRun, window.latest)
    }
    #endif

    /// Must the completed-import pass run, and which token does it record after
    /// it completes? The app never sets `ModelContext.author`, so an authored
    /// transaction is CloudKit (import, reset) or a schema migration. Ghost and
    /// orphan sweeps mature on a later import whether or not it merged rows, so
    /// their pending observations run the pass too. Titles from an older build
    /// can only have arrived in the window since the last completed pass (an
    /// unfinished pass drops the token), so a bounded window scopes the
    /// stored-title check; every other pass checks every titled trip.
    nonisolated static func postImportHistoryWindow(
        modelContainer: ModelContainer = AppDelegate.modelContainer,
        defaults: UserDefaults = .standard,
        isPersistentStore: Bool = AppDelegate.containerMode.isPersistent,
        fileManager: FileManager = .default,
        now: Date = .now
    ) -> PostImportHistoryWindow {
        guard isPersistentStore else {
            return PostImportHistoryWindow(mustRun: true, latest: nil, titleRepairScope: .all)
        }
        let context = ModelContext(modelContainer)
        // A backup restore brings back defaults that may have been captured apart
        // from the store, so no stored token can bound it until the launch consumes it.
        guard !RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager) else {
            return PostImportHistoryWindow(
                mustRun: true, latest: newestHistoryToken(in: context), titleRepairScope: .all)
        }
        let observing = [
            TripDeduplicator.firstObservedGhostsKey,
            PhotoAnnotationDeduplicator.firstObservedOrphansKey,
            PhotoImportPingDeduplicator.orphanPingFirstObservedKey,
        ].contains { defaults.dictionary(forKey: $0)?.isEmpty == false }
        guard defaults.string(forKey: postImportHistorySchemaKey)
                == CurrentTravelLogSchema.versionIdentifier.description,
              let data = defaults.data(forKey: postImportHistoryTokenKey),
              let stored = try? JSONDecoder().decode(DefaultHistoryToken.self, from: data)
        else {
            return PostImportHistoryWindow(
                mustRun: true, latest: newestHistoryToken(in: context), titleRepairScope: .all)
        }
        // A token minted by another store file, or one ahead of this file's
        // history, cannot bound it: a fetch past such a token returns nothing.
        let newest = newestHistoryToken(in: context)
        guard let storedValue = stored.tokenValue, let newestValue = newest?.tokenValue,
              newestValue.allSatisfy({ store, transaction in
                  storedValue[store].map { $0 <= transaction } ?? false
              })
        else { return PostImportHistoryWindow(mustRun: true, latest: newest, titleRepairScope: .all) }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate<DefaultHistoryTransaction> { $0.token > stored }))
        } catch {
            return PostImportHistoryWindow(mustRun: true, latest: newest, titleRepairScope: .all)
        }
        let remote = transactions.contains { $0.author != nil }
        // A missing stamp or a clock set back counts as overdue.
        let overdue = (defaults.object(forKey: postImportLastFullPassAtKey) as? Date).map {
            now < $0 || now.timeIntervalSince($0) >= postImportFullPassInterval
        } ?? true
        let mustRun = remote || observing || overdue
        return PostImportHistoryWindow(
            mustRun: mustRun,
            latest: transactions.map(\.token).max() ?? stored,
            titleRepairScope: mustRun && !overdue
                ? storedTitleCheckScope(for: transactions) : .all)
    }

    /// The Trip and Stay rows a history window inserted or updated, or `.all`
    /// past `storedTitleCheckRowLimit`. Deletes are skipped: a deleted row has
    /// no title to check, and the daily full pass backstops the rare case of
    /// a deleted stay whose loss leaves a title stale.
    nonisolated static func storedTitleCheckScope(
        for transactions: [DefaultHistoryTransaction]
    ) -> StoredTitleCheckScope {
        let tripEntity = Schema.entityName(for: Trip.self)
        let stayEntity = Schema.entityName(for: Stay.self)
        var trips = Set<PersistentIdentifier>()
        var stays = Set<PersistentIdentifier>()
        for transaction in transactions {
            for change in transaction.changes {
                if case .delete = change { continue }
                let row = change.changedPersistentIdentifier
                if row.entityName == tripEntity {
                    trips.insert(row)
                } else if row.entityName == stayEntity {
                    stays.insert(row)
                } else {
                    continue
                }
                guard trips.count + stays.count <= storedTitleCheckRowLimit else { return .all }
            }
        }
        return .changed(trips: trips, stays: stays)
    }

    nonisolated static func newestHistoryToken(in context: ModelContext) -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetchHistory(descriptor))?.first?.token
    }

    /// Record only after the whole pass and only when every unit completed,
    /// so the landed rows stay visible to the next import's check.
    /// An unfinished pass drops the token: a pass that only a pending
    /// observation started has no authored row left to start the retry.
    /// A pass whose title unit checked only the window's rows is not a full
    /// pass, so frequent small imports cannot postpone the daily one.
    nonisolated static func finishPostImportPass(
        _ window: PostImportHistoryWindow, completed: Bool, now: Date = .now,
        defaults: UserDefaults = .standard
    ) {
        if completed {
            recordPostImportHistoryToken(
                window.latest, fullPassAt: window.titleRepairScope == .all ? now : nil,
                defaults: defaults)
        } else {
            defaults.removeObject(forKey: postImportHistoryTokenKey)
        }
    }

    /// `fullPassAt` stamps a completed full pass; a skip leaves the stamp alone.
    nonisolated static func recordPostImportHistoryToken(
        _ token: DefaultHistoryToken?, fullPassAt: Date? = nil, defaults: UserDefaults = .standard
    ) {
        guard let token, let data = try? JSONEncoder().encode(token) else { return }
        defaults.set(data, forKey: postImportHistoryTokenKey)
        defaults.set(CurrentTravelLogSchema.versionIdentifier.description,
                     forKey: postImportHistorySchemaKey)
        if let fullPassAt { defaults.set(fullPassAt, forKey: postImportLastFullPassAtKey) }
    }

    /// Reconciles the device-local hash after local or CloudKit Home changes.
    /// It owns a short gate unit so callers must invoke it after, never from
    /// inside, another PipelineGate unit. Nil when the read or save failed.
    @discardableResult
    nonisolated static func reconcileActiveHomeTitleFingerprint(
        modelContainer: ModelContainer = AppDelegate.modelContainer
    ) async -> Int? {
        await PipelineGate.shared.runReturning(touching: [.home, .trip]) {
            let context = ModelContext(modelContainer)
            do {
                return try TripTitleStore.reconcileActiveHomeTitleFingerprint(
                    in: context)
            } catch {
                Logger(
                    subsystem: "com.travellog.app",
                    category: "HomeTitleFingerprint"
                ).error("Home-title fingerprint reconciliation failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: - Remote Notifications (CloudKit)

    nonisolated static func shouldRunPostCloudImportMaintenance(
        eventType: NSPersistentCloudKitContainer.EventType,
        endDate: Date?,
        succeeded: Bool,
        iCloudEnabled: Bool
    ) -> Bool {
        iCloudEnabled && eventType == .import && endDate != nil && succeeded
    }

    /// A completed failed import/export is an asynchronous sync failure worth
    /// surfacing. Setup failures are handled by container construction above;
    /// an event with no end date is still in progress, not a failure result.
    nonisolated static func shouldRecordCloudKitSyncFailure(
        eventType: NSPersistentCloudKitContainer.EventType,
        endDate: Date?,
        succeeded: Bool
    ) -> Bool {
        !succeeded && endDate != nil && (eventType == .import || eventType == .export)
    }

    /// Localized diagnostic persisted in the same Settings surface as setup
    /// failures. ISO 8601 keeps the recorded instant unambiguous across locale
    /// or time-zone changes after the event.
    nonisolated static func cloudKitSyncFailureDescription(
        eventType: NSPersistentCloudKitContainer.EventType,
        errorDescription: String,
        timestamp: Date
    ) -> String? {
        let timestampText = ISO8601DateFormatter().string(from: timestamp)
        switch eventType {
        case .import:
            return String(
                localized: "settings.icloud.sync-error.import",
                defaultValue: "iCloud import failed at \(timestampText): \(errorDescription)",
                comment: "Settings iCloud diagnostic for a failed asynchronous import; arguments are timestamp and error detail."
            )
        case .export:
            return String(
                localized: "settings.icloud.sync-error.export",
                defaultValue: "iCloud export failed at \(timestampText): \(errorDescription)",
                comment: "Settings iCloud diagnostic for a failed asynchronous export; arguments are timestamp and error detail."
            )
        case .setup:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - One-shot backfill latch policy

    /// Last remote CloudKit change push, stamped only by the push handler. A push
    /// newer than the last completed import defers `BackfillLatchPolicy`
    /// latches. Device-local by design.
    nonisolated static let lastRemoteImportAtKey = "lastRemoteImportAt_v1"

    /// End of the last successful CloudKit import event. Stamped only from
    /// completed import events, never from pushes, so the ghost and orphan
    /// sweeps and `BackfillLatchPolicy` can tell a caught-up store from one
    /// still importing.
    nonisolated static let lastSuccessfulCloudImportAtKey = "lastSuccessfulCloudImportAt_v1"

    /// Start of that same import. A push older than this start was covered
    /// by the import; a newer one means another import is pending.
    nonisolated static let lastSuccessfulCloudImportStartedAtKey = "lastSuccessfulCloudImportStartedAt_v1"

    /// True between a CloudKit import's start and end events. In memory only:
    /// a process that dies mid-import starts the next launch with no import
    /// running until the container reports one.
    nonisolated static let cloudImportInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Start of the latest CloudKit import this process saw begin, succeeded
    /// or not. In memory only, like the flag.
    nonisolated static let lastCloudImportStartedAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// Whether this process's store syncs with CloudKit. Fixed once the
    /// container has opened (a failed CloudKit open clears the preference
    /// first), unlike the preference, which Settings changes for the next
    /// launch. `didFinishLaunching` reads it before any screen can.
    nonisolated static let storeSyncsWithCloudThisLaunch: Bool = {
        _ = modelContainer
        return containerMode.isPersistent
            && UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
    }()

    /// The sync mode the last persistent launch ran with.
    nonisolated static let lastLaunchSyncedWithCloudKey = "lastLaunchSyncedWithCloud"

    /// The one-shot dataset repairs a launch may latch after one pass over
    /// its store.
    nonisolated static var datasetRepairCompletionKeys: [String] {
        [
            airportBackfillDatasetKey,
            tripCountryCodesRecomputeCompletedKey,
            offlineGeocoderBackfillCompletedKey,
            restoreWipedStayCountryCompletedKey,
            tripSummaryMetroRefreshCompletedKey,
            localityCountryNameSweepCompletedKey,
            stayLocalityFallbackBackfillCompletedKey,
        ]
    }

    /// A local-only launch latches these repairs over whatever its store
    /// holds, an empty one at first setup included, so the first launch that
    /// syncs after a local-only one re-arms them: history CloudKit brings in
    /// then is repaired like any other store's. A missing marker (an install
    /// from before it was recorded, or a fresh one) re-arms too, once: it
    /// cannot prove the latches ran over synced history. Returns true when it
    /// re-armed.
    @discardableResult
    nonisolated static func rearmDatasetRepairsOnCloudTransition(
        syncsWithCloud: Bool = storeSyncsWithCloudThisLaunch,
        isPersistentStore: Bool = containerMode.isPersistent,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard isPersistentStore else { return false }
        let previous = defaults.object(forKey: lastLaunchSyncedWithCloudKey) as? Bool
        let rearm = previous != true && syncsWithCloud
        if rearm {
            for key in datasetRepairCompletionKeys { defaults.removeObject(forKey: key) }
        }
        defaults.set(syncsWithCloud, forKey: lastLaunchSyncedWithCloudKey)
        return rearm
    }

    /// May a one-shot repair backfill latch its completion gate now?
    /// The PASS always runs (idempotent); only the permanent latch defers
    /// while the CloudKit store may still be hydrating. See
    /// `BackfillLatchPolicy` for the rule. It reads this launch's sync mode,
    /// never the next launch's preference.
    nonisolated static func mayLatchOneShotBackfill(
        processedRows: Int, passStartedAt: Date
    ) -> Bool {
        let defaults = UserDefaults.standard
        return BackfillLatchPolicy.mayLatch(.init(
            isPersistentStore: containerMode.isPersistent,
            iCloudSyncEnabled: storeSyncsWithCloudThisLaunch,
            processedRowCount: processedRows,
            lastRemoteImportAt: defaults.object(forKey: lastRemoteImportAtKey) as? Date,
            lastSuccessfulImportAt: defaults.object(
                forKey: lastSuccessfulCloudImportAtKey) as? Date,
            lastSuccessfulImportStartedAt: defaults.object(
                forKey: lastSuccessfulCloudImportStartedAtKey) as? Date,
            importInFlight: cloudImportInFlight.withLock { $0 },
            lastImportStartedAt: lastCloudImportStartedAt.withLock { $0 },
            passStartedAt: passStartedAt,
            now: .now
        ))
    }

    /// Cheap COUNT over the table a backfill repairs, for the latch policy.
    nonisolated static func backfillRowCount<T: PersistentModel>(
        _ type: T.Type, in container: ModelContainer = AppDelegate.modelContainer
    ) -> Int {
        (try? ModelContext(container).fetchCount(FetchDescriptor<T>())) ?? 0
    }
}

/// Trailing-edge coalescer shared by the CloudKit remote-push optimization and
/// completed-import correctness path. A large import's sync-back arrives as a
/// burst; `schedule` collapses pending work behind a ~1.5 s quiet window while
/// completed-import work has priority over speculative pushes. Each caller
/// awaits the pass it scheduled or joined, and an already-running pass remains
/// serialized with any genuinely later authoritative work.
actor RemotePushCoalescer {
    private var pending: Task<Void, Never>?
    private var pendingIsAuthoritative = false
    private var pendingToken: UUID?

    /// Track executing work separately from pending sleep cancellation;
    /// new passes must await this handle to keep maintenance serialized.
    private var running: Task<Void, Never>?
    private var runningToken: UUID?

    /// Debounce window. Long enough to swallow a push burst, short enough that
    /// an isolated sync reflects within a beat (well under CloudKit's own
    /// propagation latency).
    private let quietWindow: Duration
    #if DEBUG
    private var quietWaitForTesting: (@Sendable () async throws -> Void)?
    private var admittedForTesting: (@Sendable () async -> Void)?

    init(waitForQuietWindow: @escaping @Sendable () async throws -> Void,
         admitted: @escaping @Sendable () async -> Void) {
        quietWindow = .zero
        quietWaitForTesting = waitForQuietWindow
        admittedForTesting = admitted
    }
    #endif

    init(quietWindow: Duration = .milliseconds(1500)) {
        self.quietWindow = quietWindow
    }

    /// An authoritative completed-import pass replaces pending speculative
    /// push work. A later speculative push instead joins that authoritative
    /// pass, so it can never cancel the post-merge correctness path. A push
    /// superseded by or joined to that pass also awaits it, and every
    /// completed-import pass that later replaces it, before returning.
    func schedule(
        authoritative: Bool = false,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        if !authoritative, pendingIsAuthoritative, let pending, let pendingToken {
            #if DEBUG
            await admittedForTesting?()
            #endif
            await pending.value
            await awaitAuthoritativeReplacements(of: pendingToken)
            return
        }
        pending?.cancel()
        let token = UUID()
        let quietWindow = quietWindow
        #if DEBUG
        let quietWait = quietWaitForTesting
        #endif
        let task = Task { [weak self] in
            // A newer push cancels this sleep → we bail without running `work`;
            // that newer push's task carries the trailing pass instead.
            do {
                #if DEBUG
                if let quietWait { try await quietWait() }
                else { try await Task.sleep(for: quietWindow) }
                #else
                try await Task.sleep(for: quietWindow)
                #endif
            }
            catch { return }
            // Serialize with any pass already executing (see `running`).
            await self?.awaitRunningPass()
            // Cancellation may have arrived while this task was suspended on
            // the prior pass. The replacement owns the trailing execution.
            guard !Task.isCancelled else { return }
            guard let (token, execution) = await self?.beginRunning(work) else {
                return
            }
            await execution.value
            await self?.endRunning(token)
        }
        pending = task
        pendingIsAuthoritative = authoritative
        pendingToken = token
        #if DEBUG
        await admittedForTesting?()
        #endif
        await task.value
        if pendingToken == token {
            pending = nil
            pendingIsAuthoritative = false
            pendingToken = nil
        }
        await awaitAuthoritativeReplacements(of: token)
    }

    /// Completed-import passes run outside any background window, and a newer
    /// completed import replaces one still pending or running. Hold the
    /// caller's window through each replacement until the last one finishes.
    private func awaitAuthoritativeReplacements(of token: UUID) async {
        var awaited = token
        while pendingToken != awaited, pendingIsAuthoritative,
              let next = pending, let nextToken = pendingToken {
            await next.value
            awaited = nextToken
        }
    }

    private func awaitRunningPass() async {
        guard let running, let token = runningToken else { return }
        await running.value
        // A waiter can resume before the original owner's post-await cleanup.
        // Clear the completed handle here too so the atomic replacement
        // registration does not mistake finished work for an active pass.
        endRunning(token)
    }

    private func beginRunning(
        _ work: @escaping @Sendable () async -> Void
    ) -> (UUID, Task<Void, Never>)? {
        // Registration and the empty-running check are one actor-isolated
        // operation, so two replacement tasks cannot both start work.
        guard !Task.isCancelled, running == nil else { return nil }
        let token = UUID()
        let task = Task { await work() }
        running = task
        runningToken = token
        return (token, task)
    }

    private func endRunning(_ token: UUID) {
        // Only clear our own handle — a newer pass may have replaced it.
        if runningToken == token {
            running = nil
            runningToken = nil
        }
    }
}
