//
//  PhotoImportService+Discard.swift
//  TravelLog
//

import BackgroundTasks
import CoreLocation
import Foundation
import Photos
import SwiftData
import UIKit
import WidgetKit
import os.log

extension PhotoImportService {

    /// One teardown attempt's result: whether the store deletion committed
    /// (widgets must reload) and the error to surface, if any. A sidecar
    /// cleanup error can accompany a committed deletion.
    nonisolated struct DiscardTeardownOutcome: Sendable {
        let committed: Bool
        let error: PhotoImportError?
    }

    /// Pure HexVisit evidence-window repair seam for DiscardHexRepairTests.
    nonisolated enum HexRepairAction: Equatable {
        case recompute(first: Date, last: Date)
        case keep
        case delete
    }

    /// A fully validated host-Stay mutation prepared before teardown changes
    /// any model. `geometry == nil` means no ping or Visit evidence survives
    /// and the Stay must be deleted. Model references remain actor-confined.
    private struct HostStayRepair {
        let stay: Stay
        let remainingIDs: [UUID]
        let geometry: StayGeometry?
        let h3Index: String?
        let isAirport: Bool?
    }

    /// The evidence-window rule: the import upsert only ever EXTENDS a
    /// row's window to its own ping timestamps, so a row whose
    /// `firstVisited` precedes the import's first ping for that cell (or
    /// whose `lastVisited` follows its last) carries evidence the import
    /// did not create — synced from another device whose pings may not
    /// have hydrated locally (the BackfillLatchPolicy hazard). Such rows
    /// are never deleted, and their remote-owned boundaries are never
    /// clobbered on recompute. Rows whose entire window sits inside the
    /// import’s footprint with no surviving local ping were import-born and may be deleted.
    nonisolated static func hexVisitRepairAction(
        rowFirstVisited: Date,
        rowLastVisited: Date,
        importFirst: Date,
        importLast: Date,
        survivingFirst: Date?,
        survivingLast: Date?
    ) -> HexRepairAction {
        let hasOutsideEvidence =
            rowFirstVisited < importFirst || rowLastVisited > importLast
        guard let survivingFirst else {
            return hasOutsideEvidence ? .keep : .delete
        }
        let survivingLastResolved = survivingLast ?? survivingFirst
        let first = rowFirstVisited < importFirst
            ? min(rowFirstVisited, survivingFirst)
            : survivingFirst
        let last = rowLastVisited > importLast
            ? max(rowLastVisited, survivingLastResolved)
            : survivingLastResolved
        return .recompute(first: first, last: last)
    }

