//
//  ForegroundClassificationDrainTests.swift
//  TravelLogTests
//
//  The foreground drain's coordinator against a scripted backlog, and its
//  bites against the classifier: they yield the latch to queued explicit
//  actions, and their units stop for the unit policy and for Delete All
//  Data's revocation.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// A scripted backlog: each bite classifies up to its size, or what the
/// script says, and can be held until the test releases it.
@MainActor
private final class FakeBacklog {
    var remaining: Int
    var classifyPerBite: Int?
    /// Stays that never classify.
    var stuck = 0
    var failOnBite: Int?
    var unreadableAfterBite: Int?
    var bites: [Int] = []
    var titleRefills = 0
    var mayRun = true
    /// Thermal or power policy, as the bite's units read it.
    nonisolated(unsafe) var systemAllows = true
    var holdBites = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var biteStarted: (() -> Void)?
    /// What each bite's unit policy answered as the bite began.
    var policyAnswers: [Bool] = []

    init(remaining: Int) { self.remaining = remaining }

    func bite(_ size: Int, _ policy: @Sendable () -> Bool) async -> ForegroundClassificationDrain.BiteOutcome {
        bites.append(size)
        biteStarted?()
        policyAnswers.append(policy())
        if holdBites { await withCheckedContinuation { held.append($0) } }
        guard !Task.isCancelled, policy() else { return .init(completed: false, classified: 0) }
        if failOnBite == bites.count { return .init(completed: false, classified: 0) }
        let classified = min(max(0, remaining - stuck), classifyPerBite ?? size)
        remaining -= classified
        return .init(completed: true, classified: classified)
    }

    func releaseHeld() {
        holdBites = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func drain() -> ForegroundClassificationDrain {
        ForegroundClassificationDrain(environment: .init(
            bite: { size, policy in await self.bite(size, policy) },
            backlog: {
                if let after = self.unreadableAfterBite, self.bites.count >= after { return nil }
                return self.remaining
            },
            titles: { await MainActor.run { self.titleRefills += 1 } },
            mayRun: { self.mayRun && self.systemAllows },
            systemAllowsWork: { self.systemAllows }))
    }
}

@MainActor
@Suite("Foreground classification drain", .serialized)
struct ForegroundClassificationDrainTests {

    @Test("drains the backlog in bites of 200, then refills titles once")
    func drainsToEmpty() async {
        let backlog = FakeBacklog(remaining: 450)
        let drain = backlog.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.remaining == 0)
        #expect(backlog.bites == [200, 200, 200])
        #expect(backlog.titleRefills == 1)
    }

