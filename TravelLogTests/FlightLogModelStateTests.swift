import Foundation
import Testing
@testable import TravelLog

@MainActor
struct FlightLogModelStateTests {
    private func history(count: Int = 30) -> CollectionsAggregator.Collections {
        var result = CollectionsAggregator.Collections()
        result.flights = (0..<count).map { offset in
            CollectionsAggregator.FlightRecord(
                id: UUID(), departureCode: "ATH", arrivalCode: "LHR",
                departurePlace: "Athens", arrivalPlace: "London",
                departureISO: "GR", arrivalISO: "GB",
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400),
                distanceKm: 2_400, estimatedHours: 3.5, isInternational: true,
                timeZonesCrossed: 2, isOvernight: false,
                departureWindowStart: nil)
        }
        return result
    }

    @Test("A retry retains the complete log while requesting authoritative readback")
    func retryPreservesAcceptedHistory() {
        let model = FlightLogModel()
        let original = history()
        let generation = StatsSnapshotStore.clearGeneration
        model.receive(original, generation: generation)
        let previousKey = model.key(now: .now)

        let requestedRevision = model.requestRefresh()

        #expect(model.hasSnapshot)
        #expect(model.collections == original)
        #expect(model.collections.flights.count == 30)
        #expect(model.key(now: .now).revision == requestedRevision)
        #expect(requestedRevision > previousKey.revision)
        #expect(model.completedRefreshRevision < requestedRevision)
    }

    @Test("Revocation clears all displayed collections and unfinished readback authority")
    func revocationClearsDisplayedHistory() {
        let model = FlightLogModel()
        let generation = StatsSnapshotStore.clearGeneration
        model.receive(history(), generation: generation)
        model.pendingEditPublicationOwed = true
        _ = model.requestRefresh()

        model.clear(generation: generation)

        #expect(!model.hasSnapshot)
        #expect(model.collections == CollectionsAggregator.Collections())
        #expect(model.completedRefreshRevision == -1)
        #expect(!model.needsRetry)
        // A snapshot clear is not proof that an unrelated deferred edit
        // was published; both Stats and Log retain the same obligation.
        #expect(model.pendingEditPublicationOwed)
    }

    @Test("An older generation cannot repopulate a cleared log")
    func lateSnapshotIsIgnored() {
        let model = FlightLogModel()
        let generation = StatsSnapshotStore.clearGeneration
        model.clear(generation: generation)

        model.receive(history(), generation: generation &- 1)

        #expect(!model.hasSnapshot)
        #expect(model.collections.flights.isEmpty)
        #expect(model.clearGeneration == generation)
    }
}
