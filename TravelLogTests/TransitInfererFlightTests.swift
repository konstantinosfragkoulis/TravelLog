//
//  TransitInfererFlightTests.swift
//  TravelLogTests
//
//  Pure, DB-independent branches of `TransitInferer.inferFlight(distanceKm:
//  gapSeconds:from:to:)` — the flight-classification gate. Two of its three
//  conditions are deterministic regardless of whether `airports.json` loads in
//  the test host:
//   • the 300 km displacement FLOOR short-circuits to false before any airport
//     lookup, and
//   • the `nearDeparture || nearArrival` airport gate fails for mid-ocean
//     endpoints (no airport within 3 km whether the bundle DB loads or is empty).
//  Positive near-airport→flight paths are exercised below behind an
//  airport-dataset `#require`.
//
//  NOT `@MainActor`: `inferFlight` constructs no `@Model` (it takes only scalars
//  and `CLLocationCoordinate2D`), so the suite avoids needless main-actor hops.
//  Calls are synchronous because `inferFlight` is `nonisolated`.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

struct TransitInfererFlightTests {

    private func inferer() throws -> TransitInferer {
        TransitInferer(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    /// Mid-Atlantic endpoints: ~556 km apart, far from any airport in
    /// airports.json, so the airport gate is deterministically false in both
    /// the loaded and the empty-DB test-host states.
    private static let midAtlanticA = CLLocationCoordinate2D(latitude: 30.0, longitude: -40.0)
    private static let midAtlanticB = CLLocationCoordinate2D(latitude: 35.0, longitude: -40.0)

    @Test("displacement below the 300 km floor is not a flight (short-circuits before any airport lookup)")
    func displacementBelow300kmIsNotFlight() throws {
        let sut = try inferer()
        #expect(sut.inferFlight(distanceKm: 200, gapSeconds: 3600,
                                from: Self.midAtlanticA, to: Self.midAtlanticB) == false)
    }

    @Test("boundary: 299.9 km between open-ocean endpoints is below the floor")
    func displacementJustBelowFloorBoundaryIsNotFlight() throws {
        let sut = try inferer()
        #expect(sut.inferFlight(distanceKm: 299.9, gapSeconds: 3600,
                                from: Self.midAtlanticA, to: Self.midAtlanticB) == false)
    }

    @Test("zero displacement is not a flight — a stay that did not move cannot fly")
    func zeroDisplacementIsNotFlight() throws {
        let sut = try inferer()
        #expect(sut.inferFlight(distanceKm: 0, gapSeconds: 3600,
                                from: Self.midAtlanticA, to: Self.midAtlanticB) == false)
    }

    @Test("a long-haul displacement over open ocean is not a flight — neither endpoint is near an airport")
    func longHaulOverOpenOceanIsNotFlight() throws {
        let sut = try inferer()
        #expect(sut.inferFlight(distanceKm: 5000, gapSeconds: 3600,
                                from: Self.midAtlanticA, to: Self.midAtlanticB) == false)
    }
}

// MARK: - Geometry re-pass (Settings "Detect Flights")

/// `reinferUnknownLegsGeometry` — the upgrade-only revisit of terminal
/// `.unknown` legs after an airport-dataset expansion. These tests pin the
/// CONTRACT deterministically (never touches ground modes or flights; never
/// upgrades short or airport-less legs); the positive upgrade path is
/// exercised behind an airport-dataset `#require`.
///
/// `@MainActor` because the fixtures construct `@Model` stays.
@MainActor
struct TransitInfererReinferTests {

