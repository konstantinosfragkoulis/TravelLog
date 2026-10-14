//
//  TripClassifier+HomeReconciliation.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    /// A Home or RoutinePlace coverage reconciliation unit's result. Only
    /// `committed` and `placeMissing` discharge a pending reconciliation;
    /// the follow-up pipeline pass is separate work with its own triggers.
    nonisolated enum CoverageReconciliationOutcome: Sendable, Equatable {
        /// The unit saved (or had nothing to change); `resetCount` stays
        /// now await the pipeline.
        case committed(resetCount: Int)
        /// The edited row is not in this store. Only rows this device
        /// committed are queued, so absence means a local collapse or wipe.
        case placeMissing
        /// Cancelled while queued behind the pipeline; nothing ran.
        case cancelled
        /// A required read or the save failed; the unit rolled back.
        case failed

        var resetCount: Int {
            if case .committed(let count) = self { return count }
            return 0
        }

        var isSettled: Bool {
            switch self {
            case .committed, .placeMissing: true
            case .cancelled, .failed: false
            }
        }
    }

    /// Reconcile Settings home additions and moves; onboarding predates tracking.
    /// Detach reset stays because preFilterStays only processes unclassified rows and home stays cannot remain trip members.
    /// Recompute distance with StayClusterer.closestHomeDistanceKm because home history changed.
    /// Explicit actions queue behind an in-flight pipeline; zero resets skips the pipeline pass.
    /// `onSettled` runs right after the reconciliation unit settles, before the long pipeline pass.
    @discardableResult
    func applyHomeChange(
        homeID: UUID,
        gate: PipelineGate = .shared,
        onSettled: (@MainActor @Sendable () -> Void)? = nil
    ) async -> CoverageReconciliationOutcome {
        while isRunning {
            guard !Task.isCancelled else { return .cancelled }
            logger.debug("Pipeline running; home-change reconciliation queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return .cancelled }
        }
        isRunning = true
        defer { isRunning = false }

        let outcome = await gate.runReturning(touching: [.home, .stay, .trip]) {
            guard await self.primeHomeShapes() else {
                return CoverageReconciliationOutcome.failed
            }
            return await self.applyHomeChangeCore(homeID: homeID)
        }
        if outcome.isSettled, let onSettled { await onSettled() }
        let resetCount = outcome.resetCount
        guard resetCount > 0 else { return outcome }
        _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)

        logger.info("Home change: reset \(resetCount) stay(s) inside the new home ring; re-running pipeline.")
        _ = await generateTitlesStage(
            maxTripsPerCall: nil,
            sampling: .greedy,
            applyGate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return outcome
    }

    /// The deterministic half of `applyHomeChange` (backdate + reset +
    /// detach + distance recompute + save), split from the pipeline re-run
    /// so tests can drive it through the narrow `preFilterStays` /
    /// `assembleTrips` / `closeStaleOpenTrips` seams without Stage 2's
    /// FM lane in the loop. Caller must hold `isRunning`. Every read is
    /// required and precedes the first mutation; a failed save, or a summary
    /// whose home-place read failed, rolls the unit back.
    internal func applyHomeChangeCore(homeID: UUID) -> CoverageReconciliationOutcome {
        let homePredicate = #Predicate<Home> { $0.id == homeID }
        let fetchedHome: Home?
        do {
            #if DEBUG
            if failHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            fetchedHome = try modelContext.fetch(
                FetchDescriptor<Home>(predicate: homePredicate)).first
        } catch {
            logger.error("Home change skipped; edited home unreadable: \(error.localizedDescription)")
            return .failed
        }
        guard let home = fetchedHome else { return .placeMissing }

        guard let allStays = fetchReconciliationStays(orSkip: "Home change") else { return .failed }
        guard !allStays.isEmpty else { return .committed(resetCount: 0) }
        guard let dependencies = fetchHomeAreaDependencies(orSkip: "Home change") else { return .failed }
        let overrides = dependencies.overrides

        // 1. Backdate to the contiguous-arrival effective date. Only ever
        // moves EARLIER — a manual future-dated startedAt is respected.
        let points = allStays.map {
            StayPoint(
                latitude: $0.centroidLatitude,
                longitude: $0.centroidLongitude,
                startTime: $0.startTime
            )
        }
        // Reset and backdate with the same geometry as matchesHome to preserve trips outside measured coverage;
        // a missing membership retains the withShapes circle fallback.
        let editedMembership = withShapes([Self.HomeRing(
            latitude: home.latitude, longitude: home.longitude,
            radiusKm: home.radiusKm, startedAt: home.startedAt, endedAt: home.endedAt,
            homeID: home.id
        )], overrides: overrides).first?.membership

        if let effective = Self.homeEffectiveStart(
            homeLatitude: home.latitude,
            homeLongitude: home.longitude,
            radiusKm: home.radiusKm,
            membership: editedMembership,
            stays: points
        ), effective < home.startedAt {
            home.startedAt = effective
        }

        // Read after the backdate, so the edited Home's ring carries its new start.
        let allAnchors = classificationAnchors(of: dependencies)
        let homeWindows = allAnchors.map { StayClusterer.HomeWindow($0) }
        let homeRings = withShapes(allAnchors.map { Self.HomeRing($0) }, overrides: overrides)

        // Reconcile detached completed trips here because assembly does not rebuild them or remove empty rows.
        // Only the in-ring reset captures these stays, so each becomes a future home boundary.
        var affectedCompletedTrips:
            [ObjectIdentifier: (trip: Trip, detached: [Stay])] = [:]
        var affectedOpenTrips: [ObjectIdentifier: Trip] = [:]

        func resetStay(_ stay: Stay) {
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if trip.isComplete {
                    affectedCompletedTrips[identity, default: (trip, [])]
                        .detached.append(stay)
                } else {
                    affectedOpenTrips[identity] = trip
                }
            }
            stay.category = .unclassified
            stay.trip = nil
            stay.orderInTrip = nil
            stay.distanceFromHomeKm = StayClusterer.closestHomeDistanceKm(
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                atTime: stay.startTime,
                homes: homeWindows
            )
        }
        func isSacred(_ stay: Stay) -> Bool {
            if stay.userOverridden { return true }
            if let trip = stay.trip, trip.userEdited { return true }
            return false
        }

        var resetCount = 0
        // In both passes below a temporary home's stamp goes only as its own
        // unit may free it: a newer copy's, or one of a declaration this device
        // does not hold, keeps its category and pair.
        func mayRelease(_ stay: Stay) -> Bool {
            Self.automaticReleaseAllows(
                stay, liveRevisions: dependencies.temporaryHomeRevisions,
                removedIDs: dependencies.removedTemporaryHomeIDs)
        }
        for stay in allStays where stay.startTime >= home.startedAt {
            guard !isSacred(stay), mayRelease(stay) else { continue }
            // Same geometry as `matchesHome`: the measured membership when
            // one is attached, the declared circle otherwise (see
            // `editedMembership`), evaluated at the stay's own time.
            if let editedMembership {
                guard editedMembership.contains(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                    at: stay.startTime
                ) else { continue }
            } else {
                let coordinate = CLLocationCoordinate2D(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude
                )
                guard home.contains(coordinate) else { continue }
            }
            resetStay(stay)
            resetCount += 1
        }

        // Unstamp stale home stays with the exact matchesHome predicate used by preFilterStays,
        // so shrinking or moving a ring can release stays outside its new coverage.
        for stay in allStays where stay.category == .home {
            guard !isSacred(stay), mayRelease(stay) else { continue }
            if !Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings
            ) {
                resetStay(stay)
                resetCount += 1
            }
        }
        // The backdate, resets and unstamps above change the home-place inputs;
        // the recompute below must not read a snapshot from before this unit.
        TripTitleStore.invalidateHomePlaceIndex()

        // Assembly snapshots incomplete trips only after this reconciliation
        // returns. Clear titles now, while we still know that membership was
        // detached, so the already-smaller shape cannot become a false
        // carry-forward baseline for a title that described the old trip.
        for trip in affectedOpenTrips.values {
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
        }

        // Delete fully absorbed trips; shrink survivors and invalidate generated titles after membership changes.
        // Preserve closeTrip semantics: the first detached home stay after the remaining stays is the new end boundary.
        var deletedGhostTrips = 0
        for (trip, detached) in affectedCompletedTrips.values {
            let remaining = trip.orderedStays
            // A remnant with no destination is errand residue, not a journey
            // (the assembleTrips all-transit rule): shrinking would keep a
            // completed trip whose destinationSummary/countryCodes are empty
            // — a blank ghost card. Detach the transit stays into the
            // tripless steady state the destination-only dirty gate
            // tolerates, and delete the row alongside the fully-emptied case.
            guard let first = remaining.first, let last = remaining.last,
                  remaining.contains(where: { $0.category == .destination }) else {
                for stay in remaining {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(trip)
                deletedGhostTrips += 1
                continue
            }
            trip.startDate = first.startTime
            let homecoming = detached
                .filter { $0.startTime >= last.endTime }
                .map(\.startTime)
                .min()
            if let homecoming, homecoming < (trip.endDate ?? .distantFuture) {
                trip.endDate = homecoming
            }
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
            // A completed trip is never rebuilt by assembly, so a summary built
            // without its home-place filter would persist; roll back and keep the debt.
            guard trip.recomputeSummary() else {
                return rollBackUnreadableHomePlaces(unit: "Home change")
            }
        }
        if deletedGhostTrips > 0 {
            logger.info("Home change: deleted \(deletedGhostTrips) fully-absorbed completed trip(s).")
        }

        guard saveReconciliation(unit: "Home change") else { return .failed }
        return .committed(resetCount: resetCount)
    }

    func fetchReconciliationStays(orSkip unit: String) -> [Stay]? {
        do {
            #if DEBUG
            if failReconciliationStayReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            return try modelContext.fetch(FetchDescriptor<Stay>(
                sortBy: [SortDescriptor(\.startTime, order: .forward)]))
        } catch {
            logger.error("\(unit, privacy: .public) skipped; stays unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rolls back a coverage reconciliation unit whose completed-trip summary
    /// could not read its home places. The unit commits once and its queue
    /// debt settles on commit, so a degraded summary is a failed unit.
    private func rollBackUnreadableHomePlaces(unit: String) -> CoverageReconciliationOutcome {
        modelContext.rollback()
        // Never serve a home-place snapshot built from rolled-back rows.
        TripTitleStore.invalidateHomePlaceIndex()
        logger.error("\(unit, privacy: .public) rolled back; home places unreadable for a trip summary.")
        return .failed
    }

    /// Saves a coverage reconciliation unit; a failure rolls it back whole.
    func saveReconciliation(unit: String) -> Bool {
        do {
            #if DEBUG
            if shouldFailNextReconciliationSaveForTesting {
                shouldFailNextReconciliationSaveForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            // The unit's summaries read a home-place snapshot of rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("\(unit, privacy: .public) rolled back; save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Routine-place reconciliation

    /// Reconcile routine coverage without home-specific changes: no startedAt backdating for brief visits,
    /// no distanceFromHomeKm recompute because only homes define that field, and no homecoming endDate change
    /// because routine stays are never boundaries in hasHomeStayBetween.
    @discardableResult
    func applyRoutinePlaceChange(
        placeID: UUID,
        gate: PipelineGate = .shared,
        onSettled: (@MainActor @Sendable () -> Void)? = nil
    ) async -> CoverageReconciliationOutcome {
        while isRunning {
            guard !Task.isCancelled else { return .cancelled }
            logger.debug("Pipeline running; routine-place reconciliation queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return .cancelled }
        }
        isRunning = true
        defer { isRunning = false }

        let outcome = await gate.runReturning(
            touching: [.routinePlace, .stay, .trip]
        ) {
            guard await self.primeHomeShapes() else {
                return CoverageReconciliationOutcome.failed
            }
            return await self.applyRoutinePlaceChangeCore(placeID: placeID)
        }
        if outcome.isSettled, let onSettled { await onSettled() }
        let resetCount = outcome.resetCount
        guard resetCount > 0 else { return outcome }
        _ = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate)

        logger.info("Routine-place change: reset \(resetCount) stay(s); re-running pipeline.")
        _ = await generateTitlesStage(
            maxTripsPerCall: nil,
            sampling: .greedy,
            applyGate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return outcome
    }

    /// The deterministic half of `applyRoutinePlaceChange`, split from the
    /// pipeline re-run so tests can drive it without Stage 2's FM lane.
    /// Caller must hold `isRunning`. Reads are required, as in the Home core.
    internal func applyRoutinePlaceChangeCore(placeID: UUID) -> CoverageReconciliationOutcome {
        let id = placeID
        let placePredicate = #Predicate<RoutinePlace> { $0.id == id }
        let placeExists: Bool
        do {
            #if DEBUG
            if failRoutineReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            placeExists = try modelContext.fetch(
                FetchDescriptor<RoutinePlace>(predicate: placePredicate)).first != nil
        } catch {
            logger.error("Routine-place change skipped; edited place unreadable: \(error.localizedDescription)")
            return .failed
        }
        guard placeExists else { return .placeMissing }

        guard let allStays = fetchReconciliationStays(orSkip: "Routine-place change") else { return .failed }
        guard !allStays.isEmpty else { return .committed(resetCount: 0) }
        guard let dependencies = fetchHomeAreaDependencies(orSkip: "Routine-place change") else { return .failed }
        let routineRows = dependencies.routinePlaces
        let homeRows = classificationAnchors(of: dependencies)
        let overrides = dependencies.overrides

        let routineRings = routineRows.map {
            RoutineRing(
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt
            )
        }
        let homeRings = withShapes(homeRows.map { HomeRing($0) }, overrides: overrides)

        var affectedCompletedTrips: [ObjectIdentifier: Trip] = [:]
        var affectedOpenTrips: [ObjectIdentifier: Trip] = [:]

        func resetStay(_ stay: Stay) {
            if let trip = stay.trip {
                let identity = ObjectIdentifier(trip)
                if trip.isComplete {
                    affectedCompletedTrips[identity] = trip
                } else {
                    affectedOpenTrips[identity] = trip
                }
            }
            stay.category = .unclassified
            stay.trip = nil
            stay.orderInTrip = nil
        }
        func isSacred(_ stay: Stay) -> Bool {
            if stay.userOverridden { return true }
            if let trip = stay.trip, trip.userEdited { return true }
            return false
        }
        func matchesRoutineNow(_ stay: Stay) -> Bool {
            Self.matchesRoutine(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                places: routineRings
            )
        }
        func matchesHomeNow(_ stay: Stay) -> Bool {
            Self.matchesHome(
                stayStart: stay.startTime,
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                homes: homeRings
            )
        }

        var resetCount = 0

        // Both loops are deliberately GLOBAL rather than scoped to the changed
        // ring: a coverage change adds matches in one direction and removes
        // them in the other, and using the same predicate `preFilterStays`
        // stamps with is what makes the pair non-oscillating.

        // Stamp direction: a trip stay that now falls inside a routine ring.
        // Home wins in `preFilterStays`, so a home-matching stay is left alone.
        for stay in allStays where stay.category == .destination || stay.category == .transit {
            guard !isSacred(stay) else { continue }
            guard !matchesHomeNow(stay) else { continue }
            if matchesRoutineNow(stay) {
                resetStay(stay)
                resetCount += 1
            }
        }

        // Release routine stays no longer covered after a shrink or move.
        for stay in allStays where stay.category == .routine {
            guard !isSacred(stay) else { continue }
            if !matchesRoutineNow(stay) {
                resetStay(stay)
                resetCount += 1
            }
        }

        // See the home-change path: without clearing here, assembly observes
        // only the post-detach membership and can carry a pre-detach title
        // (and every localized derivative) onto that smaller ongoing trip.
        for trip in affectedOpenTrips.values {
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
        }

        // Reconcile completed trips the stamp direction emptied. Completed
        // trips are never rebuilt by assembly, so without this a trip whose
        // stays became routine survives as a zero-stay ghost card.
        var deletedGhostTrips = 0
        for trip in affectedCompletedTrips.values {
            let remaining = trip.orderedStays
            guard let first = remaining.first,
                  remaining.contains(where: { $0.category == .destination }) else {
                for stay in remaining {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(trip)
                deletedGhostTrips += 1
                continue
            }
            trip.startDate = first.startTime
            // endDate deliberately untouched — see the type-level note.
            TripTitleStore.invalidateGeneratedTitles(
                for: trip, in: modelContext)
            // See the home-change path: a failed home-place read keeps the debt.
            guard trip.recomputeSummary() else {
                return rollBackUnreadableHomePlaces(unit: "Routine-place change")
            }
        }
        if deletedGhostTrips > 0 {
            logger.info("Routine-place change: deleted \(deletedGhostTrips) fully-absorbed completed trip(s).")
        }

        guard saveReconciliation(unit: "Routine-place change") else { return .failed }
        return .committed(resetCount: resetCount)
    }
}