    @Test("an empty backlog runs no bite and no titles")
    func emptyBacklog() async {
        let backlog = FakeBacklog(remaining: 0)
        let drain = backlog.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.bites.isEmpty)
        #expect(backlog.titleRefills == 0)
    }

    @Test("leaving the foreground stops at the next boundary; activation resumes from what committed and refills titles")
    func pauseAndResume() async {
        let backlog = FakeBacklog(remaining: 600)
        let drain = backlog.drain()
        backlog.biteStarted = { [weak backlog] in
            guard let backlog, backlog.bites.count == 2 else { return }
            // The app resigns active while the second bite runs.
            backlog.mayRun = false
            drain.pause()
        }
        drain.request()
        #expect(await drain.waitUntilIdle() == .paused)
        #expect(backlog.remaining == 400)
        #expect(backlog.policyAnswers == [true, false], "the paused bite's units are refused")
        #expect(backlog.titleRefills == 0, "a pause leaves titles pending")
        // A request while paused starts nothing.
        drain.request()
        #expect(!drain.isDraining)
        backlog.biteStarted = nil
        backlog.mayRun = true
        drain.resume()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.remaining == 0)
        #expect(backlog.titleRefills == 1)
    }

    @Test("a run that stopped before its titles refills them on the next request, with nothing left to classify")
    func owedTitlesRefill() async {
        let backlog = FakeBacklog(remaining: 200)
        let drain = backlog.drain()
        backlog.biteStarted = { [weak backlog] in
            // The bite commits, then the app leaves the foreground before the titles.
            backlog?.mayRun = false
        }
        drain.request()
        #expect(await drain.waitUntilIdle() == .paused)
        #expect(backlog.remaining == 0)
        #expect(backlog.titleRefills == 0)
        backlog.biteStarted = nil
        backlog.mayRun = true
        drain.resume()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.bites.count == 1)
        #expect(backlog.titleRefills == 1)
    }

    @Test("thermal or power policy stops a bite's units; that is a pause, not a failure")
    func policyStopIsAPause() async {
        let backlog = FakeBacklog(remaining: 600)
        let drain = backlog.drain()
        backlog.biteStarted = { [weak backlog] in
            guard let backlog, backlog.bites.count == 2 else { return }
            // The device heats up while the second bite runs.
            backlog.systemAllows = false
        }
        drain.request()
        #expect(await drain.waitUntilIdle() == .paused)
        #expect(backlog.policyAnswers == [true, false])
        #expect(backlog.remaining == 400)
        #expect(backlog.titleRefills == 0)
        // A request while it is still hot starts nothing; once it cools, the drain finishes.
        drain.request()
        #expect(!drain.isDraining)
        backlog.biteStarted = nil
        backlog.systemAllows = true
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.titleRefills == 1)
    }

    @Test("two bites without progress stop the drain")
    func noProgressStops() async {
        let backlog = FakeBacklog(remaining: 90)
        backlog.classifyPerBite = 0
        let drain = backlog.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .noProgress)
        #expect(backlog.bites.count == 2)
        #expect(backlog.remaining == 90)
        #expect(backlog.titleRefills == 0)
    }

    @Test("a stuck remainder stops after two bites, keeps its titles, is not retried until it changes, and later bites reach past it")
    func stuckRemainder() async {
        let backlog = FakeBacklog(remaining: 640)
        let drain = backlog.drain()
        // Three hundred stays never classify.
        backlog.stuck = 300
        drain.request()
        #expect(await drain.waitUntilIdle() == .noProgress)
        #expect(backlog.remaining == 300)
        #expect(backlog.bites == [200, 200, 200, 200])
        #expect(backlog.titleRefills == 1)
        // Activation finds the same stuck count: no bite.
        drain.request()
        #expect(await drain.waitUntilIdle() == .noProgress)
        #expect(backlog.bites.count == 4)
        // A new import moves the count: bites now reach a whole bite past the stuck stays.
        backlog.remaining += 30
        drain.request()
        #expect(await drain.waitUntilIdle() == .noProgress)
        #expect(backlog.remaining == 300)
        #expect(backlog.bites.dropFirst(4).allSatisfy { $0 == 500 })
    }

    @Test("a failed bite stops the drain without titles")
    func failureStops() async {
        let backlog = FakeBacklog(remaining: 900)
        backlog.failOnBite = 2
        let drain = backlog.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .failed)
        #expect(backlog.bites.count == 2)
        #expect(backlog.remaining == 700)
        #expect(backlog.titleRefills == 0)
    }

    @Test("an unreadable backlog is a failure, never an empty one")
    func unreadableCountFails() async {
        let backlog = FakeBacklog(remaining: 900)
        backlog.unreadableAfterBite = 1
        let drain = backlog.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .failed)
        #expect(backlog.bites.count == 1)
        #expect(backlog.titleRefills == 0)
    }

    @Test("cancellation stops mid-bite and never restarts itself")
    func cancellation() async {
        let backlog = FakeBacklog(remaining: 900)
        backlog.holdBites = true
        let drain = backlog.drain()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        backlog.biteStarted = { continuation.yield() }
        drain.request()
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        drain.request() // a trailing request, dropped by cancellation
        drain.cancel()
        backlog.releaseHeld()
        #expect(await drain.waitUntilIdle() == .cancelled)
        #expect(!drain.isDraining)
        #expect(backlog.bites.count == 1)
        #expect(backlog.remaining == 900)
    }

    @Test("a request during a run arms one trailing run")
    func trailingRequest() async {
        let backlog = FakeBacklog(remaining: 200)
        let drain = backlog.drain()
        backlog.biteStarted = { [weak backlog] in
            guard let backlog, backlog.bites.count == 1 else { return }
            // New stays arrive and ask for a drain while the first runs.
            backlog.remaining += 200
            drain.request()
        }
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(backlog.remaining == 0)
        #expect(backlog.bites.count == 2)
    }

    @Test("the stop rule: progress is a committed classification or a smaller backlog")
    func backlogProgress() {
        var progress = ClassificationBacklogProgress(patience: 1)
        #expect(progress.record(remaining: 120, classified: 0) == .continueDrain)
        #expect(progress.record(remaining: 60, classified: 0) == .continueDrain)
        #expect(progress.record(remaining: 60, classified: 0) == .stalled)
        var patient = ClassificationBacklogProgress(remaining: 60, patience: 2)
        #expect(patient.record(remaining: 60, classified: 20) == .continueDrain,
                "arrivals that replace classified stays are progress")
        #expect(patient.record(remaining: 80, classified: 0) == .continueDrain)
        #expect(patient.record(remaining: 80, classified: 0) == .stalled)
        #expect(patient.record(remaining: 0, classified: 80) == .complete)
    }
}

