//
//  TripDetailView+Editing.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import AppIntents
import FoundationModels
import SwiftUI
import TipKit
import SwiftData
import MapKit
import Photos
import UIKit
import WidgetKit
import os.log

private let logger = Logger(subsystem: "com.travellog.app", category: "TripDetailView")

extension TripDetailView {

    #if DEBUG
    nonisolated enum EditFault: Sendable {
        case categoryRead, categorySave, splitHiddenRead, splitSave
    }
    @TaskLocal static var editFaultForTesting: EditFault?
    #endif

    /// Thin wrapper: capture the Sendable trip identities + trimmed name and
    /// serialize the rename through `PipelineGate` (same rationale as
    /// `changeStayCategory`): the ungated main-context
    /// save could race a gated background lane's save and be silently
    /// swallowed by the `try?`. The tapped physical row is renamed: a UUID
    /// twin never stands in. Edit mode ends only once the rename commits; a
    /// failed one keeps the draft.
    func saveRename() {
        guard !isSavingRename else { return }
        isSavingRename = true
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip]) {
                await Self.applyRename(tripID: tripID, tripIdentifier: tripIdentifier, newName: newName)
            }
            isSavingRename = false
            if saved {
                withAnimation { isEditing = false }
            } else {
                saveFailed = true
            }
        }
    }

    /// False when a read or the save failed. A vanished row changes nothing.
    @MainActor
    static func applyRename(
        tripID: UUID, tripIdentifier: PersistentIdentifier, newName: String?,
        in modelContext: ModelContext = AppDelegate.modelContainer.mainContext
    ) -> Bool {
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let trip: Trip
        do {
            guard let found = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext) else {
                return true
            }
            trip = found
        } catch {
            logger.error("Trip rename fetch failed: \(error.localizedDescription)")
            return false
        }
        // Edit then Done with an untouched name must not mark the trip
        // userEdited, which exempts it from reclassification for good:
        // its classified stays keep their categories and the model lane
        // skips it. A stay already reset when it was renamed is still
        // settled, by the heuristics.
        if TripTitleStore.normalized(trip.customName) == newName { return true }
        trip.customName = newName
        trip.recomputeSummary()
        trip.userEdited = true
        // The edit is the user's own now, not a temporary home's mark.
        trip.keptByTemporaryHome = false
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip rename save failed: \(error.localizedDescription)")
            return false
        }
        // CurrentTripWidget renders displayName/countryFlags — the exact
        // fields just mutated, so every trip-mutating path reloads.
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// Capture the tapped physical rows and serialize the edit through the
    /// gate, matching rename/split. A UUID twin never stands in.
    func changeStayCategory(_ stay: Stay, to newCategory: StayCategory) {
        let stayID = stay.id
        let stayIdentifier = stay.persistentModelID
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip, .stay]) {
                await Self.applyCategoryChange(
                    stayID: stayID, stayIdentifier: stayIdentifier,
                    tripID: tripID, tripIdentifier: tripIdentifier, newCategory: newCategory)
            }
            if !saved { saveFailed = true }
        }
    }

    /// Hands a stay the user set back to automatic classification. The
    /// classifier holds the gate itself, then reclassifies and reconciles
    /// any temporary home the stay sits in. The tapped physical row is reset:
    /// a UUID twin never stands in.
    func resetStayToAutomatic(_ stay: Stay) {
        let stayID = stay.id
        let stayIdentifier = stay.persistentModelID
        Task {
            let saved = await AppDelegate.tripClassifier.resetStayToAutomatic(
                stayID: stayID, stayIdentifier: stayIdentifier)
            if !saved { saveFailed = true }
        }
    }

    /// The category menu offers Automatic only for a stay the user set.
    nonisolated static func offersAutomaticCategory(userOverridden: Bool) -> Bool {
        userOverridden
    }

    nonisolated static var automaticCategoryTitle: String {
        String(
            localized: "trip-detail.stay-category.automatic",
            defaultValue: "Automatic",
            comment: "Choice in a stay's category menu that hands a stay the user set back to automatic classification."
        )
    }

    /// False when a read/save failed or the tapped stay no longer belongs
    /// to the tapped trip. Re-picking the current category changes nothing.
    @MainActor
    static func applyCategoryChange(
        stayID: UUID, stayIdentifier: PersistentIdentifier,
        tripID: UUID, tripIdentifier: PersistentIdentifier, newCategory: StayCategory,
        in modelContext: ModelContext = AppDelegate.modelContainer.mainContext
    ) -> Bool {
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let stay: Stay
        let trip: Trip
        do {
            #if DEBUG
            if editFaultForTesting == .categoryRead { throw CocoaError(.fileReadUnknown) }
            #endif
            guard let foundStay = try fetchStay(id: stayID, identifier: stayIdentifier, in: modelContext),
                  let foundTrip = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext),
                  foundStay.trip?.persistentModelID == foundTrip.persistentModelID else { return false }
            stay = foundStay
            trip = foundTrip
        } catch {
            logger.error("Trip category change fetch failed: \(error.localizedDescription)")
            return false
        }
        // Re-picking the checked category is a no-op, not an override.
        guard stay.category != newCategory else { return true }
        stay.category = newCategory
        stay.userOverridden = true
        trip.userEdited = true
        trip.keptByTemporaryHome = false
        // Changing a stay's category changes which stays count as
        // destinations vs. transits — so the AI title is now stale. Clear
        // it; the next pipeline trigger regenerates it.
        TripTitleStore.invalidateGeneratedTitles(
            for: trip, in: modelContext)
        trip.recomputeSummary()
        do {
            #if DEBUG
            if editFaultForTesting == .categorySave { throw CocoaError(.fileWriteUnknown) }
            #endif
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip category change save failed: \(error.localizedDescription)")
            return false
        }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// Thin wrapper: capture Sendable identities and serialize the split
    /// through `PipelineGate` (same rationale as `changeStayCategory`). Both
    /// the trip and the split stay are the tapped physical rows: a UUID twin
    /// can hold a different tail, so it never stands in.
    func performSplit(at splitStay: Stay) {
        guard !trip.isDeleted, !splitStay.isDeleted else { return }
        splitHintDismissed = true
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let splitStayID = splitStay.id
        let splitStayIdentifier = splitStay.persistentModelID
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip, .stay, .hiddenPhoto]) {
                await Self.applySplit(
                    tripID: tripID, tripIdentifier: tripIdentifier,
                    splitStayID: splitStayID, splitStayIdentifier: splitStayIdentifier)
            }
            if !saved { saveFailed = true }
            // The tail stays moved to the new trip; regroup so the gallery
            // drops their photos instead of offering them under this trip.
            await loadPhotos()
        }
    }

    /// The split, on the main context. True only when it committed. The trip
    /// is re-found by its physical identity and the split stay must still be a
    /// non-first child of that same row; a failed read, a vanished or moved
    /// row, or a failed save reports false and changes nothing.
    @MainActor
    static func applySplit(
        tripID: UUID, tripIdentifier: PersistentIdentifier,
        splitStayID: UUID, splitStayIdentifier: PersistentIdentifier,
        in modelContext: ModelContext = AppDelegate.modelContainer.mainContext
    ) -> Bool {
        applySplitReturningLaterHalf(
            tripID: tripID, tripIdentifier: tripIdentifier,
            splitStayID: splitStayID, splitStayIdentifier: splitStayIdentifier,
            in: modelContext) != nil
    }

    /// `applySplit`, returning the new later trip once it committed, so a
    /// "Did you go home?" answer can open it or undo the split.
    @MainActor
    static func applySplitReturningLaterHalf(
        tripID: UUID, tripIdentifier: PersistentIdentifier,
        splitStayID: UUID, splitStayIdentifier: PersistentIdentifier,
        in modelContext: ModelContext = AppDelegate.modelContainer.mainContext
    ) -> TripGapActions.TripRef? {
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return nil }
        let trip: Trip
        do {
            guard let found = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext) else {
                logger.error("Trip split skipped: the tapped trip row is gone.")
                return nil
            }
            trip = found
        } catch {
            logger.error("Trip split trip fetch failed: \(error.localizedDescription)")
            return nil
        }
        let ordered = trip.orderedStays
        guard let splitIdx = ordered.firstIndex(where: {
                  $0.persistentModelID == splitStayIdentifier && $0.id == splitStayID
              }),
              splitIdx > 0 else {
            logger.error("Trip split skipped: the tapped stay is no longer a later stop of the tapped trip.")
            return nil
        }

        let hidden: [HiddenPhoto]
        do {
            #if DEBUG
            if editFaultForTesting == .splitHiddenRead { throw CocoaError(.fileReadUnknown) }
            #endif
            hidden = try modelContext.fetch(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { $0.tripID == tripID }))
        } catch {
            logger.error("Trip split hidden photo fetch failed: \(error.localizedDescription)")
            return nil
        }

        let originalWasComplete = trip.isComplete
        let originalEndDate = trip.endDate

        let newTrip = Trip(startDate: ordered[splitIdx].startTime)
        modelContext.insert(newTrip)
        // Hidden rows have no stay attribution. Keep every choice on both halves.
        for original in hidden {
            let copy = HiddenPhoto(localIdentifier: original.localIdentifier, tripID: newTrip.id)
            copy.cloudIdentifier = original.cloudIdentifier
            copy.hiddenAt = original.hiddenAt
            modelContext.insert(copy)
        }

        for (i, stay) in ordered[splitIdx...].enumerated() {
            stay.trip = newTrip
            stay.orderInTrip = i
        }

        for (i, stay) in ordered[..<splitIdx].enumerated() {
            stay.orderInTrip = i
        }

        trip.endDate = ordered[splitIdx - 1].endTime
        trip.isComplete = true
        trip.userEdited = true
        // Both halves are the user's own edit (`newTrip` starts without the mark).
        trip.keptByTemporaryHome = false
        // Split changes which stays belong to this trip — the old AI
        // title is now wrong (generated for the union). Clear it so the
        // next pipeline trigger regenerates. `newTrip` starts without one.
        TripTitleStore.invalidateGeneratedTitles(
            for: trip, in: modelContext)
        trip.recomputeSummary()

        newTrip.isComplete = originalWasComplete
        newTrip.endDate = originalWasComplete ? originalEndDate : nil
        newTrip.userEdited = true
        newTrip.recomputeSummary()

        do {
            #if DEBUG
            if editFaultForTesting == .splitSave { throw CocoaError(.fileWriteUnknown) }
            #endif
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip split save failed: \(error.localizedDescription)")
            return nil
        }
        SplitTripTip().invalidate(reason: .actionPerformed)
        WidgetCenter.shared.reloadAllTimelines()
        return TripGapActions.TripRef(id: newTrip.id, identifier: newTrip.persistentModelID)
    }

    /// The tapped physical trip row, or nil when that row is gone. Never falls
    /// back to a UUID twin, which may hold different stays. Throws on a failed
    /// read so the caller does not mistake it for absence.
    private static func fetchTrip(
        id: UUID, identifier: PersistentIdentifier, in modelContext: ModelContext
    ) throws -> Trip? {
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { $0.id == id })
        return try modelContext.fetch(descriptor).first(where: {
            !$0.isDeleted && $0.persistentModelID == identifier
        })
    }

    private static func fetchStay(
        id: UUID, identifier: PersistentIdentifier, in modelContext: ModelContext
    ) throws -> Stay? {
        let descriptor = FetchDescriptor<Stay>(predicate: #Predicate<Stay> { $0.id == id })
        return try modelContext.fetch(descriptor).first(where: {
            !$0.isDeleted && $0.persistentModelID == identifier
        })
    }
}
