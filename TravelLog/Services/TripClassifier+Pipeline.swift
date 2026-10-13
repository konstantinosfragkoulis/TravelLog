//
//  TripClassifier+Pipeline.swift
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

    struct ReclassificationTarget: Sendable {
        let identifier: PersistentIdentifier
        let members: Set<PersistentIdentifier>
    }

    /// Reset classifications but retain trip identities and links while the
    /// model runs. Orphan cleanup and other writers may run during inference.
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
        // Title budgets describe the pre-reset inputs; clear them only once
        // the reset is durable.
        clearAllPersistentTitleFailures()
        return targets
    }

    /// Called only inside the final assembly gate. A trip edited or replaced
    /// during inference is excluded from this explicit destructive rebuild.
    /// A failed read throws into the unit's rollback: it must never become a
    /// completed rebuild that replaced nothing.
    private func detachReclassificationTargets(_ targets: [ReclassificationTarget]) throws
        -> [(id: UUID, stayIDs: Set<UUID>, startDate: Date)] {
        guard !targets.isEmpty else { return [] }
        let byIdentifier = Dictionary(uniqueKeysWithValues: targets.map { ($0.identifier, $0.members) })
        #if DEBUG
        if failRebuildDetachFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let trips = try modelContext.fetch(FetchDescriptor<Trip>())
        var identities: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)] = []
        for trip in trips where !trip.isDeleted && !trip.userEdited {
            guard let members = byIdentifier[trip.persistentModelID],
                  members == Set((trip.stays ?? []).map(\.persistentModelID)) else { continue }
            let stayIDs = Set((trip.stays ?? []).map(\.id))
            if !stayIDs.isEmpty { identities.append((trip.id, stayIDs, trip.startDate)) }
            for stay in trip.stays ?? [] {
                stay.trip = nil
                stay.orderInTrip = nil
            }
            modelContext.delete(trip)
            lastPipelineMadeChanges = true
        }
        return identities
    }

    private func restoreReclassifiedIdentities(_ identitySnapshots: [(id: UUID, stayIDs: Set<UUID>, startDate: Date)]) throws {
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

    private struct ResolvedClassificationState: Sendable, Equatable {
        let identifier: PersistentIdentifier
        let evidence: [String]
    }

    private struct Stage2Work: Sendable {
        let ambiguous: [PersistentIdentifier]
        let plans: [ClassificationPlan]
        let evidence: [PersistentIdentifier: [String]]
        let places: [ClassificationPlaceRecord]
        let resolved: [ResolvedClassificationState]
        let outcomes: [ResolvedClassificationState]
        let fmAvailable: Bool
        let classified: Int
        let needsPublication: Bool
    }

    /// `completed` is true only when every unit of the pass committed: the
    /// preparation, each Stage 2 batch that was still current, and the final
    /// assembly (or rebuild replacement). Cancellation, a thermal stop, a
    /// failed required read or save, and a rolled-back unit report false.
    /// A batch discarded because its inputs changed is ordinary CAS work and
    /// does not clear `completed`; `plannedPending` reports separately that
    /// its planned stays remain unclassified after the committed finish unit.
    func runPipelineStagesWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = nil,
        gate: PipelineGate,
        rebuild: [ReclassificationTarget] = []
    ) async -> (created: Int, needsPublication: Bool, completed: Bool, plannedPending: Bool) {
        let work: Stage2Work? = await gate.runReturning(touching: []) {
            let prepared = await self.prepareGatedClassification(reclassifyRecentStays: reclassifyRecentStays,
                maxStaysPerCall: maxStaysPerCall)
            if prepared?.needsPublication != false { await StoreChangeTracker.shared.bump([.stay, .trip]) }
            return prepared
        }
        guard let work else { return (0, true, false, false) }
        var classified = work.classified
        var needsPublication = work.needsPublication
        var evidence = work.evidence
        var outcomeWitnesses = work.outcomes
        var fmProducedOutput = false
        var stage2Completed = true
        for plan in work.plans {
            guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical else {
                stage2Completed = false
                break
            }
            let expectedEvidence = Dictionary(uniqueKeysWithValues: plan.windows.flatMap(\.identifiers).compactMap { id in
                evidence[id].map { (id, $0) }
            })
            let prepared = await gate.runReturning(touching: []) {
                await self.prepareClassificationInput(plan: plan, evidence: expectedEvidence,
                    places: work.places)
            }
            let input: ClassificationInput
            switch prepared {
            case .ready(let ready): input = ready
            case .obsolete: continue
            case .unreadable:
                stage2Completed = false
                continue
            }
            let (hints, authority) = await classificationHints(for: input.calendarInputs)
            guard !Task.isCancelled else { break }
            guard authority?.isValid != false else { continue }
            let prompt = Self.classificationPrompt(input.prompt, ids: input.ids, hints: hints)
            var outputs: [StayClassificationInference.Classification] = []
            var viaFM = false
            do {
                let session = StayClassificationInference(instructions: Self.classificationInstructions(count: input.ids.count))
                outputs = try await session.respond(to: prompt)
                viaFM = true
                let coverage = Self.validateClassificationIndices(count: input.ids.count,
                    indices: outputs.map(\.stayIndex))
                if !coverage.missing.isEmpty, !Task.isCancelled, authority?.isValid != false,
                   let retry = try? await session.respond(to:
                    "You omitted indices \(coverage.missing.sorted().map(String.init).joined(separator: ", ")). Emit the complete corrected array again: exactly one classification for EVERY numbered stay index (0 through \(input.ids.count - 1)).") {
                    outputs += retry
                }
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                // A real model failure preserves the existing heuristic fallback.
            }
            guard !Task.isCancelled else { break }
            guard authority?.isValid != false else { continue }
            let classifications = outputs
            let modelAnswered = viaFM
            let applied = await gate.runReturning(touching: []) {
                let applied = await self.applyClassificationInput(input, outputs: classifications,
                    viaFM: modelAnswered, authority: authority)
                if applied.needsPublication { await StoreChangeTracker.shared.bump([.stay, .trip]) }
                return applied
            }
            classified += applied.classified
            needsPublication = needsPublication || applied.needsPublication
            stage2Completed = stage2Completed && applied.completed
            for witness in applied.outcomes { evidence[witness.identifier] = witness.evidence }
            outcomeWitnesses += applied.outcomes
            fmProducedOutput = fmProducedOutput || applied.fmProducedOutput
            if ProcessInfo.processInfo.thermalState == .serious {
                try? await Task.sleep(for: .seconds(2))
            }
            await Task.yield()
        }
        guard !Task.isCancelled else { return (0, needsPublication, false, false) }
        let total = classified
        let modelProducedOutput = fmProducedOutput
        let finalWitnesses = outcomeWitnesses
        let priorPublication = needsPublication
        let classificationCompleted = stage2Completed
        return await gate.runReturning(touching: []) {
            let finished = await self.finishGatedClassification(work: work, classified: total,
                fmProducedOutput: modelProducedOutput, rebuild: rebuild, outcomes: finalWitnesses)
            if finished.needsPublication { await StoreChangeTracker.shared.bump([.stay, .trip]) }
            return (finished.created, priorPublication || finished.needsPublication,
                classificationCompleted && finished.completed, finished.plannedPending)
        }
    }

    private func prepareGatedClassification(reclassifyRecentStays: Bool, maxStaysPerCall: Int?) async -> Stage2Work? {
        guard let prepared = await prepareClassificationStages(reclassifyRecentStays: reclassifyRecentStays) else {
            rollBackClassificationUnit()
            return nil
        }
        guard !Task.isCancelled else {
            return Stage2Work(ambiguous: [], plans: [], evidence: [:], places: [],
                resolved: [], outcomes: [], fmAvailable: false, classified: 0,
                needsPublication: prepared.needsPublication)
        }
        // A failed batch read is not an empty backlog.
        guard let batch = try? fetchStage2Batch(cap: maxStaysPerCall, priorityIDs: prepared.resetIDs) else {
            rollBackClassificationUnit()
            return nil
        }
        let deterministic = resolveDeterministicOutcomes(batch)
        let fmAvailable = StayClassificationInference.isAvailable
        var classified = deterministic.resolved.count
        do {
            // One timeline fetch and evidence construction per pass. Batches
            // retain only physical identities and bounded dependency windows.
            let ordered = try (batch.isEmpty ? [] : orderedClassificationStays(in: modelContext))
            // A stay of a user-edited trip is protected: input preparation
            // refuses it, so planning it would discard its whole plan on
            // every pass and leave the unprotected stays beside it pending.
            // One left unclassified (reset before a rename) takes the
            // heuristics, as the model lane never will; its twins join it.
            let edited = Set(deterministic.ambiguous.filter { $0.trip?.userEdited ?? false }.map(\.id))
            classified += classifyWithHeuristics(stays: fmAvailable
                ? deterministic.ambiguous.filter { edited.contains($0.id) } : deterministic.ambiguous,
                ordered: ordered)
            // Edited owners' summaries commit with their settled members (the
            // deterministic ones too, whose provenance registers only later): a
            // later failed unit resets the tracking, so no retry would heal them.
            summaryHomePlacesUnreadable = false
            try healUserEditedOpenTripSummaries(alsoChanged: Set(deterministic.resolved.map(\.id)))
            guard !summaryHomePlacesUnreadable else { throw TripTitleStore.HomePlaceNamesUnreadable() }
            let needsPublication = modelContext.hasChanges || prepared.needsPublication
            try savePipelineResults()
            let plannable = deterministic.ambiguous.filter { $0.category == .unclassified }
            let plans = plannable.isEmpty ? [] : classificationPlans(stays: plannable, ordered: ordered)
            // Only plan windows are validated against evidence.
            let needed = Set(plans.flatMap { $0.windows.flatMap(\.identifiers) })
            let witnessed = needed.isEmpty ? [] : ordered.filter { needed.contains($0.persistentModelID) }
            let evidence = Dictionary(uniqueKeysWithValues:
                zip(witnessed.map(\.persistentModelID), classificationEvidence(witnessed)))
            return Stage2Work(ambiguous: plannable.map(\.persistentModelID),
                plans: plans, evidence: evidence,
                places: try (plans.isEmpty ? [] : classificationPlaces(in: modelContext)),
                resolved: zip(deterministic.resolved, classificationEvidence(deterministic.resolved)).map {
                    ResolvedClassificationState(identifier: $0.0.persistentModelID, evidence: $0.1)
                }, outcomes: zip(batch, classificationEvidence(batch)).map {
                    ResolvedClassificationState(identifier: $0.0.persistentModelID, evidence: $0.1)
                }, fmAvailable: fmAvailable,
                classified: classified, needsPublication: needsPublication)
        } catch {
            rollBackClassificationUnit()
            return nil
        }
    }

    /// Discard a classifier unit's unsaved work. Pre-filter and stranded
    /// classification invalidate the home-place index after stamping `.home`,
    /// so a snapshot refilled from those rows must not outlive the rollback.
    private func rollBackClassificationUnit() {
        modelContext.rollback()
        TripTitleStore.invalidateHomePlaceIndex()
    }

    private struct CalendarClassificationInput: Sendable {
        let id: UUID
        let start: Date
        let end: Date
        let places: [String]
    }

    private struct ClassificationInput: Sendable {
        let identifiers: [PersistentIdentifier]
        let ids: [UUID]
        let prompt: String
        let plan: ClassificationPlan
        let evidence: [[String]]
        let placeEvidence: [ResolvedClassificationState]
        let placeDates: [Date]
        let calendarInputs: [CalendarClassificationInput]
    }

    /// Values include exact geometry/dates and ownership, beyond rounded prompt
    /// text. Comparing the ordered timeline detects inserted/deleted neighbours.
    private func classificationEvidence(_ stays: [Stay]) -> [[String]] {
        stays.map { stay in
            [String(describing: stay.persistentModelID), stay.id.uuidString,
             String(stay.startTime.timeIntervalSinceReferenceDate.bitPattern),
             String(stay.endTime.timeIntervalSinceReferenceDate.bitPattern),
             String(stay.durationMinutes), String(stay.centroidLatitude.bitPattern),
             String(stay.centroidLongitude.bitPattern), String(stay.distanceFromHomeKm.bitPattern),
             stay.categoryRaw, String(stay.isAirport), String(stay.userOverridden), stay.sourceRaw,
             stay.metroName ?? "", stay.islandName ?? "", stay.locality ?? "",
             stay.country ?? "", stay.administrativeArea ?? "", stay.isoCountryCode ?? "",
             stay.trip.map { String(describing: $0.persistentModelID) } ?? "",
             String(stay.trip?.userEdited ?? false)]
        }
    }

    private struct ClassificationPlaceRecord: Sendable {
        let identifier: PersistentIdentifier
        let id: UUID
        let kind: String
        let startedAt: Date?
        let endedAt: Date?
        let homeID: UUID?
        let temporalEvidence: [String]
        let evidence: [String]
    }

    /// Place tables are small and independently mutable. Capture their exact
    /// values once with the timeline; each batch compares only consumed geometry
    /// plus the temporal roster that selects applicable/fallback place eras.
    private func classificationPlaces(in context: ModelContext) throws -> [ClassificationPlaceRecord] {
        func date(_ value: Date?) -> String {
            value.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"
        }
        var rows: [ClassificationPlaceRecord] = []
        for home in try context.fetch(FetchDescriptor<Home>()) where !home.isDeleted {
            let temporal = ["home", home.id.uuidString, date(home.startedAt), date(home.endedAt)]
            rows.append(ClassificationPlaceRecord(identifier: home.persistentModelID, id: home.id,
                kind: "home", startedAt: home.startedAt, endedAt: home.endedAt, homeID: nil,
                temporalEvidence: temporal, evidence: temporal + [home.label,
                    String(home.latitude.bitPattern), String(home.longitude.bitPattern), String(home.radiusKm.bitPattern),
                    home.locality ?? "", home.administrativeArea ?? "", home.country ?? "", home.isoCountryCode ?? ""]))
        }
        for home in HomeAnchors.collapsingTwins(
            try context.fetch(FetchDescriptor<TemporaryHome>()).filter { !$0.isDeleted }) {
            let temporal = ["temporaryHome", home.id.uuidString, date(home.startedAt), date(home.endedAt)]
            rows.append(ClassificationPlaceRecord(identifier: home.persistentModelID, id: home.id,
                kind: "temporaryHome", startedAt: home.startedAt, endedAt: home.endedAt, homeID: nil,
                temporalEvidence: temporal, evidence: temporal + [home.label,
                    String(home.latitude.bitPattern), String(home.longitude.bitPattern), String(home.radiusKm.bitPattern),
                    home.locality ?? "", home.administrativeArea ?? "", home.country ?? "", home.isoCountryCode ?? ""]))
        }
        for place in try context.fetch(FetchDescriptor<RoutinePlace>()) where !place.isDeleted {
            let temporal = ["routine", place.id.uuidString, date(place.startedAt), date(place.endedAt), String(place.isActive)]
            rows.append(ClassificationPlaceRecord(identifier: place.persistentModelID, id: place.id,
                kind: "routine", startedAt: place.startedAt, endedAt: place.endedAt, homeID: nil,
                temporalEvidence: temporal, evidence: temporal + [place.label,
                    String(place.latitude.bitPattern), String(place.longitude.bitPattern), String(place.radiusMeters.bitPattern)]))
        }
        for row in try context.fetch(FetchDescriptor<HomeAreaOverride>()) where !row.isDeleted {
            let evidence = ["override", row.id.uuidString, row.kindRaw, row.homeID?.uuidString ?? "",
                String(row.centerLatitude.bitPattern), String(row.centerLongitude.bitPattern), String(row.radiusKm.bitPattern)]
            rows.append(ClassificationPlaceRecord(identifier: row.persistentModelID, id: row.id,
                kind: "override", startedAt: nil, endedAt: nil, homeID: row.homeID,
                temporalEvidence: [], evidence: evidence))
        }
        return rows.sorted { String(describing: $0.identifier) < String(describing: $1.identifier) }
    }

    private func classificationPlaceEvidence(_ places: [ClassificationPlaceRecord], for dates: [Date])
        -> [ResolvedClassificationState] {
        // Prehistory is a real-home rule: temporary homes neither define nor join it.
        let homes = places.filter { $0.kind == "home" }
        let prehistory = homes.contains { $0.endedAt == nil } && dates.contains { date in
            homes.allSatisfy { date < ($0.startedAt ?? .distantPast) }
        }
        func consumesGeometry(_ row: ClassificationPlaceRecord) -> Bool {
            // All current homes/routines are global prompt or fallback context.
            // A temporary home is neither: it counts only where its dates cover a batch date.
            (row.endedAt == nil && row.kind != "temporaryHome")
                || (row.kind == "home" && prehistory) || dates.contains {
                $0 >= (row.startedAt ?? .distantPast) && $0 <= (row.endedAt ?? .distantFuture)
            }
        }
        // Corrections are keyed to either kind of home.
        let homeIDs = Set(places.filter {
            ($0.kind == "home" || $0.kind == "temporaryHome") && consumesGeometry($0)
        }.map(\.id))
        return places.compactMap { row in
            if row.kind == "override" {
                guard row.homeID == nil || row.homeID.map({ homeIDs.contains($0) }) == true else { return nil }
                return ResolvedClassificationState(identifier: row.identifier, evidence: row.evidence)
            }
            return ResolvedClassificationState(identifier: row.identifier,
                evidence: consumesGeometry(row) ? row.evidence : row.temporalEvidence)
        }
    }

    func orderedClassificationStays(in context: ModelContext) throws -> [Stay] {
        #if DEBUG
        CalendarTestHook.timelineFetched?()
        #endif
        return try context.fetch(FetchDescriptor<Stay>()).filter { !$0.isDeleted }.sorted(by: Self.classificationOrder)
    }

    static func classificationOrder(_ lhs: Stay, _ rhs: Stay) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
    }

    // Same-UUID Stay twins are one logical stay for classification:
    // one numbered input and one set of neighbours per
    // UUID, and the decision is copied to every eligible physical copy.

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
    /// its own neighbour. A UUID in `batch` shows its batch representative. The
    /// order depends only on `ordered`, so plans, prompts and applies agree.
    static func logicalClassificationTimeline(_ ordered: [Stay], batch: [Stay]) -> [Stay] {
        let representatives = logicalClassificationRepresentatives(batch)
        var seen = Set<UUID>()
        return ordered.compactMap { stay in
            guard seen.insert(stay.id).inserted else { return nil }
            return representatives[stay.id] ?? stay
        }
    }

    private struct ClassificationWindow: Sendable {
        let lower: Date
        let upper: Date
        let identifiers: [PersistentIdentifier]
    }

    private struct ClassificationPlan: Sendable {
        let identifiers: [PersistentIdentifier]
        let windows: [ClassificationWindow]
    }

    private func classificationPlans(stays: [Stay], ordered: [Stay]) -> [ClassificationPlan] {
        // Windows are physical; the walk runs over logical stays and keeps
        // every physical copy of each one it visits.
        var physicalIndices: [UUID: [Int]] = [:]
        for (index, row) in ordered.enumerated() { physicalIndices[row.id, default: []].append(index) }
        let timeline = Self.logicalClassificationTimeline(ordered, batch: [])
        let logicalIndices = Dictionary(uniqueKeysWithValues: timeline.enumerated().map {
            ($0.element.id, $0.offset)
        })
        var dateRanges: [Date: ClosedRange<Int>] = [:]
        for (index, row) in ordered.enumerated() {
            dateRanges[row.startTime] = (dateRanges[row.startTime]?.lowerBound ?? index)...index
        }
        // One plan holds every copy of a UUID, so one decision covers them all.
        var cohorts: [[Stay]] = []
        var cohortIndex: [UUID: Int] = [:]
        for stay in stays {
            if let index = cohortIndex[stay.id] {
                cohorts[index].append(stay)
            } else {
                cohortIndex[stay.id] = cohorts.count
                cohorts.append([stay])
            }
        }
        return stride(from: 0, to: cohorts.count, by: maxBatchSize).map { offset in
            let batch = Array(cohorts[offset..<min(offset + maxBatchSize, cohorts.count)].joined())
            let representatives = Self.logicalClassificationRepresentatives(batch)
            func row(_ i: Int) -> Stay { representatives[timeline[i].id] ?? timeline[i] }
            var keep = Set<Int>()
            func keepLogical(_ i: Int) { keep.formUnion(physicalIndices[timeline[i].id] ?? []) }
            for stay in Self.logicalClassificationBatch(batch) {
                guard let index = logicalIndices[stay.id] else { continue }
                for i in max(0, index - promptContextSpan)...min(timeline.count - 1, index + promptContextSpan) {
                    keepLogical(i)
                }
                // Rule B can consume more than the rendered neighbours. Record
                // exactly its walk, including the boundary/first decisive row.
                if stay.durationMinutes < 90,
                   !CollectionsAggregator.intervalCrossesSolarHour(start: stay.startTime,
                        end: stay.endTime, longitude: stay.centroidLongitude, hour: 3) {
                    func boundary(_ i: Int) -> Bool {
                        !timeline.indices.contains(i) || row(i).category == .home || row(i).category == .routine
                    }
                    let atStart = boundary(index - 1)
                    if atStart != boundary(index + 1) {
                        let step = atStart ? 1 : -1
                        var i = index + step
                        for _ in 0..<60 {
                            guard timeline.indices.contains(i) else { break }
                            keepLogical(i)
                            if boundary(i) || row(i).distanceFromHomeKm > stay.distanceFromHomeKm + 30 { break }
                            i += step
                        }
                    }
                }
            }
            // Date predicates include ties; expand them before recording the
            // physical identities. A tie can admit a UUID copy whose first
            // copy lies outside, so close over both until nothing is added.
            var size = -1
            while size != keep.count {
                size = keep.count
                for date in Set(keep.map { ordered[$0].startTime }) {
                    if let range = dateRanges[date] { keep.formUnion(range) }
                }
                for id in Set(keep.map { ordered[$0].id }) {
                    keep.formUnion(physicalIndices[id] ?? [])
                }
            }
            var ranges: [ClosedRange<Int>] = []
            for i in keep.sorted() {
                if let last = ranges.last, last.upperBound + 1 == i {
                    ranges[ranges.count - 1] = last.lowerBound...i
                } else { ranges.append(i...i) }
            }
            return ClassificationPlan(identifiers: batch.map(\.persistentModelID), windows: ranges.map { range in
                ClassificationWindow(
                    lower: range.lowerBound == 0 ? .distantPast : ordered[range.lowerBound].startTime,
                    upper: range.upperBound == ordered.count - 1 ? .distantFuture : ordered[range.upperBound].startTime,
                    identifiers: range.map { ordered[$0].persistentModelID })
            })
        }
    }

    /// Range fetches detect inserted/deleted/moved neighbours without scanning
    /// unrelated history. Limit each fetch so an import cannot inflate a unit.
    private func classificationDependencies(_ plan: ClassificationPlan, in context: ModelContext) throws -> [Stay]? {
        var rows: [Stay] = []
        for window in plan.windows {
            let lower = window.lower
            let upper = window.upper
            var descriptor = FetchDescriptor<Stay>(predicate: #Predicate {
                $0.startTime >= lower && $0.startTime <= upper
            }, sortBy: [SortDescriptor(\.startTime)])
            descriptor.fetchLimit = window.identifiers.count + 1
            let fetched = try context.fetch(descriptor).filter { !$0.isDeleted }.sorted(by: Self.classificationOrder)
            guard fetched.map(\.persistentModelID) == window.identifiers else { return nil }
            rows += fetched
        }
        // Planning keeps every physical copy of each UUID the windows consume.
        // A copy arriving outside every window (a synced twin with its own
        // start) moves that logical stay and must share its decision, so the
        // cohorts are re-read; any extra or missing copy obsoletes the plan.
        let ids = Array(Set(rows.map(\.id)))
        guard !ids.isEmpty else { return rows }
        var cohortDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { ids.contains($0.id) })
        cohortDescriptor.fetchLimit = rows.count + 1
        let cohorts = try context.fetch(cohortDescriptor).filter { !$0.isDeleted }
        guard cohorts.count == rows.count,
              Set(cohorts.map(\.persistentModelID)) == Set(rows.map(\.persistentModelID)) else { return nil }
        return rows
    }

    /// A batch whose inputs changed is obsolete, which is ordinary CAS work;
    /// an unreadable dependency is not, and leaves the pass incomplete.
    private enum PreparedClassificationInput: Sendable {
        case ready(ClassificationInput)
        case obsolete
        case unreadable
    }

    private func prepareClassificationInput(plan: ClassificationPlan,
        evidence: [PersistentIdentifier: [String]], places: [ClassificationPlaceRecord]) -> PreparedClassificationInput {
        let context = ModelContext(modelContainer)
        let dependencies: [Stay]?
        let currentPlaces: [ClassificationPlaceRecord]
        do {
            dependencies = try classificationDependencies(plan, in: context)
            currentPlaces = try classificationPlaces(in: context)
        } catch {
            return .unreadable
        }
        guard let ordered = dependencies,
              classificationEvidence(ordered) == ordered.compactMap({ evidence[$0.persistentModelID] }) else { return .obsolete }
        let placeDates = ordered.map(\.startTime)
        let placeEvidence = classificationPlaceEvidence(places, for: placeDates)
        guard classificationPlaceEvidence(currentPlaces, for: placeDates) == placeEvidence else { return .obsolete }
        let byIdentifier = Dictionary(uniqueKeysWithValues: ordered.map { ($0.persistentModelID, $0) })
        let batch = plan.identifiers.compactMap { byIdentifier[$0] }
        guard batch.count == plan.identifiers.count, batch.allSatisfy({
            $0.category == .unclassified && !$0.userOverridden && !($0.trip?.userEdited ?? false)
        }) else { return .obsolete }
        // `ids` numbers the logical stays; `identifiers` keeps every physical row for the CAS.
        let logicalBatch = Self.logicalClassificationBatch(batch)
        return .ready(ClassificationInput(identifiers: batch.map(\.persistentModelID), ids: logicalBatch.map(\.id),
            prompt: buildPrompt(stays: batch, ordered: ordered, in: context), plan: plan,
            evidence: ordered.compactMap { evidence[$0.persistentModelID] }, placeEvidence: placeEvidence, placeDates: placeDates,
            calendarInputs: logicalBatch.filter { $0.source != .liveSLC }.map {
                CalendarClassificationInput(id: $0.id, start: $0.startTime, end: $0.endTime,
                    places: [$0.metroName, $0.islandName, $0.locality, $0.administrativeArea].compactMap { $0 })
            }))
    }

    #if DEBUG
    nonisolated enum CalendarTestHook {
        @TaskLocal static var hints: [UUID: String]?
        @TaskLocal static var authority: ForwardGeocoder.RequestAuthority?
        @TaskLocal static var timelineFetched: (@Sendable () -> Void)?
        @TaskLocal static var authorityRequested: (@Sendable () -> Void)?
        @TaskLocal static var finishStaysFetched: (@Sendable () -> Void)?
    }
    #endif

    private func classificationHints(for inputs: [CalendarClassificationInput]) async
        -> (hints: [UUID: String], authority: ForwardGeocoder.RequestAuthority?) {
        #if DEBUG
        if let supplied = CalendarTestHook.hints {
            let ids = Set(inputs.map(\.id))
            let hints = supplied.filter { ids.contains($0.key) }
            guard !hints.isEmpty else { return ([:], nil) }
            CalendarTestHook.authorityRequested?()
            return (hints, CalendarTestHook.authority)
        }
        #endif
        guard CalendarEnricher.hasReadAccess,
              let start = inputs.map(\.start).min(), let end = inputs.map(\.end).max() else { return ([:], nil) }
        func hints(from events: [CalendarEventSnapshot]) -> [UUID: String] {
            var hints: [UUID: String] = [:]
            for input in inputs {
                let overlapping = events.filter { $0.startDate < input.end && $0.endDate > input.start }
                if let candidate = CalendarTripNaming.bestCandidate(events: overlapping,
                    tripStart: input.start, tripEnd: input.end, tripPlaceNames: input.places) {
                    hints[input.id] = candidate
                }
            }
            return hints
        }
        let events = await AppDelegate.calendarEnricher.eventsOverlapping(start: start, end: end)
        guard !hints(from: events).isEmpty else { return ([:], nil) }
        let authority = await AppDelegate.calendarEnricher.classificationRequestAuthority()
        // The first fetch only discovers whether calendar evidence is useful.
        // Re-read under the captured authority so revocation between discovery
        // and capture cannot attach old event text to a new authority epoch.
        let currentEvents = await AppDelegate.calendarEnricher.eventsOverlapping(start: start, end: end)
        let currentHints = hints(from: currentEvents)
        return (currentHints, currentHints.isEmpty ? nil : authority)
    }

    nonisolated static func classificationPrompt(_ prompt: String,
        ids: [UUID], hints: [UUID: String]) -> String {
        prompt.components(separatedBy: "\n").map { line in
            for index in ids.indices where line.hasPrefix("[\(index)] ") {
                if let hint = hints[ids[index]] { return line + " | CALENDAR: \"\(hint.toLatinAsciiStrict)\"" }
            }
            return line
        }.joined(separator: "\n")
    }

    /// `completed` is false when the batch could not be read or saved; a
    /// batch discarded because its inputs changed (or cancelled) is not a failure.
    private func applyClassificationInput(_ input: ClassificationInput,
        outputs: [StayClassificationInference.Classification], viaFM: Bool,
        authority: ForwardGeocoder.RequestAuthority?) -> (classified: Int, fmProducedOutput: Bool, needsPublication: Bool,
            outcomes: [ResolvedClassificationState], completed: Bool) {
        guard !Task.isCancelled, authority?.isValid != false else { return (0, false, false, [], true) }
        let context = ModelContext(modelContainer)
        let dependencies: [Stay]?
        let places: [ClassificationPlaceRecord]
        do {
            dependencies = try classificationDependencies(input.plan, in: context)
            places = try classificationPlaces(in: context)
        } catch {
            return (0, false, false, [], false)
        }
        guard let ordered = dependencies,
              classificationEvidence(ordered) == input.evidence,
              classificationPlaceEvidence(places, for: input.placeDates) == input.placeEvidence else { return (0, false, false, [], true) }
        let byIdentifier = Dictionary(uniqueKeysWithValues: ordered.map { ($0.persistentModelID, $0) })
        let batch = input.identifiers.compactMap { byIdentifier[$0] }
        guard batch.count == input.identifiers.count,
              buildPrompt(stays: batch, ordered: ordered, in: context) == input.prompt else { return (0, false, false, [], true) }
        // Output index i is logical stay ids[i]; its decision reaches every eligible copy.
        let logicalBatch = Self.logicalClassificationBatch(batch)
        var seen = Set<Int>()
        var modelIDs = Set<UUID>()
        for output in outputs {
            let index = output.stayIndex
            guard logicalBatch.indices.contains(index), seen.insert(index).inserted else { continue }
            let id = logicalBatch[index].id
            for stay in batch where stay.id == id {
                guard !stay.userOverridden, stay.category == .unclassified else { continue }
                stay.category = StayCategory(rawValue: output.category) ?? .destination
                modelIDs.insert(stay.id)
            }
        }
        let oldHeuristicIDs = heuristicClassifiedStayIDs
        let fallbackCount = classifyWithHeuristics(stays: batch.filter { $0.category == .unclassified }, ordered: ordered, in: context)
        do {
            #if DEBUG
            try SaveTestHook.beforeSave?()
            #endif
            guard !Task.isCancelled, authority?.isValid != false else {
                context.rollback()
                heuristicClassifiedStayIDs = oldHeuristicIDs
                return (0, false, false, [], true)
            }
            try context.save()
            fmClassifiedStayIDs.formUnion(modelIDs)
            return (modelIDs.count + fallbackCount, viaFM && !modelIDs.isEmpty,
                !modelIDs.isEmpty || fallbackCount > 0,
                zip(batch, classificationEvidence(batch)).map {
                    ResolvedClassificationState(identifier: $0.0.persistentModelID, evidence: $0.1)
                }, true)
        } catch {
            context.rollback()
            heuristicClassifiedStayIDs = oldHeuristicIDs
            return (0, false, true, [], false)
        }
    }

    private func finishGatedClassification(work: Stage2Work, classified: Int,
        fmProducedOutput: Bool, rebuild: [ReclassificationTarget],
        outcomes: [ResolvedClassificationState]) async
        -> (created: Int, needsPublication: Bool, completed: Bool, plannedPending: Bool) {
        // Preparation was committed before inference. Discard registered old
        // values before assembly observes the fresh-context batch commits.
        modelContext.rollback()
        // Seeds only: orbits are derived where this unit first reads them
        // (stranded pre-filter, assembly), so a settled pass derives none.
        let shapesPrimed = await primeHomeShapes(seedsOnly: true)
        // A pass without outcomes or planned stays has nothing to credit or
        // strand; skip the full read. Nil records a failed read.
        var readStays: [Stay]? = []
        if !outcomes.isEmpty || !work.resolved.isEmpty || !work.ambiguous.isEmpty {
            #if DEBUG
            CalendarTestHook.finishStaysFetched?()
            #endif
            readStays = try? modelContext.fetch(FetchDescriptor<Stay>())
        }
        let currentStays = readStays ?? []
        // Earlier batches can be edited while a later model call is suspended.
        // Credit only classifications whose exact accepted output still exists.
        let accepted = Dictionary(outcomes.map { ($0.identifier, $0.evidence) },
            uniquingKeysWith: { _, latest in latest })
        let stillAcceptedIDs = Set(currentStays.filter {
            !$0.isDeleted && !$0.userOverridden && accepted[$0.persistentModelID] != nil
                && accepted[$0.persistentModelID] == classificationEvidence([$0]).first
        }.map(\.id))
        fmClassifiedStayIDs.formIntersection(stillAcceptedIDs)
        heuristicClassifiedStayIDs.formIntersection(stillAcceptedIDs)
        let witnesses = Dictionary(uniqueKeysWithValues: work.resolved.map { ($0.identifier, $0.evidence) })
        let resolved = currentStays.filter {
            !$0.isDeleted && !$0.userOverridden && witnesses[$0.persistentModelID] != nil
                && witnesses[$0.persistentModelID] == classificationEvidence([$0]).first
        }
        registerStage2aProvenance(resolved, asFM: Self.stage2aCreditsAsFM(
            fmAvailable: work.fmAvailable, hadAmbiguousStays: !work.ambiguous.isEmpty,
            fmLaneProducedOutput: fmProducedOutput && !fmClassifiedStayIDs.isEmpty))
        guard !Task.isCancelled else {
            return (0, work.needsPublication || lastPipelineMadeChanges || classified > 0, false, false)
        }
        do {
            let planned = Set(work.ambiguous)
            let strandedCount = try classifyStrandedStays(planned: planned,
                currentStays: readStays, shapesPrimed: shapesPrimed)
            // A discarded batch (inputs changed, calendar authority lost)
            // leaves unattached planned stays for the next pass. The unit
            // still commits; completion-stamping callers must not stamp.
            let plannedPending = !planned.isEmpty && (readStays ?? []).contains {
                !$0.isDeleted && $0.category == .unclassified && !$0.userOverridden
                    && planned.contains($0.persistentModelID) && !($0.trip?.userEdited ?? false)
            }
            let identities = try detachReclassificationTargets(rebuild)
            let result = try assembleClassificationResults(classified: classified + strandedCount,
                needsPublication: work.needsPublication || lastPipelineMadeChanges || classified > 0
                    || strandedCount > 0,
                completingRebuild: !rebuild.isEmpty)
            try restoreReclassifiedIdentities(identities)
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
            return (result.created, result.needsPublication, result.completed, plannedPending)
        } catch {
            rollBackClassificationUnit()
            hasRunBackHalfSinceLaunch = false
            logger.error("Classification unit rolled back: \(error.localizedDescription)")
            return (0, true, false, false)
        }
    }

    /// A skipped or rejected batch must not strand stays reset while attached:
    /// rebuild and ongoing-row reuse restore identity only through classified members.
    /// Coverage can change during inference, so these stays take the Stage 1 home and
    /// routine predicates on fresh reads before the heuristic fallback. A failed read
    /// throws, rolling the unit back with the stays still unclassified for a retry.
    /// A trip edited during inference rejected its batch and is never planned again,
    /// so its unclassified stays are settled here too.
    private func classifyStrandedStays(planned: Set<PersistentIdentifier>, currentStays: [Stay]?,
        shapesPrimed: Bool) throws -> Int {
        guard !planned.isEmpty else { return 0 }
        guard let currentStays else { throw CocoaError(.fileReadUnknown) }
        let stranded = currentStays.filter {
            !$0.isDeleted && $0.category == .unclassified && !$0.userOverridden
                && planned.contains($0.persistentModelID) && $0.trip != nil
        }
        guard !stranded.isEmpty else { return 0 }
        // First orbit read in this unit: derive against the current store first.
        let anchors = try fetchRequiredAnchors()
        guard shapesPrimed, primeHomeOrbits(anchors: anchors) else { throw CocoaError(.fileReadUnknown) }
        let covered = preFilterStays(stranded)
        guard covered >= 0 else { throw CocoaError(.fileReadUnknown) }
        if covered > 0 { TripTitleStore.invalidateHomePlaceIndex() }
        let timeline = currentStays.filter { !$0.isDeleted }.sorted(by: Self.classificationOrder)
        return covered + classifyWithHeuristics(stays: stranded, ordered: timeline)
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
    private func prepareClassificationStages(reclassifyRecentStays: Bool) async -> (resetIDs: [UUID], needsPublication: Bool)? {
        var needsPublication = false
        fmClassifiedStayIDs = []
        heuristicClassifiedStayIDs = []
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
        let preFilteredCount = judging ? preFilterStays() : 0
        guard preFilteredCount >= 0 else { return nil }
        if preFilteredCount > 0 {
            TripTitleStore.invalidateHomePlaceIndex()
            lastPipelineMadeChanges = true
            logger.info("Pre-filtered \(preFilteredCount) stay(s) as home/routine.")
        }

        guard !Task.isCancelled else {
            logger.info("Pipeline cancelled after pre-filtering.")
            needsPublication = modelContext.hasChanges || needsPublication
            // A failed save returns nil so the caller rolls the unit back.
            guard (try? savePipelineResults()) != nil else { return nil }
            return ([], needsPublication)
        }

        // Imports skip recent-stay reconsideration because historical backlog adds no current-journey context.
        // Stage 2 must include every stay reset here even when the per-call cap is reached.
        var resetStayIDs: [UUID] = []
        if reclassifyRecentStays {
            resetStayIDs = prepareForReclassification()
            if !resetStayIDs.isEmpty {
                lastPipelineMadeChanges = true
                logger.info("Prepared \(resetStayIDs.count) stay(s) for reclassification.")
            }
        } else {
            logger.debug("Skipping Stage 1.5 reclassification (post-import path).")
        }

        guard !Task.isCancelled else {
            logger.info("Pipeline cancelled after reclassification prep.")
            needsPublication = modelContext.hasChanges || needsPublication
            guard (try? savePipelineResults()) != nil else { return nil }
            return ([], needsPublication)
        }

        return (resetStayIDs, needsPublication)
    }

    /// Throws on a failed required read or save; the caller rolls the unit
    /// back. `backHalfCompleted` tells the caller to arm the launch latch
    /// once the unit's last commit lands; the rebuild commits in the caller.
    func assembleClassificationResults(classified: Int, needsPublication initialPublication: Bool,
        completingRebuild: Bool = false) throws
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
        if upstreamChanged || !hasRunBackHalfSinceLaunch || assemblyInvariantViolated()
            || sanityFixpointViolated() || openTripClosureDue() || provisionalOpenDue() {
            summaryHomePlacesUnreadable = false
            // Stage 2.5: Sanity check - catch obvious misclassifications
            let correctedCount = sanityCheckClassifications()
            guard correctedCount >= 0 else { throw CocoaError(.fileReadUnknown) }
            if correctedCount > 0 {
                lastPipelineMadeChanges = true
                logger.info("Sanity check corrected \(correctedCount) stay(s).")
            }

            // Stage 3: Assemble trips from all classified stays
            // Assembly's confidence gate is this unit's orbit reader: derive on
            // first read. A failed evidence read rolls the unit back.
            let anchors = try fetchRequiredAnchors()
            guard primeHomeOrbits(anchors: anchors) else { throw CocoaError(.fileReadUnknown) }
            newTrips = assembleTrips()
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

    private func savePipelineResults() throws {
        #if DEBUG
        try SaveTestHook.beforeSave?()
        #endif
        try modelContext.save()
    }
}
