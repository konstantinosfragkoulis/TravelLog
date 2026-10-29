//
//  ClassifierOutcomeTests.swift
//  TravelLogTests
//
//  Classifier outcomes follow committed work: an explicit rebuild reports
//  failure instead of success, the back-half launch latch waits for its
//  commit, healing stamps wait for a completed classification, and managed
//  summaries never commit or latch on an unreadable home-place index.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
private final class HealingProbe {
    var healCalls = 0
    var classifyCalls = 0
    var fingerprintCalls = 0
}

@MainActor
@Suite("Classifier outcomes", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct ClassifierOutcomeTests {
    private static let base = Date(timeIntervalSince1970: 1_682_460_800)

    @discardableResult
    private func destination(_ context: ModelContext, hours offset: Double, key: String,
                             category: StayCategory? = .destination) -> Stay {
        let start = Self.base.addingTimeInterval(offset * 3600)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: key,
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        if let category { stay.category = category }
        stay.locality = "Athens"
        stay.country = "Greece"
        context.insert(stay)
        return stay
    }

    /// One completed, non-edited trip with a hidden-photo annotation.
    private func rebuildFixture() throws -> (ModelContainer, UUID, PersistentIdentifier, UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "outcome-rebuild")
        let trip = Trip(startDate: stay.startTime)
        trip.customName = "Outcome fixture"
        trip.isComplete = true
        trip.endDate = stay.endTime
        context.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(HiddenPhoto(localIdentifier: "outcome-photo", tripID: trip.id))
        try context.save()
        return (container, trip.id, trip.persistentModelID, stay.id)
    }

    private func expectRetained(_ container: ModelContainer, tripID: UUID,
                                identifier: PersistentIdentifier, stayID: UUID) throws {
        let check = ModelContext(container)
        let trips = try check.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.id) == [tripID])
        #expect(trips.first?.persistentModelID == identifier)
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    // MARK: - Explicit rebuild outcome

    @Test("a failed reset read aborts the rebuild before any mutation", arguments: ["trips", "stays"])
    func rebuildResetReadFailureAbortsBeforeMutation(table: String) async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failRebuildResetTripFetchForTesting = table == "trips"
        classifier.failRebuildResetStayFetchForTesting = table == "stays"
        defer {
            classifier.failRebuildResetTripFetchForTesting = false
            classifier.failRebuildResetStayFetchForTesting = false
        }

        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
            Issue.record("A failed reset read must not reach replacement")
        })

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
        let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(stay.category == .destination)
    }

    @Test("a failed reset save skips the driver")
    func rebuildResetSaveFailureSkipsDriver() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let seed = ModelContext(container)
        let pending = destination(seed, hours: 48, key: "outcome-pending", category: nil)
        try seed.save()
        let pendingID = pending.id
        let classifier = TripClassifier(modelContainer: container)

        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeResetSave: {
            throw CocoaError(.fileWriteUnknown)
        })

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(rows.first { $0.id == stayID }?.category == .destination)
        // The ordinary driver would have classified this stay.
        #expect(rows.first { $0.id == pendingID }?.category == .unclassified)
    }

    @Test("a failed detach read rolls the replacement back and reports failure")
    func rebuildDetachReadFailureReportsFailed() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failRebuildDetachFetchForTesting = true
        defer { classifier.failRebuildDetachFetchForTesting = false }

        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
            Issue.record("A failed detach read must skip the replacement save")
        })

        #expect(outcome == .failed)
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        // The committed reset stands; identities and annotations are retained.
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
    }

    @Test("a failed preparation after a committed reset reports failure")
    func rebuildPreparationFailureReportsFailed() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failHomeReadForTesting = true
        defer { classifier.failHomeReadForTesting = false }

        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
            Issue.record("A failed preparation must skip the replacement save")
        })

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
    }

    @Test("a completed rebuild reports completion and restores the trip identity")
    func rebuildCompletes() async throws {
        let (container, tripID, _, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        #expect(outcome == .completed)
        #expect(await classifier.baselinePassPending() == false)
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    @Test("a member reset between a rebuild's units is settled, so the trip keeps its identity")
    func rebuildSettlesMemberResetBetweenUnits() async throws {
        let (container, tripID, _, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        // A photo import grows the stay across a duration band and resets it
        // while it stays attached, after the classification unit committed.
        let outcome = await TripClassifier.SaveTestHook.$betweenPassUnits.withValue({
            await MainActor.run {
                let context = ModelContext(container)
                guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == stayID }) else {
                    Issue.record("Missing seeded stay"); return
                }
                stay.category = .unclassified
                do { try context.save() } catch { Issue.record(error) }
            }
        }) {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome == .completed)
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
        #expect(try category(stayID, in: container) == .destination)
    }

    /// One completed, non-edited trip of three stays with a hidden-photo annotation.
    private func threeStayRebuildFixture() throws -> (ModelContainer, UUID, [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stays = [0.0, 12, 24].enumerated().map { index, hours in
            destination(context, hours: hours, key: "outcome-unit-\(index)")
        }
        let trip = Trip(startDate: stays[0].startTime)
        trip.isComplete = true
        trip.endDate = stays[2].endTime
        context.insert(trip)
        for (index, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = index
        }
        context.insert(HiddenPhoto(localIdentifier: "outcome-unit-photo", tripID: trip.id))
        try context.save()
        return (container, trip.id, stays.map(\.id))
    }

    @Test("an uncapped rebuild settles its backlog in bounded units and still restores the trip identity")
    func rebuildSettlesBacklogInBoundedUnits() async throws {
        let (container, tripID, stayIDs) = try threeStayRebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setUncappedStage2UnitSizeForTesting(1)
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await TripClassifier.SaveTestHook.$beforeSave.withValue({
            saves.withLock { $0 += 1 }
        }) {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome == .completed)
        // One save per classification unit at least: three stays, one per unit.
        #expect(saves.withLock { $0 } >= 3)
        let check = ModelContext(container)
        let restored = try #require(try check.fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        #expect(!(restored.stays ?? []).isEmpty)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
        for stayID in stayIDs {
            #expect(try category(stayID, in: container) != .unclassified)
        }
    }

    @Test("Delete All Data between an uncapped pass's units stops it before the next")
    func revocationBetweenBoundedUnitsStopsThePass() async throws {
        let (container, tripID, stayIDs) = try threeStayRebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setUncappedStage2UnitSizeForTesting(1)
        let gate = PipelineGate(forTesting: ())
        // Three pre-filter units commit, then the wipe revokes the pass as
        // its first classification unit commits.
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await TripClassifier.SaveTestHook.$beforeSave.withValue({
            if saves.withLock({ $0 += 1; return $0 }) == 4 { gate.revokeQueuedPasses() }
        }) {
            await classifier.reclassifyAll(gate: gate, beforeReplacementSave: {
                Issue.record("A revoked pass must not reach replacement")
            })
        }
        #expect(outcome == .failed)
        #expect(try category(stayIDs[0], in: container) != .unclassified)
        #expect(try category(stayIDs[1], in: container) == .unclassified)
        #expect(try category(stayIDs[2], in: container) == .unclassified)
        // The trip keeps its identity, members and annotation until a replacement commits.
        let check = ModelContext(container)
        let trips = try check.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.id) == [tripID])
        #expect(Set((trips.first?.stays ?? []).map(\.id)) == Set(stayIDs))
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    /// A Home at the origin, and a completed trip whose last stop, 40
    /// minutes 7 km out, comes just before a two-hour stay back home.
    private func homecomingRebuildFixture() throws -> (ModelContainer, [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 2,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        // Hours after `base`, minutes, latitude, category.
        let rows: [(Double, Double, Double, StayCategory)] = [
            (10, 360, 1, .destination), (17, 40, 0.063, .destination), (18, 120, 0, .home),
        ]
        let stays = rows.enumerated().map { index, row in
            let start = Self.base.addingTimeInterval(row.0 * 3600)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(row.1 * 60),
                centroidLatitude: row.2, centroidLongitude: 0, h3IndexRes6: "homecoming-\(index)",
                pingCount: 2, distanceFromHomeKm: row.2 * 111, pingIDs: [])
            stay.category = row.3
            context.insert(stay)
            return stay
        }
        let trip = Trip(startDate: stays[0].startTime)
        trip.isComplete = true
        trip.endDate = stays[1].endTime
        context.insert(trip)
        for (index, stay) in stays.prefix(2).enumerated() {
            stay.trip = trip
            stay.orderInTrip = index
        }
        try context.save()
        return (container, stays.map(\.id))
    }

    @Test("a rebuild classifies alike whatever its unit size: a homecoming in a later unit still makes the stop before it transit")
    func rebuildCategoriesIgnoreUnitBoundaries() async throws {
        var outcomes: [[StayCategory?]] = []
        for size in [1, 2, Int.max] {
            let (container, ids) = try homecomingRebuildFixture()
            let classifier = TripClassifier(modelContainer: container)
            await classifier.setUncappedStage2UnitSizeForTesting(size)
            let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
            #expect(outcome == .completed)
            outcomes.append(try ids.map { try category($0, in: container) })
        }
        #expect(outcomes.first == [.destination, .transit, .home])
        #expect(outcomes.allSatisfy { $0 == outcomes.first })
    }

    /// A Home at the origin and two six-hour stays, a day apart, at `latitudes`.
    private func unitHomeFixture(latitudes: [Double]) throws -> (ModelContainer, [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        let ids = latitudes.enumerated().map { index, latitude in
            let start = Self.base.addingTimeInterval(Double(index) * 86_400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
                centroidLatitude: latitude, centroidLongitude: 0, h3IndexRes6: "unit-home-\(index)",
                pingCount: 2, distanceFromHomeKm: latitude * 111, pingIDs: [])
            context.insert(stay)
            return stay.id
        }
        try context.save()
        return (container, ids)
    }

    @Test("an uncapped pass's first unit pre-filters only its own rows")
    func firstUnitPreFiltersOnlyItsRows() async throws {
        let (container, ids) = try unitHomeFixture(latitudes: [0, 0])
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setUncappedStage2UnitSizeForTesting(1)
        let gate = PipelineGate(forTesting: ())
        // Delete All Data as the first unit commits: what it stamped is all it did.
        let result = await TripClassifier.SaveTestHook.$beforeSave.withValue({
            gate.revokeQueuedPasses()
        }) {
            await classifier.runPipelineStagesWithGates(reclassifyRecentStays: false, gate: gate)
        }
        #expect(!result.completed)
        #expect(try category(ids[0], in: container) == .home)
        #expect(try category(ids[1], in: container) == .unclassified)
    }

    @Test("a later unit of an uncapped pass pre-filters its stays as they are now")
    func laterUnitPreFiltersFreshRows() async throws {
        let (container, ids) = try unitHomeFixture(latitudes: [2, 2])
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setUncappedStage2UnitSizeForTesting(1)
        let moving = ids[1]
        // A photo attachment moves the second stay home while the first unit commits.
        let result = await TripClassifier.SaveTestHook.$beforeSave.withValue({
            let context = ModelContext(container)
            guard let row = try context.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == moving }),
                  row.centroidLatitude != 0 else { return }
            row.centroidLatitude = 0
            row.distanceFromHomeKm = 0
            try context.save()
        }) {
            await classifier.runPipelineStagesWithGates(reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))
        }
        #expect(result.completed)
        #expect(try category(ids[0], in: container) != .unclassified)
        #expect(try category(moving, in: container) == .home)
    }

    @Test("classification units hold at most their size, with a UUID's copies together")
    func classificationUnitsNeverOverflow() throws {
        func stay(_ id: UUID) -> Stay {
            let stay = Stay(startTime: Self.base, endTime: Self.base.addingTimeInterval(3600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "units",
                pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            stay.id = id
            return stay
        }
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        // A two-copy cohort that would overflow the open unit starts the next.
        #expect(TripClassifier.classificationUnits([stay(a), stay(b), stay(c), stay(c)], size: 3)
            == [[a, b], [c]])
        // A cohort larger than a unit takes one of its own.
        #expect(TripClassifier.classificationUnits(
            [stay(a), stay(d), stay(d), stay(d), stay(b)], size: 2) == [[a], [d], [b]])
        #expect(TripClassifier.classificationUnits([stay(a), stay(b), stay(c)], size: 2) == [[a, b], [c]])
    }

    @Test("an empty store rebuild completes")
    func emptyRebuildCompletes() async throws {
        let classifier = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        let outcome = await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        #expect(outcome == .completed)
    }

    @Test("a rebuild cancelled before admission resets nothing, even with a free latch")
    func cancelledRebuildResetsNothing() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }.value
        #expect(outcome == .cancelled)
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
        let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(stay.category == .destination)
    }

    // MARK: - Completion and the launch latch

    /// An ongoing trip whose start and member order are stale; the baseline
    /// back half repairs both.
    private func staleOngoingFixture() throws -> (ModelContainer, [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = destination(context, hours: 0, key: "stale-first")
        let second = destination(context, hours: 24, key: "stale-second")
        let trip = Trip(startDate: second.startTime)
        context.insert(trip)
        first.trip = trip
        first.orderInTrip = 1
        second.trip = trip
        second.orderInTrip = 0
        try context.save()
        return (container, [first.id, second.id])
    }

    private func orderedMembers(_ container: ModelContainer, _ ids: [UUID]) throws
        -> (orders: [Int?], tripStart: Date?, sameTrip: Bool) {
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let members = ids.compactMap { id in stays.first { $0.id == id } }
        let tripIDs = Set(members.compactMap { $0.trip?.id })
        return (members.map(\.orderInTrip), members.first?.trip?.startDate, tripIDs.count == 1)
    }

    @Test("a failed ordinary final save rolls the unit back and re-arms the baseline pass")
    func ordinaryFinalSaveFailureReArmsBaselineAndRollsBack() async throws {
        let (container, ids) = try staleOngoingFixture()
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = PipelineGate(forTesting: ())
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: gate, beforeSave: {
                let call = calls.withLock { $0 += 1; return $0 }
                if call >= 2 { throw CocoaError(.fileWriteUnknown) }
            })
        #expect(calls.withLock { $0 } == 2, "Preparation, then one checked final save")
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let stale = try orderedMembers(container, ids)
        #expect(stale.orders == [1, 0])
        #expect(stale.tripStart == Self.base.addingTimeInterval(24 * 3600))

        let healed = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: gate)
        #expect(healed)
        #expect(await classifier.baselinePassPending() == false)
        let repaired = try orderedMembers(container, ids)
        #expect(repaired.sameTrip)
        #expect(repaired.orders == [0, 1])
        #expect(repaired.tripStart == Self.base)
    }

    @Test("failed back-half reads roll back and leave the pass incomplete",
          arguments: ["sanity", "closure", "summary"])
    func backHalfReadFailureRollsBack(read: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Stage 2.5 demotes this short daytime airport destination to
        // transit and recomputes its trip's summary.
        let stay = destination(context, hours: 12, key: "back-half-read")
        stay.isAirport = true
        let trip = Trip(startDate: stay.startTime)
        context.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        try context.save()
        let stayID = stay.id
        let classifier = TripClassifier(modelContainer: container)
        classifier.failSanityFetchForTesting = read == "sanity"
        classifier.failStaleClosureFetchForTesting = read == "closure"
        let completed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(read == "summary") {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        }
        classifier.failSanityFetchForTesting = false
        classifier.failStaleClosureFetchForTesting = false

        #expect(!completed)
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var retained = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(retained.category == .destination)

        let recovered = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        #expect(recovered)
        #expect(await classifier.baselinePassPending() == false)
        retained = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(retained.category == .transit)
    }

    @Test("a failed classification save rolls its unit back and leaves the pass incomplete")
    func stage2SaveFailureReportsIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "stage2-failure", category: nil)
        try context.save()
        let stayID = stay.id
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let completed = await classifier.classifyAndAssembleTripsQueuedWithGates(
            gate: PipelineGate(forTesting: ()), beforeSave: {
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { throw CocoaError(.fileWriteUnknown) }
            })
        #expect(!completed)
        #expect(calls.withLock { $0 } == 1, "a failed classification unit stops the pass before assembly")
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID }?.category == .unclassified)
    }

    @Test("a failed Stage 2 batch read rolls preparation back and reports incomplete")
    func stage2BatchReadFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        // Pre-filter stamps this stay .home before the batch read.
        let atHome = Stay(startTime: Self.base, endTime: Self.base.addingTimeInterval(6 * 86_400),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "batch-read",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(atHome)
        try context.save()
        let stayID = atHome.id
        let classifier = TripClassifier(modelContainer: container)
        classifier.failStage2BatchFetchForTesting = true
        let completed = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        classifier.failStage2BatchFetchForTesting = false
        #expect(!completed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID }?.category == .unclassified)
    }

    @Test("a cancelled pass whose save fails rolls back instead of leaving pending changes")
    func cancelledPreparationSaveFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        let atHome = Stay(startTime: Self.base, endTime: Self.base.addingTimeInterval(6 * 86_400),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "cancel-save",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(atHome)
        try context.save()
        let stayID = atHome.id
        let classifier = TripClassifier(modelContainer: container)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()), beforeSave: {
                    throw CocoaError(.fileWriteUnknown)
                })
        }.value
        #expect(result.needsPublication)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID }?.category == .unclassified)
    }

    // MARK: - Healing stamps wait for completed classification

    private func stampedDefaults(_ name: String) throws -> (UserDefaults, String, Data, Date) {
        let suiteName = "\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let staleCoverage = try JSONEncoder().encode([
            TripClassifier.CoverageDisc(latitude: 1, longitude: 1, radiusKm: 1),
        ])
        let staleStamp = Date(timeIntervalSinceReferenceDate: 789)
        defaults.set("stale-fingerprint", forKey: HomeAreaHealing.fingerprintKey)
        defaults.set(staleCoverage, forKey: HomeAreaHealing.coverageKey)
        defaults.set(staleStamp, forKey: HomeAreaHealing.coverageStampedAtKey)
        return (defaults, suiteName, staleCoverage, staleStamp)
    }

    private func expectUnstamped(_ defaults: UserDefaults, coverage: Data, stamp: Date) {
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "stale-fingerprint")
        #expect(defaults.data(forKey: HomeAreaHealing.coverageKey) == coverage)
        #expect(defaults.object(forKey: HomeAreaHealing.coverageStampedAtKey) as? Date == stamp)
    }

    private func stages(_ probe: HealingProbe,
                        fingerprint: @escaping @MainActor @Sendable (Int) -> String? = { _ in "current-fingerprint" },
                        classify: @escaping @MainActor @Sendable () async -> Bool) -> HomeAreaHealing.Stages {
        HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: {
                probe.fingerprintCalls += 1
                return fingerprint(probe.fingerprintCalls)
            },
            heal: { _ in
                probe.healCalls += 1
                return .init(moved: 0, failed: false)
            },
            drainParked: { [] },
            classify: {
                probe.classifyCalls += 1
                return await classify()
            },
            generateTitles: {},
            coverage: { [] },
            bumpChanges: {},
            reloadWidgets: {})
    }

    @Test("an incomplete classification keeps both stamps, and a completed retry stamps")
    func incompleteClassificationLeavesStamps() async throws {
        let (defaults, suiteName, coverage, stamp) = try stampedDefaults("HealIncomplete")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = HealingProbe()
        // The maintenance unit itself finished: the post-import token contract holds.
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults,
            stages: stages(probe, classify: { false })))
        #expect(probe.healCalls == 1)
        expectUnstamped(defaults, coverage: coverage, stamp: stamp)

        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults,
            stages: stages(probe, classify: { true })))
        #expect(probe.healCalls == 2)
        let emptyCoverage = try JSONEncoder().encode([TripClassifier.CoverageDisc]())
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "current-fingerprint")
        #expect(defaults.data(forKey: HomeAreaHealing.coverageKey) == emptyCoverage)
    }

    @Test("inputs that move while classification runs keep the old snapshot")
    func movedFingerprintLeavesStamps() async throws {
        let (defaults, suiteName, coverage, stamp) = try stampedDefaults("HealMoved")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = HealingProbe()
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults,
            stages: stages(probe, fingerprint: { "fingerprint-\($0)" }, classify: { true })))
        #expect(probe.fingerprintCalls == 2)
        expectUnstamped(defaults, coverage: coverage, stamp: stamp)
    }

    @Test("healing finalization queues behind a busy classifier and stamps after it completes")
    func busyClassifierQueuesHealingFinalization() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let freed = destination(context, hours: 0, key: "heal-queued", category: nil)
        try context.save()
        let freedID = freed.id
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)
        let (defaults, suiteName, coverage, stamp) = try stampedDefaults("HealQueued")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = HealingProbe()
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let healStages = stages(probe, classify: {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        })
        let healing = Task {
            await TripClassifier.QueueTestHook.$waiting.withValue({ _ = signal.yield() }) {
                await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: healStages)
            }
        }
        var iterator = waiting.makeAsyncIterator()
        let queued = await iterator.next() != nil
        #expect(queued, "queued classification never reached its wait")
        // Still waiting: nothing classified, nothing stamped.
        expectUnstamped(defaults, coverage: coverage, stamp: stamp)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == freedID }?.category == .unclassified)

        await classifier.setRunningLatchForTesting(false)
        #expect(await healing.value)
        signal.finish()
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == freedID }?.category != .unclassified)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "current-fingerprint")
    }

    @Test("cancellation while queued leaves both stamps")
    func cancelledQueuedClassificationLeavesStamps() async throws {
        let classifier = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        await classifier.setRunningLatchForTesting(true)
        let (defaults, suiteName, coverage, stamp) = try stampedDefaults("HealCancelled")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = HealingProbe()
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let healStages = stages(probe, classify: {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        })
        let healing = Task {
            await TripClassifier.QueueTestHook.$waiting.withValue({ _ = signal.yield() }) {
                await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: healStages)
            }
        }
        var iterator = waiting.makeAsyncIterator()
        let queued = await iterator.next() != nil
        #expect(queued, "queued classification never reached its wait")
        healing.cancel()
        _ = await healing.value
        signal.finish()
        await classifier.setRunningLatchForTesting(false)
        #expect(probe.classifyCalls == 1)
        expectUnstamped(defaults, coverage: coverage, stamp: stamp)
    }

    @Test("coverage fails instead of stamping a stale orbit memo when homes are unreadable")
    func coveragePrimeFailureThrows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        _ = try await classifier.homeAreaCoverage()
        classifier.failHomeReadForTesting = true
        defer { classifier.failHomeReadForTesting = false }
        await #expect(throws: (any Error).self) {
            _ = try await classifier.homeAreaCoverage()
        }
    }

    // MARK: - Pre-filter reads and discarded batches decide completion

    private func category(_ id: UUID, in container: ModelContainer) throws -> StayCategory? {
        try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == id }?.category
    }

    @Test("a failed pre-filter read rolls preparation back instead of defaulting a home stay to destination")
    func preFilterReadFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: Self.base.addingTimeInterval(-86_400 * 100)))
        // Six hours at home: ambiguous for Stage 2a, so only Stage 1 makes it .home.
        let atHome = Stay(startTime: Self.base, endTime: Self.base.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "prefilter-read",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(atHome)
        try context.save()
        let stayID = atHome.id
        let classifier = TripClassifier(modelContainer: container)
        classifier.failPreFilterStayFetchForTesting = true
        let completed = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        classifier.failPreFilterStayFetchForTesting = false
        #expect(!completed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try category(stayID, in: container) == .unclassified)

        let recovered = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        #expect(recovered)
        #expect(try category(stayID, in: container) == .home)
    }

    // MARK: - Home-place reads are required for once-only writers

    /// A completed Aegina trip whose ferry-port wait reads "Athens", the home.
    private func homeNamedFixture() throws -> (ModelContainer, UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: 37.98, longitude: 23.72,
            startedAt: Self.base.addingTimeInterval(-86_400 * 400))
        home.locality = "Athens"
        context.insert(home)
        let aegina = destination(context, hours: 0, key: "aegina")
        aegina.locality = "Aegina"
        aegina.endTime = aegina.startTime.addingTimeInterval(48 * 3600)
        aegina.durationMinutes = 48 * 60
        let port = destination(context, hours: 60, key: "port")
        let trip = Trip(startDate: aegina.startTime)
        trip.isComplete = true
        trip.endDate = port.endTime
        trip.destinationSummary = "Aegina"
        context.insert(trip)
        aegina.trip = trip
        aegina.orderInTrip = 0
        port.trip = trip
        port.orderInTrip = 1
        try context.save()
        return (container, trip.id)
    }

    @Test("metro refresh neither saves nor reports success on an unreadable home-place index")
    func metroRefreshWithUnreadableHomeIndexDoesNotLatch() async throws {
        let (container, tripID) = try homeNamedFixture()
        let failed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        }
        // The runner latches only on `saved`.
        #expect(!failed.saved)
        var trip = try #require(ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        #expect(trip.destinationSummary == "Aegina")

        let recovered = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        #expect(recovered.saved)
        trip = try #require(ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        #expect(trip.destinationSummary == "Aegina")
    }

    @Test("a genuinely empty home-place index is absence, not failure")
    func emptyHomeIndexIsAuthoritative() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "no-home")
        let trip = Trip(startDate: stay.startTime)
        context.insert(trip)
        stay.trip = trip
        #expect(trip.recomputeSummary())
        #expect(trip.destinationSummary == "Athens")
        #expect(try TripTitleStore.homePlaceNames(
            tripStart: stay.startTime, tripEnd: stay.endTime, in: context).isEmpty)
        // An unmanaged trip keeps every name by design and is not a failure.
        #expect(Trip(startDate: stay.startTime).recomputeSummary())
    }

    @Test("restore rolls back and keeps its record on an unreadable home-place index")
    func restoreWithUnreadableHomeIndexRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "restore-index", category: .home)
        try context.save()
        let record = DissolvedTripRecord(
            id: UUID(), dissolvedAt: .now, displayName: "Retry Me",
            startDate: stay.startTime, endDate: stay.endTime, isComplete: true,
            destinationSummary: "Athens", countryCodes: "GR",
            classifiedByAI: false, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(id: stay.id, categoryRaw: "destination", orderInTrip: 0)])
        let classifier = TripClassifier(modelContainer: container)

        let failed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await classifier.restoreDissolvedTrip(record, markStaysSacred: false)
        }
        #expect(failed == .saveFailed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>()).isEmpty)
        let parked = try #require(verify.fetch(FetchDescriptor<Stay>()).first)
        #expect(parked.trip == nil)
        #expect(parked.category == .home)

        #expect(await classifier.restoreDissolvedTrip(record, markStaysSacred: false) == .restored)
        verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>()).map(\.id) == [record.id])
    }

    @Test("title generation fails closed on an unreadable home-place index")
    func titleGenerationWithUnreadableHomeIndexWritesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "title-index")
        let trip = Trip(startDate: stay.startTime)
        trip.isComplete = true
        trip.endDate = stay.endTime
        context.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        try context.save()
        let tripID = trip.id
        let classifier = TripClassifier(modelContainer: container)

        let generated = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await classifier.generateTitlesStage(maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ()))
        }
        #expect(generated == 0)
        #expect(await classifier.canonicalTitleForTesting(tripID: tripID) == nil)

        let recovered = await classifier.generateTitlesStage(maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ()))
        #expect(recovered == 1)
        #expect(await classifier.canonicalTitleForTesting(tripID: tripID) == "Athens")
    }
}
