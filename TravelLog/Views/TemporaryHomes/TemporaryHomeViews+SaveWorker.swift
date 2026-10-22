//
//  TemporaryHomeViews+SaveWorker.swift
//  TravelLog
//
//  The Settings section that lists temporary homes, the add/edit sheet, and
//  the gated write path they share.
//

import SwiftUI
import SwiftData
import Combine
import CoreLocation
import WidgetKit
import os.log

// MARK: - Temporary home save (gated write path)

/// Capture all TemporaryHomeSaveWorker inputs before geocoding; no model crosses suspension.
nonisolated struct TemporaryHomeSavePayload: Sendable {
    nonisolated enum Target: Sendable {
        case add
        /// The row's id, never the row. Every physical row with that id is written.
        case edit(UUID)
        /// Ends it on the civil day that holds `at`, read in the row's stored zone.
        case end(UUID, at: Date)
        case remove(UUID)
    }
    let target: Target
    let label: String
    let latitude: Double
    let longitude: Double
    /// Nil geocode fields keep the stored metadata while the pin stays within
    /// 1 km of the stored row; a pin moved farther stores them as they are.
    let locality: String?
    let administrativeArea: String?
    let country: String?
    let isoCountryCode: String?
    /// Already the start of the picked day and the last second of the picked
    /// day (`TemporaryHomeSaveWorker.civilDayBounds`). `.end` and `.remove` ignore both.
    let startedAt: Date
    let endedAt: Date?
    /// The zone the days were picked in. `.end` reads it only when the row stores none.
    let timeZoneIdentifier: String?
    /// One clock read for `createdAt` and `modifiedAt`.
    let now: Date
    /// `.edit` only: queue the reconciliation although the place and dates did
    /// not change, because the form's preview found stays or trips it would move.
    var reconcilesUnchangedCoverage = false
    /// The engaged trips the preview keeps or splits, held: a coverage save marks
    /// every row of each edited (this feature's mark) in the declaration's save, so no
    /// pass regroups them before the unit, which archives a split one with its
    /// earlier mark. A hold is never an explicit keep (`TemporaryHome.keptTripIDs`).
    var keptTripIDs: [UUID] = []
    /// What the review the user saw read. Inside its gate the save commits
    /// only while the store and the favourites still read the same; nil
    /// (no review behind it) skips the check.
    var reviewed: TemporaryHomeSaveWorker.ReviewedInputs? = nil

    /// Ends a temporary home on the civil day that holds `day`.
    static func ending(
        _ id: UUID, on day: Date, now: Date = .now, keptTripIDs: [UUID] = [],
        reviewed: TemporaryHomeSaveWorker.ReviewedInputs? = nil
    ) -> TemporaryHomeSavePayload {
        TemporaryHomeSavePayload(
            target: .end(id, at: day), label: "", latitude: 0, longitude: 0,
            locality: nil, administrativeArea: nil, country: nil, isoCountryCode: nil,
            startedAt: day, endedAt: nil,
            timeZoneIdentifier: TimeZone.current.identifier, now: now,
            keptTripIDs: keptTripIDs, reviewed: reviewed)
    }

    /// Removes a temporary home and the corrections taught for it.
    static func removing(
        _ id: UUID, now: Date = .now, keptTripIDs: [UUID] = [],
        reviewed: TemporaryHomeSaveWorker.ReviewedInputs? = nil
    ) -> TemporaryHomeSavePayload {
        TemporaryHomeSavePayload(
            target: .remove(id), label: "", latitude: 0, longitude: 0,
            locality: nil, administrativeArea: nil, country: nil, isoCountryCode: nil,
            startedAt: now, endedAt: nil, timeZoneIdentifier: nil, now: now,
            keptTripIDs: keptTripIDs, reviewed: reviewed)
    }
}

/// Gated temporary-home worker, the shape of `HomeSaveWorker`: Sendable inputs,
/// models refetched on an injected context, which is also the test seam.
enum TemporaryHomeSaveWorker {

    struct Result: Equatable {
        let failed: Bool
        /// The queued reconciliation, committed with the save. Nil when the
        /// save changed neither the place nor the dates.
        var pendingReconciliation: CoverageReconciliationQueue.Entry? = nil
        /// The review behind the save no longer holds: nothing was written.
        var needsReview = false

        static let noChange = Result(failed: false)

        static let failure = Result(failed: true)

        static let staleReview = Result(failed: false, needsReview: true)
    }

    /// What a review read: the store's revision over every table the preview
    /// reads (`TemporaryHomeFormSheet.reviewedChanges`), counted before the
    /// debounce, and the favourites it held.
    nonisolated struct ReviewedInputs: Equatable, Sendable {
        let revision: Int
        let favorites: Int
    }

