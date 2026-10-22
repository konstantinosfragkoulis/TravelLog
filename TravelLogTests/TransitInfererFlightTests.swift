//
//  TransitInfererFlightTests.swift
//  TravelLogTests
//
//  `TransitInferer` records a flight only where `FlightJudge` says so
//  (`FlightJudgeTests` pins the judge itself): over the drain, on the stay
//  whose leg holds the journey's flight, never where no scheduled airport
//  serves an end. Calendar corroboration is pinned here too.
//
//  Airports are the bundled `airports.json` (ATH and MLA at their dataset
//  points); every other point is a round fictional coordinate at sea, far
//  from any airport.
//

import Testing
import Foundation
import CoreLocation
import EventKit
import SwiftData
@testable import TravelLog

@MainActor
struct TransitInfererFlightTests {

    private static func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @discardableResult
    private static func insert(
        _ ctx: ModelContext, _ point: (lat: Double, lon: Double), from start: Date, to end: Date,
        isAirport: Bool = false, transit: TransitMode? = nil
    ) -> Stay {
        let stay = Stay(startTime: start, endTime: end,
                        centroidLatitude: point.lat, centroidLongitude: point.lon,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        stay.isAirport = isAirport
        stay.transitFromPreviousRaw = transit?.rawValue
        ctx.insert(stay)
        return stay
    }

    private static func mode(_ container: ModelContainer, _ id: UUID) throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == id }?.transitFromPreviousRaw
    }

    private static func drain(_ container: ModelContainer, dismissed: Set<UUID> = []) async -> TransitInferer.DrainOutcome {
        let inferer = TransitInferer(modelContainer: container)
        return await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await TransitInferer.TestScope.$dismissedArrivals.withValue(dismissed) {
                await inferer.inferTransitForRecentStaysReportingChanges()
            }
        }
    }

    /// Athens International and Malta International, dataset points.
    private static let ath = (lat: 37.9364, lon: 23.9445)
    private static let mla = (lat: 35.84593, lon: 14.49155)
    /// Open sea on the way, about 570 km from ATH and 300 km from any
    /// scheduled airport.
    private static let seaFix = (lat: 36.0, lon: 18.0)

    @Test("a leg over open ocean is never a flight, however fast")
    func openOceanIsNeverAFlight() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // About 556 km in an hour between two points no airport serves.
        Self.insert(ctx, (30.0, -40.0), from: Self.utcDate(2025, 6, 1, 8), to: Self.utcDate(2025, 6, 1, 8))
        let far = Self.insert(ctx, (35.0, -40.0), from: Self.utcDate(2025, 6, 1, 9), to: Self.utcDate(2025, 6, 1, 12))
        try ctx.save()
        let outcome = await Self.drain(container)
        #expect(!outcome.failed && outcome.flights == 0)
        #expect(try Self.mode(container, far.id) == TransitMode.unknown.rawValue)
    }

    @Test("a fix in the air upgrades the journey's first stay once the landing arrives; a dismissal holds")
    func laterLandingUpgradesTheFix() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        for dismissLanding in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            // At ATH until 9:00 (last seen 8:30), a fix at sea at 9:30, and
            // nothing else yet: no scheduled airport serves the fix.
            Self.insert(ctx, Self.ath, from: Self.utcDate(2025, 6, 1, 6), to: Self.utcDate(2025, 6, 1, 9),
                        isAirport: true)
            let fix = Self.insert(ctx, Self.seaFix, from: Self.utcDate(2025, 6, 1, 9, 30),
                                  to: Self.utcDate(2025, 6, 1, 9, 35))
            try ctx.save()
            #expect(await Self.drain(container).flights == 0)
            #expect(try Self.mode(container, fix.id) == TransitMode.unknown.rawValue)

            // Landed at MLA at 10:40: 570 km in an hour on the way there,
            // faster than anything on the ground. The flight goes on the fix.
            let later = ModelContext(container)
            let landing = Self.insert(later, Self.mla, from: Self.utcDate(2025, 6, 1, 10, 40),
                                      to: Self.utcDate(2025, 6, 1, 12), isAirport: true)
            try later.save()
            let outcome = await Self.drain(container, dismissed: dismissLanding ? [landing.id] : [])
            #expect(!outcome.failed)
            #expect(outcome.flights == (dismissLanding ? 0 : 1))
            #expect(try Self.mode(container, fix.id)
                    == (dismissLanding ? TransitMode.unknown : TransitMode.flight).rawValue)
            #expect(try Self.mode(container, landing.id) == TransitMode.unknown.rawValue)
        }
    }

