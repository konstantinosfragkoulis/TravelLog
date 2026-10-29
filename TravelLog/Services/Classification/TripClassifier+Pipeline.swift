//
//  TripClassifier+Pipeline.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import WidgetKit
import os.log

extension TripClassifier {

    struct ReclassificationTarget: Sendable {
        let identifier: PersistentIdentifier
        let members: Set<PersistentIdentifier>
    }

    /// Reset classifications but retain trip identities and links until the
    /// replacement commits. Orphan cleanup and other writers may run between units.
    /// Both tables are required reads taken before any mutation; nil means the
    /// reset did not commit (nothing changed), an empty array a committed
    /// reset with nothing to replace.
    func reclassifyAllCore() -> [ReclassificationTarget]? {
        guard !Task.isCancelled else { return nil }
        let allTrips: [Trip]
        let allStays: [Stay]
        do {
            #if DEBUG
            if failRebuildResetTripFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            allTrips = try modelContext.fetch(FetchDescriptor<Trip>())
            #if DEBUG
            if failRebuildResetStayFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            allStays = try modelContext.fetch(FetchDescriptor<Stay>())
        } catch {
            // Nothing is mutated before these reads.
            logger.error("Reclassify All reset read failed: \(error.localizedDescription)")
            return nil
        }
        let targets = allTrips.filter { !$0.userEdited }.map {
            ReclassificationTarget(identifier: $0.persistentModelID,
                members: Set(($0.stays ?? []).map(\.persistentModelID)))
        }
        for stay in allStays where !stay.userOverridden && !(stay.trip?.userEdited ?? false) {
            stay.category = .unclassified
        }
        do {
            #if DEBUG
            try SaveTestHook.beforeRebuildResetSave?()
            #endif
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Reclassify All reset save failed: \(error.localizedDescription)")
            return nil
        }
        return targets
    }