    /// The inputs a review starting now reads, or a save compares.
    @MainActor
    static func currentInputs(
        tracker: StoreChangeTracker = .shared, pinnedTripIDs: Set<UUID>
    ) -> ReviewedInputs {
        ReviewedInputs(
            revision: tracker.revision(for: TemporaryHomeFormSheet.reviewedChanges),
            favorites: TemporaryHomeFormSheet.favoritesFingerprint(pinnedTripIDs))
    }

    /// `apply`, run inside the save's gate, only while the review behind the
    /// payload still holds: a write queued ahead of the save (a photo hidden,
    /// a Home moved, a trip edited) or a favourite synced in since the review
    /// read returns `.staleReview` before anything is written or held.
    @MainActor
    static func applyIfStillReviewed(
        _ payload: TemporaryHomeSavePayload,
        context: ModelContext,
        tracker: StoreChangeTracker = .shared,
        pinnedTripIDs: Set<UUID>,
        save: (ModelContext) throws -> Void = { try $0.save() },
        pendingDefaults: UserDefaults = .standard
    ) -> Result {
        if let reviewed = payload.reviewed,
           reviewed != currentInputs(tracker: tracker, pinnedTripIDs: pinnedTripIDs) {
            return .staleReview
        }
        return apply(payload, context: context, save: save, pendingDefaults: pendingDefaults)
    }

