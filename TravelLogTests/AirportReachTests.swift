//
//  AirportReachTests.swift
//  TravelLogTests
//
//  Which airports a flight end may fly from (`AccessAirport.reach`) over the
//  bundled data: the island an end stands on, from its own coordinates
//  (`AirportGroundTable`), keeps it on its island's airports when the
//  island has one, and the commuting zone admits the user's airports across
//  the water. Public places and airports on public coordinates; fictional
//  dates.
//

import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import TravelLog

@MainActor
struct AirportReachTests {

    // Public places.
    /// Santa Teresa Gallura, Sardinia: Figari (FSC), across the strait in
    /// Corsica, is nearer than Olbia (OLB).
    private static let santaTeresa = CLLocationCoordinate2D(latitude: 41.2394, longitude: 9.1925)
    /// Its harbour, a waterfront the simplified island outline leaves
    /// offshore: its island comes from the town.
    private static let santaTeresaHarbour = CLLocationCoordinate2D(latitude: 41.2425, longitude: 9.1950)
    /// Kokkari, Samos, 10 km from SMI and 62 km from Izmir across the strait.
    private static let kokkari = CLLocationCoordinate2D(latitude: 37.7764, longitude: 26.8886)
    /// Singapore's city centre (GeoNames), on Singapore Island; Johor
    /// Bahru's airport is over the causeway.
    private static let singapore = CLLocationCoordinate2D(latitude: 1.28967, longitude: 103.85007)
    /// Copenhagen's city centre (GeoNames), on Zealand, whose own airport is
    /// Roskilde (RKE); Kastrup (CPH) stands on Amager, a bridge away in the
    /// same commuting area.
    private static let copenhagen = CLLocationCoordinate2D(latitude: 55.67594, longitude: 12.56553)
    /// Park Slope, Brooklyn, on Long Island; Newark is across the harbour.
    private static let brooklyn = CLLocationCoordinate2D(latitude: 40.6710, longitude: -73.9814)
    /// Downtown Montreal, on the Island of Montreal (YUL); Saint-Hubert (YHU)
    /// is on the south shore.
    private static let montreal = CLLocationCoordinate2D(latitude: 45.5017, longitude: -73.5673)
    /// Tinos: an island with no airport, a ferry from Mykonos and Syros.
    private static let tinos = CLLocationCoordinate2D(latitude: 37.5375, longitude: 25.1636)
    /// Central Athens, on the mainland.
    private static let athens = CLLocationCoordinate2D(latitude: 37.9838, longitude: 23.7275)

    private static func airport(_ code: String) throws -> AirportRecord {
        try #require(AirportDetector.shared.airport(code: code))
    }

    private static func ground(_ point: CLLocationCoordinate2D) -> AirportGround {
        AirportGroundTable.shared.ground(latitude: point.latitude, longitude: point.longitude)
    }

    private static func ground(of code: String) throws -> AirportGround {
        let record = try airport(code)
        return AirportGroundTable.shared.ground(latitude: record.lat, longitude: record.lon)
    }

    /// Hours after a fictional midnight UTC.
    private static func at(_ hours: Double) -> Date {
        let base: TimeInterval = 1_900_000_000
        return Date(timeIntervalSince1970: base - base.truncatingRemainder(dividingBy: 86_400) + hours * 3600)
    }

