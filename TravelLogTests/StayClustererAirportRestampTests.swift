//
//  StayClustererAirportRestampTests.swift
//  TravelLogTests
//
//  `Stay.isAirport` must track the
//  RUNNING centroid, not the seed ping. The running average can drift up to
//  `distanceThresholdMeters` (3 km) — the same size as the airport ring —
//  so a stay seeded on the fringe that settles at the terminal used to stay
//  `false` forever, and the reverse left permanent false positives.
//
//  Unlike `StayClustererClusteringTests` (which deliberately never asserts
//  on `isAirport`), these tests REQUIRE the bundled airports.json — the
//  same hard dependency `AirportDetectorTests` already pins — and anchor on
//  the real ATH reference point (37.9364, 23.9445). Every fixture's
//  in-ring/out-of-ring status is `#require`d against the live detector
//  before clustering, so a dataset change fails loudly in arrange, not
//  mysteriously in assert.
//
//  Also covers `AppDelegate.backfillAirports` (v3): the launch backfill is
//  now TWO-direction — the flag becomes a pure function of centroid +
//  dataset, healing pre-fix seed stamps both ways.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct StayClustererAirportRestampTests {

    /// ATH reference point (OurAirports), the centre of its 3 km ring.
    private static let athRef = (lat: 37.9364, lon: 23.9445)
    /// Degrees of latitude per km (WGS84 mean) — fixtures move due north/
    /// south so only latitude arithmetic is needed.
    private static let degPerKm = 1.0 / 111.32

    private func makePing(t: Date, lat: Double, lon: Double) -> LocationPing {
        LocationPing(
            timestamp: t,
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "",
            source: .liveSLC
        )
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func requireNear(_ lat: Double, _ lon: Double, _ expected: Bool) throws {
        let near = AirportDetector.shared.isNearAirport(
            CLLocationCoordinate2D(latitude: lat, longitude: lon))
        try #require(near == expected,
                     "fixture (\(lat), \(lon)) expected isNearAirport == \(expected) — dataset changed?")
    }

    @Test("a stay seeded outside the 3 km ring that settles at the terminal ends up isAirport == true")
    func centroidDriftIntoRingFlagsAirport() async throws {
        // Seed 3.4 km north of the ATH reference — outside the ring…
        let seedLat = Self.athRef.lat + 3.4 * Self.degPerKm
        try requireNear(seedLat, Self.athRef.lon, false)
        // …then nine pings 1.0 km north of the reference — inside it, and
        // 2.4 km from the seed so they accrete rather than split.
        let terminalLat = Self.athRef.lat + 1.0 * Self.degPerKm
        try requireNear(terminalLat, Self.athRef.lon, true)

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: seedLat, lon: Self.athRef.lon))
        for i in 1...9 {
            ctx.insert(makePing(t: base.addingTimeInterval(Double(i) * 300),
                                lat: terminalLat, lon: Self.athRef.lon))
        }
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        // Final centroid ≈ ref + 1.24 km — inside the ring; the seed stamp
        // said false, the accretion re-stamp must have corrected it.
        #expect(stays.first?.isAirport == true)
    }

    @Test("a stay seeded inside the ring that settles outside ends up isAirport == false")
    func centroidDriftOutOfRingClearsAirport() async throws {
        // Seed 1.0 km north of the reference — inside the ring…
        let seedLat = Self.athRef.lat + 1.0 * Self.degPerKm
        try requireNear(seedLat, Self.athRef.lon, true)
        // …then nine pings 2.8 km further north (accrete: 2.8 km from the
        // seed). Final centroid ≈ ref + 3.52 km — outside the ring.
        let awayLat = seedLat + 2.8 * Self.degPerKm
        let finalCentroidLat = (seedLat + 9 * awayLat) / 10
        try requireNear(finalCentroidLat, Self.athRef.lon, false)

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makePing(t: base, lat: seedLat, lon: Self.athRef.lon))
        for i in 1...9 {
            ctx.insert(makePing(t: base.addingTimeInterval(Double(i) * 300),
                                lat: awayLat, lon: Self.athRef.lon))
        }
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        #expect(stays.first?.isAirport == false)
    }

    // MARK: - Backfill v3 (two-direction)

    @Test("backfillAirports heals seed-stamp errors in BOTH directions from the centroid truth")
    func backfillIsTwoDirection() async throws {
        try requireNear(Self.athRef.lat, Self.athRef.lon, true)
        // Open Ionian sea — nowhere near any airport.
        let sea = (lat: 36.0, lon: 20.0)
        try requireNear(sea.lat, sea.lon, false)

        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let falseNegative = Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: Self.athRef.lat, centroidLongitude: Self.athRef.lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 20, pingIDs: []
        )
        falseNegative.isAirport = false // wrong: centroid IS at ATH
        let falsePositive = Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: sea.lat, centroidLongitude: sea.lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 300, pingIDs: []
        )
        falsePositive.isAirport = true // wrong: centroid is open sea
        let alreadyCorrect = Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: Self.athRef.lat, centroidLongitude: Self.athRef.lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 20, pingIDs: []
        )
        alreadyCorrect.isAirport = true
        ctx.insert(falseNegative)
        ctx.insert(falsePositive)
        ctx.insert(alreadyCorrect)
        let changedTrip = Trip(startDate: base)
        changedTrip.aiGeneratedTitle = "Old Airport Title"
        ctx.insert(changedTrip)
        falseNegative.trip = changedTrip
        falseNegative.orderInTrip = 0
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Alter Flughafentitel",
            sourceTitle: "Old Airport Title",
            trip: changedTrip))
        let unchangedTrip = Trip(startDate: base)
        unchangedTrip.aiGeneratedTitle = "Stable Airport Title"
        ctx.insert(unchangedTrip)
        alreadyCorrect.trip = unchangedTrip
        alreadyCorrect.orderInTrip = 0
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Stabiler Flughafentitel",
            sourceTitle: "Stable Airport Title",
            trip: unchangedTrip))
        let changedTripID = changedTrip.id
        let unchangedTripID = unchangedTrip.id
        try ctx.save()

        let result = await AppDelegate.backfillAirports(modelContainer: container)
        #expect(result.saved)
        #expect(result.flagged == 2) // both wrong stamps, not the correct one

        let fresh = ModelContext(container)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        for stay in stays {
            let expected = stay.distanceFromHomeKm == 20 // the two ATH rows
            #expect(stay.isAirport == expected)
        }
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        let changed = try #require(trips.first { $0.id == changedTripID })
        #expect(changed.aiGeneratedTitle == nil)
        #expect((changed.localizedTitles ?? []).isEmpty)
        let unchanged = try #require(trips.first { $0.id == unchangedTripID })
        #expect(unchanged.aiGeneratedTitle == "Stable Airport Title")
        #expect((unchanged.localizedTitles ?? []).count == 1)
    }
}