// MARK: Calendar corroboration

    private static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    private static func event(_ title: String, start: Date, end: Date) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            externalIdentifier: "e", localIdentifier: "l", title: title,
            notes: nil, locationText: nil, startDate: start, endDate: end,
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud)
    }

    @Test("a flight event inside the padded query but after the leg ends does not turn the drive to the airport into a flight")
    func flightEventAfterTheLegDoesNotCorroborate() {
        // The drive ends half an hour before the booked flight starts.
        let gapStart = Self.utc(2024, 11, 17, 10)
        let gapEnd = Self.utc(2024, 11, 17, 12)
        let later = Self.event("Flight to Twinville",
                               start: gapEnd.addingTimeInterval(30 * 60),
                               end: gapEnd.addingTimeInterval(90 * 60))
        #expect(!TransitInferer.corroboratingFlightEvent(
            in: [later], gapStart: gapStart, gapEnd: gapEnd))
    }

    @Test("a flight event the leg contains or overlaps still corroborates; a non-flight event never does")
    func overlappingFlightEventCorroborates() {
        let gapStart = Self.utc(2024, 11, 17, 10)
        let gapEnd = Self.utc(2024, 11, 17, 12)
        let inside = Self.event("Flight to Twinville",
                                start: gapStart.addingTimeInterval(30 * 60),
                                end: gapEnd.addingTimeInterval(-30 * 60))
        let acrossStart = Self.event("Flight to Twinville",
                                     start: gapStart.addingTimeInterval(-60 * 60),
                                     end: gapStart.addingTimeInterval(60 * 60))
        let lunch = Self.event("Lunch in Twinville", start: gapStart, end: gapEnd)
        #expect(TransitInferer.corroboratingFlightEvent(
            in: [inside], gapStart: gapStart, gapEnd: gapEnd))
        #expect(TransitInferer.corroboratingFlightEvent(
            in: [acrossStart], gapStart: gapStart, gapEnd: gapEnd))
        #expect(!TransitInferer.corroboratingFlightEvent(
            in: [lunch], gapStart: gapStart, gapEnd: gapEnd))
    }
}

// MARK: - Geometry re-pass (Settings "Detect Flights")

/// `reinferUnknownLegsGeometry` — the upgrade-only revisit of terminal
/// `.unknown` legs under the current judge and airport data. These tests pin
/// the CONTRACT deterministically (never touches ground modes or flights;
/// never upgrades a journey no scheduled airport serves); the positive
/// upgrade path is exercised behind an airport-dataset `#require`.
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
        // Long unknown leg over open ocean, tight gap: no scheduled airport
        // serves either end in BOTH host-bundle states.
        let ocean = seededStay(ctx, lat: 35.0, lon: -40.0,
                               start: utc(2025, 6, 1, 12), end: utc(2025, 6, 1, 18),
                               transit: .unknown, distanceFromPreviousKm: 556)
        // Short unknown leg over the ocean: nothing to record.
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
        // The user's Not a Flight correction: outside the predicate too.
        let corrected = seededStay(ctx, lat: 36.0, lon: -40.0,
                                   start: utc(2025, 6, 2, 12), end: utc(2025, 6, 2, 18),
                                   transit: .notFlight, distanceFromPreviousKm: 556)
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
        #expect(mode(corrected.id) == TransitMode.notFlight.rawValue)
    }

    @Test("a stale stored leg distance cannot fabricate a flight; the decision uses current-predecessor geometry")
    func staleStoredDistanceDoesNotFabricateFlight() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Current predecessor AT Athens airport, ending an hour before the
        // stay — the leg as it exists TODAY is ~70 km, nothing to fly.
        _ = seededStay(ctx, lat: 37.9128, lon: 23.9449,
                       start: utc(2024, 11, 17, 10), end: utc(2024, 11, 17, 12),
                       transit: nil, distanceFromPreviousKm: nil)
        // The stay still carries a STALE 1,500 km stored distance from the
        // predecessor it had before imports inserted the airport stay: with
        // a genuine airport departure and 1 h, the fabricated-flight recipe
        // if the stored value were read.
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

        // ATH → AMS (~2,160 km) with the envelope suite's typical 4.6 h gap
        // (6.6 h from the last fix at ATH); the stored distance is garbage
        // (9,999 km).
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
            // The haversine the Flight Log measures with.
            let expectedKm = CollectionsAggregator.haversineKm(
                lat1: expected.centroidLatitude, lon1: expected.centroidLongitude,
                lat2: 30.0, lon2: -40.0)
            let reread = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
                .first { $0.id == target.id })
            #expect(reread.distanceFromPreviousKm == expectedKm)
        }
    }
}