    private func seededStay(
        _ ctx: ModelContext,
        lat: Double, lon: Double,
        start: Date, end: Date,
        transit: TransitMode?,
        distanceFromPreviousKm: Double?
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = distanceFromPreviousKm
        ctx.insert(stay)
        return stay
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    @Test("re-pass never touches ground modes, flights, or short unknown legs, and never upgrades over open ocean")
    func reinferUpgradeOnlyContract() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Predecessor for the ocean leg (mid-Atlantic, no airport anywhere).
        _ = seededStay(ctx, lat: 30.0, lon: -40.0,
                       start: utc(2025, 6, 1, 8), end: utc(2025, 6, 1, 10),
                       transit: nil, distanceFromPreviousKm: nil)
        // Long unknown leg over open ocean: ≥300 km, tight gap — passes the
        // predicate, fails the airport gate in BOTH host-bundle states.
        let ocean = seededStay(ctx, lat: 35.0, lon: -40.0,
                               start: utc(2025, 6, 1, 12), end: utc(2025, 6, 1, 18),
                               transit: .unknown, distanceFromPreviousKm: 556)
        // Short unknown leg: below the 300 km floor — never fetched.
        let short = seededStay(ctx, lat: 35.5, lon: -40.0,
                               start: utc(2025, 6, 2, 12), end: utc(2025, 6, 2, 18),
                               transit: .unknown, distanceFromPreviousKm: 120)
        // Legacy ground mode and an existing flight: outside the predicate.
        let ground = seededStay(ctx, lat: 36.0, lon: -40.0,
                                start: utc(2025, 6, 3, 12), end: utc(2025, 6, 3, 18),
                                transit: .automotive, distanceFromPreviousKm: 400)
        let flight = seededStay(ctx, lat: 37.0, lon: -40.0,
                                start: utc(2025, 6, 4, 12), end: utc(2025, 6, 4, 18),
                                transit: .flight, distanceFromPreviousKm: 800)
        try ctx.save()

        let inferer = TransitInferer(modelContainer: container)
        let outcome = await inferer.reinferUnknownLegsGeometry()

        // A failed read rolls back and leaves every seeded mode in place, so
        // the unchanged-mode checks below only mean something after a pass
        // that actually reached the gates and finished the backlog.
        #expect(!outcome.failed)
        #expect(outcome.complete)
        #expect(outcome.upgraded == 0)
        // Re-read through a fresh context — the actor saved (or didn't) on
        // its own context.
        let fresh = ModelContext(container)
        let all = (try? fresh.fetch(FetchDescriptor<Stay>())) ?? []
        func mode(_ id: UUID) -> String? {
            all.first { $0.id == id }?.transitFromPreviousRaw
        }
        #expect(mode(ocean.id) == TransitMode.unknown.rawValue)
        #expect(mode(short.id) == TransitMode.unknown.rawValue)
        #expect(mode(ground.id) == TransitMode.automotive.rawValue)
        #expect(mode(flight.id) == TransitMode.flight.rawValue)
    }

    @Test("a stale stored leg distance cannot fabricate a flight; the decision uses current-predecessor geometry")
    func staleStoredDistanceDoesNotFabricateFlight() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Current predecessor AT Athens airport, ending an hour before the
        // stay — the leg as it exists TODAY is ~70 km (Boeotia), far below
        // the 300 km floor.
        _ = seededStay(ctx, lat: 37.9128, lon: 23.9449,
                       start: utc(2024, 11, 17, 10), end: utc(2024, 11, 17, 12),
                       transit: nil, distanceFromPreviousKm: nil)
        // The stay still carries a STALE 1,500 km stored distance from the
        // predecessor it had before imports inserted the airport stay. The
        // stale value passes the predicate floor AND (pre-fix) the speed
        // gate (1 h ≪ 1500/400 h) with a genuine airport departure — the
        // exact fabricated-flight recipe.
        let stale = seededStay(ctx, lat: 38.2, lon: 23.2,
                               start: utc(2024, 11, 17, 13), end: utc(2024, 11, 17, 18),
                               transit: .unknown, distanceFromPreviousKm: 1500)
        try ctx.save()

        let inferer = TransitInferer(modelContainer: container)
        let outcome = await inferer.reinferUnknownLegsGeometry()

