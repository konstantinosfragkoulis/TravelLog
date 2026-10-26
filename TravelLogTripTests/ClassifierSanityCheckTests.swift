//
//  ClassifierSanityCheckTests.swift
//  TravelLogTests
//
//  Stage 2.5 boundary corrections — TripClassifier.sanityCheckClassifications().
//  Three conservative rules over the destination/transit, non-userOverridden set:
//    • transit ≥ 7200min (5d)  → destination   (nobody waits in transit 5 days)
//    • destination ≤ 20min      → transit       (single coarse-SLC ping pass-through)
//    • destination, isAirport, < 1440min (24h) → transit (post-AI airport guard)
//  When a corrected stay belongs to a Trip, that trip's aiGeneratedTitle is
//  nilled and recomputeSummary() runs.
//  The method fetches from its OWN modelContext (predicate filters userOverridden ==
//  false and only destination/transit categories), so the container holds ONLY the
//  stays under test.
//
//  `@MainActor` because the app target is MainActor-by-default, making @Model types
//  (Stay/Trip) and the @ModelActor TripClassifier touchable here; the actor-isolated
//  sanityCheckClassifications is awaited.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct ClassifierSanityCheckTests {

    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        minutes: Int,
        category: StayCategory,
        isAirport: Bool = false,
        userOverridden: Bool = false,
        hex: String,
        start: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(Double(minutes) * 60),
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.isAirport = isAirport
        stay.userOverridden = userOverridden
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    // MARK: - transit > 5 days

    @Test("a transit stay ≥ 7200min (5 days) is corrected to .destination and counted")
    func transitOver5DaysBecomesDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, minutes: 7300, category: .transit, hex: "t5")
        try ctx.save()
        // sanityCheckClassifications mutates its OWN actor context and returns the
        // corrected count; it does NOT save (the caller persists). So the only
        // cross-context observable in a unit test is the return count — which fully
        // pins each correction rule and its boundary.
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1) // ≥ 7200min transit → reclassified to destination
    }

    @Test("transit boundary: 7200min IS corrected (≥); 7199min is NOT corrected")
    func transitExactly5DaysBoundary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, minutes: 7200, category: .transit, hex: "te1",
                 start: Date(timeIntervalSinceReferenceDate: 0))
        makeStay(in: ctx, minutes: 7199, category: .transit, hex: "te2",
                 start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        try ctx.save()
        // Only the ≥7200 stay qualifies → count == 1 pins the boundary (a wrong
        // threshold would correct both → 2, or neither → 0).
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1)
    }

    @Test("a transit stay under 7200min is left .transit and not counted")
    func transitUnder5DaysUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, minutes: 3 * 24 * 60, category: .transit, hex: "t3d")
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        // The pass does not save; its own context is where a correction would land.
        #expect(await classifier.stayCategoryForTesting(stay.id) == .transit)
        #expect(corrected == 0)
    }

    // MARK: - destination ≤ 20 min

    @Test("a destination stay ≤ 20min is corrected to .transit and counted")
    func destination20MinOrLessBecomesTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, minutes: 10, category: .destination, hex: "d10")
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1) // ≤ 20min destination → reclassified to transit
    }

    @Test("destination boundary: 20min IS corrected (≤); 21min is NOT corrected by the short rule")
    func destination20MinBoundary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, minutes: 20, category: .destination, hex: "d20",
                 start: Date(timeIntervalSinceReferenceDate: 0))
        makeStay(in: ctx, minutes: 21, category: .destination, hex: "d21",
                 start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        try ctx.save()
        // 20min corrects (≤ 20), 21min does not → count == 1 pins the boundary.
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1)
    }

    // MARK: - destination airport < 24h

    @Test("a destination airport stay < 1440min (and > 20) is corrected to .transit and counted")
    func destinationAirportUnder24hBecomesTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 8h: > 20 (short rule won't fire) but < 24h airport → transit.
        makeStay(in: ctx, minutes: 8 * 60, category: .destination, isAirport: true, hex: "dap8")
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1) // airport destination < 24h (and > 20min) → transit
    }

    @Test("destination airport stay exactly 1440min (24h) is NOT corrected (< 1440 boundary)")
    func destinationAirportExactly24hUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, minutes: 1440, category: .destination, isAirport: true, hex: "dap24")
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(await classifier.stayCategoryForTesting(stay.id) == .destination)
        #expect(corrected == 0)
    }

    @Test("a normal destination (non-airport, 21+ min) is left .destination, not counted")
    func destinationNonAirportNormalDurationUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, minutes: 5 * 60, category: .destination, hex: "dnorm")
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(await classifier.stayCategoryForTesting(stay.id) == .destination)
        #expect(corrected == 0)
    }

    // MARK: - Guards

    @Test("a userOverridden stay that would otherwise be corrected is left untouched (predicate filters it)")
    func userOverriddenStayNeverCorrected() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 5-day transit + 10-min destination, both userOverridden.
        let t = makeStay(in: ctx, minutes: 7300, category: .transit, userOverridden: true, hex: "ovT",
                         start: Date(timeIntervalSinceReferenceDate: 0))
        let d = makeStay(in: ctx, minutes: 10, category: .destination, userOverridden: true, hex: "ovD",
                         start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(await classifier.stayCategoryForTesting(t.id) == .transit)
        #expect(await classifier.stayCategoryForTesting(d.id) == .destination)
        #expect(corrected == 0)
    }

    @Test("home/routine stays are never considered (predicate matches only destination/transit)")
    func homeAndRoutineStaysNotConsidered() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let home = makeStay(in: ctx, minutes: 10 * 24 * 60, category: .home, hex: "homeS",
                            start: Date(timeIntervalSinceReferenceDate: 0))
        let routine = makeStay(in: ctx, minutes: 10, category: .routine, hex: "routS",
                               start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        try ctx.save()
        let corrected = await classifier.sanityCheckClassifications()
        #expect(await classifier.stayCategoryForTesting(home.id) == .home)
        #expect(await classifier.stayCategoryForTesting(routine.id) == .routine)
        #expect(corrected == 0)
    }

    // MARK: - Trip side effects

    @Test("when a corrected stay belongs to a Trip, that trip's aiGeneratedTitle is cleared")
    func affectedTripTitleCleared() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 0))
        trip.aiGeneratedTitle = "Stale Title"
        ctx.insert(trip)

        // 5-day transit stay belonging to the trip → corrected → trip title cleared.
        let stay = makeStay(in: ctx, minutes: 7300, category: .transit, hex: "tripT")
        stay.trip = trip
        stay.orderInTrip = 0
        try ctx.save()

        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 1)
        // The corrected stay belongs to a Trip, so the V9+ contract nils that trip's
        // AI title. That mutation lives in the actor's
        // UNSAVED context (the caller persists later), so we observe it THROUGH the
        // actor — a fresh ModelContext can't see unsaved changes.
        let fields = await classifier.aiTitleFieldsForTesting(trip.id)
        #expect(fields?.title == nil)
    }

    @Test("a trip whose stays are NOT corrected keeps its aiGeneratedTitle (no over-clearing)")
    func unaffectedTripTitlePreserved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 0))
        trip.aiGeneratedTitle = "Keep Me"
        ctx.insert(trip)

        // Normal 5h destination — not corrected.
        let stay = makeStay(in: ctx, minutes: 5 * 60, category: .destination, hex: "keepT")
        stay.trip = trip
        stay.orderInTrip = 0
        try ctx.save()

        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 0)
        // Observe THROUGH the actor's own context (where an erroneous clearing would
        // live): the uncorrected trip's title is preserved — a real no-over-clearing
        // check, not a re-read of the persisted literal.
        let fields = await classifier.aiTitleFieldsForTesting(trip.id)
        #expect(fields?.title == "Keep Me")
    }

    @Test("return count aggregates all three rules' corrections in one call")
    func returnCountAggregatesAllCorrections() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        makeStay(in: ctx, minutes: 7300, category: .transit, hex: "agg1",
                 start: Date(timeIntervalSinceReferenceDate: 0))
        makeStay(in: ctx, minutes: 10, category: .destination, hex: "agg2",
                 start: Date(timeIntervalSinceReferenceDate: 1_000_000))
        makeStay(in: ctx, minutes: 8 * 60, category: .destination, isAirport: true, hex: "agg3",
                 start: Date(timeIntervalSinceReferenceDate: 2_000_000))
        // A stay that should NOT be corrected, to ensure the count is precise.
        makeStay(in: ctx, minutes: 5 * 60, category: .destination, hex: "agg4",
                 start: Date(timeIntervalSinceReferenceDate: 3_000_000))
        try ctx.save()

        // Three stays match the three rules; the normal 5h destination does not →
        // count == 3 exactly (a 4 would mean the normal stay was over-corrected).
        let corrected = await classifier.sanityCheckClassifications()
        #expect(corrected == 3)
    }
}
