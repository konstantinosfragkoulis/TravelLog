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

    @Test("the five-stay window counts no blips: a port stay before a ferry's fixes is judged again when the next stay arrives")
    func windowSkipsBlips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, startDay: 0, durationHours: 12, category: .home, hex: "H")
        let earlier = (0..<5).map {
            makeStay(in: ctx, startDay: 1 + Double($0), category: .destination, hex: "J\($0)")
        }
        let port = makeStay(in: ctx, startDay: 5.9, durationHours: 0.75, category: .destination, hex: "P")
        // The ferry's fixes: six 10-minute blips, the newest rows.
        let blips = (0..<6).map {
            makeStay(in: ctx, startDay: 5.95 + Double($0) * 0.01, durationHours: 10.0 / 60,
                     category: .transit, hex: "F\($0)")
        }
        // The far shore: new, unclassified.
        makeStay(in: ctx, startDay: 6.2, category: .unclassified, hex: "N")
        try ctx.save()

        let resetIDs = try await classifier.prepareForReclassification()
        #expect(Set(resetIDs) == Set([port.id] + earlier.suffix(4).map(\.id)))
        #expect(blips.allSatisfy { !resetIDs.contains($0.id) })
    }

    @Test("a stop judged before home came back is judged again when the home stay arrives, by an ordinary pass or a backlog bite: the station before home becomes transit, unless the user set it",
          arguments: [false, true], [false, true])
    func homecomingRejudgesTheStopBeforeIt(userSet: Bool, viaBacklogBite: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        typealias F = TemporaryHomeFixture
        let home: F.Place = (44.3, 12.9)
        _ = F.realHome(ctx, "Home", at: home)
        F.stay(ctx, home, from: F.date(0.2), to: F.date(0.4), .unclassified, hex: "tail-h1", pingCount: 4)
        F.stay(ctx, (45.3, 12.9), from: F.date(1.25), to: F.date(1.6), .unclassified, hex: "tail-c", pingCount: 4)
        // 45 minutes at a station about 7 km out, on the way home.
        let station = F.stay(ctx, (44.36, 12.9), from: F.date(1.7), to: F.date(1.7).addingTimeInterval(45 * 60),
                             .unclassified, hex: "tail-s", pingCount: 3)
        try ctx.save()
        let classifier = await F.classifier(container, squares: [(1, home)])
        await F.ordinaryPass(classifier)
        // With no stay after it yet, the station has no anchor on that side.
        #expect(await classifier.stayCategoryForTesting(station.id) == .destination)
        if userSet {
            let check = ModelContext(container)
            let row = try #require(check.fetch(FetchDescriptor<Stay>()).first { $0.id == station.id })
            row.userOverridden = true
            try check.save()
        }

        // Home arrives; the pre-filter stamps it before Stage 1.5 reads the journey.
        F.stay(ctx, home, from: F.date(1.8), to: F.date(2.2), .unclassified, hex: "tail-h2", pingCount: 4)
        try ctx.save()
        if viaBacklogBite {
            // The foreground drain's default bite: no recent-stay window.
            let bite = await classifier.runBacklogBite(maxStaysPerCall: 200, gate: PipelineGate(forTesting: ()))
            #expect(bite.completed)
        } else {
            await F.ordinaryPass(classifier)
        }
        #expect(await classifier.stayCategoryForTesting(station.id) == (userSet ? .destination : .transit))
    }

    @Test("a later, longer copy of the blip before home, which the user set, does not hide the station before it when home arrives",
          arguments: [false, true])
    func homecomingWalksPastAProtectedTwin(viaBacklogBite: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        typealias F = TemporaryHomeFixture
        let home: F.Place = (44.3, 12.9)
        let road: F.Place = (44.37, 12.9)
        _ = F.realHome(ctx, "Home", at: home)
        F.stay(ctx, home, from: F.date(0.2), to: F.date(0.4), .unclassified, hex: "twin-h1", pingCount: 4)
        F.stay(ctx, (45.3, 12.9), from: F.date(1.25), to: F.date(1.6), .unclassified, hex: "twin-c", pingCount: 4)
        // 45 minutes at a station about 7 km out, then a 10-minute blip on the way home.
        let station = F.stay(ctx, (44.36, 12.9), from: F.date(1.7), to: F.date(1.7).addingTimeInterval(45 * 60),
                             .unclassified, hex: "twin-s", pingCount: 3)
        let blipStart = F.date(1.7).addingTimeInterval(50 * 60)
        let blip = F.stay(ctx, road, from: blipStart, to: blipStart.addingTimeInterval(10 * 60),
                          .unclassified, hex: "twin-b", pingCount: 2)
        try ctx.save()
        let classifier = await F.classifier(container, squares: [(1, home)])
        await F.ordinaryPass(classifier)
        #expect(await classifier.stayCategoryForTesting(station.id) == .destination)

        // A sync brings a later, longer copy of the blip, which the user set;
        // then home arrives.
        let twin = F.stay(ctx, road, from: blipStart.addingTimeInterval(5 * 60),
                          to: blipStart.addingTimeInterval(50 * 60), .destination, hex: "twin-b", pingCount: 2)
        twin.id = blip.id
        twin.userOverridden = true
        F.stay(ctx, home, from: F.date(1.8), to: F.date(2.2), .unclassified, hex: "twin-h2", pingCount: 4)
        try ctx.save()
        if viaBacklogBite {
            let bite = await classifier.runBacklogBite(maxStaysPerCall: 200, gate: PipelineGate(forTesting: ()))
            #expect(bite.completed)
        } else {
            await F.ordinaryPass(classifier)
        }
        // The walk reads the blip at its earlier, 10-minute copy, as the
        // journey test does, and reaches the station.
        #expect(await classifier.stayCategoryForTesting(station.id) == .transit)
        let kept = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first {
            $0.id == blip.id && $0.userOverridden
        })
        #expect(kept.category == .destination)
        await F.ordinaryPass(classifier)
        #expect(await classifier.stayCategoryForTesting(station.id) == .transit)
    }

    @Test("a stop judged before its next stay existed is judged again when a later import brings that stay: the port between two places is transit, as when they are imported together",
          arguments: [false, true])
    func laterImportRejudgesTheStopBeforeIt(separately: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        typealias F = TemporaryHomeFixture
        let classifier = TripClassifier(modelContainer: container)
        func importPass() async {
            // An import's own pass: no recent-stay window.
            let pass = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()), waitingForInFlight: true)
            #expect(pass.completed)
        }
        func farShore() {
            F.stay(ctx, (46.3, 12.9), from: F.date(1.6), to: F.date(2.0), .unclassified,
                   hex: "next-d", pingCount: 1, source: .photoImport)
        }
        // One photo each: a town, then a 40-minute port stop about 55 km on.
        F.stay(ctx, (45.3, 12.9), from: F.date(1.0), to: F.date(1.4), .unclassified,
               hex: "next-c", pingCount: 1, source: .photoImport)
        let port = F.stay(ctx, (45.8, 12.9), from: F.date(1.5), to: F.date(1.5).addingTimeInterval(40 * 60),
                          .unclassified, hex: "next-p", pingCount: 1, source: .photoImport)
        if !separately { farShore() }
        try ctx.save()
        await importPass()
        if separately {
            // With no stay after it yet, the port has no anchor on that side.
            #expect(await classifier.stayCategoryForTesting(port.id) == .destination)
            farShore()
            try ctx.save()
            await importPass()
        }
        #expect(await classifier.stayCategoryForTesting(port.id) == .transit)
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

    @Test("the stop before the latest home, left unclassified by a cancelled pass, is lifted past the backlog")
    func journeyTailLaneIncluded() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        for i in 0..<80 {
            makeStay(in: ctx, startDay: Double(i), category: .unclassified, hex: "B\(i)", source: .photoImport)
        }
        makeStay(in: ctx, startDay: 100, category: .destination, hex: "C")
        let station = makeStay(in: ctx, startDay: 100.5, durationHours: 0.75, category: .unclassified, hex: "S")
        makeStay(in: ctx, startDay: 101, durationHours: 12, category: .home, hex: "H")
        try ctx.save()

        let stationID = station.id
        try await classifier.runIsolated { classifier in
            let batch = try classifier.fetchStage2Batch(cap: 60, priorityIDs: [])
            #expect(batch.map(\.id).contains(stationID))
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
            _ = await TripClassifier(modelContainer: container).classifyAndAssembleTripsWithGates(
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
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

    @Test("another photo inside a photo stop's interval hands it back once its photos span 45 minutes")
    func photoSpanGrowthCrossesBriefStop() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        let start = date(day: 0)
        func grown(to minutes: Double, times: Bool = true) -> (reset: Bool, category: StayCategory) {
            let stop = makeStay(in: ctx, startDay: 0, durationHours: 2, category: .transit, hex: "P",
                                source: .photoImport)
            stop.pingIDs = [UUID(), UUID()]
            let before = [start, start.addingTimeInterval(30 * 60)]
            let inputs = StayClassificationInputs(stop, photoTimes: times ? before : nil)
            // Inside the stored two hours: the interval does not move.
            stop.appendPingID(UUID())
            let after = before + [start.addingTimeInterval(minutes * 60)]
            let reset = StayClassificationInputs.resetIfMoved(stop, from: inputs, photoTimes: times ? after : nil)
            return (reset, stop.category)
        }
        #expect(grown(to: 50) == (true, .unclassified))
        #expect(grown(to: 40) == (false, .transit))
        #expect(grown(to: 50, times: false) == (false, .transit))
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
