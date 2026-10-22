//
//  ShotBugsRegressionTests.swift
//  TravelLogTests
//
//  Bugs found while making the App Store screenshots: title work reading a
//  trip row deleted while inference awaited, bracketed source qualifiers in
//  place names, a lone elision apostrophe stripped from titles, the
//  unregistered `travellog://` scheme, and import legs left unclassified for
//  flights until later launches.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Screenshot bugs", .serialized, IsolatedTitleDefaults())
struct ShotBugsRegressionTests {

    private nonisolated static func insertTrip(
        locality: String, startOffsetDays: Double, in context: ModelContext
    ) -> Trip {
        let start = Date(timeIntervalSinceReferenceDate: 826_611_200 + startOffsetDays * 86_400)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3 * 60 * 60),
                        centroidLatitude: 44.3, centroidLongitude: 12.9, h3IndexRes6: "8a2a1072b59ffff",
                        pingCount: 2, distanceFromHomeKm: 400, pingIDs: [])
        stay.category = .destination
        stay.locality = locality
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
        return trip
    }

    // MARK: - Title work and deleted rows

    @Test("a trip row deleted and saved is not found by its identifier, and reading it does not trap")
    func fetchTripSkipsDeletedRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let found = try await classifier.runIsolated { c -> Bool in
            let trip = Self.insertTrip(locality: "Testville", startOffsetDays: 0, in: c.modelContext)
            try c.modelContext.save()
            let id = trip.id
            let identifier = trip.persistentModelID
            #expect(c.fetchTrip(tripID: id, tripIdentifier: identifier) != nil)
            c.modelContext.delete(trip)
            try c.modelContext.save()
            return c.fetchTrip(tripID: id, tripIdentifier: identifier) != nil
        }
        #expect(!found)
    }

    @Test("Stage 5 skips a candidate deleted while its title was inferred and titles the rest",
          .timeLimit(.minutes(1)))
    func stageFiveSurvivesDeletionDuringInference() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let doomed = Self.insertTrip(locality: "Testville", startOffsetDays: 10, in: context)
        let kept = Self.insertTrip(locality: "Sampleton", startOffsetDays: 0, in: context)
        try context.save()
        let doomedID = doomed.id
        let keptID = kept.id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await classifier.setTitleGenerationOverrideForTesting { id in
            if id == doomedID {
                // A classification unit deletes the row while the model runs.
                try? await classifier.runIsolated { c in
                    let target = doomedID
                    for trip in try c.modelContext.fetch(FetchDescriptor<Trip>(
                        predicate: #Predicate { $0.id == target })) {
                        c.modelContext.delete(trip)
                    }
                    try c.modelContext.save()
                }
                return "Testville Days"
            }
            return "Sampleton Days"
        }
        let generated = await classifier.generateTitlesStage(maxTripsPerCall: nil, applyGate: gate)
        #expect(generated == 1)
        #expect(await classifier.aiTitleFieldsForTesting(doomedID) == nil)
        #expect(await classifier.aiTitleFieldsForTesting(keptID)?.title == "Sampleton Days")
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("an ensure whose trip is deleted while its title is inferred returns nothing", .timeLimit(.minutes(1)))
    func ensureSurvivesDeletionDuringInference() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Self.insertTrip(locality: "Testville", startOffsetDays: 0, in: context)
        try context.save()
        let tripID = trip.id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await classifier.setTitleGenerationOverrideForTesting { _ in
            try? await classifier.runIsolated { c in
                let target = tripID
                for row in try c.modelContext.fetch(FetchDescriptor<Trip>(
                    predicate: #Predicate { $0.id == target })) {
                    c.modelContext.delete(row)
                }
                try c.modelContext.save()
            }
            return "Testville Days"
        }
        #expect(await classifier.ensureCanonicalTitle(for: tripID, gate: gate) == nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    // MARK: - Titles after an import

    @Test("a drain that finds nothing to classify still refills titles a trip waits for")
    func drainRefillsPendingTitles() async {
        let log = EventLog()
        let drain = ForegroundClassificationDrain(environment: .init(
            bite: { _, _ in .init(completed: true, classified: 0) },
            backlog: { 0 },
            titlesPending: { true },
            titles: { await log.record("titles") },
            mayRun: { true },
            systemAllowsWork: { true },
            modelBatch: 20))
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(log.events == ["titles"])
    }

    @Test("a refill that waits for the pass in flight runs its own, even when that pass's caller is cancelled",
          .timeLimit(.minutes(1)))
    func waitingRefillSurvivesCancelledPass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = Self.insertTrip(locality: "Testville", startOffsetDays: 10, in: context)
        let second = Self.insertTrip(locality: "Sampleton", startOffsetDays: 0, in: context)
        try context.save()
        let firstID = first.id
        let secondID = second.id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let hold = TestLatch()
        let calls = CallCounter()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await classifier.setTitleGenerationOverrideForTesting { id in
            if await calls.next() == 1 {
                continuation.yield()
                await hold.wait()
            }
            return id == firstID ? "Testville Days" : "Sampleton Days"
        }
        // Another caller's capped pass is in flight, then its task is cancelled.
        let other = Task { await classifier.generateTitlesStage(maxTripsPerCall: 1, applyGate: gate) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let refill = Task {
            await classifier.generateTitlesStage(
                maxTripsPerCall: nil, applyGate: gate, waitingForInFlight: true)
        }
        // Let the refill reach the actor while the other pass is held.
        try await Task.sleep(for: .milliseconds(500))
        other.cancel()
        await hold.release()
        _ = await other.value
        #expect(await refill.value == 2)
        #expect(await classifier.aiTitleFieldsForTesting(firstID)?.title == "Testville Days")
        #expect(await classifier.aiTitleFieldsForTesting(secondID)?.title == "Sampleton Days")
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    // MARK: - Place names

    @Test("a source's bracketed qualifier is not part of the place name")
    func primaryPlaceName() {
        let cases: [(String, String)] = [
            ("Testville [Sampleton]", "Testville"),
            ("Northport [prefecture]", "Northport"),
            ("Lakeside (Old Town) [Fraccionamiento]", "Lakeside (Old Town)"),
            ("Riverton (Saale)", "Riverton (Saale)"),
            ("'s-Testbosch", "'s-Testbosch"),
            ("[Escuela]", "[Escuela]"),
            ("Testville", "Testville"),
        ]
        for (raw, expected) in cases {
            #expect(GeocodeResolver.primaryPlaceName(raw) == expected, "\(raw)")
        }
    }

    @Test("a two-core metro whose cores cannot be placed is named by the core the locality is, else its main city")
    func twoCoreMetroName() {
        let unplaced = GeocodeResolver.TwoCoreMetroCores(primary: nil, qualifier: nil)
        func name(_ raw: String, locality: String?) -> String {
            GeocodeResolver.metroPlaceName(raw, latitude: 44.3, longitude: 12.9, cores: unplaced, locality: locality)
        }
        #expect(name("Testville [Sampleton]", locality: "Sampleton") == "Sampleton")
        #expect(name("Testville [Sampléton]", locality: "sampleton") == "Sampléton")
        #expect(name("Testville [Sampleton]", locality: "Testville") == "Testville")
        #expect(name("Testville [Sampleton]", locality: "Smallbrook") == "Testville")
        #expect(name("Testville [Sampleton]", locality: nil) == "Testville")
        #expect(name("Testville", locality: "Sampleton") == "Testville")
    }

    @Test("a district of a two-core metro's second city is named by that city, whatever the district is called")
    func twoCoreMetroNamedByNearerCore() {
        // Testville's centre lies southwest of Sampleton's; a ward of Sampleton
        // has its own locality name, which never equals either core's.
        let cores = GeocodeResolver.TwoCoreMetroCores(
            primary: (latitude: 44.0, longitude: 12.6), qualifier: (latitude: 44.3, longitude: 12.9))
        func name(latitude: Double, longitude: Double, locality: String?) -> String {
            GeocodeResolver.metroPlaceName(
                "Testville [Sampleton]", latitude: latitude, longitude: longitude, cores: cores, locality: locality)
        }
        #expect(name(latitude: 44.32, longitude: 12.88, locality: "Upper Ward") == "Sampleton")
        #expect(name(latitude: 44.3, longitude: 12.9, locality: nil) == "Sampleton")
        #expect(name(latitude: 44.02, longitude: 12.63, locality: "Harbour Ward") == "Testville")
        #expect(GeocodeResolver.metroPlaceName(
            "Testville", latitude: 44.32, longitude: 12.88, cores: cores, locality: "Upper Ward") == "Testville")
    }

    @Test("a name's leading elision apostrophe survives title cleanup; wrapping quotes still go")
    func elisionApostropheKept() {
        #expect(TripTitlePolicy.normalizeAITitle("'s-Hertogenbosch") == "'s-Hertogenbosch")
        #expect(TripTitlePolicy.normalizeAITitle("'t Zand & Leiden") == "'t Zand & Leiden")
        #expect(TripTitlePolicy.normalizeAITitle("\"'s-Hertogenbosch\"") == "'s-Hertogenbosch")
        #expect(TripTitlePolicy.normalizeAITitle("'Tokyo'") == "Tokyo")
        #expect(TripTitlePolicy.normalizeAITitle("\"White Plains") == "White Plains")
    }

    @Test("a one-place title keeps its elision apostrophe and validates")
    func elisionTitleValidates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = Self.insertTrip(locality: "'s-Testbosch", startOffsetDays: 0, in: ModelContext(container))
            let material = c.titlePromptMaterial(for: trip)
            let choices = TripTitleSchema.choices(for: material.candidates)
            #expect(choices.count == 1)
            let only = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: choices, candidates: material.candidates, titleSpellings: material.titleSpellings))
            #expect(only == "'s-Testbosch")
            #expect(c.titleValidationFailure(only, for: trip) == nil)
        }
    }

    // MARK: - Day counts

    @Test("Wrapped's longest-trip days are the trip's own day count, read in its boundary stays' zones")
    func wrappedDaysAreTripDays() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Self.insertTrip(locality: "Testville", startOffsetDays: 0, in: context)
        let stays = trip.stays ?? []
        // Late in the evening in a zone west of the device's: a different civil day there.
        for stay in stays { stay.timeZoneIdentifier = "GMT-1000" }
        let last = try #require(stays.first)
        let later = Stay(startTime: last.startTime.addingTimeInterval(10 * 86_400),
                         endTime: last.startTime.addingTimeInterval(10 * 86_400 + 3_600),
                         centroidLatitude: 44.3, centroidLongitude: 12.9, h3IndexRes6: "8a2a1072b59ffff",
                         pingCount: 2, distanceFromHomeKm: 400, pingIDs: [])
        later.timeZoneIdentifier = "GMT+1000"
        context.insert(later)
        later.trip = trip
        trip.endDate = later.endTime
        let days = try #require(trip.durationDays)
        #expect(YearWrappedGenerator.effectiveDurationDays(trip) == days)
        #expect(YearWrappedGenerator.longestTrip(in: [trip]).map { YearWrappedGenerator.effectiveDurationDays($0) } == days)
    }

    // MARK: - Deep links

    @Test("the app registers the travellog scheme its widgets link to")
    func urlSchemeRegistered() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("travellog"))
        #expect(OpenedFile.kind(of: try #require(URL(string: "travellog://stats"))) == .other)
    }

    // MARK: - Flights after an import

    @Test("the foreground drain classifies inbound legs before its first bite, even with nothing to classify",
          .timeLimit(.minutes(1)))
    func drainClassifiesTransitFirst() async {
        let log = EventLog()
        func drain(backlog: Int) -> ForegroundClassificationDrain {
            ForegroundClassificationDrain(environment: .init(
                bite: { _, _ in
                    await log.record("bite")
                    return .init(completed: true, classified: backlog)
                },
                backlog: { log.biteCount > 0 ? 0 : backlog },
                titles: { await log.record("titles") },
                transit: { policy in await log.record(policy() ? "transit" : "transit refused"); return .exhausted },
                mayRun: { true },
                systemAllowsWork: { true },
                modelBatch: 20))
        }
        let first = drain(backlog: 30)
        first.request()
        #expect(await first.waitUntilIdle() == .drained)
        #expect(log.events == ["transit", "bite", "titles"])
        log.events.removeAll()
        let second = drain(backlog: 0)
        second.request()
        #expect(await second.waitUntilIdle() == .drained)
        #expect(log.events == ["transit"])
    }
}

private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

@MainActor
private final class EventLog {
    var events: [String] = []
    var biteCount: Int { events.filter { $0 == "bite" }.count }
    func record(_ event: String) { events.append(event) }
}
