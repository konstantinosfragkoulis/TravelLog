//
//  HomeSeedOnlyPrimeTests.swift
//  TravelLogTests
//
//  The Welcome-Home lookup primes and consults only the measured seed. A
//  learned orbit remains classification membership, never a homecoming point.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct HomeSeedOnlyPrimeTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 38.0, lon: 23.8)
    private static let village = (lat: 38.0, lon: 23.99)
    private let base = Date.now

    private func date(day offset: Double) -> Date {
        base.addingTimeInterval(offset * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    private func makeStay(
        in context: ModelContext,
        startDay: Double,
        durationHours: Double,
        latitude: Double,
        longitude: Double,
        category: StayCategory,
        hex: String
    ) {
        let start = date(day: startDay)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(durationHours * 3600),
            centroidLatitude: latitude,
            centroidLongitude: longitude,
            h3IndexRes6: hex,
            pingCount: 2,
            distanceFromHomeKm: 15,
            pingIDs: [])
        stay.category = category
        context.insert(stay)
    }

    @Test("currentHomeSeedCovers excludes a qualifying orbit disc")
    func currentHomeCoverageIsSeedOnly() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(
            label: "Home",
            latitude: Self.home.lat,
            longitude: Self.home.lon,
            radiusKm: 25,
            startedAt: date(day: -100)))

        for (index, month) in [-60.0, -30, -1].enumerated() {
            makeStay(
                in: context, startDay: month, durationHours: 8,
                latitude: Self.home.lat, longitude: Self.home.lon,
                category: .home, hex: "H\(index)")
            makeStay(
                in: context, startDay: month + 0.4, durationHours: 5,
                latitude: Self.village.lat, longitude: Self.village.lon,
                category: .destination, hex: "V\(index)")
            makeStay(
                in: context, startDay: month + 0.7, durationHours: 10,
                latitude: Self.home.lat, longitude: Self.home.lon,
                category: .home, hex: "G\(index)")
        }
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat,
            longitude: Self.home.lon,
            shape: Self.squareShape())

        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.home.lat, longitude: Self.home.lon))
        #expect(try await classifier.currentHomeSeedCovers(
            latitude: Self.village.lat, longitude: Self.village.lon) == false)

        let learned = try #require(await classifier.learnedPlaces().first)
        let distanceKm = CLLocation(
            latitude: learned.latitude, longitude: learned.longitude)
            .distance(from: CLLocation(
                latitude: Self.village.lat, longitude: Self.village.lon)) / 1000
        #expect(distanceKm <= learned.radiusKm)
        #expect(learned.returnCount == 3)
        #expect(await classifier.currentMembershipCovers(
            latitude: Self.village.lat, longitude: Self.village.lon))
    }
}
