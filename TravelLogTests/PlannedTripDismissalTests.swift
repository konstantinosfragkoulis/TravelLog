//
//  PlannedTripDismissalTests.swift
//  TravelLogTests
//
//  Dismissing an Upcoming journey reports a committed outcome: a
//  failed read or save dismisses nothing, rolls back only its own change,
//  keeps unrelated pending edits, and leaves nothing a later save could
//  commit. `.upcoming` and `.expired` rows become `.dismissed`; matched
//  records stand.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Planned trip dismissal", .serialized)
struct PlannedTripDismissalTests {

    private let start = Date.now.addingTimeInterval(20 * 86_400)

    @discardableResult
    private func seedLeg(_ context: ModelContext, id: UUID = UUID(), status: PlannedTripStatus = .upcoming,
                         key: String = UUID().uuidString) -> PlannedTrip {
        let row = PlannedTrip(eventExternalIdentifier: key, eventLocalIdentifier: key,
            title: "Flight to Lisbon", startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, locationText: nil)
        row.id = id
        row.status = status
        context.insert(row)
        return row
    }

    private func statuses(_ container: ModelContainer) throws -> [UUID: [PlannedTripStatus]] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
        return Dictionary(grouping: rows, by: \.id).mapValues { $0.map(\.status) }
    }

    @Test("a gated dismissal commits every leg, UUID twins included")
    func dismissalCommitsThroughTheGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let first = UUID()
        let second = UUID()
        seedLeg(context, id: first)
        seedLeg(context, id: second)
        seedLeg(context, id: second)          // a UUID twin of the second leg
        try context.save()

        let ids: Set<UUID> = [first, second]
        let saved = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
            await TripsListView.dismissPlannedTrips(ids: ids, container: container)
        }

        #expect(saved)
        #expect(!context.hasChanges)
        let byID = try statuses(container)
        #expect(byID[first] == [.dismissed])
        #expect(byID[second] == [.dismissed, .dismissed])
    }

    @Test("a failed save rolls back the dismissal but commits the unrelated pending edit")
    func saveFailureRollsBackOnlyTheDismissal() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let legID = UUID()
        seedLeg(context, id: legID)
        let trip = Trip(startDate: start.addingTimeInterval(-90 * 86_400))
        context.insert(trip)
        try context.save()
        trip.aiGeneratedSummary = "Pending summary"   // unrelated pending edit

        let saved = TripsListView.dismissPlannedTrips(
            ids: [legID], container: container,
            save: { _ in throw CocoaError(.fileWriteUnknown) })

        #expect(!saved)
        #expect(!context.hasChanges)
        #expect(try statuses(container)[legID] == [.upcoming])
        let freshTrip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(freshTrip.aiGeneratedSummary == "Pending summary")

        // A later unrelated save on the shared main context cannot carry it.
        trip.aiGeneratedSummary = "Later edit"
        try context.save()
        #expect(try statuses(container)[legID] == [.upcoming])
    }

    @Test("a failed read dismisses nothing and reports failure")
    func readFailureDismissesNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let legID = UUID()
        seedLeg(context, id: legID)
        try context.save()

        let saved = TripsListView.dismissPlannedTrips(
            ids: [legID], container: container,
            fetch: { _, _ in throw CocoaError(.fileReadUnknown) })

        #expect(!saved)
        #expect(!context.hasChanges)
        #expect(try statuses(container)[legID] == [.upcoming])
    }

    @Test("upcoming and expired legs are dismissed, matched and dismissed legs keep their record; repeating is a no-op success")
    func upcomingAndExpiredLegsAreDismissed() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let upcoming = UUID(), matched = UUID(), expired = UUID(), dismissed = UUID()
        let tripID = UUID()
        seedLeg(context, id: upcoming)
        seedLeg(context, id: matched, status: .matched).matchedTripID = tripID
        seedLeg(context, id: expired, status: .expired)
        seedLeg(context, id: dismissed, status: .dismissed)
        try context.save()
        let ids: Set<UUID> = [upcoming, matched, expired, dismissed]

        #expect(TripsListView.dismissPlannedTrips(ids: ids, container: container))
        var byID = try statuses(container)
        #expect(byID[upcoming] == [.dismissed])
        #expect(byID[matched] == [.matched])
        #expect(byID[expired] == [.dismissed])
        #expect(byID[dismissed] == [.dismissed])
        let matchedRow = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
            .first { $0.id == matched })
        #expect(matchedRow.matchedTripID == tripID)

        #expect(TripsListView.dismissPlannedTrips(ids: ids, container: container,
            save: { _ in Issue.record("Nothing left to save"); throw CocoaError(.fileWriteUnknown) }))
        byID = try statuses(container)
        #expect(byID[upcoming] == [.dismissed])
        #expect(byID[expired] == [.dismissed])
        #expect(byID[matched] == [.matched])
    }

    @Test("legs already deleted by an earlier unit are a successful no-op")
    func missingLegsSucceed() throws {
        let container = try TestSupport.makeInMemoryContainer()
        #expect(TripsListView.dismissPlannedTrips(ids: [UUID()], container: container))
        #expect(!container.mainContext.hasChanges)
    }
}
