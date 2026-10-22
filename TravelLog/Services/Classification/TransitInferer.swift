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
        /// Replaces the EventKit query once Calendar access is granted.
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

    /// Calendar-corroborated flights:
    /// the judge's timing rules leave genuine short regional flights with
    /// slack in the data unrecorded. A calendar event
    /// that is specifically flight-shaped (`PlannedTripDetector.isFlightEvent`
    /// — context-gated flight code or "Flight to …" title) overlapping the
    /// transit gap is strong independent evidence, so the displacement floor
    /// drops to this value for corroborated legs. Kept well above city scale
    /// so an unrelated flight event on a driving day can't relabel an errand.
    private static let corroboratedFlightMinDisplacementKm: Double = 100

    /// Padding around the transit gap when querying calendar events —
    /// booked flight times and SLC-observed gaps disagree by check-in,
    /// delays, and clock skew. Fetch only: a match must still overlap the
    /// gap itself (`corroboratingFlightEvent`).
    private static let calendarGapPaddingSeconds: TimeInterval = 3 * 60 * 60

    /// Widest gap a flight-shaped calendar event may vouch for. Over a
    /// longer silence the user may have flown out and back, or flown and
    /// then driven on, so the two endpoints need not be the flight's: one
    /// booked flight would record a leg between places it never joined.
    /// Such a leg stays `.unknown`, where the Flight Log's review tiers can
    /// still offer it.
    nonisolated static let calendarMaxGapSeconds: TimeInterval = 48 * 60 * 60

    /// The shape a calendar event may vouch for: a journey of at least the
    /// corroborated floor whose stays are at most `calendarMaxGapSeconds`
    /// apart. Shared by the drain and the Detect Flights calendar re-pass.
    nonisolated static func calendarMayVouch(distanceKm: Double, gapSeconds: TimeInterval) -> Bool {
        distanceKm >= corroboratedFlightMinDisplacementKm
            && gapSeconds > 0 && gapSeconds <= calendarMaxGapSeconds
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
    /// read too, at most `overlapReach`: they flag bad data.
    private static let neighbourhoodReach = 64
    private static let overlapReach = 16
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

    /// Runs inside the caller's gate unit. Only this drain writes the
    /// actor's own context (the re-passes read and apply through their own
    /// contexts), so the rollback below discards only this unit's writes.
    func inferTransitForRecentStaysReportingChanges() async -> DrainOutcome {
        // Defensive: commit anything the context already holds so a rollback
        // cannot discard it. A failed pre-save reports failure without
        // rolling back, and its dirty attempt stays publication-worthy.
        var needsPublication = modelContext.hasChanges
        guard preserveUnrelatedPendingEdits(in: modelContext) else {
            return DrainOutcome(fetched: 0, classified: 0, flights: 0,
                                needsPublication: true, failed: true)
        }
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
            stays = try modelContext.fetch(descriptor)
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
        let dismissed = Self.dismissedArrivals()
        do {
            for stay in stays {
                guard !Task.isCancelled else { break }
                flights += try await inferTransitForStay(stay, dismissed: dismissed)
                inferred += 1
            }
        } catch {
            // A failed predecessor read is not "no predecessor within 7
            // days": committing the terminal no-leg value would hide the leg
            // from every later drain. Leave the whole unit pending instead.
            modelContext.rollback()
            logger.error("Transit inference read failed; batch left pending: \(error.localizedDescription)")
            return DrainOutcome(fetched: stays.count, classified: 0, flights: 0,
                                needsPublication: needsPublication, failed: true)
        }

        if inferred > 0 {
            needsPublication = modelContext.hasChanges || needsPublication
            do {
                #if DEBUG
                try TestScope.beforeSave?()
                #endif
                try modelContext.save()
            } catch {
                // Roll back so the rows re-enter the nil-transit fetch; left
                // dirty they matched no later drain and committed only if an
                // unrelated later save carried them along.
                modelContext.rollback()
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
    /// stays and their legs on a fresh context, the geometry decision and
    /// any EventKit corroboration on the captured values, then short gated
    /// units that revalidate each leg against committed store state and
    /// write it. A calendar query never holds the gate, so live saves and
    /// deletion never wait on EventKit. A leg another writer moved meanwhile
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
        /// `CalendarEnricher.revocationCount` captured before the EventKit
        /// query that decided the flight; nil when no calendar evidence did.
        let calendarRevocation: UInt64?
    }

    /// Ungated read and decision phase of `inferTransitBatchOutsideGate`.
    /// Throws on a failed read: a missing predecessor must be a read that
    /// happened. Every stay is judged as the earlier ones in the batch were
    /// decided, then the calendar answers for the journeys geometry left
    /// open. Cancellation stops before the next leg; what was decided still
    /// applies.
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
        let dismissed = Self.dismissedArrivals()
        // Values only past this point: no model is read after an EventKit await.
        var decided: [PersistentIdentifier: TransitMode] = [:]
        var captured: [(leg: PendingLeg, calendar: (start: Date, end: Date)?, flightID: PersistentIdentifier?)] = []
        for stay in stays where !stay.isDeleted {
            guard !Task.isCancelled else { break }
            guard let hood = try neighbourhood(of: stay, in: context, decided: decided) else { continue }
            let recording = FlightJudge.recording(
                for: hood.index, in: hood.timeline, airports: .bundled, dismissed: dismissed)
            let target = recording.target.map { hood.rows[$0].persistentModelID }
            var flightID: PersistentIdentifier?
            var calendar: (start: Date, end: Date)?
            if let target, case .record = recording.decision {
                flightID = target
                decided[target] = .flight
            } else if target != nil {
                calendar = Self.calendarWindow(recording, in: hood.timeline)
            }
            if decided[stay.persistentModelID] == nil { decided[stay.persistentModelID] = .unknown }
            captured.append((PendingLeg(
                targetID: stay.persistentModelID, targetUUID: stay.id,
                witness: Self.witness(hood, recording),
                legKm: Self.legKm(hood.index, in: hood.timeline),
                flightID: flightID, calendarRevocation: nil), calendar, target))
        }
        var evaluated: [PendingLeg] = []
        for entry in captured {
            guard !Task.isCancelled else { break }
            guard let window = entry.calendar else {
                evaluated.append(entry.leg)
                continue
            }
            let revocation = CalendarEnricher.revocationCount
            let vouched = await calendarCorroboratesFlight(gapStart: window.start, gapEnd: window.end)
            evaluated.append(PendingLeg(
                targetID: entry.leg.targetID, targetUUID: entry.leg.targetUUID,
                witness: entry.leg.witness, legKm: entry.leg.legKm,
                flightID: vouched ? entry.flightID : nil,
                calendarRevocation: vouched ? revocation : nil))
        }
        return (stays.count, evaluated)
    }

    /// Gated apply half of `inferTransitBatchOutsideGate`, on a fresh
    /// context: the evaluated physical row must still be nil-transit (a
    /// concurrent writer's terminal value wins), and the journey the judge
    /// read must still be in the store as it was (`JourneyWitness`), with
    /// the same verdict. Drifted legs are skipped, not counted. A flight
    /// only calendar evidence vouched for also needs the calendar authority
    /// it was decided under: after Delete Calendar Data (or any revocation)
    /// began, or once the batch is cancelled, it is skipped and its leg
    /// stays nil for a later batch to judge afresh.
    private func applyPendingLegs(
        _ legs: [PendingLeg]
    ) -> (classified: Int, flights: Int, attemptedSave: Bool, failed: Bool) {
        let context = ModelContext(modelContainer)
        let ids = Array(Set(legs.map(\.targetUUID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        // Re-read: the user may have dismissed a candidate meanwhile.
        let dismissed = Self.dismissedArrivals()
        // A dirty save attempt stays publication-worthy even when it fails.
        var attemptedSave = false
        do {
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
                if let revocation = pending.calendarRevocation,
                   Task.isCancelled || revocation != CalendarEnricher.revocationCount { continue }
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
                    if pending.calendarRevocation == nil {
                        guard case .record = recording.decision else { continue }
                    }
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
        /// Committed flights across the drain and both re-passes.
        let found: Int
        /// A read or save failed and the run stopped there.
        let failed: Bool
        /// Every phase ran to exhaustion. False after a failure, cancellation
        /// or a runaway cap, so a zero count proves nothing.
        let complete: Bool
    }

    /// Settings "Detect Flights": drain the nil-transit backlog in bounded,
    /// separately gated batches so SLC writes interleave, then revisit
    /// terminal `.unknown` legs for airport-data changes and Calendar
    /// corroboration. Every phase owns its own short gate units; do NOT wrap
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
        guard geometry.complete else {
            return FlightDetectionOutcome(analyzed: analyzed, found: found,
                                          failed: geometry.failed, complete: false)
        }
        let calendar = await recorroborateUnknownLegs(gate: gate)
        found += calendar.upgraded
        return FlightDetectionOutcome(analyzed: analyzed, found: found,
                                      failed: calendar.failed, complete: calendar.complete)
    }

    // MARK: - Core

    /// Writes `distanceFromPreviousKm` (the leg from the predecessor) and
    /// `.unknown` onto the stay, and `.flight` onto its journey's first stay
    /// when the judge records the journey (or a flight-shaped calendar event
    /// vouches for it): the stay itself, or an earlier `.unknown` leg whose
    /// journey the stay turned out to extend. Returns the flights written.
    /// Every fetched nil-transit stay gets a value unless a read throws; the
    /// caller then rolls the unit back.
    ///
    /// Values stay terminal: a calendar event added AFTER a leg was
    /// classified `.unknown` does not retroactively upgrade it (the
    /// nil-transit fetch never revisits classified stays). Flights are
    /// booked ahead in practice, so the event is normally present at
    /// inference time.
    ///
    /// A journey holding a stay in `dismissed` (the user dismissed it as a
    /// possible flight), a flight or the user's Not a Flight takes no new
    /// flight.
    private func inferTransitForStay(_ stay: Stay, dismissed: Set<UUID>) async throws -> Int {
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        guard let hood = try neighbourhood(of: stay, in: modelContext) else {
            stay.distanceFromPreviousKm = nil
            return 0
        }
        let timeline = hood.timeline
        stay.distanceFromPreviousKm = Self.legKm(hood.index, in: timeline)
        let recording = FlightJudge.recording(
            for: hood.index, in: timeline, airports: .bundled, dismissed: dismissed)
        guard let target = recording.target else { return 0 }
        if case .record = recording.decision {
            // Recorded below.
        } else if let window = Self.calendarWindow(recording, in: timeline),
                  await calendarCorroboratesFlight(gapStart: window.start, gapEnd: window.end) {
            // Vouched for by the calendar.
        } else {
            return 0
        }
        let row = hood.rows[target]
        row.transitFromPreviousRaw = TransitMode.flight.rawValue
        row.distanceFromPreviousKm = Self.legKm(target, in: timeline)
        return 1
    }

    /// True when a flight-shaped calendar event overlaps the transit gap.
    /// Exits immediately without Calendar access — in tests and
    /// on non-granted devices this path is a no-op and the classifier stays
    /// pure geometry. The narrow per-gap `eventsOverlapping` query neither
    /// touches the store nor `PipelineGate`, so calling it from inside a
    /// gated pipeline unit is safe.
    private func calendarCorroboratesFlight(gapStart: Date, gapEnd: Date) async -> Bool {
        guard CalendarEnricher.hasReadAccess else { return false }
        #if DEBUG
        if let corroborates = TestScope.corroborates { return corroborates(gapStart, gapEnd) }
        #endif
        let events = await AppDelegate.calendarEnricher.eventsOverlapping(
            start: gapStart.addingTimeInterval(-Self.calendarGapPaddingSeconds),
            end: gapEnd.addingTimeInterval(Self.calendarGapPaddingSeconds)
        )
        return Self.corroboratingFlightEvent(in: events, gapStart: gapStart, gapEnd: gapEnd)
    }

    /// The padded query only fetches; a flight event vouches for the leg
    /// only when its own interval overlaps the unpadded gap. Otherwise the
    /// drive to the airport, ending before the booked flight starts, would
    /// borrow that flight and become one.
    nonisolated static func corroboratingFlightEvent(
        in events: [CalendarEventSnapshot], gapStart: Date, gapEnd: Date
    ) -> Bool {
        events.contains {
            $0.startDate < gapEnd && $0.endDate > gapStart
                && PlannedTripDetector.isFlightEvent($0)
        }
    }

    /// Settings backfill: revisit `.unknown`
    /// legs of the shape a calendar event may vouch for (`calendarMayVouch`:
    /// ≥ the corroborated floor, within `calendarMaxGapSeconds`) and
    /// upgrade the ones a flight-shaped calendar event now vouches for.
    /// A leg whose candidate the user dismissed is never upgraded.
    /// This is the ONE deliberate exception to "classifications are
    /// terminal" — explicitly user-invoked, upgrade-only (`.unknown` →
    /// `.flight`; never touches ground modes or existing flights), and
    /// idempotent.
    ///
    /// Gate discipline lives INSIDE: the per-leg EventKit
    /// queries run UNGATED — one per eligible leg over a full history is an
    /// unbounded gate hold — and the upgrades land through small gated
    /// apply units that revalidate each leg against committed store state
    /// (see `applyFlightUpgrades`). Do NOT wrap calls in `PipelineGate.run`
    /// — the nested unit would deadlock.

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
                    mode: stay.mode)
            })
    }

    /// A re-pass upgrade: the `.unknown` stay its journey's flight goes on,
    /// as the read that judged it saw it.
    private nonisolated struct JourneyLeg: Sendable {
        let targetID: PersistentIdentifier
        let targetUUID: UUID
        let witness: JourneyWitness
        let legKm: Double?
        /// The journey's stays' raw window, for the calendar.
        let gapStart: Date
        let gapEnd: Date
    }

    /// Fetch one batch of `.unknown` legs from `cursor`, and compute the next
    /// cursor. Shared by both re-passes so the keyset logic exists once.
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

    /// Drain wrapper: batches until the backlog is exhausted, stopping at
    /// the first failed batch with the counts committed before it.
    @discardableResult
    func recorroborateUnknownLegs(gate: PipelineGate = .shared) async -> UnknownLegPassOutcome {
        var cursor: UnknownLegCursor? = .start
        var total = 0
        var rounds = 0
        while let current = cursor, rounds < 400, !Task.isCancelled {
            rounds += 1
            let result = await recorroborateUnknownLegsBatch(from: current, gate: gate)
            total += result.upgraded
            if result.failed {
                return UnknownLegPassOutcome(upgraded: total, failed: true, complete: false)
            }
            cursor = result.next
        }
        return UnknownLegPassOutcome(upgraded: total, failed: false,
                                     complete: cursor == nil && !Task.isCancelled)
    }

    /// One bounded batch of the calendar re-pass.
    func recorroborateUnknownLegsBatch(
        from cursor: UnknownLegCursor = .start,
        batchSize: Int = TransitInferer.unknownLegScanBatchSize,
        gate: PipelineGate = .shared
    ) async -> UnknownLegScanResult {
        guard CalendarEnricher.hasReadAccess else {
            return UnknownLegScanResult(upgraded: 0, scanned: 0, next: nil)
        }

        // Admission uses the TRUE distance, not the stored one:
        // `distanceFromPreviousKm` was written against the predecessor at
        // inference time and goes stale when imports later insert stays into
        // the gap — a leg whose true displacement GREW past the floor would
        // never re-enter a stored-distance predicate, so no calendar event
        // could ever vouch for it. Every `.unknown` leg is floor-checked
        // against the CURRENT predecessor's geometry (the
        // reinferUnknownLegsGeometry rule). Bounded and resumable: one batch
        // at a time instead of the whole Stay table.
        let scan: (scanned: Int, next: UnknownLegCursor?, legs: [JourneyLeg])
        do {
            scan = try calendarCandidateLegs(from: cursor, batchSize: batchSize)
        } catch {
            logger.error("Calendar backfill read failed: \(error.localizedDescription)")
            return UnknownLegScanResult(upgraded: 0, scanned: 0, next: nil, failed: true)
        }

        // Ungated corroboration phase over captured values only: no model is
        // read after an EventKit await, so a row deleted meanwhile cannot
        // trap here. Store writes happen
        // only in the gated, revalidating apply below.
        let revocation = CalendarEnricher.revocationCount
        var corroborated: [JourneyLeg] = []
        for leg in scan.legs {
            guard !Task.isCancelled else { break }
            if await calendarCorroboratesFlight(gapStart: leg.gapStart, gapEnd: leg.gapEnd) {
                corroborated.append(leg)
            }
        }
        guard !corroborated.isEmpty else {
            return UnknownLegScanResult(upgraded: 0, scanned: scan.scanned, next: scan.next)
        }

        let applied = await applyInSlices(corroborated, calendarRevocation: revocation, gate: gate)
        return UnknownLegScanResult(
            upgraded: applied.upgraded, scanned: scan.scanned,
            next: applied.failed ? nil : scan.next, failed: applied.failed)
    }

    /// Ungated read phase of the calendar re-pass: journeys of the shape a
    /// calendar event may vouch for (`calendarMayVouch`), on their first
    /// stay, never one holding a dismissed candidate. A fresh context per
    /// batch reads committed store state and holds nothing across the
    /// EventKit awaits that follow.
    private func calendarCandidateLegs(
        from cursor: UnknownLegCursor,
        batchSize: Int
    ) throws -> (scanned: Int, next: UnknownLegCursor?, legs: [JourneyLeg]) {
        let context = ModelContext(modelContainer)
        let batch = try unknownLegBatch(from: cursor, batchSize: batchSize, in: context)
        let dismissed = Self.dismissedArrivals()
        var legs: [JourneyLeg] = []
        for stay in batch.fresh where !dismissed.contains(stay.id) {
            guard let leg = try journeyLeg(for: stay, in: context, dismissed: dismissed),
                  Self.calendarMayVouch(distanceKm: leg.journeyKm,
                                        gapSeconds: leg.leg.gapEnd.timeIntervalSince(leg.leg.gapStart))
            else { continue }
            legs.append(leg.leg)
        }
        return (batch.fresh.count, batch.next, legs)
    }

    /// Runs the apply in bounded gate units, one after another (never
    /// nested). Every slice runs before the caller advances its cursor, and
    /// the count keeps slices that committed before a failed one.
    private func applyInSlices(
        _ legs: [JourneyLeg],
        calendarRevocation: UInt64? = nil,
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
                await self.applyFlightUpgrades(slice, calendarRevocation: calendarRevocation)
            }
            upgraded += result.upgraded
            if result.failed { return (upgraded, true) }
        }
        return (upgraded, false)
    }

    /// Gated apply half of both re-passes. Revalidates every candidate
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
        _ legs: [JourneyLeg], calendarRevocation: UInt64? = nil
    ) -> (upgraded: Int, failed: Bool) {
        // Calendar-vouched upgrades land only under the authority they were
        // decided with (see `applyPendingLegs`).
        if let calendarRevocation,
           Task.isCancelled || calendarRevocation != CalendarEnricher.revocationCount {
            return (0, false)
        }
        let context = ModelContext(modelContainer)
        let unknownRaw = TransitMode.unknown.rawValue
        let ids = Array(Set(legs.map(\.targetUUID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
        // Re-read: the user may have dismissed the candidate while the
        // ungated phase ran.
        let dismissed = Self.dismissedArrivals()
        do {
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
                if calendarRevocation == nil {
                    guard case .record = recording.decision else { continue }
                }
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
    /// whose candidate the user dismissed in the Flight Log is skipped. Second sanctioned
    /// exception to "transit values are terminal", with the same discipline as
    /// `recorroborateUnknownLegs`: user-invoked, upgrade-only (`.unknown` →
    /// `.flight`), never touches ground modes or existing flights, idempotent.
    ///
    /// Gate discipline (the `recorroborateUnknownLegs` shape): the expensive
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
    /// No stored-distance prefilter (the `recorroborateUnknownLegs` rule): the
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
        let dismissed = Self.dismissedArrivals()
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
    ) throws -> (leg: JourneyLeg, decision: FlightJudge.Decision, journeyKm: Double)? {
        guard let hood = try neighbourhood(of: stay, in: context) else { return nil }
        let timeline = hood.timeline
        let recording = FlightJudge.recording(
            for: hood.index, in: timeline, airports: .bundled, dismissed: dismissed)
        guard recording.target == hood.index, let journey = recording.journey,
              let assessment = recording.assessment else { return nil }
        let leg = JourneyLeg(
            targetID: stay.persistentModelID, targetUUID: stay.id,
            witness: Self.witness(hood, recording),
            legKm: Self.legKm(hood.index, in: timeline),
            gapStart: timeline.stays[journey.origin].end,
            gapEnd: timeline.stays[journey.destination].start)
        return (leg, recording.decision, assessment.distanceKm)
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
        var overlapping = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime < start && $0.endTime >= start },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        overlapping.fetchLimit = Self.overlapReach
        var after = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime >= start && $0.startTime <= latest },
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        after.fetchLimit = Self.neighbourhoodReach
        #if DEBUG
        try TestScope.readFault?(.predecessor)
        #endif
        let fetched = try context.fetch(before) + context.fetch(overlapping) + context.fetch(after) + [stay]
        var rows: [Stay] = []
        var seen: Set<PersistentIdentifier> = []
        for row in fetched where !row.isDeleted && seen.insert(row.persistentModelID).inserted {
            rows.append(row)
        }
        let photoRaw = DataSource.photoImport.rawValue
        let timeline = FlightJudge.Timeline(rows.map { row in
            FlightJudge.Stay(
                id: row.id, start: row.startTime, end: row.endTime,
                latitude: row.centroidLatitude, longitude: row.centroidLongitude,
                isAirport: row.isAirport, islandName: row.islandName, pingCount: row.pingCount,
                isPhoto: row.sourceRaw == photoRaw,
                mode: FlightJudge.Mode(raw: decided[row.persistentModelID]?.rawValue ?? row.transitFromPreviousRaw))
        })
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

    /// The calendar's question for a journey that may take a flight: its
    /// stays' raw window (the origin's end to the destination's start),
    /// when a flight event may vouch for it (`calendarMayVouch`).
    private static func calendarWindow(
        _ recording: FlightJudge.Recording, in timeline: FlightJudge.Timeline
    ) -> (start: Date, end: Date)? {
        guard recording.target != nil, let journey = recording.journey,
              let assessment = recording.assessment else { return nil }
        let start = timeline.stays[journey.origin].end
        let end = timeline.stays[journey.destination].start
        guard calendarMayVouch(distanceKm: assessment.distanceKm, gapSeconds: end.timeIntervalSince(start))
        else { return nil }
        return (start, end)
    }

    /// Great-circle leg distance, the haversine the Flight Log measures
    /// with, so the stored leg and the log agree.
    nonisolated static func legDistanceKm(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CollectionsAggregator.haversineKm(lat1: from.latitude, lon1: from.longitude,
                                          lat2: to.latitude, lon2: to.longitude)
    }
}
