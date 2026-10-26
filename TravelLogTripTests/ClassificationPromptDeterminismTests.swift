import CoreLocation
import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

/// The Stage 2 prompt is rebuilt inside the apply unit and compared with the
/// one the model answered. Everything it renders must be a pure function of
/// the validated inputs, or a batch whose inputs never changed is discarded on
/// every pass and its stays are never classified.
@MainActor
@Suite("Classification prompt determinism", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct ClassificationPromptDeterminismTests {

    private static func day(_ value: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 700_000_000 + value * 86_400)
    }

    nonisolated private static let settledPlace = (lat: 44.3, lon: 12.9)
    nonisolated private static let firstPendingPlace = (lat: 44.9, lon: 14.1)

    /// A settled stay, then four unclassified stays: the first 116 to 117 km
    /// from the settled one, the pair CoreLocation measures either way.
    private func distanceFixture() throws -> (ModelContainer, [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Self.day(0)
        let settled = Stay(startTime: start, endTime: start.addingTimeInterval(8 * 3600),
            centroidLatitude: Self.settledPlace.lat, centroidLongitude: Self.settledPlace.lon,
            h3IndexRes6: "prompt-settled", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [])
        settled.category = .destination
        settled.locality = "Settled"
        settled.country = "Testland"
        context.insert(settled)
        let places = [Self.firstPendingPlace, (lat: 45.2, lon: 14.6), (lat: 45.6, lon: 15.1), (lat: 45.9, lon: 15.8)]
        var pending: [UUID] = []
        for (k, place) in places.enumerated() {
            let begin = start.addingTimeInterval(Double(k + 1) * 86_400)
            let stay = Stay(startTime: begin, endTime: begin.addingTimeInterval(6 * 3600),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: "prompt-pending-\(k)", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [])
            stay.locality = "Pending \(k)"
            stay.country = "Testland"
            context.insert(stay)
            pending.append(stay.id)
        }
        try context.save()
        return (container, pending)
    }

    nonisolated private static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }

    /// `CLLocation.distance(from:)` reuses state from earlier measurements,
    /// on any thread. Unrelated measurements while the model answers can
    /// leave it measuring the first numbered stay's pair differently from
    /// the prompt the model saw; stop at the first that does.
    nonisolated private static func measureUnrelatedPlaces(until prompt: String) {
        guard let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("[0] ") }),
              let range = line.range(of: #"\d+km from prev"#, options: .regularExpression),
              let shown = Int(line[range].prefix { $0.isNumber }) else { return }
        let unrelated = [(-30.0, 100.0, -31.0, 120.0), (44.3, 12.9, 44.306, 14.9),
                         (44.9, 14.1, 44.3, 12.9), (10.0, 10.0, 44.3, 12.9)]
        for place in unrelated {
            _ = distance((place.0, place.1), (place.2, place.3))
            let km = Int((distance(settledPlace, firstPendingPlace) / 1000).rounded())
            if km != shown { return }
        }
    }

    @Test("a batch whose inputs did not change applies after unrelated distance measurements")
    func unrelatedDistanceWorkKeepsTheBatch() async throws {
        let (container, pending) = try distanceFixture()
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ prompt in
                calls.withLock { $0 += 1 }
                Self.measureUnrelatedPlaces(until: prompt)
                return (0..<4).map { .init(stayIndex: $0, category: "destination") }
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(
                    reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))
            }
        }
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(calls.withLock { $0 } == 1)
        for id in pending {
            #expect(stays.first { $0.id == id }?.category == .destination)
        }
    }

    // MARK: - Canonical order

    private static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test("homes, routine places and temporary homes render in one order however they were stored")
    func placeOrderIsCanonical() async throws {
        var prompts = Set<String>()
        for order in [[0, 1, 2], [2, 0, 1], [1, 2, 0], [2, 1, 0]] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            for i in order {
                let home = Home(label: "Home \(i)", latitude: 44.3 + Double(i), longitude: 12.9,
                    startedAt: Self.day(-400))
                home.id = Self.fixedID(10 - i)
                context.insert(home)
                let routine = RoutinePlace(label: "Routine \(i)", latitude: 44.3 + Double(i), longitude: 13.0,
                    startedAt: Self.day(-400))
                routine.id = Self.fixedID(20 - i)
                context.insert(routine)
                let temporary = TemporaryHome(label: "Temporary \(i)", latitude: 45.0, longitude: 14.0 + Double(i),
                    startedAt: Self.day(-10), endedAt: Self.day(10))
                temporary.id = Self.fixedID(30 - i)
                context.insert(temporary)
            }
            let stay = Stay(startTime: Self.day(0), endTime: Self.day(0.25), centroidLatitude: 46, centroidLongitude: 15,
                h3IndexRes6: "prompt-order", pingCount: 4, distanceFromHomeKm: 120, pingIDs: [])
            stay.id = Self.fixedID(40)
            context.insert(stay)
            try context.save()
            let classifier = TripClassifier(modelContainer: container)
            let prompt = try await classifier.runIsolated { classifier in
                try classifier.buildPrompt(stays: classifier.modelContext.fetch(FetchDescriptor<Stay>()))
            }
            #expect(prompt.contains("Home: Home 2"))
            #expect(prompt.contains("Routine places: Routine 2, Routine 1, Routine 0"))
            prompts.insert(prompt)
        }
        #expect(prompts.count == 1)
    }

    @Test("stays starting together keep one order in the batch and the prompt")
    func equalStartTimesKeepOneOrder() async throws {
        var batches = Set<[UUID]>()
        var prompts = Set<String>()
        for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2]] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            for i in order {
                // Two settled neighbours and two pending stays share each start.
                for (offset, settled) in [(0.0, true), (1.0, false)] {
                    let start = Self.day(offset)
                    let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
                        centroidLatitude: 44.3 + Double(i) * 0.4, centroidLongitude: 12.9 + offset,
                        h3IndexRes6: "prompt-tie-\(i)-\(offset)", pingCount: 4, distanceFromHomeKm: 50, pingIDs: [])
                    stay.id = Self.fixedID(Int(offset) * 10 + i)
                    stay.locality = "Place \(i)-\(Int(offset))"
                    stay.country = "Testland"
                    if settled { stay.category = .destination }
                    context.insert(stay)
                }
            }
            try context.save()
            let classifier = TripClassifier(modelContainer: container)
            let batch = try await classifier.runIsolated { try $0.fetchStage2Batch(cap: 60, priorityIDs: []).map(\.id) }
            batches.insert(batch)
            prompts.insert(try await classifier.runIsolated { classifier in
                let rows = try classifier.fetchStage2Batch(cap: 60, priorityIDs: [])
                return try classifier.buildPrompt(stays: rows)
            })
        }
        #expect(batches.count == 1)
        #expect(prompts.count == 1)
    }

    // MARK: - Formatting context

    @Test("a time zone change while the model answers keeps the batch, rendered in the zone it was prepared in")
    func timeZoneChangeKeepsTheBatch() async throws {
        let (container, pending) = try distanceFixture()
        let classifier = TripClassifier(modelContainer: container)
        let zone = OSAllocatedUnfairLock(initialState: TimeZone(secondsFromGMT: 0)!)
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        await TripClassifier.PromptTestHook.$timeZone.withValue({ zone.withLock { $0 } }) {
            await StayClassificationInference.TestHook.$availability.withValue(true) {
                await StayClassificationInference.TestHook.$response.withValue({ prompt in
                    prompts.withLock { $0.append(prompt) }
                    zone.withLock { $0 = TimeZone(secondsFromGMT: 9 * 3600)! }
                    return (0..<4).map { .init(stayIndex: $0, category: "destination") }
                }) {
                    _ = await classifier.classifyAndAssembleTripsWithGates(
                        reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))
                }
            }
        }
        let first = try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == pending[0] }
        let start = try #require(first?.startTime)
        #expect(prompts.withLock { $0 }.first?.contains(
            FMPromptFormat.numericDateAndShortTime(start, timeZone: TimeZone(secondsFromGMT: 0)!)) == true)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        for id in pending {
            #expect(stays.first { $0.id == id }?.category == .destination)
        }
    }

    // MARK: - Safety net

    /// A rebuilt prompt that never matches, whatever the inputs.
    nonisolated private static func diverging(_ snapshot: ClassificationPromptSnapshot) -> ClassificationPromptSnapshot {
        ClassificationPromptSnapshot(homes: snapshot.homes, temporaryHomes: snapshot.temporaryHomes,
            routinePlaces: snapshot.routinePlaces + ["Diverging"], lines: snapshot.lines,
            ids: snapshot.ids, timeZone: snapshot.timeZone)
    }

    private func pass(_ classifier: TripClassifier, calls: OSAllocatedUnfairLock<Int>) async {
        await TripClassifier.PromptTestHook.$rebuilt.withValue(Self.diverging) {
            await StayClassificationInference.TestHook.$availability.withValue(true) {
                await StayClassificationInference.TestHook.$response.withValue({ _ in
                    calls.withLock { $0 += 1 }
                    return (0..<4).map { .init(stayIndex: $0, category: "transit") }
                }) {
                    _ = await classifier.classifyAndAssembleTripsWithGates(
                        reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))
                }
            }
        }
    }

    private func categories(_ container: ModelContainer, _ ids: [UUID]) throws -> [StayCategory?] {
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        return ids.map { id in stays.first { $0.id == id }?.category }
    }

    @Test("a batch rejected for unchanged inputs on consecutive passes is settled by the heuristic, without the model")
    func repeatedPromptRejectionSettlesTheBatch() async throws {
        let (container, pending) = try distanceFixture()
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // The first pass also assembles the settled stay's trip, a dependency
        // change; the count starts on the next.
        let passes = 1 + TripClassifier.promptRejectionSettleThreshold
        for _ in 0..<passes {
            await pass(classifier, calls: calls)
            #expect(try categories(container, pending).allSatisfy { $0 == .unclassified })
        }
        #expect(calls.withLock { $0 } == passes)
        await pass(classifier, calls: calls)
        // No further model call; the six-hour stays take the heuristic's destination.
        #expect(calls.withLock { $0 } == passes)
        #expect(try categories(container, pending).allSatisfy { $0 == .destination })
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(!trips.isEmpty)
        #expect(trips.allSatisfy { !$0.classifiedByAI })
    }

    @Test("a changed input starts the rejection count again")
    func changedInputRestartsTheCount() async throws {
        let (container, pending) = try distanceFixture()
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let passes = 1 + TripClassifier.promptRejectionSettleThreshold
        for _ in 0..<passes {
            await pass(classifier, calls: calls)
        }
        let context = ModelContext(container)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first { $0.id == pending[1] })
        stay.locality = "Renamed"
        try context.save()
        await pass(classifier, calls: calls)
        // A new batch for the model, discarded again rather than settled.
        #expect(calls.withLock { $0 } == passes + 1)
        #expect(try categories(container, pending).allSatisfy { $0 == .unclassified })
    }
}
