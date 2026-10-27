//
//  AirportDetectorTests.swift
//  TravelLogTests
//
//  Positive-path coverage for `AirportDetector` (Services/Geography/AirportDetector.swift).
//
//  The public query members under test — `isNearAirport(_:radiusMeters:)`,
//  `nearestAirport(_:radiusMeters:)` and `airportCount` — are all
//  `nonisolated` internal on a `@unchecked Sendable` final class accessed via
//  the `nonisolated static let shared` singleton. They lazily load
//  `Resources/airports.json` from `Bundle.main`. Because the TEST target is a
//  host-application bundle and `airports.json` is a member resource, the bundle
//  loads exactly as it does in the shipping app.
//
//  All assertions are grounded against the real, shipped JSON (5,278 entries as
//  of this writing). Coordinates were verified against the dataset using the
//  production equirectangular distance formula, so the radius gates below are
//  exact, not approximate. We still keep a `try #require` precondition on the
//  airport count so that, were the resource ever to fail to load (count == 0),
//  the proximity assertions are skipped with a clear failure on the precondition
//  rather than a misleading "isNearAirport == false" cascade.
//
//  Not @MainActor: no `@Model` object is constructed; `AirportDetector` is a
//  plain Sendable class with nonisolated members.
//

import Testing
import Foundation
import CoreLocation
@testable import TravelLog

struct AirportDetectorTests {

    // MARK: - Fixtures (verified against Resources/airports.json)

    /// Athens International "Eleftherios Venizelos" (ATH) — exact dataset coord.
    nonisolated static let ath = CLLocationCoordinate2D(latitude: 37.9364, longitude: 23.9445)

    /// London Heathrow (LHR) — ~400 m from the dataset's LHR record.
    nonisolated static let lhr = CLLocationCoordinate2D(latitude: 51.4700, longitude: -0.4543)

    /// A point in the open South Pacific — nearest airport is ~980 km away,
    /// well outside any plausible proximity radius.
    nonisolated static let midOcean = CLLocationCoordinate2D(latitude: 0, longitude: -140)

    /// Exactly ~5 km due north of the ATH record (5000 m / 111_320 m-per-degree
    /// of latitude). No airport lies within 3 km of this point; only ATH lies
    /// within 10 km. This isolates the `radiusMeters` gate.
    nonisolated static let fiveKmFromAth = CLLocationCoordinate2D(
        latitude: 37.9364 + 5000.0 / 111_320.0,
        longitude: 23.9445
    )

    /// The singleton under test.
    private var detector: AirportDetector { AirportDetector.shared }

    /// Precondition: the bundled database loaded and is the curated ~5K slice.
    /// Returns the count so callers can both assert it and trust later queries.
    private func requireLoadedDatabase() throws -> Int {
        let count = detector.airportCount
        // If airports.json failed to load, `count` is 0 and this requirement
        // fails loudly here instead of producing confusing proximity failures.
        try #require(count > 5000,
                     "airports.json must be a bundle resource of the test host (~5K entries); got \(count)")
        return count
    }

    @Test("airportCount is stable across repeated calls (idempotent lazy load)")
    func airportCountIsStable() throws {
        let first = try requireLoadedDatabase()
        let second = detector.airportCount
        #expect(first == second)
    }

    // MARK: - isNearAirport — positive path

    @Test("isNearAirport is true at the ATH coordinate (default 3 km radius)")
    func nearAthIsTrue() throws {
        _ = try requireLoadedDatabase()
        #expect(detector.isNearAirport(Self.ath))
    }

    @Test("isNearAirport is true at the LHR coordinate (default 3 km radius)")
    func nearLhrIsTrue() throws {
        _ = try requireLoadedDatabase()
        #expect(detector.isNearAirport(Self.lhr))
    }

    // MARK: - isNearAirport — negative path

    @Test("isNearAirport is false mid-ocean, even at a generous 100 km radius")
    func midOceanIsFalse() throws {
        _ = try requireLoadedDatabase()
        #expect(detector.isNearAirport(Self.midOcean) == false)
        #expect(detector.isNearAirport(Self.midOcean, radiusMeters: 100_000) == false)
    }

    // MARK: - radiusMeters gate

    @Test("a point ~5 km from ATH is NOT near at the default ring (3 km for ATH)")
    func fiveKmPointFalseAtDefaultRadius() throws {
        _ = try requireLoadedDatabase()
        #expect(detector.isNearAirport(Self.fiveKmFromAth) == false)
    }

    @Test("the same ~5 km point IS near once the radius widens to 10000 m")
    func fiveKmPointTrueAt10000m() throws {
        _ = try requireLoadedDatabase()
        #expect(detector.isNearAirport(Self.fiveKmFromAth, radiusMeters: 10_000))
    }

    // MARK: - Each airport's own ring

    @Test("a missing ring reads as the old 3 km; a stored one is capped there")
    @MainActor
    func ringMetersDefaults() throws {
        let decode = { (json: String) in
            try JSONDecoder().decode(AirportRecord.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"code":"AAA","lat":1,"lon":2}"#).ringMeters == 3000)
        #expect(try decode(#"{"code":"AAA","lat":1,"lon":2,"ring":1600}"#).ringMeters == 1600)
        #expect(try decode(#"{"code":"AAA","lat":1,"lon":2,"ring":9000}"#).ringMeters == 3000)
    }

    @Test("a small field's ring stops short of the town 2 km off; a big airport's still reaches 2.5 km")
    @MainActor
    func ringFollowsTheRunways() throws {
        _ = try requireLoadedDatabase()
        // A short-runway field with no other airport for 6 km, so only its
        // own ring decides.
        let field = try #require(detector.allAirports.first { airport in
            airport.ringMeters <= 1600 && detector.airports(
                near: CLLocationCoordinate2D(latitude: airport.lat, longitude: airport.lon),
                radiusMeters: 6000).count == 1
        })
        let point = CLLocationCoordinate2D(latitude: field.lat, longitude: field.lon)
        let twoKmNorth = CLLocationCoordinate2D(latitude: field.lat + 2000.0 / 111_320.0, longitude: field.lon)
        #expect(detector.isNearAirport(point))
        #expect(detector.nearestAirport(point)?.code == field.code)
        #expect(!detector.isNearAirport(twoKmNorth))
        #expect(detector.nearestAirport(twoKmNorth) == nil)
        // An explicit radius still overrides the ring.
        #expect(detector.isNearAirport(twoKmNorth, radiusMeters: 3000))

        let ath = try #require(detector.airport(code: "ATH"))
        #expect(ath.ringMeters == 3000)
        let athNorth = CLLocationCoordinate2D(latitude: ath.lat + 2500.0 / 111_320.0, longitude: ath.lon)
        #expect(detector.nearestAirport(athNorth)?.code == "ATH")
    }
}
