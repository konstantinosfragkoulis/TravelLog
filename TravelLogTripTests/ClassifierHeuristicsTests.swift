//
//  ClassifierHeuristicsTests.swift
//  TravelLogTests
//
//  Heuristic fallback classification: TripClassifier.classifyWithHeuristics(stays:)
//  Covers chronological neighbours and the airport pre-filter.
//  The method fetches the FULL chronological stay list from its OWN modelContext to
//  build the neighbour index, so neighbours come from context order, NOT the passed
//  array. We insert the full set into the SAME container the classifier wraps, then
//  pass only the stay(s) under test. Airport pre-filter (isAirport && <24h → transit)
//  runs BEFORE the <180min sandwich branch.
//
//  `@MainActor` because the app target compiles with MainActor-by-default isolation,
//  which makes `@Model` types (Stay) and the @ModelActor TripClassifier members
//  MainActor-touchable here; the actor-isolated classifyWithHeuristics is awaited.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct ClassifierHeuristicsTests {

    // MARK: - Fixtures

    /// Builds an unclassified Stay with controlled duration (endTime = start + minutes),
    /// home distance, airport flag, and a unique hex. Inserted into `ctx`.
    @discardableResult
    private func makeStay(
        in ctx: ModelContext,
        start: Date,
        minutes: Int,
        dist: Double,
        isAirport: Bool = false,
        lat: Double = 0,
        lon: Double = 0,
        category: StayCategory = .unclassified,
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
        ctx.insert(stay)
        return stay
    }

    private func base(_ minutesFromEpoch: Int) -> Date {
        // Stable, ordering-only dates; noon on the base day plus an offset.
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        return day.addingTimeInterval(Double(minutesFromEpoch) * 60)
    }

    /// UTC-pinned instants for the journey-boundary / adjacent-base rules:
    /// their overnight guard evaluates solar time (= UTC at longitude 0), so
    /// these fixtures must not drift with the test runner's local timezone
    /// the way `base()` does.
    private func utc(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Airport pre-filter

    @Test("airport stay under 24h is forced to .transit even when its duration would pass as destination")
    func airportStayUnder24hForcedTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 8h airport stay; long enough that the duration branch would call it a
        // destination, but the airport pre-filter fires first.
        let stay = makeStay(in: ctx, start: base(0), minutes: 8 * 60, dist: 100, isAirport: true, hex: "ap1")

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .transit)
        #expect(count == 1)
    }

    @Test("airport stay ≥ 24h is NOT forced to transit; falls through to duration branch → .destination")
    func airportStayOver24hNotForcedTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 25h airport stay (airport-hotel multi-day stopover).
        let stay = makeStay(in: ctx, start: base(0), minutes: 25 * 60, dist: 100, isAirport: true, hex: "ap2")

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .destination)
        #expect(count == 1)
    }

    @Test("airport boundary: 1439min → transit; 1440min (exactly 24h) → not forced")
    func airportBoundaryExactly24hMinusOne() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let under = makeStay(in: ctx, start: base(0), minutes: 1439, dist: 100, isAirport: true, hex: "apA")
        let exact = makeStay(in: ctx, start: base(5000), minutes: 1440, dist: 100, isAirport: true, hex: "apB")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [under, exact])
        #expect(under.category == .transit)        // 1439 < 1440 → forced transit
        #expect(exact.category == .destination)    // 1440 not < 1440 → falls through (≥180 → destination)
    }

    // MARK: - Short-stay sandwich (true chronological neighbours)

    @Test("short non-airport stay between two far neighbours → .transit (neighbours from context fetch)")
    func shortStaySandwichedBetweenFarNeighboursIsTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // prev(far) → short(near) → next(far). The short stay is near home (10km),
        // both chronological neighbours are far (100km > 10+50).
        let prev = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "p")
        let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "s")
        let next = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 100, hex: "n")
        _ = prev; _ = next

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [short])
        #expect(short.category == .transit)
        #expect(count == 1)
    }

    @Test("short non-airport stay with non-far neighbours (within +50km) → .destination")
    func shortStayWithNonFarNeighboursIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Neighbours at 40km are NOT > 10+50; both far flags false → destination.
        _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 40, hex: "p2")
        let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "s2")
        _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 40, hex: "n2")

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [short])
        #expect(short.category == .destination)
        #expect(count == 1)
    }

    @Test("short stay's far neighbours are absent from the passed array yet still seen via the context fetch")
    func shortStayNeighbourComesFromFullSequenceNotPassedArray() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // The neighbours are already-classified (.destination) and NOT passed to
        // classifyWithHeuristics. Only the short stay is passed. It must still see
        // them through the modelContext fetch and become transit.
        let prev = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "fp")
        prev.category = .destination
        let next = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 100, hex: "fn")
        next.category = .destination
        let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "fs")

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [short])
        #expect(short.category == .transit)
        #expect(count == 1)
    }

    @Test("short stay first in sequence: far NEXT → transit; near-only next → destination (nil prev tolerated)")
    func shortStayAtSequenceStartNoPrevNeighbour() async throws {
        // far next → transit
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            let short = makeStay(in: ctx, start: base(0), minutes: 60, dist: 10, hex: "ss1")
            _ = makeStay(in: ctx, start: base(1000), minutes: 600, dist: 100, hex: "sn1") // far next
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .transit)
        }
        // near-only next → destination
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            let short = makeStay(in: ctx, start: base(0), minutes: 60, dist: 10, hex: "ss2")
            _ = makeStay(in: ctx, start: base(1000), minutes: 600, dist: 40, hex: "sn2") // near next
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .destination)
        }
    }

    @Test("short stay last in sequence: far PREV → transit; near prev → destination (nil next tolerated)")
    func shortStayAtSequenceEndNoNextNeighbour() async throws {
        // far prev → transit
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "ep1") // far prev
            let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "es1")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .transit)
        }
        // near prev → destination
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 40, hex: "ep2") // near prev
            let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "es2")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .destination)
        }
    }

    // MARK: - Duration branch

    @Test("a non-airport stay ≥ 180min is unconditionally .destination regardless of neighbour distance")
    func longStayIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Far neighbours present, but the 5h stay never enters the sandwich branch.
        _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 500, hex: "lp")
        let long = makeStay(in: ctx, start: base(1000), minutes: 300, dist: 10, hex: "ll")
        _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 500, hex: "ln")

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [long])
        #expect(long.category == .destination)
        #expect(count == 1)
    }

    @Test("duration boundary: 180min → destination (not < 180); 179min enters the sandwich branch")
    func boundaryDurationExactly180IsDestination() async throws {
        // 180 with far neighbours → still destination (skips sandwich).
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "b180p")
            let s = makeStay(in: ctx, start: base(1000), minutes: 180, dist: 10, hex: "b180")
            _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 100, hex: "b180n")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [s])
            #expect(s.category == .destination)
        }
        // 179 with far neighbours → enters sandwich → transit.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "b179p")
            let s = makeStay(in: ctx, start: base(1000), minutes: 179, dist: 10, hex: "b179")
            _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 100, hex: "b179n")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [s])
            #expect(s.category == .transit)
        }
    }

    @Test("neighbour-distance boundary: exactly +50km is NOT far (>) → destination; +50.001 → transit")
    func boundaryNeighbourDistanceExactlyPlus50NotFar() async throws {
        // Mid-journey layout (unclassified neighbours on BOTH sides) so the
        // journey-boundary rule can't claim the stay first. This test pins
        // the sandwich rule's strict > boundary in isolation.
        // short.dist = 10; neighbours at exactly 60 → 60 > 10+50 == 60 is false → not far.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 60.0, hex: "p50ap")
            let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "p50a")
            _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 60.0, hex: "p50an") // exactly +50
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .destination)
        }
        // neighbours at 60.001 → > 60 → far → transit.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: base(0), minutes: 600, dist: 60.001, hex: "p50bp")
            let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "p50b")
            _ = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 60.001, hex: "p50bn")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [short])
            #expect(short.category == .transit)
        }
    }

    // MARK: - Rule B: journey-boundary transit

    @Test("short first stay of a journey with a farther continuation → transit even when the sandwich rule would miss it")
    func journeyStartShortStayIsTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // home → [port 60min, 10km] → [island 600min, 45km]. The island is
        // only +35km (sandwich needs +50), so only the boundary rule applies.
        _ = makeStay(in: ctx, start: utc(1, hour: 6), minutes: 120, dist: 0, category: .home, hex: "jb-h")
        let port = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 60, dist: 10, hex: "jb-p")
        _ = makeStay(in: ctx, start: utc(1, hour: 11), minutes: 600, dist: 45, hex: "jb-i")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [port])
        #expect(port.category == .transit)
    }

    @Test("short last stay of a journey (before home) with a farther origin → transit")
    func journeyEndShortStayIsTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // [island 600min, 45km] → [port 60min, 10km] → home.
        _ = makeStay(in: ctx, start: utc(1, hour: 6), minutes: 600, dist: 45, hex: "je-i")
        let port = makeStay(in: ctx, start: utc(1, hour: 17), minutes: 60, dist: 10, hex: "je-p")
        _ = makeStay(in: ctx, start: utc(1, hour: 19), minutes: 120, dist: 0, category: .home, hex: "je-h")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [port])
        #expect(port.category == .transit)
    }

    @Test("home → X → home errand is NOT claimed (both sides are boundaries; no destination to be en route to)")
    func isolatedErrandBetweenHomesStaysDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        _ = makeStay(in: ctx, start: utc(1, hour: 6), minutes: 120, dist: 0, category: .home, hex: "er-h1")
        let errand = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 60, dist: 10, hex: "er-x")
        _ = makeStay(in: ctx, start: utc(1, hour: 11), minutes: 120, dist: 0, category: .home, hex: "er-h2")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [errand])
        #expect(errand.category == .destination)
    }

    @Test("the inward walk passes intermediate journey stays to find the farther destination")
    func journeyBoundaryWalkSkipsIntermediateStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // home → [station 45min, 10km] → [suburb 600min, 20km] → [city 600min, 45km].
        // The immediate neighbour (+10km) isn't far enough; the walk reaches
        // the city (+35km) two steps in.
        _ = makeStay(in: ctx, start: utc(2, hour: 6), minutes: 120, dist: 0, category: .home, hex: "wk-h")
        let station = makeStay(in: ctx, start: utc(2, hour: 9), minutes: 45, dist: 10, hex: "wk-s")
        _ = makeStay(in: ctx, start: utc(2, hour: 10), minutes: 600, dist: 20, hex: "wk-m")
        _ = makeStay(in: ctx, start: utc(2, hour: 21), minutes: 600, dist: 45, hex: "wk-c")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [station])
        #expect(station.category == .transit)
    }

    @Test("duration boundary: 90min is NOT claimed by the journey-boundary rule; 89min is")
    func journeyBoundaryDurationBoundary() async throws {
        func run(minutes: Int) async throws -> StayCategory {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: utc(3, hour: 6), minutes: 120, dist: 0, category: .home, hex: "db-h")
            let s = makeStay(in: ctx, start: utc(3, hour: 9), minutes: minutes, dist: 10, hex: "db-s")
            _ = makeStay(in: ctx, start: utc(3, hour: 12), minutes: 600, dist: 45, hex: "db-i")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [s])
            return s.category
        }
        #expect(try await run(minutes: 90) == .destination)
        #expect(try await run(minutes: 89) == .transit)
    }

    @Test("overnight guard: a boundary stay spanning solar 03:00 is never claimed")
    func journeyBoundaryOvernightGuard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Same shape as journeyStartShortStayIsTransit, but the stay runs
        // 02:30 to 03:30 UTC at longitude 0 (= solar) → the guard suppresses
        // rule B, and the sandwich rule (+35km < +50km) doesn't fire either.
        _ = makeStay(in: ctx, start: utc(4, hour: 0), minutes: 120, dist: 0, category: .home, hex: "on-h")
        let night = makeStay(in: ctx, start: utc(4, hour: 2, minute: 30), minutes: 60, dist: 10, hex: "on-s")
        _ = makeStay(in: ctx, start: utc(4, hour: 5), minutes: 600, dist: 45, hex: "on-i")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [night])
        #expect(night.category == .destination)
    }

    // MARK: - Rule C: short hop beside a long nearby base

    /// ~0.05° latitude ≈ 5.5 km; ~0.32° ≈ 35.5 km (1° lat ≈ 111 km).
    @Test("port shape: a 75min stop (under the 90min cap) 5km from a long base, followed by a ≥30km jump → transit")
    func adjacentBasePortIsTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // All distances-from-home ~equal so neither the sandwich rule nor
        // rule B can claim it. Transit here exercises rule C.
        _ = makeStay(in: ctx, start: utc(5, hour: 6), minutes: 600, dist: 100, lat: 0.0, hex: "ab-base")
        let port = makeStay(in: ctx, start: utc(5, hour: 17), minutes: 75, dist: 102, lat: 0.05, hex: "ab-port")
        _ = makeStay(in: ctx, start: utc(5, hour: 20), minutes: 600, dist: 120, lat: 0.37, hex: "ab-next")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [port])
        #expect(port.category == .transit)
    }

    @Test("errand shape: same stop but the far side returns to the base (<30km) → destination")
    func adjacentBaseErrandStaysDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        _ = makeStay(in: ctx, start: utc(6, hour: 6), minutes: 600, dist: 100, lat: 0.0, hex: "ae-base")
        let stop = makeStay(in: ctx, start: utc(6, hour: 17), minutes: 60, dist: 102, lat: 0.05, hex: "ae-stop")
        _ = makeStay(in: ctx, start: utc(6, hour: 19), minutes: 600, dist: 100, lat: 0.0, hex: "ae-back")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [stop])
        #expect(stop.category == .destination)
    }

    @Test("rule C needs the base within 25km and the stop under 90min; either failing → destination")
    func adjacentBaseGuards() async throws {
        // Base too far (33km).
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: utc(7, hour: 6), minutes: 600, dist: 100, lat: 0.0, hex: "ag-base")
            let stop = makeStay(in: ctx, start: utc(7, hour: 17), minutes: 60, dist: 102, lat: 0.30, hex: "ag-stop")
            _ = makeStay(in: ctx, start: utc(7, hour: 20), minutes: 600, dist: 120, lat: 0.60, hex: "ag-next")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [stop])
            #expect(stop.category == .destination)
        }
        // An 85min stop is below the 90min cap and is claimed.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: utc(8, hour: 6), minutes: 600, dist: 100, lat: 0.0, hex: "ag2-base")
            let stop = makeStay(in: ctx, start: utc(8, hour: 17), minutes: 85, dist: 102, lat: 0.05, hex: "ag2-stop")
            _ = makeStay(in: ctx, start: utc(8, hour: 20), minutes: 600, dist: 120, lat: 0.37, hex: "ag2-next")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [stop])
            #expect(stop.category == .transit)
        }
        // Stop at the 90min boundary is NOT claimed.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)
            _ = makeStay(in: ctx, start: utc(9, hour: 6), minutes: 600, dist: 100, lat: 0.0, hex: "ag3-base")
            let stop = makeStay(in: ctx, start: utc(9, hour: 17), minutes: 90, dist: 102, lat: 0.05, hex: "ag3-stop")
            _ = makeStay(in: ctx, start: utc(9, hour: 20), minutes: 600, dist: 120, lat: 0.37, hex: "ag3-next")
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: [stop])
            #expect(stop.category == .destination)
        }
    }

    @Test("rule C overnight guard: the port shape spanning solar 03:00 is not claimed")
    func adjacentBaseOvernightGuard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        _ = makeStay(in: ctx, start: utc(9, hour: 20), minutes: 360, dist: 100, lat: 0.0, hex: "ao-base")
        let stop = makeStay(in: ctx, start: utc(10, hour: 2, minute: 30), minutes: 60, dist: 102, lat: 0.05, hex: "ao-stop")
        _ = makeStay(in: ctx, start: utc(10, hour: 5), minutes: 600, dist: 120, lat: 0.37, hex: "ao-next")

        try ctx.save()
        _ = await classifier.classifyWithHeuristics(stays: [stop])
        #expect(stop.category == .destination)
    }

    // MARK: - Guards / skips

    @Test("a userOverridden stay is never reclassified and not counted")
    func userOverriddenStaySkipped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Would otherwise be forced transit (airport, short), but overridden wins.
        let stay = makeStay(in: ctx, start: base(0), minutes: 30, dist: 100, isAirport: true, hex: "ov")
        stay.category = .destination
        stay.userOverridden = true

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .destination)
        #expect(count == 0)
    }

    @Test("a stay already classified (category != .unclassified) is skipped and not counted")
    func alreadyClassifiedStaySkipped() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, start: base(0), minutes: 30, dist: 100, isAirport: true, hex: "home")
        stay.category = .home

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .home)
        #expect(count == 0)
    }

    @Test("return count equals the number of stays actually transitioned from .unclassified")
    func returnCountMatchesNewlyClassified() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let a = makeStay(in: ctx, start: base(0), minutes: 300, dist: 10, hex: "ra")          // unclassified → destination
        let b = makeStay(in: ctx, start: base(1000), minutes: 30, dist: 10, isAirport: true, hex: "rb") // → transit
        let c = makeStay(in: ctx, start: base(2000), minutes: 300, dist: 10, hex: "rc")
        c.category = .home // skipped
        let d = makeStay(in: ctx, start: base(3000), minutes: 300, dist: 10, hex: "rd")
        d.userOverridden = true // skipped

        try ctx.save()
        let count = await classifier.classifyWithHeuristics(stays: [a, b, c, d])
        #expect(count == 2)
        #expect(a.category == .destination)
        #expect(b.category == .transit)
    }

    @Test("result is independent of the passed-array order (neighbours come from chronological context fetch)")
    func orderIndependentSameResultRegardlessOfPassedArrayOrder() async throws {
        // Build the SAME chronological graph twice, classify in two different
        // argument orders, and confirm identical per-stay categories.
        func run(reversed: Bool) async throws -> (StayCategory, StayCategory, StayCategory) {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)

            // chronological: far → short(near) → far. short should become transit.
            let first = makeStay(in: ctx, start: base(0), minutes: 600, dist: 100, hex: "oi-first")
            let short = makeStay(in: ctx, start: base(1000), minutes: 60, dist: 10, hex: "oi-short")
            let last = makeStay(in: ctx, start: base(2000), minutes: 600, dist: 100, hex: "oi-last")

            let arr = reversed ? [last, short, first] : [first, short, last]
            try ctx.save()
            _ = await classifier.classifyWithHeuristics(stays: arr)
            return (first.category, short.category, last.category)
        }

        let forward = try await run(reversed: false)
        let backward = try await run(reversed: true)
        #expect(forward == backward)
        #expect(forward.1 == .transit) // the short middle stay
    }
}