    private static func stay(at point: CLLocationCoordinate2D, from start: Double, to end: Double) -> Stay {
        Stay(startTime: at(start), endTime: at(end),
             centroidLatitude: point.latitude, centroidLongitude: point.longitude,
             h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
    }

    /// The departure code the Flight Log shows for a flight from `point`
    /// (outside every airport's ring, its stored island `islandName`, in
    /// `iso`) to the airport `destination`, after a day at each of
    /// `visited`, through the production resolvers.
    private func departureCode(
        from point: CLLocationCoordinate2D, iso: String, islandName: String? = nil,
        to destination: String, visited: [String] = []
    ) throws -> String? {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        #expect(AirportDetector.shared.nearestAirport(point) == nil)
        let arrivalAirport = try Self.airport(destination)
        var stays: [Stay] = []
        for (offset, code) in visited.enumerated() {
            let record = try Self.airport(code)
            let before = Self.stay(at: CLLocationCoordinate2D(latitude: record.lat, longitude: record.lon),
                                   from: Double(-96 + 24 * offset), to: Double(-94 + 24 * offset))
            before.category = .transit
            before.isAirport = true
            before.isoCountryCode = record.iso
            stays.append(before)
        }
        let departure = Self.stay(at: point, from: 0, to: 5)
        departure.category = .destination
        departure.islandName = islandName
        departure.isoCountryCode = iso
        let arrival = Self.stay(at: CLLocationCoordinate2D(latitude: arrivalAirport.lat + 0.001,
                                                           longitude: arrivalAirport.lon + 0.001),
                                from: 24, to: 30)
        arrival.category = .transit
        arrival.isAirport = true
        arrival.isoCountryCode = arrivalAirport.iso
        arrival.transitFromPreviousRaw = TransitMode.flight.rawValue
        stays += [departure, arrival]
        for stay in stays { context.insert(stay) }
        try context.save()
        let flights = CollectionsAggregator.aggregate(stays: stays, dismissedCandidates: []).flights
        let flight = try #require(flights.first { $0.arrivalCode == destination })
        return flight.departureCode
    }

    /// The airport the judge times a flight from `point` through.
    private static func judgeServing(_ point: CLLocationCoordinate2D) -> String? {
        FlightJudge.Airports.bundled.serving(point.latitude, point.longitude)?.code
    }

    // MARK: Data

    @Test("the bundled airports carry their island's id, the one an end's ground reads")
    func bundledIslandIDs() throws {
        let olb = try Self.airport("OLB"), fsc = try Self.airport("FSC")
        #expect(olb.islid != nil && fsc.islid != nil && olb.islid != fsc.islid)
        #expect(try Self.airport("JFK").islid == Self.airport("LGA").islid)
        #expect(try Self.airport("EWR").islid == nil)
        #expect(try Self.airport("SIN").islid == Self.ground(Self.singapore).island)
        #expect(Self.ground(Self.santaTeresa).island == olb.islid)
        #expect(try Self.ground(Self.kokkari).island == Self.airport("SMI").islid)
        #expect(try Self.ground(Self.montreal).island == Self.airport("YUL").islid)
        #expect(Self.ground(Self.athens).island == nil)
        #expect(AirportGroundTable.islandAreaCapKm2 == GeocodeResolver.islandAreaCapKm2)
    }

    @Test("a waterfront outside the island outline takes its town's island")
    func harbourTakesTheTownsIsland() throws {
        #expect(try Self.ground(Self.santaTeresaHarbour).island == Self.airport("OLB").islid)
    }

    @Test("commuting areas join Brooklyn to Newark, Copenhagen to Kastrup and Singapore to Johor Bahru")
    func commutingAreas() throws {
        let brooklyn = try #require(Self.ground(Self.brooklyn).area)
        let newark = try #require(try Self.ground(of: "EWR").area)
        #expect(brooklyn.commutes(with: newark))
        let copenhagen = try #require(Self.ground(Self.copenhagen).area)
        #expect(try Self.ground(of: "CPH").area.map(copenhagen.commutes(with:)) == true)
        #expect(try Self.ground(Self.copenhagen).island == Self.airport("RKE").islid)
        let singapore = try #require(Self.ground(Self.singapore).area)
        let johor = try #require(try Self.ground(of: "JHB").area)
        #expect(singapore.id != johor.id && singapore.iso != johor.iso)
        #expect(singapore.commutes(with: johor) && johor.commutes(with: singapore))
        // No commuting area joins the town to Corsica across the strait.
        #expect(Self.ground(Self.santaTeresa).area == nil)
    }

    // MARK: The Flight Log

    @Test("a Sardinian town flies from Sardinia, not from the nearer airport across the strait in Corsica")
    func sardiniaKeepsItsOwnAirports() throws {
        #expect(try departureCode(from: Self.santaTeresa, iso: "IT", islandName: "Sardinia", to: "FRA") == "OLB")
        #expect(try departureCode(from: Self.santaTeresa, iso: "IT", islandName: "Sardinia", to: "FCO") == "OLB")
        #expect(try departureCode(from: Self.santaTeresaHarbour, iso: "IT", to: "FRA") == "OLB")
    }

    @Test("Kokkari flies from Samos whatever island name the stay stored")
    func kokkariFliesFromSamos() throws {
        for stored in [nil, "Samos", "Ikaria"] as [String?] {
            #expect(try departureCode(from: Self.kokkari, iso: "GR", islandName: stored, to: "FRA") == "SMI")
        }
    }

    @Test("Copenhagen flies from Kastrup across the bridge, not from Roskilde on its own island")
    func copenhagenTakesKastrup() throws {
        #expect(try departureCode(from: Self.copenhagen, iso: "DK", to: "FRA") == "CPH")
        #expect(try departureCode(from: Self.copenhagen, iso: "DK", to: "AAL") == "CPH")
        #expect(Self.judgeServing(Self.copenhagen) == "CPH")
    }

    @Test("Singapore flies from Changi, or from Johor Bahru over the causeway once the user has been there")
    func singaporeTakesTheCauseway() throws {
        #expect(try departureCode(from: Self.singapore, iso: "SG", to: "LHR") == "SIN")
        #expect(try departureCode(from: Self.singapore, iso: "SG", to: "LHR", visited: ["JHB"]) == "JHB")
    }

    @Test("Brooklyn ranks Long Island's airports and Newark, in its commuting area, as a mainland end would")
    func brooklynRanksNewarkWithLongIsland() throws {
        // Newark (16 km) and JFK (17 km) are both hubs, with no penalty:
        // the shorter drive wins.
        #expect(try departureCode(from: Self.brooklyn, iso: "US", to: "LAX") == "EWR")
        // The airport the user has been at still comes first.
        #expect(try departureCode(from: Self.brooklyn, iso: "US", to: "LAX", visited: ["JFK"]) == "JFK")
        #expect(try departureCode(from: Self.brooklyn, iso: "US", to: "LAX", visited: ["EWR"]) == "EWR")
    }

    @Test("Montreal flies from YUL on its island by tier, though Saint-Hubert in its commuting area is nearer")
    func montrealKeepsYUL() throws {
        #expect(try departureCode(from: Self.montreal, iso: "CA", to: "CDG") == "YUL")
    }

    @Test("an island with no airport ranks every airport, across the water included")
    func ferryIslandRanksEveryAirport() throws {
        #expect(Self.ground(Self.tinos).island != nil)
        // Abroad: the hub on the mainland, a ferry away.
        #expect(try departureCode(from: Self.tinos, iso: "GR", to: "FRA") == "ATH")
    }

    // MARK: The judge

    @Test("the judge times a flight through an airport the end may fly from, the one the Flight Log shows")
    func judgeTimesThroughTheShownAirport() throws {
        let shown = try departureCode(from: Self.santaTeresa, iso: "IT", islandName: "Sardinia", to: "FCO")
        #expect(Self.judgeServing(Self.santaTeresa) == "OLB")
        #expect(Self.judgeServing(Self.santaTeresa) == shown)
        #expect(Self.judgeServing(Self.santaTeresaHarbour) == "OLB")
        #expect(Self.judgeServing(Self.kokkari) == "SMI")
        // The judge times through the nearest the end may fly from: Montreal's
        // Saint-Hubert, in its commuting area, though the log shows YUL.
        #expect(Self.judgeServing(Self.montreal) == "YHU")
        // On an island with no airport, and on the mainland, the nearest
        // scheduled airport, as before.
        let nearestToTinos = CollectionsAggregator.bundledServingAirport(Self.tinos)?.code
        #expect(nearestToTinos != nil && Self.judgeServing(Self.tinos) == nearestToTinos)
        #expect(Self.judgeServing(Self.athens) == CollectionsAggregator.bundledServingAirport(Self.athens)?.code)
    }
}
