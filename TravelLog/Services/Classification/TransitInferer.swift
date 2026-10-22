//
//  TransitInferer.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

/// Classifies each `Stay`'s inbound leg as `.flight` or `.unknown` with
/// `FlightJudge`: the stays around it are cut into journeys at real places
/// (anchors), and a journey is recorded a flight only when no car, train or
/// ferry could have covered it in the time the data leaves, or the phone was
/// seen in the air on the way, with a scheduled airport serving both ends.
/// The flight goes on the journey's first stay after its origin; a stay
/// that turns out to be a waypoint of an earlier stay's journey can upgrade
/// that stay's `.unknown` leg. The Flight Log's review queue reads the same
/// judge.
///
/// **No CoreMotion.** `CMMotionActivity` has no airplane or boat class, needs
/// the Motion & Fitness permission and exposes only a 7-day history, so it
/// cannot reach imported photos or motion-denied devices. The judge is
/// deterministic and runs for **every** stay regardless of permission or age;
/// ground sub-modes are not distinguished for NEW data — a non-flight leg is
/// recorded as `.unknown`. Legacy ground-mode values (`automotive`, `walking`,
/// …) on older stays, and any restored from a JSON import, are left untouched
/// and still render in Wrapped's transit breakdown.
@ModelActor
actor TransitInferer {

    #if DEBUG
    /// Task-local fault and timing seams, scoped per invocation across actor
    /// awaits and into gate units (unstructured tasks inherit task-locals).
    nonisolated enum TestScope {
        /// Thrown before the drain's save and before each re-pass apply save.
        @TaskLocal static var beforeSave: (@Sendable () throws -> Void)?
        /// Called before each required store read; throwing simulates a failed fetch.
        @TaskLocal static var readFault: (@Sendable (ReadSite) throws -> Void)?
        /// Awaited after a re-pass read phase, before each apply unit takes the gate.
        @TaskLocal static var beforeApply: (@Sendable () async -> Void)?
        /// Legacy test seam; Calendar text no longer grants recording authority.
        @TaskLocal static var corroborates: (@Sendable (Date, Date) -> Bool)?
        /// Replaces the Flight Log's dismissed-candidate set (host UserDefaults).
        @TaskLocal static var dismissedArrivals: Set<UUID>?
    }

    nonisolated enum ReadSite: Sendable, Equatable {
        case drainBatch, predecessor, unknownScan, unknownTies, applyTargets
    }

    func inferTransitForRecentStaysReportingChanges(
        beforeSave: @escaping @Sendable () throws -> Void
    ) async -> DrainOutcome {
        await TestScope.$beforeSave.withValue(beforeSave) {
            await inferTransitForRecentStaysReportingChanges()
        }
    }
    #endif

    private let logger = Logger(subsystem: "com.travellog.app", category: "TransitInferer")

    // Calendar booking text can describe cancelled plans, someone else's
    // flight, or an unrelated overlapping event. It is not evidence that the
    // user travelled. Only the geometry judge (or an explicit user decision
    // elsewhere) may write a flight; inference never queries EventKit.

    /// Legacy advisory bounds, retained for compatibility. Passing these
    /// checks says nothing about whether the user boarded and never grants
    /// authority to record a flight.
    nonisolated static let calendarMaxGapSeconds: TimeInterval = 48 * 60 * 60

    nonisolated static func calendarMayVouch(distanceKm: Double, gapSeconds: TimeInterval) -> Bool {
        distanceKm >= 100 && gapSeconds > 0 && gapSeconds <= calendarMaxGapSeconds
    }

    /// Text/overlap matching only. Inference deliberately does not call this:
    /// even a matched booking is not proof that the journey was a flight.
    nonisolated static func corroboratingFlightEvent(
        in events: [CalendarEventSnapshot], gapStart: Date, gapEnd: Date
    ) -> Bool {
        events.contains {
            $0.startDate < gapEnd && $0.endDate > gapStart
                && PlannedTripDetector.isFlightEvent($0)
        }
    }

    /// Stays whose candidate the user dismissed in the Flight Log. A
    /// dismissal says the journey holding that stay was not a flight, so no
    /// inference path may write `.flight` anywhere in it (upgrades are
    /// blocked, a re-inferred leg is written `.unknown`). Read per batch: the store
    /// is UserDefaults and device-local.
    nonisolated static func dismissedArrivals() -> Set<UUID> {
        #if DEBUG
        if let override = TestScope.dismissedArrivals { return override }
        #endif
        return FlightCandidateDismissals.all()
    }

    /// Portable UUID dismissals have no authority when the logical ID is
    /// shared by multiple physical rows, including twins outside this read's
    /// local neighbourhood. Re-read in every fresh apply context.
    private static func applicableDismissals(in context: ModelContext) throws -> Set<UUID> {
        let dismissed = dismissedArrivals()
        guard !dismissed.isEmpty else { return [] }
        var counts: [UUID: Int] = [:]
        let ids = Array(dismissed)
        for offset in stride(from: 0, to: ids.count, by: 512) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 512, ids.count)])
            var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { batch.contains($0.id) })
            descriptor.propertiesToFetch = [\.id]
            for row in try context.fetch(descriptor) where !row.isDeleted {
                counts[row.id, default: 0] += 1
            }
        }
        return Set(dismissed.filter { counts[$0] == 1 })
    }

    /// Max gap between the previous stay's end and this stay's start for the
    /// two to count as a continuous transit leg. Beyond this there is no
    /// meaningful "previous stay" — the prior recorded location is from a
    /// different journey after a dormancy / tracking gap — so we must NOT write
    /// a `distanceFromPreviousKm` (it would be a bogus cross-period great-circle
    /// such as Athens→Tokyo ~9000 km that inflates trip "total km" / Wrapped
    /// stats) and must NOT infer a transit mode.
    private static let transitMaxGapSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// The stays the judge reads around one: at most this many ending in
    /// the lookback before it, and starting with or after it within
    /// `forwardReachSeconds` (a journey walks at most
    /// `FlightJudge.maxMembers` stays, each followed by under
    /// `FlightJudge.anchorSilenceSeconds` of silence). Overlapping ones are
    /// read across the whole neighbourhood, at most `overlapReach` plus a
    /// sentinel: truncation explicitly disables automatic recording.
    private static let neighbourhoodReach = 64
    private static let overlapReach = 256
    private static let forwardReachSeconds: TimeInterval = 3 * 24 * 60 * 60

    // MARK: - Public

    /// Per-call cap for `inferTransitForRecentStays`. Internal so drain
    /// loops can detect a full batch (== the cap ⇒ probably more backlog)
    /// without duplicating the constant.
    nonisolated static let inferenceBatchSize = 50

    /// Outcome of one drain call. Counts are committed work only; `fetched`
    /// is fetch progress (a full batch means more backlog may remain).
    nonisolated struct DrainOutcome: Sendable {
        let fetched: Int
        /// Legs whose classification committed.
        let classified: Int
        /// Committed `.flight` classifications.
        let flights: Int
        /// Dirty save attempts stay publication-worthy even when the save
        /// failed (fail-open refresh when persistence could not be confirmed).
        let needsPublication: Bool
        /// A required read or the save failed and the unit rolled back. The
        /// same rows come back on the next call, so drain loops must stop.
        let failed: Bool
    }

    #if DEBUG
    /// Classify every stay whose inbound leg hasn't been classified yet
    /// (`transitFromPreviousRaw == nil`), oldest first, bounded per call.
    ///
    /// No permission gate and no recency window: every nil-transit stay is
    /// classified, a freshly imported flight included. Every fetched
    /// stay leaves a successful pass with a terminal value (`.flight` or
    /// `.unknown`), so it is never re-processed and the backlog drains a bounded
    /// `inferenceBatchSize` per call.
    ///
    /// Returns the number of stays fetched this call — `inferenceBatchSize`
    /// means the backlog may still have more (drain by calling again in a
    /// NEW gate unit; never loop inside one — gate starvation). Loops that
    /// must stop on failure use `inferTransitForRecentStaysReportingChanges`.
    @discardableResult
    func inferTransitForRecentStays() async -> Int {
        await inferTransitForRecentStaysReportingChanges().fetched
    }
    #endif

    /// Runs inside the caller's gate unit, on a fresh context. Registered
    /// values retained by the process-long actor cannot overrule another
    /// context's terminal user choice. Rollback discards only this unit.
    func inferTransitForRecentStaysReportingChanges() async -> DrainOutcome {
        // Defensive: commit anything the context already holds so a rollback
        // cannot discard it. A failed pre-save reports failure without
        // rolling back, and its dirty attempt stays publication-worthy.
        var needsPublication = modelContext.hasChanges
        guard preserveUnrelatedPendingEdits(in: modelContext) else {
            return DrainOutcome(fetched: 0, classified: 0, flights: 0,
                                needsPublication: true, failed: true)
        }
        // Fresh per gate unit: registered values on this process-long actor
        // must not overwrite a terminal decision saved by another context.
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<Stay> {
            $0.transitFromPreviousRaw == nil
        }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        descriptor.fetchLimit = Self.inferenceBatchSize

        let stays: [Stay]
        do {
            #if DEBUG
            try TestScope.readFault?(.drainBatch)
            #endif
            stays = try context.fetch(descriptor)
        } catch {
            logger.error("Transit inference fetch failed: \(error.localizedDescription)")
            return DrainOutcome(fetched: 0, classified: 0, flights: 0,
                                needsPublication: needsPublication, failed: true)
        }
        guard !stays.isEmpty else {
            return DrainOutcome(fetched: 0, classified: 0, flights: 0,
                                needsPublication: needsPublication, failed: false)
        }

        var inferred = 0
        var flights = 0
        do {
            let dismissed = try Self.applicableDismissals(in: context)
            for stay in stays {
                guard !Task.isCancelled else { break }
                flights += try await inferTransitForStay(stay, dismissed: dismissed, in: context)
                inferred += 1
            }
        } catch {
            // A failed predecessor read is not "no predecessor within 7
            // days": committing the terminal no-leg value would hide the leg
            // from every later drain. Leave the whole unit pending instead.
            context.rollback()
            logger.error("Transit inference read failed; batch left pending: \(error.localizedDescription)")
            return DrainOutcome(fetched: stays.count, classified: 0, flights: 0,
                                needsPublication: needsPublication, failed: true)
        }

        if inferred > 0 {
            needsPublication = context.hasChanges || needsPublication
            do {
                #if DEBUG
                try TestScope.beforeSave?()
                #endif
                try context.save()
            } catch {
                // Roll back so the rows re-enter the nil-transit fetch; left
                // dirty they matched no later drain and committed only if an
                // unrelated later save carried them along.
                context.rollback()
                logger.error("Transit inference save failed: \(error.localizedDescription)")
                return DrainOutcome(fetched: stays.count, classified: 0, flights: 0,
                                    needsPublication: needsPublication, failed: true)
            }
            logger.info("Transit inference: \(inferred) leg(s) classified (\(flights) flight(s)).")
        }
        return DrainOutcome(fetched: stays.count, classified: inferred, flights: flights,
                            needsPublication: needsPublication, failed: false)
    }

    /// The foreground drain's batch, with its evidence gathered outside the
    /// gate (the re-pass shape): one ungated read of the oldest nil-transit
    /// stays and their legs on a fresh context, the geometry decision on
    /// captured values, then short gated units that revalidate each leg
    /// against committed store state and write it. A leg another writer moved meanwhile
    /// stays nil and is evaluated again by a later batch. `publishing` bumps
    /// the store-change tracker inside each unit that attempted a save.
    /// Do NOT call this inside a gate unit: its own units would deadlock.
    func inferTransitBatchOutsideGate(gate: PipelineGate = .shared, publishing: Bool) async -> DrainOutcome {
        let pending: (fetched: Int, evaluated: [PendingLeg])
        do {
            pending = try await evaluatePendingLegs()
        } catch {
            logger.error("Transit inference read failed; batch left pending: \(error.localizedDescription)")
            return DrainOutcome(fetched: 0, classified: 0, flights: 0,
                                needsPublication: false, failed: true)
        }
        var classified = 0
        var flights = 0
        var needsPublication = false
        var start = 0
        while start < pending.evaluated.count {
            let end = min(start + Self.applySliceSize, pending.evaluated.count)
            let slice = Array(pending.evaluated[start..<end])
            start = end
            #if DEBUG
            await TestScope.beforeApply?()
            #endif
            let result = await gate.runReturning(touching: [.stay]) {
                let result = await self.applyPendingLegs(slice)
                if publishing, result.attemptedSave {
                    await StoreChangeTracker.shared.bump([.stay, .trip])
                }
                return result
            }
            classified += result.classified
            flights += result.flights
            needsPublication = needsPublication || result.attemptedSave
            if result.failed {
                return DrainOutcome(fetched: pending.fetched, classified: classified, flights: flights,
                                    needsPublication: needsPublication, failed: true)
            }
        }
        if classified > 0 {
            logger.info("Transit inference: \(classified) leg(s) classified (\(flights) flight(s)).")
        }
        return DrainOutcome(fetched: pending.fetched, classified: classified, flights: flights,
                            needsPublication: needsPublication, failed: false)
    }

    /// A nil-transit stay's inbound leg as the ungated read saw it, with the
    /// judge's decision on it. `legKm` nil: no predecessor within the
    /// lookback, so no leg (`.unknown`, no distance).
    private nonisolated struct PendingLeg: Sendable {
        let targetID: PersistentIdentifier
        let targetUUID: UUID
        let witness: JourneyWitness
        let legKm: Double?
        /// The row a flight goes on (the target, or its journey's first
        /// stay, an `.unknown` leg), nil when the leg stays `.unknown`.
        let flightID: PersistentIdentifier?
    }

    /// Ungated read and decision phase of `inferTransitBatchOutsideGate`.
    /// Throws on a failed read: a missing predecessor must be a read that
    /// happened. Every stay is judged as the earlier ones in the batch were
    /// decided. Cancellation stops before the next leg; what was decided
    /// still applies. Calendar text and overlap cannot promote a verdict.
    private func evaluatePendingLegs() async throws -> (fetched: Int, evaluated: [PendingLeg]) {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate<Stay> { $0.transitFromPreviousRaw == nil },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        descriptor.fetchLimit = Self.inferenceBatchSize
        #if DEBUG
        try TestScope.readFault?(.drainBatch)
        #endif
        let stays = try context.fetch(descriptor)
        let dismissed = try Self.applicableDismissals(in: context)
        var decided: [PersistentIdentifier: TransitMode] = [:]
        var evaluated: [PendingLeg] = []
        for stay in stays where !stay.isDeleted {
            guard !Task.isCancelled else { break }
            guard let hood = try neighbourhood(of: stay, in: context, decided: decided) else { continue }
            let recording = FlightJudge.recording(
                for: hood.index, in: hood.timeline, airports: .bundled, dismissed: dismissed)
            let target = recording.target.map { hood.rows[$0].persistentModelID }
            var flightID: PersistentIdentifier?
            if let target, case .record = recording.decision {
                flightID = target
                decided[target] = .flight
            }
            if decided[stay.persistentModelID] == nil { decided[stay.persistentModelID] = .unknown }
            evaluated.append(PendingLeg(
                targetID: stay.persistentModelID, targetUUID: stay.id,
                witness: Self.witness(hood, recording),
                legKm: Self.legKm(hood.index, in: hood.timeline),
                flightID: flightID))
        }
        return (stays.count, evaluated)
    }

    /// Gated apply half of `inferTransitBatchOutsideGate`, on a fresh
    /// context: the evaluated physical row must still be nil-transit (a
    /// concurrent writer's terminal value wins), and the journey the judge
    /// read must still be in the store as it was (`JourneyWitness`), with
    /// the same verdict. Drifted legs are skipped, not counted. Every flight
    /// must still have a recording verdict under the current geometry.
    private func applyPendingLegs(
        _ legs: [PendingLeg]
    ) -> (classified: Int, flights: Int, attemptedSave: Bool, failed: Bool) {
        let context = ModelContext(modelContainer)
        let ids = Array(Set(legs.map(\.targetUUID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        // Re-read: the user may have dismissed a candidate meanwhile.
        // A dirty save attempt stays publication-worthy even when it fails.
        var attemptedSave = false
        do {
            let dismissed = try Self.applicableDismissals(in: context)
            #if DEBUG
            try TestScope.readFault?(.applyTargets)
            #endif
            let fetched = try context.fetch(FetchDescriptor<Stay>(predicate: predicate))
            // Never fall back to a UUID twin: only the evaluated physical row.
            let rows = Dictionary(
                fetched.map { ($0.persistentModelID, $0) },
                uniquingKeysWith: { first, _ in first })
            var classified = 0
            var flights = 0
            for pending in legs {
                guard !Task.isCancelled else { break }
                guard let stay = rows[pending.targetID], !stay.isDeleted,
                      stay.transitFromPreviousRaw == nil,
                      let hood = try neighbourhood(of: stay, in: context) else { continue }
                let recording = FlightJudge.recording(
                    for: hood.index, in: hood.timeline, airports: .bundled, dismissed: dismissed)
                guard Self.witness(hood, recording) == pending.witness else { continue }
                var flightRow: (row: Stay, index: Int)?
                if let flightID = pending.flightID {
                    guard let target = recording.target,
                          hood.rows[target].persistentModelID == flightID else { continue }
                    guard case .record = recording.decision else { continue }
                    flightRow = (hood.rows[target], target)
                }
                stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
                stay.distanceFromPreviousKm = pending.legKm
                if let flightRow {
                    flightRow.row.transitFromPreviousRaw = TransitMode.flight.rawValue
                    flightRow.row.distanceFromPreviousKm = Self.legKm(flightRow.index, in: hood.timeline)
                    flights += 1
                }
                classified += 1
            }
            guard classified > 0 else { return (0, 0, false, false) }
            attemptedSave = true
            #if DEBUG
            try TestScope.beforeSave?()
            #endif
            try context.save()
            return (classified, flights, true, false)
        } catch {
            context.rollback()
            logger.error("Transit inference apply failed; legs left pending: \(error.localizedDescription)")
            return (0, 0, attemptedSave, true)
        }
    }

    /// Outcome of Settings "Detect Flights". Counts are committed work.
    nonisolated struct FlightDetectionOutcome: Sendable {
        /// Committed drain classifications.
        let analyzed: Int
        /// Committed flights across the drain and geometry re-pass.
        let found: Int
        /// A read or save failed and the run stopped there.
        let failed: Bool
        /// Every phase ran to exhaustion. False after a failure, cancellation
        /// or a runaway cap, so a zero count proves nothing.
        let complete: Bool
    }

    /// Settings "Detect Flights": drain the nil-transit backlog in bounded,
    /// separately gated batches so SLC writes interleave, then revisit
    /// terminal `.unknown` legs for airport-data changes under the current
    /// geometry judge. Every phase owns its own short gate units; do NOT wrap
    /// this call in `PipelineGate.run` (the non-reentrant gate would deadlock).
    func detectFlights(gate: PipelineGate = .shared) async -> FlightDetectionOutcome {
        var analyzed = 0
        var found = 0
        var drained = false
        var rounds = 0
        while rounds < 400, !Task.isCancelled { // 20k-leg runaway backstop
            rounds += 1
            let batch = await gate.runReturning(touching: [.stay]) {
                await self.inferTransitForRecentStaysReportingChanges()
            }
            analyzed += batch.classified
            found += batch.flights
            if batch.failed {
                return FlightDetectionOutcome(analyzed: analyzed, found: found,
                                              failed: true, complete: false)
            }
            if batch.fetched < Self.inferenceBatchSize {
                drained = true
                break
            }
        }
        guard drained else {
            return FlightDetectionOutcome(analyzed: analyzed, found: found,
                                          failed: false, complete: false)
        }
        let geometry = await reinferUnknownLegsGeometry(gate: gate)
        found += geometry.upgraded
        return FlightDetectionOutcome(analyzed: analyzed, found: found,
                                      failed: geometry.failed, complete: geometry.complete)
    }

    // MARK: - Core

    /// Writes `distanceFromPreviousKm` (the leg from the predecessor) and
    /// `.unknown` onto the stay, and `.flight` onto its journey's first stay
    /// when the geometry judge records the journey: the stay itself, or an
    /// earlier `.unknown` leg whose journey the stay turned out to extend.
    /// Returns the flights written. Every fetched nil-transit stay gets a
    /// value unless a read throws; the caller then rolls the unit back.
    ///
    /// A journey holding a stay in `dismissed` (the user dismissed it as a
    /// possible flight), a flight or the user's Not a Flight takes no new
    /// flight.
    private func inferTransitForStay(_ stay: Stay, dismissed: Set<UUID>, in context: ModelContext) async throws -> Int {
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        guard let hood = try neighbourhood(of: stay, in: context) else {
            stay.distanceFromPreviousKm = nil
            return 0
        }
        let timeline = hood.timeline
        stay.distanceFromPreviousKm = Self.legKm(hood.index, in: timeline)
        let recording = FlightJudge.recording(
            for: hood.index, in: timeline, airports: .bundled, dismissed: dismissed)
        guard let target = recording.target,
              case .record = recording.decision else { return 0 }
        let row = hood.rows[target]
        row.transitFromPreviousRaw = TransitMode.flight.rawValue
        row.distanceFromPreviousKm = Self.legKm(target, in: timeline)
        return 1
    }

    // MARK: - Resumable `.unknown`-leg scanning

    /// Position in the oldest-first `.unknown`-leg scan.
    ///
    /// Value type, caller-owned, deliberately NEVER persisted: a fresh button
    /// tap must re-scan from the beginning, because the store changed since
    /// last time.
    nonisolated struct UnknownLegCursor: Sendable {
        /// EXCLUSIVE lower bound on `Stay.startTime`; nil = start from oldest.
        ///
        /// Exclusivity is safe because each batch EXHAUSTS its boundary
        /// instant before stopping (see `unknownLegBatch`). `Stay.startTime`
        /// is not unique — JSON/GPX/Timeline imports mint co-timed stays — and
        /// SwiftData cannot sort on `id` (UUID is Hashable, not Comparable),
        /// so a cursor that stopped mid-instant would either skip the
        /// remaining siblings or have to carry tie bookkeeping that cannot
        /// make progress when one instant exceeds the batch size.
        let startTime: Date?

        static let start = UnknownLegCursor(startTime: nil)
    }

    nonisolated struct UnknownLegScanResult: Sendable {
        /// Legs whose `.flight` upgrade COMMITTED in this batch.
        let upgraded: Int
        /// Rows actually examined — the honest progress number.
        let scanned: Int
        /// nil means the backlog is exhausted (or, with `failed`, that the
        /// scan must stop). This, NOT `upgraded`, is the completion signal:
        /// a batch can scan hundreds and upgrade none.
        let next: UnknownLegCursor?
        /// A required read or an apply save failed. `upgraded` keeps only
        /// the apply slices that committed before it, and `next` is nil so
        /// no caller advances past the failure.
        let failed: Bool

        init(upgraded: Int, scanned: Int, next: UnknownLegCursor?, failed: Bool = false) {
            self.upgraded = upgraded
            self.scanned = scanned
            self.next = next
            self.failed = failed
        }
    }

    /// Outcome of a whole re-pass drain.
    nonisolated struct UnknownLegPassOutcome: Sendable {
        /// Committed upgrades, including batches before a failure.
        let upgraded: Int
        /// A read or save failed and the pass stopped there.
        let failed: Bool
        /// The scan reached the end of the backlog. False after a failure,
        /// cancellation or the runaway cap.
        let complete: Bool
    }

    nonisolated static let unknownLegScanBatchSize = 200

    /// Most candidates one apply gate unit revalidates. A co-timed tie
    /// cohort can push a scan batch well past `unknownLegScanBatchSize`.
    nonisolated static let applySliceSize = 50

    /// What the judge read of a journey: the chain's physical rows, origin
    /// first, and the values it took from each. An apply commits only
    /// while this still matches committed store state (same rows, same
    /// times, places, airports, modes), so a stay clustered into the gap,
    /// an edited interval, a moved centroid or a replaced row blocks it. A
    /// stay with nothing after it is still open: its growing end changes
    /// nothing the judge reads, so it is left out.
    private nonisolated struct JourneyWitness: Sendable, Equatable {
        let rows: [PersistentIdentifier]
        let values: [FlightJudge.Stay]
    }

    /// The journey (or, without one, the leg) into the neighbourhood's stay.
    private static func witness(_ hood: Neighbourhood, _ recording: FlightJudge.Recording) -> JourneyWitness {
        let timeline = hood.timeline
        let chain = recording.journey.map { [$0.origin] + $0.members }
            ?? ([timeline.previous[hood.index]].compactMap { $0 } + [hood.index])
        return JourneyWitness(
            rows: chain.map { hood.rows[$0].persistentModelID },
            values: chain.map { index in
                let stay = timeline.stays[index]
                guard timeline.next[index] == nil else { return stay }
                return FlightJudge.Stay(
                    id: stay.id, start: stay.start, end: .distantFuture,
                    latitude: stay.latitude, longitude: stay.longitude, isAirport: stay.isAirport,
                    islandName: stay.islandName, pingCount: stay.pingCount, isPhoto: stay.isPhoto,
                    mode: stay.mode, firstObservedAt: stay.firstObservedAt)
            })
    }

    /// A re-pass upgrade: the `.unknown` stay its journey's flight goes on,
    /// as the read that judged it saw it.
    private nonisolated struct JourneyLeg: Sendable {
        let targetID: PersistentIdentifier
        let targetUUID: UUID
        let witness: JourneyWitness
        let legKm: Double?
    }

    /// Fetch one batch of `.unknown` legs from `cursor`, and compute the next
    /// cursor. The geometry re-pass uses one shared keyset walk.
    /// Throws on a failed read: an empty result must mean an exhausted
    /// backlog, never a fetch that did not happen.
    private func unknownLegBatch(
        from cursor: UnknownLegCursor,
        batchSize: Int,
        in context: ModelContext
    ) throws -> (fresh: [Stay], next: UnknownLegCursor?) {
        let unknownRaw = TransitMode.unknown.rawValue
        let lower = cursor.startTime ?? .distantPast
        let predicate = #Predicate<Stay> {
            $0.transitFromPreviousRaw == unknownRaw && $0.startTime > lower
        }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )
        descriptor.fetchLimit = batchSize
        #if DEBUG
        try TestScope.readFault?(.unknownScan)
        #endif
        var rows = try context.fetch(descriptor)
        guard !rows.isEmpty else { return ([], nil) }

        // A short batch means the backlog is exhausted. This — NOT the number
        // of upgrades — is the completion signal: a batch can scan hundreds of
        // legs and upgrade none, which is exactly why a plain `fetchLimit`
        // plus "stop when a batch upgrades nothing" loop truncates the scan.
        guard rows.count >= batchSize else { return (rows, nil) }

        // Exhaust the boundary instant so the next cursor can be strictly
        // exclusive. Without this the batch could stop mid-instant, and any
        // scheme that resumes AT that instant either re-scans it forever or
        // (if it steps past) silently drops the siblings the limit cut off.
        let boundary = rows[rows.count - 1].startTime
        let tiePredicate = #Predicate<Stay> {
            $0.transitFromPreviousRaw == unknownRaw && $0.startTime == boundary
        }
        #if DEBUG
        try TestScope.readFault?(.unknownTies)
        #endif
        let ties = try context.fetch(FetchDescriptor<Stay>(predicate: tiePredicate))
        // Physical identity, not UUID: CloudKit twins share a UUID but are
        // distinct rows, and each one is its own leg to examine.
        let known = Set(rows.map(\.persistentModelID))
        rows.append(contentsOf: ties.filter { !known.contains($0.persistentModelID) })

        return (rows, UnknownLegCursor(startTime: boundary))
    }

    /// Retired Calendar backfill entry point, retained for older callers.
    /// Booked events cannot prove that the user travelled, so this performs
    /// no reads or writes. Detect Flights owns the geometry-only re-pass.
    @discardableResult
    func recorroborateUnknownLegs(gate: PipelineGate = .shared) async -> UnknownLegPassOutcome {
        UnknownLegPassOutcome(upgraded: 0, failed: false, complete: true)
    }

    /// Bounded counterpart of the compatibility entry point above.
    func recorroborateUnknownLegsBatch(
        from cursor: UnknownLegCursor = .start,
        batchSize: Int = TransitInferer.unknownLegScanBatchSize,
        gate: PipelineGate = .shared
    ) async -> UnknownLegScanResult {
        UnknownLegScanResult(upgraded: 0, scanned: 0, next: nil)
    }

    /// Runs the apply in bounded gate units, one after another (never
    /// nested). Every slice runs before the caller advances its cursor, and
    /// the count keeps slices that committed before a failed one.
    private func applyInSlices(
        _ legs: [JourneyLeg],
        gate: PipelineGate
    ) async -> (upgraded: Int, failed: Bool) {
        var upgraded = 0
        var start = 0
        while start < legs.count {
            let end = min(start + Self.applySliceSize, legs.count)
            let slice = Array(legs[start..<end])
            start = end
            #if DEBUG
            await TestScope.beforeApply?()
            #endif
            let result = await gate.runReturning(touching: [.stay]) {
                await self.applyFlightUpgrades(slice)
            }
            upgraded += result.upgraded
            if result.failed { return (upgraded, true) }
        }
        return (upgraded, false)
    }

    /// Gated apply half of the geometry re-pass. Revalidates every candidate
    /// against committed store state before upgrading (inference results
    /// apply only after dependency validation): the evaluated physical row
    /// must still be `.unknown` (a concurrent pass that wrote a terminal
    /// value wins), the journey must still be the one the judge read
    /// (`JourneyWitness`) with the stay as its flight's place, and a
    /// geometry upgrade must still be recorded. Drifted legs are skipped,
    /// not counted; the next run re-evaluates them. The write stores the
    /// leg distance as well as `.flight` (the `applyConfirmedFlight`
    /// unconditional-overwrite rule), replacing a stored km that went stale
    /// against an older predecessor.
    ///
    /// A fresh context: rows registered in a long-lived context keep the
    /// values they were first fetched with, so revalidating there could
    /// miss drift another context saved. Only reads and the judge's
    /// arithmetic happen here.
    private func applyFlightUpgrades(
        _ legs: [JourneyLeg]
    ) -> (upgraded: Int, failed: Bool) {
        guard !Task.isCancelled else { return (0, false) }
        let context = ModelContext(modelContainer)
        let unknownRaw = TransitMode.unknown.rawValue
        let ids = Array(Set(legs.map(\.targetUUID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        // Re-read: the user may have dismissed the candidate while the
        // ungated phase ran.
        do {
            let dismissed = try Self.applicableDismissals(in: context)
            #if DEBUG
            try TestScope.readFault?(.applyTargets)
            #endif
            let fetched = try context.fetch(FetchDescriptor<Stay>(predicate: predicate))
            // Never fall back to a UUID twin: only the evaluated physical row.
            let rows = Dictionary(
                fetched.map { ($0.persistentModelID, $0) },
                uniquingKeysWith: { first, _ in first })
            var upgraded = 0
            for leg in legs where !dismissed.contains(leg.targetUUID) {
                guard let stay = rows[leg.targetID], !stay.isDeleted,
                      stay.transitFromPreviousRaw == unknownRaw,
                      let hood = try neighbourhood(of: stay, in: context) else { continue }
                let recording = FlightJudge.recording(
                    for: hood.index, in: hood.timeline, airports: .bundled, dismissed: dismissed)
                guard recording.target == hood.index,
                      Self.witness(hood, recording) == leg.witness else { continue }
                guard case .record = recording.decision else { continue }
                stay.transitFromPreviousRaw = TransitMode.flight.rawValue
                stay.distanceFromPreviousKm = Self.legKm(hood.index, in: hood.timeline)
                upgraded += 1
            }
            guard upgraded > 0 else { return (0, false) }
            #if DEBUG
            try TestScope.beforeSave?()
            #endif
            try context.save()
            logger.info("Flight re-pass upgraded \(upgraded) leg(s) to .flight.")
            return (upgraded, false)
        } catch {
            context.rollback()
            logger.error("Flight re-pass apply failed: \(error.localizedDescription)")
            return (0, true)
        }
    }

    /// Settings "Detect Flights": geometry re-pass over `.unknown` legs.
    /// `.unknown` is terminal, so when the bundled airport dataset expands
    /// to include scheduled small fields, such as island airports, or the
    /// judge's rules change, journeys the older rule or data rejected must
    /// be revisited explicitly. A leg
    /// whose candidate the user dismissed in the Flight Log is skipped.
    /// This deliberate exception to terminal transit values is user-invoked,
    /// upgrade-only (`.unknown` →
    /// `.flight`), never touches ground modes or existing flights, idempotent.
    ///
    /// Gate discipline: the expensive
    /// read/judge phase — the batch fetch plus a per-leg neighbourhood
    /// fetch and AirportDetector lookups — runs UNGATED;
    /// only the revalidating apply takes short gate units, so a large
    /// `.unknown` backlog can never starve a background SLC save.
    /// Do NOT wrap calls in `PipelineGate.run` — the nested unit would
    /// deadlock.
    /// Drain wrapper: batches until the backlog is exhausted,
    /// stopping at the first failed batch with the counts committed before it.
    @discardableResult
    func reinferUnknownLegsGeometry(gate: PipelineGate = .shared) async -> UnknownLegPassOutcome {
        var cursor: UnknownLegCursor? = .start
        var total = 0
        var rounds = 0
        while let current = cursor, rounds < 400, !Task.isCancelled {
            rounds += 1
            let result = await reinferUnknownLegsGeometryBatch(from: current, gate: gate)
            total += result.upgraded
            if result.failed {
                return UnknownLegPassOutcome(upgraded: total, failed: true, complete: false)
            }
            cursor = result.next
        }
        return UnknownLegPassOutcome(upgraded: total, failed: false,
                                     complete: cursor == nil && !Task.isCancelled)
    }

    /// One bounded batch of the geometry re-pass.
    func reinferUnknownLegsGeometryBatch(
        from cursor: UnknownLegCursor = .start,
        batchSize: Int = TransitInferer.unknownLegScanBatchSize,
        gate: PipelineGate = .shared
    ) async -> UnknownLegScanResult {
        let scan: (scanned: Int, next: UnknownLegCursor?, legs: [JourneyLeg])
        do {
            scan = try geometryCandidateLegs(from: cursor, batchSize: batchSize)
        } catch {
            logger.error("Geometry re-pass read failed: \(error.localizedDescription)")
            return UnknownLegScanResult(upgraded: 0, scanned: 0, next: nil, failed: true)
        }
        guard !scan.legs.isEmpty else {
            return UnknownLegScanResult(upgraded: 0, scanned: scan.scanned, next: scan.next)
        }

        let applied = await applyInSlices(scan.legs, gate: gate)
        return UnknownLegScanResult(
            upgraded: applied.upgraded, scanned: scan.scanned,
            next: applied.failed ? nil : scan.next, failed: applied.failed)
    }

    /// Ungated read and inference phase of the geometry re-pass.
    ///
    /// No stored-distance prefilter: the
    /// stored value goes stale when imports insert stays into the gap. Every
    /// `.unknown` leg is admitted and judged from the CURRENT timeline
    /// around it (same rationale as the Flight Log); a stay is upgraded only
    /// as its journey's first stay, the place the journey's flight goes. A
    /// fresh context per batch reads committed store state.
    private func geometryCandidateLegs(
        from cursor: UnknownLegCursor,
        batchSize: Int
    ) throws -> (scanned: Int, next: UnknownLegCursor?, legs: [JourneyLeg]) {
        let context = ModelContext(modelContainer)
        let batch = try unknownLegBatch(from: cursor, batchSize: batchSize, in: context)
        // A dismissed candidate is the user's word that the journey was not
        // a flight: rules that grew more permissive since must not overrule it.
        let dismissed = try Self.applicableDismissals(in: context)
        var legs: [JourneyLeg] = []
        for stay in batch.fresh where !dismissed.contains(stay.id) {
            guard !Task.isCancelled else { break }
            guard let leg = try journeyLeg(for: stay, in: context, dismissed: dismissed),
                  case .record = leg.decision else { continue }
            legs.append(leg.leg)
        }
        return (batch.fresh.count, batch.next, legs)
    }

    /// The journey `stay` is the first stay of, as a re-pass reads it; nil
    /// when the stay is not its journey's first or the journey may not take
    /// a flight.
    private func journeyLeg(
        for stay: Stay, in context: ModelContext, dismissed: Set<UUID>
    ) throws -> (leg: JourneyLeg, decision: FlightJudge.Decision)? {
        guard let hood = try neighbourhood(of: stay, in: context) else { return nil }
        let timeline = hood.timeline
        let recording = FlightJudge.recording(
            for: hood.index, in: timeline, airports: .bundled, dismissed: dismissed)
        guard recording.target == hood.index else { return nil }
        let leg = JourneyLeg(
            targetID: stay.persistentModelID, targetUUID: stay.id,
            witness: Self.witness(hood, recording),
            legKm: Self.legKm(hood.index, in: timeline))
        return (leg, recording.decision)
    }

    // MARK: - Journeys

    /// The stays around one stay, as `FlightJudge` reads them.
    private struct Neighbourhood {
        /// Aligned with `timeline.stays`.
        let rows: [Stay]
        let timeline: FlightJudge.Timeline
        /// The stay's own position.
        let index: Int
    }

    /// The stays the judge reads around `stay` (see `neighbourhoodReach`),
    /// with the modes `decided` holds in place of stored ones; nil when the
    /// stay is gone. Throws on a failed read: a missing predecessor must be
    /// a read that happened.
    private func neighbourhood(
        of stay: Stay, in context: ModelContext, decided: [PersistentIdentifier: TransitMode] = [:]
    ) throws -> Neighbourhood? {
        guard !stay.isDeleted else { return nil }
        let start = stay.startTime
        // Bound the lookback to `transitMaxGapSeconds` so a stay after a long
        // dormancy / tracking gap finds NO previous stay (→ distance nil,
        // transit .unknown) instead of a bogus cross-period leg.
        let earliest = start.addingTimeInterval(-Self.transitMaxGapSeconds)
        let latest = start.addingTimeInterval(Self.forwardReachSeconds)
        var before = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.endTime < start && $0.endTime >= earliest },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)])
        before.fetchLimit = Self.neighbourhoodReach
        var after = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime >= start && $0.startTime <= latest },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        after.fetchLimit = Self.neighbourhoodReach
        #if DEBUG
        try TestScope.readFault?(.predecessor)
        #endif
        let core = try context.fetch(before) + context.fetch(after) + [stay]
        let firstStart = core.map(\.startTime).min() ?? start
        let lastEnd = core.map(\.endTime).max() ?? stay.endTime
        // Cover overlaps with the entire evaluated chain, including a long
        // older envelope hidden behind many short rows. Read one extra row
        // to disclose density truncation; incomplete coverage cannot record.
        var overlapping = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime < lastEnd && $0.endTime > firstStart },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        overlapping.fetchLimit = Self.overlapReach + 1
        let overlaps = try context.fetch(overlapping)
        let complete = overlaps.count <= Self.overlapReach
        let fetched = core + Array(overlaps.prefix(Self.overlapReach))
        var rows: [Stay] = []
        var seen: Set<PersistentIdentifier> = []
        for row in fetched where !row.isDeleted && seen.insert(row.persistentModelID).inserted {
            rows.append(row)
        }
        let evidence = try FlightObservationBounds.fetch(stays: rows, in: context,
                                                         checkCancellation: { try Task.checkCancellation() })
        let timeline = FlightJudge.Timeline(rows.map { row in
            let observations = evidence[row.persistentModelID]
            return FlightJudge.Stay(
                id: row.id, start: row.startTime, end: row.endTime,
                latitude: row.centroidLatitude, longitude: row.centroidLongitude,
                isAirport: row.isAirport, islandName: row.islandName, pingCount: row.pingCount,
                isPhoto: DataSource.needsPhotoTimeCaution(
                    storedRaw: row.sourceRaw, retainedRaws: observations?.retainedSourceRaws ?? [],
                    memberEvidenceComplete: observations?.memberEvidenceComplete ?? false),
                mode: FlightJudge.Mode(raw: decided[row.persistentModelID]?.rawValue ?? row.transitFromPreviousRaw),
                lastObservedAt: observations?.lastObservedAt, firstObservedAt: observations?.firstObservedAt)
        }, overlapCoverageComplete: complete)
        let ordered = timeline.inputIndex.map { rows[$0] }
        let id = stay.persistentModelID
        guard let index = ordered.firstIndex(where: { $0.persistentModelID == id }) else { return nil }
        return Neighbourhood(rows: ordered, timeline: timeline, index: index)
    }

    /// The leg into the stay at `index`: great-circle km from the stay
    /// before it (the latest ending before it starts, inside the lookback;
    /// equal ends break on the larger uuidString, as the Flight Log's walk
    /// does), nil without one.
    private static func legKm(_ index: Int, in timeline: FlightJudge.Timeline) -> Double? {
        guard let previous = timeline.previous[index] else { return nil }
        let from = timeline.stays[previous], to = timeline.stays[index]
        return legDistanceKm(
            from: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
            to: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude))
    }

    /// Great-circle leg distance, the haversine the Flight Log measures
    /// with, so the stored leg and the log agree.
    nonisolated static func legDistanceKm(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CollectionsAggregator.haversineKm(lat1: from.latitude, lon1: from.longitude,
                                          lat2: to.latitude, lon2: to.longitude)
    }
}
