//
//  ClassifierStage15Tests.swift
//  TravelLogTests
//
//  The Stage-1.5 × Stage-2-cap interaction that
//  stripped the ongoing trip during large-import backlogs:
//
//  Stage 1.5 reset the current journey's 5 newest destination/transit stays
//  to `.unclassified` on every foreground pass (its gate was "ANY
//  unclassified stay exists"), while Stage 2's per-call freeze cap drained
//  the unclassified table OLDEST-FIRST — so a big historical import consumed
//  every capped slot, the just-reset stays stayed `.unclassified`, and the
//  back half detached them from the "Currently Traveling" trip. Five more
//  stays vanished per Trips-tab visit until the backlog drained.
//
//  Fixes pinned here:
//   1. Stage 1.5's gate is journey-scoped: pre-journey backlog alone never
//      triggers a reset.
//   2. `fetchStage2Batch` hard-guarantees the reset IDs a slot in the same
//      pass, cap notwithstanding.
//   3. The journey-priority lane pulls current-journey unclassified stays
//      ahead of historical backlog (bounded, home-anchored only).
//
//  Pattern (same as TripBoundaryHardeningTests): seed by hand via a plain
//  context + save, then drive the actor's internal seams.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct ClassifierStage15Tests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double = 6,
        category: StayCategory,
        hex: String,
        source: DataSource = .liveSLC
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.sourceRaw = source.rawValue
        ctx.insert(stay)
        return stay
    }

    // MARK: - Stage 1.5 journey gate

    @Test("a pre-journey import backlog alone never resets journey stays")
    func backlogAloneDoesNotTriggerReset() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Historical import backlog: unclassified, well BEFORE the last
        // home stay.
        for i in 0..<30 {
            makeStay(in: ctx, startDay: Double(i), category: .unclassified, hex: "B\(i)", source: .photoImport)
        }
        // Settled homecoming, then the current journey: classified stays only.
        makeStay(in: ctx, startDay: 40, durationHours: 12, category: .home, hex: "H")
        for i in 0..<5 {
            makeStay(in: ctx, startDay: 41 + Double(i), category: .destination, hex: "J\(i)")
        }
        try ctx.save()

        // Pre-fix: the any-unclassified gate fired and reset the journey's
        // 5 newest classified stays. Post-fix: pure pre-journey backlog is
        // not journey context — no reset.
        let resetIDs = try await classifier.prepareForReclassification()
        #expect(resetIDs.isEmpty)
    }

    @Test("new unclassified data inside the journey still triggers the reset")
    func journeyDataStillTriggersReset() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 12, category: .home, hex: "H")
        let j0 = makeStay(in: ctx, startDay: 1, category: .destination, hex: "J0")
        let j1 = makeStay(in: ctx, startDay: 2, category: .transit, hex: "J1")
        // The new arrival (JFK after IST): unclassified, inside the journey.
        makeStay(in: ctx, startDay: 3, category: .unclassified, hex: "J2")
        try ctx.save()

        let resetIDs = try await classifier.prepareForReclassification()
        #expect(Set(resetIDs) == Set([j0.id, j1.id]))
    }

    @Test("user-overridden journey stays are never reset")
    func userOverriddenNeverReset() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 12, category: .home, hex: "H")
        let locked = makeStay(in: ctx, startDay: 1, category: .destination, hex: "J0")
        locked.userOverridden = true
        makeStay(in: ctx, startDay: 2, category: .unclassified, hex: "J1")
        try ctx.save()

        let resetIDs = try await classifier.prepareForReclassification()
        #expect(!resetIDs.contains(locked.id))
    }

    // MARK: - Stage 2 guaranteed inclusion

    @Test("the per-call cap can no longer starve the reset stays")
    func capCannotStarveResetStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 80 historical unclassified stays — more than the 60 cap.
        for i in 0..<80 {
            makeStay(in: ctx, startDay: Double(i), category: .unclassified, hex: "B\(i)", source: .photoImport)
        }
        makeStay(in: ctx, startDay: 100, durationHours: 12, category: .home, hex: "H")
        // The journey stays Stage 1.5 just reset (newest rows in the table).
        var resetIDs: [UUID] = []
        for i in 0..<3 {
            let s = makeStay(in: ctx, startDay: 101 + Double(i), category: .unclassified, hex: "J\(i)")
            resetIDs.append(s.id)
        }
        try ctx.save()

        // Pre-fix shape: the oldest-first `fetchLimit = 60` fetch returned
        // only backlog rows — none of the reset stays made the batch.
        // The batch holds the classifier's own models: read it on the actor.
        try await classifier.runIsolated { [resetIDs] classifier in
            let batch = try classifier.fetchStage2Batch(cap: 60, priorityIDs: resetIDs)
            let batchIDs = Set(batch.map(\.id))
            #expect(resetIDs.allSatisfy { batchIDs.contains($0) })
            // The freeze cap still bounds the backlog portion.
            #expect(batch.count <= 60 + TripClassifier.stage2JourneyPriorityCap + resetIDs.count)
            // Chronological order is preserved for the prompt builder.
            #expect(batch.map(\.startTime) == batch.map(\.startTime).sorted())
        }
    }

    @Test("journey-priority lane pulls current-journey backlog ahead of history")
    func journeyPriorityLaneIncluded() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        for i in 0..<80 {
            makeStay(in: ctx, startDay: Double(i), category: .unclassified, hex: "B\(i)", source: .photoImport)
        }
        makeStay(in: ctx, startDay: 100, durationHours: 12, category: .home, hex: "H")
        // A journey stay that was NOT part of this pass's reset (e.g. left
        // over from a cancelled pass) — the journey lane must still lift it
        // past the backlog.
        let leftover = makeStay(in: ctx, startDay: 101, category: .unclassified, hex: "J0")
        try ctx.save()

        let leftoverID = leftover.id
        try await classifier.runIsolated { classifier in
            let batch = try classifier.fetchStage2Batch(cap: 60, priorityIDs: [])
            #expect(batch.map(\.id).contains(leftoverID))
        }
    }

    @Test("without a home anchor the journey lane stays off and the cap holds")
    func noHomeAnchorKeepsCapMeaningful() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // No home stay at all (pre-onboarding import): "journey" would be
        // the whole table, so the journey lane must not fire — otherwise
        // the freeze cap is defeated.
        for i in 0..<80 {
            makeStay(in: ctx, startDay: Double(i), category: .unclassified, hex: "B\(i)", source: .photoImport)
        }
        try ctx.save()

        try await classifier.runIsolated { classifier in
            let batch = try classifier.fetchStage2Batch(cap: 60, priorityIDs: [])
            #expect(batch.count == 60)
        }
    }

    // MARK: - Outgrown short stop

    @Test("a stop the 20-minute rule made transit is judged again once it grows past it, with no new stay")
    func outgrownShortStopIsJudgedAgain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let clusterer = StayClusterer(modelContainer: container)
        let start = date(day: 10)
        func ping(minutes: Double) -> LocationPing {
            LocationPing(
                timestamp: start.addingTimeInterval(minutes * 60), latitude: 44.3, longitude: 12.9,
                horizontalAccuracy: 10, h3IndexRes6: H3Service.cellIndex(latitude: 44.3, longitude: 12.9) ?? "")
        }
        func classify() async {
            await StayClassificationInference.TestHook.$availability.withValue(false) {
                _ = await TripClassifier(modelContainer: container).classifyAndAssembleTripsWithGates(
                    maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
            }
        }
        func onlyStay() throws -> Stay {
            let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
            #expect(stays.count == 1)
            return try #require(stays.first)
        }

        ctx.insert(ping(minutes: 0))
        ctx.insert(ping(minutes: 15))
        try ctx.save()
        _ = await clusterer.clusterUnprocessedPings()
        await classify()
        #expect(try onlyStay().category == .transit)

        // The user stays put: the same stay grows to four hours.
        for minutes in [60.0, 120, 180, 240] { ctx.insert(ping(minutes: minutes)) }
        try ctx.save()
        _ = await clusterer.clusterUnprocessedPings()
        await classify()
        let grown = try onlyStay()
        #expect(grown.durationMinutes == 240)
        #expect(grown.category == .destination)
    }

    @Test("the lapse leaves user-set, airport, edited-trip and completed-trip stops, and long transit, alone")
    func outgrownShortStopReleaseGuards() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        func grown(from before: Int, to minutes: Double, _ configure: (Stay) -> Void = { _ in }) -> StayCategory {
            let stay = makeStay(in: ctx, startDay: 0, durationHours: minutes / 60, category: .transit, hex: "S")
            configure(stay)
            StayClassificationInputs.releaseOutgrownShortStop(stay, fromMinutes: before)
            return stay.category
        }
        func trip(complete: Bool, edited: Bool) -> Trip {
            let trip = Trip(startDate: date(day: 0))
            trip.isComplete = complete
            trip.userEdited = edited
            ctx.insert(trip)
            return trip
        }
        #expect(grown(from: 15, to: 60) == .unclassified)
        #expect(grown(from: 15, to: 18) == .transit)
        #expect(grown(from: 30, to: 90) == .transit)
        #expect(grown(from: 15, to: 60) { $0.userOverridden = true } == .transit)
        #expect(grown(from: 15, to: 60) { $0.isAirport = true } == .transit)
        #expect(grown(from: 15, to: 60) { $0.trip = trip(complete: false, edited: true) } == .transit)
        #expect(grown(from: 15, to: 60) { $0.trip = trip(complete: true, edited: false) } == .transit)
        #expect(grown(from: 15, to: 60) { $0.trip = trip(complete: false, edited: false) } == .unclassified)
    }

    @Test("import growth past the same 20-minute rule hands a short stop back, sparing one the user set")
    func importGrowthCrossesShortStopRule() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        func grownByImport(_ configure: (Stay) -> Void = { _ in }) -> (reset: Bool, category: StayCategory) {
            let stop = makeStay(in: ctx, startDay: 0, durationHours: 0.25, category: .transit, hex: "S")
            configure(stop)
            let before = StayClassificationInputs(stop)
            stop.endTime = stop.startTime.addingTimeInterval(60 * 60)
            stop.durationMinutes = 60
            return (StayClassificationInputs.resetIfMoved(stop, from: before), stop.category)
        }
        let automatic = grownByImport()
        #expect(automatic.reset)
        #expect(automatic.category == .unclassified)
        let userSet = grownByImport { $0.userOverridden = true }
        #expect(!userSet.reset)
        #expect(userSet.category == .transit)
    }
}
