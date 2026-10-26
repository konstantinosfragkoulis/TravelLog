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

    private func respondDestination<T: Sendable>(
        _ body: () async -> T
    ) async -> T {
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                [.init(stayIndex: 0, category: "destination")]
            }) {
                await body()
            }
        }
    }

    // MARK: - Explicit rebuild outcome

    @Test("a failed reset read aborts the rebuild before any mutation", arguments: ["trips", "stays"])
    func rebuildResetReadFailureAbortsBeforeMutation(table: String) async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: tripID))
        await classifier.markCanonicalTitleFailureForTesting(shape)
        classifier.failRebuildResetTripFetchForTesting = table == "trips"
        classifier.failRebuildResetStayFetchForTesting = table == "stays"
        defer {
            classifier.failRebuildResetTripFetchForTesting = false
            classifier.failRebuildResetStayFetchForTesting = false
        }

        let outcome = await respondDestination {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
                Issue.record("A failed reset read must not reach replacement")
            })
        }

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(await classifier.hasCanonicalTitleFailureForTesting(shape))
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
        let stay = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(stay.category == .destination)
    }

    @Test("a failed reset save skips the driver and keeps title budgets")
    func rebuildResetSaveFailureSkipsDriver() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let seed = ModelContext(container)
        let pending = destination(seed, hours: 48, key: "outcome-pending", category: nil)
        try seed.save()
        let pendingID = pending.id
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: tripID))
        await classifier.markCanonicalTitleFailureForTesting(shape)

        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeResetSave: {
                throw CocoaError(.fileWriteUnknown)
            })
        }

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(await classifier.hasCanonicalTitleFailureForTesting(shape))
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

        let outcome = await respondDestination {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
                Issue.record("A failed detach read must skip the replacement save")
            })
        }

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

        let outcome = await respondDestination {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()), beforeReplacementSave: {
                Issue.record("A failed preparation must skip the replacement save")
            })
        }

        #expect(outcome == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        try expectRetained(container, tripID: tripID, identifier: identifier, stayID: stayID)
    }

    @Test("a completed rebuild reports completion and restores the trip identity")
    func rebuildCompletes() async throws {
        let (container, tripID, _, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await respondDestination {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome == .completed)
        #expect(await classifier.baselinePassPending() == false)
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    @Test("an empty store rebuild completes")
    func emptyRebuildCompletes() async throws {
        let classifier = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome == .completed)
    }

    @Test("a rebuild cancelled before admission resets nothing, even with a free latch")
    func cancelledRebuildResetsNothing() async throws {
        let (container, tripID, identifier, stayID) = try rebuildFixture()
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: tripID))
        await classifier.markCanonicalTitleFailureForTesting(shape)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
        }.value
        #expect(outcome == .cancelled)
        #expect(await classifier.hasCanonicalTitleFailureForTesting(shape))
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
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate, beforeSave: {
                    let call = calls.withLock { $0 += 1; return $0 }
                    if call >= 2 { throw CocoaError(.fileWriteUnknown) }
                })
        }
        #expect(calls.withLock { $0 } == 2, "Preparation, then one checked final save")
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let stale = try orderedMembers(container, ids)
        #expect(stale.orders == [1, 0])
        #expect(stale.tripStart == Self.base.addingTimeInterval(24 * 3600))

        let healed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: gate)
        }
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
        // Stage 2.5 demotes this short airport destination to transit and
        // recomputes its trip's summary.
        let stay = destination(context, hours: 0, key: "back-half-read")
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
        let completed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(read == "summary") {
                await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
            }
        }
        classifier.failSanityFetchForTesting = false
        classifier.failStaleClosureFetchForTesting = false

        #expect(!completed)
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var retained = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(retained.category == .destination)

        let recovered = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        }
        #expect(recovered)
        #expect(await classifier.baselinePassPending() == false)
        retained = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(retained.category == .transit)
    }

    @Test("a failed Stage 2 batch save leaves the pass incomplete even when assembly commits")
    func stage2SaveFailureReportsIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = destination(context, hours: 0, key: "stage2-failure", category: nil)
        try context.save()
        let stayID = stay.id
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let completed = await respondDestination {
            await classifier.classifyAndAssembleTripsQueuedWithGates(
                gate: PipelineGate(forTesting: ()), beforeSave: {
                    let call = calls.withLock { $0 += 1; return $0 }
                    if call == 2 { throw CocoaError(.fileWriteUnknown) }
                })
        }
        #expect(!completed)
        #expect(calls.withLock { $0 } == 3, "Preparation, the failed batch, then the final commit")
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
        let completed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        }
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
            return await StayClassificationInference.TestHook.$availability.withValue(false) {
                await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                    reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()), beforeSave: {
                        throw CocoaError(.fileWriteUnknown)
                    })
            }
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
                await StayClassificationInference.TestHook.$availability.withValue(false) {
                    await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: healStages)
                }
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
        let completed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        }
        classifier.failPreFilterStayFetchForTesting = false
        #expect(!completed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try category(stayID, in: container) == .unclassified)

        let recovered = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        }
        #expect(recovered)
        #expect(try category(stayID, in: container) == .home)
    }

    @Test("a batch rejected after inference leaves the healing stamps, and a steady retry stamps")
    func rejectedInferenceLeavesHealingStamps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let freed = destination(context, hours: 0, key: "heal-rejected", category: nil)
        try context.save()
        let freedID = freed.id
        let classifier = TripClassifier(modelContainer: container)
        let (defaults, suiteName, coverage, stamp) = try stampedDefaults("HealRejected")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = HealingProbe()
        let healStages = stages(probe, classify: {
            await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
        })
        // Locality enrichment lands while the model answers: classification
        // evidence moves, orbit geometry (the fingerprint) does not.
        let maintained = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                await MainActor.run {
                    let context = ModelContext(container)
                    guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == freedID }) else {
                        Issue.record("Missing seeded stay"); return
                    }
                    stay.locality = "Gérakas"
                    do { try context.save() } catch { Issue.record(error) }
                }
                return [.init(stayIndex: 0, category: "destination")]
            }) {
                await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: healStages)
            }
        }
        #expect(maintained, "the heal unit itself finished")
        #expect(try category(freedID, in: container) == .unclassified)
        expectUnstamped(defaults, coverage: coverage, stamp: stamp)

        let retried = await respondDestination {
            await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: healStages)
        }
        #expect(retried)
        #expect(probe.healCalls == 2, "unchanged stamps re-arm the heal")
        #expect(try category(freedID, in: container) == .destination)
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == "current-fingerprint")
    }

    @Test("a batch made obsolete before its inference leaves the pass incomplete")
    func obsoleteBatchLeavesPassIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 24 ambiguous stays: two plans. The last stay lies only in the
        // second plan's windows (the first reaches three stays past its 20).
        let ids = (0..<24).map { destination(context, hours: Double($0) * 12, key: "obsolete-\($0)", category: nil).id }
        try context.save()
        let lastID = try #require(ids.last)
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let respond: @Sendable (String) async throws -> [StayClassificationInference.Classification] = { prompt in
            let call = prompts.withLock { $0 += 1; return $0 }
            if call == 1 {
                await MainActor.run {
                    let context = ModelContext(container)
                    guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == lastID }) else {
                        Issue.record("Missing seeded stay"); return
                    }
                    stay.locality = "Gérakas"
                    do { try context.save() } catch { Issue.record(error) }
                }
            }
            let count = prompt.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            return (0..<count).map { StayClassificationInference.Classification(stayIndex: $0, category: "destination") }
        }
        let classifier = TripClassifier(modelContainer: container)
        func run() async -> Bool {
            await StayClassificationInference.TestHook.$availability.withValue(true) {
                await StayClassificationInference.TestHook.$response.withValue(respond) {
                    await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
                }
            }
        }

        #expect(await run() == false, "the second plan's stays are still pending")
        #expect(prompts.withLock { $0 } == 1, "the obsolete plan never reached the model")
        #expect(try ids.suffix(4).map { try category($0, in: container) }.allSatisfy { $0 == .unclassified })

        #expect(await run())
        let check = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(check.count == 24)
        #expect(check.allSatisfy { $0.category != .unclassified })
    }

    @Test("a rebuild whose later batch is made obsolete still completes and titles its trips")
    func rebuildWithObsoleteBatchCompletes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // One untitled trip plus 24 unattached stays after it: 25 reset stays,
        // two plans. The last stay lies only in the second plan's windows.
        let member = destination(context, hours: 0, key: "rebuild-obsolete-member")
        let trip = Trip(startDate: member.startTime)
        trip.isComplete = true
        trip.endDate = member.endTime
        context.insert(trip)
        member.trip = trip
        member.orderInTrip = 0
        let ids = (0..<24).map { destination(context, hours: 24 + Double($0) * 12, key: "rebuild-obsolete-\($0)").id }
        try context.save()
        let tripID = trip.id
        let lastID = try #require(ids.last)
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        // A live writer (locality enrichment, the foreground fast path)
        // rewrites a later window's row while the first batch is inferring.
        let respond: @Sendable (String) async throws -> [StayClassificationInference.Classification] = { prompt in
            let call = prompts.withLock { $0 += 1; return $0 }
            if call == 1 {
                await MainActor.run {
                    let context = ModelContext(container)
                    guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == lastID }) else {
                        Issue.record("Missing seeded stay"); return
                    }
                    stay.locality = "Gérakas"
                    do { try context.save() } catch { Issue.record(error) }
                }
            }
            let count = prompt.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            return (0..<count).map { StayClassificationInference.Classification(stayIndex: $0, category: "destination") }
        }
        let classifier = TripClassifier(modelContainer: container)
        let titleCalls = OSAllocatedUnfairLock(initialState: 0)
        await classifier.setTitleGenerationOverrideForTesting { _ in
            titleCalls.withLock { $0 += 1 }
            return nil
        }

        let outcome = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue(respond) {
                await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()))
            }
        }

        #expect(outcome == .completed, "the replacement committed; the discard is ordinary CAS work")
        let card = TripsListView.computeFMUpgradeCardState(after: outcome)
        #expect(card.dismiss)
        #expect(!card.showFailure)
        #expect(prompts.withLock { $0 } == 1, "the obsolete plan never reached the model")
        #expect(titleCalls.withLock { $0 } > 0, "titles follow the committed rebuild")
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ids.suffix(5).map { try category($0, in: container) }.allSatisfy { $0 == .unclassified })
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).contains { $0.id == tripID })

        // The next ordinary pass classifies the leftovers.
        let settled = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue(respond) {
                await classifier.classifyAndAssembleTripsQueuedWithGates(gate: PipelineGate(forTesting: ()))
            }
        }
        #expect(settled)
        let check = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(check.count == 25)
        #expect(check.allSatisfy { $0.category != .unclassified })
        await classifier.setTitleGenerationOverrideForTesting(nil)
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

    @Test("title generation fails closed on an unreadable home-place index without spending budget")
    func titleGenerationWithUnreadableHomeIndexSpendsNothing() async throws {
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
        let probe = OSAllocatedUnfairLock(initialState: false)
        await classifier.setTitleGenerationOverrideForTesting { _ in
            probe.withLock { $0 = true }
            return "Athens After Dark"
        }
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: tripID))
        let source = try #require(await classifier.canonicalTitleSourceStateForTesting(tripID: tripID))

        let generated = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await classifier.generateTitlesStage(maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ()))
        }
        #expect(generated == 0)
        #expect(!probe.withLock { $0 })
        let applied = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await classifier.applyTitleGenerationForTesting(
                nil, tripID: tripID, expectedShape: shape, expectedSourceState: source)
        }
        #expect(applied == 0)
        #expect(await classifier.titleAttemptCountForTesting(shape) == 0)
        #expect(!(await classifier.hasCanonicalTitleFailureForTesting(shape)))
        #expect(await classifier.canonicalTitleForTesting(tripID: tripID) == nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }
}

@MainActor
@Suite("Enhance card outcome")
struct FMUpgradeCardOutcomeTests {
    @Test("only a completed rebuild dismisses the Enhance card; a failure reports", arguments: [
        TripClassifier.RebuildOutcome.completed, .failed, .cancelled,
    ])
    func cardFollowsCommittedOutcome(outcome: TripClassifier.RebuildOutcome) {
        let state = TripsListView.computeFMUpgradeCardState(after: outcome)
        #expect(state.dismiss == (outcome == .completed))
        #expect(state.showFailure == (outcome == .failed))
    }
}
