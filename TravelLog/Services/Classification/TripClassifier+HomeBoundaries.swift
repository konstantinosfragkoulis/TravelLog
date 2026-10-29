//
//  TripClassifier+HomeBoundaries.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Homecoming Confirmation

    /// Minimum interval between one-shot confirmation location requests.
    nonisolated static let homecomingConfirmationThrottleSeconds: TimeInterval = 10 * 60

    /// A stationary homecoming may receive no further SLC ping to establish stored dwell.
    /// After enough wall time, request a confirming measurement through didUpdateLocations → PingRecorder;
    /// never close by wall time alone because an isolated false home fix must not become a boundary.
    nonisolated static func homecomingConfirmationNeeded(
        terminalStayCategory: StayCategory,
        terminalStaySource: DataSource,
        terminalStayStartTime: Date,
        terminalStayEndTime: Date,
        hasOpenTrip: Bool,
        now: Date
    ) -> Bool {
        guard hasOpenTrip else { return false }
        guard terminalStayCategory == .home, terminalStaySource == .liveSLC else { return false }
        let storedDwell = terminalStayEndTime.timeIntervalSince(terminalStayStartTime)
        guard storedDwell < homeBoundaryMinimumDwellSeconds else { return false }
        return now.timeIntervalSince(terminalStayStartTime) >= homeBoundaryMinimumDwellSeconds
    }

    /// Store-consulting wrapper: true when the caller should fire a one-shot
    /// `LocationService.requestCurrentLocation()` now (and stamps the
    /// throttle). Read-only against the store — no gate involvement. The
    /// hardware call stays at the call site (background refresh; RootView
    /// activation now requests a fix unconditionally) so this actor keeps
    /// zero CoreLocation coupling.
    internal func homecomingConfirmationDue(now: Date = .now) -> Bool {
        if let last = lastHomecomingConfirmationRequest,
           now.timeIntervalSince(last) < Self.homecomingConfirmationThrottleSeconds {
            return false
        }

        let openPredicate = #Predicate<Trip> { $0.isComplete == false }
        guard let openCount = try? modelContext.fetchCount(FetchDescriptor<Trip>(predicate: openPredicate)),
              openCount > 0 else {
            return false
        }

        // The chronologically-last stay overall. If any later ping had
        // arrived, it would either have accreted here (extending endTime)
        // or started a newer stay — so "terminal" is exactly the
        // no-ping-since-arrival state the rule needs.
        var terminalDescriptor = FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        terminalDescriptor.fetchLimit = 1
        guard let terminal = (try? modelContext.fetch(terminalDescriptor))?.first else {
            return false
        }

        guard Self.homecomingConfirmationNeeded(
            terminalStayCategory: terminal.category,
            terminalStaySource: terminal.source,
            terminalStayStartTime: terminal.startTime,
            terminalStayEndTime: terminal.endTime,
            hasOpenTrip: true,
            now: now
        ) else {
            return false
        }

        lastHomecomingConfirmationRequest = now
        return true
    }

    /// Check if a home stay exists between two trip stays (time-based).
    /// One qualifying home boundary's span, with the category/source decode
    /// already done. See `qualifyingHomeBoundarySpans`.
    nonisolated struct HomeBoundarySpan: Sendable {
        let start: Date
        let end: Date
    }

    /// Precompute qualifying boundaries once per pass to avoid repeated category/source decoding inside trip-by-stay scans.
    func qualifyingHomeBoundarySpans(_ allStays: [Stay]) -> [HomeBoundarySpan] {
        allStays.compactMap { stay in
            guard isQualifyingHomeBoundary(stay) else { return nil }
            return HomeBoundarySpan(start: stay.startTime, end: stay.endTime)
        }
    }

    /// Convenience overload retained for callers (and tests) that have no
    /// precomputed boundaries. Hot paths should build one `HomeBoundaryIndex`
    /// outside their loop and use the variant below.
    internal func hasHomeStayBetween(afterStay: Stay, beforeStay: Stay, allStays: [Stay]) -> Bool {
        hasHomeStayBetween(
            afterStay: afterStay,
            beforeStay: beforeStay,
            boundaries: HomeBoundaryIndex(qualifyingHomeBoundarySpans(allStays))
        )
    }

    /// True when a qualifying home span starts or ends inside the closed gap
    /// from `afterStay`'s end to `beforeStay`'s start.
    internal func hasHomeStayBetween(
        afterStay: Stay,
        beforeStay: Stay,
        boundaries: HomeBoundaryIndex
    ) -> Bool {
        // Only prequalified home spans may split trips; a zero-dwell live-SLC fix cannot be a boundary.
        boundaries.hasEndpoint(from: afterStay.endTime, through: beforeStay.startTime)
    }

    internal func closeTrip(_ trip: Trip, boundaries: HomeBoundaryIndex) {
        guard let lastStay = trip.orderedStays.last else { return }

        // Use >= as closeStaleOpenTrips does: a home stay starting exactly at the last stay's end is a homecoming.
        let tripEndTime = lastStay.endTime
        let homeAfter = boundaries.hasStart(atOrAfter: tripEndTime)

        if homeAfter {
            trip.endDate = lastStay.endTime
            trip.isComplete = true
        }
        // If no home stay found after, trip is still ongoing

        recomputeBackHalfSummary(trip)
    }

    // MARK: - Stage 4: Close Stale Open Trips

    /// Close open trips that assembly did not revisit once a qualifying home stay follows their last member.
    /// Returns -1 when a required read fails; nothing is mutated before the reads.
    internal func closeStaleOpenTrips() -> Int {
        let predicate = #Predicate<Trip> { $0.isComplete == false }
        let descriptor = FetchDescriptor<Trip>(predicate: predicate)

        let openTrips: [Trip]
        do {
            #if DEBUG
            if failStaleClosureFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            openTrips = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Stale-trip closure skipped; open trips unreadable: \(error.localizedDescription)")
            return -1
        }
        guard !openTrips.isEmpty else { return 0 }

        // Unsorted: only whether a qualifying home stay follows is read, and a
        // sorted fetch over pending edits re-sorts every row through SwiftData.
        let homePredicate = #Predicate<Stay> { $0.categoryRaw == "home" }
        let homeDescriptor = FetchDescriptor<Stay>(predicate: homePredicate)
        // A failed read is not "no homecoming".
        guard let homeStays = try? modelContext.fetch(homeDescriptor) else {
            logger.error("Stale-trip closure skipped; home stays unreadable.")
            return -1
        }
        // Same qualifying-boundary gate as `hasHomeStayBetween`/`closeTrip`:
        // a phantom zero-dwell live-SLC home stay must not close a trip
        // either (it would strand the REAL remainder of the journey in a
        // new second trip on the next assembly pass).
        let boundaries = HomeBoundaryIndex(qualifyingHomeBoundarySpans(homeStays))
        guard !boundaries.isEmpty else { return 0 }

        var closedCount = 0

        for trip in openTrips {
            guard let lastStay = trip.orderedStays.last else { continue }
            let tripEndTime = lastStay.endTime

            if boundaries.hasStart(atOrAfter: tripEndTime) {
                let titleInputsBeforeClose = TripTitleStore.semanticSnapshot(
                    for: trip)
                trip.endDate = lastStay.endTime
                trip.isComplete = true
                recomputeBackHalfSummary(trip)
                if !TripTitleStore.hasSameSemanticInputs(
                    titleInputsBeforeClose,
                    TripTitleStore.semanticSnapshot(for: trip)) {
                    TripTitleStore.invalidateGeneratedTitles(
                        for: trip, in: modelContext)
                }
                closedCount += 1
            }
        }

        return closedCount
    }

    // MARK: - Data Fetching Helpers

    /// Real Home rows, for code that reads homes for meaning (Welcome Home,
    /// the edited-Home lookup). Coverage reads `fetchAllAnchors` instead.
    func fetchAllHomes() -> [Home] {
        (try? fetchRequiredHomes()) ?? []
    }

    func fetchAllAnchors() -> [HomeAnchor] {
        (try? fetchRequiredAnchors()) ?? []
    }

    /// Required-read variants: a failed read is not absence, so callers abort their unit.
    func fetchRequiredHomes() throws -> [Home] {
        #if DEBUG
        if failHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        return try modelContext.fetch(FetchDescriptor<Home>())
    }

    /// Classification anchors: every Home plus every temporary home. Throws
    /// when either table is unreadable.
    func fetchRequiredAnchors() throws -> [HomeAnchor] {
        #if DEBUG
        if failHomeReadForTesting || failTemporaryHomeReadForTesting {
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try HomeAnchors.fetch(in: modelContext)
    }

    func fetchRequiredTemporaryHomes() throws -> [HomeAnchor] {
        try fetchRequiredTemporaryHomeDeclarations().anchors
    }

    /// The collapsed temporary homes, each one's coverage revision and the
    /// removed ids, from one read.
    func fetchRequiredTemporaryHomeDeclarations() throws -> (
        anchors: [HomeAnchor], revisions: [UUID: Int], removedIDs: Set<UUID>
    ) {
        #if DEBUG
        if failTemporaryHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let rows = try modelContext.fetch(FetchDescriptor<TemporaryHome>())
        return (HomeAnchors.collapsingTwins(rows).map { HomeAnchor($0) },
                Self.coverageRevisions(of: rows), HomeAnchors.removedIDs(rows))
    }

    /// The trips the user kept against a live temporary home: the union of
    /// `keptTripIDs` over every row of every declaration not removed.
    func fetchRequiredKeptTripIDs() throws -> Set<UUID> {
        #if DEBUG
        if failTemporaryHomeReadForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let rows = try modelContext.fetch(FetchDescriptor<TemporaryHome>())
        let removedIDs = HomeAnchors.removedIDs(rows)
        return TemporaryHome.keptTripIDs(of: rows.filter { !removedIDs.contains($0.id) })
    }

    func fetchRequiredRoutinePlaces() throws -> [RoutinePlace] {
        #if DEBUG
        if failRoutineReadForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        return try modelContext.fetch(FetchDescriptor<RoutinePlace>())
    }

    /// Every table a home-area pass reads before it mutates.
    struct HomeAreaDependencies {
        let homes: [Home]
        let temporaryHomes: [HomeAnchor]
        /// Each live temporary home's collapsed `coverageRevision`, read with `temporaryHomes`.
        let temporaryHomeRevisions: [UUID: Int]
        /// The removed temporary homes' ids, read with `temporaryHomes`.
        let removedTemporaryHomeIDs: Set<UUID>
        let routinePlaces: [RoutinePlace]
        let overrides: [HomeAreaOverride]
    }

    /// Every classification anchor of a dependency read. Built when called,
    /// so a Home row the unit has edited shows its new dates.
    func classificationAnchors(of dependencies: HomeAreaDependencies) -> [HomeAnchor] {
        dependencies.homes.map { HomeAnchor($0) } + dependencies.temporaryHomes
    }

    /// Reads every dependency before the caller mutates, so a failed read
    /// leaves nothing to roll back. A failed read is not absence: the unit
    /// is logged as skipped and the caller aborts with its own sentinel.
    func fetchHomeAreaDependencies(orSkip unit: String) -> HomeAreaDependencies? {
        do {
            let declarations = try fetchRequiredTemporaryHomeDeclarations()
            return HomeAreaDependencies(
                homes: try fetchRequiredHomes(),
                temporaryHomes: declarations.anchors,
                temporaryHomeRevisions: declarations.revisions,
                removedTemporaryHomeIDs: declarations.removedIDs,
                routinePlaces: try fetchRequiredRoutinePlaces(),
                overrides: try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()))
        } catch {
            logger.error("\(unit, privacy: .public) skipped; dependencies unreadable: \(error.localizedDescription)")
            return nil
        }
    }
}
