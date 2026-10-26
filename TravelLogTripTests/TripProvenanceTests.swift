//
//  TripProvenanceTests.swift
//  TravelLogTests
//
//  Per-trip `classifiedByAI` provenance: a trip whose stays were
//  heuristic-classified this pass is stamped false; a trip whose stays
//  were untouched this pass keeps its existing flag.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct TripProvenanceTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    private func makeStay(
        in ctx: ModelContext,
        startDay: Double,
        durationHours: Double = 6,
        category: StayCategory,
        distanceFromHomeKm: Double = 300
    ) -> Stay {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "hex", pingCount: 1,
            distanceFromHomeKm: distanceFromHomeKm, pingIDs: []
        )
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    @Test("a pass that never classified this trip's stays leaves its flag alone")
    func untouchedTripKeepsExistingFlag() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Previously-FM-classified open trip: stays already categorized, so
        // no Stage 2 engine touches them this pass.
        let stay = makeStay(in: ctx, startDay: 0, category: .destination)
        let trip = Trip(startDate: date(day: 0))
        trip.classifiedByAI = true
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        try ctx.save()

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let flag = await classifier.classifiedByAIForTesting(trips[0].id)
        #expect(flag == true)
    }

    @Test("a heuristic-classified trip is stamped classifiedByAI=false")
    func heuristicTripStampedFalse() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Unclassified far-from-home stay → the heuristic engine (the only
        // one available in tests) classifies it this pass.
        let stay = makeStay(in: ctx, startDay: 0, category: .unclassified)
        try ctx.save()

        let classified = await classifier.classifyUnclassifiedWithHeuristicsForTesting()
        #expect(classified == 1)
        #expect(await classifier.stayCategoryForTesting(stay.id) == .destination)

        _ = await classifier.assembleTrips()

        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        let flag = await classifier.classifiedByAIForTesting(trips[0].id)
        #expect(flag == false)
    }
}
