//
//  AccessAirportTests.swift
//  TravelLogTests
//
//  The airport tier in the bundled data and the guess it feeds
//  (`AccessAirport`): which airport a place outside every airport's ring
//  likely flew from. Fictional places on round coordinates; real airports
//  come from the bundled dataset at run time, and island ends rank fictional
//  airports on fictional islands through the injectable resolvers.
//  Fictional dates. Real island ends: `AirportReachTests`.
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

    @Test("the island decodes and a missing one reads nil")
    func islandDecodes() throws {
        let json = """
        [{"code":"QQA","lat":10,"lon":0,"svc":true,"isl":"Twinisle"},
         {"code":"QQB","lat":10,"lon":1,"svc":true}]
        """
        let records = try JSONDecoder().decode([AirportRecord].self, from: Data(json.utf8))
        #expect(records.map(\.isl) == ["Twinisle", nil])
    }

    @Test("the bundled airports carry islands")
    func bundledIslands() throws {
        #expect(try Self.airport("JFK").isl == "Long Island")
        #expect(try Self.airport("LGA").isl == "Long Island")
        #expect(try Self.airport("EWR").isl == nil)
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

    // MARK: Island ends

    /// A fictional island town on round coordinates; its flight goes abroad
    /// (`far`) or 333 km within its country.
    private static let islandTown = CLLocationCoordinate2D(latitude: 10.0, longitude: 20.0)
    private static let abroad = AirportRecord(code: "QQF", lat: 30.0, lon: 20.0, name: nil, city: nil,
                                              iso: "QB", svc: true, size: "L")
    private static let domestic = AirportRecord(code: "QQN", lat: 13.0, lon: 20.0, name: nil, city: nil,
                                                iso: "QA", svc: true, size: "L")
    /// Fictional island ids (`AirportRecord.islid`).
    private static let twinisle: Int64 = 9_000_001
    private static let otherisle: Int64 = 9_000_002
    /// The town's commuting area, its part over a border (same name), and
    /// another one.
    private static let townArea = CommutingArea(id: 1, name: "Twinville", iso: "QA", minLatitude: 9.7,
                                                maxLatitude: 10.2, minLongitude: 19.8, maxLongitude: 20.2)
    private static let borderArea = CommutingArea(id: 2, name: "Twinville", iso: "QB", minLatitude: 9.5,
                                                  maxLatitude: 9.7, minLongitude: 19.8, maxLongitude: 20.2)
    private static let otherArea = CommutingArea(id: 3, name: "Otherville", iso: "QA", minLatitude: 9.5,
                                                 maxLatitude: 9.85, minLongitude: 19.8, maxLongitude: 20.2)

    private static func fixture(_ code: String, lat: Double, size: String, island: Int64?) -> AirportRecord {
        AirportRecord(code: code, lat: lat, lon: 20.0, name: nil, city: nil, iso: "QA", svc: true,
                      size: size, isl: island.map { "Isle \($0)" }, islid: island)
    }

    /// The departure code the Flight Log shows for a flight from
    /// `islandTown` (standing on `island`, outside every ring) through the
    /// injectable resolvers over `airports`, after a day at `visited` when
    /// given. `areas` places airports in commuting areas; the town stands in
    /// `townArea`. `storedIsland` is the stay's stored island name, which
    /// the guess never reads.
    private func islandDepartureCode(
        island: Int64?, far: Bool, airports: [AirportRecord], visited: AirportRecord? = nil,
        areas: [String: CommutingArea] = [:], storedIsland: String? = nil
    ) throws -> String? {
        let all = airports + [Self.abroad, Self.domestic]
        func km(_ point: CLLocationCoordinate2D, _ airport: AirportRecord) -> Double {
            CollectionsAggregator.haversineKm(lat1: point.latitude, lon1: point.longitude,
                                              lat2: airport.lat, lon2: airport.lon)
        }
        func nearest(_ point: CLLocationCoordinate2D, withinKm radius: Double) -> AirportRecord? {
            all.filter { km(point, $0) <= radius }.min { km(point, $0) < km(point, $1) }
        }
        func ground(_ point: CLLocationCoordinate2D) -> AirportGround {
            if point.latitude == Self.islandTown.latitude, point.longitude == Self.islandTown.longitude {
                return AirportGround(island: island, area: Self.townArea)
            }
            guard let airport = all.first(where: { km(point, $0) < 0.5 }) else { return AirportGround() }
            return AirportGround(island: airport.islid, area: areas[airport.code])
        }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let destination = far ? Self.abroad : Self.domestic
        let departure = Stay(startTime: Self.at(0), endTime: Self.at(5),
                             centroidLatitude: Self.islandTown.latitude, centroidLongitude: Self.islandTown.longitude,
                             h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        departure.category = .destination
        departure.islandName = storedIsland
        departure.isoCountryCode = "QA"
        let arrival = Stay(startTime: Self.at(24), endTime: Self.at(30),
                           centroidLatitude: destination.lat, centroidLongitude: destination.lon,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        arrival.category = .transit
        arrival.isAirport = true
        arrival.isoCountryCode = destination.iso
        arrival.transitFromPreviousRaw = TransitMode.flight.rawValue
        var stays = [departure, arrival]
        if let visited {
            let before = Stay(startTime: Self.at(-48), endTime: Self.at(-46),
                              centroidLatitude: visited.lat, centroidLongitude: visited.lon,
                              h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
            before.category = .transit
            before.isAirport = true
            before.isoCountryCode = "QA"
            stays.insert(before, at: 0)
        }
        for stay in stays { context.insert(stay) }
        try context.save()
        let flights = CollectionsAggregator.aggregate(
            stays: stays,
            nearestAirport: { nearest($0, withinKm: 3) },
            servingAirport: { nearest($0, withinKm: FlightJudge.servingRadiusKm) },
            accessAirports: { point in all.filter { km(point, $0) <= AccessAirport.majorReachKm } },
            airportGround: ground,
            dismissedCandidates: []).flights
        let flight = try #require(flights.first)
        #expect(flight.arrivalCode == destination.code)
        return flight.departureCode
    }

    @Test("limitation: a bridged island outside any commuting area ranks on its own island")
    func bridgedIslandOutsideCommutingAreaRanksOnItsOwnIsland() throws {
        // A known limitation, not a goal. Without road data a bridge and a
        // ferry look alike (the simplified outlines cannot tell a 500 m
        // bridged strait from a 1 km ferry one), and only a shared commuting
        // area shows a road. So a town on a bridged island with its own
        // airport and no commuting area (Svendborg's Tåsinge field, a bridge
        // away, loses to Odense 49 km off) ranks only its island's airports.
        // Here: a regional field 11 km away across the water, a major
        // airport 44 km away across the water, and a small field 56 km away
        // on the town's own island, with no commuting area at all.
        let airports = [
            Self.fixture("QQR", lat: 10.1, size: "M", island: nil),
            Self.fixture("QQM", lat: 10.4, size: "L", island: nil),
            Self.fixture("QQK", lat: 9.5, size: "S", island: Self.twinisle),
        ]
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports) == "QQK")
        #expect(try islandDepartureCode(island: Self.twinisle, far: false, airports: airports) == "QQK")
        // On the mainland every airport ranks.
        #expect(try islandDepartureCode(island: nil, far: true, airports: airports) == "QQM")
        #expect(try islandDepartureCode(island: nil, far: false, airports: airports) == "QQR")
    }

    @Test("an end's island comes from its coordinates: a missing, stale or matching stored name changes nothing")
    func storedIslandNameIsNeverRead() throws {
        let airports = [
            Self.fixture("QQS", lat: 10.05, size: "S", island: Self.twinisle),
            Self.fixture("QQM", lat: 9.8, size: "L", island: nil),
        ]
        for stored in [nil, "Isle \(Self.twinisle)", "Isle \(Self.otherisle)", ""] as [String?] {
            #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports,
                                            storedIsland: stored) == "QQS")
            #expect(try islandDepartureCode(island: nil, far: true, airports: airports,
                                            storedIsland: stored) == "QQM")
        }
    }

    @Test("an island end beside its own airport keeps the island's airports, ranked as for a near flight")
    func islandKeepsItsOwnAirports() throws {
        // A small field 6 km away and a major airport 33 km away on the
        // town's island, and a major airport 22 km away across the water.
        let airports = [
            Self.fixture("QQS", lat: 10.05, size: "S", island: Self.twinisle),
            Self.fixture("QQI", lat: 10.3, size: "L", island: Self.twinisle),
            Self.fixture("QQM", lat: 9.8, size: "L", island: nil),
        ]
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports) == "QQI")
        #expect(try islandDepartureCode(island: Self.twinisle, far: false, airports: airports) == "QQI")
        // The same place on the mainland ranks every airport.
        #expect(try islandDepartureCode(island: nil, far: true, airports: airports) == "QQM")
        // So does an island with no airport (a ferry island).
        #expect(try islandDepartureCode(island: Self.otherisle, far: true, airports: airports) == "QQM")
    }

    @Test("an island end also ranks the airports across the water in its commuting zone, visited or not")
    func islandReachesItsCommutingZone() throws {
        let across = Self.fixture("QQM", lat: 9.8, size: "L", island: nil)
        let airports = [Self.fixture("QQS", lat: 10.05, size: "S", island: Self.twinisle),
                        Self.fixture("QQI", lat: 10.3, size: "L", island: Self.twinisle), across]
        // In the town's commuting area, or its part over the border: a
        // drive, and the nearer major airport wins as on a mainland.
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports,
                                        areas: ["QQM": Self.townArea]) == "QQM")
        #expect(try islandDepartureCode(island: Self.twinisle, far: false, airports: airports,
                                        areas: ["QQM": Self.borderArea]) == "QQM")
        // Another commuting area: a ferry away.
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports,
                                        areas: ["QQM": Self.otherArea]) == "QQI")
        let reach = AccessAirport.reach(
            latitude: Self.islandTown.latitude, longitude: Self.islandTown.longitude,
            nearest: airports[0], candidates: airports,
            ground: { AirportGround(island: Self.twinisle, area: Self.townArea) },
            area: { $0.code == "QQM" ? Self.townArea : nil })
        // The judge times through the nearest of them.
        #expect(reach.serving?.code == "QQS")
        #expect(Set(reach.candidates.map(\.code)) == ["QQS", "QQI", "QQM"])
    }

    @Test("an island end takes the user's airport on its island, or across the water only within its commuting zone")
    func islandKeepsItsOwnVisitedAirports() throws {
        let small = Self.fixture("QQS", lat: 10.05, size: "S", island: Self.twinisle)
        let across = Self.fixture("QQM", lat: 9.8, size: "L", island: nil)
        let airports = [small, Self.fixture("QQI", lat: 10.3, size: "L", island: Self.twinisle), across]
        // Across the water with no commuting area in common: a ferry away.
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports, visited: across) == "QQI")
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports, visited: across,
                                        areas: ["QQM": Self.otherArea]) == "QQI")
        // In the town's commuting area, or its part over the border: a drive.
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports, visited: across,
                                        areas: ["QQM": Self.townArea]) == "QQM")
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports, visited: across,
                                        areas: ["QQM": Self.borderArea]) == "QQM")
        #expect(try islandDepartureCode(island: Self.twinisle, far: true, airports: airports, visited: small) == "QQS")
        // On the mainland the airport the user has been at wins.
        #expect(try islandDepartureCode(island: nil, far: true, airports: airports, visited: small) == "QQS")
    }

    @Test("commuting areas: the same one, or the same-named part over a border that touches it")
    func commutingAreas() {
        #expect(Self.townArea.commutes(with: Self.townArea))
        #expect(Self.townArea.commutes(with: Self.borderArea))
        #expect(Self.borderArea.commutes(with: Self.townArea))
        // Another name, even touching.
        #expect(!Self.townArea.commutes(with: Self.otherArea))
        // The same name in the same country is another metro.
        let namesake = CommutingArea(id: 4, name: "Twinville", iso: "QA", minLatitude: 9.5, maxLatitude: 9.7,
                                     minLongitude: 19.8, maxLongitude: 20.2)
        #expect(!Self.townArea.commutes(with: namesake))
        // Over a border but apart.
        let distant = CommutingArea(id: 5, name: "Twinville", iso: "QB", minLatitude: 5, maxLatitude: 6,
                                    minLongitude: 19.8, maxLongitude: 20.2)
        #expect(!Self.townArea.commutes(with: distant))
    }

    @Test("the ground is read only when an airport within reach stands on an island")
    func groundReadOnlyNearIslandAirports() {
        let mainland = [Self.fixture("QQR", lat: 10.1, size: "M", island: nil)]
        var reads = 0
        let plain = AccessAirport.reach(latitude: 10, longitude: 20, nearest: mainland.first, candidates: mainland,
                                        ground: { reads += 1; return AirportGround(island: Self.twinisle) },
                                        area: { _ in nil })
        #expect(reads == 0)
        #expect(plain.serving?.code == "QQR" && plain.island == nil)
        let island = [Self.fixture("QQK", lat: 9.5, size: "S", island: Self.twinisle)] + mainland
        let restricted = AccessAirport.reach(latitude: 10, longitude: 20, nearest: mainland.first,
                                             candidates: island,
                                             ground: { reads += 1; return AirportGround(island: Self.twinisle) },
                                             area: { _ in nil })
        #expect(reads == 1)
        // The judge's serving airport is the island's, the nearer mainland
        // field notwithstanding.
        #expect(restricted.serving?.code == "QQK" && restricted.island == Self.twinisle)
        #expect(restricted.candidates.map(\.code) == ["QQK"])
        // No airport within the serving radius on the island: none serves.
        let beyond = [Self.fixture("QQB", lat: 9.0, size: "L", island: Self.twinisle)] + mainland
        let unserved = AccessAirport.reach(latitude: 10, longitude: 20, nearest: mainland.first, candidates: beyond,
                                           ground: { AirportGround(island: Self.twinisle) },
                                           area: { _ in nil })
        #expect(unserved.serving == nil && unserved.candidates.isEmpty)
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
