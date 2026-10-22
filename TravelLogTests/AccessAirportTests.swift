//
//  AccessAirportTests.swift
//  TravelLogTests
//
//  The airport tier in the bundled data and the guess it feeds
//  (`AccessAirport`): which airport a place outside every airport's ring
//  likely flew from. Fictional places on round coordinates; real airports
//  come from the bundled dataset at run time. Fictional dates.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct AccessAirportTests {

    /// A fictional town on round coordinates 5 km from a small airport with
    /// scheduled service (outside its 3 km ring) and about 118 km from a
    /// connecting hub, with no other scheduled airport within 100 km.
    private static let town = CLLocationCoordinate2D(latitude: -36.7, longitude: 144.3)
    private static let smallCode = "BXG"
    private static let hubCode = "MEL"
    /// Far away abroad, for the flight's other end.
    private static let farCode = "SIN"

    private static func airport(_ code: String) throws -> AirportRecord {
        try #require(AirportDetector.shared.airport(code: code))
    }

    private static func candidates(_ coordinate: CLLocationCoordinate2D) -> [AirportRecord] {
        CollectionsAggregator.bundledAccessAirports(coordinate)
    }

    // MARK: Data

    @Test("the tier decodes, a missing or unknown tier reads unknown, and a major hub reads hub")
    func tierDecodes() throws {
        let json = """
        [{"code":"QQA","lat":10,"lon":0,"svc":true,"size":"S"},
         {"code":"QQB","lat":10,"lon":1,"svc":true,"size":"M"},
         {"code":"QQC","lat":10,"lon":2,"svc":true,"size":"L"},
         {"code":"FRA","lat":10,"lon":3,"svc":true,"size":"L"},
         {"code":"QQD","lat":10,"lon":4},
         {"code":"QQE","lat":10,"lon":5,"size":"X"}]
        """
        let records = try JSONDecoder().decode([AirportRecord].self, from: Data(json.utf8))
        #expect(records.map(\.tier) == [.small, .regional, .major, .hub, .unknown, .unknown])
        #expect(records[4].size == nil && records[4].svc == nil)
        // The memberwise init (fixtures across the tests) leaves it unknown.
        let fixture = AirportRecord(code: "QQF", lat: 10, lon: 6, name: nil, city: nil, iso: nil, svc: true)
        #expect(fixture.tier == .unknown)
    }

    @Test("the bundled airports carry tiers, and every connecting hub the stops suggest reads hub")
    func bundledTiers() throws {
        #expect(try Self.airport(Self.smallCode).tier == .small)
        #expect(try Self.airport(Self.hubCode).tier == .hub)
        #expect(FlightStops.hubCodes.allSatisfy { AirportDetector.shared.airport(code: $0)?.tier == .hub })
    }

    // MARK: The guess

    @Test("a town between a small airport and a hub flies abroad from the hub, and a short hop from the small one")
    func farFlightTakesTheHub() throws {
        let pool = Self.candidates(Self.town)
        let far = AccessAirport.choose(latitude: Self.town.latitude, longitude: Self.town.longitude,
                                       candidates: pool, visited: [], far: true)
        #expect(far?.code == Self.hubCode)
        let near = AccessAirport.choose(latitude: Self.town.latitude, longitude: Self.town.longitude,
                                        candidates: pool, visited: [], far: false)
        #expect(near?.code == Self.smallCode)
    }

    @Test("an airport the user has been at wins, even against a hub on a far flight")
    func visitedAirportWins() throws {
        let small = try Self.airport(Self.smallCode)
        let chosen = AccessAirport.choose(latitude: Self.town.latitude, longitude: Self.town.longitude,
                                          candidates: Self.candidates(Self.town), visited: [small], far: true)
        #expect(chosen?.code == Self.smallCode)
    }

    @Test("a hub beyond the serving radius serves nothing alone, and a JSON without tiers keeps the nearest")
    func servingRadiusAndUntieredData() throws {
        let hub = try Self.airport(Self.hubCode)
        #expect(AccessAirport.choose(latitude: Self.town.latitude, longitude: Self.town.longitude,
                                     candidates: [hub], visited: [], far: true) == nil)
        let untiered = Self.candidates(Self.town).map {
            AirportRecord(code: $0.code, lat: $0.lat, lon: $0.lon, name: $0.name, city: $0.city,
                          iso: $0.iso, svc: $0.svc)
        }
        let chosen = AccessAirport.choose(latitude: Self.town.latitude, longitude: Self.town.longitude,
                                          candidates: untiered, visited: [], far: true)
        #expect(chosen?.code == Self.smallCode)
    }

    // MARK: The Flight Log

    /// Hours after a fictional midnight UTC.
    private static func at(_ hours: Double) -> Date {
        let base: TimeInterval = 1_900_000_000
        return Date(timeIntervalSince1970: base - base.truncatingRemainder(dividingBy: 86_400) + hours * 3600)
    }

    private func flightCodes(from coordinate: CLLocationCoordinate2D, inRing: Bool) throws -> (String?, String?) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let destination = try Self.airport(Self.farCode)
        let departure = Stay(startTime: Self.at(0), endTime: Self.at(5),
                             centroidLatitude: coordinate.latitude, centroidLongitude: coordinate.longitude,
                             h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        departure.category = .transit
        departure.isAirport = inRing
        let arrival = Stay(startTime: Self.at(24), endTime: Self.at(30),
                           centroidLatitude: destination.lat + 0.001, centroidLongitude: destination.lon + 0.001,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        arrival.category = .transit
        arrival.isAirport = true
        arrival.transitFromPreviousRaw = TransitMode.flight.rawValue
        context.insert(departure)
        context.insert(arrival)
        try context.save()
        let flights = CollectionsAggregator.aggregate(stays: [departure, arrival], dismissedCandidates: []).flights
        let flight = try #require(flights.first)
        return (flight.departureCode, flight.arrivalCode)
    }

    @Test("a flight abroad from the town shows the hub, and one from inside the small airport's ring keeps it")
    func flightLogRouteCodes() throws {
        let fromTown = try flightCodes(from: Self.town, inRing: false)
        #expect(fromTown.0 == Self.hubCode)
        #expect(fromTown.1 == Self.farCode)

        let small = try Self.airport(Self.smallCode)
        let fromRing = try flightCodes(
            from: CLLocationCoordinate2D(latitude: small.lat + 0.001, longitude: small.lon + 0.001), inRing: true)
        #expect(fromRing.0 == Self.smallCode)
        #expect(fromRing.1 == Self.farCode)
    }
}
