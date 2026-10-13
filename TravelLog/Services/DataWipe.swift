//
//  DataWipe.swift
//  TravelLog
//
//  The "Delete All Data" store wipe as a result-returning service: a
//  partially failed wipe must never be presented as success.
//
//  The declared type lists below are the wipe's CONTRACT, pinned by
//  `DataWipeTests`: every entity in the current schema must appear in
//  exactly one of them, so a future schema bump that adds an entity
//  without deciding its wipe fate fails the suite instead of silently
//  surviving "Delete Everything".
//

import Foundation
import os.log
import SwiftData
import UserNotifications

enum DataWipe {

    private static let logger = Logger(
        subsystem: "com.travellog.app", category: "DataWipe")

    /// The `@Model` types "Delete All Data" erases, in deletion order.
    /// Why each type is wiped:
    /// - `HiddenPhoto`/`PinnedPhoto`: no inverse on Trip, so SwiftData can't
    ///   cascade — wiped explicitly as subordinate photo metadata.
    /// - `PhotoImportState`: a stale completed/failed banner must not linger
    ///   over data that no longer exists, and a still-running background
    ///   import stops cleanly via its own `fetchState()==nil` guard.
    /// - `YearWrapped`/`PlannedTrip`: annual memories / upcoming cards of the
    ///   trips just deleted — stale by construction; both regrow from source
    ///   (calendar, next December's data).
    /// - `HomeAreaOverride`: derived FROM the erased travel history;
    ///   surviving rows would silently reshape whatever is imported next.
    /// - `Visit`: raw travel evidence, so rows are wiped.
    /// - `TripTitleVariant`: derived from an erased trip title. It is listed
    ///   explicitly even though the Trip relationship cascades, so schema
    ///   accounting and partial-store edge cases cannot let translated title
    ///   history survive a user-requested wipe.
    nonisolated static var wipedModelTypes: [any PersistentModel.Type] { [
        TripTitleVariant.self,
        Trip.self,
        Stay.self,
        LocationPing.self,
        HexVisit.self,
        HiddenPhoto.self,
        PinnedPhoto.self,
        PhotoImportState.self,
        YearWrapped.self,
        PlannedTrip.self,
        HomeAreaOverride.self,
        Visit.self,
    ] }

    /// Entities that deliberately SURVIVE the wipe: the user's own setup,
    /// not travel history. A temporary home is one of the user's homes; an
    /// active one wiped mid-stay would silently start a giant trip. Removed
    /// ones survive too, so a backup or a twin cannot bring them back.
    nonisolated static let survivingEntityNames: Set<String> = [
        "Home", "RoutinePlace", "TemporaryHome",
    ]

