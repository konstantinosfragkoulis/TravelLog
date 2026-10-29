//
//  ClassifierStageTwoTests.swift
//  TravelLogTests
//
//  Stage 2a of the classifier: `resolveDeterministicOutcomes` decides the
//  stays whose evidence alone settles their category (the same rules as
//  `sanityCheckClassifications`; the equivalence tests here pin that).
//
//  Fixtures are UTC-pinned where the overnight guard is in play (solar time
//  at the fixture longitudes must not drift with the runner's timezone) —
//  same convention as ClassifierHeuristicsTests.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (Stay) MainActor-touchable here;
//  actor-isolated TripClassifier methods are awaited. Tests that hand stays
//  to the classifier build them inside `runIsolated`, so no model crosses
//  an actor boundary.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct ClassifierStageTwoTests {

    // MARK: - Fixtures

    // Nonisolated so tests can build stays inside `TripClassifier.runIsolated`.
    @discardableResult
    private nonisolated func makeStay(
        in ctx: ModelContext,
        start: Date,
        minutes: Int,
        dist: Double = 100,
        isAirport: Bool = false,
        lat: Double = 0,
        lon: Double = 0,
        locality: String? = nil,
        island: String? = nil,
        country: String = "Greece",
        category: StayCategory = .unclassified,
        userOverridden: Bool = false,
        hex: String
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(Double(minutes) * 60),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: dist, pingIDs: []
        )
        stay.isAirport = isAirport
        stay.category = category
        stay.userOverridden = userOverridden
        stay.locality = locality
        stay.islandName = island
        stay.country = country
        ctx.insert(stay)
        return stay
    }

    /// UTC-pinned instant (see file header).
    private nonisolated func utc(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 4, day: day, hour: hour, minute: minute))!
            .addingTimeInterval(56 * 86_400)
    }

    // MARK: - Stage 2a: resolveDeterministicOutcomes

    @Test("airport <24h, ≤20min, and ≥5-day stays resolve deterministically; the rest stay ambiguous")
    func deterministicResolutionMatrix() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let airport = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 300, isAirport: true, hex: "a")
            let blip = makeStay(in: ctx, start: utc(1, hour: 14), minutes: 15, hex: "b")
            let week = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 8000, hex: "c")
            let airportWeek = makeStay(in: ctx, start: utc(8, hour: 8), minutes: 8000, isAirport: true, hex: "d")
            let hotel = makeStay(in: ctx, start: utc(14, hour: 8), minutes: 1500, isAirport: true, hex: "e")
            let plain = makeStay(in: ctx, start: utc(15, hour: 12), minutes: 100, hex: "f")
            try ctx.save()

            let (resolved, ambiguous) = try classifier.resolveDeterministicOutcomes(
                [airport, blip, week, airportWeek, hotel, plain], timeline: nil
            )

            #expect(resolved.count == 4)
            #expect(airport.category == .transit)
            #expect(blip.category == .transit)
            #expect(week.category == .destination)
            // ≥5 days beats the airport rule (which only covers <24h) — matches
            // the sanity-check fixpoint, where the long-transit flip lands on
            // destination and the airport flip can't fire.
            #expect(airportWeek.category == .destination)
            // The 25h airport-hotel case is the heuristics' to judge.
            #expect(hotel.category == .unclassified)
            #expect(plain.category == .unclassified)
            #expect(ambiguous.count == 2)
        }
    }

    @Test("boundary values: exactly 20min resolves transit; exactly 24h airport and 21min do not resolve")
    func deterministicResolutionBoundaries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let exactly20 = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 20, hex: "a")
            let just21 = makeStay(in: ctx, start: utc(1, hour: 10), minutes: 21, hex: "b")
            let exactly24hAirport = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 24 * 60, isAirport: true, hex: "c")
            try ctx.save()

            let (resolved, ambiguous) = try classifier.resolveDeterministicOutcomes(
                [exactly20, just21, exactly24hAirport], timeline: nil
            )

            #expect(resolved.count == 1)
            #expect(exactly20.category == .transit)
            #expect(just21.category == .unclassified)
            #expect(exactly24hAirport.category == .unclassified)
            #expect(ambiguous.count == 2)
        }
    }

    @Test("user-overridden and already-classified stays are never touched and never returned as ambiguous")
    func deterministicResolutionRespectsOverrides() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let overridden = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 15, userOverridden: true, hex: "a")
            let settled = makeStay(in: ctx, start: utc(1, hour: 10), minutes: 15, category: .destination, hex: "b")
            try ctx.save()

            let (resolved, ambiguous) = try classifier.resolveDeterministicOutcomes(
                [overridden, settled], timeline: nil
            )

            #expect(resolved.isEmpty)
            #expect(ambiguous.isEmpty)
            #expect(overridden.category == .unclassified)
            #expect(settled.category == .destination)
        }
    }

    /// Equivalence pin: for every shape Stage 2a claims, resolving up front
    /// must land on the SAME category the sanity check would force onto a
    /// disagreeing earlier verdict. If someone changes a threshold on one side
    /// only, this test fails.
    @Test("Stage 2a outcome equals the sanity-check fixpoint of a disagreeing verdict")
    func resolutionMatchesSanityFixpoint() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            // Copy A: resolved deterministically. Copy B: an earlier verdict "disagreed";
            // the sanity check must flip B to A's category.
            let airportA = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 300, isAirport: true, hex: "a1")
            let airportB = makeStay(in: ctx, start: utc(1, hour: 14), minutes: 300, isAirport: true,
                                    category: .destination, hex: "a2")
            let blipA = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 15, hex: "b1")
            let blipB = makeStay(in: ctx, start: utc(2, hour: 10), minutes: 15, category: .destination, hex: "b2")
            let weekA = makeStay(in: ctx, start: utc(3, hour: 8), minutes: 8000, hex: "c1")
            let weekB = makeStay(in: ctx, start: utc(10, hour: 8), minutes: 8000, category: .transit, hex: "c2")
            try ctx.save()

            _ = try classifier.resolveDeterministicOutcomes([airportA, blipA, weekA], timeline: nil)
            _ = classifier.sanityCheckClassifications()

            #expect(airportA.category == .transit)
            #expect(classifier.stayCategoryForTesting(airportB.id) == .transit)
            #expect(blipA.category == .transit)
            #expect(classifier.stayCategoryForTesting(blipB.id) == .transit)
            #expect(weekA.category == .destination)
            #expect(classifier.stayCategoryForTesting(weekB.id) == .destination)
        }
    }

    /// The back-half dirty gate's
    /// sanity-fixpoint arm must (a) fire on exactly the states the Stage-2.5
    /// rules would correct, since clustering can create them without minting
    /// an unclassified stay, and (b) go quiet after one sanity pass, or the
    /// arm would re-run the back half on every pass forever.
    @Test("sanity-fixpoint gate arm fires on violations and converges after one sanity pass")
    func sanityFixpointGateConverges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Clean store: no violation.
        makeStay(in: ctx, start: utc(1, hour: 8), minutes: 600, category: .destination, hex: "a")
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)

        // A transit stay grown past 5 days (the endTime-extension shape) and
        // a destination re-stamped as an airport — both sanity violations
        // with zero unclassified stays anywhere.
        let longTransit = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 8000,
                                   category: .transit, hex: "b")
        let airportDest = makeStay(in: ctx, start: utc(9, hour: 8), minutes: 300,
                                   category: .destination, hex: "c")
        airportDest.isAirport = true
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == true)

        // One sanity pass corrects both; the gate arm goes quiet (threshold
        // mirror + convergence in one assertion).
        _ = await classifier.sanityCheckClassifications()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
        // Read through the actor's seam — the corrections live in ITS
        // context (the file-header pattern; the seeding ctx can't see them).
        #expect(await classifier.stayCategoryForTesting(longTransit.id) == .destination)
        #expect(await classifier.stayCategoryForTesting(airportDest.id) == .transit)

        // userOverridden violations are exempt on BOTH sides — the gate
        // must not loop on a stay sanity will never touch.
        let locked = makeStay(in: ctx, start: utc(12, hour: 8), minutes: 8000,
                              category: .transit, hex: "d")
        locked.userOverridden = true
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
    }
}