        // The stale-distance checks below hold trivially after a failed
        // read, so the pass must have run its gates to the end.
        #expect(!outcome.failed)
        #expect(outcome.complete)
        #expect(outcome.upgraded == 0)
        let fresh = ModelContext(container)
        let all = (try? fresh.fetch(FetchDescriptor<Stay>())) ?? []
        let reread = all.first { $0.id == stale.id }
        #expect(reread?.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        // Upgrade-only pass: a non-upgrade must not rewrite the stored leg.
        #expect(reread?.distanceFromPreviousKm == 1500)
    }

    @Test("a genuine upgrade stores the geometry it vouched for, replacing a garbage stored distance")
    func genuineUpgradeRefreshesStoredDistance() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // ATH → AMS (~2,160 km) with the envelope suite's typical 4.6 h gap;
        // the stored distance is garbage (9,999 km) but still ≥ the
        // predicate floor, so the leg is revisited.
        _ = seededStay(ctx, lat: 37.9128, lon: 23.9449,
                       start: utc(2024, 11, 17, 10), end: utc(2024, 11, 17, 12),
                       transit: nil, distanceFromPreviousKm: nil)
        let leg = seededStay(ctx, lat: 52.2948, lon: 4.74505,
                             start: utc(2024, 11, 17, 12).addingTimeInterval(4.6 * 3600),
                             end: utc(2024, 11, 17, 22),
                             transit: .unknown, distanceFromPreviousKm: 9999)
        try ctx.save()

        let inferer = TransitInferer(modelContainer: container)
        let upgraded = await inferer.reinferUnknownLegsGeometry().upgraded

        #expect(upgraded == 1)
        let fresh = ModelContext(container)
        let all = (try? fresh.fetch(FetchDescriptor<Stay>())) ?? []
        let reread = all.first { $0.id == leg.id }
        #expect(reread?.transitFromPreviousRaw == TransitMode.flight.rawValue)
        let stored = try #require(reread?.distanceFromPreviousKm)
        #expect((2_000...2_300).contains(stored))
    }

    @Test("drain batch reporting: inferTransitForRecentStays returns the fetched count")
    func drainBatchCountReporting() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Three unclassified stays (mid-ocean → they will classify to
        // .unknown deterministically).
        for day in 1...3 {
            _ = seededStay(ctx, lat: 30.0 + Double(day), lon: -40.0,
                           start: utc(2025, 7, day, 8), end: utc(2025, 7, day, 10),
                           transit: nil, distanceFromPreviousKm: nil)
        }
        try ctx.save()

        let inferer = TransitInferer(modelContainer: container)
        let first = await inferer.inferTransitForRecentStays()
        #expect(first == 3) // fetched the whole (sub-batch-size) backlog
        let second = await inferer.inferTransitForRecentStays()
        #expect(second == 0) // terminal values — backlog drained, no refetch
    }

    @Test("equal predecessor endTimes break on the larger uuidString, as the Flight Log does")
    func predecessorEndTimeTieMatchesFlightLog() async throws {
        let lowID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        for laterStartHasHighID in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            // Co-ended predecessors at different places; the later start
            // used to win regardless of id.
            let earlierStart = seededStay(ctx, lat: 31.0, lon: -40.0,
                                          start: utc(2025, 7, 1, 8), end: utc(2025, 7, 1, 12),
                                          transit: .unknown, distanceFromPreviousKm: nil)
            let laterStart = seededStay(ctx, lat: 32.0, lon: -40.0,
                                        start: utc(2025, 7, 1, 10), end: utc(2025, 7, 1, 12),
                                        transit: .unknown, distanceFromPreviousKm: nil)
            earlierStart.id = laterStartHasHighID ? lowID : highID
            laterStart.id = laterStartHasHighID ? highID : lowID
            let target = seededStay(ctx, lat: 30.0, lon: -40.0,
                                    start: utc(2025, 7, 1, 15), end: utc(2025, 7, 1, 18),
                                    transit: nil, distanceFromPreviousKm: nil)
            try ctx.save()

            let inferer = TransitInferer(modelContainer: container)
            #expect(await inferer.inferTransitForRecentStays() == 1)

            let expected = laterStartHasHighID ? laterStart : earlierStart
            let expectedKm = CLLocation(latitude: expected.centroidLatitude,
                                        longitude: expected.centroidLongitude)
                .distance(from: CLLocation(latitude: 30.0, longitude: -40.0)) / 1000.0
            let reread = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
                .first { $0.id == target.id })
            #expect(reread.distanceFromPreviousKm == expectedKm)
        }
    }
}

