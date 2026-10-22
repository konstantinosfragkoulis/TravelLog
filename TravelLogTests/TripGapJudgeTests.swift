//
//  TripGapJudgeTests.swift
//  TravelLogTests
//
//  One test per rule of `TripGapJudge`, on bare coordinates north of a home
//  at (40, 10): a degree of latitude is about 111 km.
//

import Foundation
import Testing
@testable import TravelLog

@Suite("Trip gap judge")
struct TripGapJudgeTests {

    private static let home = (lat: 40.0, lon: 10.0)

    private func side(_ lat: Double, _ lon: Double = 10.0, hour: Double) -> TripGapJudge.Side {
        let km = HomeOrbit.greatCircleKm(Self.home.lat, Self.home.lon, lat, lon)
        return TripGapJudge.Side(latitude: lat, longitude: lon, distanceFromHomeKm: km,
                                 time: Date(timeIntervalSinceReferenceDate: hour * 3600))
    }

    private func verdict(_ earlier: TripGapJudge.Side, _ later: TripGapJudge.Side) -> TripGapJudge.Verdict {
        TripGapJudge.verdict(after: earlier, before: later)
    }

    @Test("the same place on both sides is one trip for days without an observation, and two after three weeks")
    func samePlace() {
        let resort = 42.0
        #expect(verdict(side(resort, hour: 0), side(resort, 10.1, hour: 86)) == .sameTrip)
        #expect(verdict(side(resort, hour: 0), side(resort, hour: 21 * 24)) == .separateTrips)
    }

    @Test("moving on after a week without an observation is two trips, however far home is")
    func movedAfterAWeek() {
        #expect(verdict(side(55.0, 20.0, hour: 0), side(52.0, 25.0, hour: 7 * 24)) == .separateTrips)
        #expect(verdict(side(55.0, 20.0, hour: 0), side(52.0, 25.0, hour: 7 * 24 - 1)) == .sameTrip)
    }

    @Test("a gap too short to reach home and leave again is one trip")
    func homeUnreachable() {
        // Home lies on the way, but four hours cannot cover about 450 km twice.
        #expect(verdict(side(42.5, hour: 0), side(38.0, hour: 4)) == .sameTrip)
    }

    @Test("a route that passes home with time to spare is two trips, even overnight")
    func passesHome() {
        // 2.5 degrees north, then 1 degree south: home is on the way.
        #expect(verdict(side(42.5, hour: 0), side(39.0, hour: 12)) == .separateTrips)
    }

    @Test("home far off the route is one trip, however much time there is")
    func homeOffRoute() {
        // Two cities about 150 km apart, both about 1,000 km from home.
        #expect(verdict(side(49.0, hour: 0), side(49.0, 12.0, hour: 40)) == .sameTrip)
    }

    @Test("home near the route: a night's spare time is two trips, less is a question for the user")
    func homeNearRoute() {
        // About 334 km apart, 445 km of travel through home.
        let earlier = side(42.0, hour: 0)
        let later = side(40.0, 12.6, hour: 0)
        let detour = (earlier.distanceFromHomeKm + later.distanceFromHomeKm)
            / HomeOrbit.greatCircleKm(earlier.latitude, earlier.longitude, later.latitude, later.longitude)
        #expect(detour > TripGapJudge.passesHomeDetour && detour <= TripGapJudge.nearRouteDetour)
        let travel = (TripGapJudge.travelTime(km: earlier.distanceFromHomeKm)
                      + TripGapJudge.travelTime(km: later.distanceFromHomeKm)) / 3600
        #expect(verdict(earlier, side(40.0, 12.6, hour: travel + 7)) == .separateTrips)
        #expect(verdict(earlier, side(40.0, 12.6, hour: travel + 3)) == .unsure)
    }
}
