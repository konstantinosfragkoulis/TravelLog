//
//  CanonicalTitleLifecycleTests.swift
//  TravelLogTests
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

private actor CanonicalTitleTestLatch {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor CanonicalTitleGateProbe {
    private(set) var ran = false
    func mark() { ran = true }
}

@MainActor
@Suite("Canonical title lifecycle", .serialized, IsolatedTitleDefaults())
struct CanonicalTitleLifecycleTests {

    private func makeTrip(in context: ModelContext) throws -> (Trip, Stay) {
        let start = Date(timeIntervalSinceReferenceDate: 826_611_200)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(3 * 60 * 60),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 4,
            pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        stay.country = "Greece"
        stay.isoCountryCode = "GR"

        let trip = Trip(startDate: start)
        trip.isComplete = true
        trip.endDate = stay.endTime
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        try context.save()
        return (trip, stay)
    }

    @Test("metro refresh preserves valid titles and invalidates rank-1 violations")
    func metroRefreshRevalidatesStoredTitlesUnderCurrentPolicy() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        #expect(AppDelegate.tripSummaryMetroRefreshCompletedKey
                == "tripSummaryMetroRefreshCompleted_v6")
        let (validTrip, _) = try makeTrip(in: context)
        validTrip.aiGeneratedTitle = "Athens"
        let (invalidTrip, cephaloniaStay) = try makeTrip(in: context)
        cephaloniaStay.locality = "Lixoúri"
        cephaloniaStay.islandName = "Cephalonia"
        cephaloniaStay.endTime = cephaloniaStay.startTime.addingTimeInterval(96 * 3_600)
        cephaloniaStay.durationMinutes = 96 * 60
        let samosStart = cephaloniaStay.endTime.addingTimeInterval(3_600)
        let samosStay = Stay(
            startTime: samosStart,
            endTime: samosStart.addingTimeInterval(24 * 3_600),
            centroidLatitude: 37.7888, centroidLongitude: 26.7049,
            h3IndexRes6: "8a2a1072b597fff", pingCount: 2,
            distanceFromHomeKm: 160, pingIDs: [])
        samosStay.category = .destination
        samosStay.locality = "Néon Karlovásion"
        samosStay.islandName = "Samos"
        samosStay.country = "Greece"
        samosStay.isoCountryCode = "GR"
        context.insert(samosStay)
        samosStay.trip = invalidTrip
        samosStay.orderInTrip = 1
        invalidTrip.endDate = samosStay.endTime
        invalidTrip.aiGeneratedTitle = "Samos"
        try context.save()
        _ = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
            modelContainer: container)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let byID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byID[validTrip.id]?.aiGeneratedTitle == "Athens")
        #expect(byID[invalidTrip.id]?.aiGeneratedTitle == nil)
    }

    @Test("metro refresh keeps abbreviations and stored spellings and respells titles missing letters")
    func metroRefreshRepairsDeletedLetterTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // New York (100 h) and White Plains (30 h): a lone "NYC" names the top place.
        let (nycTrip, nycStay) = try makeTrip(in: context)
        nycStay.metroName = "New York"
        nycStay.locality = "Manhattan"
        nycStay.country = "United States"
        nycStay.isoCountryCode = "US"
        nycStay.endTime = nycStay.startTime.addingTimeInterval(100 * 3_600)
        nycStay.durationMinutes = 100 * 60
        let whitePlainsStart = nycStay.endTime.addingTimeInterval(3_600)
        let whitePlainsStay = Stay(
            startTime: whitePlainsStart,
            endTime: whitePlainsStart.addingTimeInterval(30 * 3_600),
            centroidLatitude: 41.0356, centroidLongitude: -73.7631,
            h3IndexRes6: "8a2a1072b5a7fff", pingCount: 2,
            distanceFromHomeKm: 300, pingIDs: [])
        whitePlainsStay.category = .destination
        whitePlainsStay.metroName = "White Plains"
        whitePlainsStay.locality = "White Plains"
        whitePlainsStay.country = "United States"
        whitePlainsStay.isoCountryCode = "US"
        whitePlainsStay.durationMinutes = 30 * 60
        context.insert(whitePlainsStay)
        whitePlainsStay.trip = nycTrip
        whitePlainsStay.orderInTrip = 1
        nycTrip.endDate = whitePlainsStay.endTime
        nycTrip.aiGeneratedTitle = "NYC"

        func tromsoTrip(title: String, region: String? = nil) throws -> Trip {
            let (trip, stay) = try makeTrip(in: context)
            stay.locality = "Tromsø"
            stay.administrativeArea = region
            stay.country = "Norway"
            stay.isoCountryCode = "NO"
            trip.aiGeneratedTitle = title
            return trip
        }
        let mangled = try tromsoTrip(title: "Troms")
        let native = try tromsoTrip(title: "Tromsø")
        // Tromsø lies in the Troms region, so grounding alone accepts "Troms".
        let regionOwned = try tromsoTrip(title: "Troms", region: "Troms")
        let revision = UUID()
        regionOwned.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Troms", sourceTitle: "Troms",
            sourceRevision: revision, trip: regionOwned))
        // A retired spelling whose respelling the policy still rejects is cleared.
        let ungrounded = try tromsoTrip(title: "Troms & Paris")
        try context.save()
        #expect(TripClassifier(modelContainer: container)
            .titleValidationFailure("Troms", for: regionOwned) == nil)

        _ = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let byID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byID[nycTrip.id]?.aiGeneratedTitle == "NYC")
        #expect(byID[native.id]?.aiGeneratedTitle == "Tromsø")
        #expect(byID[mangled.id]?.aiGeneratedTitle == "Tromsø")
        let respelled = try #require(byID[regionOwned.id])
        #expect(respelled.aiGeneratedTitle == "Tromsø")
        #expect(respelled.titleSourceRevision != nil && respelled.titleSourceRevision != revision)
        #expect((respelled.localizedTitles ?? []).isEmpty)
        #expect(byID[ungrounded.id]?.aiGeneratedTitle == nil)
    }

    @Test("an exhausted title budget writes the stored-spelling fallback")
    func exhaustedBudgetWritesStoredSpellingFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        stay.locality = "Tromsø"
        stay.country = "Norway"
        stay.isoCountryCode = "NO"
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setTitleGenerationOverrideForTesting { _ in nil }
        // Two failed attempts in one session reach the threshold; the second writes the fallback.
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 0)
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 1)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.id == trip.id }
        #expect(stored?.aiGeneratedTitle == "Tromsø")
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("names outside ASCII retry after an old-policy exhaustion")
    func nonASCIINameRetriesOldPolicyFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        stay.locality = "Tromsø"
        stay.country = "Norway"
        stay.isoCountryCode = "NO"
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: trip.id))
        let key = await classifier.canonicalTitleFailureKeyForTesting(shape)
        #expect(key.contains("|v10|"))
        let oldKey = key.replacingOccurrences(of: "|v10|", with: "|v7|")
        #expect(oldKey != key)
        let defaultsKey = "failedTitleInputKeys_v2"
        defer {
            let remaining = (IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? [])
                .filter { $0 != oldKey && $0 != key }
            if remaining.isEmpty { IsolatedTitleDefaults.current.removeObject(forKey: defaultsKey) }
            else { IsolatedTitleDefaults.current.set(remaining, forKey: defaultsKey) }
        }
        var failures = IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? []
        failures.append(oldKey)
        IsolatedTitleDefaults.current.set(failures, forKey: defaultsKey)
        let retry = TripClassifier(modelContainer: container)
        await retry.setTitleGenerationOverrideForTesting { _ in "Tromsø" }
        #expect(await retry.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(await retry.canonicalTitleForTesting(tripID: trip.id) == "Tromsø")
        await retry.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("canonical inference leaves PipelineGate free until its CAS apply",
          .timeLimit(.minutes(1)))
    func canonicalInferenceDoesNotHoldGlobalGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeTrip(in: context)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let release = CanonicalTitleTestLatch()
        let probe = CanonicalTitleGateProbe()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            startedContinuation.yield()
            await release.wait()
            return "Athens After Dark"
        }

        let generation = Task {
            await classifier.generateTitlesStage(
                maxTripsPerCall: 1,
                applyGate: gate)
        }
        var startedIterator = started.makeAsyncIterator()
        let inferenceStarted = await startedIterator.next() != nil
        #expect(inferenceStarted && !Task.isCancelled, "title inference never started")
        guard inferenceStarted && !Task.isCancelled else {
            await release.release()
            generation.cancel()
            await classifier.setTitleGenerationOverrideForTesting(nil)
            return
        }
        let (enteredGate, continuation) = AsyncStream<Void>.makeStream()
        let competingUnit = Task {
            await gate.run(touching: [.locationPing]) {
                await probe.mark()
                continuation.yield()
            }
            continuation.finish()
        }
        // Wait for actual gate entry while inference is held, not an assumed
        // scheduler latency. AsyncStream responds to the test's time-limit
        // cancellation, and the handler frees inference even on regression.
        let entered = await withTaskCancellationHandler {
            var iterator = enteredGate.makeAsyncIterator()
            return await iterator.next() != nil
        } onCancel: {
            Task { await release.release() }
        }
        await release.release()
        #expect(entered && !Task.isCancelled,
                "slow title inference held the global store gate")
        guard entered && !Task.isCancelled else {
            // Do not await a broken gate chain after the deadline: its units
            // may themselves be stuck behind the regressed inference unit.
            competingUnit.cancel()
            generation.cancel()
            await classifier.setTitleGenerationOverrideForTesting(nil)
            return
        }
        await competingUnit.value
        #expect(await probe.ran)
        #expect(await generation.value == 1)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("a trigger arriving during title inference queues a fresh candidate pass",
          .timeLimit(.minutes(1)))
    func concurrentTitleTriggerIsNotDropped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (firstTrip, _) = try makeTrip(in: context)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let started = CanonicalTitleTestLatch()
        let release = CanonicalTitleTestLatch()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await started.release()
            await release.wait()
            return "Athens After Dark"
        }

        let owner = Task {
            await classifier.generateTitlesStage(
                maxTripsPerCall: 1,
                applyGate: gate)
        }
        await started.wait()

        // This row did not exist in the owner's candidate snapshot. The
        // second trigger therefore must cause a follow-up fetch, not merely
        // return as duplicate work.
        let (secondTrip, _) = try makeTrip(in: context)
        let queuedResult = await classifier.generateTitlesStage(
            maxTripsPerCall: nil,
            applyGate: gate)
        #expect(queuedResult == 0)

        await release.release()
        #expect(await owner.value == 2)
        #expect(await classifier.canonicalTitleForTesting(
            tripID: firstTrip.id,
            tripIdentifier: firstTrip.persistentModelID) == "Athens After Dark")
        #expect(await classifier.canonicalTitleForTesting(
            tripID: secondTrip.id,
            tripIdentifier: secondTrip.persistentModelID) == "Athens After Dark")
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("batch generation admits and applies a title to an all-transit trip")
    func allTransitTripReachesStageFive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        stay.category = .transit
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setTitleGenerationOverrideForTesting { _ in
            "Athens Stopover"
        }
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: 1,
            applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(await classifier.canonicalTitleForTesting(
            tripID: trip.id,
            tripIdentifier: trip.persistentModelID) == "Athens Stopover")
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("canonical generation fails closed when active Home inputs cannot be read")
    func canonicalHomeReadFailureDoesNotGenerateOrSpendBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let home = Home(label: "Athens Home", latitude: 37.98, longitude: 23.72)
        home.country = "Greece"
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let generationProbe = CanonicalTitleGateProbe()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            await generationProbe.mark()
            return "Athens After Dark"
        }
        await classifier.setCanonicalHomeInputFetchFailureForTesting(true)

        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: 1,
            applyGate: PipelineGate(forTesting: ())) == 0)
        #expect(!(await generationProbe.ran))
        #expect(trip.aiGeneratedTitle == nil)

        await classifier.setCanonicalHomeInputFetchFailureForTesting(false)
        let shape = try #require(
            await classifier.canonicalTitleShapeForTesting(
                tripID: trip.id,
                tripIdentifier: trip.persistentModelID))
        #expect(await classifier.titleAttemptCountForTesting(shape) == 0)
        #expect(!(await classifier.hasCanonicalTitleFailureForTesting(shape)))
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("country-island titles retry after an old-policy exhaustion")
    func countryIslandRetriesOldPolicyFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        stay.locality = "Limassol"
        stay.islandName = "Cyprus"
        stay.country = "Cyprus"
        stay.isoCountryCode = "CY"
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: trip.id))
        let key = await classifier.canonicalTitleFailureKeyForTesting(shape)
        let oldKey = key.replacingOccurrences(of: "|v8|", with: "|v7|")
        #expect(oldKey != key)
        let defaultsKey = "failedTitleInputKeys_v2"
        defer {
            let remaining = (IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? [])
                .filter { $0 != oldKey && $0 != key }
            if remaining.isEmpty { IsolatedTitleDefaults.current.removeObject(forKey: defaultsKey) }
            else { IsolatedTitleDefaults.current.set(remaining, forKey: defaultsKey) }
        }
        var failures = IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? []
        failures.append(oldKey)
        IsolatedTitleDefaults.current.set(failures, forKey: defaultsKey)
        let retry = TripClassifier(modelContainer: container)
        await retry.setTitleGenerationOverrideForTesting { _ in "Limassol" }
        #expect(await retry.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(await retry.canonicalTitleForTesting(tripID: trip.id) == "Limassol")
    }

    @Test("country-named city titles retry after an old-policy exhaustion")
    func countryWordCityRetriesOldPolicyFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        stay.metroName = "Mexico City"
        stay.locality = "Mexico City"
        stay.country = "Mexico"
        stay.isoCountryCode = "MX"
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: trip.id))
        let key = await classifier.canonicalTitleFailureKeyForTesting(shape)
        #expect(key.contains("|v9|"))
        let oldKey = key.replacingOccurrences(of: "|v9|", with: "|v7|")
        #expect(oldKey != key)
        let defaultsKey = "failedTitleInputKeys_v2"
        defer {
            let remaining = (IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? [])
                .filter { $0 != oldKey && $0 != key }
            if remaining.isEmpty { IsolatedTitleDefaults.current.removeObject(forKey: defaultsKey) }
            else { IsolatedTitleDefaults.current.set(remaining, forKey: defaultsKey) }
        }
        var failures = IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? []
        failures.append(oldKey)
        IsolatedTitleDefaults.current.set(failures, forKey: defaultsKey)
        let retry = TripClassifier(modelContainer: container)
        await retry.setTitleGenerationOverrideForTesting { _ in "Mexico City" }
        #expect(await retry.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(await retry.canonicalTitleForTesting(tripID: trip.id) == "Mexico City")

        // An ordinary city keeps its v7 key.
        stay.metroName = nil
        stay.locality = "Paris"
        stay.country = "France"
        stay.isoCountryCode = "FR"
        try context.save()
        let parisClassifier = TripClassifier(modelContainer: container)
        let parisShape = try #require(await parisClassifier.canonicalTitleShapeForTesting(tripID: trip.id))
        #expect(await parisClassifier.canonicalTitleFailureKeyForTesting(parisShape).contains("|v7|"))
    }

    @Test("country-island repair preserves unrelated v7 exhaustion keys")
    func unrelatedPolicyFailureRemainsExhausted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: trip.id))
        let key = await classifier.canonicalTitleFailureKeyForTesting(shape)
        #expect(key.contains("|v7|"))
        let defaultsKey = "failedTitleInputKeys_v2"
        defer {
            let remaining = (IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? [])
                .filter { $0 != key }
            IsolatedTitleDefaults.current.set(remaining, forKey: defaultsKey)
        }
        var failures = IsolatedTitleDefaults.current.stringArray(forKey: defaultsKey) ?? []
        failures.append(key)
        IsolatedTitleDefaults.current.set(failures, forKey: defaultsKey)
        let retry = TripClassifier(modelContainer: container)
        let probe = CanonicalTitleGateProbe()
        await retry.setTitleGenerationOverrideForTesting { _ in
            await probe.mark()
            return "Athens"
        }
        #expect(await retry.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 0)
        #expect(!(await probe.ran))
        #expect(await retry.hasCanonicalTitleFailureForTesting(shape))

        // A metro still wins over a country-named island; its policy did not change.
        stay.country = "Cyprus"
        stay.isoCountryCode = "CY"
        stay.islandName = "Cyprus"
        stay.locality = "Limassol"
        stay.metroName = "Limassol"
        try context.save()
        let metroClassifier = TripClassifier(modelContainer: container)
        let metroShape = try #require(await metroClassifier.canonicalTitleShapeForTesting(tripID: trip.id))
        #expect(await metroClassifier.canonicalTitleFailureKeyForTesting(metroShape).contains("|v7|"))
    }

    @Test("an ignored country-island layover does not reset an ordinary title failure")
    func ignoredCountryIslandDoesNotResetPolicy() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let layover = Stay(startTime: trip.startDate, endTime: trip.endDate!,
                           centroidLatitude: 34.8, centroidLongitude: 32.5,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 900, pingIDs: [])
        layover.locality = "Paphos"
        layover.islandName = "Cyprus"
        layover.country = "Cyprus"
        layover.isoCountryCode = "CY"
        context.insert(layover)
        layover.trip = trip
        for isTransit in [true, false] {
            layover.category = isTransit ? .transit : .destination
            layover.isAirport = !isTransit
            try context.save()
            let classifier = TripClassifier(modelContainer: container)
            let shape = try #require(await classifier.canonicalTitleShapeForTesting(tripID: trip.id))
            #expect(await classifier.canonicalTitleFailureKeyForTesting(shape).contains("|v7|"))
        }
    }

    @Test("retry identity follows semantic input but ignores generated decoration")
    func retryIdentityTracksSemanticInput() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)

        let firstClassifier = TripClassifier(modelContainer: container)
        let initial = try #require(await firstClassifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let initialKey = await firstClassifier.canonicalTitleFailureKeyForTesting(initial)

        trip.aiGeneratedSummary = "A generated paragraph that is not title input."
        trip.summaryGeneratedAt = .now
        try context.save()

        let decorationClassifier = TripClassifier(modelContainer: container)
        let afterDecoration = try #require(
            await decorationClassifier.canonicalTitleShapeForTesting(
                tripID: trip.id))
        #expect(afterDecoration == initial)

        stay.locality = "Lixoúri"
        try context.save()

        let changedClassifier = TripClassifier(modelContainer: container)
        let changed = try #require(await changedClassifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let changedKey = await changedClassifier.canonicalTitleFailureKeyForTesting(changed)
        #expect(changed != initial)
        #expect(changedKey != initialKey)
        #expect(!changedKey.contains("Lixoúri"))

        stay.locality = " Lixoúri "
        try context.save()
        let exactRawShape = try #require(
            await changedClassifier.canonicalTitleShapeForTesting(
                tripID: trip.id))
        #expect(exactRawShape != changed,
                "the apply guard must describe the exact raw prompt input")
    }

    @Test("active Home locality changes reject every stale canonical apply")
    func activeHomeLocalityChangeRejectsStaleApply() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let home = Home(
            label: "Home",
            latitude: 37.9838,
            longitude: 23.7275,
            radiusKm: 3,
            startedAt: trip.startDate.addingTimeInterval(-86_400))
        home.locality = "Athens"
        home.country = "Greece"
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        let classifier = TripClassifier(modelContainer: container)
        let before = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let beforeSource = try #require(
            await classifier.canonicalTitleSourceStateForTesting(tripID: trip.id))

        home.locality = "Ioánnina"
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        #expect(await classifier.applyTitleGenerationForTesting(
            "Athens",
            tripID: trip.id,
            expectedShape: before,
            expectedSourceState: beforeSource) == 0)
        #expect(await classifier.applyTitleGenerationForTesting(
            nil,
            tripID: trip.id,
            expectedShape: before,
            expectedSourceState: beforeSource) == 0)
        #expect(await classifier.titleAttemptCountForTesting(before) == 0)
        for lane in TripClassifier.CanonicalApplyLaneForTesting.allCases {
            #expect(!(await classifier.applyCanonicalTitleForTesting(
                "Athens",
                tripID: trip.id,
                expectedShape: before,
                expectedSourceState: beforeSource,
                lane: lane)))
        }
    }

    @Test("external home-place changes rotate canonical retry identity")
    func externalHomePlaceChangeRotatesRetryIdentity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let homeStay = Stay(
            startTime: trip.startDate,
            endTime: trip.startDate.addingTimeInterval(3 * 60 * 60),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 0,
            pingIDs: [])
        homeStay.category = .home
        homeStay.locality = "Athens"
        context.insert(homeStay)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        let classifier = TripClassifier(modelContainer: container)
        let before = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let beforeKey = await classifier.canonicalTitleFailureKeyForTesting(before)

        homeStay.locality = "Ioánnina"
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        let after = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let afterKey = await classifier.canonicalTitleFailureKeyForTesting(after)
        #expect(after.trip == before.trip)
        #expect(after.activeHomes == before.activeHomes)
        #expect(before.homePlaceNames == ["athens"])
        #expect(after.homePlaceNames == ["ioannina"])
        #expect(afterKey != beforeKey)
    }

    @Test("stale success and failure are rejected without spending retry budget")
    func staleApplyIsRejected() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stay) = try makeTrip(in: context)
        let tripID = trip.id

        let beforeClassifier = TripClassifier(modelContainer: container)
        let before = try #require(await beforeClassifier.canonicalTitleShapeForTesting(
            tripID: tripID))
        let beforeSource = try #require(
            await beforeClassifier.canonicalTitleSourceStateForTesting(tripID: tripID))

        stay.locality = "Lixoúri"
        try context.save()

        // Re-use the actor that captured `before`: production holds one long-
        // lived ModelActor across the FM suspension, so this also proves its
        // context observes a different context's gated save before applying.
        let applyingClassifier = beforeClassifier
        #expect(await applyingClassifier.applyTitleGenerationForTesting(
            "Athens",
            tripID: tripID,
            expectedShape: before,
            expectedSourceState: beforeSource) == 0)
        #expect(await applyingClassifier.applyTitleGenerationForTesting(
            nil,
            tripID: tripID,
            expectedShape: before,
            expectedSourceState: beforeSource) == 0)
        #expect(await applyingClassifier.titleAttemptCountForTesting(before) == 0)
        for lane in TripClassifier.CanonicalApplyLaneForTesting.allCases {
            #expect(!(await applyingClassifier.applyCanonicalTitleForTesting(
                "Athens",
                tripID: tripID,
                expectedShape: before,
                expectedSourceState: beforeSource,
                lane: lane)))
        }

        var fresh = ModelContext(container)
        var predicate = #Predicate<Trip> { $0.id == tripID }
        #expect(try fresh.fetch(FetchDescriptor<Trip>(predicate: predicate)).first?.aiGeneratedTitle == nil)

        let current = try #require(await applyingClassifier.canonicalTitleShapeForTesting(
            tripID: tripID))
        let currentSource = try #require(
            await applyingClassifier.canonicalTitleSourceStateForTesting(tripID: tripID))
        #expect(await applyingClassifier.applyTitleGenerationForTesting(
            "Lixoúri",
            tripID: tripID,
            expectedShape: current,
            expectedSourceState: currentSource) == 1)

        fresh = ModelContext(container)
        predicate = #Predicate<Trip> { $0.id == tripID }
        #expect(try fresh.fetch(FetchDescriptor<Trip>(predicate: predicate)).first?.aiGeneratedTitle == "Lixoúri")
    }

    @Test("same-semantics newer canonical writes win every asynchronous apply race")
    func newerCanonicalWriteWinsApplyCAS() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let tripID = trip.id
        TripTitleStore.replaceCanonicalTitle("Original", for: trip, in: context)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let source = try #require(
            await classifier.canonicalTitleSourceStateForTesting(tripID: trip.id))

        // Represents a newer CloudKit/device write that changes no stay/home
        // prompt input, only the canonical artifact and its revision.
        TripTitleStore.replaceCanonicalTitle("Newer Cloud Title", for: trip, in: context)
        try context.save()

        for lane in TripClassifier.CanonicalApplyLaneForTesting.allCases {
            #expect(!(await classifier.applyCanonicalTitleForTesting(
                "Stale Model Result",
                tripID: trip.id,
                expectedShape: shape,
                expectedSourceState: source,
                lane: lane)))
        }

        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first)
        #expect(reloaded.aiGeneratedTitle == "Newer Cloud Title")
    }

    @Test("canonical apply targets the physical trip when app UUIDs collide")
    func canonicalApplyTargetsPhysicalTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (firstTrip, _) = try makeTrip(in: context)
        let (secondTrip, _) = try makeTrip(in: context)
        secondTrip.id = firstTrip.id
        try context.save()
        let secondIdentifier = secondTrip.persistentModelID

        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: secondTrip.id,
            tripIdentifier: secondIdentifier))
        let source = try #require(
            await classifier.canonicalTitleSourceStateForTesting(
                tripID: secondTrip.id,
                tripIdentifier: secondIdentifier))

        #expect(await classifier.applyTitleGenerationForTesting(
            "Athens After Dark",
            tripID: secondTrip.id,
            tripIdentifier: secondIdentifier,
            expectedShape: shape,
            expectedSourceState: source) == 1)

        #expect(await classifier.canonicalTitleForTesting(
            tripID: firstTrip.id,
            tripIdentifier: firstTrip.persistentModelID) == nil)
        #expect(await classifier.canonicalTitleForTesting(
            tripID: secondTrip.id,
            tripIdentifier: secondIdentifier) == "Athens After Dark")
    }

    @Test("cancelled queued applies cannot write or spend canonical retry budget")
    func cancelledApplyIsInert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))
        let source = try #require(
            await classifier.canonicalTitleSourceStateForTesting(tripID: trip.id))

        let generated = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.applyTitleGenerationForTesting(
                nil,
                tripID: trip.id,
                expectedShape: shape,
                expectedSourceState: source)
        }.value
        #expect(generated == 0)
        #expect(await classifier.titleAttemptCountForTesting(shape) == 0)

        for lane in TripClassifier.CanonicalApplyLaneForTesting.allCases {
            let applied = await Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                return await classifier.applyCanonicalTitleForTesting(
                    "Canceled Result",
                    tripID: trip.id,
                    expectedShape: shape,
                    expectedSourceState: source,
                    lane: lane)
            }.value
            #expect(!applied)
        }
        #expect(trip.aiGeneratedTitle == nil)
    }

    @Test("reclassifying a stay in a user-edited open trip invalidates all generated titles")
    func userEditedOpenTripHealingInvalidatesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 826_611_200)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(3 * 60 * 60),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 4,
            pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        let trip = Trip(startDate: start)
        trip.userEdited = true
        trip.aiGeneratedTitle = "Athens"
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athen",
            sourceTitle: "Athens",
            trip: trip))
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.healUserEditedOpenTripTitlesForTesting(
            changedStayIDs: [stay.id])

        let fields = try #require(await classifier.aiTitleFieldsForTesting(trip.id))
        #expect(fields.title == nil)
        #expect(fields.localizedCount == 0)
    }

    @Test("canonical retry state clears from memory and disk for a full wipe")
    func canonicalRetryStateClearsCompletely() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context)
        let classifier = TripClassifier(modelContainer: container)
        let shape = try #require(await classifier.canonicalTitleShapeForTesting(
            tripID: trip.id))

        await classifier.markCanonicalTitleFailureForTesting(shape)
        IsolatedTitleDefaults.current.set(
            [trip.id.uuidString],
            forKey: "failedTitleTripIDs_v1")
        #expect(await classifier.hasCanonicalTitleFailureForTesting(shape))
        #expect(IsolatedTitleDefaults.current.object(forKey: "failedTitleInputKeys_v2") != nil)

        await classifier.clearAllPersistentTitleFailures()

        #expect(!(await classifier.hasCanonicalTitleFailureForTesting(shape)))
        #expect(IsolatedTitleDefaults.current.object(forKey: "failedTitleInputKeys_v2") == nil)
        #expect(IsolatedTitleDefaults.current.object(forKey: "failedTitleTripIDs_v1") == nil)
    }

    // MARK: - Exact failure keys

    // Devices store exhausted budgets under these keys: any changed byte
    // would grant every exhausted trip in the library a fresh attempt.

    private typealias KeyStay = TripTitleStore.SemanticSnapshot.StayInput

    private nonisolated static func keyStay(
        _ index: Int, category: String = "destination", isAirport: Bool = false,
        metro: String? = nil, island: String? = nil, locality: String?,
        admin: String? = nil, country: String?, iso: String?, hasOrder: Bool = true
    ) -> KeyStay {
        let start = Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 7_200)
        return KeyStay(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            orderInTrip: hasOrder ? index : nil, startTime: start, endTime: start.addingTimeInterval(3_600),
            durationMinutes: 60, categoryRaw: category, isAirport: isAirport,
            metroName: metro, islandName: island, locality: locality,
            administrativeArea: admin, country: country, isoCountryCode: iso)
    }

    private nonisolated static func keyShape(
        _ stays: [KeyStay], homes: [TripClassifier.CanonicalTitleShape.HomeInput] = [],
        homeNames: [String] = [], endDate: Date? = Date(timeIntervalSince1970: 1_780_100_000),
        customName: String? = nil
    ) -> TripClassifier.CanonicalTitleShape {
        TripClassifier.CanonicalTitleShape(
            trip: TripTitleStore.SemanticSnapshot(
                tripID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
                startDate: Date(timeIntervalSince1970: 1_780_000_000), endDate: endDate,
                isComplete: endDate != nil, customName: customName, stays: stays),
            activeHomes: homes,
            homePlaceNames: homeNames)
    }

    private nonisolated static let athens = keyStay(0, locality: "Athens", admin: "Attica", country: "Greece", iso: "GR")
    private nonisolated static let limassol = keyStay(1, island: "Cyprus", locality: "Limassol", country: "Cyprus", iso: "CY")

    private nonisolated static let tripKey = "6F9619FF-8B86-D011-B42D-00C04FC964FF|"

    struct FailureKeyFixture: Sendable, CustomTestStringConvertible {
        let name: String
        let shape: TripClassifier.CanonicalTitleShape
        let key: String
        var testDescription: String { name }
    }

    nonisolated static let failureKeyFixtures: [FailureKeyFixture] = [
        FailureKeyFixture(name: "v7 ordinary city", shape: keyShape([athens]),
            key: tripKey + "v7|ff71c7cfb7d55936bcd53abdcef1434106cd35d6efe3f39884226744fa8787d9"),
        FailureKeyFixture(name: "v7 empty trip", shape: keyShape([]),
            key: tripKey + "v7|0053062e04200f6ad52e750a783a02f1124661eda57635f34934558d42b71a28"),
        FailureKeyFixture(name: "v7 open trip with homes and a custom name", shape: keyShape(
            [athens, keyStay(1, locality: "Corinth", country: "Greece", iso: "GR", hasOrder: false)],
            homes: [TripTitleStore.ActiveHomeTitleInput(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                locality: "Lisbon", country: nil, isoCountryCode: "PT")],
            homeNames: ["lisbon", "sintra"], endDate: nil, customName: "Spring"),
            key: tripKey + "v7|99fe27982b5cb9f95dddb65e5180f1f08cc7a53639d45e68c294e04b98f7b416"),
        FailureKeyFixture(name: "v7 nil order", shape: keyShape(
            [keyStay(0, locality: "Athens", admin: "Attica", country: "Greece", iso: "GR", hasOrder: false)]),
            key: tripKey + "v7|307038892fd48ddb56cd9f4a7ff272a7d3a38d522c19cf1c7dff16c6d732c3ba"),
        FailureKeyFixture(name: "v7 nil locality", shape: keyShape(
            [keyStay(0, locality: nil, country: "Greece", iso: "GR")]),
            key: tripKey + "v7|d4be202c88b16690ac87ebb0f9c887bf6ff51e9667e41723d0aee2b6345ba384"),
        FailureKeyFixture(name: "v7 empty locality", shape: keyShape(
            [keyStay(0, locality: "", country: "Greece", iso: "GR")]),
            key: tripKey + "v7|ebfb74b57696577dfc9d71f3d2ca9f76535493657a75726973e5b55bf0b3f423"),
        FailureKeyFixture(name: "v8 country-island locality", shape: keyShape([limassol]),
            key: tripKey + "v8|11c5c9b8d26db699a31ab6d7130da3188fa4c7e03e3afb1b7f13171e02acaff4"),
        FailureKeyFixture(name: "v8 island matched through the ISO name", shape: keyShape(
            [keyStay(0, island: "Cyprus", locality: "Paphos", country: nil, iso: "CY")]),
            key: tripKey + "v8|fda08dfada4133e0e530fbaf9e021ce6ad063e2d65bf19a202638f925328a6e0"),
        FailureKeyFixture(name: "v7 home locality beside an away island", shape: keyShape(
            [limassol, keyStay(2, island: "Aegina", locality: "Kypséli", country: "Greece", iso: "GR")],
            homeNames: ["limassol"]),
            key: tripKey + "v7|c0608fe6ce597e0f4d8b6a1f652db4401da5200b0538a88b056ddb92f8673a10"),
        FailureKeyFixture(name: "v7 airport country-island beside a city", shape: keyShape(
            [athens, keyStay(1, isAirport: true, island: "Cyprus", locality: "Larnaca", country: "Cyprus", iso: "CY")]),
            key: tripKey + "v7|2b356492f99346c616517362379be23d0e353d60194fce6327484e3fc7601913"),
        FailureKeyFixture(name: "v7 metro over a country island", shape: keyShape(
            [keyStay(0, metro: "Limassol", island: "Cyprus", locality: "Limassol", country: "Cyprus", iso: "CY")]),
            key: tripKey + "v7|ad51e62eee45a557f00926ab797200a6f19f9d54ef8c4cde3eae065ebbdbcedd"),
        FailureKeyFixture(name: "v9 country word in a city", shape: keyShape(
            [keyStay(0, metro: "Mexico City", locality: "Cuauhtémoc", country: "Mexico", iso: "MX")]),
            key: tripKey + "v9|c67a46e2410237093499fa2de37c0a8f5ff818d1a5e91f8732c00877835c43d4"),
        FailureKeyFixture(name: "v10 native-script place", shape: keyShape(
            [keyStay(0, locality: "Tromsø", country: "Norway", iso: "NO")]),
            key: tripKey + "v10|407bbf025f9e5c858bf99a9a87c49f2a3a347cdbb116a4f9cfab3fc1749219bf"),
        FailureKeyFixture(name: "v10 outranks v9 and v8", shape: keyShape(
            [limassol, keyStay(2, metro: "Mexico City", locality: "Roma", country: "Mexico", iso: "MX"),
             keyStay(3, locality: "Σύρος", country: "Greece", iso: "GR")]),
            key: tripKey + "v10|e55d248f89b050066509a1edf6616b1a51ef04464ff543a935d202ec84c40c26"),
        FailureKeyFixture(name: "v10 transit-only trip falls back to every stay", shape: keyShape(
            [keyStay(0, category: "transit", locality: "Tromsø", country: "Norway", iso: "NO")]),
            key: tripKey + "v10|e381007550cdd4cead744edc9df6d49ea27dfd466f8f8153d5d4feff0fdd5718"),
        FailureKeyFixture(name: "v7 unknown category beside a destination", shape: keyShape(
            [athens, keyStay(1, category: "bogus", locality: "Tromsø", country: "Norway", iso: "NO")]),
            key: tripKey + "v7|211decd652854e63bdbd808444f0c32c5f14728faf58d6e6329b52f7458d5c21"),
        FailureKeyFixture(name: "v10 unknown category with no destination", shape: keyShape(
            [keyStay(0, category: "bogus", locality: "Tromsø", country: "Norway", iso: "NO")]),
            key: tripKey + "v10|562fd261bb1cb47e496c9e0a29c1916f0e76d577c6ceb7efb25985212b57b1fb"),
    ]

    @Test("failure keys are byte-identical for fixed shapes", arguments: failureKeyFixtures)
    func failureKeysAreExact(fixture: FailureKeyFixture) async throws {
        #expect(TripTitlePolicy.titleFailureKey(for: fixture.shape) == fixture.key)
        let classifier = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        let key = await classifier.canonicalTitleFailureKeyForTesting(fixture.shape)
        #expect(key == fixture.key)
    }
}
