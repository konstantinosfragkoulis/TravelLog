//
//  HomeAndRoutinePlaceTests.swift
//  TravelLogTests
//
//  Covers `Home` (distanceKm/contains/isCurrent, 25 km default radius) and
//  `RoutinePlace` (contains/isCurrent, 500 m default radius). The load-bearing
//  assertion is the unit distinction: Home.radiusKm is KILOMETERS while
//  RoutinePlace.radiusMeters is METERS — a ~4 km point is inside a 25 km Home
//  but outside a 500 m RoutinePlace. Distances go through CLLocation.distance
//  so geo assertions use tolerance bands with real coordinates.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes the `@Model` types (`Home`, `RoutinePlace`)
//  MainActor-isolated.
//

import Testing
import Foundation
import CoreLocation
@testable import TravelLog

@MainActor
struct HomeAndRoutinePlaceTests {

    /// Athens home point.
    static let athens = (lat: 38.0095, lon: 23.6494)
    /// ~4 km from Athens home point, inside 25 km, outside 500 m.
    static let athensNearby = (lat: 37.9757, lon: 23.6719)
    /// ~100 m from Athens home point, inside 500 m.
    static let athensVeryNear = (lat: 38.0104, lon: 23.6494)
    /// Ioánnina, ~300 km from Athens.
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    private func coord(_ pair: (lat: Double, lon: Double)) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pair.lat, longitude: pair.lon)
    }

    private func makeHome(radiusKm: Double = 25) -> Home {
        Home(label: "Athens Home", latitude: Self.athens.lat, longitude: Self.athens.lon, radiusKm: radiusKm)
    }

    private func makeRoutine(radiusMeters: Double = 500) -> RoutinePlace {
        RoutinePlace(label: "Office", latitude: Self.athens.lat, longitude: Self.athens.lon, radiusMeters: radiusMeters)
    }

    // MARK: - Home.distanceKm

    @Test("distanceKm to the home's own coordinate is ~0")
    func homeDistanceKmZeroAtSameCoordinate() {
        let home = makeHome()
        #expect(home.distanceKm(to: coord(Self.athens)) < 0.001)
    }

    @Test("distanceKm Athens→Ioánnina within ~300 km band (meters/1000 conversion sane)")
    func homeDistanceKmMatchesGreatCircleApprox() {
        let home = makeHome()
        let d = home.distanceKm(to: coord(Self.ioannina))
        #expect(d > 290 && d < 320)
    }

    // MARK: - Home.contains

    @Test("contains true for a point ~4 km away inside the 25 km radius")
    func homeContainsTrueInsideRadius() {
        let home = makeHome()
        #expect(home.contains(coord(Self.athensNearby)))
    }

    @Test("contains false for Ioánnina (~300 km) outside the 25 km radius")
    func homeContainsFalseOutsideRadius() {
        let home = makeHome()
        #expect(!home.contains(coord(Self.ioannina)))
    }

    @Test("contains is boundary-inclusive (<= radiusKm): a point just inside returns true")
    func homeContainsBoundaryInclusive() {
        // Tiny radius; the ~4 km nearby point sits just inside a radius set to
        // a hair above the measured distance.
        let home = makeHome(radiusKm: 25)
        let measured = home.distanceKm(to: coord(Self.athensNearby))
        let tight = makeHome(radiusKm: measured + 0.01)
        #expect(tight.contains(coord(Self.athensNearby)))
    }

    @Test("Home default radius is 25 km")
    func homeDefaultRadiusIsTwentyFive() {
        let home = Home(label: "H", latitude: Self.athens.lat, longitude: Self.athens.lon)
        #expect(home.radiusKm == 25)
    }

    // MARK: - Home.isCurrent

    @Test("isCurrent true when endedAt nil; false once endedAt set")
    func homeIsCurrentTrueWhenEndedAtNil() {
        let home = makeHome()
        #expect(home.isCurrent)
        home.endedAt = .now
        #expect(!home.isCurrent)
    }

    // MARK: - RoutinePlace.contains

    @Test("RoutinePlace contains true for a point ~100 m away within 500 m")
    func routinePlaceContainsTrueWithinMeters() {
        let place = makeRoutine()
        #expect(place.contains(coord(Self.athensVeryNear)))
    }

    @Test("RoutinePlace contains false for ~4 km away (500 m is meters, not km)")
    func routinePlaceContainsFalseBeyondMeters() {
        let place = makeRoutine()
        #expect(!place.contains(coord(Self.athensNearby)))
    }

    @Test("RoutinePlace default radius is 500 meters (distinct from Home's km default)")
    func routinePlaceDefaultRadiusIsFiveHundredMeters() {
        let place = RoutinePlace(label: "R", latitude: Self.athens.lat, longitude: Self.athens.lon)
        #expect(place.radiusMeters == 500)
    }

    // MARK: - RoutinePlace.isCurrent

    @Test("isCurrent == isActive && endedAt == nil (both conjuncts exercised)")
    func routinePlaceIsCurrentRequiresActiveAndNotEnded() {
        let place = makeRoutine()
        #expect(place.isCurrent)               // fresh: active + not ended
        place.isActive = false
        #expect(!place.isCurrent)              // inactive
        place.isActive = true
        place.endedAt = .now
        #expect(!place.isCurrent)              // active but ended
    }
}
