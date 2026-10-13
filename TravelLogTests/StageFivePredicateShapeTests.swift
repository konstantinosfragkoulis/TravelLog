//
//  StageFivePredicateShapeTests.swift
//  TravelLogTests
//
//  Pins the Stage 5 title-candidate predicate shape: the fetch that used
//  to materialize the FULL Trip table on every Trips-tab visit now pushes
//  the "no custom name, no AI title" checks into a #Predicate. SwiftData
//  translates the `?? ""` comparisons at runtime, not compile time — if
//  that translation ever broke, Stage 5 would silently stop titling trips
//  (the `try?` fetch would just return nothing), so the shape is pinned
//  here against an in-memory store. Same rationale as the `?? 0`
//  predicate-shape test from calendar Phase 5.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct StageFivePredicateShapeTests {

    private func makeTrip(
        in context: ModelContext, customName: String? = nil, aiTitle: String? = nil
    ) -> Trip {
        let trip = Trip(startDate: .now)
        trip.customName = customName
        trip.aiGeneratedTitle = aiTitle
        context.insert(trip)
        return trip
    }

    @Test func untitledPredicateMatchesExactlyTheEligibleTrips() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let untitled = makeTrip(in: context)
        let emptyStrings = makeTrip(in: context, customName: "", aiTitle: "")
        _ = makeTrip(in: context, aiTitle: "Weekend in Rome")
        _ = makeTrip(in: context, customName: "Honeymoon")
        _ = makeTrip(in: context, customName: "Honeymoon", aiTitle: "Weekend in Rome")
        try context.save()

        // The predicate `generateTitlesStage` actually fetches with — the
        // shared factory, not a copy (signal-repair 2026-08-08).
        let descriptor = FetchDescriptor<Trip>(
            predicate: TripClassifier.untitledTripsPredicate(),
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let fetched = try context.fetch(descriptor)

        #expect(Set(fetched.map(\.id)) == Set([untitled.id, emptyStrings.id]))
    }
}
