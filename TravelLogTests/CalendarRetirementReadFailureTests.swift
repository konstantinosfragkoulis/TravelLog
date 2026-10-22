import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Shares the scan suite's serialization and isolated calendar defaults.
extension CalendarEnricherScanTests {
    @Test("A failed retirement candidate read rolls back the scan and retries matching next pass")
    func retirementReadFailurePreservesUpcomingAndRetries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let start = now.addingTimeInterval(-7 * 86400)
        let end = now.addingTimeInterval(-3 * 86400)
        let planned = PlannedTrip(eventExternalIdentifier: "retirement",
            eventLocalIdentifier: "retirement", title: "Trip to Rome",
            startDate: start, endDate: end, isAllDay: false, locationText: nil)
        context.insert(planned)
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = true
        context.insert(trip)
        let plannedID = planned.id
        let tripID = trip.id
        try context.save()

        // A new detection stages an insert before the retirement read, so
        // hasChanges checks the actor's rollback of real pending work.
        let future = CalendarEventSnapshot(externalIdentifier: "future",
            localIdentifier: "future", title: "Trip to Paris", notes: nil,
            locationText: nil, startDate: now.addingTimeInterval(86400),
            endDate: now.addingTimeInterval(3 * 86400), isAllDay: false,
            hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Test", calendarKind: .icloud)
        let detections = [PlannedTripDetection(snapshot: future,
            confidence: .high, signals: ["bookingTitle"])]
        let enricher = CalendarEnricher(modelContainer: container)
        enricher.failTripCandidateFetchForTesting = true
        defer { enricher.failTripCandidateFetchForTesting = false }

        let succeeded = await enricher.applyScan(detections: detections, now: now)
        #expect(!succeeded)
        #expect(await enricher.retirementContextHasChangesForTesting() == false)
        let afterFailure = try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
        #expect(afterFailure.count == 1)
        let preserved = try #require(afterFailure.first)
        #expect(preserved.id == plannedID)
        #expect(preserved.status == .upcoming)
        #expect(preserved.matchedTripID == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 1)

        enricher.failTripCandidateFetchForTesting = false
        let retried = await enricher.applyScan(detections: detections, now: now)
        #expect(retried)
        #expect(await enricher.retirementContextHasChangesForTesting() == false)
        let afterRetry = try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
        #expect(afterRetry.count == 2)
        let matched = try #require(afterRetry.first { $0.id == plannedID })
        #expect(matched.status == .matched)
        #expect(matched.matchedTripID == tripID)
    }
}

extension CalendarEnricher {
    // Return only a value across the actor boundary, never its ModelContext.
    func retirementContextHasChangesForTesting() -> Bool {
        modelContext.hasChanges
    }
}