    #if DEBUG
    /// Teardown fetches and mutates inside PipelineGate; no model crosses its Sendable boundary.
    /// Test seam substitutes widget reload and bypasses BG scheduling and gate acquisition.
    /// A nil queue directory runs against a scratch queue, never the host
    /// app's Application Support.
    func performDiscardTeardownForTesting(
        dissolvedQueueDirectory: URL? = nil,
        reloadWidgets: @escaping @Sendable () async -> Void = {}
    ) async throws {
        let scratchQueueDirectory = dissolvedQueueDirectory == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "discard-queue-\(UUID().uuidString)", isDirectory: true)
            : nil
        defer {
            if let scratchQueueDirectory {
                try? FileManager.default.removeItem(at: scratchQueueDirectory)
            }
        }
        let outcome = await performDiscardTeardown(
            dissolvedQueueDirectory: dissolvedQueueDirectory ?? scratchQueueDirectory)
        if outcome.committed { await reloadWidgets() }
        if let error = outcome.error { throw error }
    }
    #endif

    /// Runs the store transaction and converts every failure into the public,
    /// Sendable error type required by `PipelineGate.runReturning`. A failed
    /// fetch, validation, or save rolls the actor context back so a retry does
    /// not inherit dirty in-memory models from the failed attempt.
    func performDiscardTeardown(
        dissolvedQueueDirectory: URL? = nil
    ) async -> DiscardTeardownOutcome {
        let deletedStayIDs: Set<UUID>
        do {
            deletedStayIDs = try performDiscardTeardownTransaction()
        } catch let error as PhotoImportError {
            modelContext.rollback()
            return DiscardTeardownOutcome(committed: false, error: error)
        } catch {
            modelContext.rollback()
            return DiscardTeardownOutcome(
                committed: false, error: .persistenceFailure(error.localizedDescription))
        }

        StatsSnapshotStore.clear()
        // The database deletion is committed. Sidecar removal can still fail,
        // but must not skip invalidating transient recorder state for those
        // deleted rows. Preserve the cleanup error so the caller can retry it.
        var cleanupError: PhotoImportError?
        do { try PhotoImportCheckpointJournal.clear(in: modelContainer) }
        catch { cleanupError = .persistenceFailure(error.localizedDescription) }
        // Drop the recovery records this commit left past restoring, with
        // their photo identifiers: it deleted one of their recorded stays and
        // neither a row of those stays (a UUID twin) nor of their trip is
        // left. A stay a live Visit kept, or a trip that came back, keeps its
        // record. Only after the commit: a rolled-back discard keeps them all.
        // Best effort: the deleted ids exist only in this invocation, so a
        // failed read or rewrite cannot be retried and is logged instead of
        // reported. Reporting it would make a committed deletion read as a
        // failed one and skip the caller's reconcile. The records stay as an
        // unreadable file keeps its bytes, and a swipe Forget removes them.
        if !deletedStayIDs.isEmpty {
            do {
                let remainingStayIDs = try Set(
                    modelContext.fetch(FetchDescriptor<Stay>()).map(\.id))
                let remainingTripIDs = try Set(
                    modelContext.fetch(FetchDescriptor<Trip>()).map(\.id))
                try DissolvedTripQueue.removeRecords(
                    deletedStayIDs: deletedStayIDs,
                    remainingStayIDs: remainingStayIDs,
                    remainingTripIDs: remainingTripIDs,
                    in: dissolvedQueueDirectory)
            } catch {
                logger.error("Discard recovery record cleanup failed: \(error.localizedDescription)")
            }
        }

        // These actor-local cursors describe rows the transaction has now
        // durably removed. Clear them only after save succeeds; otherwise a
        // failed discard would perturb a subsequent import despite rolling
        // the store back.
        await recorder.clearAffectedTripIDs()
        await recorder.resetLastImportedH3Index()
        await recorder.endImportDedupSession()
        return DiscardTeardownOutcome(committed: true, error: cleanupError)
    }

    /// Two distinct logical IDs exclude the current stay and UUID twins; date groups preserve strict earlier/later bounds.
    private func discardNeighborBounds(_ stays: [Stay]) throws
        -> (previousEnds: [PersistentIdentifier: Date], nextStarts: [PersistentIdentifier: Date]) {
        let groups = Dictionary(grouping: stays, by: \.startTime)
        let dates = groups.keys.sorted()
        var previousEnds: [PersistentIdentifier: Date] = [:]
        var nextStarts: [PersistentIdentifier: Date] = [:]
        var nearest: [Stay] = []
        for date in dates {
            try Task.checkCancellation()
            let group = groups[date]!.sorted {
                $0.id == $1.id ? $0.persistentModelID < $1.persistentModelID : $0.id.uuidString < $1.id.uuidString
            }
            for stay in group {
                previousEnds[stay.persistentModelID] = nearest.first { $0.id != stay.id }?.endTime
            }
            var updated: [Stay] = []
            for row in group + nearest where !updated.contains(where: { $0.id == row.id }) {
                updated.append(row)
                if updated.count == 2 { break }
            }
            nearest = updated
        }
        nearest = []
        for date in dates.reversed() {
            try Task.checkCancellation()
            let group = groups[date]!.sorted {
                $0.id == $1.id ? $0.persistentModelID < $1.persistentModelID : $0.id.uuidString < $1.id.uuidString
            }
            for stay in group {
                nextStarts[stay.persistentModelID] = nearest.first { $0.id != stay.id }?.startTime
            }
            var updated: [Stay] = []
            for row in group + nearest where !updated.contains(where: { $0.id == row.id }) {
                updated.append(row)
                if updated.count == 2 { break }
            }
            nearest = updated
        }
        return (previousEnds, nextStarts)
    }

    #if DEBUG
    @TaskLocal static var cancelBeforeDiscardSaveForTesting = false
    @TaskLocal static var failDiscardAnnotationFetchForTesting = false

    func discardNeighborBoundsForTesting() throws
        -> (previousEnds: [PersistentIdentifier: Date], nextStarts: [PersistentIdentifier: Date]) {
        try discardNeighborBounds(modelContext.fetch(FetchDescriptor<Stay>()))
    }
    #endif

    /// Returns the ids of the stay rows it deleted. The caller uses them only
    /// after this save commits.
    private func performDiscardTeardownTransaction() throws -> Set<UUID> {
        try Task.checkCancellation()
        modelContext.autosaveEnabled = false
        // Snapshot fetches up front — running them per-step would
        // re-fetch the now-deleted rows. These fetches are deliberately
        // throwing: treating a failed fetch as an empty table could turn a
        // recoverable store error into a destructive partial discard.
        let importTripsPredicate = #Predicate<Trip> { $0.sourceRaw == "photoImport" }
        let taggedImportTrips = try modelContext.fetch(FetchDescriptor<Trip>(predicate: importTripsPredicate))
        // Every row, so annotation ownership is decided against the rows
        // that survive this transaction. Trip counts are small.
        let allTrips = try modelContext.fetch(FetchDescriptor<Trip>())

        let mergedStaysPredicate = #Predicate<Stay> { $0.sourceRaw == "merged" }
        let mergedStays = try modelContext.fetch(FetchDescriptor<Stay>(predicate: mergedStaysPredicate))

        let importStaysPredicate = #Predicate<Stay> { $0.sourceRaw == "photoImport" }
        let importStays = try modelContext.fetch(FetchDescriptor<Stay>(predicate: importStaysPredicate))

        let externalHostPredicate = #Predicate<Stay> {
            $0.sourceRaw == "jsonImport" || $0.sourceRaw == "timelineImport" || $0.sourceRaw == "gpxImport"
        }
        let externalHostStays = try modelContext.fetch(
            FetchDescriptor<Stay>(predicate: externalHostPredicate)
        )
        let allStays = try modelContext.fetch(FetchDescriptor<Stay>())
        let neighbors = try discardNeighborBounds(allStays)

        // One chronological fetch serves both host reconstruction and the
        // later HexVisit repair. It also avoids an N+1 fetch for every UUID in
        // every touched Stay.
        let allPings = try modelContext.fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        ))
        let importPings = allPings.filter { $0.sourceRaw == DataSource.photoImport.rawValue }
        let importPingIDs = Set(importPings.map(\.id))

        var pingSnapshotsByID: [UUID: StayGeometryPing] = [:]
        var pingModelsByID: [UUID: [LocationPing]] = [:]
        pingSnapshotsByID.reserveCapacity(allPings.count)
        pingModelsByID.reserveCapacity(allPings.count)
        for ping in allPings {
            try Task.checkCancellation()
            let snapshot = StayGeometryPing(
                timestamp: ping.timestamp,
                latitude: ping.latitude,
                longitude: ping.longitude,
                sourceRaw: ping.sourceRaw
            )
            if let existing = pingSnapshotsByID[ping.id], existing != snapshot {
                // A Stay UUID cannot identify one authoritative coordinate if
                // duplicate logical pings disagree. Wait for normal store
                // convergence/dedup rather than selecting one arbitrarily.
                throw PhotoImportError.inconsistentLocalData
            }
            pingSnapshotsByID[ping.id] = snapshot
            pingModelsByID[ping.id, default: []].append(ping)
        }

        let allVisits = try modelContext.fetch(FetchDescriptor<Visit>())
        var visitsByStayID: [UUID: [StayGeometryVisit]] = [:]
        for visit in allVisits {
            try Task.checkCancellation()
            guard let stayID = visit.stayID else { continue }
            visitsByStayID[stayID, default: []].append(StayGeometryVisit(
                id: visit.id,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate,
                latitude: visit.latitude,
                longitude: visit.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                receivedAt: visit.receivedAt
            ))
        }

        // Validate every touched host before the first mutation. CloudKit can
        // hydrate a Stay before all LocationPing rows it references; rebuilding
        // from that subset would sync a false centroid and shortened time
        // window to otherwise-complete devices. The discard is retryable, so
        // missing evidence is a fail-closed condition.
        var hostRepairs: [HostStayRepair] = []
        for stay in mergedStays + externalHostStays {
            try Task.checkCancellation()
            let originalIDs = stay.pingIDs
            let remainingIDs = originalIDs.filter { !importPingIDs.contains($0) }
            guard remainingIDs.count != originalIDs.count else { continue }

            var survivingPings: [StayGeometryPing] = []
            survivingPings.reserveCapacity(remainingIDs.count)
            for id in remainingIDs {
                guard let ping = pingSnapshotsByID[id] else {
                    throw PhotoImportError.incompleteLocalData
                }
                survivingPings.append(ping)
            }
            let visitEvidence = visitsByStayID[stay.id] ?? []
            let geometry = StayGeometry.recompute(
                from: survivingPings,
                visits: visitEvidence,
                earliestAllowedStart: neighbors.previousEnds[stay.persistentModelID]?.addingTimeInterval(1),
                latestAllowedEnd: neighbors.nextStarts[stay.persistentModelID]?.addingTimeInterval(-1)
            )
            let h3Index: String?
            let isAirport: Bool?
            if let geometry {
                guard let index = H3Service.cellIndex(
                    latitude: geometry.centroidLatitude,
                    longitude: geometry.centroidLongitude
                ) else { throw PhotoImportError.inconsistentLocalData }
                h3Index = index
                isAirport = AirportDetector.shared.isNearAirport(
                    CLLocationCoordinate2D(
                        latitude: geometry.centroidLatitude,
                        longitude: geometry.centroidLongitude
                    )
                )
            } else {
                guard remainingIDs.isEmpty && visitEvidence.isEmpty else {
                    throw PhotoImportError.inconsistentLocalData
                }
                h3Index = nil
                isAirport = nil
            }
            hostRepairs.append(HostStayRepair(
                stay: stay,
                remainingIDs: remainingIDs,
                geometry: geometry,
                h3Index: h3Index,
                isAirport: isAirport
            ))
        }

        // Import-owned stays are deleted rather than reconstructed, but any
        // non-photo ping they reference must be released back to clustering.
        // Require those rows to be present before deleting the host; otherwise
        // a late-hydrating processed ping could become a permanent orphan.
        for stay in importStays {
            try Task.checkCancellation()
            for id in stay.pingIDs where !importPingIDs.contains(id) {
                guard pingModelsByID[id] != nil else {
                    throw PhotoImportError.incompleteLocalData
                }
            }
        }

        // A trip's stored `.photoImport` tag can trail its stays: a stay that
        // turned `.merged` before its parent was marked with it, or another
        // source the trip took in since. A tagged parent holding a stay this
        // discard keeps (anything but a photo-import stay or a host emptied
        // above) is repaired by the tail like any surviving trip, so its
        // identity, name and photo choices stay. Decided per physical row.
        let emptiedHostRows = Set(hostRepairs.filter { $0.geometry == nil }.map(\.stay.persistentModelID))
        var importTrips: [Trip] = []
        var repairedImportTrips: [Trip] = []
        for trip in taggedImportTrips {
            try Task.checkCancellation()
            let keepsAStay = (trip.stays ?? []).contains { stay in
                !stay.isDeleted
                    && stay.sourceRaw != DataSource.photoImport.rawValue
                    && !emptiedHostRows.contains(stay.persistentModelID)
            }
            if keepsAStay { repairedImportTrips.append(trip) } else { importTrips.append(trip) }
        }
        // Physical rows, not UUIDs: a UUID twin of an import trip with
        // another source survives step 5 and needs its own repair.
        let importTripRows = Set(importTrips.map(\.persistentModelID))

        // Collect affected trip IDs before deletion while stay.trip is still intact.
        var titleInputsBeforeRepair:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]

        func markTripAffected(_ trip: Trip?) {
            guard let trip else { return }
            let identity = ObjectIdentifier(trip)
            if titleInputsBeforeRepair[identity] == nil {
                titleInputsBeforeRepair[identity] =
                    TripTitleStore.ParentSemanticSnapshot(
                        trip: trip,
                        semantic: TripTitleStore.semanticSnapshot(for: trip))
            }
        }

        // Every Trip row this transaction deletes (step 5 and the repair
        // tail). HiddenPhoto / PinnedPhoto cleanup runs once they are all
        // staged, just before the save.
        var deletedTripRows: Set<PersistentIdentifier> = []
        var deletedTripIDs: Set<UUID> = []

        for trip in repairedImportTrips { markTripAffected(trip) }

        // Reconstruct only hosts touched by photo removal, preserving external-import provenance.
        // `.merged` also covers Timeline and GPX imports; untouched merged stays must remain unchanged.
        // Ids of the stay rows deleted below, UUID twins included.
        var deletedStayIDs: Set<UUID> = []
        for repair in hostRepairs {
            try Task.checkCancellation()
            let stay = repair.stay
            markTripAffected(stay.trip)
            guard let geometry = repair.geometry,
                  let h3Index = repair.h3Index,
                  let isAirport = repair.isAirport
            else {
                // Detach empty stays before deletion so inverse arrays cannot expose invalidated models.
                stay.trip = nil
                deletedStayIDs.insert(stay.id)
                modelContext.delete(stay)
                continue
            }

            let weatherKey = WeatherEnricher.WeatherValidityKey(stay)
            stay.pingIDs = repair.remainingIDs
            stay.pingCount = repair.remainingIDs.count
            stay.startTime = geometry.startTime
            stay.endTime = geometry.endTime
            stay.durationMinutes = geometry.durationMinutes
            stay.centroidLatitude = geometry.centroidLatitude
            stay.centroidLongitude = geometry.centroidLongitude
            stay.h3IndexRes6 = h3Index
            stay.isAirport = isAirport
            stay.sourceRaw = geometry.sourceRaw
            WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)
        }

        // Release surviving live pings from deleted photo-import stays by clearing isProcessed.
        // Continuity clustering can append live pings to an import stay without changing its source.
        var releasedLivePings = 0
        for stay in importStays {
            try Task.checkCancellation()
            if let trip = stay.trip, !importTripRows.contains(trip.persistentModelID) {
                // Only track surviving rows. A .photoImport trip is deleted
                // in step 5, so there's nothing to recompute; a UUID twin of
                // one with another source survives and is repaired.
                markTripAffected(trip)
            }
            let survivingPingIDs = stay.pingIDs.filter { !importPingIDs.contains($0) }
            for pingID in survivingPingIDs {
                // All referenced rows were preflighted above. If duplicate
                // logical UUID rows are temporarily present after CloudKit
                // convergence, release every copy; the normal deduplicator can
                // then choose the survivor without leaving a processed orphan.
                for ping in pingModelsByID[pingID] ?? [] where !ping.isDeleted {
                    ping.isProcessed = false
                    releasedLivePings += 1
                }
            }
            // Detach BEFORE deleting: SwiftData delays nullify until processPendingChanges.
            // Date and summary repair must not read discarded stays from a stale inverse array.
            stay.trip = nil
            deletedStayIDs.insert(stay.id)
            modelContext.delete(stay)
        }
        if releasedLivePings > 0 {
            logger.info("Discard released \(releasedLivePings) live ping(s) held by import stays for re-clustering.")
        }

        // Step 5: delete .photoImport trips that keep no stay.
        for trip in importTrips {
            try Task.checkCancellation()
            deletedTripRows.insert(trip.persistentModelID)
            deletedTripIDs.insert(trip.id)
            modelContext.delete(trip)
        }

        // Step 6: delete .photoImport pings.
        for ping in importPings {
            try Task.checkCancellation()
            modelContext.delete(ping)
        }

        // Repair imported HexVisits from surviving pings using the live chronological hex-reentry rule.
        // Apply repairs to all duplicate rows; deleting or recounting propagates across devices.
        // No surviving local ping does not prove import-only ownership under partial CloudKit hydration.
        // Preserve any boundary outside the import’s ping window: import upserts only extend that window.
        // Separately synced rows remain safe when they hydrate later.
        let affectedCells = Set(importPings.map(\.h3IndexRes6)).filter { !$0.isEmpty }
        if !affectedCells.isEmpty {
            var importFirstByCell: [String: Date] = [:]
            var importLastByCell: [String: Date] = [:]
            for ping in importPings {
            try Task.checkCancellation()
                let cell = ping.h3IndexRes6
                importFirstByCell[cell] = min(importFirstByCell[cell] ?? ping.timestamp, ping.timestamp)
                importLastByCell[cell] = max(importLastByCell[cell] ?? ping.timestamp, ping.timestamp)
            }

            let survivingPings = allPings.filter { !importPingIDs.contains($0.id) }
            var firstByCell: [String: Date] = [:]
            var lastByCell: [String: Date] = [:]
            var countByCell: [String: Int] = [:]
            var previousCell: String?
            for ping in survivingPings {
            try Task.checkCancellation()
                let cell = ping.h3IndexRes6
                if affectedCells.contains(cell) {
                    if firstByCell[cell] == nil { firstByCell[cell] = ping.timestamp }
                    lastByCell[cell] = ping.timestamp
                    if cell != previousCell { countByCell[cell, default: 0] += 1 }
                }
                previousCell = cell
            }
            for cell in affectedCells {
            try Task.checkCancellation()
                let cellKey = cell
                let importFirst = importFirstByCell[cell] ?? .distantFuture
                let importLast = importLastByCell[cell] ?? .distantPast
                let hexPredicate = #Predicate<HexVisit> { $0.h3Index == cellKey }
                let rows = try modelContext.fetch(FetchDescriptor<HexVisit>(predicate: hexPredicate))
                for row in rows {
                    switch Self.hexVisitRepairAction(
                        rowFirstVisited: row.firstVisited,
                        rowLastVisited: row.lastVisited,
                        importFirst: importFirst,
                        importLast: importLast,
                        survivingFirst: firstByCell[cell],
                        survivingLast: lastByCell[cell]
                    ) {
                    case .recompute(let first, let last):
                        row.firstVisited = first
                        row.lastVisited = last
                        // Recount visits only when the whole window comes from local evidence; remote-owned boundaries
                        // also protect the count against shrinkage under partial CloudKit hydration.
                        let windowIsLocalOnly =
                            first == firstByCell[cell] && last == lastByCell[cell]
                        if windowIsLocalOnly {
                            row.visitCount = max(1, countByCell[cell] ?? 1)
                        } else {
                            row.visitCount = max(1, row.visitCount)
                        }
                    case .keep:
                        continue
                    case .delete:
                        modelContext.delete(row)
                    }
                }
            }
        }

        // Recompute summaries AND dates: recomputeSummary does not update startDate/endDate.
        // Use remaining stays for boundaries and delete empty trips, matching assembleTrips.
        for snapshot in titleInputsBeforeRepair.values {
            try Task.checkCancellation()
            let trip = snapshot.trip
            if !trip.isDeleted {
                // Second belt on the same rule as the step-3/4 detach: even a
                // still-attached pending-deleted row must not decide the
                // boundaries, and reading `startTime` off an invalidated
                // @Model traps outright.
                let remaining = trip.orderedStays.filter { !$0.isDeleted }
                guard let first = remaining.first, let last = remaining.last else {
                    deletedTripRows.insert(trip.persistentModelID)
                    deletedTripIDs.insert(trip.id)
                    modelContext.delete(trip)
                    continue
                }
                trip.startDate = first.startTime
                if trip.isComplete, trip.endDate != nil {
                    trip.endDate = last.endTime
                }
                trip.recomputeSummary()
                // Invalidate titles only for membership, boundary, or title-input changes; ping-count and centroid repairs retain them.
                if snapshot.semantic != TripTitleStore.semanticSnapshot(for: trip) {
                    TripTitleStore.invalidateGeneratedTitles(
                        for: trip, in: modelContext)
                }
            }
        }

        // Delete HiddenPhoto / PinnedPhoto keyed to a deleted trip's UUID
        // unless a populated row with that UUID survives this transaction,
        // decided after every detach and deletion above. The same ownership
        // rule as TripsListView.deletePhotoAnnotations and
        // TripClassifier.deletePhotoAnnotationRows: the rows belong to every
        // twin, so a populated survivor keeps them and an empty one does not.
        let populatedSurvivorIDs = Set(allTrips.filter { trip in
            !deletedTripRows.contains(trip.persistentModelID) && !trip.isDeleted
                && (trip.stays ?? []).contains { !$0.isDeleted }
        }.map(\.id))
        for tripID in deletedTripIDs.subtracting(populatedSurvivorIDs) {
            try Task.checkCancellation()
            #if DEBUG
            if Self.failDiscardAnnotationFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            let id = tripID
            let hiddenPredicate = #Predicate<HiddenPhoto> { $0.tripID == id }
            let hiddenRows = try modelContext.fetch(FetchDescriptor<HiddenPhoto>(predicate: hiddenPredicate))
            for row in hiddenRows { modelContext.delete(row) }
            let pinnedPredicate = #Predicate<PinnedPhoto> { $0.tripID == id }
            let pinnedRows = try modelContext.fetch(FetchDescriptor<PinnedPhoto>(predicate: pinnedPredicate))
            for row in pinnedRows { modelContext.delete(row) }
        }

        // Step 8: delete every state row, including temporary CloudKit
        // duplicates. Teardown must propagate read failures.
        let stateRows = try modelContext.fetch(FetchDescriptor<PhotoImportState>())
        for state in stateRows { modelContext.delete(state) }

        // Step 10: atomic save. Cancellation before here rolls back all work.
        #if DEBUG
        if Self.cancelBeforeDiscardSaveForTesting { withUnsafeCurrentTask { $0?.cancel() } }
        #endif
        try Task.checkCancellation()
        try saveOrThrow()
        return deletedStayIDs
    }

    private func saveOrThrow() throws {
        do { try modelContext.save() }
        catch { throw PhotoImportError.persistenceFailure(error.localizedDescription) }
    }
}