// MARK: - Bites against the classifier

@MainActor
@Suite("Backlog bites", .serialized, IsolatedTitleDefaults())
struct BacklogBiteTests {

    private func seedUnclassified(_ count: Int, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: 826_611_200)
        for index in 0..<count {
            let start = base.addingTimeInterval(Double(index) * 86_400)
            context.insert(Stay(startTime: start, endTime: start.addingTimeInterval(4 * 3600),
                centroidLatitude: 10.5, centroidLongitude: 20.5 + Double(index) / 100,
                h3IndexRes6: "bite-\(index)", pingCount: 2, distanceFromHomeKm: 400, pingIDs: []))
        }
        try context.save()
    }

    private func unclassified(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }))
    }

    @Test("a bite classifies at most its size and reports what it committed")
    func biteIsBounded() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUnclassified(30, in: container)
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.runBacklogBite(maxStaysPerCall: 20, gate: PipelineGate(forTesting: ()))
        #expect(outcome.completed)
        #expect(outcome.classified == 20)
        #expect(try unclassified(container) == 10)
    }

    @Test("a bite whose unit policy refuses stops before it writes", .timeLimit(.minutes(1)))
    func refusedUnitsWriteNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUnclassified(10, in: container)
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.runBacklogBite(
            maxStaysPerCall: 20, unitPolicy: { false }, gate: PipelineGate(forTesting: ()))
        #expect(!outcome.completed)
        #expect(outcome.classified == 0)
        #expect(try unclassified(container) == 10)
    }

    @Test("a pass revoked by Delete All Data lands none of its queued units", .timeLimit(.minutes(1)))
    func revokedPassLandsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUnclassified(10, in: container)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        // Hold the gate, start a bite behind it, revoke, then let it go: the
        // bite's first unit runs after the revocation and must refuse.
        let (holding, entered) = AsyncStream<Void>.makeStream()
        let (release, releasing) = AsyncStream<Void>.makeStream()
        let blocker = Task {
            await gate.run(touching: []) {
                entered.yield()
                for await _ in release { break }
            }
        }
        var iterator = holding.makeAsyncIterator()
        _ = await iterator.next()
        let bite = Task {
            await classifier.runBacklogBite(maxStaysPerCall: 20, gate: gate)
        }
        // The latch is taken and the actor free again once the bite's pass
        // has read the epoch and waits on the gate.
        while await !classifier.isRunning { await Task.yield() }
        gate.revokeQueuedPasses()
        releasing.yield()
        await blocker.value
        let outcome = await bite.value
        #expect(!outcome.completed)
        #expect(try unclassified(container) == 10)
    }

    @Test("a bite yields the latch to an explicit action waiting for it", .timeLimit(.minutes(1)))
    func biteYieldsToQueuedAction() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUnclassified(10, in: container)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await classifier.setRunningLatchForTesting(true)
        let order = OrderLog()
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let queued = Task {
            await TripClassifier.QueueTestHook.$waiting.withValue({ _ = signal.yield() }) {
                do {
                    let completed = await classifier.classifyAndAssembleTripsQueuedWithGates(gate: gate)
                    await order.append("queued")
                    return completed
                }
            }
        }
        var iterator = waiting.makeAsyncIterator()
        _ = await iterator.next()
        let bite = Task {
            do {
                let outcome = await classifier.runBacklogBite(maxStaysPerCall: 20, gate: gate)
                await order.append("bite")
                return outcome
            }
        }
        // Free the latch while both wait: the queued action takes it first.
        try await Task.sleep(for: .milliseconds(100))
        await classifier.setRunningLatchForTesting(false)
        #expect(await queued.value)
        #expect(await bite.value.completed)
        #expect(await order.entries == ["queued", "bite"])
    }
}

private actor OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