    /// A day picked without a time, as the instants that are stored: the
    /// start of that civil day and its last second, in `zone`. An end at the
    /// last second keeps the whole final day at the temporary home; ending
    /// that morning would turn the rest of the day into a one-day trip.
    nonisolated static func civilDayBounds(
        of picked: Date, in zone: TimeZone
    ) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // The calendar's own day, not 24 hours: a clock-change day is 23 or 25 hours long.
        guard let day = calendar.dateInterval(of: .day, for: picked) else {
            let start = calendar.startOfDay(for: picked)
            return (start, start.addingTimeInterval(24 * 60 * 60 - 1))
        }
        return (day.start, day.end.addingTimeInterval(-1))
    }

    /// The end, when there is one, may not precede the start.
    nonisolated static func datesAreValid(startedAt: Date, endedAt: Date?) -> Bool {
        endedAt.map { $0 >= startedAt } ?? true
    }

    @MainActor
    private static func fetchRows(id: UUID, in context: ModelContext) throws -> [TemporaryHome] {
        try context.fetch(FetchDescriptor<TemporaryHome>(
            predicate: #Predicate { $0.id == id }))
    }

    /// The `modifiedAt` an edit writes: now, or just past the latest stored
    /// twin when that lies ahead (a clock that ran fast), so the edited rows
    /// still outrank a stale twin that syncs in later with that old value.
    @MainActor
    private static func advancedModifiedAt(of rows: [TemporaryHome], now: Date) -> Date {
        guard let latest = rows.map(\.modifiedAt).max() else { return now }
        return max(now, latest.addingTimeInterval(0.001))
    }

    /// - Returns: whether the save failed, and the reconciliation it queued.
    ///   `.noChange` when the targeted temporary home is no longer in the store.
    @MainActor
    @discardableResult
    static func apply(
        _ payload: TemporaryHomeSavePayload,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        pendingDefaults: UserDefaults = .standard
    ) -> Result {
        // Rollback is context-wide; preserve earlier pending edits first.
        if context.hasChanges {
            do {
                try save(context)
            } catch {
                temporaryHomeLogger.error("Temporary home save pre-save failed: \(error.localizedDescription)")
                return .failure
            }
        }
        do {
            let reconcileID: UUID?
            switch payload.target {
            case .add:
                guard datesAreValid(
                    startedAt: payload.startedAt, endedAt: payload.endedAt) else { return .failure }
                let row = TemporaryHome(
                    label: payload.label,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    startedAt: payload.startedAt,
                    endedAt: payload.endedAt
                )
                row.locality = payload.locality
                row.administrativeArea = payload.administrativeArea
                row.country = payload.country
                row.isoCountryCode = payload.isoCountryCode
                row.timeZoneIdentifier = payload.timeZoneIdentifier
                row.createdAt = payload.now
                row.modifiedAt = payload.now
                // The first coverage of a new id.
                row.coverageRevision = TemporaryHome.nextCoverageRevision(of: [])
                context.insert(row)
                reconcileID = row.id

            case .edit(let id):
                guard datesAreValid(
                    startedAt: payload.startedAt, endedAt: payload.endedAt) else { return .failure }
                // Refetch by id after suspension. Two devices importing one backup
                // leave same-id twins; an edit writes them all so they stay alike.
                let rows = try fetchRows(id: id, in: context)
                guard let stored = HomeAnchors.collapsingTwins(rows).first else {
                    return .noChange
                }
                // Coalesce, don't wipe, while the pin stays put: a failed lookup
                // changes no stored metadata. A pin moved 1 km or more is another
                // place, so the lookup's answer stands, nil included (the Home
                // worker's rule): the old city's name must not follow the pin.
                let samePlace = HomeOrbit.greatCircleKm(
                    stored.latitude, stored.longitude, payload.latitude, payload.longitude) < 1
                let locality = samePlace ? payload.locality ?? stored.locality : payload.locality
                let administrativeArea = samePlace
                    ? payload.administrativeArea ?? stored.administrativeArea
                    : payload.administrativeArea
                let country = samePlace ? payload.country ?? stored.country : payload.country
                let isoCountryCode = samePlace
                    ? payload.isoCountryCode ?? stored.isoCountryCode : payload.isoCountryCode
                let timeZoneIdentifier = payload.timeZoneIdentifier ?? stored.timeZoneIdentifier
                // Only the place and the dates decide which stays it claims,
                // and the locality also names it in trip names; a label-only
                // edit skips reconciliation (the Home worker's rule) unless
                // the form's preview found work for it.
                let coverageChanged = rows.contains {
                    $0.latitude != payload.latitude || $0.longitude != payload.longitude
                        || $0.startedAt != payload.startedAt || $0.endedAt != payload.endedAt
                }
                let localityChanged = rows.contains { $0.locality != locality }
                let modifiedAt = advancedModifiedAt(of: rows, now: payload.now)
                // A coverage change is one revision, written on every row.
                let revision = coverageChanged
                    ? TemporaryHome.nextCoverageRevision(of: rows) : nil
                for row in rows {
                    row.label = payload.label
                    row.latitude = payload.latitude
                    row.longitude = payload.longitude
                    row.locality = locality
                    row.administrativeArea = administrativeArea
                    row.country = country
                    row.isoCountryCode = isoCountryCode
                    row.startedAt = payload.startedAt
                    row.endedAt = payload.endedAt
                    row.timeZoneIdentifier = timeZoneIdentifier
                    row.modifiedAt = modifiedAt
                    if let revision { row.coverageRevision = revision }
                }
                reconcileID = coverageChanged || localityChanged
                    || payload.reconcilesUnchangedCoverage ? id : nil

            case .end(let id, let day):
                let rows = try fetchRows(id: id, in: context)
                guard let stored = HomeAnchors.collapsingTwins(rows).first else {
                    return .noChange
                }
                let zone = stored.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
                    ?? payload.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
                    ?? .current
                let endedAt = civilDayBounds(of: day, in: zone).end
                // The user ends the declaration they see, the winner: a losing
                // twin's start cannot fail it. Every twin takes the winner's
                // content with the new end, so the twins agree from here on.
                guard datesAreValid(startedAt: stored.startedAt, endedAt: endedAt) else {
                    return .failure
                }
                let modifiedAt = advancedModifiedAt(of: rows, now: payload.now)
                // A row whose coverage this changes (the new end, or a losing
                // twin taking the winner's place and dates) moves every row
                // to the next revision.
                let coverageChanged = rows.contains {
                    $0.latitude != stored.latitude || $0.longitude != stored.longitude
                        || $0.radiusKm != stored.radiusKm || $0.startedAt != stored.startedAt
                        || $0.endedAt != endedAt
                }
                let revision = coverageChanged
                    ? TemporaryHome.nextCoverageRevision(of: rows) : nil
                // The winner's own fields are only ever written with themselves,
                // so the other rows read them unchanged whatever the order.
                for row in rows {
                    row.label = stored.label
                    row.latitude = stored.latitude
                    row.longitude = stored.longitude
                    row.radiusKm = stored.radiusKm
                    row.locality = stored.locality
                    row.administrativeArea = stored.administrativeArea
                    row.country = stored.country
                    row.isoCountryCode = stored.isoCountryCode
                    row.startedAt = stored.startedAt
                    row.timeZoneIdentifier = stored.timeZoneIdentifier
                    row.endedAt = endedAt
                    row.modifiedAt = modifiedAt
                    if let revision { row.coverageRevision = revision }
                }
                reconcileID = id

            case .remove(let id):
                let rows = try fetchRows(id: id, in: context)
                // Already removed (a tombstone arrived while the sheet was
                // open), or never here.
                guard !HomeAnchors.collapsingTwins(rows).isEmpty else { return .noChange }
                // Removal is a fact about the id: every row keeps its content
                // and is stamped, so a same-id twin arriving later stays hidden.
                // Its corrections are withdrawn by the reconciliation queued below,
                // which frees the stays they stamped and deletes them in one unit.
                let revision = TemporaryHome.nextCoverageRevision(of: rows)
                for row in rows {
                    row.removedAt = payload.now
                    row.modifiedAt = payload.now
                    row.coverageRevision = revision
                }
                reconcileID = id
            }

            // The trips the preview keeps or splits become edited with the
            // coverage that touches them: a pass already running reads both or
            // neither, and none regroups them before the unit. The unit marks
            // the kept ones again from current inputs and consumes the hold of
            // a split one. The mark is a temporary home's, which the user's own
            // edits clear.
            if reconcileID != nil, !payload.keptTripIDs.isEmpty {
                let ids = payload.keptTripIDs
                let kept = try context.fetch(FetchDescriptor<Trip>(
                    predicate: #Predicate { ids.contains($0.id) }))
                for trip in kept where !trip.userEdited {
                    trip.userEdited = true
                    trip.keptByTemporaryHome = true
                }
            }

            // Queue the reconciliation before the edit can become durable,
            // so no kill leaves a committed edit without its reconciliation.
            let staged = reconcileID.map {
                CoverageReconciliationQueue.stage(.temporaryHome, id: $0, defaults: pendingDefaults)
            }
            do {
                try save(context)
            } catch {
                // Withdraw only this edit: an earlier committed edit of the
                // same temporary home may still owe its reconciliation.
                if let staged {
                    CoverageReconciliationQueue.withdraw(staged, defaults: pendingDefaults)
                }
                throw error
            }
            return Result(failed: false, pendingReconciliation: staged?.entry)
        } catch {
            context.rollback()
            return .failure
        }
    }

    nonisolated enum CommitOutcome: Equatable, Sendable {
        case saved
        /// The save failed and nothing changed.
        case failed
        /// The review no longer holds and nothing changed: review again.
        case needsReview
    }

    /// The commit flow every temporary-home write shares (the Home form's):
    /// the gated save, then the reconciliation it queued, in the background.
    @MainActor
    static func commit(_ payload: TemporaryHomeSavePayload) async -> CommitOutcome {
        // Gate the save against pipeline writes; runReturning(touching:) publishes the change.
        // AppDelegate.modelContainer.mainContext must match the context injected by TravelLogApp.
        let saveResult = await PipelineGate.shared.runReturning(
            touching: payload.keptTripIDs.isEmpty ? [.temporaryHome] : [.temporaryHome, .trip]
        ) {
            await MainActor.run {
                TemporaryHomeSaveWorker.applyIfStillReviewed(
                    payload, context: AppDelegate.modelContainer.mainContext,
                    pinnedTripIDs: PinnedTripsStorage.shared.pinnedIDs)
            }
        }

        if saveResult.needsReview { return .needsReview }
        guard !saveResult.failed else { return .failed }

        // Keep reconciliation OUTSIDE the gate: the classifier self-serializes and owns its unit.
        // The worker queued it before its save; a failed or cancelled one stays
        // queued for the activation and launch drain, which repeats this sequence.
        if let pending = saveResult.pendingReconciliation {
            Task {
                // Favorites live on the main actor; the classifier reads them
                // inside its unit, after any wait for the pipeline.
                let outcome = await AppDelegate.tripClassifier.applyTemporaryHomeChange(
                    temporaryHomeID: pending.id,
                    pinnedTripIDs: { PinnedTripsStorage.shared.pinnedIDs },
                    onSettled: { CoverageReconciliationQueue.complete(pending) })
                // The card and detail say whether it waits or failed.
                CoverageReconciliationQueue.recordTemporaryHomeOutcome(outcome, for: pending)
                guard outcome.isSettled else {
                    StoreChangeTracker.shared.bump(
                        outcome.didCommit ? [.temporaryHome, .stay, .trip] : [.temporaryHome])
                    return
                }
                // A removal puts back the trips it split on this device, as the drain does.
                if case .remove = payload.target {
                    await HomeAreaHealing.keepSplitTrips(splitBy: [pending.id])
                }
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                StoreChangeTracker.shared.bump([.temporaryHome, .stay, .trip])
                WidgetCenter.shared.reloadAllTimelines()
                await HomeAreaHealing.healIfNeeded()
            }
        } else {
            // A label-only edit queues nothing; the Current Trip widget shows the label.
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .saved
    }
}