// MARK: - Detection envelope

/// Pins what the judge records, offers and leaves for the bundled airports
/// the inferer reads (`FlightJudge.Airports.bundled`), from the last fix at
/// the origin to the first at the destination. Short flights between
/// airports are offered, not recorded: a fast train between two airport
/// stations, or a fast ferry, cannot be ruled out with margin.
struct TransitInfererDetectionEnvelopeTests {

    private static let ath = (lat: 37.9364, lon: 23.9445)
    private static let ams = (lat: 52.3086, lon: 4.76389)
    private static let vie = (lat: 48.1103, lon: 16.5697)
    private static let cdg = (lat: 49.00896, lon: 2.55412)
    private static let lys = (lat: 45.726, lon: 5.09014)
    private static let jsy = (lat: 37.4228, lon: 24.9509)
    /// Open sea, over 300 km from any scheduled airport.
    private static let openSea = (lat: 35.0, lon: 18.0)
    /// About 22 km from ATH and 14 km from AMS: served, not at an airport.
    private static let nearATH = (lat: 38.0, lon: 23.7)
    private static let nearAMS = (lat: 52.4, lon: 4.9)

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Last seen at the origin at hour 0 (a single fix), first seen at the
    /// destination `hours` later.
    private func decision(
        from origin: (lat: Double, lon: Double), to destination: (lat: Double, lon: Double),
        hours: Double, island: String? = nil
    ) throws -> FlightJudge.Decision {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let arrival = Self.base.addingTimeInterval(hours * 3600)
        let timeline = FlightJudge.Timeline([
            FlightJudge.Stay(id: UUID(), start: Self.base, end: Self.base,
                             latitude: origin.lat, longitude: origin.lon, isAirport: false,
                             islandName: nil, pingCount: 1, isPhoto: false, mode: .unknown),
            FlightJudge.Stay(id: UUID(), start: arrival, end: arrival.addingTimeInterval(3600),
                             latitude: destination.lat, longitude: destination.lon, isAirport: false,
                             islandName: island, pingCount: 1, isPhoto: false, mode: .pending),
        ])
        return FlightJudge.recording(for: 1, in: timeline, airports: .bundled, dismissed: []).decision
    }

    @Test("long and medium haul between airports at a typical pace is recorded")
    func airportFlightsAreRecorded() throws {
        // ATH to AMS, about 2,160 km, in 4.6 hours; ATH to VIE, about
        // 1,280 km, in 3.5: no train between the airports manages either.
        #expect(try decision(from: Self.ath, to: Self.ams, hours: 4.6) == .record(.tooFastForSurface))
        #expect(try decision(from: Self.ath, to: Self.vie, hours: 3.5) == .record(.tooFastForSurface))
    }

    @Test("door to door, both ends served: recorded only when no train fits with margin")
    func servedDoorToDoor() throws {
        #expect(try decision(from: Self.nearATH, to: Self.nearAMS, hours: 6) == .record(.tooFastForSurface))
        #expect(try decision(from: Self.nearATH, to: Self.nearAMS, hours: 10) == .suggest(.tooFarOverland))
        // An end no scheduled airport serves: never, however fast.
        #expect(try decision(from: Self.nearATH, to: Self.openSea, hours: 1.5) == .none)
    }

    @Test("short hops between airports are offered, never recorded")
    func shortHopsAreOffered() throws {
        // CDG to LYS, about 390 km, in three hours: the airport train fits.
        #expect(try decision(from: Self.cdg, to: Self.lys, hours: 3) == .suggest(.airportToAirport))
        // ATH to the island airport JSY, about 105 km, in 40 minutes.
        #expect(try decision(from: Self.ath, to: Self.jsy, hours: 2.0 / 3, island: "Twinisle")
                == .suggest(.airportToAirport))
    }

    @Test("photo-import blind spot: a flight bracketed by photos days apart is offered, never recorded")
    func photoDayGapsAreOffered() throws {
        #expect(try decision(from: Self.ath, to: Self.ams, hours: 48) == .suggest(.longGap))
    }
}

// MARK: - Flight model and calendar shape

/// The pure halves of the flight rules: no store.
struct TransitInfererPaceBarTests {

