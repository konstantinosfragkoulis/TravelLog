//
//  FlightLogAuthority.swift
//  TravelLog
//
//  A Flight Log row is a presentation, not permission to edit a UUID.
//  User actions re-read the physical journey inside their pipeline unit.
//

import Foundation
import SwiftData

nonisolated enum FlightLogAuthority {
    /// Both boundaries matter: a wipe revokes queued work before its unit
    /// reaches the gate, and snapshot revocation also invalidates retained UI.
    nonisolated struct Epoch: Sendable, Equatable {
        let pipeline: Int
        let snapshot: Int
    }

    static var currentEpoch: Epoch {
        Epoch(pipeline: PipelineGate.shared.revocationEpoch,
              snapshot: StatsSnapshotStore.clearGeneration)
    }

    /// Exact values consumed by the journey reduction. Physical identities
    /// distinguish UUID twins, including predecessor-only observations.
    nonisolated struct Node: Sendable, Equatable {
        let physicalIdentifier: PersistentIdentifier
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        let categoryRaw: String
        var modeRaw: String?
        let sourceRaw: String
        let sourceRaws: [String]
        let firstObservedAt: Date?
        let lastObservedAt: Date?
        let memberEvidenceComplete: Bool
        let pingCount: Int
        let isAirport: Bool
        let isHomeAtAirport: Bool
        let islandName: String?
        let metroName: String?
        let locality: String?
        let administrativeArea: String?
        let country: String?
        let isoCountryCode: String?
        let timeZoneIdentifier: String?
        let tripID: UUID?
        let tripIdentifier: PersistentIdentifier?

        init(endpoint: CollectionsAggregator.Endpoint, modeRaw: String?,
             tripID: UUID? = nil, tripIdentifier: PersistentIdentifier? = nil) {
            physicalIdentifier = endpoint.physicalIdentifier
            id = endpoint.id
            start = endpoint.startTime
            end = endpoint.endTime
            latitude = endpoint.centroidLatitude
            longitude = endpoint.centroidLongitude
            categoryRaw = endpoint.categoryRaw
            self.modeRaw = modeRaw
            sourceRaw = endpoint.sourceRaw
            sourceRaws = endpoint.sourceRaws.sorted()
            firstObservedAt = endpoint.firstObservedAt
            lastObservedAt = endpoint.lastObservedAt
            memberEvidenceComplete = endpoint.memberEvidenceComplete
            pingCount = endpoint.pingCount
            isAirport = endpoint.isAirport
            isHomeAtAirport = endpoint.isHomeAtAirport
            islandName = endpoint.islandName
            metroName = endpoint.metroName
            locality = endpoint.locality
            administrativeArea = endpoint.administrativeArea
            country = endpoint.country
            isoCountryCode = endpoint.isoCountryCode
            timeZoneIdentifier = endpoint.timeZoneIdentifier
            self.tripID = tripID
            self.tripIdentifier = tripIdentifier
        }
    }

    /// Transient, never decoded from the disk cache or a backup. Every member
    /// of the assessed journey participates, not just the arrival's times.
    nonisolated struct Witness: Sendable, Equatable {
        let targetIdentifier: PersistentIdentifier
        let nodes: [Node]
        let boundaryNodes: [Node]
        let topology: [Link]

        init(targetIdentifier: PersistentIdentifier, nodes: [Node], boundaryNodes: [Node] = [], topology: [Link] = []) {
            self.targetIdentifier = targetIdentifier
            self.nodes = nodes
            self.boundaryNodes = boundaryNodes
            self.topology = topology
        }

        /// The exact local inputs to the existing timeline algorithm: every
        /// represented node, its predecessor/successor, and all overlaps. Rows
        /// elsewhere cannot change its anchor, stray, conflict, or journey
        /// decision without first changing one of these links or values.
        static func capture(targetIdentifier: PersistentIdentifier, journeyIndices: [Int],
                            orderedNodes: [Node], previous: [Int?], next: [Int?]) -> Witness {
            let journey = Set(journeyIndices)
            var context = journey
            var links: [Link] = []
            let temporal = orderedNodes.map(TemporalNode.init)
            for index in journeyIndices {
                let overlaps = overlapIndices(of: index, in: temporal)
                if let earlier = previous[index] { context.insert(earlier) }
                if let later = next[index] { context.insert(later) }
                context.formUnion(overlaps)
                links.append(Link(physicalIdentifier: orderedNodes[index].physicalIdentifier,
                    previous: previous[index].map { orderedNodes[$0].physicalIdentifier },
                    next: next[index].map { orderedNodes[$0].physicalIdentifier },
                    overlaps: sortedIdentifiers(overlaps.map { orderedNodes[$0].physicalIdentifier })))
            }
            return Witness(targetIdentifier: targetIdentifier,
                nodes: journeyIndices.map { orderedNodes[$0] },
                boundaryNodes: context.subtracting(journey).sorted().map { orderedNodes[$0] },
                topology: links)
        }

        fileprivate func replacingTargetMode(_ mode: String?) -> Witness {
            Witness(targetIdentifier: targetIdentifier, nodes: nodes.map {
                var node = $0
                if node.physicalIdentifier == targetIdentifier { node.modeRaw = mode }
                return node
            }, boundaryNodes: boundaryNodes, topology: topology)
        }
    }

    nonisolated struct Link: Sendable, Equatable {
        let physicalIdentifier: PersistentIdentifier
        let previous: PersistentIdentifier?
        let next: PersistentIdentifier?
        let overlaps: [PersistentIdentifier]
    }

    private struct TemporalNode {
        let physicalIdentifier: PersistentIdentifier
        let id: UUID
        let start: Date
        let end: Date

        init(_ node: Node) {
            physicalIdentifier = node.physicalIdentifier
            id = node.id; start = node.start; end = node.end
        }

        init(_ stay: Stay) {
            physicalIdentifier = stay.persistentModelID
            id = stay.id; start = stay.startTime; end = stay.endTime
        }
    }

    nonisolated struct Target: Sendable, Equatable {
        let id: UUID
        let physicalIdentifier: PersistentIdentifier
        let witness: Witness
        let epoch: Epoch
        let annotations: Annotations?
        let distanceKm: Double
        let windowStart: Date?
        let windowEnd: Date
        let earliestDeparture: Date?
        let isCandidate: Bool

        /// Cache-only rows remain browsable while the authoritative refresh
        /// runs, but can never grant write authority to a replacement row.
        init?(record: CollectionsAggregator.FlightRecord, epoch: Epoch = currentEpoch) {
            guard let physicalIdentifier = record.arrivalIdentifier,
                  let witness = record.actionWitness,
                  witness.targetIdentifier == physicalIdentifier else { return nil }
            id = record.id
            self.physicalIdentifier = physicalIdentifier
            self.witness = witness
            self.epoch = epoch
            annotations = record.annotationSnapshot
            distanceKm = record.distanceKm
            windowStart = record.departureWindowStart
            windowEnd = record.date
            earliestDeparture = record.departureLastObservedAt
            isCandidate = false
        }

        init?(candidate: CollectionsAggregator.PossibleFlight, epoch: Epoch = currentEpoch) {
            guard let physicalIdentifier = candidate.arrivalIdentifier,
                  let witness = candidate.record.actionWitness,
                  witness.targetIdentifier == physicalIdentifier else { return nil }
            id = candidate.id
            self.physicalIdentifier = physicalIdentifier
            self.witness = witness
            self.epoch = epoch
            annotations = candidate.record.annotationSnapshot
            distanceKm = candidate.legKm ?? candidate.record.distanceKm
            windowStart = candidate.record.departureWindowStart
            windowEnd = candidate.record.date
            earliestDeparture = candidate.record.departureLastObservedAt
            isCandidate = true
        }

        fileprivate func replacingAnnotations(_ annotations: Annotations) -> Target {
            Target(copying: self, annotations: annotations)
        }

        private init(copying target: Target, annotations: Annotations?) {
            id = target.id; physicalIdentifier = target.physicalIdentifier
            witness = target.witness; epoch = target.epoch; self.annotations = annotations
            distanceKm = target.distanceKm; windowStart = target.windowStart
            windowEnd = target.windowEnd; earliestDeparture = target.earliestDeparture
            isCandidate = target.isCandidate
        }
    }

    /// The values the editor actually saw, including answers that no longer
    /// fit a changed observation window. Compare only the field being edited.
    nonisolated struct Annotations: Sendable, Equatable {
        let times: FlightTimeOverrides.Times?
        let stops: [String]?
    }

    nonisolated enum Action: Sendable {
        case confirm(times: FlightTimeOverrides.Times? = nil, clearTimes: Bool = false, stops: [String]? = nil)
        case markNotFlight
        case setTimes(FlightTimeOverrides.Times?)
        case setStops([String]?)
        case dismiss
        case undo(Receipt)
    }

    nonisolated enum Status: Sendable, Equatable {
        case committed
        case unchanged
        case rejected
        case failed
    }

    nonisolated struct Result: Sendable {
        let status: Status
        let receipt: Receipt?
        let updatedTarget: Target?
        var didCommit: Bool { status == .committed }
        var succeeded: Bool { status == .committed || status == .unchanged }

        fileprivate static func outcome(_ status: Status, receipt: Receipt? = nil, updatedTarget: Target? = nil) -> Result {
            Result(status: status, receipt: receipt, updatedTarget: updatedTarget)
        }
    }

    /// Undo is a compare-and-set of this action's own value. It never restores
    /// an entire preferences snapshot, and is invalid after either reset epoch.
    nonisolated struct Receipt: Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable { case notFlight, dismissal }
        let kind: Kind
        let target: Target
        fileprivate let expectedWitness: Witness
        fileprivate let expectedPreference: [String]?
        fileprivate let priorPreference: [String]?
    }

    /// A synchronous leaf called *inside* one PipelineGate unit. It never
    /// enqueues, awaits, or carries ModelContext/Stay across actor boundaries.
    /// Pending edits are preserved first; rollback touches only the new context.
    @MainActor
    static func apply(_ action: Action, target: Target, context pendingContext: ModelContext,
                      defaults: UserDefaults = .standard) -> Result {
        guard !Task.isCancelled, target.epoch == currentEpoch else { return .outcome(.rejected) }
        guard preserveUnrelatedPendingEdits(in: pendingContext) else { return .outcome(.failed) }
        guard target.epoch == currentEpoch else { return .outcome(.rejected) }

        let context = ModelContext(pendingContext.container)
        context.autosaveEnabled = false
        do {
            try checkpoint(.beforeRead)
            // No try? or missing-row fallback: every source read is required.
            var descriptor = FetchDescriptor<Stay>()
            descriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.categoryRaw, \.transitFromPreviousRaw]
            let stays = try context.fetch(descriptor).filter { !$0.isDeleted }
            guard let row = stays.first(where: { $0.persistentModelID == target.physicalIdentifier && $0.id == target.id })
            else { return .outcome(.rejected) }
            guard matchesTopology(target.witness, currentStays: stays) else { return .outcome(.rejected) }
            let contextIDs = Set((target.witness.nodes + target.witness.boundaryNodes).map(\.physicalIdentifier))
            // The scalar timeline is cheap even for a long history. Raw pings
            // and Visit provenance are read only for this captured local
            // context, never for every journey in the store.
            guard contextIDs.count <= 512 else { return .outcome(.rejected) }
            let prepared = try prepare(stays: stays.filter { contextIDs.contains($0.persistentModelID) }, context: context)
            let uniqueLogicalID = stays.count(where: { $0.id == target.id }) == 1

            if case .undo(let receipt) = action {
                return try undo(receipt, target: target, row: row, prepared: prepared,
                                uniqueLogicalID: uniqueLogicalID, context: context, defaults: defaults)
            }

            guard matches(target.witness, currentNodes: prepared.nodes),
                  target.epoch == currentEpoch else { return .outcome(.rejected) }

            switch action {
            case .confirm(let times, let clearTimes, let stops):
                // A Not a Flight correction is terminal. The exact context
                // checks above refuse a changed predecessor or journey.
                guard row.transitFromPreviousRaw != TransitMode.notFlight.rawValue,
                      target.isCandidate,
                      !hasDismissedCandidateMember(target, defaults: defaults),
                      !(clearTimes && times != nil) else { return .outcome(.rejected) }
                if (times != nil || clearTimes || stops != nil) && !uniqueLogicalID { return .outcome(.rejected) }
                if times != nil || clearTimes {
                    guard let annotations = target.annotations,
                          annotations.times == FlightTimeOverrides.times(for: target.id, defaults: defaults)
                    else { return .outcome(.rejected) }
                }
                if stops != nil {
                    guard let annotations = target.annotations,
                          annotations.stops == FlightStops.stops(for: target.id, defaults: defaults)
                    else { return .outcome(.rejected) }
                }
                let savedTimes: FlightTimeOverrides.Times?
                if let times {
                    guard let canonical = canonicalTimes(times, target: target) else { return .outcome(.rejected) }
                    savedTimes = canonical
                } else { savedTimes = nil }
                if let stops, !validStops(stops) { return .outcome(.rejected) }
                let distance = target.distanceKm
                guard distance.isFinite, distance >= 0 else { return .outcome(.rejected) }
                row.transitFromPreviousRaw = TransitMode.flight.rawValue
                row.distanceFromPreviousKm = distance
                try checkpoint(.beforeSave)
                guard target.epoch == currentEpoch else { context.rollback(); return .outcome(.rejected) }
                try context.save()
                // No suspension/prewrite exists between authority validation,
                // row save, and these answers. A failed save changes no prefs.
                if let savedTimes { FlightTimeOverrides.set(savedTimes, for: target.id, defaults: defaults) }
                else if clearTimes { FlightTimeOverrides.clear(target.id, defaults: defaults) }
                if let stops { FlightStops.set(stops, for: target.id, defaults: defaults) }
                return .outcome(.committed)

            case .markNotFlight:
                guard !target.isCandidate, row.transitFromPreviousRaw == TransitMode.flight.rawValue else { return .outcome(.rejected) }
                row.transitFromPreviousRaw = TransitMode.notFlight.rawValue
                try checkpoint(.beforeSave)
                guard target.epoch == currentEpoch else { context.rollback(); return .outcome(.rejected) }
                try context.save()
                return .outcome(.committed, receipt: Receipt(kind: .notFlight, target: target,
                    expectedWitness: target.witness.replacingTargetMode(TransitMode.notFlight.rawValue),
                    expectedPreference: nil, priorPreference: nil))

            case .setTimes(let times):
                guard !target.isCandidate, uniqueLogicalID, let annotations = target.annotations,
                      annotations.times == FlightTimeOverrides.times(for: target.id, defaults: defaults)
                else { return .outcome(.rejected) }
                let savedTimes: FlightTimeOverrides.Times?
                if let times {
                    guard let canonical = canonicalTimes(times, target: target) else { return .outcome(.rejected) }
                    savedTimes = canonical
                } else { savedTimes = nil }
                let advanced = target.replacingAnnotations(Annotations(times: savedTimes,
                    stops: annotations.stops))
                guard FlightTimeOverrides.times(for: target.id, defaults: defaults) != savedTimes else {
                    return .outcome(.unchanged, updatedTarget: advanced)
                }
                if let savedTimes { FlightTimeOverrides.set(savedTimes, for: target.id, defaults: defaults) }
                else { FlightTimeOverrides.clear(target.id, defaults: defaults) }
                return .outcome(.committed, updatedTarget: advanced)

            case .setStops(let stops):
                guard !target.isCandidate, uniqueLogicalID, let annotations = target.annotations,
                      annotations.stops == FlightStops.stops(for: target.id, defaults: defaults),
                      stops.map(validStops) ?? true else { return .outcome(.rejected) }
                let advanced = target.replacingAnnotations(Annotations(
                    times: annotations.times, stops: stops))
                guard FlightStops.stops(for: target.id, defaults: defaults) != stops else {
                    return .outcome(.unchanged, updatedTarget: advanced)
                }
                if let stops { FlightStops.set(stops, for: target.id, defaults: defaults) }
                else { FlightStops.clear(target.id, defaults: defaults) }
                return .outcome(.committed, updatedTarget: advanced)

            case .dismiss:
                guard target.isCandidate, uniqueLogicalID else { return .outcome(.rejected) }
                let before = preferenceEntries(for: target.id, key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                guard before?.isEmpty != false else { return .outcome(.unchanged) }
                replacePreferenceEntries([target.id.uuidString], for: target.id,
                                         key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                return .outcome(.committed, receipt: Receipt(kind: .dismissal, target: target,
                    expectedWitness: target.witness,
                    expectedPreference: [target.id.uuidString], priorPreference: before))

            case .undo: return .outcome(.rejected)
            }
        } catch {
            context.rollback()
            return .outcome(.failed)
        }
    }

    private struct Prepared {
        let nodes: [Node]
    }

    @MainActor
    private static func prepare(stays: [Stay], context: ModelContext) throws -> Prepared {
        let evidence = try FlightObservationBounds.fetch(stays: stays, in: context)
        var nodes: [Node] = []
        for stay in stays {
            let endpoint = CollectionsAggregator.Endpoint(stay, categoryRaw: stay.categoryRaw,
                                                          observationEvidence: evidence[stay.persistentModelID])
            if stay.categoryRaw == StayCategory.unclassified.rawValue,
               !CollectionsAggregator.hasTerminalFlightDecision(stay.transitFromPreviousRaw) {
                nodes.append(Node(endpoint: endpoint, modeRaw: nil))
            } else if [StayCategory.home.rawValue, StayCategory.routine.rawValue,
                       StayCategory.destination.rawValue, StayCategory.transit.rawValue,
                       StayCategory.unclassified.rawValue].contains(stay.categoryRaw) {
                let row = CollectionsAggregator.StayRow(stay, observationEvidence: evidence[stay.persistentModelID])
                nodes.append(Node(endpoint: endpoint, modeRaw: stay.transitFromPreviousRaw,
                                  tripID: row.tripID, tripIdentifier: stay.trip?.persistentModelID))
            }
        }
        return Prepared(nodes: nodes)
    }

    @MainActor
    private static func undo(_ receipt: Receipt, target: Target, row: Stay, prepared: Prepared,
                             uniqueLogicalID: Bool, context: ModelContext, defaults: UserDefaults) throws -> Result {
        guard receipt.target == target, target.epoch == currentEpoch,
              matches(receipt.expectedWitness, currentNodes: prepared.nodes) else { return .outcome(.rejected) }
        switch receipt.kind {
        case .notFlight:
            guard row.transitFromPreviousRaw == TransitMode.notFlight.rawValue else { return .outcome(.rejected) }
            row.transitFromPreviousRaw = TransitMode.flight.rawValue
            try checkpoint(.beforeSave)
            guard target.epoch == currentEpoch else { context.rollback(); return .outcome(.rejected) }
            try context.save()
            return .outcome(.committed)
        case .dismissal:
            guard uniqueLogicalID,
                  preferenceEntries(for: target.id, key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                    == receipt.expectedPreference else { return .outcome(.rejected) }
            replacePreferenceEntries(receipt.priorPreference, for: target.id,
                                     key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
            return .outcome(.committed)
        }
    }

    /// The scalar link check below has already established complete context.
    /// These required-read values must then match exactly; missing backing
    /// observations may invalidate authority, never strengthen it.
    static func matches(_ witness: Witness, currentNodes: [Node]) -> Bool {
        let captured = witness.nodes + witness.boundaryNodes
        guard !witness.nodes.isEmpty,
              Set(captured.map(\.physicalIdentifier)).count == captured.count,
              currentNodes.count == captured.count,
              Set(currentNodes.map(\.physicalIdentifier)).count == currentNodes.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.physicalIdentifier, $0) })
        return captured.allSatisfy { byID[$0.physicalIdentifier] == $0 }
    }

    /// `FlightJudge.Timeline` chooses temporal links before it reads geometry
    /// or airports. Reproduce only that inexpensive part over projected Stay
    /// scalars. This detects a new predecessor/waypoint/successor or overlap,
    /// including one that began before the captured journey's start. No full
    /// history ping/Visit scan or airport matching runs under the write gate.
    private static func matchesTopology(_ witness: Witness, currentStays: [Stay]) -> Bool {
        guard !witness.topology.isEmpty else { return false }
        let raw = currentStays.filter {
            StayCategory(rawValue: $0.categoryRaw) != nil
        }.map(TemporalNode.init)
        let ordered = raw.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            return $0.physicalIdentifier < $1.physicalIdentifier
        }
        let byEnd = ordered.indices.sorted {
            if ordered[$0].end != ordered[$1].end { return ordered[$0].end < ordered[$1].end }
            if ordered[$0].id != ordered[$1].id {
                return ordered[$0].id.uuidString < ordered[$1].id.uuidString
            }
            return $0 < $1
        }
        var previous = [Int?](repeating: nil, count: ordered.count)
        var next = previous
        for index in ordered.indices {
            var low = 0, high = byEnd.count
            while low < high {
                let middle = (low + high) / 2
                if ordered[byEnd[middle]].end < ordered[index].start { low = middle + 1 }
                else { high = middle }
            }
            var cursor = low - 1
            while cursor >= 0, ordered[byEnd[cursor]].id == ordered[index].id { cursor -= 1 }
            if cursor >= 0 { previous[index] = byEnd[cursor] }
            if let earlier = previous[index], next[earlier] == nil { next[earlier] = index }
        }
        let indices = Dictionary(uniqueKeysWithValues: ordered.indices.map { (ordered[$0].physicalIdentifier, $0) })
        return witness.topology.allSatisfy { link in
            guard let index = indices[link.physicalIdentifier] else { return false }
            return previous[index].map { ordered[$0].physicalIdentifier } == link.previous
                && next[index].map { ordered[$0].physicalIdentifier } == link.next
                && sortedIdentifiers(overlapIndices(of: index, in: ordered).map { ordered[$0].physicalIdentifier }) == link.overlaps
        }
    }

    private static func overlapIndices(of index: Int, in ordered: [TemporalNode]) -> [Int] {
        ordered.indices.filter { other in
            guard other != index else { return false }
            if other < index { return ordered[other].end > ordered[index].start }
            return ordered[index].end > ordered[other].start
        }
    }

    private static func sortedIdentifiers(_ identifiers: [PersistentIdentifier]) -> [PersistentIdentifier] {
        // Debug descriptions can be identical for distinct physical rows.
        // Canonicalize the actual identifiers so fetch order cannot alter a
        // witness's otherwise unchanged overlap set.
        identifiers.sorted()
    }

    /// The ledger stores whole seconds. Validate that exact value too, so
    /// rounding cannot move a valid draft beyond an observation-window edge
    /// or leave this editor expecting a value that was never persisted.
    private static func canonicalTimes(_ times: FlightTimeOverrides.Times, target: Target) -> FlightTimeOverrides.Times? {
        guard FlightTimeOverrides.fits(times, windowStart: target.windowStart,
                                      windowEnd: target.windowEnd, earliestDeparture: target.earliestDeparture),
              let departure = Int64(exactly: times.departure.timeIntervalSince1970.rounded()),
              let arrival = Int64(exactly: times.arrival.timeIntervalSince1970.rounded()) else { return nil }
        let canonical = FlightTimeOverrides.Times(
            departure: Date(timeIntervalSince1970: TimeInterval(departure)),
            arrival: Date(timeIntervalSince1970: TimeInterval(arrival)))
        guard FlightTimeOverrides.fits(canonical, windowStart: target.windowStart,
                                      windowEnd: target.windowEnd, earliestDeparture: target.earliestDeparture) else { return nil }
        return canonical
    }

    private static func hasDismissedCandidateMember(_ target: Target, defaults: UserDefaults) -> Bool {
        let dismissed = Set((defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        // Candidate witnesses contain the origin followed by the journey's
        // members. Match the projection: an origin-only dismissal does not
        // close this journey. An existing dismissal remains a negative veto
        // when physical twins arrive; it authorizes no positive row write.
        return target.witness.nodes.dropFirst().contains {
            dismissed.contains($0.id)
        }
    }

    private static func validStops(_ codes: [String]) -> Bool {
        codes.count <= FlightStops.maximumStops && Set(codes).count == codes.count
            && codes.allSatisfy(FlightStops.isCode)
            && codes.allSatisfy {
                guard let airport = AirportDetector.shared.airport(code: $0) else { return false }
                return airport.svc != false
            }
    }

    private static func preferenceEntries(for id: UUID, key: String, defaults: UserDefaults) -> [String]? {
        let entries = (defaults.stringArray(forKey: key) ?? []).filter {
            $0 == id.uuidString || $0.hasPrefix(id.uuidString + " ")
        }
        return entries.isEmpty ? nil : entries
    }

    private static func replacePreferenceEntries(_ entries: [String]?, for id: UUID,
                                                 key: String, defaults: UserDefaults) {
        var raw = (defaults.stringArray(forKey: key) ?? []).filter {
            $0 != id.uuidString && !$0.hasPrefix(id.uuidString + " ")
        }
        raw.append(contentsOf: entries ?? [])
        if raw.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(raw, forKey: key) }
    }

    nonisolated enum Checkpoint: Sendable { case beforeRead, beforeSave }

    @MainActor private static func checkpoint(_ point: Checkpoint) throws {
        #if DEBUG
        try failureForTesting?(point)
        #endif
    }

    #if DEBUG
    @TaskLocal private static var failureForTesting: (@MainActor @Sendable (Checkpoint) throws -> Void)?

    @MainActor
    static func withFailureForTesting<T>(_ failure: @escaping @MainActor @Sendable (Checkpoint) throws -> Void,
                                         operation: () throws -> T) rethrows -> T {
        try $failureForTesting.withValue(failure, operation: operation)
    }
    #endif
}
