//
//  TripsListView+TripActions.swift
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

    func tripDiscoveryTip(for trip: Trip) -> (any Tip)? {
        guard !isProcessing, !isSearching, !trip.isDeleted,
              !(trip.stays ?? []).isEmpty,
              !PinnedTripsStorage.shared.isPinned(trip.id) else { return nil }
        guard correctionTipLearned else { return DismissTripTip() }
        let adjacent = adjacentTrips(for: trip)
        return adjacent.newer != nil || adjacent.older != nil ? MergeTripsTip() : nil
    }

    // MARK: - Merge

    private func adjacentTrips(for trip: Trip) -> (newer: Trip?, older: Trip?) {
        let row = trip.persistentModelID
        guard let index = trips.firstIndex(where: { $0.persistentModelID == row }) else { return (nil, nil) }
        // A UUID twin is never offered: twins are one journey, and the merge worker refuses them.
        let newer = index > 0 ? trips[index - 1] : nil
        let older = index < trips.count - 1 ? trips[index + 1] : nil
        return (newer?.id == trip.id ? nil : newer, older?.id == trip.id ? nil : older)
    }

    /// Keep the internal pin name and iCloud KVS key stable while displaying “Favorite”.
    @ViewBuilder
    func tripContextMenu(for trip: Trip) -> some View {
        let isFavorite = PinnedTripsStorage.shared.isPinned(trip.id)
        Button {
            PinnedTripsStorage.shared.toggle(trip.id)
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: isFavorite ? "star.slash" : "star")
        }
        Button {
            guard !trip.isDeleted else { return }
            shareRequest = TripShareRequest(tripIDs: [trip.id])
        } label: {
            Label(String(localized: "trip-share.menu.share", defaultValue: "Share…",
                         comment: "Context menu and toolbar action that opens the trip share sheet."),
                  systemImage: "square.and.arrow.up")
        }

        let adjacent = adjacentTrips(for: trip)
        if adjacent.newer != nil || adjacent.older != nil {
            Divider()
        }
        if let newer = adjacent.newer {
            let newerName = newer.displayName
            Button {
                mergeSourceTrip = newer
                mergeTargetTrip = trip
            } label: {
                Label("Merge with \(newerName)", systemImage: "arrow.triangle.merge")
            }
        }
        if let older = adjacent.older {
            let olderName = older.displayName
            Button {
                mergeSourceTrip = trip
                mergeTargetTrip = older
            } label: {
                Label("Merge with \(olderName)", systemImage: "arrow.triangle.merge")
            }
        }

        Divider()

        // A long stay somewhere is better declared than left as one long trip.
        if TemporaryHomeFormSheet.Prefill.isOffered(
            isComplete: trip.isComplete, startDate: trip.startDate, endDate: trip.endDate) {
            Button {
                guard !trip.isDeleted else { return }
                temporaryHomeSheetMode = .add(prefill: TemporaryHomeFormSheet.Prefill.forTrip(trip))
            } label: {
                Label(
                    String(
                        localized: "trips.context.set-up-temporary-home",
                        defaultValue: "Set Up a Temporary Home…",
                        comment: "Trip context menu action that opens the form for a new temporary home, prefilled from this trip."
                    ),
                    systemImage: "house.and.flag"
                )
            }
        }

        // Teach ordinary-life membership with a persisted include disc; apply immediately and offer undo.
        Button {
            demoteTrip(trip)
        } label: {
            Label("This Wasn't a Trip", systemImage: "house")
        }

        Button(role: .destructive) {
            tripToDelete = trip
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Home-area correction apply: runs the classifier worker in a gate unit, cleans the
    /// pin, reloads widgets, and offers undo via `demotedTripName`.
    private func demoteTrip(_ trip: Trip) {
        guard !trip.isDeleted else { return }
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        Task {
            let outcome = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto]) {
                await AppDelegate.tripClassifier.demoteTripToHomeArea(
                    tripID: tripID, tripIdentifier: tripIdentifier)
            }
            let name: String
            switch outcome {
            case .demoted(let tripName):
                name = tripName
            case .unavailable:
                return
            case .failed:
                // Nothing committed: the trip, its favourite and any earlier Undo stand.
                saveFailed = true
                return
            }
            DismissTripTip.hasLearnedCorrection = true
            DismissTripTip().invalidate(reason: .actionPerformed)
            correctionTipLearned = true
            demotedFavouriteID = Self.unpinUnlessTripRowSurvives(tripID) ? tripID : nil
            // Invalidate cached photos for the trip whose annotation rows were removed.
            PhotoService.shared.invalidateCache(for: tripID)
            // The demote's restoration record (the soft-delete contract
            // covers Arm B too) is already in Removed Trips: the classifier's
            // sink persisted it before the deleting save, which cannot commit
            // without it. Appending it again here, outside the gate, could
            // restore it after a Delete All Data or a Forget in between.
            StoreChangeTracker.shared.bump([.stay, .trip, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto])
            WidgetCenter.shared.reloadAllTimelines()
            recomputeTripSlices()
            demotedTripName = name
            // Heal other trips claimed by the new include disc.
            await HomeAreaHealing.healIfNeeded()
            recomputeTripSlices()
        }
    }

    /// Restore the trip’s original row and heal-dissolved siblings BEFORE the pipeline can remint their stays.
    /// Undo also removes the include override; stable identities preserve the review queue.
    func undoDemotion() {
        let favourite = demotedFavouriteID
        demotedFavouriteID = nil
        Task {
            let queued = await Task.detached(priority: .userInitiated) {
                DissolvedTripQueue.load()
            }.value
            let outcome = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto]) {
                () -> (TripClassifier.DemotionUndoOutcome, [UUID]) in
                let undo = await AppDelegate.tripClassifier.undoLastDemotion()
                guard undo == .undone else { return (undo, []) }
                // Siblings freed by the override withdrawal come back under
                // their original identities; missing-stay records are left
                // for the rescue. Not sacred — the withdrawn teaching
                // removed the claim. `.alreadyExists` covers the undone
                // trip's OWN record (undoLastDemotion just re-minted it) —
                // pruned alongside, its trip is back. An earlier demotion's
                // record (nil) stays queued: its stays are still home.
                // Removal goes by id: an older queue's second partial archive
                // of one trip keeps both queued until it comes back too.
                var restoredIDs: [UUID] = []
                var unsettledIDs = Set<UUID>()
                for record in queued {
                    switch await AppDelegate.tripClassifier.restoreFreedSibling(record) {
                    case .restored, .alreadyExists:
                        restoredIDs.append(record.id)
                    case .staysClaimed, .staysMissing, .staysAmbiguous,
                         .saveFailed, nil:
                        unsettledIDs.insert(record.id)
                    }
                }
                return (.undone, restoredIDs.filter { !unsettledIDs.contains($0) })
            }
            let (undo, restoredIDs) = outcome
            switch undo {
            case .undone:
                break
            case .unavailable:
                undoUnavailable = true
                return
            case .failed:
                // The demotion and its queued record stand; keep the
                // favourite so a retried Undo can pin it again.
                demotedFavouriteID = favourite
                undoFailed = true
                return
            }
            // The trip is back under its own UUID, so its favourite is too.
            // Pin before the stages below: a delete or merge the user makes
            // while they run then keeps the last word on the favourite, and
            // the ghost sweep carries an existing pin to a merge winner.
            if let favourite { PinnedTripsStorage.shared.pin(favourite) }
            _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates(
                maxStaysPerCall: nil)
            _ = await AppDelegate.tripClassifier.generateTitlesStage(
                maxTripsPerCall: nil)
            _ = await AppDelegate.tripTitleLocalizationService
                .generateLocalizedTitlesStage(maxTripsPerCall: nil)
            // The undone trip's own record (persisted at demote) and every
            // restored sibling's record leave the queue — their trips are
            // back; a lingering record reads as a removed trip that isn't.
            if !restoredIDs.isEmpty {
                try? DissolvedTripQueue.remove(ids: Set(restoredIDs))
            }
            // Photo rows may have landed on a trip row that synced back first.
            for record in queued
            where restoredIDs.contains(record.id) && record.carriesPhotoAnnotations {
                PhotoService.shared.invalidateCache(for: record.id)
            }
            StoreChangeTracker.shared.bump([.stay, .trip, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto])
            WidgetCenter.shared.reloadAllTimelines()
            recomputeTripSlices()
            await HomeAreaHealing.healIfNeeded()
            recomputeTripSlices()
        }
    }

    /// Serialize merge through PipelineGate; capture Sendable IDs and refetch models on the main context.
    func performMerge(source: Trip, into target: Trip) {
        let sourceID = source.id
        let targetID = target.id
        let sourceIdentifier = source.persistentModelID
        let targetIdentifier = target.persistentModelID
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip, .stay, .hiddenPhoto, .pinnedPhoto]) {
                await Self.mergeTrips(sourceID: sourceID, sourceIdentifier: sourceIdentifier,
                                      targetID: targetID, targetIdentifier: targetIdentifier)
            }
            guard saved else {
                saveFailed = true
                return
            }
            // Move the absorbed trip’s favourite to the merged trip, then free its UUID unless a UUID twin still shows it.
            Self.carryFavouriteAfterMerge(sourceID: sourceID, targetID: targetID)
            // Reflect the merge immediately (the tracker bump is 500 ms
            // debounced); the render-time `filteringDeleted()` drops the
            // absorbed source row in the interim.
            recomputeTripSlices()
            // Reload widgets so they stop rendering the absorbed trip.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// The actual merge, on the main context. Static + ID-based so the gate
    /// closure stays free of non-Sendable captures; refetching also tolerates
    /// either trip having been deleted by a unit that ran ahead of this one
    /// in the gate's queue (guard returns — nothing half-merged).
    /// Both endpoints are the tapped physical rows; a UUID twin never stands in.
    /// Container-injected test seam for TripDestructiveOpsTests.
    @discardableResult
    static func mergeTrips(
        sourceID: UUID, sourceIdentifier: PersistentIdentifier,
        targetID: UUID, targetIdentifier: PersistentIdentifier,
        container: ModelContainer = AppDelegate.modelContainer,
        gapAnswers: UserDefaults = .standard
    ) -> Bool {
        let modelContext = container.mainContext
        // Rollback is context-wide; preserve earlier pending edits first.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                logger.error("Trip merge pre-save failed: \(error.localizedDescription)")
                return false
            }
        }
        // UUID twins of one journey are the same trip to the user; merging a
        // row into its own UUID would move its stays onto itself and then
        // delete that row, leaving them without a trip.
        guard sourceID != targetID else {
            logger.error("Trip merge refused: source and target share a UUID.")
            return false
        }
        let source: Trip
        let target: Trip
        do {
            guard let foundSource = try fetchTrip(id: sourceID, identifier: sourceIdentifier, in: modelContext),
                  let foundTarget = try fetchTrip(id: targetID, identifier: targetIdentifier, in: modelContext)
            else { return false }
            source = foundSource
            target = foundTarget
        } catch {
            logger.error("Trip merge trip fetch failed: \(error.localizedDescription)")
            return false
        }

        let sourceRows = Set((source.stays ?? []).map(\.persistentModelID))
        for stay in (source.stays ?? []) {
            stay.trip = target
        }

        let allStays = (target.stays ?? []).sorted { $0.startTime < $1.startTime }
        for (index, stay) in allStays.enumerated() {
            stay.orderInTrip = index
        }
        // The user joined these gaps: the merged trip never asks about them.
        let mergeSeams = TripGapAnswers.mergeSeams(allStays.map {
            (id: $0.id, category: $0.category, fromSource: sourceRows.contains($0.persistentModelID))
        })

        target.startDate = min(source.startDate, target.startDate)
        if let sourceEnd = source.endDate, let targetEnd = target.endDate {
            target.endDate = max(sourceEnd, targetEnd)
        } else {
            target.endDate = nil
        }
        target.isComplete = source.isComplete && target.isComplete
        target.userEdited = true
        target.keptByTemporaryHome = false
        // The target’s stay set changes: derive its title again.
        TripTitleStore.invalidateGeneratedTitles(
            for: target, in: modelContext)
        target.recomputeSummary()

        // Hidden choices follow the moved stays; pins are not migrated.
        // Clean up source annotations unless a populated UUID twin keeps them.
        do {
            let sourceHidden = try modelContext.fetch(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { $0.tripID == sourceID },
                sortBy: [SortDescriptor(\HiddenPhoto.hiddenAt)]))
            let targetHidden = try modelContext.fetch(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { $0.tripID == targetID }))
            // Same identity as PhotoAnnotationDeduplicator: a row is redundant
            // when its cloud-first stable ID is already on the target, or when
            // it is local-only and the target already hides that local asset.
            var identities = PhotoAnnotationDeduplicator.ChoiceIdentities()
            for row in targetHidden {
                identities.hold(localIdentifier: row.localIdentifier, cloudIdentifier: row.cloudIdentifier)
            }
            for original in sourceHidden {
                guard identities.admit(
                    localIdentifier: original.localIdentifier,
                    cloudIdentifier: original.cloudIdentifier) else { continue }
                let copy = HiddenPhoto(localIdentifier: original.localIdentifier, tripID: targetID)
                copy.cloudIdentifier = original.cloudIdentifier
                copy.hiddenAt = original.hiddenAt
                modelContext.insert(copy)
            }
            try deletePhotoAnnotations(for: source, in: modelContext)
        } catch {
            modelContext.rollback()
            logger.error("Merge annotation fetch failed: \(error.localizedDescription)")
            return false
        }

        // Invalidate both photo caches: the source disappears and the target’s stay set grows.
        PhotoService.shared.invalidateCache(for: source.id)
        PhotoService.shared.invalidateCache(for: target.id)

        modelContext.delete(source)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip merge save failed: \(error.localizedDescription)")
            return false
        }
        TripGapAnswers.confirm(mergeSeams, defaults: gapAnswers)
        MergeTripsTip().invalidate(reason: .actionPerformed)
        return true
    }

    // MARK: - Delete

    /// **Cascade-delete a trip and every record that backed it.**
    /// Remove the trip and all backing evidence to prevent automatic reassembly.
    ///   - Every Stay in the trip (including `userOverridden` stays —
    ///     explicit user delete overrides the "preserve manual category"
    ///     intent of that flag).
    ///   - Every Visit whose scalar `stayID` links it to those stays.
    ///   - Every LocationPing referenced by any of those stays.
    ///   (Evidence a same-UUID Stay twin outside the trip still references is kept.)
    ///   - HexVisit records for hexes whose only remaining pings (after
    ///     the ping deletion above) were in the deleted trip. Hexes
    ///     shared with other trips keep their HexVisit row; `visitCount`
    ///     may run slightly high but the cell stays meaningful.
    ///   - HiddenPhoto / PinnedPhoto rows pointing at the trip.
    ///   - PhotoService's in-memory cache entry for the trip.
    ///
    /// What is NOT touched: photos in the user's Photos library, the
    /// resolver database, Home / RoutinePlace records, sibling trips.
    ///
    /// Caveats surfaced in the confirmation alert:
    ///   - Re-importing the same photos later WILL recreate the trip
    ///     (no excluded-photo-asset memory yet — separate feature).
    ///   - Within a single device this is irreversible. CloudKit replay
    ///     from a still-synced sibling device could resurrect the data;
    ///     same-account devices receive the delete via CloudKit sync.
    ///
    /// Serialize the cascade through PipelineGate using the tapped row's Sendable identity; the worker refetches on the main context.
    func performDelete(_ trip: Trip) {
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        Task {
            // Declare photo-annotation tables because deleteTrip also removes their rows.
            let saved = await PipelineGate.shared.runReturning(
                touching: [.trip, .stay, .hexVisit, .locationPing, .hiddenPhoto, .pinnedPhoto, .visit]
            ) {
                await Self.deleteTrip(tripID: tripID, tripIdentifier: tripIdentifier)
            }
            guard saved else {
                saveFailed = true
                return
            }
            // Revoke the persisted Stats snapshot, which can still name the
            // deleted trip and its places; an open Stats page recomputes.
            StatsSnapshotStore.clear()
            // Remove the deleted trip’s favorite UUID from iCloud KVS unless a UUID twin still shows it.
            Self.unpinUnlessTripRowSurvives(tripID)
            // Recompute immediately so the deleted row disappears without
            // waiting on the 500 ms tracker debounce. `filteringDeleted()`
            // already prevented a trap on the stale slice in the meantime.
            recomputeTripSlices()
            // Reload widgets so the deleted trip disappears there too.
            WidgetCenter.shared.reloadAllTimelines()
            // Deleting the stays can de-qualify a learned orbit disc; the
            // healing pass's shrink arm (stale-coverage snapshot) frees
            // whatever that disc had claimed. Run it now, not at the next
            // app activation; no-op when the fingerprint didn't move.
            await HomeAreaHealing.healIfNeeded()
            recomputeTripSlices()
        }
    }

    /// Trip-only removal preserves stays, pings, and hexes; remove annotations and the favorite with the trip.
    /// Set stays to unclassified + userOverridden so every classifier pass skips them and cannot remint the trip.
    func performRemoveKeepData(_ trip: Trip) {
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        Task {
            let saved = await PipelineGate.shared.runReturning(
                touching: [.trip, .stay, .hiddenPhoto, .pinnedPhoto]
            ) {
                await Self.removeTripKeepData(tripID: tripID, tripIdentifier: tripIdentifier)
            }
            guard saved else {
                saveFailed = true
                return
            }
            // The snapshot can still name the removed trip.
            StatsSnapshotStore.clear()
            Self.unpinUnlessTripRowSurvives(tripID)
            recomputeTripSlices()
            WidgetCenter.shared.reloadAllTimelines()
            await HomeAreaHealing.healIfNeeded()
            recomputeTripSlices()
        }
    }

    @discardableResult
    static func removeTripKeepData(
        tripID: UUID, tripIdentifier: PersistentIdentifier,
        container: ModelContainer = AppDelegate.modelContainer
    ) -> Bool {
        let modelContext = container.mainContext
        // Rollback is context-wide; preserve earlier pending edits first.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                logger.error("Remove-trip-keep-data pre-save failed: \(error.localizedDescription)")
                return false
            }
        }
        let trip: Trip
        do {
            guard let found = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext) else { return true }
            trip = found
        } catch {
            logger.error("Remove-trip-keep-data trip fetch failed: \(error.localizedDescription)")
            return false
        }
        do {
            try deletePhotoAnnotations(for: trip, in: modelContext)
        } catch {
            modelContext.rollback()
            logger.error("Remove-trip-keep-data annotation fetch failed: \(error.localizedDescription)")
            return false
        }
        PhotoService.shared.invalidateCache(for: trip.id)
        for stay in (trip.stays ?? []) {
            stay.trip = nil
            stay.orderInTrip = nil
            stay.category = .unclassified
            // Sacred tombstone: no pass reclassifies an overridden stay, so
            // the removed trip stays removed while its pings keep the map lit.
            stay.userOverridden = true
        }
        modelContext.delete(trip)
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            logger.error("Remove-trip-keep-data save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns false when nothing was deleted: the cascade is rolled back so no
    /// pending deletion can ride along with a later, unrelated save.
    @discardableResult
    static func deleteTrip(
        tripID: UUID, tripIdentifier: PersistentIdentifier,
        container: ModelContainer = AppDelegate.modelContainer
    ) -> Bool {
        let modelContext = container.mainContext
        // The rollback below is context-wide. Commit whatever an earlier failed
        // save left pending first, so a failed cascade cannot discard it too.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                logger.error("Trip cascade pre-save failed: \(error.localizedDescription)")
                return false
            }
        }
        // Tolerate the trip having been deleted by a unit that ran ahead of
        // this one in the gate's queue (e.g. a rapid second delete). A failed
        // read is not absence: report it so the favorite is kept.
        let trip: Trip
        do {
            guard let found = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext) else { return true }
            trip = found
        } catch {
            logger.error("Trip cascade trip fetch failed: \(error.localizedDescription)")
            return false
        }

        let stays = trip.stays ?? []
        let stayIDsToDelete = Set(stays.map(\.id))
        let visitsToDelete: [Visit]
        let pingIDsToDelete: Set<UUID>
        do {
            // Visits link to stays by UUID: a same-UUID Stay twin outside this
            // trip still owns them. Pings belong to every surviving Stay row
            // that references them, whatever its UUID: two devices can cluster
            // the same synced ping into stays of their own.
            let deletedRows = Set(stays.map(\.persistentModelID))
            let candidateIDs = Array(stayIDsToDelete)
            let survivingTwins = try modelContext.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate<Stay> { candidateIDs.contains($0.id) }
            )).filter { !$0.isDeleted && !deletedRows.contains($0.persistentModelID) }
            let keptStayIDs = Set(survivingTwins.map(\.id))
            let keptPingIDs = try pingIDsReferencedBySurvivingStays(
                among: Set(stays.flatMap { $0.pingIDs }), excluding: deletedRows, in: modelContext)
            let descriptor = FetchDescriptor<Visit>(
                predicate: #Predicate<Visit> { $0.stayID != nil }
            )
            visitsToDelete = try modelContext.fetch(descriptor).filter {
                guard let stayID = $0.stayID else { return false }
                return stayIDsToDelete.contains(stayID) && !keptStayIDs.contains(stayID)
            }
            pingIDsToDelete = Set(stays.flatMap { $0.pingIDs }).subtracting(keptPingIDs)
        } catch {
            logger.error("Trip cascade Visit or twin fetch failed: \(error.localizedDescription)")
            return false
        }

        // Include actual deleted-ping hexes, not just centroids: stay pings may span neighboring cells.
        // The remaining-ping guard makes this superset safe to prune.
        var affectedHexes: Set<String> = Set(
            stays
                .map(\.h3IndexRes6)
                .filter { !$0.isEmpty }
        )

        // 3. Visit has no inverse Stay relationship, so SwiftData cannot
        //    cascade these rows. Delete the manual stayID links before their
        //    Stays, just like the trip's relationship-free photo annotations.
        for visit in visitsToDelete { modelContext.delete(visit) }

        // 4. Clean up photo-annotation rows pointing at this trip — no
        //    inverse relationship, so SwiftData can't cascade for us.
        //    A failed dependency read is not absence: stop before any
        //    deletion so the trip cannot vanish while its rows stay behind.
        let pingsToDelete: [LocationPing]
        do {
            try deletePhotoAnnotations(for: trip, in: modelContext)
            pingsToDelete = try fetchPingsForDeletion(ids: pingIDsToDelete, in: modelContext)
        } catch {
            modelContext.rollback()
            logger.error("Trip cascade dependency fetch failed: \(error.localizedDescription)")
            return false
        }

        PhotoService.shared.invalidateCache(for: trip.id)

        for stay in stays {
            modelContext.delete(stay)
        }

        // Record each deleted ping’s own hex for pruning beyond stay centroids.
        for ping in pingsToDelete {
            if !ping.h3IndexRes6.isEmpty { affectedHexes.insert(ping.h3IndexRes6) }
            modelContext.delete(ping)
        }

        modelContext.delete(trip)

        // 9. Save BEFORE the per-hex remaining-ping check so the ping
        //    deletions are visible to the fetch predicate.
        do {
            try modelContext.save()
        } catch {
            // On save failure, stop before hex pruning because its fetch would observe stale ping data.
            // Use Logger so failures remain visible in Release and TestFlight.
            modelContext.rollback()
            logger.error("Trip cascade delete save failed: \(error.localizedDescription)")
            return false
        }

        // 10. Hex pruning. For each affected hex, drop the HexVisit iff
        //    no LocationPing remains in that hex.
        for hex in affectedHexes {
            let h3 = hex
            let remainingDescriptor = FetchDescriptor<LocationPing>(
                predicate: #Predicate<LocationPing> { $0.h3IndexRes6 == h3 }
            )
            // A failed count is not zero: keep the hex rather than prune on a read error.
            guard let remaining = try? modelContext.fetchCount(remainingDescriptor),
                  remaining == 0 else { continue }

            let hexDescriptor = FetchDescriptor<HexVisit>(
                predicate: #Predicate<HexVisit> { $0.h3Index == h3 }
            )
            if let hexVisits = try? modelContext.fetch(hexDescriptor) {
                for hv in hexVisits {
                    modelContext.delete(hv)
                }
            }
        }
        // The trip is already gone; a failed prune save must not leave
        // pending HexVisit deletions to ride along with an unrelated save.
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip cascade hex prune save failed: \(error.localizedDescription)")
        }
        return true
    }

    /// Fetch the tapped physical row on the given context. Used by the gated
    /// merge / delete workers, which receive Sendable identities rather than
    /// `@Model` instances across the `PipelineGate` closure boundary. Nil when
    /// that row is gone; never falls back to a UUID twin, which may hold
    /// different stays and history.
    private static func fetchTrip(
        id: UUID, identifier: PersistentIdentifier, in modelContext: ModelContext
    ) throws -> Trip? {
        #if DEBUG
        if failTripFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first(where: {
            !$0.isDeleted && $0.persistentModelID == identifier
        })
    }

    /// Delete every `HiddenPhoto` / `PinnedPhoto` record whose `tripID`
    /// references the given trip. Called immediately before the trip itself
    /// is deleted (or absorbed by a merge) so the records don't linger as
    /// orphans pointing at a non-existent trip.
    /// Throws instead of treating a failed read as "no rows": every caller
    /// deletes or tombstones the trip next, and would otherwise orphan them.
    /// UUID twins are distinct physical rows sharing one UUID; the rows keyed
    /// to it belong to every twin, so a populated surviving twin keeps them.
    /// An empty twin does not: it would otherwise hold annotations and a
    /// favourite that block the ghost sweep from ever removing it.
    private static func deletePhotoAnnotations(for trip: Trip, in modelContext: ModelContext) throws {
        #if DEBUG
        if failCascadeDependencyFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let tripID = trip.id
        let twins = try modelContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == tripID }))
        let removed = trip.persistentModelID
        guard !twins.contains(where: { $0.persistentModelID != removed && !($0.stays ?? []).isEmpty }) else {
            return
        }
        let hiddenDescriptor = FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )
        for record in try modelContext.fetch(hiddenDescriptor) {
            modelContext.delete(record)
        }
        let pinnedDescriptor = FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )
        for record in try modelContext.fetch(pinnedDescriptor) {
            modelContext.delete(record)
        }
    }

    /// Whether a populated physical row with this UUID still exists.
    /// Favourites are keyed by UUID, so one outlives the deletion of a single
    /// UUID twin; a failed read keeps the favourite too.
    private static func populatedTripRowSurvives(
        _ tripID: UUID, container: ModelContainer
    ) -> Bool {
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { $0.id == tripID })
        guard let remaining = try? container.mainContext.fetch(descriptor) else { return true }
        return remaining.contains { !($0.stays ?? []).isEmpty }
    }

    /// Frees a deleted trip's favourite unless a populated UUID twin still shows it.
    /// Returns whether a favourite was freed.
    @discardableResult
    static func unpinUnlessTripRowSurvives(
        _ tripID: UUID, pins: PinnedTripsStorage = .shared,
        container: ModelContainer = AppDelegate.modelContainer
    ) -> Bool {
        guard !populatedTripRowSurvives(tripID, container: container), pins.isPinned(tripID) else { return false }
        pins.unpin(tripID)
        return true
    }

    /// Moves a merged-away trip's favourite onto the merge target (winner first,
    /// as the dedup carry does), then frees the source unless a populated UUID
    /// twin still shows it.
    static func carryFavouriteAfterMerge(
        sourceID: UUID, targetID: UUID, pins: PinnedTripsStorage = .shared,
        container: ModelContainer = AppDelegate.modelContainer
    ) {
        if pins.isPinned(sourceID) { pins.pin(targetID) }
        unpinUnlessTripRowSurvives(sourceID, pins: pins, container: container)
    }

    /// The candidate pings some Stay row outside `deletedRows` still lists.
    /// `pingIDs` is a joined string no predicate can match per element, so
    /// this scans the one column; deletion is rare and a user action. A failed
    /// read throws: it is not proof that no other stay keeps the evidence.
    private static func pingIDsReferencedBySurvivingStays(
        among candidates: Set<UUID>, excluding deletedRows: Set<PersistentIdentifier>,
        in modelContext: ModelContext
    ) throws -> Set<UUID> {
        guard !candidates.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate<Stay> { $0.pingIDsString != "" })
        descriptor.propertiesToFetch = [\.pingIDsString]
        var kept = Set<UUID>()
        for stay in try modelContext.fetch(descriptor)
        where !stay.isDeleted && !deletedRows.contains(stay.persistentModelID) {
            for id in stay.pingIDs where candidates.contains(id) { kept.insert(id) }
        }
        return kept
    }

    private static func fetchPingsForDeletion(ids: Set<UUID>, in modelContext: ModelContext) throws -> [LocationPing] {
        guard !ids.isEmpty else { return [] }
        #if DEBUG
        if failCascadeDependencyFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        return try modelContext.fetch(FetchDescriptor<LocationPing>(
            predicate: #Predicate<LocationPing> { ids.contains($0.id) }))
    }

    #if DEBUG
    nonisolated(unsafe) static var failTripFetchForTesting = false

    /// Makes the cascade's dependency reads fail so tests can pin that a
    /// failed read never deletes the trip.
    static var failCascadeDependencyFetchForTesting = false
    #endif
}