    @Test("the mode model orders the ways of travelling, and recording needs margin")
    func modeModelOrdering() {
        // The fastest door-to-door averages, great circle.
        #expect(FlightJudge.ferryFastestKmh < FlightJudge.roadFastestKmh)
        #expect(FlightJudge.roadFastestKmh < FlightJudge.airportRailFastestKmh)
        #expect(FlightJudge.airportRailFastestKmh <= FlightJudge.railFastestKmh)
        #expect(FlightJudge.railFastestKmh < FlightJudge.airborneKmh)
        #expect(FlightJudge.airborneOverWaterKmh > FlightJudge.ferryFastestKmh)
        #expect(FlightJudge.flightCruiseKmh < FlightJudge.impossibleKmh)
        #expect(FlightJudge.recordMargin > 1)
        #expect(FlightJudge.flightFitSlack < 1)
    }

    @Test("a calendar flight vouches only for a leg of at least 100 km inside two days")
    func calendarShape() {
        let hour: TimeInterval = 3600
        #expect(!TransitInferer.calendarMayVouch(distanceKm: 99, gapSeconds: 2 * hour))
        #expect(TransitInferer.calendarMayVouch(distanceKm: 100, gapSeconds: 2 * hour))
        #expect(TransitInferer.calendarMayVouch(distanceKm: 150, gapSeconds: 48 * hour))
        #expect(!TransitInferer.calendarMayVouch(distanceKm: 150, gapSeconds: 48 * hour + 1))
        #expect(!TransitInferer.calendarMayVouch(distanceKm: 150, gapSeconds: 0))
    }

    @Test("the stored leg distance is the Flight Log's haversine")
    func legDistanceIsHaversine() {
        let from = CLLocationCoordinate2D(latitude: 44.3, longitude: 12.9)
        let to = CLLocationCoordinate2D(latitude: 45.6, longitude: 12.9)
        #expect(TransitInferer.legDistanceKm(from: from, to: to)
                == CollectionsAggregator.haversineKm(lat1: 44.3, lon1: 12.9, lat2: 45.6, lon2: 12.9))
    }
}

// MARK: - User decisions

/// A candidate the user dismissed in the Flight Log is the user's word that
/// the leg was not a flight. Rules that grew more permissive must not
/// overrule it on any path: the drain, the batch outside the gate, and both
/// Detect Flights re-passes. Calendar evidence also needs a gap of at most
/// two days.
@MainActor
struct TransitInfererUserDecisionTests {

    private static let ath = (lat: 37.9128, lon: 23.9449)
    private static let ams = (lat: 52.2948, lon: 4.74505)

    private static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    @discardableResult
    private static func makeStay(
        _ ctx: ModelContext, lat: Double, lon: Double, start: Date, end: Date,
        transit: TransitMode?, km: Double?
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = km
        ctx.insert(stay)
        return stay
    }

    /// ATH → AMS (~2,160 km), 6.6 h from the last fix at ATH: no train
    /// between the airports manages it, a recorded flight.
    private static func athAmsLeg(_ container: ModelContainer, transit: TransitMode?, km: Double?) throws -> UUID {
        let ctx = ModelContext(container)
        makeStay(ctx, lat: ath.lat, lon: ath.lon,
                 start: utc(2024, 11, 17, 10), end: utc(2024, 11, 17, 12),
                 transit: .unknown, km: nil)
        let target = makeStay(ctx, lat: ams.lat, lon: ams.lon,
                              start: utc(2024, 11, 17, 12).addingTimeInterval(4.6 * 3600),
                              end: utc(2024, 11, 17, 22),
                              transit: transit, km: km)
        try ctx.save()
        return target.id
    }

    /// A ~150 km mid-ocean leg no airport serves (geometry never records
    /// it), above the calendar floor, `gapHours` long.
    private static func calendarLeg(_ container: ModelContainer, gapHours: Double, transit: TransitMode?) throws -> UUID {
        let ctx = ModelContext(container)
        let end = utc(2025, 6, 1, 10)
        makeStay(ctx, lat: 30.0, lon: -40.0, start: utc(2025, 6, 1, 8), end: end,
                 transit: .unknown, km: nil)
        let start = end.addingTimeInterval(gapHours * 3600)
        let target = makeStay(ctx, lat: 31.35, lon: -40.0,
                              start: start, end: start.addingTimeInterval(6 * 3600),
                              transit: transit, km: nil)
        try ctx.save()
        return target.id
    }

