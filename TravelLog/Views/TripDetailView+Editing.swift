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

    /// Thin wrapper: capture the Sendable trip identities + trimmed name and
    /// serialize the rename through `PipelineGate` (same rationale as
    /// `changeStayCategory`): the ungated main-context
    /// save could race a gated background lane's save and be silently
    /// swallowed by the `try?`. The tapped physical row is renamed: a UUID
    /// twin never stands in.
    func saveRename() {
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip]) {
                await Self.applyRename(tripID: tripID, tripIdentifier: tripIdentifier, newName: newName)
            }
            if !saved { saveFailed = true }
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

    /// Thin wrapper: capture the Sendable stay/trip IDs + category and
    /// serialize the edit through `PipelineGate` so the main-context save can't
    /// race a gated background wake-ping save and be silently swallowed by the
    /// `try?`. The static worker refetches by ID on the
    /// main context — the same objects the view is bound to — so the change is
    /// reflected in place. `run(touching:)` also advances the Stats/Map tokens.
    func changeStayCategory(_ stay: Stay, to newCategory: StayCategory) {
        let stayID = stay.id

        let tripID = trip.id
        Task {
            await PipelineGate.shared.run(touching: [.trip, .stay]) {
                await Self.applyCategoryChange(stayID: stayID, tripID: tripID, newCategory: newCategory)
            }
        }
    }

    /// Hands a stay the user set back to automatic classification. The
    /// classifier holds the gate itself, then reclassifies and reconciles
    /// any temporary home the stay sits in.
    func resetStayToAutomatic(_ stay: Stay) {
        let stayID = stay.id
        Task {
            let saved = await AppDelegate.tripClassifier.resetStayToAutomatic(stayID: stayID)
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

    @MainActor
    static func applyCategoryChange(
        stayID: UUID, tripID: UUID, newCategory: StayCategory,
        in modelContext: ModelContext = AppDelegate.modelContainer.mainContext
    ) {
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return }
        guard let stay = fetchStay(id: stayID, in: modelContext),
              let trip = fetchTrip(id: tripID, in: modelContext) else { return }
        // Re-picking the checked category is a no-op, not an override.
        guard stay.category != newCategory else { return }
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
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip category change save failed: \(error.localizedDescription)")
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Thin wrapper: capture Sendable identities and serialize the split
    /// through `PipelineGate` (same rationale as `changeStayCategory`). Both
    /// the trip and the split stay are the tapped physical rows: a UUID twin
    /// can hold a different tail, so it never stands in.
    func performSplit(at splitStay: Stay) {
        guard !trip.isDeleted, !splitStay.isDeleted else { return }
        splitHintDismissed = true
        showSplitHint = false
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let splitStayID = splitStay.id
        let splitStayIdentifier = splitStay.persistentModelID
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.trip, .stay]) {
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
        guard preserveUnrelatedPendingEdits(in: modelContext) else { return false }
        let trip: Trip
        do {
            guard let found = try fetchTrip(id: tripID, identifier: tripIdentifier, in: modelContext) else {
                logger.error("Trip split skipped: the tapped trip row is gone.")
                return false
            }
            trip = found
        } catch {
            logger.error("Trip split trip fetch failed: \(error.localizedDescription)")
            return false
        }
        let ordered = trip.orderedStays
        guard let splitIdx = ordered.firstIndex(where: {
                  $0.persistentModelID == splitStayIdentifier && $0.id == splitStayID
              }),
              splitIdx > 0 else {
            logger.error("Trip split skipped: the tapped stay is no longer a later stop of the tapped trip.")
            return false
        }

        let originalWasComplete = trip.isComplete
        let originalEndDate = trip.endDate

        let newTrip = Trip(startDate: ordered[splitIdx].startTime)
        modelContext.insert(newTrip)

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
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Trip split save failed: \(error.localizedDescription)")
            return false
        }
        SplitTripTip().invalidate(reason: .actionPerformed)
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// Fetch a trip/stay by ID on the given context — the gated edit workers
    /// receive Sendable UUIDs, not `@Model` instances, across the PipelineGate
    /// closure boundary (mirrors TripsListView's merge/delete workers).
    private static func fetchTrip(id: UUID, in modelContext: ModelContext) -> Trip? {
        var descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
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

    private static func fetchStay(id: UUID, in modelContext: ModelContext) -> Stay? {
        var descriptor = FetchDescriptor<Stay>(predicate: #Predicate<Stay> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
