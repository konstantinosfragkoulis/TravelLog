//
//  TitleWorkerTests.swift
//  TravelLogTests
//
//  The title worker: single titles and bulk regeneration run without the
//  classifier latch, ensures for one trip join one generation, and the
//  calendar title wipe and title operations exclude each other.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

private actor TitleCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor TitleHold {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
@Suite("Title worker", .serialized, IsolatedTitleDefaults())
struct TitleWorkerTests {

    private func makeTrip(in context: ModelContext) throws -> Trip {
        let start = Date(timeIntervalSinceReferenceDate: 826_611_200)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3 * 60 * 60),
                        centroidLatitude: 10.5, centroidLongitude: 20.5, h3IndexRes6: "8a2a1072b59ffff",
                        pingCount: 2, distanceFromHomeKm: 400, pingIDs: [])
        stay.category = .destination
        stay.locality = "Testville"
        stay.country = "Testland"
        stay.isoCountryCode = "TL"
        let trip = Trip(startDate: start)
        trip.isComplete = true
        trip.endDate = stay.endTime
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        _ = trip.recomputeSummary()
        try context.save()
        return trip
    }

    @Test("ensuring a title does not hold the classifier latch, and a second ensure joins the first",
          .timeLimit(.minutes(1)))
    func ensureRunsBesideClassification() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let tripID = try makeTrip(in: ModelContext(container)).id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let hold = TitleHold()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let calls = TitleCalls()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await calls.record()
            continuation.yield()
            await hold.wait()
            return "Testville Days"
        }
        let first = Task { await classifier.ensureCanonicalTitle(for: tripID, gate: gate) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task { await classifier.ensureCanonicalTitle(for: tripID, gate: gate) }
        // A pass that never waits reports a skip while the latch is held.
        let pass = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
        }
        await hold.release()
        #expect(pass.completed, "classification waited behind title inference")
        #expect(await first.value == "Testville Days")
        #expect(await second.value == "Testville Days")
        #expect(await calls.count == 1)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("bulk regeneration runs while a pass holds the classifier latch", .timeLimit(.minutes(1)))
    func bulkRegenerationTakesNoLatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let tripID = try makeTrip(in: ModelContext(container)).id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await classifier.setTitleGenerationOverrideForTesting { _ in "Testville Days" }
        await classifier.setRunningLatchForTesting(true)
        #expect(await classifier.regenerateAllTitles(gate: gate) == 1)
        #expect(await classifier.aiTitleFieldsForTesting(tripID)?.title == "Testville Days")
        // Whatever it writes, it returns without queueing behind the pass.
        _ = await classifier.clearAndRegenerateAllTitles(gate: gate)
        await classifier.setRunningLatchForTesting(false)
        #expect(await classifier.aiTitleFieldsForTesting(tripID)?.title != nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("a calendar title wipe waits for a single title in flight, then clears it", .timeLimit(.minutes(1)))
    func calendarWipeWaitsForSingleTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let tripID = try makeTrip(in: ModelContext(container)).id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let hold = TitleHold()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            continuation.yield()
            await hold.wait()
            return "Testville Days"
        }
        let ensure = Task { await classifier.ensureCanonicalTitle(for: tripID, gate: gate) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        await classifier.setTitleGenerationOverrideForTesting(nil)
        let wipe = Task { await classifier.clearThenRegenerateAllTitlesForCalendarWipe(gate: gate) }
        while await !classifier.calendarWipeIsWaitingForLatchForTesting() { await Task.yield() }
        await hold.release()
        #expect(await ensure.value == "Testville Days")
        let result = await wipe.value
        #expect(result.cleared)
        #expect(await classifier.aiTitleFieldsForTesting(tripID)?.title != "Testville Days")
    }

    @Test("a single title waits while the calendar wipe owns the title namespace", .timeLimit(.minutes(1)))
    func singleTitleWaitsForCalendarWipe() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let tripID = try makeTrip(in: ModelContext(container)).id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let hold = TitleHold()
        let (refilling, continuation) = AsyncStream<Void>.makeStream()
        await classifier.setCalendarWipeAfterClearOverrideForTesting {
            continuation.yield()
            await hold.wait()
        }
        let wipe = Task { await classifier.clearThenRegenerateAllTitlesForCalendarWipe(gate: gate) }
        var iterator = refilling.makeAsyncIterator()
        _ = await iterator.next()
        let calls = TitleCalls()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await calls.record()
            return "Testville Days"
        }
        let ensure = Task { await classifier.ensureCanonicalTitle(for: tripID, gate: gate) }
        // The clear has let go of the classifier latch: a pass runs meanwhile.
        let pass = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
        }
        #expect(pass.completed)
        #expect(await calls.count == 0, "the ensure inferred inside the wipe")
        await hold.release()
        #expect(await wipe.value.cleared)
        // Afterwards it returns what the store holds: the refill's title, or its own.
        let ensured = await ensure.value
        #expect(ensured != nil)
        #expect(ensured == (await classifier.aiTitleFieldsForTesting(tripID)?.title))
        await classifier.setCalendarWipeAfterClearOverrideForTesting(nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("a queued calendar title wipe stops an unlimited title pass at its next inference",
          .timeLimit(.minutes(1)))
    func calendarWipeStopsUnlimitedTitlePass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for _ in 0..<4 { _ = try makeTrip(in: context) }
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let hold = TitleHold()
        let calls = TitleCalls()
        let callsAtClear = TitleCalls()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await calls.record()
            continuation.yield()
            await hold.wait()
            return "Testville Days"
        }
        // How many trips the pass had titled when the wipe's clear committed.
        await classifier.setCalendarWipeAfterClearOverrideForTesting {
            for _ in 0..<(await calls.count) { await callsAtClear.record() }
        }
        // The foreground drain's refill: no limit, every untitled trip.
        let pass = Task {
            await classifier.generateTitlesStage(maxTripsPerCall: nil, applyGate: gate)
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let wipe = Task { await classifier.clearThenRegenerateAllTitlesForCalendarWipe(gate: gate) }
        while await !classifier.calendarWipeIsWaitingForLatchForTesting() { await Task.yield() }
        await hold.release()
        _ = await pass.value
        #expect(await wipe.value.cleared)
        #expect(await callsAtClear.count == 1,
                "the wipe waited while the pass titled the rest of the library")
        await classifier.setCalendarWipeAfterClearOverrideForTesting(nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }
}