    /// Called only inside the final assembly gate. A trip edited or replaced
    /// since the reset is excluded from this explicit destructive rebuild.
    /// A failed read throws into the unit's rollback: it must never become a
    /// completed rebuild that replaced nothing.
    private func detachReclassificationTargets(_ targets: [ReclassificationTarget]) throws
        -> (identities: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)], regrouped: RegroupedTrips) {
        guard !targets.isEmpty else { return ([], RegroupedTrips()) }
        let byIdentifier = Dictionary(uniqueKeysWithValues: targets.map { ($0.identifier, $0.members) })
        #if DEBUG
        if failRebuildDetachFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let trips = try modelContext.fetch(FetchDescriptor<Trip>())
        let detached = trips.filter { trip in
            guard !trip.isDeleted, !trip.userEdited,
                  let members = byIdentifier[trip.persistentModelID] else { return false }
            return members == Set((trip.stays ?? []).map(\.persistentModelID))
        }
        // Their hidden photos follow their stays once identities are restored.
        var regrouped = RegroupedTrips()
        try regrouped.note(detached, in: modelContext)
        var identities: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)] = []
        for trip in detached {
            let stayIDs = Set((trip.stays ?? []).map(\.id))
            if !stayIDs.isEmpty { identities.append((trip.id, stayIDs, trip.startDate)) }
            for stay in trip.stays ?? [] {
                stay.trip = nil
                stay.orderInTrip = nil
            }
            modelContext.delete(trip)
            lastPipelineMadeChanges = true
        }
        return (identities, regrouped)
    }

    private func restoreReclassifiedIdentities(_ identitySnapshots: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)],
                                               regrouped: RegroupedTrips) throws {
        // Restore identities by dominant stay overlap so boundary shifts preserve favorites and hidden photos.
        if !identitySnapshots.isEmpty {
            #if DEBUG
            if failIdentityRestorationFetchForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            let rebuilt = try modelContext.fetch(FetchDescriptor<Trip>())
            let candidates = rebuilt.filter { !$0.userEdited }
            let claims = Self.identityClaims(
                snapshots: identitySnapshots,
                rebuilt: candidates.map {
                    (id: $0.id, stayIDs: Set(($0.stays ?? []).map(\.id)), startDate: $0.startDate)
                }
            )
            var restored = 0
            for trip in candidates {
                if let oldID = claims[trip.id], trip.id != oldID {
                    trip.id = oldID
                    restored += 1
                }
            }
            if restored > 0 {
                logger.info("Reclassify All: restored stable Trip.id on \(restored) rebuilt trip(s).")
            }
            // An id no rebuilt trip took passes its hidden photos to the
            // trips holding its stays, as an ordinary regroup does.
            try inheritRegroupedHiddenChoices(regrouped, outputs: candidates)
        }
    }

    nonisolated struct TripIdentityArbitration: Sendable {
        typealias Row = (id: UUID, stayIDs: Set<UUID>, startDate: Date)
        let candidates: [Row]
        let byStay: [UUID: [Int]]

        init(_ candidates: [Row]) {
            self.candidates = candidates
            var byStay: [UUID: [Int]] = [:]
            for (index, candidate) in candidates.enumerated() {
                for stay in candidate.stayIDs { byStay[stay, default: []].append(index) }
            }
            self.byStay = byStay
        }

        func overlaps(_ stayIDs: Set<UUID>) -> [Int: Int] {
            var counts: [Int: Int] = [:]
            for stay in stayIDs {
                for index in byStay[stay] ?? [] { counts[index, default: 0] += 1 }
            }
            return counts
        }

        // Rebuilds claim a UUID; assembly claims a physical output. Keep the policy explicit.
        func claims<Key: Hashable>(
            snapshots: [Row], claimKey: (Int) -> Key,
            eligible: (Int, Int) -> Bool = { _, _ in true }
        ) -> [(index: Int, id: UUID)] {
            let ordered = snapshots.sorted { a, b in
                if a.stayIDs.count != b.stayIDs.count { return a.stayIDs.count > b.stayIDs.count }
                if a.startDate != b.startDate { return a.startDate < b.startDate }
                return a.id.uuidString < b.id.uuidString
            }
            var claimed = Set<Key>(), result: [(index: Int, id: UUID)] = []
            for snapshot in ordered {
                var best: (index: Int, overlap: Int)?
                for (index, overlap) in overlaps(snapshot.stayIDs)
                where !claimed.contains(claimKey(index)) && eligible(index, overlap) {
                    if let current = best {
                        let a = candidates[index], b = candidates[current.index]
                        guard overlap > current.overlap || (overlap == current.overlap
                            && (a.startDate > b.startDate || (a.startDate == b.startDate
                                && (a.id.uuidString < b.id.uuidString
                                    || (a.id == b.id && index < current.index))))) else { continue }
                    }
                    best = (index, overlap)
                }
                guard let best else { continue }
                claimed.insert(claimKey(best.index))
                result.append((best.index, snapshot.id))
            }
            return result
        }
    }

    /// Restore each snapshot ID to its largest-overlap rebuilt trip, claimed at most once.
    /// Use Phase 3c ordering and tie-breaks; snapshots with no surviving stays claim nothing.
    nonisolated static func identityClaims(
        snapshots: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)],
        rebuilt: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)]
    ) -> [UUID: UUID] {
        let arbitration = TripIdentityArbitration(rebuilt)
        let claims = arbitration.claims(snapshots: snapshots, claimKey: { rebuilt[$0].id })
        return Dictionary(uniqueKeysWithValues: claims.map {
            (rebuilt[$0.index].id, $0.id)
        })
    }

    private struct Stage2Work: Sendable {
        var classified: Int
        var needsPublication: Bool
        /// The batch the classification units settled, by row.
        var planned: Set<PersistentIdentifier> = []
        /// An uncapped pass's planned stays left for later units, by UUID,
        /// one bounded unit each (`classificationUnits`), with the stays the
        /// pre-filter's resets handed back.
        var remaining: [[UUID]] = []
        /// How many units of `remaining`, from the first, the pre-filter has
        /// read: the rest are pre-filtered before any is classified.
        var preFiltered = 0

        mutating func absorb(_ unit: Stage2Work) {
            classified += unit.classified
            needsPublication = needsPublication || unit.needsPublication
            planned.formUnion(unit.planned)
        }
    }

    /// The UUIDs of `batch` in classification order, cut into units of at
    /// most `size` rows; a UUID's copies always share a unit, since
    /// classification judges them as one logical stay. A unit closes before
    /// a UUID whose copies would overflow it, and a UUID with more copies
    /// than `size` takes a unit of its own.
    nonisolated static func classificationUnits(_ batch: [Stay], size: Int) -> [[UUID]] {
        var rowCounts: [UUID: Int] = [:]
        var order: [UUID] = []
        for stay in batch {
            if rowCounts[stay.id] == nil { order.append(stay.id) }
            rowCounts[stay.id, default: 0] += 1
        }
        let limit = max(1, size)
        var units: [[UUID]] = []
        var current: [UUID] = []
        var rows = 0
        for id in order {
            let copies = rowCounts[id] ?? 0
            if !current.isEmpty, rows + copies > limit {
                units.append(current)
                current = []
                rows = 0
            }
            current.append(id)
            rows += copies
            if rows >= limit {
                units.append(current)
                current = []
                rows = 0
            }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// `completed` is true only when every unit of the pass committed: the
    /// classification unit and the final assembly (or rebuild replacement).
    /// Cancellation, a failed required read or save, and a rolled-back unit
    /// report false.
    func runPipelineStagesWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = nil,
        gate: PipelineGate,
        rebuild: [ReclassificationTarget] = [],
        unitPolicy: (@Sendable () -> Bool)? = nil
    ) async -> (created: Int, needsPublication: Bool, completed: Bool, classified: Int) {
        // Each unit checks as it begins that Delete All Data has not revoked
        // the pass since it started, and that the caller's policy still
        // holds; a unit refused stops the pass there, before it writes.
        let epoch = gate.revocationEpoch
        let admitted: @Sendable () -> Bool = {
            gate.revocationEpoch == epoch && unitPolicy?() != false
        }
        let preparedWork: Stage2Work? = await gate.runReturning(touching: []) {
            guard admitted() else { return nil }
            let prepared = await self.prepareGatedClassification(reclassifyRecentStays: reclassifyRecentStays,
                maxStaysPerCall: maxStaysPerCall)
            if prepared?.needsPublication != false { await StoreChangeTracker.shared.bump([.stay, .trip]) }
            return prepared
        }
        guard var drained = preparedWork else { return (0, true, false, 0) }
        // An uncapped pass (a rebuild, healing, a Home change) works through
        // the rest of its plan in bounded units of their own: location saves
        // and Delete All Data run between them, and cancellation or a revoked
        // epoch stops the pass before the next. Every unit is pre-filtered
        // before any is classified, so each stay is judged with every home
        // and routine anchor of the plan stamped, whatever the unit size.
        // Assembly still runs once.
        while drained.preFiltered < drained.remaining.count {
            let index = drained.preFiltered
            let unit = drained.remaining[index]
            guard !Task.isCancelled else { return (0, drained.needsPublication, false, drained.classified) }
            let filtered: (resetIDs: [UUID], needsPublication: Bool)? = await gate.runReturning(touching: []) {
                guard admitted(), !Task.isCancelled else { return nil }
                let filtered = await self.preFilterGatedUnit(unit)
                if filtered?.needsPublication == true { await StoreChangeTracker.shared.bump([.stay, .trip]) }
                return filtered
            }
            guard let filtered else { return (0, true, false, drained.classified) }
            drained.remaining[index] += filtered.resetIDs
            drained.needsPublication = drained.needsPublication || filtered.needsPublication
            drained.preFiltered += 1
        }
        while !drained.remaining.isEmpty {
            let unit = drained.remaining.removeFirst()
            guard !Task.isCancelled else { return (0, drained.needsPublication, false, drained.classified) }
            let settled: Stage2Work? = await gate.runReturning(touching: []) {
                guard admitted(), !Task.isCancelled else { return nil }
                let settled = await self.classifyGatedUnit(unit)
                if settled?.needsPublication == true { await StoreChangeTracker.shared.bump([.stay, .trip]) }
                return settled
            }
            guard let settled else { return (0, true, false, drained.classified) }
            drained.absorb(settled)
        }
        let work = drained
        #if DEBUG
        if let hook = SaveTestHook.betweenPassUnits { await hook() }
        #endif
        guard !Task.isCancelled else { return (0, work.needsPublication, false, work.classified) }
        return await gate.runReturning(touching: []) {
            guard admitted() else { return (0, work.needsPublication, false, work.classified) }
            let finished = await self.finishGatedClassification(work: work, rebuild: rebuild)
            if finished.needsPublication { await StoreChangeTracker.shared.bump([.stay, .trip]) }
            return (finished.created, work.needsPublication || finished.needsPublication,
                finished.completed, work.classified)
        }
    }

    /// Stages 1 to 2 in one unit: pre-filter, recent-stay reset, then every
    /// stay of the batch settled by the duration rules or the heuristics,
    /// over one read of the timeline. With no cap the whole backlog is
    /// planned first, before anything changes, and this unit pre-filters
    /// only its first `uncappedStage2UnitSize` rows: when that is the whole
    /// plan it settles them (with the stays its resets hand back), and
    /// otherwise it settles nothing and leaves the plan to later units, which
    /// pre-filter the rest (`preFilterGatedUnit`) before any classifies
    /// (`classifyGatedUnit`). A failed read or save rolls the unit back and
    /// returns nil.
    private func prepareGatedClassification(reclassifyRecentStays: Bool, maxStaysPerCall: Int?) async -> Stage2Work? {
        var remaining: [[UUID]] = []
        var firstRows: [Stay]?
        if maxStaysPerCall == nil {
            do {
                // A failed backlog read is not an empty backlog.
                let backlog = try fetchStage2Batch(cap: nil, priorityIDs: [])
                remaining = Self.classificationUnits(backlog, size: uncappedStage2UnitSize)
                let first = Set(remaining.isEmpty ? [] : remaining.removeFirst())
                firstRows = backlog.filter { first.contains($0.id) }
            } catch {
                rollBackClassificationUnit()
                return nil
            }
        }
        guard let prepared = await prepareClassificationStages(
            reclassifyRecentStays: reclassifyRecentStays, preFilterCandidates: firstRows) else {
            rollBackClassificationUnit()
            return nil
        }
        guard !Task.isCancelled else {
            return Stage2Work(classified: 0, needsPublication: prepared.needsPublication)
        }
        if let firstRows, !remaining.isEmpty {
            // Later units hold anchors of this plan the pre-filter has not
            // stamped yet; the first unit's stays wait for them.
            do {
                let needsPublication = modelContext.hasChanges || prepared.needsPublication
                try savePipelineResults()
                let first = Set(firstRows.map(\.id)).union(prepared.resetIDs)
                return Stage2Work(classified: 0, needsPublication: needsPublication,
                    remaining: [Array(first)] + remaining, preFiltered: 1)
            } catch {
                rollBackClassificationUnit()
                return nil
            }
        }
        do {
            // A failed batch read is not an empty backlog.
            let batch = try firstRows.map {
                try fetchUnclassifiedStays(Set($0.map(\.id)).union(prepared.resetIDs))
            } ?? fetchStage2Batch(cap: maxStaysPerCall, priorityIDs: prepared.resetIDs)
            let (classified, settled) = try settleStage2Batch(batch)
            let needsPublication = modelContext.hasChanges || prepared.needsPublication
            try savePipelineResults()
            return Stage2Work(classified: classified, needsPublication: needsPublication,
                planned: Set(settled.map(\.persistentModelID)), remaining: remaining)
        } catch {
            rollBackClassificationUnit()
            return nil
        }
    }

    /// One later pre-filter unit of an uncapped pass: the planned stays of
    /// `unit` still unclassified take Stage 1 (`preFilterUnitRows`) and
    /// nothing else. Returns the stays its resets handed back, which classify
    /// with `unit`; a failed read or save rolls the unit back and returns nil.
    private func preFilterGatedUnit(_ unit: [UUID]) async -> (resetIDs: [UUID], needsPublication: Bool)? {
        // Earlier units committed; read what other writers committed since.
        modelContext.rollback()
        guard await primeHomeShapes(seedsOnly: true) else {
            rollBackClassificationUnit()
            return nil
        }
        do {
            let resetIDs = try preFilterUnitRows(Set(unit))
            let needsPublication = modelContext.hasChanges
            try savePipelineResults()
            return (resetIDs, needsPublication)
        } catch {
            rollBackClassificationUnit()
            return nil
        }
    }

    /// One later classification unit of an uncapped pass: the planned stays
    /// of `unit` (every copy of each UUID) still unclassified, on fresh
    /// reads, take Stage 1 again (`preFilterUnitRows`) and then Stage 2, with
    /// the stays those resets hand back. A failed read or save rolls the unit
    /// back and returns nil.
    private func classifyGatedUnit(_ unit: [UUID]) async -> Stage2Work? {
        // Earlier units committed; read what other writers committed since.
        modelContext.rollback()
        guard await primeHomeShapes(seedsOnly: true) else {
            rollBackClassificationUnit()
            return nil
        }
        do {
            let resetIDs = try preFilterUnitRows(Set(unit))
            let batch = try fetchUnclassifiedStays(Set(unit).union(resetIDs))
            let (classified, settled) = try settleStage2Batch(batch)
            let needsPublication = modelContext.hasChanges
            try savePipelineResults()
            return Stage2Work(classified: classified, needsPublication: needsPublication,
                planned: Set(settled.map(\.persistentModelID)))
        } catch {
            rollBackClassificationUnit()
            return nil
        }
    }

    /// Stage 1 for the stays `ids` names that are still unclassified, on
    /// fresh reads: the home and routine pre-filter, then the reset of the
    /// journey tails before the anchors it stamps. An interleaved write (a
    /// photo attachment moving a centroid) may have put a planned stay inside
    /// a home area since the plan. Returns the reset stays; throws on a
    /// failed read.
    private func preFilterUnitRows(_ ids: Set<UUID>) throws -> [UUID] {
        // Only this unit's stamps are new anchors.
        stampedAnchors = []
        defer { stampedAnchors = [] }
        let rows = try fetchUnclassifiedStays(ids)
        guard !rows.isEmpty else { return [] }
        guard primeHomeOrbits(anchors: try fetchRequiredAnchors()) else { throw CocoaError(.fileReadUnknown) }
        let covered = preFilterStays(rows)
        guard covered >= 0 else { throw CocoaError(.fileReadUnknown) }
        if covered > 0 {
            TripTitleStore.invalidateHomePlaceIndex()
            lastPipelineMadeChanges = true
        }
        let resetIDs = try prepareForReclassification(newAnchors: stampedAnchors, recentWindow: false)
        if !resetIDs.isEmpty { lastPipelineMadeChanges = true }
        return resetIDs
    }

    /// Every copy of the stays `ids` names that is still unclassified, in
    /// classification order. Throws on a failed read.
    private func fetchUnclassifiedStays(_ ids: Set<UUID>) throws -> [Stay] {
        guard !ids.isEmpty else { return [] }
        let wanted = Array(ids)
        return try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate<Stay> {
            wanted.contains($0.id) && $0.categoryRaw == "unclassified"
        })).filter { !$0.isDeleted }.sorted(by: Self.classificationOrder)
    }

    /// Stage 2 over `batch` and the stops before it (`stopsBefore`): the
    /// duration rules, then the heuristics, over one read of the timeline,
    /// with the summaries of the edited owners whose members it settles.
    /// Throws on a failed read. Returns how many stays it classified and the
    /// stays it settled, the unit's planned stays.
    private func settleStage2Batch(_ batch: [Stay]) throws -> (classified: Int, settled: [Stay]) {
        let ordered = try batch.isEmpty ? [] : orderedClassificationStays(in: modelContext)
        let batch = batch + stopsBefore(batch, in: ordered)
        let deterministic = try resolveDeterministicOutcomes(batch, timeline: ordered)
        let heuristic = try classifyWithHeuristics(stays: deterministic.ambiguous, ordered: ordered)
        // Edited owners' summaries commit with their settled members.
        summaryHomePlacesUnreadable = false
        try healUserEditedOpenTripSummaries()
        guard !summaryHomePlacesUnreadable else { throw TripTitleStore.HomePlaceNamesUnreadable() }
        return (deterministic.resolved.count + heuristic, batch)
    }

    /// The stays a stay of `batch` follows, which were judged without it: as
    /// `journeyTailRows` walks back from a new anchor, the stays before each
    /// in `ordered` back to and including the first that cannot be a blip,
    /// within `anchorWalkLimit` stays and stopping at a home or routine stay.
    /// An import that brings a settled stop its next stay (its anchor on that
    /// side and, for photos, its next observation) has no recent-stay window
    /// to judge it again. The automatic destination and transit stays among
    /// them are reset to unclassified and returned; a stay the user set, or
    /// one in a trip the user edited or that is complete, keeps its category
    /// (`journeyTail(before:)`). Each walk ends at the first stay that
    /// cannot be a blip, inside a run of new stays another of the batch, so
    /// the batch bounds them. The walk reads one row per UUID, as the
    /// heuristics judge it (`logicalClassificationTimeline`), and every copy
    /// of a reset UUID is reset and returned with it, as is each copy of it
    /// already unclassified that `batch` does not hold (a later unit's), so
    /// one decision covers the logical stay (`fetchStage2Batch`).
    private func stopsBefore(_ batch: [Stay], in ordered: [Stay]) -> [Stay] {
        let logical = Self.logicalClassificationTimeline(ordered, batch: batch)
        var position: [UUID: Int] = [:]
        for (index, stay) in logical.enumerated() { position[stay.id] = index }
        var copies: [UUID: [Stay]] = [:]
        for stay in ordered { copies[stay.id, default: []].append(stay) }
        var joined = Set(batch.map(\.persistentModelID))
        var reset: [Stay] = []
        for stay in Self.logicalClassificationBatch(batch) {
            guard let index = position[stay.id] else { continue }
            for candidate in logical[..<index].reversed().prefix(Self.anchorWalkLimit) {
                if candidate.category == .home || candidate.category == .routine { break }
                let rows = copies[candidate.id] ?? []
                var handedBack = false
                for copy in rows
                where (copy.category == .destination || copy.category == .transit)
                    && !copy.userOverridden && !(copy.trip?.userEdited ?? false)
                    && !(copy.trip?.isComplete ?? false) {
                    copy.category = .unclassified
                    handedBack = true
                }
                if handedBack {
                    for copy in rows where copy.category == .unclassified && !copy.userOverridden
                        && joined.insert(copy.persistentModelID).inserted {
                        reset.append(copy)
                    }
                }
                if candidate.durationMinutes > StayClassificationInputs.shortStopMinutes { break }
            }
        }
        return reset
    }

    /// Discard a classifier unit's unsaved work. The pre-filter invalidates
    /// the home-place index after stamping `.home`,
    /// so a snapshot refilled from those rows must not outlive the rollback.
    private func rollBackClassificationUnit() {
        modelContext.rollback()
        pendingHiddenLineages = []
        pendingHiddenSplits = []
        pendingDetachedMembers = nil
        pendingSparedTrips = nil
        pendingHistoricalScan = .none
        TripTitleStore.invalidateHomePlaceIndex()
    }

    func orderedClassificationStays(in context: ModelContext) throws -> [Stay] {
        Self.sortedForClassification(try context.fetch(FetchDescriptor<Stay>()).filter { !$0.isDeleted })
    }

    /// `sorted(by: classificationOrder)`, reading each start once: only rows
    /// that share a start compare by id and identity. The order is total, so
    /// the result is the same. A NaN start has no place in that order, so a
    /// timeline holding one takes the comparator sort as before.
    static func sortedForClassification(_ stays: [Stay]) -> [Stay] {
        let keyed = stays.map { (start: $0.startTime, stay: $0) }
        guard !keyed.contains(where: { $0.start.timeIntervalSinceReferenceDate.isNaN }) else {
            return stays.sorted(by: classificationOrder)
        }
        let byStart = keyed.sorted { $0.start < $1.start }
        var result: [Stay] = []
        result.reserveCapacity(byStart.count)
        var lower = 0
        while lower < byStart.count {
            var upper = lower + 1
            while upper < byStart.count, byStart[upper].start == byStart[lower].start { upper += 1 }
            if upper - lower == 1 {
                result.append(byStart[lower].stay)
            } else {
                result += byStart[lower..<upper].map(\.stay).sorted(by: classificationOrder)
            }
            lower = upper
        }
        return result
    }

    static func classificationOrder(_ lhs: Stay, _ rhs: Stay) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
    }

    // Same-UUID Stay twins are one logical stay for classification:
    // one decision and one set of neighbours per UUID, copied to every
    // eligible physical copy.

    /// Each UUID's earliest copy in `batch` (classification order).
    static func logicalClassificationRepresentatives(_ batch: [Stay]) -> [UUID: Stay] {
        var representatives: [UUID: Stay] = [:]
        for stay in batch {
            if let current = representatives[stay.id], !classificationOrder(stay, current) { continue }
            representatives[stay.id] = stay
        }
        return representatives
    }

    /// `batch` with one copy per UUID, in batch order.
    static func logicalClassificationBatch(_ batch: [Stay]) -> [Stay] {
        let representatives = logicalClassificationRepresentatives(batch)
        return batch.filter { representatives[$0.id] === $0 }
    }

    /// One row per UUID at its first position in `ordered`, so a twin is never
    /// its own neighbour. A UUID in `batch` shows its batch representative.
    static func logicalClassificationTimeline(_ ordered: [Stay], batch: [Stay]) -> [Stay] {
        let representatives = logicalClassificationRepresentatives(batch)
        var seen = Set<UUID>()
        return ordered.compactMap { stay in
            guard seen.insert(stay.id).inserted else { return nil }
            return representatives[stay.id] ?? stay
        }
    }

    private func finishGatedClassification(work: Stage2Work, rebuild: [ReclassificationTarget]) async
        -> (created: Int, needsPublication: Bool, completed: Bool) {
        // The classification unit committed; discard registered old values
        // before assembly reads what other writers committed since.
        modelContext.rollback()
        // Seeds only: orbits are derived where this unit first reads them
        // (stranded pre-filter, assembly), so a settled pass derives none.
        let shapesPrimed = await primeHomeShapes(seedsOnly: true)
        // Favourites live on the main actor; assembly leaves them whole
        // against a late home boundary.
        let pinnedTripIDs = await pinnedTripIDsSource()
        guard !Task.isCancelled else {
            return (0, work.needsPublication || lastPipelineMadeChanges || work.classified > 0, false)
        }
        do {
            let stranded = try classifyStrandedStays(planned: work.planned, shapesPrimed: shapesPrimed)
            let detached = try detachReclassificationTargets(rebuild)
            let classified = work.classified + stranded
            let result = try assembleClassificationResults(classified: classified,
                needsPublication: work.needsPublication || lastPipelineMadeChanges || classified > 0,
                completingRebuild: !rebuild.isEmpty, pinnedTripIDs: pinnedTripIDs)
            try restoreReclassifiedIdentities(detached.identities, regrouped: detached.regrouped)
            if !rebuild.isEmpty {
                #if DEBUG
                try SaveTestHook.beforeRebuildSave?()
                #endif
                // Deletion, assembly and UUID restoration reach the store in
                // one commit; rollback retains original trips/annotations.
                try savePipelineResults()
            }
            // The launch latch requires the unit's last commit:
            // an unsaved repair must retry on the next pass, not wait for relaunch.
            if result.backHalfCompleted { hasRunBackHalfSinceLaunch = true }
            return (result.created, result.needsPublication, result.completed)
        } catch {
            rollBackClassificationUnit()
            hasRunBackHalfSinceLaunch = false
            logger.error("Classification unit rolled back: \(error.localizedDescription)")
            return (0, true, false)
        }
    }

    /// A stay of this pass's batch reset while attached after the
    /// classification unit committed (a photo import growing it across a
    /// duration band) must not be left out of assembly: rebuild and
    /// ongoing-row reuse restore identity only through classified members.
    /// Such stays take the pre-filter, the duration rules and the heuristics
    /// here, on fresh reads; the batch bounds the unit. A failed read throws,
    /// rolling the unit back with the stays still unclassified.
    private func classifyStrandedStays(planned: Set<PersistentIdentifier>, shapesPrimed: Bool) throws -> Int {
        guard !planned.isEmpty else { return 0 }
        let descriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "unclassified" && !$0.userOverridden
        })
        let stranded = try modelContext.fetch(descriptor).filter {
            !$0.isDeleted && $0.trip != nil && planned.contains($0.persistentModelID)
        }
        guard !stranded.isEmpty else { return 0 }
        let anchors = try fetchRequiredAnchors()
        guard shapesPrimed, primeHomeOrbits(anchors: anchors) else { throw CocoaError(.fileReadUnknown) }
        let covered = preFilterStays(stranded)
        guard covered >= 0 else { throw CocoaError(.fileReadUnknown) }
        if covered > 0 { TripTitleStore.invalidateHomePlaceIndex() }
        // A stranded stay stamped home completes the journey tail before it.
        let tail = try journeyTail(before: stampedAnchors)
        stampedAnchors = []
        for stay in tail { stay.category = .unclassified }
        var seen = Set<PersistentIdentifier>()
        let remaining = (stranded + tail).filter {
            $0.category == .unclassified && seen.insert($0.persistentModelID).inserted
        }
        guard !remaining.isEmpty else { return covered }
        let ordered = try orderedClassificationStays(in: modelContext)
        let deterministic = try resolveDeterministicOutcomes(remaining, timeline: ordered)
        return covered + deterministic.resolved.count
            + (try classifyWithHeuristics(stays: deterministic.ambiguous, ordered: ordered))
    }

    /// Rebuilds the pass's Visit-backed stay ids; the caller decides whether a failed read is fatal.
    private func refreshVisitBackedStayIDs() throws {
        #if DEBUG
        if failVisitBackedReadForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        visitBackedStayIDs = try fetchVisitBackedStayIDs()
    }

    func fetchVisitBackedStayIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stayID != nil })
        descriptor.propertiesToFetch = [\.stayID]
        return Set(try modelContext.fetch(descriptor).compactMap(\.stayID))
    }

    /// Returns nil when a Stage 1 dependency read fails.
    /// `preFilterCandidates` bounds the pre-filter to those stays (an
    /// uncapped pass's first unit); nil pre-filters every unclassified stay.
    private func prepareClassificationStages(
        reclassifyRecentStays: Bool, preFilterCandidates: [Stay]? = nil
    ) async -> (resetIDs: [UUID], needsPublication: Bool)? {
        var needsPublication = false
        classifiedStayIDs = []
        lastPipelineMadeChanges = false

        // A linked Visit gives its home Stay measured-dwell credit in the
        // boundary rule for this pass only. Open and closed visits both count;
        // each pass rebuilds the set so newly linked visits are observed.
        // A failed read is not an empty set: without the credit, outings a
        // Visit-backed home stay separates would join, so the pass fails.
        do {
            try refreshVisitBackedStayIDs()
        } catch {
            logger.error("Failed to fetch Visit-backed stay IDs: \(error.localizedDescription)")
            return nil
        }

        // Stage 1: Pre-filter obvious home/routine stays. Learned orbits are read
        // only by this judgment, so derive them only when a stay awaits it. A
        // failed probe is not absence: it takes the full path. The probe, the
        // orbit prime and the pre-filter run with no suspension between them.
        guard await primeHomeShapes(seedsOnly: true) else { return nil }
        let judging = (try? modelContext.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }))).map { $0 > 0 } ?? true
        if judging {
            guard let anchors = try? fetchRequiredAnchors(), primeHomeOrbits(anchors: anchors) else { return nil }
        }
        // Only this pass's stamps are new anchors.
        stampedAnchors = []
        defer { stampedAnchors = [] }
        let preFilteredCount = judging ? preFilterStays(preFilterCandidates) : 0
        guard preFilteredCount >= 0 else { return nil }
        if preFilteredCount > 0 {
            TripTitleStore.invalidateHomePlaceIndex()
            lastPipelineMadeChanges = true
            logger.info("Pre-filtered \(preFilteredCount) stay(s) as home/routine.")
        }

        // Stage 1.5 runs before any cancellation point after the pre-filter,
        // so a new anchor's stamp never commits without its journey tail's
        // reset: once stamped, the anchor is no longer new.
        // Imports and backlog bites skip the recent-stay window because historical
        // backlog adds no current-journey context; every path hands back the
        // journey tails of the anchors it stamped.
        // Stage 2 must include every stay reset here even when the per-call cap is reached.
        let resetStayIDs: [UUID]
        do {
            resetStayIDs = try prepareForReclassification(
                newAnchors: stampedAnchors, recentWindow: reclassifyRecentStays)
        } catch {
            // The pre-filter's changes roll back with the unit.
            logger.error("Stage 1.5 skipped; a journey read failed: \(error.localizedDescription)")
            return nil
        }
        if !resetStayIDs.isEmpty {
            lastPipelineMadeChanges = true
            logger.info("Prepared \(resetStayIDs.count) stay(s) for reclassification.")
        }

        guard !Task.isCancelled else {
            logger.info("Pipeline cancelled after reclassification prep.")
            needsPublication = modelContext.hasChanges || needsPublication
            // A failed save returns nil so the caller rolls the unit back.
            guard (try? savePipelineResults()) != nil else { return nil }
            return ([], needsPublication)
        }

        return (resetStayIDs, needsPublication)
    }

    /// Throws on a failed required read or save; the caller rolls the unit
    /// back. `backHalfCompleted` tells the caller to arm the launch latch
    /// once the unit's last commit lands; the rebuild commits in the caller.
    func assembleClassificationResults(classified: Int, needsPublication initialPublication: Bool,
        completingRebuild: Bool = false, pinnedTripIDs: Set<UUID> = []) throws
        -> (created: Int, needsPublication: Bool, completed: Bool, backHalfCompleted: Bool) {
        var needsPublication = initialPublication
        if classified > 0 { lastPipelineMadeChanges = true }
        // Once replacement starts, finish its synchronous identity transaction
        // even if cancellation arrives between the admission check and here.
        guard completingRebuild || !Task.isCancelled else {
            logger.info("Pipeline cancelled after classification.")
            needsPublication = modelContext.hasChanges || needsPublication
            // A failed save throws into the unit's rollback rather than
            // leaving these changes for whichever unit saves next.
            try savePipelineResults()
            return (0, needsPublication, false, false)
        }

        // The back half may skip unchanged, correctly assigned stays; ongoing trips display directly from their stays.
        // Closure and provisional-admission checks must still catch dwell growth without category changes.
        // The launch latch is armed by the caller after the commit, and only for a complete, non-cancelled pass.
        let upstreamChanged = lastPipelineMadeChanges
        var newTrips = 0
        var backHalfCompleted = false
        // Clustering can change sanity inputs without unclassifying a stay; the fixpoint check must catch that.
        if upstreamChanged || !hasRunBackHalfSinceLaunch || assemblyInvariantViolated(pinnedTripIDs: pinnedTripIDs)
            || sanityFixpointViolated() || openTripClosureDue() || provisionalOpenDue() {
            summaryHomePlacesUnreadable = false
            // Stage 2.5: Sanity check - catch obvious misclassifications
            let correctedCount = sanityCheckClassifications()
            guard correctedCount >= 0 else { throw CocoaError(.fileReadUnknown) }
            if correctedCount > 0 {
                lastPipelineMadeChanges = true
                logger.info("Sanity check corrected \(correctedCount) stay(s).")
            }

            // A trip a coverage edit marked only to spare it is automatic again
            // once nothing the user chose holds it, before assembly reads it.
            if releaseSparedTrips(pinnedTripIDs: pinnedTripIDs) > 0 {
                lastPipelineMadeChanges = true
            }

            // Stage 3: Assemble trips from all classified stays
            // Assembly's confidence gate is this unit's orbit reader: derive on
            // first read. A failed evidence read rolls the unit back.
            let anchors = try fetchRequiredAnchors()
            guard primeHomeOrbits(anchors: anchors) else { throw CocoaError(.fileReadUnknown) }
            newTrips = assembleTrips(pinnedTripIDs: pinnedTripIDs)
            guard newTrips >= 0 else { throw CocoaError(.fileReadUnknown) }
            if newTrips > 0 {
                lastPipelineMadeChanges = true
            }

            // Assembly never rebuilds user-edited open trips; heal only members reclassified this pass,
            // since even same-value setters dirty rows for CloudKit export. Pure sanity flips may not be in these ID sets.
            try healUserEditedOpenTripSummaries()

            // Stage 4: Safety net - close any trips that assembleTrips() rebuilt
            // but couldn't close (e.g., edge cases with timing of home stay detection).
            let closedCount = closeStaleOpenTrips()
            guard closedCount >= 0 else { throw CocoaError(.fileReadUnknown) }
            if closedCount > 0 {
                lastPipelineMadeChanges = true
                logger.info("Closed \(closedCount) stale open trip(s).")
            }

            // A managed summary built without its home-place filter would
            // persist home-named places under an armed latch; nothing
            // recomputes a completed trip's summary until its membership
            // changes, so the unit retries instead.
            guard !summaryHomePlacesUnreadable else { throw TripTitleStore.HomePlaceNamesUnreadable() }
            backHalfCompleted = !Task.isCancelled
        } else {
            logger.debug("Pipeline back half skipped — no upstream stay change and the stay↔trip invariant holds.")
        }

        // Explicit rebuild restores stable identities before its one checked
        // commit in finishGatedClassification. Never expose intermediate UUIDs.
        if completingRebuild {
            return (newTrips, modelContext.hasChanges || needsPublication, true, backHalfCompleted)
        }

        // One checked commit before Stage 5, which runs outside this unit and
        // must see the latest trip shape. A failure throws into the caller's
        // rollback, so no later unit commits or discards these repairs.
        needsPublication = modelContext.hasChanges || needsPublication
        try savePipelineResults()

        return (newTrips, needsPublication, true, backHalfCompleted)
    }

    /// Logs the hidden-photo lineages this unit's regroup retired before the
    /// commit that retires them, and puts the log back if the save fails.
    private func savePipelineResults() throws {
        let logged = logPendingHiddenLineages()
        do {
            #if DEBUG
            try SaveTestHook.beforeSave?()
            #endif
            try modelContext.save()
        } catch {
            logged.restore()
            throw error
        }
        acknowledgePendingHistoricalScan()
    }

    /// What `logPendingHiddenLineages` wrote, to put back after a failed save.
    struct LoggedHiddenLineages {
        let restore: () -> Void
    }

    /// Records the unit's pending hidden-photo lineages and splits, and the
    /// detached-member log its assembly left, ahead of its save, and empties
    /// them; `restore` puts every log back.
    func logPendingHiddenLineages() -> LoggedHiddenLineages {
        let lineages = pendingHiddenLineages
        let splits = pendingHiddenSplits
        let detached = pendingDetachedMembers
        let spared = pendingSparedTrips
        pendingHiddenLineages = []
        pendingHiddenSplits = []
        pendingDetachedMembers = nil
        pendingSparedTrips = nil
        let defaults = hiddenLineageDefaults
        let priorLineages = lineages.isEmpty ? nil : PhotoLineageStore.record(lineages, defaults: defaults)
        let priorSplits = splits.isEmpty ? nil : PhotoLineageStore.recordSplits(splits, defaults: defaults)
        let priorDetached = detached.map { PhotoLineageStore.writeDetachedMembers($0, defaults: defaults) }
        let priorSpared = spared.map { Self.writeSparedTrips($0, defaults: defaults) }
        return LoggedHiddenLineages {
            if !lineages.isEmpty { PhotoLineageStore.restore(priorLineages, defaults: defaults) }
            if !splits.isEmpty { PhotoLineageStore.restoreSplits(priorSplits, defaults: defaults) }
            if let priorDetached { PhotoLineageStore.restoreDetachedMembers(priorDetached, defaults: defaults) }
            if let priorSpared { Self.restoreSparedTrips(priorSpared, defaults: defaults) }
        }
    }
}
