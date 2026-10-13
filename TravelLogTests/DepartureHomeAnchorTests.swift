//
//  DepartureHomeAnchorTests.swift
//  TravelLogTests
//
//  A trip's distance from home is anchored to the home the trip LEFT
//  FROM and never changes afterwards. Pins the pure
//  anchor pick (`TripClassifier.departureHomeAnchor`) and the in-situ
//  re-stamp assembly performs on every member stay.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct DepartureHomeAnchorTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let athens = (lat: 38.0, lon: 23.8)
    private static let london = (lat: 51.5, lon: -0.12)
    private static let amsterdam = (lat: 52.37, lon: 4.9)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 259) * Self.day)
    }

    private func km(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon)) / 1000
    }

    private func ring(
        _ place: (lat: Double, lon: Double), startDay: Double, endDay: Double? = nil
    ) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: place.lat, longitude: place.lon, radiusKm: 25,
            startedAt: date(day: startDay), endedAt: endDay.map { date(day: $0) })
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, day: Double, hours: Double,
        at place: (lat: Double, lon: Double), category: StayCategory, hex: String
    ) -> Stay {
        let start = date(day: day)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: hex, pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    private func makeHome(in ctx: ModelContext, at place: (lat: Double, lon: Double), startDay: Double) {
        ctx.insert(Home(label: "Home", latitude: place.lat, longitude: place.lon,
                        radiusKm: 25, startedAt: date(day: startDay)))
    }

    // MARK: - Pure anchor pick

    @Test("the anchor is the ring containing the last home stay before the trip, not the nearest home")
    func anchorIsTheDepartureRing() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        let departure = makeStay(in: ctx, day: 0, hours: 10, at: Self.athens, category: .home, hex: "H")
        makeStay(in: ctx, day: 5, hours: 10, at: Self.london, category: .home, hex: "L") // after the trip
        let anchor = TripClassifier.departureHomeAnchor(
            tripStart: date(day: 1), homeStays: [departure],
            homeRings: [ring(Self.athens, startDay: -30), ring(Self.london, startDay: -30)])
        #expect(anchor?.latitude == Self.athens.lat)
        #expect(anchor?.longitude == Self.athens.lon)
    }

    @Test("no preceding home stay, or a stay no ring claims, yields no anchor")
    func anchorAbsent() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        #expect(TripClassifier.departureHomeAnchor(
            tripStart: date(day: 1), homeStays: [], homeRings: [ring(Self.athens, startDay: -30)]) == nil)
        let stray = makeStay(in: ctx, day: 0, hours: 10, at: Self.amsterdam, category: .home, hex: "X")
        #expect(TripClassifier.departureHomeAnchor(
            tripStart: date(day: 1), homeStays: [stray], homeRings: [ring(Self.athens, startDay: -30)]) == nil)
    }

    @Test("a ring is consulted only inside its active window")
    func anchorRespectsHomeWindows() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        let departure = makeStay(in: ctx, day: 0, hours: 10, at: Self.athens, category: .home, hex: "H")
        // Athens ended before the stay; the stay predates London's window.
        #expect(TripClassifier.departureHomeAnchor(
            tripStart: date(day: 1), homeStays: [departure],
            homeRings: [ring(Self.athens, startDay: -30, endDay: -1), ring(Self.london, startDay: 2)]) == nil)
        // An ended ring still anchors a stay inside its window.
        let anchor = TripClassifier.departureHomeAnchor(
            tripStart: date(day: 1), homeStays: [departure],
            homeRings: [ring(Self.athens, startDay: -30, endDay: 3), ring(Self.london, startDay: 2)])
        #expect(anchor?.latitude == Self.athens.lat)
    }

    // MARK: - In situ

    @Test("assembly stamps every member from the departure home even when another home is nearer")
    func assemblyStampsFromDepartureHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, at: Self.athens, startDay: -30)
        makeHome(in: ctx, at: Self.london, startDay: -30)
        makeStay(in: ctx, day: 0, hours: 10, at: Self.athens, category: .home, hex: "H")
        let outbound = makeStay(in: ctx, day: 1, hours: 48, at: Self.amsterdam, category: .destination, hex: "A")
        // The clusterer's nearest-active-home stamp: London is 360 km away.
        outbound.distanceFromHomeKm = km(Self.london, Self.amsterdam)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.assembleTrips() == 1)

        // assembleTrips leaves the write unsaved in the actor's context; read
        // it there (a fresh context would still see the London value).
        let stamped = try #require(await classifier.stayHomeDistancesForTesting()[outbound.id])
        #expect(abs(stamped - km(Self.athens, Self.amsterdam)) < 1, "measured from Athens, the home the trip left")
        #expect(stamped > 2_000)
    }

    @Test("with no preceding home stay the fallback is the nearest home active at the trip's start")
    func assemblyFallsBackToNearestActiveHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(in: ctx, at: Self.athens, startDay: -30)
        makeHome(in: ctx, at: Self.london, startDay: -30)
        let outbound = makeStay(in: ctx, day: 1, hours: 48, at: Self.amsterdam, category: .destination, hex: "A")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.assembleTrips() == 1)

        let stamped = try #require(await classifier.stayHomeDistancesForTesting()[outbound.id])
        #expect(abs(stamped - km(Self.london, Self.amsterdam)) < 1)
    }
}
