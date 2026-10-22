//
//  HomeShapeTests.swift
//  TravelLogTests
//
//  Runs against the REAL bundled `urban_centre` layer, not a fixture. That is
//  deliberate: the home-shape design's evidence base was measured
//  by a Python probe of the source GeoPackage, and these tests are the proof
//  that the SHIPPED layer plus the app's own parser reach the same answers.
//  If the geocoder is ever rebuilt with a broken projection, these fail.
//

import Foundation
import CoreLocation
import Testing
@testable import TravelLog

struct HomeShapeTests {

    // A synthetic declared-home seed and projection regression points.
    private static let home = (lat: 38.0, lon: 23.8)

    // MARK: - The seed

    @Test("the declared home resolves to the Athens urban centre, 412 km²")
    func resolvesAthens() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        guard case .urbanCentre(_, let name) = shape.seed else {
            Issue.record("expected an urban centre seed")
            return
        }
        #expect(name == "Athens")
        #expect(shape.areaKm2 == 412)
        // D* = sqrt(412/pi). The plan's headline number.
        #expect(abs(shape.areaEquivalentRadiusKm - 11.45) < 0.01)
    }

    @Test("mid-ocean falls back to the 1 km disc")
    func fallsBackAtSea() async {
        // Open Aegean, no urban centre for hundreds of km.
        let shape = await HomeShapeResolver.resolve(latitude: 37.5, longitude: 24.6)
        #expect(shape.seed == .fallbackDisc)
        #expect(shape.areaEquivalentRadiusKm == HomeShape.fallbackRadiusKm)
    }

    // MARK: - Containment: the plan's acceptance table

    @Test("suburbs the Mollweide bug pushed OUT are inside Athens")
    func suburbsAreInside() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        // These substitute suburb points must remain inside the bundled polygon.
        for (name, lat, lon) in [
            ("Phloisvos", 37.9276, 23.6928), ("Agios Dimitrios", 37.9343, 23.7341),
            ("Néa Pentéli", 38.0606, 23.8593), ("Távros", 37.97064, 23.69043),
            ("Zefyri", 38.0661, 23.7134), ("Peristéri", 38.0212, 23.6894),
        ] {
            #expect(shape.contains(latitude: lat, longitude: lon), "\(name) should be inside")
            #expect(shape.distanceKm(toLatitude: lat, longitude: lon) == 0, "\(name) D must be 0")
        }
    }

    @Test("destination points are outside, with expected edge distances")
    func destinationsAreOutside() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        // (place, lat, lon, expected D km), the values used by the distance score.
        for (name, lat, lon, expected) in [
            ("Yimnón", 38.4405, 23.8840, 35.4),
            ("Aegina", 37.7470, 23.4270, 24.1),
            ("Sounio", 37.6500, 24.0270, 28.9),
            ("Syros", 37.4465, 24.9419, 110.6),
        ] {
            #expect(!shape.contains(latitude: lat, longitude: lon), "\(name) should be outside")
            let d = shape.distanceKm(toLatitude: lat, longitude: lon)
            #expect(abs(d - expected) < 1.0, "\(name) D = \(d), expected ~\(expected)")
        }
    }

    @Test("the airport and Diónysos sit just outside the boundary")
    func nearBoundaryCases() async {
        let shape = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        // ATH: outside the built-up city, which is why transit-node neutrality
        // is needed rather than a hole in the shape.
        let airport = shape.distanceKm(toLatitude: 37.9364, longitude: 23.9445)
        #expect(!shape.contains(latitude: 37.9364, longitude: 23.9445))
        #expect(airport > 5 && airport < 12, "ATH D = \(airport)")
        // Diónysos is just outside and keeps the ordinary near-boundary role.
        let dionysos = shape.distanceKm(toLatitude: 38.1003, longitude: 23.8835)
        #expect(dionysos > 0 && dionysos < 4, "Diónysos D = \(dionysos)")
    }

    // MARK: - D* semantics

    @Test("D* is the AREA radius and is floored, never the shape's reach")
    func areaRadiusSemantics() {
        // Reach would be huge for a sprawling shape; area radius is not.
        let sprawling = HomeShape.urbanCentre(
            id: 1, name: "X", areaKm2: 412,
            rings: [[[0, 0, 0, 1, 5, 1, 5, 0, 0, 0]]],
            centreLatitude: 0, centreLongitude: 0)
        #expect(abs(sprawling.areaEquivalentRadiusKm - 11.45) < 0.01)

        // The two 1 km² centres in the source must not out-tighten the fallback.
        let tiny = HomeShape.urbanCentre(
            id: 2, name: "tiny", areaKm2: 1, rings: [],
            centreLatitude: 0, centreLongitude: 0)
        #expect(tiny.areaEquivalentRadiusKm == HomeShape.fallbackRadiusKm)
    }

    // MARK: - Disc geometry

    @Test("the fallback disc measures from its edge, not its centre")
    func discDistance() {
        let disc = HomeShape.fallbackDisc(latitude: 38.0, longitude: 23.8)
        #expect(disc.contains(latitude: 38.0, longitude: 23.8))
        #expect(disc.distanceKm(toLatitude: 38.0, longitude: 23.8) == 0)
        // ~11.1 km due north => ~10.1 km beyond a 1 km disc.
        let d = disc.distanceKm(toLatitude: 38.1, longitude: 23.8)
        #expect(abs(d - 10.1) < 0.3, "got \(d)")
    }

    // MARK: - Antimeridian safety

    @Test("distance is measured across ±180°, not around the world")
    func antimeridianDistance() {
        // A ring just west of the date line; query just east of it.
        let shape = HomeShape.urbanCentre(
            id: 3, name: "dateline", areaKm2: 100,
            rings: [[[179.9, -0.1, 179.9, 0.1, 180.0, 0.1, 180.0, -0.1, 179.9, -0.1]]],
            centreLatitude: 0, centreLongitude: 179.95)
        // -179.95 is 0.05° east of the ring's edge, about 5.6 km, NOT ~40,000 km.
        let d = shape.distanceKm(toLatitude: 0, longitude: -179.95)
        #expect(d < 10, "wrapped distance was \(d) km; longitude wrap is broken")
    }

    // MARK: - Robustness

    @Test("degenerate geometry falls back to a disc and reports a disc seed")
    func degenerateRings() {
        // A corrupt/truncated WKB blob is the realistic way to get here. The
        // invariant: `.urbanCentre` implies usable rings, so `contains` and
        // `distanceKm` can never be reached in a state they weren't written
        // for, and the caller is told it got a disc, not a 50 km² city.
        for rings in [[], [[[Double]()]], [[[0, 0, 0, 1]]]] as [[[[CLLocationDegrees]]]] {
            let shape = HomeShape.urbanCentre(
                id: 4, name: nil, areaKm2: 50, rings: rings,
                centreLatitude: 10, centreLongitude: 10)
            #expect(shape.seed == .fallbackDisc)
            #expect(shape.areaEquivalentRadiusKm == HomeShape.fallbackRadiusKm)
            // Behaves as the disc it says it is.
            #expect(shape.contains(latitude: 10, longitude: 10))
            #expect(shape.distanceKm(toLatitude: 10, longitude: 10) == 0)
        }

        // A real triangle is NOT degenerate and keeps its urban-centre seed.
        let triangle = HomeShape.urbanCentre(
            id: 5, name: nil, areaKm2: 50, rings: [[[0, 0, 0, 1, 1, 0, 0, 0]]],
            centreLatitude: 0, centreLongitude: 0)
        #expect(triangle.seed == .urbanCentre(id: 5, name: nil))
        #expect(triangle.contains(latitude: 0.2, longitude: 0.2))
    }

    @Test("resolution is deterministic")
    func deterministic() async {
        let a = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        let b = await HomeShapeResolver.resolve(latitude: Self.home.lat, longitude: Self.home.lon)
        #expect(a == b)
    }
}
