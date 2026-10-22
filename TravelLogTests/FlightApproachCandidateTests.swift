//
//  FlightApproachCandidateTests.swift
//  TravelLogTests
//
//  Waypoints in the Flight Log: a phone that wakes in the air on a short
//  hop logs a brief stay over the sea on the way down, so the stay after
//  the departure is a fix tens of km short of the arrival airport.
//  `FlightJudge` reads the fix as a waypoint of one journey from the
//  departure to the landing, so the flight is offered once, on the fix (the
//  stay whose leg holds it), and reads, offered or confirmed, like a direct
//  flight to the airport it landed at. Never over a user decision.
//
//  Airports come from the bundled `airports.json` (the production resolver):
//  ATH and JSY at their dataset coordinates. Every other point is a round
//  fictional coordinate at sea or inland, at least 10 km from any airport.
//

import Testing
import Foundation
import CoreLocation
@testable import TravelLog

@MainActor
struct FlightApproachCandidateTests {

    /// Athens International, dataset coordinates.
    private static let ath = (lat: 37.9364, lon: 23.9445)
    /// Syros, dataset coordinates: about 105 km from ATH, across water.
    private static let jsy = (lat: 37.4228, lon: 24.9509)
    /// Open sea about 30 km short of JSY.
    private static let approachFix = (lat: 37.6, lon: 24.7)
    /// Open sea about 32 km short of JSY, a little farther out.
    private static let outerFix = (lat: 37.5, lon: 24.6)
    /// Open sea about 19 km short of JSY.
    private static let innerFix = (lat: 37.55, lon: 24.8)
    /// An inland town about 188 km from JSY, no airport within 10 km.
    private static let town = (lat: 37.9, lon: 22.9)
    /// An inland town about 148 km from ATH, no airport within 10 km.
    private static let inlandTown = (lat: 37.4, lon: 22.4)
    /// About 34 km short of ATH, no airport within 10 km.
    private static let athApproach = (lat: 37.8, lon: 23.6)

