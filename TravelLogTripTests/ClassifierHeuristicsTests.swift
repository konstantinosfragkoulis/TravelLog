//
//  ClassifierHeuristicsTests.swift
//  TravelLogTests
//
//  Heuristic classification: TripClassifier.classifyWithHeuristics(stays:)
//  Covers the airport stop and the journey-stop test over anchors (the
//  nearest stays on each side that are not blips).
//  The method fetches the FULL chronological stay list from its OWN modelContext to
//  find the anchors, so they come from context order, NOT the passed
//  array. We insert the full set into the SAME container the classifier wraps, then
//  pass only the stay(s) under test. The airport stop (isAirport, < 24h, no
//  night) runs BEFORE the journey test.
//
//  Journey fixtures sit on the meridian 12.9 E (0.1 degree of latitude is
//  about 11.1 km); solar 03:00 there is about 02:08 UTC, so daytime UTC
//  instants never span it.
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
        source: DataSource = .liveSLC,
        hex: String
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(Double(minutes) * 60),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: dist, pingIDs: [], source: source
        )
        stay.isAirport = isAirport
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    /// A stay on the fixtures' meridian at `lat`.
    @discardableResult
    private func journeyStay(
        _ ctx: ModelContext, _ start: Date, minutes: Int, lat: Double,
        category: StayCategory = .unclassified, source: DataSource = .liveSLC, hex: String
    ) -> Stay {
        makeStay(in: ctx, start: start, minutes: minutes, dist: 0, lat: lat, lon: 12.9,
                 category: category, source: source, hex: hex)
    }

    private func base(_ minutesFromEpoch: Int) -> Date {
        // Stable, ordering-only dates; noon on the base day plus an offset.
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        return day.addingTimeInterval(Double(minutesFromEpoch) * 60)
    }

    /// UTC-pinned instants: the airport stop and the journey test read solar
    /// time (= UTC at longitude 0), so these fixtures must not drift with the
    /// test runner's local timezone the way `base()` does.
    private func utc(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    /// Classifies `stay` alone against everything in `ctx`.
    private func judge(_ stay: Stay, _ ctx: ModelContext, _ container: ModelContainer) async throws -> StayCategory {
        try ctx.save()
        _ = try await TripClassifier(modelContainer: container).classifyWithHeuristics(stays: [stay])
        return stay.category
    }

    // MARK: - Airport stop

    @Test("airport stay under 24h is forced to .transit even when its duration would pass as destination")
    func airportStayUnder24hForcedTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 8h daytime airport stay; long enough that the journey test would
        // call it a destination, but the airport stop fires first.
        let stay = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 8 * 60, dist: 100, isAirport: true, hex: "ap1")

        try ctx.save()
        let count = try await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .transit)
        #expect(count == 1)
    }

    @Test("airport stay ≥ 24h is NOT forced to transit; it falls through to the journey test → .destination")
    func airportStayOver24hNotForcedTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 25h airport stay (airport-hotel multi-day stopover).
        let stay = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 25 * 60, dist: 100, isAirport: true, hex: "ap2")

        try ctx.save()
        let count = try await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .destination)
        #expect(count == 1)
    }

    @Test("airport boundary: a daytime stay under 24h → transit; one spanning solar 03:00, or of exactly 24h → not forced")
    func airportBoundaryExactly24hMinusOne() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // 05:00 to 01:00 at longitude 0: 20h, no solar 03:00.
        let day = makeStay(in: ctx, start: utc(1, hour: 5), minutes: 20 * 60, dist: 100, isAirport: true, hex: "apA")
        // 22:00 to 06:00: the user slept there (an airport hotel).
        let night = makeStay(in: ctx, start: utc(3, hour: 22), minutes: 8 * 60, dist: 100, isAirport: true, hex: "apN")
        let exact = makeStay(in: ctx, start: utc(6, hour: 9), minutes: 1440, dist: 100, isAirport: true, hex: "apB")

        try ctx.save()
        _ = try await classifier.classifyWithHeuristics(stays: [day, night, exact])
        #expect(day.category == .transit)          // < 1440 and no night → forced transit
        #expect(night.category == .destination)    // a night there → judged like any stay
        #expect(exact.category == .destination)    // 1440 not < 1440 → falls through
    }

    // MARK: - Journey stop: through-stop

    @Test("a brief stop at a station just outside home before a far city is transit, and so is the one on the way back")
    func stationOutsideHomeIsTransit() async throws {
        // home (44.3) → [station 40min, 44.36: about 7 km out] → [city 600min, 45.3].
        // A home anchor needs only 1 km: the station is outside home by definition.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(1, hour: 5), minutes: 120, lat: 44.3, category: .home, hex: "st-h")
            let station = journeyStay(ctx, utc(1, hour: 8), minutes: 40, lat: 44.36, hex: "st-s")
            journeyStay(ctx, utc(1, hour: 12), minutes: 600, lat: 45.3, hex: "st-c")
            #expect(try await judge(station, ctx, container) == .transit)
        }
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(2, hour: 6), minutes: 600, lat: 45.3, hex: "sr-c")
            let station = journeyStay(ctx, utc(2, hour: 17), minutes: 40, lat: 44.36, hex: "sr-s")
            journeyStay(ctx, utc(2, hour: 19), minutes: 120, lat: 44.3, category: .home, hex: "sr-h")
            #expect(try await judge(station, ctx, container) == .transit)
        }
    }

    @Test("a photo at a home anchor's own place, outside its dates, is no stop on the way from it")
    func stopAtTheHomeAnchorsPlaceIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // One photo 0.5 km from the home stay before it, the next stay a far
        // city a day later: brief and on the way, but at home's own place.
        journeyStay(ctx, utc(1, hour: 5), minutes: 120, lat: 44.3, category: .home, hex: "ah-h")
        let photo = journeyStay(ctx, utc(1, hour: 12), minutes: 60, lat: 44.3045, source: .photoImport, hex: "ah-p")
        journeyStay(ctx, utc(2, hour: 12), minutes: 600, lat: 45.3, hex: "ah-c")
        #expect(try await judge(photo, ctx, container) == .destination)
    }

    @Test("a port stop between two legs is transit: its anchor across the water lies past the ferry's fixes")
    func portBetweenLegsIsTransit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // [town 600min, 44.5] → [port 45min, 44.6] → three 10min ferry fixes
        // (the first 5.6 km out) → [island 600min, 45.0, 44 km on].
        // Were the first fix the anchor, the port would not be isolated from it.
        journeyStay(ctx, utc(1, hour: 6), minutes: 600, lat: 44.5, hex: "pt-a")
        let port = journeyStay(ctx, utc(1, hour: 17), minutes: 45, lat: 44.6, hex: "pt-p")
        journeyStay(ctx, utc(1, hour: 18), minutes: 10, lat: 44.65, hex: "pt-f1")
        journeyStay(ctx, utc(1, hour: 18, minute: 15), minutes: 10, lat: 44.8, hex: "pt-f2")
        journeyStay(ctx, utc(1, hour: 18, minute: 30), minutes: 10, lat: 44.9, hex: "pt-f3")
        journeyStay(ctx, utc(1, hour: 19), minutes: 600, lat: 45.0, hex: "pt-b")
        #expect(try await judge(port, ctx, container) == .transit)
    }

    @Test("an excursion from a base and back to it is a destination: it lies on no way between its anchors")
    func excursionFromBaseIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        journeyStay(ctx, utc(1, hour: 6), minutes: 600, lat: 44.3, hex: "ex-a")
        let excursion = journeyStay(ctx, utc(1, hour: 17), minutes: 45, lat: 44.6, hex: "ex-x")
        journeyStay(ctx, utc(1, hour: 19), minutes: 600, lat: 44.3, hex: "ex-b")
        #expect(try await judge(excursion, ctx, container) == .destination)
    }

    @Test("home → X → home errand is a destination")
    func isolatedErrandBetweenHomesStaysDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        journeyStay(ctx, utc(1, hour: 6), minutes: 120, lat: 44.3, category: .home, hex: "er-h1")
        let errand = journeyStay(ctx, utc(1, hour: 9), minutes: 45, lat: 44.48, hex: "er-x")
        journeyStay(ctx, utc(1, hour: 11), minutes: 120, lat: 44.3, category: .home, hex: "er-h2")
        #expect(try await judge(errand, ctx, container) == .destination)
    }

    @Test("a city stop with anchors 10 km away on each side and no 30 km leg is a destination")
    func cityHopWithoutALegIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        journeyStay(ctx, utc(1, hour: 6), minutes: 600, lat: 44.3, hex: "ch-a")
        let stop = journeyStay(ctx, utc(1, hour: 17), minutes: 45, lat: 44.39, hex: "ch-s")
        journeyStay(ctx, utc(1, hour: 19), minutes: 600, lat: 44.48, hex: "ch-b")
        #expect(try await judge(stop, ctx, container) == .destination)
    }

    @Test("a through-stop is brief under an hour: 59 minutes → transit, 60 → destination")
    func throughStopBriefBoundary() async throws {
        func run(minutes: Int) async throws -> StayCategory {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(3, hour: 6), minutes: 600, lat: 44.3, hex: "bb-a")
            let stop = journeyStay(ctx, utc(3, hour: 17), minutes: minutes, lat: 44.6, hex: "bb-s")
            journeyStay(ctx, utc(3, hour: 19), minutes: 600, lat: 45.0, hex: "bb-b")
            return try await judge(stop, ctx, container)
        }
        #expect(try await run(minutes: 59) == .transit)
        #expect(try await run(minutes: 60) == .destination)
    }

    @Test("a stop with no anchor after it (the timeline's end) is a destination")
    func stopWithoutAnchorIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        journeyStay(ctx, utc(1, hour: 6), minutes: 600, lat: 44.3, hex: "na-a")
        let stop = journeyStay(ctx, utc(1, hour: 17), minutes: 45, lat: 44.6, hex: "na-s")
        #expect(try await judge(stop, ctx, container) == .destination)
    }

    // MARK: - Journey stop: night

    @Test("a stop spanning solar 03:00 is never a journey stop")
    func journeyStopNightGuard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 01:40 to 02:30 UTC spans solar 03:00 (about 02:08 UTC at 12.9 E).
        journeyStay(ctx, utc(1, hour: 14), minutes: 600, lat: 44.3, hex: "ng-a")
        let night = journeyStay(ctx, utc(2, hour: 1, minute: 40), minutes: 50, lat: 44.6, hex: "ng-s")
        journeyStay(ctx, utc(2, hour: 5), minutes: 600, lat: 45.0, hex: "ng-b")
        #expect(try await judge(night, ctx, container) == .destination)
    }

    @Test("an evening photo before a morning departure may be where the user slept → destination; a midday one is a stop")
    func eveningPhotoBeforeMorningDepartureIsDestination() async throws {
        // A single photo at 20:00 UTC, the next stay at 08:00: solar 03:00
        // comes 7 h after it with nothing observed in between.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(1, hour: 8), minutes: 600, lat: 44.3, hex: "ev-a")
            let photo = journeyStay(ctx, utc(1, hour: 20), minutes: 60, lat: 44.6, source: .photoImport, hex: "ev-p")
            journeyStay(ctx, utc(2, hour: 8), minutes: 600, lat: 45.0, hex: "ev-b")
            #expect(try await judge(photo, ctx, container) == .destination)
        }
        // The same photo at noon, the next stay three hours later.
        do {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(3, hour: 0), minutes: 600, lat: 44.3, hex: "md-a")
            let photo = journeyStay(ctx, utc(3, hour: 12), minutes: 60, lat: 44.6, source: .photoImport, hex: "md-p")
            journeyStay(ctx, utc(3, hour: 15), minutes: 600, lat: 45.0, hex: "md-b")
            #expect(try await judge(photo, ctx, container) == .transit)
        }
    }

    // MARK: - Journey stop: departure or arrival beside a base

    @Test("a stop under 90min within 25 km of a six-hour base, with the other anchor 30 km on, is the base's departure point")
    func baseDepartureIsTransit() async throws {
        func run(minutes: Int, baseMinutes: Int = 600, arrival: Bool = false) async throws -> StayCategory {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            // base (44.3) and stop (44.35) are 5.6 km apart, too close for a
            // through-stop; the far anchor (44.8) is 50 km on.
            let first = arrival ? (minutes: 600, lat: 44.8) : (minutes: baseMinutes, lat: 44.3)
            let last = arrival ? (minutes: baseMinutes, lat: 44.3) : (minutes: 600, lat: 44.8)
            journeyStay(ctx, utc(1, hour: 4), minutes: first.minutes, lat: first.lat, hex: "bd-a")
            let stop = journeyStay(ctx, utc(1, hour: 15), minutes: minutes, lat: 44.35, hex: "bd-s")
            journeyStay(ctx, utc(1, hour: 17), minutes: last.minutes, lat: last.lat, hex: "bd-b")
            return try await judge(stop, ctx, container)
        }
        #expect(try await run(minutes: 75) == .transit)
        #expect(try await run(minutes: 75, arrival: true) == .transit)
        #expect(try await run(minutes: 89) == .transit)
        #expect(try await run(minutes: 90) == .destination)
        // A base needs six observed hours.
        #expect(try await run(minutes: 75, baseMinutes: 300) == .destination)
    }

    @Test("a wait under 90min at a station near home before a far city is home's departure point")
    func homeDepartureIsTransit() async throws {
        func run(minutes: Int) async throws -> StayCategory {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            journeyStay(ctx, utc(1, hour: 5), minutes: 120, lat: 44.3, category: .home, hex: "hd-h")
            let station = journeyStay(ctx, utc(1, hour: 8), minutes: minutes, lat: 44.36, hex: "hd-s")
            journeyStay(ctx, utc(1, hour: 12), minutes: 600, lat: 45.3, hex: "hd-c")
            return try await judge(station, ctx, container)
        }
        #expect(try await run(minutes: 75) == .transit)
        #expect(try await run(minutes: 90) == .destination)
    }

    // MARK: - Duration

    @Test("a non-airport stay of 90min or more is a destination whatever its journey shape")
    func longStayIsDestination() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        journeyStay(ctx, utc(1, hour: 4), minutes: 600, lat: 44.3, hex: "lp")
        let long = journeyStay(ctx, utc(1, hour: 15), minutes: 300, lat: 44.35, hex: "ll")
        journeyStay(ctx, utc(1, hour: 21), minutes: 600, lat: 44.8, hex: "ln")
        try ctx.save()
        let count = try await TripClassifier(modelContainer: container).classifyWithHeuristics(stays: [long])
        #expect(long.category == .destination)
        #expect(count == 1)
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
        let count = try await classifier.classifyWithHeuristics(stays: [stay])
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
        let count = try await classifier.classifyWithHeuristics(stays: [stay])
        #expect(stay.category == .home)
        #expect(count == 0)
    }

    @Test("return count equals the number of stays actually transitioned from .unclassified")
    func returnCountMatchesNewlyClassified() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let a = makeStay(in: ctx, start: utc(1, hour: 6), minutes: 300, dist: 10, hex: "ra")          // unclassified → destination
        let b = makeStay(in: ctx, start: utc(1, hour: 12), minutes: 30, dist: 10, isAirport: true, hex: "rb") // daytime airport → transit
        let c = makeStay(in: ctx, start: utc(1, hour: 14), minutes: 300, dist: 10, hex: "rc")
        c.category = .home // skipped
        let d = makeStay(in: ctx, start: utc(1, hour: 20), minutes: 300, dist: 10, hex: "rd")
        d.userOverridden = true // skipped

        try ctx.save()
        let count = try await classifier.classifyWithHeuristics(stays: [a, b, c, d])
        #expect(count == 2)
        #expect(a.category == .destination)
        #expect(b.category == .transit)
    }

    @Test("result is independent of the passed-array order (anchors come from chronological context fetch)")
    func orderIndependentSameResultRegardlessOfPassedArrayOrder() async throws {
        // Build the SAME chronological graph twice, classify in two different
        // argument orders, and confirm identical per-stay categories.
        func run(reversed: Bool) async throws -> (StayCategory, StayCategory, StayCategory) {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let classifier = TripClassifier(modelContainer: container)

            // chronological: town → port → island. The port should become transit.
            let first = journeyStay(ctx, utc(1, hour: 6), minutes: 600, lat: 44.3, hex: "oi-first")
            let short = journeyStay(ctx, utc(1, hour: 17), minutes: 45, lat: 44.6, hex: "oi-short")
            let last = journeyStay(ctx, utc(1, hour: 19), minutes: 600, lat: 45.0, hex: "oi-last")

            let arr = reversed ? [last, short, first] : [first, short, last]
            try ctx.save()
            _ = try await classifier.classifyWithHeuristics(stays: arr)
            return (first.category, short.category, last.category)
        }

        let forward = try await run(reversed: false)
        let backward = try await run(reversed: true)
        #expect(forward == backward)
        #expect(forward.1 == .transit) // the port between the legs
    }
}