    private static func row(_ container: ModelContainer, _ id: UUID) throws -> Stay {
        try #require(try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test("the geometry re-pass never upgrades a dismissed candidate; the same leg undismissed upgrades")
    func geometryRepassKeepsDismissal() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        for dismissed in [true, false] {
            let container = try TestSupport.makeInMemoryContainer()
            let target = try Self.athAmsLeg(container, transit: .unknown, km: 2160)
            let inferer = TransitInferer(modelContainer: container)
            let dismissals: Set<UUID> = dismissed ? [target] : []
            let outcome = await TransitInferer.TestScope.$dismissedArrivals.withValue(dismissals) {
                await inferer.reinferUnknownLegsGeometry(gate: PipelineGate(forTesting: ()))
            }
            #expect(!outcome.failed && outcome.complete)
            #expect(outcome.upgraded == (dismissed ? 0 : 1))
            let stay = try Self.row(container, target)
            #expect(stay.transitFromPreviousRaw
                    == (dismissed ? TransitMode.unknown : TransitMode.flight).rawValue)
        }
    }

    @Test("a re-inferred leg into a dismissed arrival is written unknown, with its distance, on both drains")
    func drainsKeepDismissal() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        for outsideGate in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let target = try Self.athAmsLeg(container, transit: nil, km: nil)
            let inferer = TransitInferer(modelContainer: container)
            let outcome = await TransitInferer.TestScope.$dismissedArrivals.withValue([target]) {
                () async -> TransitInferer.DrainOutcome in
                if outsideGate {
                    return await inferer.inferTransitBatchOutsideGate(
                        gate: PipelineGate(forTesting: ()), publishing: false)
                }
                return await inferer.inferTransitForRecentStaysReportingChanges()
            }
            #expect(!outcome.failed)
            #expect(outcome.flights == 0)
            let stay = try Self.row(container, target)
            #expect(stay.transitFromPreviousRaw == TransitMode.unknown.rawValue)
            #expect((2_000...2_300).contains(try #require(stay.distanceFromPreviousKm)))
        }
    }

    @Test("the calendar re-pass never upgrades a dismissed candidate")
    func calendarRepassKeepsDismissal() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let target = try Self.calendarLeg(container, gapHours: 2, transit: .unknown)
        let inferer = TransitInferer(modelContainer: container)
        let outcome = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await TransitInferer.TestScope.$corroborates.withValue({ _, _ in true }) {
                await TransitInferer.TestScope.$dismissedArrivals.withValue([target]) {
                    await inferer.recorroborateUnknownLegs(gate: PipelineGate(forTesting: ()))
                }
            }
        }
        #expect(!outcome.failed && outcome.complete && outcome.upgraded == 0)
        #expect(try Self.row(container, target).transitFromPreviousRaw == TransitMode.unknown.rawValue)
    }

    @Test("a calendar flight vouches for a leg inside two days, not for a longer silence")
    func calendarNeedsATwoDayGap() async throws {
        for (gapHours, expected) in [(46.0, TransitMode.flight), (50.0, TransitMode.unknown)] {
            let container = try TestSupport.makeInMemoryContainer()
            let target = try Self.calendarLeg(container, gapHours: gapHours, transit: nil)
            let inferer = TransitInferer(modelContainer: container)
            let outcome = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
                await TransitInferer.TestScope.$corroborates.withValue({ _, _ in true }) {
                    await TransitInferer.TestScope.$dismissedArrivals.withValue([]) {
                        await inferer.inferTransitBatchOutsideGate(gate: PipelineGate(forTesting: ()), publishing: false)
                    }
                }
            }
            #expect(!outcome.failed)
            #expect(try Self.row(container, target).transitFromPreviousRaw == expected.rawValue)
        }
        // The Detect Flights calendar re-pass keeps the same bound.
        let container = try TestSupport.makeInMemoryContainer()
        let target = try Self.calendarLeg(container, gapHours: 50, transit: .unknown)
        let inferer = TransitInferer(modelContainer: container)
        let outcome = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await TransitInferer.TestScope.$corroborates.withValue({ _, _ in true }) {
                await TransitInferer.TestScope.$dismissedArrivals.withValue([]) {
                    await inferer.recorroborateUnknownLegs(gate: PipelineGate(forTesting: ()))
                }
            }
        }
        #expect(!outcome.failed && outcome.upgraded == 0)
        #expect(try Self.row(container, target).transitFromPreviousRaw == TransitMode.unknown.rawValue)
    }
}
