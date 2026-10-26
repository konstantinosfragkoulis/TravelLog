import Foundation
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
private actor ClassificationResponseScript {
    enum Step: Sendable {
        case answer([StayClassificationInference.Classification])
        case fail
        case cancelThenAnswer([StayClassificationInference.Classification])
    }

    private var steps: [Step]
    private(set) var prompts: [String] = []
    private(set) var categoryBeforeRetry: String?

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func recordCategoryBeforeRetry(_ category: String?) {
        categoryBeforeRetry = category
    }

    func respond(to prompt: String) throws -> [StayClassificationInference.Classification] {
        prompts.append(prompt)
        guard !steps.isEmpty else { throw CocoaError(.coderInvalidValue) }
        switch steps.removeFirst() {
        case .answer(let classifications):
            return classifications
        case .fail:
            throw CocoaError(.coderReadCorrupt)
        case .cancelThenAnswer(let classifications):
            // Simulate respond returning output despite cancellation of the
            // invocation task, without a timing-dependent sleep or real FM.
            withUnsafeCurrentTask { $0?.cancel() }
            return classifications
        }
    }
}

@MainActor
@Suite("Classification inference lifecycle", IsolatedTitleDefaults())
struct ClassifierInferenceLifecycleTests {
    private func fixture(
        count: Int, includeDeterministicStay: Bool = false
    ) throws -> (container: ModelContainer, ids: [UUID]) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [UUID] = []
        for index in 0..<(count + (includeDeterministicStay ? 1 : 0)) {
            let start = base.addingTimeInterval(Double(index) * 8 * 86400)
            // Six hours is ambiguous to Stage 2a but always destination in
            // the heuristic lane, so a model transit verdict is observable.
            let minutes = index == count ? 8000 : 360
            let stay = Stay(
                startTime: start,
                endTime: start.addingTimeInterval(Double(minutes) * 60),
                centroidLatitude: 0, centroidLongitude: 0,
                h3IndexRes6: "inference-\(index)", pingCount: 2,
                distanceFromHomeKm: 200, pingIDs: [])
            stay.locality = "Place \(index)"
            stay.country = "Greece"
            context.insert(stay)
            ids.append(stay.id)
        }
        try context.save()
        return (container, ids)
    }

    private func categories(in container: ModelContainer, ids: [UUID]) throws -> [String] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Stay>())
        return try ids.map { id in
            let stay = try #require(rows.first { $0.id == id })
            return stay.categoryRaw
        }
    }

    private func onlyTripAIFlag(in container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 1)
        return try #require(trips.first).classifiedByAI
    }

    private func run(
        classifier: TripClassifier,
        script: ClassificationResponseScript,
        fmAvailable: Bool = true
    ) async -> (created: Int, needsPublication: Bool, completed: Bool) {
        let gate = PipelineGate(forTesting: ())
        return await Task {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false,
                gate: gate, fmAvailable: fmAvailable,
                response: { try await script.respond(to: $0) })
        }.value
    }

    @Test("responses remain uncommitted until validation; first verdict wins across coverage retry")
    func coverageRetryPreservesAppliedResponse() async throws {
        let (container, ids) = try fixture(count: 3)
        let classifier = TripClassifier(modelContainer: container)
        let firstID = ids[0]
        let script = ClassificationResponseScript([
            .answer([
                .init(stayIndex: 0, category: "transit"),
                .init(stayIndex: 0, category: "destination"),
                .init(stayIndex: -1, category: "destination"),
                .init(stayIndex: 3, category: "destination")
            ]),
            .answer([
                .init(stayIndex: 0, category: "destination"),
                .init(stayIndex: 1, category: "transit"),
                .init(stayIndex: 1, category: "destination"),
                .init(stayIndex: 2, category: "destination")
            ])
        ])
        let gate = PipelineGate(forTesting: ())
        let outcome = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false,
                gate: gate, fmAvailable: true,
                response: { prompt in
                    if prompt.hasPrefix("You omitted indices") {
                        let category = await classifier.stayCategoryForTesting(firstID)
                        await script.recordCategoryBeforeRetry(category?.rawValue)
                    }
                    return try await script.respond(to: prompt)
                })

        #expect(outcome.created == 1 && outcome.needsPublication)
        #expect(try categories(in: container, ids: ids) == ["transit", "transit", "destination"])
        #expect(try onlyTripAIFlag(in: container))
        #expect(await script.categoryBeforeRetry == "unclassified")
        let prompts = await script.prompts
        #expect(prompts.count == 2)
        #expect(try #require(prompts.last).hasPrefix("You omitted indices 1, 2."))
        #expect(StayClassificationInference.TestHook.availability == nil)
        #expect(StayClassificationInference.TestHook.response == nil)
    }

    @Test("failed coverage retry preserves FM output and heuristically fills only omissions")
    func failedRetryRetainsFirstResponse() async throws {
        let (container, ids) = try fixture(count: 2, includeDeterministicStay: true)
        let script = ClassificationResponseScript([
            .answer([.init(stayIndex: 0, category: "transit")]), .fail
        ])
        let outcome = await run(classifier: TripClassifier(modelContainer: container), script: script)

        #expect(outcome.created == 1 && outcome.needsPublication)
        #expect(try categories(in: container, ids: ids) == ["transit", "destination", "destination"])
        #expect(try onlyTripAIFlag(in: container))
        #expect(await script.prompts.count == 2)
    }

    @Test("throwing initial response uses heuristics and does not credit Stage 2a as FM")
    func initialFailurePreservesHeuristicProvenance() async throws {
        let (container, ids) = try fixture(count: 2, includeDeterministicStay: true)
        let script = ClassificationResponseScript([.fail])
        let outcome = await run(classifier: TripClassifier(modelContainer: container), script: script)

        #expect(outcome.created == 1 && outcome.needsPublication)
        #expect(try categories(in: container, ids: ids) == Array(repeating: "destination", count: 3))
        #expect(try !onlyTripAIFlag(in: container))
        #expect(await script.prompts.count == 1)
    }

    @Test("initial response returned after cancellation is discarded; all uncommitted stays defer")
    func cancelledInitialResponseDefersUncommittedBatch() async throws {
        let (container, ids) = try fixture(count: 21)
        let script = ClassificationResponseScript([
            .cancelThenAnswer([.init(stayIndex: 0, category: "transit")])
        ])
        let outcome = await run(classifier: TripClassifier(modelContainer: container), script: script)

        #expect(outcome.created == 0 && !outcome.needsPublication)
        // The gated lane commits only after both response turns and validation.
        let expected = Array(repeating: "unclassified", count: 21)
        #expect(try categories(in: container, ids: ids) == expected)
        #expect(await script.prompts.count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(!Task.isCancelled, "only the invocation task was cancelled")
    }

    @Test("cancellation during correction discards the uncommitted batch and defers later batches")
    func cancelledRetryDefersUncommittedBatch() async throws {
        let (container, ids) = try fixture(count: 21)
        let script = ClassificationResponseScript([
            .answer([.init(stayIndex: 0, category: "transit")]),
            .cancelThenAnswer([.init(stayIndex: 1, category: "transit")])
        ])
        let outcome = await run(classifier: TripClassifier(modelContainer: container), script: script)

        #expect(outcome.created == 0 && !outcome.needsPublication)
        let expected = Array(repeating: "unclassified", count: 21)
        #expect(try categories(in: container, ids: ids) == expected)
        #expect(await script.prompts.count == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(!Task.isCancelled, "only the invocation task was cancelled")
    }

    @Test("cancelling a later batch preserves earlier committed classifications and publication")
    func cancellationRetainsEarlierCommittedBatch() async throws {
        let (container, ids) = try fixture(count: 21)
        let script = ClassificationResponseScript([
            .answer((0..<20).map { .init(stayIndex: $0, category: "transit") }),
            .cancelThenAnswer([.init(stayIndex: 0, category: "destination")])
        ])
        let outcome = await run(classifier: TripClassifier(modelContainer: container), script: script)
        #expect(outcome.created == 0 && outcome.needsPublication)
        #expect(try categories(in: container, ids: ids) == Array(repeating: "transit", count: 20) + ["unclassified"])
        #expect(await script.prompts.count == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(!Task.isCancelled)
    }

    @Test("invocation-scoped unavailable override bypasses model responses and retains heuristic provenance")
    func unavailableOverrideUsesProductionHeuristicLane() async throws {
        let (container, ids) = try fixture(count: 2, includeDeterministicStay: true)
        let script = ClassificationResponseScript([])
        let outcome = await run(
            classifier: TripClassifier(modelContainer: container), script: script, fmAvailable: false)

        #expect(outcome.created == 1 && outcome.needsPublication)
        #expect(try categories(in: container, ids: ids) == Array(repeating: "destination", count: 3))
        #expect(try !onlyTripAIFlag(in: container))
        #expect(await script.prompts.isEmpty)
        #expect(StayClassificationInference.TestHook.availability == nil)
        #expect(StayClassificationInference.TestHook.response == nil)
    }
}
#endif
