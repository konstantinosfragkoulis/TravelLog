//
//  FlightLogAuthority.swift
//  TravelLog
//
//  A Flight Log row is a presentation, not permission to edit a UUID.
//  User actions re-check the tapped physical row inside their pipeline unit.
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

    /// What the fresh reduction that showed the row saw of it, of the
    /// stay the journey walk put immediately before it, and of the arrival
    /// the row named. Never decoded from the disk cache or a backup.
    nonisolated struct Guard: Sendable, Equatable {
        let target: PersistentIdentifier
        let id: UUID
        let start: Date
        let end: Date
        var modeRaw: String?
        let predecessor: PersistentIdentifier?
        let predecessorID: UUID?
        let predecessorEnd: Date?
        /// The stay the row named as its arrival, when a later one than
        /// `target`, and its start.
        var arrival: PersistentIdentifier? = nil
        var arrivalStart: Date? = nil
        /// The stays from `target` to the arrival (a candidate's: its whole
        /// journey after the origin). A dismissal of any of a candidate's
        /// closes the journey.
        let memberIDs: [UUID]
    }

    nonisolated struct Target: Sendable, Equatable {
        let id: UUID
        let physicalIdentifier: PersistentIdentifier
        private(set) var actionGuard: Guard
        let epoch: Epoch
        private(set) var annotations: Annotations?
        let distanceKm: Double
        let windowStart: Date?
        let windowEnd: Date
        let isCandidate: Bool

        /// Cache-only rows remain browsable while the fresh refresh runs, but
        /// never grant write authority to a replacement row.
        init?(record: CollectionsAggregator.FlightRecord, epoch: Epoch = currentEpoch) {
            self.init(record: record, distanceKm: record.distanceKm, isCandidate: false, epoch: epoch)
        }

        init?(candidate: CollectionsAggregator.PossibleFlight, epoch: Epoch = currentEpoch) {
            guard candidate.arrivalIdentifier == candidate.record.arrivalIdentifier else { return nil }
            // The leg as the data measured it, never the ends the user named.
            let measured = candidate.record.detectedRoute?.distanceKm ?? candidate.record.distanceKm
            self.init(record: candidate.record, distanceKm: candidate.legKm ?? measured,
                      isCandidate: true, epoch: epoch)
        }

        private init?(record: CollectionsAggregator.FlightRecord, distanceKm: Double,
                      isCandidate: Bool, epoch: Epoch) {
            guard let physicalIdentifier = record.arrivalIdentifier,
                  let actionGuard = record.actionGuard,
                  actionGuard.target == physicalIdentifier, actionGuard.id == record.id else { return nil }
            id = record.id
            self.physicalIdentifier = physicalIdentifier
            self.actionGuard = actionGuard
            self.epoch = epoch
            annotations = record.annotationSnapshot
            self.distanceKm = distanceKm
            windowStart = record.departureWindowStart
            windowEnd = record.date
            self.isCandidate = isCandidate
        }

        fileprivate func replacing(annotations: Annotations? = nil, modeRaw: String? = nil) -> Target {
            var copy = self
            if let annotations { copy.annotations = annotations }
            if let modeRaw { copy.actionGuard.modeRaw = modeRaw }
            return copy
        }
    }

    /// The values the editor actually saw. Compare only the field being edited.
    nonisolated struct Annotations: Sendable, Equatable {
        let times: FlightTimeOverrides.Times?
        let stops: [String]?
        var route: FlightRouteOverrides.Route? = nil
    }

    nonisolated enum Action: Sendable {
        case confirm(times: FlightTimeOverrides.Times? = nil, clearTimes: Bool = false, stops: [String]? = nil,
                     route: FlightRouteOverrides.Route? = nil)
        case markNotFlight
        case setTimes(FlightTimeOverrides.Times?)
        case setStops([String]?)
        /// An empty route goes back to the detected ends.
        case setRoute(FlightRouteOverrides.Route)
        case dismiss
        case undo(Receipt)
    }

    nonisolated enum Status: Sendable, Equatable {
        case committed, unchanged, rejected, failed
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

    /// Undo is a compare-and-set of this action's own value: it lands only
    /// while the row or preference still holds what the action wrote.
    nonisolated struct Receipt: Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable { case notFlight, dismissal }
        let kind: Kind
        let target: Target
        fileprivate let expectedPreference: [String]?
        fileprivate let priorPreference: [String]?
    }

    /// A synchronous leaf called *inside* one PipelineGate unit. It never
    /// enqueues, awaits, or carries ModelContext/Stay across actor boundaries.
    /// Pending edits are preserved first; rollback touches only the new context.
    @MainActor
    static func apply(_ action: Action, target shown: Target, context pendingContext: ModelContext,
                      defaults: UserDefaults = .standard) -> Result {
        // Undo checks what its own action wrote, for the row it wrote it to.
        var target = shown
        if case .undo(let receipt) = action {
            guard receipt.target.physicalIdentifier == shown.physicalIdentifier,
                  receipt.target.id == shown.id else { return .outcome(.rejected) }
            target = receipt.target
        }
        guard !Task.isCancelled, target.epoch == currentEpoch else { return .outcome(.rejected) }
        guard preserveUnrelatedPendingEdits(in: pendingContext) else { return .outcome(.failed) }
        let context = ModelContext(pendingContext.container)
        context.autosaveEnabled = false
        do {
            try checkpoint(.beforeRead)
            // Required reads: a failed fetch is a failure, never absence.
            let id = target.id
            guard let row = try fetchRow(target.physicalIdentifier, in: context), row.id == id
            else { return .outcome(.rejected) }
            // Answers keyed by a UUID several rows share would land on all.
            // `Stay.id` has no index: count only for an action that needs it.
            func uniqueLogicalID() throws -> Bool {
                try context.fetchCount(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })) == 1
            }

            if case .undo(let receipt) = action, receipt.kind == .dismissal {
                guard try uniqueLogicalID(),
                      preferenceEntries(for: id, key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                        == receipt.expectedPreference else { return .outcome(.rejected) }
                replacePreferenceEntries(receipt.priorPreference, for: id,
                                         key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                return .outcome(.committed)
            }
            guard try isCurrent(target.actionGuard, row: row, in: context) else { return .outcome(.rejected) }

            switch action {
            case .confirm(let times, let clearTimes, let stops, let route):
                guard target.isCandidate, !(clearTimes && times != nil),
                      !hasDismissedMember(target, defaults: defaults) else { return .outcome(.rejected) }
                if times != nil || clearTimes || stops != nil || route != nil {
                    guard try uniqueLogicalID(), let annotations = target.annotations else { return .outcome(.rejected) }
                    if (times != nil || clearTimes),
                       annotations.times != FlightTimeOverrides.times(for: id, defaults: defaults) {
                        return .outcome(.rejected)
                    }
                    if stops != nil, annotations.stops != FlightStops.stops(for: id, defaults: defaults) {
                        return .outcome(.rejected)
                    }
                    if route != nil, annotations.route != FlightRouteOverrides.route(for: id, defaults: defaults) {
                        return .outcome(.rejected)
                    }
                }
                let savedTimes = try times.map { try canonicalTimes($0, target: target) }
                if let stops, !validStops(stops) { return .outcome(.rejected) }
                if let route, !validRoute(route) { return .outcome(.rejected) }
                guard target.distanceKm.isFinite, target.distanceKm >= 0 else { return .outcome(.rejected) }
                row.transitFromPreviousRaw = TransitMode.flight.rawValue
                row.distanceFromPreviousKm = target.distanceKm
                try save(context, target: target)
                // Answers follow the committed row, so a failed save writes none.
                if let savedTimes { FlightTimeOverrides.set(savedTimes, for: id, defaults: defaults) }
                else if clearTimes { FlightTimeOverrides.clear(id, defaults: defaults) }
                if let stops { FlightStops.set(stops, for: id, defaults: defaults) }
                if let route { FlightRouteOverrides.set(route, for: id, defaults: defaults) }
                return .outcome(.committed)

            case .markNotFlight:
                guard !target.isCandidate, row.transitFromPreviousRaw == TransitMode.flight.rawValue
                else { return .outcome(.rejected) }
                row.transitFromPreviousRaw = TransitMode.notFlight.rawValue
                try save(context, target: target)
                return .outcome(.committed, receipt: Receipt(
                    kind: .notFlight, target: target.replacing(modeRaw: TransitMode.notFlight.rawValue),
                    expectedPreference: nil, priorPreference: nil))

            case .setTimes(let times):
                guard !target.isCandidate, try uniqueLogicalID(), let annotations = target.annotations,
                      annotations.times == FlightTimeOverrides.times(for: id, defaults: defaults)
                else { return .outcome(.rejected) }
                let savedTimes = try times.map { try canonicalTimes($0, target: target) }
                let advanced = target.replacing(annotations: Annotations(
                    times: savedTimes, stops: annotations.stops, route: annotations.route))
                guard annotations.times != savedTimes else { return .outcome(.unchanged, updatedTarget: advanced) }
                if let savedTimes { FlightTimeOverrides.set(savedTimes, for: id, defaults: defaults) }
                else { FlightTimeOverrides.clear(id, defaults: defaults) }
                return .outcome(.committed, updatedTarget: advanced)

            case .setStops(let stops):
                guard !target.isCandidate, try uniqueLogicalID(), let annotations = target.annotations,
                      annotations.stops == FlightStops.stops(for: id, defaults: defaults),
                      stops.map(validStops) ?? true else { return .outcome(.rejected) }
                let advanced = target.replacing(annotations: Annotations(
                    times: annotations.times, stops: stops, route: annotations.route))
                guard annotations.stops != stops else { return .outcome(.unchanged, updatedTarget: advanced) }
                if let stops { FlightStops.set(stops, for: id, defaults: defaults) }
                else { FlightStops.clear(id, defaults: defaults) }
                return .outcome(.committed, updatedTarget: advanced)

            case .setRoute(let route):
                guard !target.isCandidate, try uniqueLogicalID(), let annotations = target.annotations,
                      annotations.route == FlightRouteOverrides.route(for: id, defaults: defaults),
                      validRoute(route) else { return .outcome(.rejected) }
                // No entry and a reset are the same detected route.
                guard (annotations.route ?? FlightRouteOverrides.Route()) != route
                else { return .outcome(.unchanged, updatedTarget: target) }
                let advanced = target.replacing(annotations: Annotations(
                    times: annotations.times, stops: annotations.stops, route: route))
                FlightRouteOverrides.set(route, for: id, defaults: defaults)
                return .outcome(.committed, updatedTarget: advanced)

            case .dismiss:
                guard target.isCandidate, try uniqueLogicalID() else { return .outcome(.rejected) }
                let before = preferenceEntries(for: id, key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                guard before?.isEmpty != false else { return .outcome(.unchanged) }
                replacePreferenceEntries([id.uuidString], for: id,
                                         key: FlightCandidateDismissals.defaultsKey, defaults: defaults)
                return .outcome(.committed, receipt: Receipt(kind: .dismissal, target: target,
                    expectedPreference: [id.uuidString], priorPreference: before))

            case .undo(let receipt):
                // Not a Flight: the guard above required the row to still
                // hold the value this action wrote.
                guard receipt.kind == .notFlight else { return .outcome(.rejected) }
                row.transitFromPreviousRaw = TransitMode.flight.rawValue
                try save(context, target: target)
                return .outcome(.committed)
            }
        } catch Rejection.rejected {
            context.rollback()
            return .outcome(.rejected)
        } catch {
            context.rollback()
            return .outcome(.failed)
        }
    }

    private enum Rejection: Error { case rejected }

    /// One row by its store identity, a primary-key lookup; nil once it
    /// is gone.
    @MainActor
    private static func fetchRow(_ identifier: PersistentIdentifier, in context: ModelContext) throws -> Stay? {
        var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.persistentModelID == identifier })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first { !$0.isDeleted }
    }

    /// The tapped row still holds the captured values, the captured
    /// predecessor still ends where it did, no other stay now ends between
    /// them, and the arrival the row named still starts where it did with
    /// no new stay before it. A row that is that arrival may have grown its
    /// end (the phone is still recording there); any other change rejects.
    /// Primary-key lookups, plus `fetchLimit 1` probes (`Stay` has no index
    /// on its times, so each probe scans until it finds a row).
    @MainActor
    private static func isCurrent(_ captured: Guard, row: Stay, in context: ModelContext) throws -> Bool {
        let endHolds = captured.arrival == nil ? row.endTime >= captured.end : row.endTime == captured.end
        guard row.startTime == captured.start, endHolds,
              row.transitFromPreviousRaw == captured.modeRaw else { return false }
        let start = captured.start, targetID = captured.id
        let categories = StayCategory.allCases.map(\.rawValue)
        var floor = Date.distantPast
        if let predecessor = captured.predecessor, let predecessorEnd = captured.predecessorEnd {
            guard let stored = try fetchRow(predecessor, in: context), stored.id == captured.predecessorID,
                  stored.endTime == predecessorEnd else { return false }
            floor = predecessorEnd
        }
        let predecessorID = captured.predecessorID ?? targetID
        var later = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.endTime < start && $0.endTime > floor && $0.id != targetID && $0.id != predecessorID
                && categories.contains($0.categoryRaw)
        })
        later.fetchLimit = 1
        guard try context.fetch(later).allSatisfy(\.isDeleted) else { return false }
        guard let arrival = captured.arrival, let arrivalStart = captured.arrivalStart else { return true }
        guard let stored = try fetchRow(arrival, in: context), stored.startTime == arrivalStart else { return false }
        let members = captured.memberIDs
        var inserted = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.startTime > start && $0.startTime < arrivalStart && !members.contains($0.id)
                && categories.contains($0.categoryRaw)
        })
        inserted.fetchLimit = 1
        return try context.fetch(inserted).allSatisfy(\.isDeleted)
    }

    @MainActor
    private static func save(_ context: ModelContext, target: Target) throws {
        try checkpoint(.beforeSave)
        guard target.epoch == currentEpoch else { throw Rejection.rejected }
        try context.save()
    }

    /// The ledger stores whole seconds. Validate that exact value too, so
    /// rounding cannot move a valid draft beyond an observation-window edge.
    private static func canonicalTimes(_ times: FlightTimeOverrides.Times, target: Target) throws -> FlightTimeOverrides.Times {
        guard let departure = Int64(exactly: times.departure.timeIntervalSince1970.rounded()),
              let arrival = Int64(exactly: times.arrival.timeIntervalSince1970.rounded()) else { throw Rejection.rejected }
        let canonical = FlightTimeOverrides.Times(
            departure: Date(timeIntervalSince1970: TimeInterval(departure)),
            arrival: Date(timeIntervalSince1970: TimeInterval(arrival)))
        guard FlightTimeOverrides.fits(times, windowStart: target.windowStart, windowEnd: target.windowEnd),
              FlightTimeOverrides.fits(canonical, windowStart: target.windowStart, windowEnd: target.windowEnd)
        else { throw Rejection.rejected }
        return canonical
    }

    /// An existing dismissal stays a veto, even once UUID twins arrive.
    private static func hasDismissedMember(_ target: Target, defaults: UserDefaults) -> Bool {
        let dismissed = Set((defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
        return target.actionGuard.memberIDs.contains(where: dismissed.contains)
    }

    private static func validStops(_ codes: [String]) -> Bool {
        codes.count <= FlightStops.maximumStops && Set(codes).count == codes.count
            && codes.allSatisfy(FlightStops.isCode)
            && codes.allSatisfy {
                guard let airport = AirportDetector.shared.airport(code: $0) else { return false }
                return airport.svc != false
            }
    }

    private static func validRoute(_ route: FlightRouteOverrides.Route) -> Bool {
        let codes = [route.departure, route.arrival].compactMap { $0 }
        return Set(codes).count == codes.count
            && codes.allSatisfy {
                guard FlightStops.isCode($0), let airport = AirportDetector.shared.airport(code: $0)
                else { return false }
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
