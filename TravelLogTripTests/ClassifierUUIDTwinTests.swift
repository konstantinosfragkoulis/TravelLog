//
//  ClassifierUUIDTwinTests.swift
//  TravelLogTests
//
//  Same-UUID Stay twins are one logical stay for Stage 2 classification:
//  one decision with real chronological neighbours, copied to every eligible
//  physical copy, in one pass for the whole cohort. Driven through the gated
//  pipeline entry the app calls.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classifier UUID twins", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct ClassifierUUIDTwinTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    private func stay(
        _ ctx: ModelContext, hours: Double, minutes: Int, latitude: Double,
        locality: String, distance: Double, category: StayCategory = .unclassified, id: UUID? = nil
    ) -> Stay {
        let begin = Self.start.addingTimeInterval(hours * 3600)
        let row = Stay(startTime: begin, endTime: begin.addingTimeInterval(Double(minutes) * 60),
            centroidLatitude: latitude, centroidLongitude: 0, h3IndexRes6: "twin-\(locality)",
            pingCount: 2, distanceFromHomeKm: distance, pingIDs: [])
        row.locality = locality
        row.country = "Greece"
        row.category = category
        if let id { row.id = id }
        ctx.insert(row)
        return row
    }

    private func twins(_ id: UUID, _ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>()).filter { $0.id == id }
    }

    @Test("twins are decided once, beside the real previous stay, and the decision reaches every copy")
    func twinsAreOneDecision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 360, latitude: 0, locality: "Before", distance: 200, category: .destination)
        let twinID = UUID()
        for _ in 0..<2 {
            stay(ctx, hours: 8, minutes: 60, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        }
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category == .destination }, "the decision reaches every physical copy")
    }

    @Test("a settled twin keeps its category while its unclassified copy is decided")
    func settledTwinKeepsItsCategory() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 360, latitude: 0, locality: "Before", distance: 200, category: .destination)
        let twinID = UUID()
        let settled = stay(ctx, hours: 8, minutes: 60, latitude: 1, locality: "Twinville", distance: 200,
                           category: .transit, id: twinID)
        stay(ctx, hours: 8, minutes: 60, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        try ctx.save()
        let settledRow = settled.persistentModelID

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.first { $0.persistentModelID == settledRow }?.category == .transit,
                "a settled copy keeps its category")
        #expect(rows.first { $0.persistentModelID != settledRow }?.category == .destination)
    }

    /// Settled history is not reopened to make copies agree: Stage 2 decides the
    /// re-decided copy alone, and the sanity pass then judges both copies by the earlier one.
    @Test("a settled earlier copy beside a re-decided longer copy", arguments: [StayCategory.transit, .destination])
    func settledEarlierCopyBesideReDecidedCopy(settled: StayCategory) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 360, latitude: 0, locality: "Before", distance: 200, category: .destination)
        let twinID = UUID()
        // A settled destination this short exists only until the sanity pass, e.g. just synced.
        stay(ctx, hours: 8, minutes: 15, latitude: 1, locality: "Twinville", distance: 200,
             category: settled, id: twinID)
        let fresh = stay(ctx, hours: 8.5, minutes: 180, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        try ctx.save()
        let freshRow = fresh.persistentModelID

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.first { $0.persistentModelID != freshRow }?.category == .transit)
        #expect(rows.first { $0.persistentModelID == freshRow }?.category
                    == (settled == .transit ? .destination : .transit),
                "a settled transit copy and its re-decided copy may disagree; a settled blip destination corrects both")
        #expect(await classifier.sanityFixpointViolatedForTesting() == false, "the pair converges")
    }

    @Test("the heuristic lane gives twins their real neighbours")
    func heuristicTwinsSeeRealNeighbours() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Home, a brief stop 10 km out, then a destination 50 km out: the
        // journey test needs home before the stop and the far stay after it,
        // not the stop's own twin (0 km away).
        stay(ctx, hours: 0, minutes: 600, latitude: 0, locality: "Home", distance: 0, category: .home)
        let twinID = UUID()
        for _ in 0..<2 {
            stay(ctx, hours: 11, minutes: 45, latitude: 0.09, locality: "Twinville", distance: 10, id: twinID)
        }
        stay(ctx, hours: 13, minutes: 600, latitude: 0.45, locality: "Far", distance: 50, category: .destination)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category == .transit },
                "each copy sees home before and the far destination after, not its twin")
    }

    @Test("a per-call cap that cuts between twins still admits the whole cohort")
    func capAdmitsWholeCohort() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 30, latitude: 0, locality: "First", distance: 200)
        stay(ctx, hours: 2, minutes: 30, latitude: 0, locality: "Second", distance: 200)
        let twinID = UUID()
        for _ in 0..<2 {
            stay(ctx, hours: 4, minutes: 30, latitude: 0, locality: "Twinville", distance: 200, id: twinID)
        }
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, maxStaysPerCall: 3, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category != .unclassified }, "one pass decides every copy")
        #expect(Set(rows.map(\.category)).count == 1)
    }

    @Test("a failed cohort-completion read commits neither twin")
    func failedCohortReadCommitsNeitherTwin() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 30, latitude: 0, locality: "First", distance: 200)
        stay(ctx, hours: 2, minutes: 30, latitude: 0, locality: "Second", distance: 200)
        let twinID = UUID()
        for _ in 0..<2 {
            stay(ctx, hours: 4, minutes: 30, latitude: 0, locality: "Twinville", distance: 200, id: twinID)
        }
        try ctx.save()

        // The cap of 3 admits one copy; only the cohort read would admit the other.
        let classifier = TripClassifier(modelContainer: container)
        classifier.failStage2CohortFetchForTesting = true
        let failed = await classifier.classifyAndAssembleTripsQueuedWithGates(
            maxStaysPerCall: 3, gate: PipelineGate(forTesting: ()))
        classifier.failStage2CohortFetchForTesting = false
        #expect(!failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .allSatisfy { $0.category == .unclassified }, "no partial cohort commits")

        let recovered = await classifier.classifyAndAssembleTripsQueuedWithGates(
            maxStaysPerCall: 3, gate: PipelineGate(forTesting: ()))
        #expect(recovered)
        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category != .unclassified })
        #expect(Set(rows.map(\.category)).count == 1)
    }

    @Test("a short copy of an ambiguous twin is decided with it, never by its own duration")
    func shortCopyFollowsTheLogicalDecision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 360, latitude: 0, locality: "Before", distance: 200, category: .destination)
        let twinID = UUID()
        // The earlier copy decides. Three hours is ambiguous, so the 15-minute
        // copy neither resolves to transit alone nor is corrected apart afterwards.
        stay(ctx, hours: 8, minutes: 180, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        stay(ctx, hours: 8.5, minutes: 15, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category == .destination })
        #expect(await classifier.sanityFixpointViolatedForTesting() == false,
                "a copy the sanity pass will not change does not keep the back half due")
    }

    @Test("a twin whose deciding copy is a blip resolves every copy by the duration rule")
    func blipDecidingCopyResolvesEveryCopy() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, hours: 0, minutes: 360, latitude: 0, locality: "Before", distance: 200, category: .destination)
        let twinID = UUID()
        stay(ctx, hours: 8, minutes: 15, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        stay(ctx, hours: 8.5, minutes: 180, latitude: 1, locality: "Twinville", distance: 200, id: twinID)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let rows = try twins(twinID, container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.category == .transit })
    }

    @Test("the sanity pass judges a logical stay by its deciding copy and corrects every copy")
    func sanityJudgesTheLogicalStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Settled destinations whose copies disagree on duration.
        let blipID = UUID()
        stay(ctx, hours: 0, minutes: 15, latitude: 0, locality: "Blip", distance: 200,
             category: .destination, id: blipID)
        stay(ctx, hours: 0.5, minutes: 180, latitude: 0, locality: "Blip", distance: 200,
             category: .destination, id: blipID)
        let longID = UUID()
        stay(ctx, hours: 10, minutes: 180, latitude: 1, locality: "Long", distance: 200,
             category: .destination, id: longID)
        stay(ctx, hours: 10.5, minutes: 15, latitude: 1, locality: "Long", distance: 200,
             category: .destination, id: longID)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.sanityFixpointViolatedForTesting())
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        #expect(try twins(blipID, container).allSatisfy { $0.category == .transit },
                "the deciding copy's correction reaches its longer copy")
        #expect(try twins(longID, container).allSatisfy { $0.category == .destination },
                "a short copy is not corrected apart from its deciding copy")
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
    }
}
