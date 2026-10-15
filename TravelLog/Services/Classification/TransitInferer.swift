//
//  TransitInferer.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import os.log

/// Classifies each `Stay`'s inbound leg as `.flight` or `.unknown` from pure
/// geometry: great-circle displacement from the previous stay, proximity to a
/// known airport at either endpoint, and physical ground-speed impossibility.
///
/// **No CoreMotion.** `CMMotionActivity` has no airplane or boat class, needs
/// the Motion & Fitness permission and exposes only a 7-day history, so it
/// cannot reach imported photos or motion-denied devices. `inferFlight` is
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

    private static let flightMinDisplacementKm: Double = 300
    private static let flightMaxGroundSpeedKmh: Double = 400
    private static let airportRadiusMeters: Double = 3000

    /// Calendar-corroborated flights:
    /// the geometry heuristic's 300 km + airport + speed bar misses genuine
    /// short regional flights and airport-detector gaps. A calendar event
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

    /// Max gap between the previous stay's end and this stay's start for the
    /// two to count as a continuous transit leg. Beyond this there is no
    /// meaningful "previous stay" — the prior recorded location is from a
    /// different journey after a dormancy / tracking gap — so we must NOT write
    /// a `distanceFromPreviousKm` (it would be a bogus cross-period great-circle
    /// such as Athens→Tokyo ~9000 km that inflates trip "total km" / Wrapped
    /// stats) and must NOT infer a transit mode.
    private static let transitMaxGapSeconds: TimeInterval = 7 * 24 * 60 * 60

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
        do {
            for stay in stays {
                guard !Task.isCancelled else { break }
                try await inferTransitForStay(stay)
                inferred += 1
                if stay.transitFromPreviousRaw == TransitMode.flight.rawValue {
                    flights += 1
                }
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

    /// Writes `distanceFromPreviousKm` and sets `transitFromPreviousRaw` to
    /// `.flight` when the inbound leg passes the flight test — geometric, or
    /// calendar-corroborated for the shorter legs geometry can't call —
    /// else `.unknown` (ground sub-mode is no longer tracked — see the type
    /// doc). Every fetched nil-transit stay gets a value unless the
    /// predecessor read throws; the caller then rolls the unit back.
    ///
    /// Values stay terminal: a calendar event added AFTER a leg was
    /// classified `.unknown` does not retroactively upgrade it (the
    /// nil-transit fetch never revisits classified stays). Flights are
    /// booked ahead in practice, so the event is normally present at
    /// inference time.
    private func inferTransitForStay(_ stay: Stay) async throws {
        guard let previousStay = try findPreviousStay(before: stay, in: modelContext) else {
            stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
            stay.distanceFromPreviousKm = nil
            return
        }

        let fromCoord = CLLocation(latitude: previousStay.centroidLatitude,
                                   longitude: previousStay.centroidLongitude)
        let toCoord = CLLocation(latitude: stay.centroidLatitude,
                                 longitude: stay.centroidLongitude)
        let distanceKm = fromCoord.distance(from: toCoord) / 1000.0
        stay.distanceFromPreviousKm = distanceKm

        let gapStart = previousStay.endTime
        let gapEnd = stay.startTime

        guard gapEnd > gapStart else {
            // Overlapping / zero-gap pair: there is no leg here, so there is
            // no leg distance either. The distance was written above, before
            // this guard; left in place it would be a phantom great-circle
            // between two stays that never had a journey between them,
            // feeding trip totals and Wrapped km. Matches the no-previous-stay
            // branch, which nils it for exactly this reason.
            stay.distanceFromPreviousKm = nil
            stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
            return
        }

        if inferFlight(distanceKm: distanceKm,
                       gapSeconds: gapEnd.timeIntervalSince(gapStart),
                       from: fromCoord.coordinate,
                       to: toCoord.coordinate) {
            stay.transitFromPreviousRaw = TransitMode.flight.rawValue
        } else if distanceKm >= Self.corroboratedFlightMinDisplacementKm,
                  await calendarCorroboratesFlight(gapStart: gapStart, gapEnd: gapEnd) {
            stay.transitFromPreviousRaw = TransitMode.flight.rawValue
        } else {
            stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        }
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
    /// legs long enough to have been flights (≥ the corroborated floor) and
    /// upgrade the ones a flight-shaped calendar event now vouches for.
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

    /// The leg into a target stay, as seen by the read that evaluated it.
    /// The apply commits only while every witness still matches committed
    /// store state: same physical target and predecessor rows, same gap
    /// bounds, same endpoint coordinates. The geometry decision and the
    /// EventKit evidence are functions of exactly these values.
    private nonisolated struct LegEvidence: Sendable {
        let targetID: PersistentIdentifier
        let targetUUID: UUID
        let predecessorID: PersistentIdentifier
        let gapStart: Date
        let gapEnd: Date
        let fromLatitude: Double
        let fromLongitude: Double
        let toLatitude: Double
        let toLongitude: Double
        let distanceKm: Double

        var fromCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: fromLatitude, longitude: fromLongitude)
        }
        var toCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: toLatitude, longitude: toLongitude)
        }
        var gapSeconds: TimeInterval { gapEnd.timeIntervalSince(gapStart) }

        func witnessesMatch(_ other: LegEvidence) -> Bool {
            targetID == other.targetID
                && predecessorID == other.predecessorID
                && gapStart == other.gapStart
                && gapEnd == other.gapEnd
                && fromLatitude == other.fromLatitude
                && fromLongitude == other.fromLongitude
                && toLatitude == other.toLatitude
                && toLongitude == other.toLongitude
        }
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
        let scan: (scanned: Int, next: UnknownLegCursor?, legs: [LegEvidence])
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
        var corroborated: [LegEvidence] = []
        for leg in scan.legs {
            guard !Task.isCancelled else { break }
            if await calendarCorroboratesFlight(gapStart: leg.gapStart, gapEnd: leg.gapEnd) {
                corroborated.append(leg)
            }
        }
        guard !corroborated.isEmpty else {
            return UnknownLegScanResult(upgraded: 0, scanned: scan.scanned, next: scan.next)
        }

        let applied = await applyInSlices(corroborated, gate: gate)
        return UnknownLegScanResult(
            upgraded: applied.upgraded, scanned: scan.scanned,
            next: applied.failed ? nil : scan.next, failed: applied.failed)
    }

    /// Ungated read phase of the calendar re-pass: legs at or above the
    /// corroborated floor. A fresh context per batch reads committed store
    /// state and holds nothing across the EventKit awaits that follow.
    private func calendarCandidateLegs(
        from cursor: UnknownLegCursor,
        batchSize: Int
    ) throws -> (scanned: Int, next: UnknownLegCursor?, legs: [LegEvidence]) {
        let context = ModelContext(modelContainer)
        let batch = try unknownLegBatch(from: cursor, batchSize: batchSize, in: context)
        var legs: [LegEvidence] = []
        for stay in batch.fresh {
            guard let leg = try legGeometry(for: stay, in: context) else { continue }
            guard leg.distanceKm >= Self.corroboratedFlightMinDisplacementKm else { continue }
            legs.append(leg)
        }
        return (batch.fresh.count, batch.next, legs)
    }

    /// Runs the apply in bounded gate units, one after another (never
    /// nested). Every slice runs before the caller advances its cursor, and
    /// the count keeps slices that committed before a failed one.
    private func applyInSlices(
        _ legs: [LegEvidence],
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

    /// Gated apply half of both re-passes. Revalidates every candidate
    /// against committed store state before upgrading (inference results
    /// apply only after dependency validation): the evaluated physical row
    /// must still be `.unknown` (a concurrent pass that wrote a terminal
    /// value wins), and its current leg must have the same predecessor row,
    /// gap bounds and endpoint coordinates as the leg the geometry rule or
    /// the calendar evidence vouched for. Drifted legs are skipped, not
    /// counted; the next run re-evaluates them. The write stores the
    /// vouched-for leg distance as well as `.flight` (the
    /// `applyConfirmedFlight` unconditional-overwrite rule), replacing a
    /// stored km that went stale against an older predecessor.
    ///
    /// A fresh context: rows registered in a long-lived context keep the
    /// values they were first fetched with, so revalidating there could
    /// miss drift another context saved. Only reads happen here; the
    /// geometry decision was made outside the gate.
    private func applyFlightUpgrades(_ legs: [LegEvidence]) -> (upgraded: Int, failed: Bool) {
        let context = ModelContext(modelContainer)
        let unknownRaw = TransitMode.unknown.rawValue
        let ids = Array(Set(legs.map(\.targetUUID)))
        let predicate = #Predicate<Stay> { ids.contains($0.id) }
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
            for leg in legs {
                guard let stay = rows[leg.targetID], !stay.isDeleted,
                      stay.transitFromPreviousRaw == unknownRaw else { continue }
                guard let current = try legGeometry(for: stay, in: context),
                      current.witnessesMatch(leg) else { continue }
                stay.transitFromPreviousRaw = TransitMode.flight.rawValue
                stay.distanceFromPreviousKm = leg.distanceKm
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

    /// Settings "Detect Flights": geometry re-pass over `.unknown` legs long
    /// enough for the geometric rule. `.unknown` is terminal, so when the
    /// bundled airport dataset expands to include scheduled small fields,
    /// such as island airports, legs that failed only the
    /// airport-endpoint arm must be revisited explicitly. Second sanctioned
    /// exception to "transit values are terminal", with the same discipline as
    /// `recorroborateUnknownLegs`: user-invoked, upgrade-only (`.unknown` →
    /// `.flight`), never touches ground modes or existing flights, idempotent.
    ///
    /// Gate discipline (the `recorroborateUnknownLegs` shape): the expensive
    /// read/geometry phase — the batch fetch plus a per-leg
    /// `findPreviousStay` fetch and AirportDetector lookups — runs UNGATED;
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
        let scan: (scanned: Int, next: UnknownLegCursor?, legs: [LegEvidence])
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
    /// stored value goes stale when imports insert stays into the gap, and a
    /// leg whose TRUE displacement grew past the floor could never re-enter a
    /// stored-distance predicate. Every `.unknown` leg is admitted; the
    /// decision uses geometry recomputed from the CURRENT predecessor (same
    /// rationale as `CollectionsAggregator.legRecord(preferStoredDistance:
    /// false)`), and
    /// `inferFlight` applies the real displacement floor. A fresh context
    /// per batch reads committed store state.
    private func geometryCandidateLegs(
        from cursor: UnknownLegCursor,
        batchSize: Int
    ) throws -> (scanned: Int, next: UnknownLegCursor?, legs: [LegEvidence]) {
        let context = ModelContext(modelContainer)
        let batch = try unknownLegBatch(from: cursor, batchSize: batchSize, in: context)
        var legs: [LegEvidence] = []
        for stay in batch.fresh {
            guard !Task.isCancelled else { break }
            guard let leg = try legGeometry(for: stay, in: context) else { continue }
            if inferFlight(distanceKm: leg.distanceKm, gapSeconds: leg.gapSeconds,
                           from: leg.fromCoordinate, to: leg.toCoordinate) {
                legs.append(leg)
            }
        }
        return (batch.fresh.count, batch.next, legs)
    }

    // MARK: - Flight Inference

    /// A leg is a flight when it spans at least `flightMinDisplacementKm`,
    /// touches a known airport at the departure OR arrival end, and could not
    /// have been covered by ground in the available gap (`> flightMaxGroundSpeedKmh`).
    /// Pure scalars — no `@Model`, no CoreMotion — so it is `nonisolated` and
    /// unit-tested directly.
    nonisolated func inferFlight(distanceKm: Double,
                             gapSeconds: TimeInterval,
                             from: CLLocationCoordinate2D,
                             to: CLLocationCoordinate2D) -> Bool {
        guard distanceKm >= Self.flightMinDisplacementKm else { return false }

        let nearDepartureAirport = AirportDetector.shared.isNearAirport(
            from, radiusMeters: Self.airportRadiusMeters)
        let nearArrivalAirport = AirportDetector.shared.isNearAirport(
            to, radiusMeters: Self.airportRadiusMeters)
        guard nearDepartureAirport || nearArrivalAirport else { return false }

        let gapHours = gapSeconds / 3600.0
        let maxGroundHours = distanceKm / Self.flightMaxGroundSpeedKmh
        guard gapHours < maxGroundHours else { return false }

        return true
    }

    // MARK: - Helpers

    /// The leg into `stay` with its dependency witnesses, or nil when it has
    /// none. Throws when the predecessor read fails.
    private func legGeometry(for stay: Stay, in context: ModelContext) throws -> LegEvidence? {
        guard !stay.isDeleted else { return nil }
        guard let previous = try findPreviousStay(before: stay, in: context) else { return nil }
        let gapStart = previous.endTime
        let gapEnd = stay.startTime
        guard gapEnd > gapStart else { return nil }
        let fromLocation = CLLocation(latitude: previous.centroidLatitude,
                                      longitude: previous.centroidLongitude)
        let toLocation = CLLocation(latitude: stay.centroidLatitude,
                                    longitude: stay.centroidLongitude)
        return LegEvidence(
            targetID: stay.persistentModelID,
            targetUUID: stay.id,
            predecessorID: previous.persistentModelID,
            gapStart: gapStart,
            gapEnd: gapEnd,
            fromLatitude: previous.centroidLatitude,
            fromLongitude: previous.centroidLongitude,
            toLatitude: stay.centroidLatitude,
            toLongitude: stay.centroidLongitude,
            distanceKm: fromLocation.distance(from: toLocation) / 1000.0)
    }

    /// Throws on a failed read: nil must mean "no predecessor within the
    /// lookback", never a fetch that did not happen.
    private func findPreviousStay(before stay: Stay, in context: ModelContext) throws -> Stay? {
        let stayStart = stay.startTime
        // Bound the lookback to `transitMaxGapSeconds` so a stay after a long
        // dormancy / tracking gap finds NO previous stay (→ distance nil,
        // transit .unknown via the no-previous branch) instead of a bogus
        // cross-period leg.
        let earliest = stayStart.addingTimeInterval(-Self.transitMaxGapSeconds)
        let predicate = #Predicate<Stay> {
            $0.endTime < stayStart && $0.endTime >= earliest
        }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        #if DEBUG
        try TestScope.readFault?(.predecessor)
        #endif
        let latest = try context.fetch(descriptor)
        guard let first = latest.first, latest.count > 1,
              latest[1].endTime == first.endTime else { return latest.first }
        // `endTime` is not unique (imports mint co-timed stays), and the store
        // returns ties in no defined order. Break them as
        // `CollectionsAggregator`'s Flight Log walk does, on the largest
        // uuidString, so the inferer and the Flight Log agree on the leg.
        let tiedEnd = first.endTime
        let tied = try context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.endTime == tiedEnd }))
        return tied.max { $0.id.uuidString < $1.id.uuidString }
    }
}
