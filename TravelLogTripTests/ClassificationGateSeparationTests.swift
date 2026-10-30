import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classification gate separation", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct ClassificationGateSeparationTests {
    private func fixture() throws -> (ModelContainer, UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "classification-gate",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        stay.locality = "Athens"
        stay.country = "Greece"
        context.insert(stay)
        try context.save()
        return (container, stay.id)
    }

    @Test("a settled owned-gate pass retains the no-publication outcome")
    func settledPassPublishesNothing() async throws {
        let (container, _) = try fixture()
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        do {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
            let second = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
            #expect(!second.needsPublication)
        }
    }
}