    private func time(_ hour: Int, _ minute: Int = 0, day: Int = 1) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: 2030, month: 5, day: day, hour: hour, minute: minute))!
    }

    private func stay(
        _ point: (lat: Double, lon: Double), from start: Date, to end: Date,
        category: StayCategory = .transit, isAirport: Bool = false,
        transit: TransitMode? = .unknown, island: String? = nil, metro: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: point.lat, centroidLongitude: point.lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 200, pingIDs: []
        )
        stay.category = category
        stay.isAirport = isAirport
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.islandName = island
        stay.metroName = metro
        stay.isoCountryCode = "GR"
        return stay
    }

    /// The bundled airport data, with no dismissals (the default reads the
    /// host's UserDefaults).
    private func possibleFlights(
        _ stays: [Stay], dismissed: Set<UUID> = []
    ) -> [CollectionsAggregator.PossibleFlight] {
        CollectionsAggregator.aggregate(stays: stays, dismissedCandidates: dismissed).possibleFlights
    }

    /// The airport at the end of the hop, then a stay in town.
    private func landing(
        at start: Date, transit: TransitMode? = .unknown, dwellMinutes: Double = 30
    ) -> [Stay] {
        [
            stay(Self.jsy, from: start, to: start.addingTimeInterval(dwellMinutes * 60),
                 isAirport: true, transit: transit, island: "Syros"),
            stay((lat: 37.45, lon: 24.92), from: start.addingTimeInterval(45 * 60),
                 to: start.addingTimeInterval(5 * 3600), category: .destination, island: "Syros"),
        ]
    }

    /// ATH to JSY airport to airport, km.
    private static let athToJSYKm = CollectionsAggregator.haversineKm(
        lat1: ath.lat, lon1: ath.lon, lat2: jsy.lat, lon2: jsy.lon)

    /// A record that reads exactly like a direct ATH to JSY flight landing
    /// at `landed`, kept on the fix's id.
    private func expectReadsToLanding(
        _ record: CollectionsAggregator.FlightRecord, fix: Stay, landed: Stay
    ) {
        #expect(record.id == fix.id)
        #expect(record.routeLabel == "ATH → JSY")
        #expect(record.placeRouteLabel == "Athens → Syros")
        #expect(abs(record.distanceKm - Self.athToJSYKm) < 0.001)
        #expect(abs(record.estimatedHours - CollectionsAggregator.estimatedHours(distanceKm: Self.athToJSYKm)) < 0.001)
        #expect(record.date == landed.startTime)
        #expect(record.arrivalISO == "GR")
        #expect(record.isInternational == false)
        #expect(record.arrivalAirportName?.isEmpty == false)
        #expect(record.arrivalLatitude == Self.jsy.lat)
        #expect(record.arrivalLongitude == Self.jsy.lon)
        #expect(record.arrivalStayEnd == landed.endTime)
        #expect(record.arrivalIsHome == false)
    }

    @Test("an airport departure whose journey lands after an approach fix is offered on the fix, reading ATH to the landing airport")
    func airportDepartureIsOffered() throws {
        let departure = stay(Self.ath, from: time(8), to: time(9), isAirport: true, metro: "Athens")
        let fix = stay(Self.approachFix, from: time(9, 40), to: time(9, 45))
        let landed = landing(at: time(9, 52))
        let flights = possibleFlights([departure, fix] + landed)
        let candidate = try #require(flights.first)
        #expect(flights.count == 1)
        #expect(candidate.evidence == .airportToAirport)
        expectReadsToLanding(candidate.record, fix: fix, landed: landed[0])
        // The window runs from the last fix at ATH (9:00 less the 40
        // minutes clustering added) to the landing: 92 minutes.
        #expect(abs(candidate.gapHours - 92.0 / 60) < 0.001)
        #expect(candidate.record.departureWindowStart == departure.endTime)
        #expect(candidate.record.assessment?.lastSeenAtOrigin == time(8, 20))
        // Confirm stores the leg into the fix, not the whole journey.
        let legKm = CollectionsAggregator.haversineKm(
            lat1: Self.ath.lat, lon1: Self.ath.lon, lat2: Self.approachFix.lat, lon2: Self.approachFix.lon)
        #expect(abs(try #require(candidate.legKm) - legKm) < 0.001)
    }

    @Test("a confirmed approach flight reads and counts like a direct one, its short landing a visit, once")
    func confirmedApproachFlightReadsToLanding() throws {
        let departure = stay(Self.ath, from: time(8), to: time(9), isAirport: true, metro: "Athens")
        let fix = stay(Self.approachFix, from: time(9, 40), to: time(9, 45), transit: .flight)
        fix.distanceFromPreviousKm = 76
        // Ten minutes at the airport: under the set-foot minimum.
        let landed = landing(at: time(9, 52), dwellMinutes: 10)
        let collections = CollectionsAggregator.aggregate(
            stays: [departure, fix] + landed, dismissedCandidates: [])
        let flight = try #require(collections.flights.first)
        #expect(collections.flights.count == 1)
        #expect(collections.possibleFlights.isEmpty)
        expectReadsToLanding(flight, fix: fix, landed: landed[0])
        #expect(collections.flightStats.totalFlights == 1)
        #expect(abs(collections.flightStats.totalKm - Self.athToJSYKm) < 0.001)
        let jsy = try #require(collections.airports.first { $0.code == "JSY" })
        #expect(jsy.flownThrough)
        #expect(jsy.stayCount == 1)
        #expect(collections.airports.first { $0.code == "ATH" }?.flownThrough == true)
    }

    @Test("a stay across water reaching the landing airport faster than a ferry is offered, measured from the stay")
    func stayAcrossWaterIsOffered() throws {
        // Last seen in the town at 7:20, landed at 9:52: two and a half
        // hours for 188 km across water to the airport, where a ferry
        // plausibly needs nearly five.
        let departure = stay(Self.town, from: time(4), to: time(8, 30), category: .home)
        let fix = stay(Self.approachFix, from: time(9, 40), to: time(9, 45))
        let flights = possibleFlights([departure, fix] + landing(at: time(9, 52)))
        let candidate = try #require(flights.first)
        #expect(flights.count == 1)
        #expect(candidate.id == fix.id)
        #expect(candidate.evidence == .acrossWater)
        // No airport at the town: it shows the one that likely served it
        // (ATH, about 92 km away), and the distance runs airport to airport.
        #expect(candidate.record.departureCode == "ATH")
        #expect(candidate.record.arrivalCode == "JSY")
        #expect(abs(candidate.record.distanceKm - Self.athToJSYKm) < 0.001)
    }

    @Test("two approach fixes, or a longer one, offer the flight once, on the journey's first stay")
    func waypointsAddNoCandidate() {
        let departure = stay(Self.ath, from: time(8), to: time(9), isAirport: true)
        let outer = stay(Self.outerFix, from: time(9, 36), to: time(9, 38))
        let inner = stay(Self.innerFix, from: time(9, 42), to: time(9, 45))
        let flights = possibleFlights([departure, outer, inner] + landing(at: time(9, 48)))
        #expect(flights.map(\.id) == [outer.id])
        #expect(flights.first?.evidence == .airportToAirport)
        // Twenty minutes over the sea, seven of them clustering's: still on
        // the way.
        let longFix = stay(Self.approachFix, from: time(9, 25), to: time(9, 45))
        #expect(possibleFlights([departure, longFix] + landing(at: time(9, 52))).map(\.id) == [longFix.id])
    }

    @Test("a day long enough for the ferry is not offered, however the fixes fall")
    func ferryDayIsNotOffered() {
        let departure = stay(Self.ath, from: time(8), to: time(9), isAirport: true)
        let fix = stay(Self.approachFix, from: time(9, 40), to: time(9, 45))
        // Landed at 14:00: the fix, followed by four hours of silence, is a
        // place of its own, and neither leg is flight-shaped.
        #expect(possibleFlights([departure, fix] + landing(at: time(14))).isEmpty)
        // From ATH at 3:00 to the landing at 9:52: a ferry's time.
        let early = stay(Self.ath, from: time(3), to: time(5, 30), isAirport: true)
        #expect(possibleFlights([early, fix] + landing(at: time(9, 52))).isEmpty)
    }

    @Test("an approach into an airport on the same land, from a stay with no airport, is not offered")
    func sameLandWithoutDepartureAirportIsNotOffered() {
        // The airport-train shape: into the airport, but no airport at the
        // departure and no water on the way.
        let departure = stay(Self.inlandTown, from: time(6), to: time(8), category: .destination)
        let fix = stay(Self.athApproach, from: time(9, 40), to: time(9, 45))
        let arrival = stay(Self.ath, from: time(9, 52), to: time(10, 30), isAirport: true)
        #expect(possibleFlights([departure, fix, arrival]).isEmpty)
    }

    @Test("Not a Flight, a dismissal of any of its stays, or a flight already in the journey keeps it out of the queue")
    func userDecisionsHold() throws {
        let departure = stay(Self.ath, from: time(8), to: time(9), isAirport: true)
        let notFlight = stay(Self.approachFix, from: time(9, 40), to: time(9, 45), transit: .notFlight)
        #expect(possibleFlights([departure, notFlight] + landing(at: time(9, 52))).isEmpty)

        let fix = stay(Self.approachFix, from: time(9, 40), to: time(9, 45))
        let landed = landing(at: time(9, 52))
        #expect(possibleFlights([departure, fix] + landed, dismissed: [fix.id]).isEmpty)
        // A dismissal kept on the landing (an older queue's key) holds too.
        #expect(possibleFlights([departure, fix] + landed, dismissed: [landed[0].id]).isEmpty)

        let recorded = landing(at: time(9, 52), transit: .flight)
        let collections = CollectionsAggregator.aggregate(stays: [departure, fix] + recorded, dismissedCandidates: [])
        #expect(collections.possibleFlights.isEmpty)
        // The flight kept on the landing reads from the journey's origin.
        let flight = try #require(collections.flights.first)
        #expect(flight.id == recorded[0].id)
        #expect(flight.routeLabel == "ATH → JSY")
    }
}