// MARK: - Detection envelope

/// Pins the pass/fail envelope of the geometry gate for synthetic flight
/// profiles. The modeled live-SLC gap is boarding dwell (~0.75 h) plus
/// block time (km/750 + 0.5 h) plus landing dwell (~0.5 h). The gate
/// demands gap < km/400, so typical dwell requires about 1,600 km
/// (about 900 km with shorter dwell, or 3,000 km with longer dwell).
/// These tests preserve the current medium-haul blindspot. A future
/// probable-flight tier would change the corresponding FAIL expectations.
///
/// Uses the bundled airports.json with an ATH endpoint. A missing or
/// empty airport dataset fails the required check because the app ships it.
struct TransitInfererDetectionEnvelopeTests {

    private static let athAirport = CLLocationCoordinate2D(latitude: 37.9128, longitude: 23.9449)
    private static let amsAirport = CLLocationCoordinate2D(latitude: 52.2948, longitude: 4.74505)
    private static let viennaAirport = CLLocationCoordinate2D(latitude: 48.11, longitude: 16.5697)

    private func inferer() throws -> TransitInferer {
        TransitInferer(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    @Test("long-haul live-SLC flight passes: ATH→AMS (2,160 km) with a modeled 4.6 h gap")
    func longHaulTypicalGapPasses() throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let sut = try inferer()
        #expect(sut.inferFlight(distanceKm: 2160, gapSeconds: 4.6 * 3600,
                                from: Self.athAirport, to: Self.amsAirport))
    }

    @Test("boundary: between airports at flight speed, 299.9 km fails the floor and 300 km passes")
    func displacementFloorBoundaryBetweenAirports() throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let sut = try inferer()
        // Both endpoints are airports and a 6 minute gap is far faster than
        // any ground speed, so only the 300 km floor separates the two.
        #expect(sut.inferFlight(distanceKm: 299.9, gapSeconds: 360,
                                from: Self.athAirport, to: Self.amsAirport) == false)
        #expect(sut.inferFlight(distanceKm: 300, gapSeconds: 360,
                                from: Self.athAirport, to: Self.amsAirport))
    }

    @Test("medium-haul blindspot: ATH→VIE (1,280 km) with a typical 3.5 h gap FAILS the 400 km/h gate")
    func mediumHaulTypicalGapFails() throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let sut = try inferer()
        // Threshold is 1280/400 = 3.2 h; the modeled gap is 3.5 h.
        // The gate calls this "drivable" and writes .unknown.
        #expect(sut.inferFlight(distanceKm: 1280, gapSeconds: 3.5 * 3600,
                                from: Self.athAirport, to: Self.viennaAirport) == false)
    }

    @Test("photo-import blindspot: any flight bracketed by photos days apart fails the speed gate")
    func photoImportDayGapFails() throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let sut = try inferer()
        // Last Athens photo two days before the first Amsterdam photo:
        // 48 h ≫ 5.4 h threshold. Every photo-era flight looks like this.
        #expect(sut.inferFlight(distanceKm: 2160, gapSeconds: 48 * 3600,
                                from: Self.athAirport, to: Self.amsAirport) == false)
    }
}
