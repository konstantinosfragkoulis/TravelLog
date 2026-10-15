//
//  CollectionsAggregatorTests.swift
//  TravelLogTests
//
//  Covers `CollectionsAggregator` — the pure reductions behind the Stats
//  "Collections" feature (airports visited / flight log / Places gazetteer).
//
//  Focus areas:
//  1. Airport attribution + the home/routine guard (living inside the 3 km
//     airport ring must not produce daily "airport visits").
//  2. Flight-leg reconstruction: `TransitInferer`'s exact predecessor rule
//     (latest endTime < arrival start, 7-day lookback), airport-to-airport
//     distance, code-vs-place fallbacks, antimeridian safety.
//  3. Places ontology: metro > island > locality precedence, (name, ISO)
//     keying, nil-ISO folding, the 25 km `.area` cluster fallback, and the
//     distinct-trips visit unit.
//  4. Determinism: shuffled input must produce identical output.
//
//  Airport lookups are INJECTED fixtures — the bundled 5,300-entry dataset
//  is never consulted, so these tests pin grouping logic, not data.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, making `@Model` types MainActor-isolated.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct CollectionsAggregatorTests {

    // MARK: - Fixture airports

    private static let ath = AirportRecord(
        code: "ATH", lat: 37.9364, lon: 23.9445,
        name: "Athens International", city: "Athens", iso: "GR", svc: true)
    private static let ams = AirportRecord(
        code: "AMS", lat: 52.3086, lon: 4.76389,
        name: "Amsterdam Schiphol", city: "Amsterdam", iso: "NL", svc: true)
    private static let jfk = AirportRecord(
        code: "JFK", lat: 40.63945, lon: -73.77932,
        name: "John F. Kennedy International", city: "New York", iso: "US", svc: true)
    /// About 105 km from ATH: a domestic short hop under the 300 km fastLeg floor.
    private static let jsy = AirportRecord(
        code: "JSY", lat: 37.4228, lon: 24.9509,
        name: "Syros Airport", city: "Ermoúpolis", iso: "GR", svc: true)
    /// About 222 km from ATH: a longer domestic pair, still under the
    /// 300 km fastLeg floor.
    private static let gpa = AirportRecord(
        code: "GPA", lat: 38.1511, lon: 21.4256,
        name: "Twinville Airport", city: "Twinville", iso: "GR", svc: true)
    /// Military field with no scheduled service (the Tanagra LGTG case).
    private static let lgtg = AirportRecord(
        code: "LGTG", lat: 38.3398, lon: 23.565,
        name: "Tanagra Air Base", city: "Tanagra", iso: "GR", svc: false)

    /// Nearest fixture airport within 3 km — same contract as the production
    /// `AirportDetector.nearestAirport` default.
    private static func resolver(_ coordinate: CLLocationCoordinate2D) -> AirportRecord? {
        let candidates = [ath, ams, jfk, jsy, gpa, lgtg]
        let best = candidates
            .map { (record: $0, km: CollectionsAggregator.haversineKm(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: $0.lat, lon2: $0.lon)) }
            .filter { $0.km <= 3 }
            .min { $0.km < $1.km }
        return best?.record
    }

    // MARK: - Fixture stays

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeStay(
        category: StayCategory,
        lat: Double, lon: Double,
        start: Date, end: Date,
        isAirport: Bool = false,
        transit: TransitMode? = nil,
        distanceFromPreviousKm: Double? = nil,
        distanceFromHomeKm: Double = 0,
        metroName: String? = nil,
        islandName: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        country: String? = nil,
        isoCountryCode: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: distanceFromHomeKm, pingIDs: []
        )
        stay.category = category
        stay.isAirport = isAirport
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = distanceFromPreviousKm
        stay.metroName = metroName
        stay.islandName = islandName
        stay.locality = locality
        stay.administrativeArea = administrativeArea
        stay.country = country
        stay.isoCountryCode = isoCountryCode
        return stay
    }

    private func aggregate(
        _ stays: [Stay],
        dismissed: Set<UUID> = []
    ) -> CollectionsAggregator.Collections {
        // Places are trip-membership-gated (2026-08-04 gate-residue fix:
        // suppressed errand stays are permanently tripless `.destination`
        // residue and must not mint place rows). These fixtures pin the
        // GROUPING semantics, so the harness supplies the membership
        // precondition: destination stays without a trip ride one shared
        // trip. Tests that pin trip counts attach their own explicitly.
        let harnessTrip = Trip(startDate: stays.first?.startTime ?? .now)
        for stay in stays where stay.category == .destination && stay.trip == nil {
            stay.trip = harnessTrip
        }
        // Explicit empty dismissed set — the production default reads the
        // host's real UserDefaults, which would make tests order-dependent.
        return CollectionsAggregator.aggregate(
            stays: stays, nearestAirport: Self.resolver, dismissedCandidates: dismissed)
    }

    // MARK: - Airports

    @Test("airport stays group by nearest airport with visit counts and date range")
    func airportGrouping() {
        let stays = [
            makeStay(category: .transit, lat: 37.937, lon: 23.945,
                     start: date(2023, 3, 31, hour: 8), end: date(2023, 3, 31, hour: 10),
                     isAirport: true),
            makeStay(category: .transit, lat: 37.936, lon: 23.944,
                     start: date(2024, 7, 9, hour: 18), end: date(2024, 7, 9, hour: 20),
                     isAirport: true),
            makeStay(category: .transit, lat: 52.309, lon: 4.764,
                     start: date(2024, 7, 9, hour: 23), end: date(2024, 7, 10, hour: 1),
                     isAirport: true),
        ]
        let result = aggregate(stays)

        #expect(result.airports.map(\.code) == ["AMS", "ATH"]) // alphabetical
        let ath = result.airports.first { $0.code == "ATH" }
        #expect(ath?.stayCount == 2)
        #expect(ath?.firstVisit == date(2023, 3, 31, hour: 8))
        #expect(ath?.lastVisit == date(2024, 7, 9, hour: 20))
        #expect(ath?.name == "Athens International")
        #expect(ath?.isoCountryCode == "GR")
    }

    @Test("home and routine stays inside the airport ring never become airport visits")
    func homeNearAirportExcluded() {
        let stays = [
            makeStay(category: .home, lat: 37.937, lon: 23.945,
                     start: date(2024, 1, 31), end: date(2024, 2, 1), isAirport: true),
            makeStay(category: .routine, lat: 37.936, lon: 23.944,
                     start: date(2024, 2, 2), end: date(2024, 2, 2, hour: 14), isAirport: true),
        ]
        #expect(aggregate(stays).airports.isEmpty)
    }

    @Test("home-category airport stay counts when far from the home centre (ATH inside a 25 km home radius)")
    func homeRadiusAirportCounts() {
        // A synthetic home radius includes ATH. The injected airport dwell
        // has category .home and sits beyond the visit-distance guard.
        let departureDwell = makeStay(category: .home, lat: 37.937, lon: 23.945,
                                      start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                                      isAirport: true, distanceFromHomeKm: 18)
        let atHouse = makeStay(category: .home, lat: 37.937, lon: 23.945,
                               start: date(2024, 6, 30), end: date(2024, 7, 1),
                               isAirport: true, distanceFromHomeKm: 1)
        let result = aggregate([departureDwell, atHouse])
        let ath = result.airports.first { $0.code == "ATH" }
        #expect(ath != nil)
        #expect(ath?.stayCount == 1) // the at-house stay stays excluded
    }

    @Test("brief drive-by stays inside the ring don't count; flight endpoints are dwell-exempt")
    func driveByDwellGuard() {
        // 8 minutes at a scheduled airport — a drop-off drive-past.
        let driveBy = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 6, 30, hour: 10), end: date(2024, 6, 30, hour: 10, minute: 8),
                               isAirport: true)
        #expect(aggregate([driveBy]).airports.isEmpty)

        // A 10-minute SLC dwell at the ARRIVAL airport of a flight counts.
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                           isAirport: true)
        let briefArrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                                    start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 21, minute: 10),
                                    isAirport: true, transit: .flight)
        let result = aggregate([dep, briefArrival])
        #expect(result.airports.first { $0.code == "AMS" }?.flownThrough == true)
    }

    @Test("non-scheduled fields (LGTG) need flight evidence; drive-bys never surface them")
    func militaryFieldRequiresFlightEvidence() {
        // Two 40-minute traffic stays near the airbase (dwell alone passes
        // the drive-by guard — the svc filter is the backstop).
        let traffic1 = makeStay(category: .transit, lat: 38.34, lon: 23.566,
                                start: date(2024, 3, 30, hour: 9), end: date(2024, 3, 30, hour: 9, minute: 40),
                                isAirport: true)
        let traffic2 = makeStay(category: .transit, lat: 38.34, lon: 23.566,
                                start: date(2024, 4, 30, hour: 9), end: date(2024, 4, 30, hour: 9, minute: 40),
                                isAirport: true)
        #expect(aggregate([traffic1, traffic2]).airports.isEmpty)

        // But a genuine flight out of a non-scheduled field surfaces it.
        let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 4, 30, hour: 13), end: date(2024, 4, 30, hour: 14),
                               isAirport: true, transit: .flight)
        let withFlight = aggregate([traffic2, arrival])
        #expect(withFlight.airports.first { $0.code == "LGTG" }?.flownThrough == true)
    }

    @Test("flight endpoints are tiered flown-through; a lone ground visit is not")
    func flownThroughTiering() {
        let stays = [
            // Departure dwell at ATH…
            makeStay(category: .transit, lat: 37.937, lon: 23.945,
                     start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                     isAirport: true),
            // …flight leg arriving at AMS.
            makeStay(category: .transit, lat: 52.309, lon: 4.764,
                     start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                     isAirport: true, transit: .flight),
            // Unrelated JFK pickup months later — set foot only.
            makeStay(category: .transit, lat: 40.640, lon: -73.779,
                     start: date(2024, 9, 30, hour: 10), end: date(2024, 9, 30, hour: 11),
                     isAirport: true),
        ]
        let result = aggregate(stays)
        #expect(result.airports.first { $0.code == "ATH" }?.flownThrough == true)
        #expect(result.airports.first { $0.code == "AMS" }?.flownThrough == true)
        #expect(result.airports.first { $0.code == "JFK" }?.flownThrough == false)
    }

    // MARK: - Flights

    @Test("airport-to-airport flight builds route codes, distance, and estimate")
    func flightRecordRoute() throws {
        let departure = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                                 start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                                 isAirport: true)
        let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                               isAirport: true, transit: .flight)
        let result = aggregate([departure, arrival])

        #expect(result.flights.count == 1)
        let flight = try #require(result.flights.first)
        #expect(flight.departureCode == "ATH")
        #expect(flight.arrivalCode == "AMS")
        // Great-circle ATH–AMS is ~2,160 km; assert the band, and that the
        // estimate is exactly the documented formula over that distance.
        #expect(flight.distanceKm > 2000 && flight.distanceKm < 2300)
        #expect(flight.estimatedHours == flight.distanceKm / 780 + 0.5)
        #expect(flight.isInternational == true)
        #expect(flight.date == arrival.startTime)
        #expect(flight.routeLabel == "ATH → AMS")
        #expect(result.flightStats.totalFlights == 1)
        #expect(result.flightStats.longestRouteLabel == "ATH → AMS")
    }

    @Test("city departure without a nearby airport falls back to place name + stored distance")
    func cityDepartureFallback() throws {
        // Athens city centre is ~20 km from ATH — outside the 3 km ring.
        let departure = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                                 start: date(2024, 7, 8), end: date(2024, 7, 9, hour: 18),
                                 metroName: "Athens", isoCountryCode: "GR")
        let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 7, 9, hour: 23), end: date(2024, 7, 10, hour: 1),
                               isAirport: true, transit: .flight,
                               distanceFromPreviousKm: 2205)
        let result = aggregate([departure, arrival])

        let flight = try #require(result.flights.first)
        #expect(flight.departureCode == nil)
        #expect(flight.departurePlace == "Athens")
        #expect(flight.arrivalCode == "AMS")
        #expect(flight.distanceKm == 2205) // stored leg value, not centroid math
        #expect(flight.routeLabel == "Athens → AMS")
        #expect(flight.isInternational == true) // stay ISO fallback on the city side
    }

    @Test("an unclassified true predecessor wins departure attribution (predecessor-only lane)")
    func unclassifiedPredecessorAttribution() throws {
        // During a classification backlog the
        // leg's true chronological predecessor may still be `.unclassified`
        // — invisible to the old visited+transit pool, so the departure was
        // attributed from an older classified stay (wrong route/window).
        // The unclassified stay joins ONLY the predecessor walk: it must
        // win attribution yet never become an airport/place entry.
        let staleClassified = makeStay(category: .destination, lat: 52.309, lon: 4.764,
                                       start: date(2024, 6, 30), end: date(2024, 7, 1),
                                       isAirport: true)
        let unclassifiedTrue = makeStay(category: .unclassified, lat: 37.937, lon: 23.945,
                                        start: date(2024, 7, 9, hour: 12), end: date(2024, 7, 9, hour: 18),
                                        isAirport: true)
        let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                               isAirport: true, transit: .flight)
        let result = CollectionsAggregator.aggregate(
            stays: [staleClassified, arrival],
            predecessorOnlyStays: [unclassifiedTrue],
            nearestAirport: Self.resolver,
            dismissedCandidates: [])
        let leg = try #require(result.flights.first)
        #expect(leg.departureCode == "ATH")
        #expect(leg.departureWindowStart == unclassifiedTrue.endTime)
        // Predecessor-only means ENTRY-invisible: the unclassified stay
        // never mints a place entry.
        #expect(!result.places.contains { $0.name == "Athens" })
    }

    @Test("predecessor picks the latest endTime and attributes at ANY gap — the 7-day cap was an inference rule, not a display rule")
    func predecessorRule() throws {
        let stale = makeStay(category: .destination, lat: 37.937, lon: 23.945,
                             start: date(2024, 6, 30), end: date(2024, 7, 1, hour: 12),
                             isAirport: true)
        let fresh = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                             start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                             isAirport: true)
        let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                               start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                               isAirport: true, transit: .flight)
        let withBoth = aggregate([stale, fresh, arrival])
        #expect(withBoth.flights.first?.departureCode == "ATH")
        #expect(withBoth.flights.first?.departureWindowStart == fresh.endTime)

        // Only the stale stay (8+ days before arrival) — the confirmed
        // photo-era shape. The 7-day-capped lookup
        // used to render "? → AMS" for the very leg the review queue had
        // just shown as "ATH → …": departure lost, no ISO pair, no window.
        // The stale stay is the last place the user was seen — the honest
        // departure at any gap.
        let lateArrival = makeStay(
            category: .transit, lat: 52.309, lon: 4.764,
            start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
            isAirport: true, transit: .flight)
        let photoEra = aggregate([stale, lateArrival])
        #expect(photoEra.flights.count == 1)
        let leg = try #require(photoEra.flights.first)
        #expect(leg.departureCode == "ATH")
        #expect(leg.arrivalCode == "AMS")
        #expect(leg.isInternational == true)
        #expect(leg.departureWindowStart == stale.endTime)
        // Airport-to-airport geometry — no stored distance needed.
        let athToAms = CollectionsAggregator.haversineKm(
            lat1: 37.9364, lon1: 23.9445, lat2: 52.3086, lon2: 4.76389)
        #expect(leg.distanceKm == athToAms)
        // An 8-day endpoint window cannot pin a red-eye — never fabricated.
        #expect(leg.isOvernight == false)
        // The departure airport earns its flown-through mark from the leg.
        #expect(photoEra.airports.first { $0.code == "ATH" }?.flownThrough == true)

        // A stored distance no longer shadows resolved-endpoint geometry.
        let lateArrivalStored = makeStay(
            category: .transit, lat: 52.309, lon: 4.764,
            start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
            isAirport: true, transit: .flight, distanceFromPreviousKm: 2160)
        let stored = aggregate([stale, lateArrivalStored])
        #expect(stored.flights.first?.departureCode == "ATH")
        #expect(stored.flights.first?.distanceKm == athToAms)

        // With NO predecessor at all, the old fallbacks still hold: a
        // stored distance keeps the record with unknown origin…
        let soloStored = aggregate([lateArrivalStored])
        #expect(soloStored.flights.count == 1)
        #expect(soloStored.flights.first?.departureCode == nil)
        #expect(soloStored.flights.first?.departurePlace == nil)
        #expect(soloStored.flights.first?.distanceKm == 2160)
        // …and without any geometry the leg is skipped entirely.
        #expect(aggregate([lateArrival]).flights.isEmpty)
    }

    @Test("equal predecessor endTimes break on id: the higher uuidString sorts last and wins")
    func predecessorEndTimeTieBreaksOnID() throws {
        let lowID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        func legDeparture(athID: UUID, tanagraID: UUID, reverseInput: Bool) -> String? {
            let athens = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                                  start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                                  isAirport: true)
            athens.id = athID
            let tanagra = makeStay(category: .transit, lat: 38.3398, lon: 23.565,
                                   start: date(2024, 7, 9, hour: 14), end: date(2024, 7, 9, hour: 18),
                                   isAirport: true)
            tanagra.id = tanagraID
            let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                                   start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                                   isAirport: true, transit: .flight)
            let stays = [athens, tanagra, arrival]
            return aggregate(reverseInput ? Array(stays.reversed()) : stays).flights.first?.departureCode
        }
        for reverseInput in [false, true] {
            #expect(legDeparture(athID: highID, tanagraID: lowID, reverseInput: reverseInput) == "ATH")
            #expect(legDeparture(athID: lowID, tanagraID: highID, reverseInput: reverseInput) == "LGTG")
        }
    }

    @Test("overnight is claimed inside a ≤24h endpoint window and suppressed beyond it")
    func overnightWindowGate() throws {
        // Departure fix 22:00 UTC at ATH (solar ≈ +1.6h → 23:36), arrival
        // fix 04:00 UTC next day (solar 05:36): the window crosses 02:00
        // solar at the departure longitude, and it is 6h wide → a real
        // red-eye claim.
        let redEyeDeparture = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                                       start: date(2024, 7, 9, hour: 20),
                                       end: date(2024, 7, 9, hour: 22),
                                       isAirport: true)
        let redEyeArrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                                     start: date(2024, 7, 10, hour: 4),
                                     end: date(2024, 7, 10, hour: 5),
                                     isAirport: true, transit: .flight)
        let redEye = aggregate([redEyeDeparture, redEyeArrival])
        #expect(redEye.flights.first?.isOvernight == true)

        // The same leg with fixes 3 days apart trivially contains 02:00 —
        // that is information-free, so the claim is suppressed.
        let wideDeparture = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                                     start: date(2024, 7, 6, hour: 20),
                                     end: date(2024, 7, 6, hour: 22),
                                     isAirport: true)
        let wideArrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                                   start: date(2024, 7, 10, hour: 4),
                                   end: date(2024, 7, 10, hour: 5),
                                   isAirport: true, transit: .flight)
        let wide = aggregate([wideDeparture, wideArrival])
        #expect(wide.flights.first?.isOvernight == false)
    }

    @Test("legacy ground transit modes never produce flight records")
    func groundModesIgnored() {
        let a = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                         start: date(2024, 5, 30), end: date(2024, 5, 31))
        let b = makeStay(category: .destination, lat: 39.6627, lon: 20.8569,
                         start: date(2024, 5, 31, hour: 18), end: date(2024, 6, 1),
                         transit: .automotive, distanceFromPreviousKm: 500)
        #expect(aggregate([a, b]).flights.isEmpty)
    }

    @Test("route pair is unordered and stats sum across both directions")
    func mostFlownRouteUnordered() {
        let stays = [
            makeStay(category: .transit, lat: 37.937, lon: 23.945,
                     start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                     isAirport: true),
            makeStay(category: .transit, lat: 52.309, lon: 4.764,
                     start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                     isAirport: true, transit: .flight),
            makeStay(category: .transit, lat: 52.309, lon: 4.764,
                     start: date(2024, 7, 19, hour: 8), end: date(2024, 7, 19, hour: 10),
                     isAirport: true),
            makeStay(category: .transit, lat: 37.937, lon: 23.945,
                     start: date(2024, 7, 19, hour: 13, minute: 30), end: date(2024, 7, 19, hour: 14),
                     isAirport: true, transit: .flight),
        ]
        let stats = aggregate(stays).flightStats
        #expect(stats.totalFlights == 2)
        #expect(stats.mostFlownRouteLabel == "AMS – ATH")
        #expect(stats.mostFlownRouteCount == 2)
        // ATH↔AMS spans |23.94 − 4.76| / 15 ≈ 1.28 → 1 zone each way.
        #expect(stats.timeZonesCrossedTotal == 2)
    }

    @Test("antimeridian: time zones and distance wrap correctly")
    func antimeridianSafety() {
        #expect(CollectionsAggregator.timeZonesCrossed(lon1: 179, lon2: -179) == 0)
        #expect(CollectionsAggregator.timeZonesCrossed(lon1: 0, lon2: 180) == 12)
        #expect(CollectionsAggregator.timeZonesCrossed(lon1: -170, lon2: 170) == 1)
        let shortHop = CollectionsAggregator.haversineKm(lat1: 0, lon1: 179, lat2: 0, lon2: -179)
        #expect(shortHop > 200 && shortHop < 250) // 2° at the equator, not 358°
    }

    @Test("overnight heuristic: interval crossing 02:00 solar-local at departure")
    func overnightDetection() {
        // 23:00 → 04:00 UTC at longitude 0 crosses 02:00.
        #expect(CollectionsAggregator.intervalCrossesSolarHour(
            start: date(2025, 6, 10, hour: 23), end: date(2025, 6, 11, hour: 4),
            longitude: 0, hour: 2))
        // 23:00 → 01:00 does not reach it.
        #expect(!CollectionsAggregator.intervalCrossesSolarHour(
            start: date(2025, 6, 10, hour: 23), end: date(2025, 6, 11, hour: 1),
            longitude: 0, hour: 2))
        // Daytime hop, no.
        #expect(!CollectionsAggregator.intervalCrossesSolarHour(
            start: date(2025, 6, 10, hour: 9), end: date(2025, 6, 10, hour: 14),
            longitude: 0, hour: 2))
        // 22:00–23:30 UTC at 45°E is 01:00–02:30 solar-local — crosses.
        #expect(CollectionsAggregator.intervalCrossesSolarHour(
            start: date(2025, 6, 10, hour: 22), end: date(2025, 6, 10, hour: 23, minute: 30),
            longitude: 45, hour: 2))
        // ≥24 h interval always contains the hour.
        #expect(CollectionsAggregator.intervalCrossesSolarHour(
            start: date(2025, 6, 10, hour: 9), end: date(2025, 6, 12, hour: 9),
            longitude: 0, hour: 2))
    }

    // MARK: - Possible flights (review queue)

    @Test("fastLeg: a medium-haul .unknown leg at flight-only effective speed becomes a candidate")
    func fastLegCandidate() throws {
        // ATH airport dwell → city stay 2,160 km away, 4.6 h gap: effective
        // ~470 km/h — the certain tier missed it (it was written .unknown),
        // the probable tier must surface it.
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                           isAirport: true)
        let arr = makeStay(category: .destination, lat: 52.3848, lon: 4.8487,
                           start: date(2024, 7, 9, hour: 22, minute: 36), end: date(2024, 7, 11),
                           transit: .unknown, distanceFromPreviousKm: 2160,
                           metroName: "Amsterdam", isoCountryCode: "NL")
        let result = aggregate([dep, arr])
        #expect(result.flights.isEmpty) // nothing auto-written
        #expect(result.possibleFlights.count == 1)
        let candidate = try #require(result.possibleFlights.first)
        #expect(candidate.evidence == .fastLeg)
        #expect(candidate.record.departureCode == "ATH")
        #expect(candidate.record.arrivalPlace == "Amsterdam")

        // Same leg at a 20 h gap (~108 km/h — drivable): not a candidate
        // via speed… but it IS a cross-border ≥700 km jump, so the sparse
        // tier still offers it (weaker evidence).
        let slowArr = makeStay(category: .destination, lat: 52.3848, lon: 4.8487,
                               start: date(2024, 7, 10, hour: 14), end: date(2024, 7, 11),
                               transit: .unknown, distanceFromPreviousKm: 2160,
                               metroName: "Amsterdam", isoCountryCode: "NL")
        // Give the departure a country so the ISO comparison can fire.
        let depGR = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                             start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                             isAirport: true, isoCountryCode: "GR")
        let slow = aggregate([depGR, slowArr])
        #expect(slow.possibleFlights.first?.evidence == .countryJump)
    }

    @Test("bothAirports: two different airports back-to-back is a candidate even under 300 km")
    func bothAirportsCandidateUnder300Km() throws {
        // ATH → JSY, about 105 km, same country: below the fastLeg floor and
        // no country jump, so only two different codes, ≥80 km and
        // ≥25 km/h door to door within 4 h can claim it. Two airport
        // endpoints already rule out a port-to-port ferry; the speed floor
        // and the window cap only drop windows too wide for one flight.
        func hop(gapHours: Double, to airport: AirportRecord = Self.jsy) -> CollectionsAggregator.Collections {
            let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                               start: date(2024, 7, 30, hour: 8), end: date(2024, 7, 30, hour: 10),
                               isAirport: true, isoCountryCode: "GR")
            let arrival = date(2024, 7, 30, hour: 10).addingTimeInterval(gapHours * 3600)
            let arr = makeStay(category: .transit, lat: airport.lat, lon: airport.lon,
                               start: arrival, end: arrival.addingTimeInterval(3600),
                               isAirport: true, transit: .unknown, isoCountryCode: "GR")
            return aggregate([dep, arr])
        }
        // 1 h gap: about 105 km/h.
        let candidate = try #require(hop(gapHours: 1).possibleFlights.first)
        #expect(candidate.evidence == .bothAirports)
        #expect(candidate.record.routeLabel == "ATH → JSY")
        #expect(candidate.record.distanceKm > 80 && candidate.record.distanceKm < 300)
        // 2 h and 3 h gaps (about 53 and 35 km/h): sparse fixes around a
        // real hop, offered for review rather than lost.
        #expect(hop(gapHours: 2).possibleFlights.first?.evidence == .bothAirports)
        #expect(hop(gapHours: 3).possibleFlights.first?.evidence == .bothAirports)
        // A ferry-day window (8 h, about 13 km/h): nothing claims the leg.
        #expect(hop(gapHours: 8).possibleFlights.isEmpty)
        // A longer domestic pair (ATH → GPA, about 222 km): a 3 h window is
        // offered, but a day-long window (8 h, about 28 km/h, a drive) is
        // past the 4 h cap even though it clears the speed floor.
        let longer = try #require(hop(gapHours: 3, to: Self.gpa).possibleFlights.first)
        #expect(longer.evidence == .bothAirports)
        #expect(longer.record.routeLabel == "ATH → GPA")
        #expect(longer.record.distanceKm > 200 && longer.record.distanceKm < 300)
        #expect(hop(gapHours: 8, to: Self.gpa).possibleFlights.isEmpty)
    }

    @Test("bothAirports outranks fastLeg when both tiers match")
    func bothAirportsOutranksFastLeg() throws {
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 30, hour: 8), end: date(2024, 7, 30, hour: 10),
                           isAirport: true, isoCountryCode: "GR")
        let arr = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                           start: date(2024, 7, 30, hour: 13), end: date(2024, 7, 30, hour: 14),
                           isAirport: true, transit: .unknown,
                           isoCountryCode: "NL")
        let result = aggregate([dep, arr])
        let candidate = try #require(result.possibleFlights.first)
        // Airport-to-airport distance (~2,160 km) at a 3 h gap: both the
        // bothAirports and fastLeg tiers match — strongest evidence wins.
        #expect(candidate.evidence == .bothAirports)
        #expect(candidate.record.routeLabel == "ATH → AMS")
    }

    @Test("countryJump: photo-era legs beyond the 7-day lookback still surface")
    func sparseCountryJumpCandidate() throws {
        // Last Athens photo cluster, then nothing for 9 days, then Amsterdam
        // photos. TransitInferer's no-previous branch wrote .unknown with a
        // nil distance — the miner must look past the cap and use geometry.
        let athens = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                              start: date(2024, 5, 30), end: date(2024, 5, 31),
                              metroName: "Athens", isoCountryCode: "GR")
        let amsterdam = makeStay(category: .destination, lat: 52.3848, lon: 4.8487,
                                 start: date(2024, 6, 9), end: date(2024, 6, 11),
                                 transit: .unknown,
                                 metroName: "Amsterdam", isoCountryCode: "NL")
        let result = aggregate([athens, amsterdam])
        let candidate = try #require(result.possibleFlights.first)
        #expect(candidate.evidence == .countryJump)
        #expect(candidate.record.distanceKm > 2000 && candidate.record.distanceKm < 2300)
        #expect(candidate.gapHours > 200) // the 9-day photo gap, reported honestly
    }

    @Test("islandHop: different-island domestic legs surface; same-island legs never do")
    func islandHopCandidate() throws {
        // An injected domestic island leg is invisible to every country tier
        // and caught by the island signal.
        let athens = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                              start: date(2024, 7, 30), end: date(2024, 8, 1),
                              metroName: "Athens", isoCountryCode: "GR")
        let spilion = makeStay(category: .destination, lat: 35.21961, lon: 24.5341,
                                 start: date(2024, 8, 3), end: date(2024, 8, 6),
                                 transit: .unknown,
                                 metroName: "Spílion", islandName: "Crete",
                                 isoCountryCode: "GR")
        let result = aggregate([athens, spilion])
        let candidate = try #require(result.possibleFlights.first)
        #expect(candidate.evidence == .islandHop)
        // Date honesty: the window starts at the last mainland fix.
        #expect(candidate.record.departureWindowStart == athens.endTime)

        // Two stays on the SAME island ~265 km apart (Crete is long) must
        // not be suggested — no strait was crossed.
        let khersonisos = makeStay(category: .destination, lat: 35.60, lon: 23.50,
                              start: date(2024, 8, 30), end: date(2024, 8, 31),
                              islandName: "Crete", isoCountryCode: "GR")
        let sitia = makeStay(category: .destination, lat: 34.90, lon: 26.30,
                             start: date(2024, 9, 2), end: date(2024, 9, 3),
                             transit: .unknown,
                             islandName: "Crete", isoCountryCode: "GR")
        #expect(aggregate([khersonisos, sitia]).possibleFlights.isEmpty)
    }

    @Test("countryJump floor at 300 km: Athens→Sofia-class flights now surface")
    func mediumCrossBorderCandidate() throws {
        let athens = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                              start: date(2024, 9, 30), end: date(2024, 10, 1),
                              metroName: "Athens", isoCountryCode: "GR")
        let sofia = makeStay(category: .destination, lat: 42.7017, lon: 23.2432,
                             start: date(2024, 10, 3), end: date(2024, 10, 5),
                             transit: .unknown,
                             metroName: "Sofia", isoCountryCode: "BG")
        let result = aggregate([athens, sofia])
        let candidate = try #require(result.possibleFlights.first)
        #expect(candidate.evidence == .countryJump)
        #expect(candidate.record.distanceKm > 450 && candidate.record.distanceKm < 600)
    }

    @Test("ground-mode override: CoreMotion-era .automotive legs re-open only at impossible speed")
    func groundModeOverride() throws {
        // ATH airport dwell → ~1,190 km leg marked .automotive back when
        // CoreMotion's taxi-ride vote won. 5 h gap → ~240 km/h effective:
        // impossible by car, so the strict override suggests it.
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 3, 30, hour: 8), end: date(2024, 3, 30, hour: 10),
                           isAirport: true, isoCountryCode: "GR")
        let fast = makeStay(category: .destination, lat: 46.0265, lon: 14.4710,
                            start: date(2024, 3, 30, hour: 15), end: date(2024, 3, 31),
                            transit: .automotive, isoCountryCode: "SI")
        let result = aggregate([dep, fast])
        #expect(result.possibleFlights.first?.evidence == .fastLeg)

        // The same leg over 8 h (~150 km/h — a hard but possible drive)
        // stays .automotive: CoreMotion measured it, we don't second-guess.
        // Note 150 ≥ the .unknown fastLeg bar (140) — the ground override
        // deliberately demands more (200).
        let slower = makeStay(category: .destination, lat: 46.0265, lon: 14.4710,
                              start: date(2024, 3, 30, hour: 18), end: date(2024, 3, 31),
                              transit: .automotive, isoCountryCode: "SI")
        #expect(aggregate([dep, slower]).possibleFlights.isEmpty)
    }

    @Test("candidate distance ignores stale stored legs — geometry against the true predecessor wins")
    func candidateDistanceIgnoresStaleStored() throws {
        // A later photo import inserted the Vienna stay between two rows
        // whose leg distance (60 km) was computed pre-import. Mining must
        // measure the actual Vienna→Athens geometry, not trust the relic.
        let vienna = makeStay(category: .destination, lat: 48.2219, lon: 16.3336,
                              start: date(2024, 10, 30), end: date(2024, 11, 1),
                              metroName: "Vienna", isoCountryCode: "AT")
        let athens = makeStay(category: .destination, lat: 37.98, lon: 23.72,
                              start: date(2024, 11, 3), end: date(2024, 11, 5),
                              transit: .unknown, distanceFromPreviousKm: 60,
                              metroName: "Athens", isoCountryCode: "GR")
        let result = aggregate([vienna, athens])
        let candidate = try #require(result.possibleFlights.first)
        #expect(candidate.evidence == .countryJump)
        #expect(candidate.record.distanceKm > 1150 && candidate.record.distanceKm < 1350)
    }

    @Test("not flight-shaped: short cross-border hops and slow same-country legs are never suggested")
    func nonCandidates() {
        // The slow cross-border drive is below the country-jump floor
        // and has no airport endpoint.
        let a = makeStay(category: .destination, lat: 39.6627, lon: 20.8569,
                         start: date(2024, 4, 30), end: date(2024, 5, 1),
                         locality: "Ioánnina", isoCountryCode: "GR")
        let b = makeStay(category: .destination, lat: 42.0345, lon: 21.3817,
                         start: date(2024, 5, 1, hour: 18), end: date(2024, 5, 2),
                         transit: .unknown, distanceFromPreviousKm: 230,
                         locality: "Skopje", isoCountryCode: "MK")
        // A same-country leg over 2 days (a meandering road trip):
        // below the 1,200 km same-country floor.
        let c = makeStay(category: .destination, lat: 48.8922, lon: 2.3688,
                         start: date(2024, 5, 9), end: date(2024, 5, 10),
                         locality: "Paris", isoCountryCode: "FR")
        let d = makeStay(category: .destination, lat: 50.7279, lon: 1.6010,
                         start: date(2024, 5, 12), end: date(2024, 5, 13),
                         transit: .unknown, distanceFromPreviousKm: 900,
                         locality: "Boulogne-sur-Mer", isoCountryCode: "FR")
        #expect(aggregate([a, b, c, d]).possibleFlights.isEmpty)
    }

    @Test("dismissed candidates never resurface; confirmed legs move to the real log")
    func dismissalAndConfirmationFlows() {
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                           isAirport: true)
        let arr = makeStay(category: .destination, lat: 52.3848, lon: 4.8487,
                           start: date(2024, 7, 9, hour: 22, minute: 36), end: date(2024, 7, 11),
                           transit: .unknown, distanceFromPreviousKm: 2160,
                           metroName: "Amsterdam", isoCountryCode: "NL")
        // Dismissed: excluded from the queue.
        let dismissed = aggregate([dep, arr], dismissed: [arr.id])
        #expect(dismissed.possibleFlights.isEmpty)
        #expect(dismissed.flights.isEmpty)

        // Confirmed (the UI writes .flight onto the arrival stay): the leg
        // becomes a real FlightRecord and leaves the queue — even though
        // its id is in the dismissed set from some earlier tap-dance.
        arr.transitFromPreviousRaw = TransitMode.flight.rawValue
        let confirmed = aggregate([dep, arr], dismissed: [arr.id])
        #expect(confirmed.possibleFlights.isEmpty)
        #expect(confirmed.flights.count == 1)
        #expect(confirmed.flights.first?.departureCode == "ATH")
    }

    @Test("a leg marked Not a Flight is neither a flight nor a suggestion, however flight-shaped")
    func notFlightLegIsNeverAFlightOrCandidate() {
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 30, hour: 8), end: date(2024, 7, 30, hour: 10),
                           isAirport: true, isoCountryCode: "GR")
        let arr = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                           start: date(2024, 7, 30, hour: 13), end: date(2024, 7, 30, hour: 14),
                           isAirport: true, transit: .notFlight, isoCountryCode: "NL")
        let corrected = aggregate([dep, arr])
        #expect(corrected.flights.isEmpty)
        #expect(corrected.possibleFlights.isEmpty)
        #expect(corrected.flightStats.totalFlights == 0)
        // The same leg left `.unknown` is suggested: the correction is what
        // keeps it out.
        arr.transitFromPreviousRaw = TransitMode.unknown.rawValue
        #expect(aggregate([dep, arr]).possibleFlights.count == 1)
    }

    @Test("a departure from the house inside an airport ring names the place, not that airport; a dwell farther from home keeps its code")
    func homeAtAirportEndpointShowsPlaceName() throws {
        func leg(fromHomeKm: Double) throws -> CollectionsAggregator.FlightRecord {
            let home = makeStay(category: .home, lat: 37.937, lon: 23.945,
                                start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                                isAirport: true, distanceFromHomeKm: fromHomeKm,
                                locality: "Twinville", isoCountryCode: "GR")
            let arrival = makeStay(category: .transit, lat: 52.309, lon: 4.764,
                                   start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                                   isAirport: true, transit: .flight)
            return try #require(aggregate([home, arrival]).flights.first)
        }
        let atHouse = try leg(fromHomeKm: 1)
        #expect(atHouse.departureCode == nil)
        #expect(atHouse.arrivalCode == "AMS")
        #expect(atHouse.routeLabel == "Twinville → AMS")
        let dwell = try leg(fromHomeKm: 18)
        #expect(dwell.departureCode == "ATH")
        #expect(dwell.routeLabel == "ATH → AMS")
        // Only the label changes: the leg's geometry is the same.
        #expect(atHouse.distanceKm == dwell.distanceKm)
    }

    @Test("flight dates read in the endpoint stays' own zones, not the device's, and the record carries its trip")
    func flightDatesUseEndpointZones() throws {
        // Departure 21:00 on 9 July in Athens; arrival 18:00 the same civil
        // day in Los Angeles, which is already 10 July in UTC and Athens.
        let dep = makeStay(category: .transit, lat: 37.937, lon: 23.945,
                           start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                           isAirport: true)
        dep.timeZoneIdentifier = "Europe/Athens"
        let arr = makeStay(category: .destination, lat: 34.0217, lon: -118.2936,
                           start: date(2024, 7, 10, hour: 1), end: date(2024, 7, 13),
                           transit: .flight, distanceFromPreviousKm: 2205)
        arr.timeZoneIdentifier = "America/Los_Angeles"
        let flight = try #require(aggregate([dep, arr]).flights.first)
        #expect(flight.departureTimeZoneIdentifier == "Europe/Athens")
        #expect(flight.arrivalTimeZoneIdentifier == "America/Los_Angeles")
        #expect(flight.tripID != nil)
        #expect(flight.tripID == arr.trip?.id)

        var utcDay = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        utcDay.timeZone = TimeZone(identifier: "UTC")!
        #expect(FlightLogView.flightDateText(flight) == date(2024, 7, 9).formatted(utcDay))
        #expect(FlightLogView.yearSections([flight]).map(\.year) == [2024])

        // Across the date line the arrival's date can come first: leaving
        // Tokyo on 10 July (03:00) for 9 July in Los Angeles shows both
        // dates, departure first, never a reversed range or one date.
        var dateLine = flight
        dateLine.departureTimeZoneIdentifier = "Asia/Tokyo"
        #expect(FlightLogView.flightDateText(dateLine)
            == "\(date(2024, 7, 10).formatted(utcDay)) → \(date(2024, 7, 9).formatted(utcDay))")

        // An unstamped departure reads in the device zone, not the arrival
        // stay's: arriving 15:00 on 10 July on Kiritimati, the window start
        // (18:00 UTC on 9 July) is still 10 July there, but in most device
        // zones it is 9 July and the window is a two-day range.
        var halfZoned = flight
        halfZoned.departureTimeZoneIdentifier = nil
        halfZoned.arrivalTimeZoneIdentifier = "Pacific/Kiritimati"
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let windowStart = try #require(halfZoned.departureWindowStart)
        let startsOnArrivalDay = deviceCalendar.component(.day, from: windowStart) == 10
        let utcInterval = Date.IntervalFormatStyle(
            date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)
        #expect(FlightLogView.flightDateText(halfZoned) == (startsOnArrivalDay
            ? date(2024, 7, 10).formatted(utcDay)
            : (date(2024, 7, 9, hour: 0)..<date(2024, 7, 10, hour: 0)).formatted(utcInterval)))

        // A snapshot written before the zones were carried reads in the
        // device zone, as before.
        var unzoned = flight
        unzoned.departureTimeZoneIdentifier = nil
        unzoned.arrivalTimeZoneIdentifier = nil
        let start = try #require(unzoned.departureWindowStart)
        let deviceZoneText = Calendar.current.isDate(start, inSameDayAs: unzoned.date)
            ? unzoned.date.formatted(.dateTime.day().month(.abbreviated).year())
            : (start..<unzoned.date).formatted(Date.IntervalFormatStyle(date: .abbreviated, time: .omitted))
        #expect(FlightLogView.flightDateText(unzoned) == deviceZoneText)
    }

    // MARK: - Places

    @Test("metro grouping: Gérakas + Agios Dimitrios collapse into Athens with nested localities")
    func metroGrouping() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = Trip(startDate: date(2024, 5, 30))
        ctx.insert(trip)
        let gerakas = makeStay(category: .destination, lat: 38.0228, lon: 23.8576,
                               start: date(2024, 5, 30), end: date(2024, 5, 31),
                               metroName: "Athens", locality: "Gérakas",
                               country: "Greece", isoCountryCode: "GR")
        let agiosDimitrios = makeStay(category: .destination, lat: 37.9313, lon: 23.7371,
                               start: date(2024, 5, 31), end: date(2024, 6, 1),
                               metroName: "Athens", locality: "Agios Dimitrios",
                               country: "Greece", isoCountryCode: "GR")
        ctx.insert(gerakas); ctx.insert(agiosDimitrios)
        gerakas.trip = trip; agiosDimitrios.trip = trip
        try ctx.save()

        let result = aggregate([gerakas, agiosDimitrios])
        #expect(result.places.count == 1)
        let athens = try #require(result.places.first)
        #expect(athens.name == "Athens")
        #expect(athens.kind == .metro)
        #expect(athens.stayCount == 2)
        #expect(athens.tripCount == 1) // ONE trip, not two stays
        #expect(athens.localities == ["Gérakas", "Agios Dimitrios"])
        #expect(athens.dayCount == 3) // three UTC day-starts covered
    }

    @Test("island grouping: the chora folds into its island; same-name locality is not nested")
    func islandChoraGrouping() {
        let chora = makeStay(category: .destination, lat: 37.4405, lon: 24.9399,
                             start: date(2024, 7, 30), end: date(2024, 7, 31),
                             islandName: "Siros", locality: "Siros", isoCountryCode: "GR")
        let beach = makeStay(category: .destination, lat: 37.4605, lon: 24.9301,
                             start: date(2024, 7, 31), end: date(2024, 8, 1),
                             islandName: "Siros", locality: "Vári", isoCountryCode: "GR")
        let result = aggregate([chora, beach])
        #expect(result.places.count == 1)
        #expect(result.places.first?.name == "Siros")
        #expect(result.places.first?.kind == .island)
        #expect(result.places.first?.localities == ["Vári"])
    }

    @Test("metro beats island: Limín Khersonísou groups as its FUA, not as Crete")
    func metroBeatsIsland() {
        let khersonisos = makeStay(category: .destination, lat: 35.3217, lon: 25.3836,
                              start: date(2024, 8, 30), end: date(2024, 9, 2),
                              metroName: "Limín Khersonísou", islandName: "Crete",
                              locality: "Limín Khersonísou", isoCountryCode: "GR")
        let result = aggregate([khersonisos])
        #expect(result.places.first?.name == "Limín Khersonísou")
        #expect(result.places.first?.kind == .metro)
    }

    @Test("transit stays never enter Places")
    func transitExcludedFromPlaces() {
        let layover = makeStay(category: .transit, lat: 45.4250, lon: 9.2155,
                               start: date(2024, 4, 30), end: date(2024, 4, 30, hour: 16),
                               metroName: "Milan", isoCountryCode: "IT")
        #expect(aggregate([layover]).places.isEmpty)
    }

    @Test("same name in different countries stays distinct; nil-ISO folds into its single sibling")
    func nameKeyingAndNilISOFold() {
        let us = makeStay(category: .destination, lat: 39.80, lon: -89.64,
                          start: date(2024, 3, 30), end: date(2024, 3, 31),
                          locality: "Springfield", isoCountryCode: "US")
        let gb = makeStay(category: .destination, lat: 52.09, lon: -1.03,
                          start: date(2024, 4, 3), end: date(2024, 4, 4),
                          locality: "Springfield", isoCountryCode: "GB")
        let two = aggregate([us, gb])
        #expect(two.places.count == 2)

        // A geocode-degraded Limín Khersonísou stay (nil ISO) folds into the GR entry…
        let full = makeStay(category: .destination, lat: 35.3217, lon: 25.3836,
                            start: date(2024, 8, 30), end: date(2024, 8, 31),
                            metroName: "Limín Khersonísou", isoCountryCode: "GR")
        let degraded = makeStay(category: .destination, lat: 35.3217, lon: 25.3836,
                                start: date(2024, 9, 30), end: date(2024, 10, 1),
                                metroName: "Limín Khersonísou")
        let folded = aggregate([full, degraded])
        #expect(folded.places.count == 1)
        #expect(folded.places.first?.stayCount == 2)
        #expect(folded.places.first?.isoCountryCode == "GR")

        // …but with TWO same-named siblings in different countries, the
        // orphan must not guess — it stays its own entry.
        let usDegraded = makeStay(category: .destination, lat: 39.80, lon: -89.64,
                                  start: date(2024, 4, 8), end: date(2024, 4, 9),
                                  locality: "Springfield")
        let ambiguous = aggregate([us, gb, usDegraded])
        #expect(ambiguous.places.count == 3)
    }

    @Test("un-geocoded stays cluster geometrically into labelled areas")
    func areaClusterFallback() {
        // Two nearby stays in Attica and a separate regional point in Epirus.
        let a = makeStay(category: .destination, lat: 38.0556, lon: 23.6495,
                         start: date(2024, 3, 2), end: date(2024, 3, 3),
                         administrativeArea: "Attica", country: "Greece", isoCountryCode: "GR")
        let b = makeStay(category: .destination, lat: 38.0956, lon: 23.6695,
                         start: date(2024, 3, 3), end: date(2024, 3, 4),
                         administrativeArea: "Attica", country: "Greece", isoCountryCode: "GR")
        let c = makeStay(category: .destination, lat: 39.5942, lon: 20.8565,
                         start: date(2024, 3, 11), end: date(2024, 3, 12),
                         administrativeArea: "Epirus", country: "Greece", isoCountryCode: "GR")
        let result = aggregate([a, b, c])
        #expect(result.places.count == 2)
        #expect(result.places.map(\.kind) == [.area, .area])
        let attica = result.places.first { $0.name == "Attica" }
        #expect(attica?.stayCount == 2)
        #expect(result.places.contains { $0.name == "Epirus" })
    }

    @Test("a port stay that missed the island polygon adopts the nearest island (Kypséli → Aegina)")
    func portStayAdoptsIsland() {
        // Vathý resolved normally; the harbour stay's centroid sat
        // half over water and got locality only.
        let vathy = makeStay(category: .destination, lat: 37.7642, lon: 23.4801,
                                 start: date(2024, 8, 30), end: date(2024, 8, 31),
                                 islandName: "Aegina", locality: "Vathý", isoCountryCode: "GR")
        let kypseliPort = makeStay(category: .destination, lat: 37.7562, lon: 23.4374,
                                  start: date(2024, 8, 31), end: date(2024, 9, 1),
                                  locality: "Kypséli", isoCountryCode: "GR")
        let result = aggregate([vathy, kypseliPort])
        #expect(result.places.count == 1)
        let aegina = result.places.first
        #expect(aegina?.name == "Aegina")
        #expect(aegina?.kind == .island)
        #expect(aegina?.localities.contains("Kypséli") == true)
        #expect(aegina?.localities.contains("Vathý") == true)

        // A stay well beyond the adoption radius must NOT be
        // pulled in — it keeps its own locality identity.
        let farTown = makeStay(category: .destination, lat: 37.6100, lon: 23.0912,
                               start: date(2024, 9, 3), end: date(2024, 9, 4),
                               locality: "Lavrio", isoCountryCode: "GR")
        let withFar = aggregate([vathy, kypseliPort, farTown])
        #expect(withFar.places.count == 2)
        #expect(withFar.places.contains { $0.name == "Lavrio" && $0.kind == .locality })
    }

    @Test("country-only geocodes never form a place — the mid-sea ferry stay")
    func countryOnlyStayDropped() {
        // A destination-classified stay from sea pings: country resolved,
        // no admin area, no locality/metro/island. Must not become a
        // "Greece · Area" row.
        let seaStay = makeStay(category: .destination, lat: 37.0, lon: 25.0,
                               start: date(2024, 8, 3, hour: 9), end: date(2024, 8, 3, hour: 13),
                               country: "Greece", isoCountryCode: "GR")
        #expect(aggregate([seaStay]).places.isEmpty)
    }

    @Test("dayCount counts distinct UTC days; utcDays edge cases hold")
    func dayCounting() {
        // The overnight interval covers two UTC days.
        let overnight = makeStay(category: .destination, lat: 48.8922, lon: 2.3688,
                                 start: date(2024, 7, 30, hour: 22), end: date(2024, 7, 31, hour: 9),
                                 locality: "Paris", isoCountryCode: "FR")
        // Same-day revisit adds no new day.
        let sameDay = makeStay(category: .destination, lat: 48.8922, lon: 2.3688,
                               start: date(2024, 7, 31, hour: 12), end: date(2024, 7, 31, hour: 15),
                               locality: "Paris", isoCountryCode: "FR")
        let result = aggregate([overnight, sameDay])
        #expect(result.places.first?.dayCount == 2)

        #expect(CollectionsAggregator.utcDays(
            start: date(2024, 7, 30, hour: 10), end: date(2024, 7, 30, hour: 10)).count == 1)
        #expect(CollectionsAggregator.utcDays(
            start: date(2024, 7, 31), end: date(2024, 7, 30)).isEmpty) // inverted → empty
    }

    @Test("dayCount buckets by the stay's own civil date")
    func dayCountingUsesStayZone() {
        // The daytime AEST interval crosses a UTC midnight.
        let melbourne = makeStay(category: .destination, lat: -37.7523, lon: 144.9363,
                                 start: date(2024, 7, 30, hour: 23), end: date(2024, 7, 31, hour: 8),
                                 locality: "Melbourne", isoCountryCode: "AU")
        melbourne.timeZoneIdentifier = "Australia/Melbourne"
        #expect(aggregate([melbourne]).places.first?.dayCount == 1)

        // The interval stays within one PDT day.
        let losAngeles = makeStay(category: .destination, lat: 34.0217, lon: -118.2936,
                                  start: date(2024, 7, 30, hour: 22), end: date(2024, 7, 31, hour: 3),
                                  locality: "Los Angeles", isoCountryCode: "US")
        losAngeles.timeZoneIdentifier = "America/Los_Angeles"
        #expect(aggregate([losAngeles]).places.first?.dayCount == 1)
    }

    // MARK: - Determinism

    @Test("shuffled input produces identical collections")
    func inputOrderInvariance() {
        var stays = [
            makeStay(category: .transit, lat: 37.937, lon: 23.945,
                     start: date(2024, 7, 9, hour: 15), end: date(2024, 7, 9, hour: 18),
                     isAirport: true),
            makeStay(category: .transit, lat: 52.309, lon: 4.764,
                     start: date(2024, 7, 9, hour: 21), end: date(2024, 7, 9, hour: 22),
                     isAirport: true, transit: .flight),
            makeStay(category: .destination, lat: 52.3848, lon: 4.8487,
                     start: date(2024, 7, 10), end: date(2024, 7, 13),
                     metroName: "Amsterdam", locality: "Jordaan", isoCountryCode: "NL"),
            makeStay(category: .destination, lat: 37.4405, lon: 24.9399,
                     start: date(2024, 7, 30), end: date(2024, 8, 1),
                     islandName: "Siros", locality: "Vári", isoCountryCode: "GR"),
        ]
        let sorted = aggregate(stays)
        stays.reverse()
        let reversed = aggregate(stays)
        #expect(sorted == reversed)
    }

    // MARK: - Parity with the model-read walk

    /// Deterministic generator so a diverging fixture is reproducible from its seed.
    private struct FixtureRNG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Stays over airports, cities, islands and open sea, in a permuted
    /// order, with tied starts and ends, UUID twins, blank and missing names,
    /// every kind of leg, and unclassified rows that only serve as predecessors.
    private func legFixture(seed: UInt64) -> (stays: [Stay], predecessorOnly: [Stay]) {
        var rng = FixtureRNG(state: seed)
        typealias Place = (lat: Double, lon: Double, airport: Bool, iso: String?, metro: String?,
                           island: String?, locality: String?, admin: String?, country: String?)
        let places: [Place] = [
            (37.9364, 23.9445, true, "GR", nil, nil, "Néa Mákri", "Attica", "Greece"),
            (37.98, 23.72, false, "GR", "Athens", nil, "Athens", "Attica", "Greece"),
            (52.3086, 4.76389, true, "NL", nil, nil, "Schiphol", "North Holland", "Netherlands"),
            (52.3848, 4.8487, false, "NL", "Amsterdam", nil, "Jordaan", "North Holland", "Netherlands"),
            (40.63945, -73.77932, true, "US", "New York", nil, "Queens", "New York", "United States"),
            (37.4228, 24.9509, true, "GR", nil, "Siros", nil, "South Aegean", "Greece"),
            (38.1958, 20.4306, false, "GR", nil, "Cephalonia", "Lixoúri", "Ionian Islands", "Greece"),
            (38.3398, 23.565, true, "GR", nil, nil, "Tanagra", "Central Greece", "Greece"),
            (42.7017, 23.2432, false, "BG", nil, nil, nil, nil, "Bulgaria"),
            (36.5, 24.5, false, nil, nil, nil, nil, nil, nil),
        ]
        let categories: [StayCategory] = [.home, .routine, .destination, .transit, .transit, .destination]
        let modes: [String?] = [nil, "flight", "flight", "unknown", "unknown", "unknown", "automotive", "walking",
                                "notFlight"]
        let gapHours: [Double] = [0, 0, 0.5, 2, 6, 30, 200]
        let dwellMinutes: [Double] = [5, 10, 30, 240, 900]
        let homeDistances: [Double] = [0, 3, 12, 900]
        // A quarter of the names are blank and a quarter missing.
        func name(_ value: String?, _ rng: inout FixtureRNG) -> String? {
            switch rng.next(4) {
            case 0: return value == nil ? nil : ""
            case 1: return nil
            default: return value
            }
        }
        func makeRow(_ start: Date, _ category: StayCategory, _ rng: inout FixtureRNG) -> Stay {
            let place = places[rng.next(places.count)]
            let end = start.addingTimeInterval(dwellMinutes[rng.next(dwellMinutes.count)] * 60)
            let latitude = place.lat + Double(rng.next(9) - 4) * 0.001
            let longitude = place.lon + Double(rng.next(9) - 4) * 0.001
            let stored: Double? = rng.next(3) == 0 ? nil : Double(rng.next(2_500))
            let fromHome = homeDistances[rng.next(homeDistances.count)]
            let metro = name(place.metro, &rng)
            let island = name(place.island, &rng)
            let locality = name(place.locality, &rng)
            let admin = name(place.admin, &rng)
            let country = name(place.country, &rng)
            let stay = makeStay(
                category: category, lat: latitude, lon: longitude, start: start, end: end,
                isAirport: place.airport, distanceFromPreviousKm: stored, distanceFromHomeKm: fromHome,
                metroName: metro, islandName: island, locality: locality,
                administrativeArea: admin, country: country, isoCountryCode: place.iso)
            stay.transitFromPreviousRaw = modes[rng.next(modes.count)]
            return stay
        }
        var clock = Date(timeIntervalSince1970: 1_670_969_600)
        var stays: [Stay] = []
        var predecessorOnly: [Stay] = []
        for index in 0..<64 {
            clock = clock.addingTimeInterval(gapHours[rng.next(gapHours.count)] * 3_600)
            let category = categories[rng.next(categories.count)]
            let stay = makeRow(clock, category, &rng)
            if index % 3 == 0 { stay.timeZoneIdentifier = "Europe/Athens" }
            if index % 7 == 6 { stay.id = stays[rng.next(stays.count)].id }
            stays.append(stay)
            if index % 9 == 4 {
                let backlog = makeRow(clock.addingTimeInterval(-3_600), .unclassified, &rng)
                if index % 2 == 0 { backlog.id = stay.id }
                predecessorOnly.append(backlog)
            }
        }
        var shuffled: [Stay] = []
        while !stays.isEmpty { shuffled.append(stays.remove(at: rng.next(stays.count))) }
        return (shuffled, predecessorOnly)
    }

    /// The flight log, review queue and airports as computed before value
    /// rows, reading every field from the models at each use. The numbers
    /// are `CollectionsAggregator`'s private tunables.
    private func referenceLegs(stays: [Stay], predecessorOnly: [Stay]) -> (
        flights: [CollectionsAggregator.FlightRecord],
        candidates: [CollectionsAggregator.PossibleFlight],
        airports: [CollectionsAggregator.AirportEntry]
    ) {
        let nearestAirport = Self.resolver
        let byStart = stays.map { (stay: $0, start: $0.startTime, id: $0.id.uuidString) }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
            .map { $0.stay }
        let byEndKeys = (byStart + predecessorOnly)
            .map { (stay: $0, end: $0.endTime, id: $0.id.uuidString) }
            .sorted {
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }
        let byEnd = byEndKeys.map { $0.stay }
        let endTimes = byEndKeys.map { $0.end }

        func predecessor(of stay: Stay) -> Stay? {
            var low = 0, high = endTimes.count
            while low < high {
                let mid = (low + high) / 2
                if endTimes[mid] < stay.startTime { low = mid + 1 } else { high = mid }
            }
            var index = low - 1
            while index >= 0, byEnd[index].id == stay.id { index -= 1 }
            guard index >= 0 else { return nil }
            return byEnd[index]
        }
        func placeName(for stay: Stay) -> String? {
            let candidates = [stay.metroName, stay.islandName, stay.locality,
                              stay.administrativeArea, stay.country]
            return candidates.compactMap { $0 }.first { !$0.isEmpty }
        }
        func legRecord(stay: Stay, previous: Stay?,
                       preferStoredDistance: Bool) -> CollectionsAggregator.FlightRecord? {
            let arrivalRecord = nearestAirport(
                CLLocationCoordinate2D(latitude: stay.centroidLatitude, longitude: stay.centroidLongitude))
            let departureRecord = previous.flatMap { prev in
                nearestAirport(CLLocationCoordinate2D(latitude: prev.centroidLatitude,
                                                      longitude: prev.centroidLongitude))
            }
            let distanceKm: Double
            if let dep = departureRecord, let arr = arrivalRecord {
                distanceKm = CollectionsAggregator.haversineKm(lat1: dep.lat, lon1: dep.lon,
                                                               lat2: arr.lat, lon2: arr.lon)
            } else if preferStoredDistance, let stored = stay.distanceFromPreviousKm {
                distanceKm = stored
            } else if let prev = previous {
                distanceKm = CollectionsAggregator.haversineKm(
                    lat1: prev.centroidLatitude, lon1: prev.centroidLongitude,
                    lat2: stay.centroidLatitude, lon2: stay.centroidLongitude)
            } else if let stored = stay.distanceFromPreviousKm {
                distanceKm = stored
            } else {
                return nil
            }
            let departureISO = departureRecord?.iso ?? previous?.isoCountryCode
            let arrivalISO = arrivalRecord?.iso ?? stay.isoCountryCode
            let isInternational: Bool?
            if let dep = departureISO, let arr = arrivalISO {
                isInternational = dep != arr
            } else {
                isInternational = nil
            }
            let departureLon = departureRecord?.lon ?? previous?.centroidLongitude
            let arrivalLon = arrivalRecord?.lon ?? stay.centroidLongitude
            let zonesCrossed = departureLon.map {
                CollectionsAggregator.timeZonesCrossed(lon1: $0, lon2: arrivalLon)
            } ?? 0
            let overnight: Bool
            if let prev = previous, let depLon = departureLon,
               stay.startTime.timeIntervalSince(prev.endTime) <= 24 * 60 * 60 {
                overnight = CollectionsAggregator.intervalCrossesSolarHour(
                    start: prev.endTime, end: stay.startTime, longitude: depLon, hour: 2)
            } else {
                overnight = false
            }
            return CollectionsAggregator.FlightRecord(
                id: stay.id,
                departureCode: departureRecord?.code,
                arrivalCode: arrivalRecord?.code,
                departurePlace: previous.flatMap { placeName(for: $0) },
                arrivalPlace: placeName(for: stay),
                departureISO: departureISO,
                arrivalISO: arrivalISO,
                date: stay.startTime,
                distanceKm: distanceKm,
                estimatedHours: distanceKm / 780 + 0.5,
                isInternational: isInternational,
                timeZonesCrossed: zonesCrossed,
                isOvernight: overnight,
                departureWindowStart: previous?.endTime,
                departureTimeZoneIdentifier: previous?.timeZoneIdentifier,
                arrivalTimeZoneIdentifier: stay.timeZoneIdentifier)
        }
        func atHouse(_ stay: Stay) -> Bool {
            stay.isAirport && stay.categoryRaw == StayCategory.home.rawValue && stay.distanceFromHomeKm < 5
        }
        func hidingHomeCodes(_ record: CollectionsAggregator.FlightRecord, stay: Stay,
                             previous: Stay?) -> CollectionsAggregator.FlightRecord {
            var record = record
            if let previous, atHouse(previous) { record.departureCode = nil }
            if atHouse(stay) { record.arrivalCode = nil }
            return record
        }
        func evidence(record: CollectionsAggregator.FlightRecord, stay: Stay, previous: Stay,
                      speedOverrideOnly: Bool) -> CollectionsAggregator.CandidateEvidence? {
            let gapHours = stay.startTime.timeIntervalSince(previous.endTime) / 3600
            guard gapHours > 0 else { return nil }
            let speed = record.distanceKm / gapHours
            if speedOverrideOnly {
                if record.distanceKm >= 300, record.departureCode != nil || record.arrivalCode != nil,
                   speed >= 200 {
                    return .fastLeg
                }
                return nil
            }
            if previous.isAirport, stay.isAirport,
               let dep = record.departureCode, let arr = record.arrivalCode, dep != arr,
               record.distanceKm >= 80, speed >= 60 || (gapHours <= 4 && speed >= 25) {
                return .bothAirports
            }
            if record.distanceKm >= 300, record.departureCode != nil || record.arrivalCode != nil,
               speed >= 140 {
                return .fastLeg
            }
            if let dep = record.departureISO, let arr = record.arrivalISO, dep != arr,
               record.distanceKm >= 300 {
                return .countryJump
            }
            if record.distanceKm >= 1200 { return .countryJump }
            let departureIsland = previous.islandName ?? ""
            let arrivalIsland = stay.islandName ?? ""
            if record.distanceKm >= 250, departureIsland != arrivalIsland,
               !departureIsland.isEmpty || !arrivalIsland.isEmpty {
                return .islandHop
            }
            return nil
        }

        var flights: [CollectionsAggregator.FlightRecord] = []
        var candidates: [CollectionsAggregator.PossibleFlight] = []
        var endpointIDs: Set<UUID> = []
        var recordlessCodes: Set<String> = []
        for stay in byStart {
            guard let transitRaw = stay.transitFromPreviousRaw else { continue }
            if transitRaw == TransitMode.flight.rawValue {
                let previous = predecessor(of: stay)
                endpointIDs.insert(stay.id)
                if let previous { endpointIDs.insert(previous.id) }
                if var record = legRecord(stay: stay, previous: previous, preferStoredDistance: true) {
                    record = hidingHomeCodes(record, stay: stay, previous: previous)
                    record.tripID = stay.trip?.id
                    record.arrivalIdentifier = stay.persistentModelID
                    flights.append(record)
                } else {
                    if let code = nearestAirport(CLLocationCoordinate2D(
                        latitude: stay.centroidLatitude, longitude: stay.centroidLongitude))?.code {
                        recordlessCodes.insert(code)
                    }
                    if let previous, let code = nearestAirport(CLLocationCoordinate2D(
                        latitude: previous.centroidLatitude, longitude: previous.centroidLongitude))?.code {
                        recordlessCodes.insert(code)
                    }
                }
            } else if transitRaw != TransitMode.notFlight.rawValue,
                      let previous = predecessor(of: stay),
                      let record = legRecord(stay: stay, previous: previous, preferStoredDistance: false),
                      let found = evidence(record: record, stay: stay, previous: previous,
                                           speedOverrideOnly: transitRaw != TransitMode.unknown.rawValue) {
                candidates.append(CollectionsAggregator.PossibleFlight(
                    record: hidingHomeCodes(record, stay: stay, previous: previous),
                    evidenceRaw: found.rawValue,
                    gapHours: stay.startTime.timeIntervalSince(previous.endTime) / 3600,
                    arrivalIdentifier: stay.persistentModelID))
            }
        }

        var entries: [String: CollectionsAggregator.AirportEntry] = [:]
        for stay in byStart where stay.isAirport {
            if stay.categoryRaw == StayCategory.routine.rawValue { continue }
            if stay.categoryRaw == StayCategory.home.rawValue, stay.distanceFromHomeKm < 5 { continue }
            if !endpointIDs.contains(stay.id), stay.durationMinutes < 15 { continue }
            guard let record = nearestAirport(CLLocationCoordinate2D(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)) else { continue }
            if var entry = entries[record.code] {
                entry.stayCount += 1
                entry.firstVisit = min(entry.firstVisit, stay.startTime)
                entry.lastVisit = max(entry.lastVisit, stay.endTime)
                entries[record.code] = entry
            } else {
                entries[record.code] = CollectionsAggregator.AirportEntry(
                    code: record.code, name: record.name, city: record.city, isoCountryCode: record.iso,
                    hasScheduledService: record.svc ?? true, stayCount: 1,
                    firstVisit: stay.startTime, lastVisit: stay.endTime, flownThrough: false)
            }
        }
        for flight in flights {
            if let code = flight.departureCode { entries[code]?.flownThrough = true }
            if let code = flight.arrivalCode { entries[code]?.flownThrough = true }
        }
        for code in recordlessCodes { entries[code]?.flownThrough = true }

        let sortedFlights = flights.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        let sortedCandidates = candidates.sorted {
            if $0.record.date != $1.record.date { return $0.record.date > $1.record.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        let airports = entries.values
            .filter { $0.hasScheduledService || $0.flownThrough }
            .sorted { $0.code < $1.code }
        return (sortedFlights, sortedCandidates, airports)
    }

    @Test("value rows reproduce the model-read flight log, review queue and airports, ties and twins included")
    func legWalkMatchesModelReadReference() {
        var flights = 0, candidates = 0, airports = 0
        for seed: UInt64 in [3, 17, 2_024, 77_777] {
            let (stays, predecessorOnly) = legFixture(seed: seed)
            let result = CollectionsAggregator.aggregate(
                stays: stays, predecessorOnlyStays: predecessorOnly,
                nearestAirport: Self.resolver, dismissedCandidates: [])
            let reference = referenceLegs(stays: stays, predecessorOnly: predecessorOnly)
            #expect(result.flights == reference.flights, "seed \(seed): flight log diverged")
            #expect(result.possibleFlights == reference.candidates, "seed \(seed): review queue diverged")
            #expect(result.airports == reference.airports, "seed \(seed): airports diverged")
            flights += reference.flights.count
            candidates += reference.candidates.count
            airports += reference.airports.count
        }
        // Not vacuous: every lane produced rows.
        #expect(flights > 0)
        #expect(candidates > 0)
        #expect(airports > 0)
        let empty = CollectionsAggregator.aggregate(
            stays: [], predecessorOnlyStays: [], nearestAirport: Self.resolver, dismissedCandidates: [])
        #expect(empty == CollectionsAggregator.Collections())
    }

    @Test("UUID-twin port stays adopt their own island and keep their own zone in Places")
    func twinRowsKeepTheirOwnAdoptionAndZone() {
        let shared = UUID()
        // 22:00 to 02:00 UTC: one civil day in Athens, two in UTC.
        let aeginaPort = makeStay(category: .destination, lat: 37.790, lon: 23.221,
                                  start: date(2024, 7, 30, hour: 22), end: date(2024, 7, 31, hour: 2),
                                  administrativeArea: "Attica", isoCountryCode: "GR")
        aeginaPort.id = shared
        aeginaPort.timeZoneIdentifier = "Europe/Athens"
        let cephaloniaPort = makeStay(category: .destination, lat: 38.202, lon: 20.435,
                                 start: date(2024, 7, 30, hour: 22), end: date(2024, 7, 31, hour: 2),
                                 administrativeArea: "Ionian Islands", isoCountryCode: "GR")
        cephaloniaPort.id = shared
        let aegina = makeStay(category: .destination, lat: 37.791, lon: 23.222,
                              start: date(2024, 8, 3, hour: 10), end: date(2024, 8, 3, hour: 12),
                              islandName: "Aegina", isoCountryCode: "GR")
        let cephalonia = makeStay(category: .destination, lat: 38.203, lon: 20.436,
                             start: date(2024, 8, 3, hour: 10), end: date(2024, 8, 3, hour: 12),
                             islandName: "Cephalonia", isoCountryCode: "GR")
        let rows = [cephaloniaPort, aegina, aeginaPort, cephalonia]
        let places = aggregate(rows).places
        #expect(places.map(\.name).sorted() == ["Aegina", "Cephalonia"])
        #expect(places.first { $0.name == "Aegina" }?.dayCount == 2)
        #expect(places.first { $0.name == "Cephalonia" }?.dayCount == 3)
        #expect(places.allSatisfy { $0.stayCount == 2 && $0.kind == .island })
        let byStart = rows.sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
        #expect(CollectionsAggregator.placeEntriesForTesting(byStart: byStart) == places)
    }

    @Test("the area-cluster seam reads trip and zone from any stay it is given")
    func areaClusterSeamReadsEveryCategory() throws {
        let trip = Trip(startDate: date(2025, 5, 1))
        let stay = makeStay(category: .transit, lat: 38, lon: 24,
                            start: date(2025, 5, 1, hour: 20), end: date(2025, 5, 2, hour: 10),
                            administrativeArea: "Attica", isoCountryCode: "GR")
        stay.trip = trip
        stay.timeZoneIdentifier = "Asia/Tokyo"
        var entries: [String: CollectionsAggregator.PlaceEntry] = [:]
        var tripIDs: [String: Set<UUID>] = [:]
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        CollectionsAggregator.appendAreaClusters(
            unnamed: [stay], entries: &entries, tripIDs: &tripIDs, days: &days, order: &order)
        let key = try #require(order.first)
        #expect(tripIDs[key] == [trip.id])
        // Tokyo: May 2 05:00 to 19:00, one civil day.
        #expect(days[key]?.count == 1)
    }

    @Test("the stay entry point checks cancellation before copying each stay")
    func rowCopiesFollowCheckpoints() {
        let trip = Trip(startDate: date(2025, 5, 1))
        let stays = (0..<3).map { day in
            let stay = makeStay(category: .destination, lat: 38, lon: 24,
                                start: date(2025, 5, 1 + day), end: date(2025, 5, 1 + day, hour: 14),
                                metroName: "Athens", isoCountryCode: "GR")
            stay.trip = trip
            return stay
        }
        var calls = 0
        let result = CollectionsAggregator.aggregate(
            stays: stays, nearestAirport: Self.resolver, dismissedCandidates: []
        ) {
            calls += 1
            // A stay copied right after its own checkpoint carries that
            // call's name; one copied before any checkpoint keeps "Athens".
            for stay in stays { stay.metroName = "Metro \(calls)" }
        }
        #expect(Set(result.places.map(\.name)).count == stays.count)
        #expect(!result.places.contains { $0.name == "Athens" })
    }
}

// MARK: - Same-named towns in one country must not merge

extension CollectionsAggregatorTests {

    private func placeStay(
        locality: String,
        admin: String?,
        iso: String,
        startDay: Double,
        trip: Trip,
        in ctx: ModelContext
    ) -> Stay {
        let start = Date(timeIntervalSince1970: 1_714_515_200 + startDay * 86_400)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 35.19, centroidLongitude: 25.71,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
            distanceFromHomeKm: 300, pingIDs: []
        )
        stay.category = .destination
        stay.locality = locality
        stay.administrativeArea = admin
        stay.isoCountryCode = iso
        stay.country = "Greece"
        ctx.insert(stay)
        stay.trip = trip
        return stay
    }

    /// Two different towns that share a name in one country must stay separate.
    @Test("same-named towns in different admin areas do not merge into one place")
    func homonymTownsDoNotMerge() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let tripA = Trip(startDate: Date(timeIntervalSince1970: 1_714_515_200))
        let tripB = Trip(startDate: Date(timeIntervalSince1970: 1_715_015_200))
        ctx.insert(tripA)
        ctx.insert(tripB)
        // Agios Nikolaos, Crete vs Agios Nikolaos, Epirus.
        _ = placeStay(locality: "Agios Nikolaos", admin: "Crete", iso: "GR", startDay: 0, trip: tripA, in: ctx)
        _ = placeStay(locality: "Agios Nikolaos", admin: "Epirus", iso: "GR", startDay: 10, trip: tripB, in: ctx)
        try ctx.save()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let places = CollectionsAggregator.placeEntriesForTesting(byStart: stays.sorted { $0.startTime < $1.startTime })
        let agios = places.filter { $0.name == "Agios Nikolaos" }
        #expect(agios.count == 2)
        #expect(agios.allSatisfy { $0.stayCount == 1 })
    }

    /// The counterpart guard: ONE real place whose admin area is consistent
    /// must still collapse to a single row - qualifying every key would have
    /// split real places apart.
    @Test("a single town visited twice stays one place")
    func consistentPlaceStaysMerged() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let tripA = Trip(startDate: Date(timeIntervalSince1970: 1_714_515_200))
        let tripB = Trip(startDate: Date(timeIntervalSince1970: 1_715_015_200))
        ctx.insert(tripA)
        ctx.insert(tripB)
        // Same town twice; the second visit resolved no admin area at all.
        _ = placeStay(locality: "Kontakaíika", admin: "North Aegean", iso: "GR", startDay: 0, trip: tripA, in: ctx)
        _ = placeStay(locality: "Kontakaíika", admin: nil, iso: "GR", startDay: 10, trip: tripB, in: ctx)
        try ctx.save()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let places = CollectionsAggregator.placeEntriesForTesting(byStart: stays.sorted { $0.startTime < $1.startTime })
        let kontakaiika = places.filter { $0.name == "Kontakaíika" }
        #expect(kontakaiika.count == 1)
        #expect(kontakaiika.first?.stayCount == 2)
    }
}