    /// Executes the store wipe on the container's main context (the
    /// `performMerge` shape — static, no view state). Also clears the
    /// store-derived side state that would poison the next store: the
    /// home-area healing fingerprint + coverage snapshot (they describe the
    /// old store; the first heal against the new one must start honest), the
    /// dissolve review queue (its records point at stays that no longer exist
    /// — restoration is impossible by construction). The Visit and live
    /// acceptance floors advance together after a successful commit so
    /// pre-wipe callbacks, buffered fixes and failed-save retries are rejected.
    /// The temporary-home acknowledgements are cleared after the commit too:
    /// they schedule work about the old store, so a failure to clear them
    /// only replays a unit and is logged, not reported.
    /// After the commit it also retires this device's obsolete pre-App-Group
    /// store family, only when the open persistent store is positively a
    /// different file; a failed or unproven removal keeps a durable marker
    /// that the next successful persistent open retries.
    /// The app's notifications go too, pending and delivered (country names,
    /// days away, the recap reminder), with the travel-notification state and
    /// recap latches and the dismissals that name deleted trips and stays.
    /// Alert preferences stay. Synced favourites and backup-import fences
    /// also stay, since they are shared with devices that were not wiped.
    ///
    /// Returns `false` when any delete or the final save failed — the caller
    /// must surface that instead of reporting success. The dissolve queue is
    /// cleared only after the store commit: clearing it before a failed,
    /// rolled-back wipe would destroy recovery records for trips that remain.
    /// A post-commit queue failure falls back to removing the queue file
    /// directly. If personal queue data still remains, the result is `false`
    /// even though the store deletion itself committed. The post-commit
    /// callback runs before that cleanup and never on rollback. Callers run
    /// this inside a `PipelineGate` unit; it never takes the gate itself.
    @MainActor
    static func execute(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        beforeCommit: () throws -> Void = {},
        afterCommit: @MainActor () -> Void = {},
        clearDissolvedQueue: () throws -> Void = {
            try DissolvedTripQueue.clear()
        },
        dissolvedQueueFileURL: () -> URL? = {
            DissolvedTripQueue.fileURL()
        },
        removeDissolvedQueueFile: (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        clearTemporaryHomeAcknowledgements: () throws -> Void = {
            try CoverageReconciliationQueue.Acknowledgements.clear()
        },
        obsoleteStoreFamily: (ModelContainer) -> ObsoleteStoreFamily? = {
            DataWipe.applicationObsoleteStoreFamily(for: $0)
        },
        removeStoreFile: (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        removeAllNotifications: () -> Void = {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
    ) -> Bool {
        let modelContext = container.mainContext
        // Rollback is context-wide; preserve earlier pending edits first.
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        do {
            // Stage row-wise context deletions and commit once. The bulk
            // `delete(model:)` API bypasses rollback; registered row deletes
            // remain pending and are fully discarded if any step fails.
            for type in wipedModelTypes {
                try deleteAll(type, in: modelContext)
            }
            try beforeCommit()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return false
        }
        afterCommit()
        // One committed instant for both floors: late Visit callbacks and
        // buffered or retried live fixes from before the wipe are rejected.
        let committedAt = Date.now
        defaults.set(committedAt, forKey: VisitRecorder.acceptanceFloorKey)
        defaults.set(committedAt, forKey: PingRecorder.liveAcceptanceFloorKey)
        defaults.removeObject(forKey: HomeAreaHealing.fingerprintKey)
        defaults.removeObject(forKey: HomeAreaHealing.coverageKey)
        defaults.removeObject(forKey: HomeAreaHealing.coverageStampedAtKey)
        defaults.removeObject(forKey: AppDelegate.postImportHistoryTokenKey)
        // These observe rows the wipe just deleted.
        defaults.removeObject(forKey: PlacesDeduplicator.homeAliasesKey)
        defaults.removeObject(forKey: CoverageReconciliationQueue.pendingKey)
        defaults.removeObject(forKey: CoverageReconciliationQueue.removalHintsKey)
        defaults.removeObject(forKey: CoverageReconciliationQueue.temporaryHomeStatusKey)
        do {
            try clearTemporaryHomeAcknowledgements()
        } catch {
            logger.error("Delete All Data could not clear the temporary-home acknowledgements: \(error.localizedDescription)")
        }
        // The retired temporary-home coverage trail, still on devices that ran it.
        defaults.removeObject(forKey: "temporaryHomeCoverageTrail_v1")
        defaults.removeObject(forKey: TripDeduplicator.firstObservedGhostsKey)
        defaults.removeObject(forKey: PhotoAnnotationDeduplicator.firstObservedOrphansKey)
        defaults.removeObject(forKey: PhotoImportPingDeduplicator.orphanPingFirstObservedKey)
        // Carry aliases name deleted trips; a stale one must not re-key a
        // favourite or photo row restored later under the old UUID.
        defaults.removeObject(forKey: TripDeduplicator.carriedFavouritesKey)
        // Notifications name countries and days away; the dedup state and the
        // recap latches describe the erased history. A live add still in
        // flight at this instant can land afterwards; it is not awaited, so a
        // slow notification daemon never delays saving raw location batches.
        removeAllNotifications()
        NotificationService.clearTravelState(defaults: defaults)
        YearWrappedGenerator.clearScheduledNotificationFlags(defaults: defaults)
        // Dismissals keyed by deleted trips, stays and import sessions.
        defaults.removeObject(forKey: FlightCandidateDismissals.defaultsKey)
        defaults.removeObject(forKey: TemporaryHomeSuggestion.dismissalsKey)
        defaults.removeObject(forKey: TemporaryHomeCards.endHintDismissalsKey)
        // RootView's photo-import banner dismissal (its `@AppStorage` key).
        defaults.removeObject(forKey: "photoImportBannerDismissedSessionKey")
        // Staged backups and diagnostics hold the erased history.
        TripDataExporter.removeStagedExports()
        #if DEBUG
        DebugGateAudit.clear()
        DebugHealLog.clear()
        #endif
        var postCommitCleanupSucceeded = true
        do {
            try PhotoImportCheckpointJournal.clear(in: container)
        } catch {
            logger.error("Delete All Data could not clear the import checkpoint journal: \(error.localizedDescription)")
            postCommitCleanupSucceeded = false
        }
        // Store-family migration preserves the old database, its WAL/SHM and
        // its copied import journal as a backup until an explicit committed
        // wipe. Attempted independently of the active journal above.
        if let family = obsoleteStoreFamily(container),
           !retireObsoleteStoreFamily(family, defaults: defaults, removeItem: removeStoreFile) {
            postCommitCleanupSucceeded = false
        }
        do {
            try clearDissolvedQueue()
        } catch {
            logger.error(
                "Delete All Data committed, but the dissolved-trip queue could not be cleared: \(error.localizedDescription)")
            if let queueURL = dissolvedQueueFileURL() {
                do {
                    try removeDissolvedQueueFile(queueURL)
                } catch CocoaError.fileNoSuchFile {
                    // Missing is already clear.
                } catch {
                    logger.error(
                        "Delete All Data queue-file fallback failed: \(error.localizedDescription)")
                }
                if FileManager.default.fileExists(atPath: queueURL.path) {
                    logger.error("Delete All Data failed because dissolved-trip personal data remains on disk.")
                    postCommitCleanupSucceeded = false
                }
            } else {
                postCommitCleanupSucceeded = false
            }
        }
        return postCommitCleanupSucceeded
    }

    /// Durable authority to retire this device's obsolete pre-App-Group
    /// store family. Set before removal and cleared only once no family file
    /// remains, so an interrupted or failed removal is retried after the next
    /// successful persistent open, and that launch never remigrates the
    /// wiped backup into a missing App Group store.
    nonisolated static let legacyStoreRemovalPendingKey = "legacyStoreRemovalPending_v1"

    /// The legacy family and the store this wipe committed to.
    nonisolated struct ObsoleteStoreFamily: Sendable {
        let legacy: URL
        let active: URL
    }

    /// Only the application's own persistent container can retire the
    /// legacy family; fixture and in-memory containers never reach it.
    nonisolated static func applicationObsoleteStoreFamily(
        for container: ModelContainer
    ) -> ObsoleteStoreFamily? {
        guard container === AppDelegate.modelContainer,
              AppDelegate.containerMode.isPersistent,
              let active = container.configurations.first?.url else { return nil }
        return ObsoleteStoreFamily(
            legacy: AppDelegate.legacyStoreURL(schema: container.schema),
            active: active)
    }

    /// Returns false while any obsolete family file remains or authority
    /// cannot be proven; the marker then stays set for the launch retry.
    @MainActor
    private static func retireObsoleteStoreFamily(
        _ family: ObsoleteStoreFamily,
        defaults: UserDefaults,
        removeItem: (URL) throws -> Void
    ) -> Bool {
        if AppDelegate.obsoleteStoreFamilyNeedsRetirement(
            legacyURL: family.legacy, activeURL: family.active) {
            defaults.set(true, forKey: legacyStoreRemovalPendingKey)
        }
        guard let outcome = AppDelegate.retireObsoleteStoreFamilyIfPending(
            legacyURL: family.legacy, activeURL: family.active,
            defaults: defaults, logger: logger, removeItem: removeItem) else {
            return true
        }
        if !outcome.isComplete {
            logger.error("Delete All Data committed, but the obsolete pre-App-Group store could not be removed (\(String(describing: outcome), privacy: .public)).")
        }
        return outcome.isComplete
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws {
        // `context.delete(model:)` issues a store-level batch delete that
        // SwiftData does not roll back when a later entity fails. Fetching
        // and deleting registered rows keeps the whole wipe inside the
        // surrounding transaction's actual undo boundary.
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }
}
