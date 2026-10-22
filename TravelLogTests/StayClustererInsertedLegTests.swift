//
//  StayClustererInsertedLegTests.swift
//  TravelLogTests
//
//  A stay the clusterer inserts ahead of a stored stay (a photo or timeline
//  import's historical stay, or a Visit with no host) becomes the predecessor
//  that stored stay's inbound leg is measured from. The leg's automatic
//  transit and distance were measured from the old predecessor, so they are
//  cleared in the insertion's save and the nil drain measures them again;
//  the user's Not a Flight correction is kept.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct StayClustererInsertedLegTests {
    private static let base = Date(timeIntervalSince1970: 1_750_000_000)
    private static let lat = 0.0
    private static let lon = -140.0

    private func at(_ hour: Double) -> Date {
        Self.base.addingTimeInterval(hour * 3_600)
    }

    private func longitude(metersEast: Double) -> Double {
        Self.lon + metersEast / 111_320
    }

    @discardableResult
    private func insertStay(_ context: ModelContext, start: Date, end: Date,
                            metersEast: Double,
                            transit: TransitMode? = nil,
                            km: Double? = nil) -> Stay {
        let lon = longitude(metersEast: metersEast)
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.lat, centroidLongitude: lon,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.lat, longitude: lon) ?? "",
            pingCount: 1, distanceFromHomeKm: .greatestFiniteMagnitude,
            pingIDs: [])
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = km
        context.insert(stay)
        return stay
    }

    private func insertPhotoPing(_ context: ModelContext, at timestamp: Date,
                                 metersEast: Double) {
        let lon = longitude(metersEast: metersEast)
        context.insert(LocationPing(
            timestamp: timestamp, latitude: Self.lat, longitude: lon,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.lat, longitude: lon) ?? "",
            source: .photoImport))
    }

    private func stay(_ id: UUID, in container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == id })
    }

    /// Departure A 500 km east, then hotel B whose inbound leg is a committed
    /// automatic flight of 500 km.
    private func departureAndHotel(_ context: ModelContext,
                                   hotelTransit: TransitMode = .flight) -> (a: Stay, b: Stay) {
        let a = insertStay(context, start: at(8), end: at(9), metersEast: 500_000,
                           transit: .unknown)
        let b = insertStay(context, start: at(12), end: at(20), metersEast: 0,
                           transit: hotelTransit, km: 500)
        return (a, b)
    }

    @Test("a historical stay inserted between a departure and the hotel clears the hotel's flight, and the drain measures it from the new stay")
    func historicalInsertionClearsSuccessorLeg() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (_, hotel) = departureAndHotel(context)
        let hotelID = hotel.id
        try context.save()

        // An arrival-side photo 22 km from the hotel, between the two stays.
        insertPhotoPing(context, at: at(10.5), metersEast: 22_000)
        try context.save()
        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1)

        let cleared = try stay(hotelID, in: container)
        #expect(cleared.transitFromPreviousRaw == nil)
        #expect(cleared.distanceFromPreviousKm == nil)

        let drain = await TransitInferer(modelContainer: container)
            .inferTransitForRecentStaysReportingChanges()
        #expect(!drain.failed)
        let measured = try stay(hotelID, in: container)
        #expect(measured.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        let km = try #require(measured.distanceFromPreviousKm)
        #expect(abs(km - 22) < 0.5)
    }

    @Test("the user's Not a Flight correction survives an inserted predecessor")
    func historicalInsertionKeepsNotAFlight() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (_, hotel) = departureAndHotel(context, hotelTransit: .notFlight)
        let hotelID = hotel.id
        try context.save()

        insertPhotoPing(context, at: at(10.5), metersEast: 22_000)
        try context.save()
        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1)

        let kept = try stay(hotelID, in: container)
        #expect(kept.transitFromPreviousRaw == TransitMode.notFlight.rawValue)
        #expect(kept.distanceFromPreviousKm == 500)
    }

    @Test("an inserted stay that does not precede the leg leaves it alone")
    func unrelatedInsertionKeepsLeg() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (departure, hotel) = departureAndHotel(context)
        let departureID = departure.id
        let hotelID = hotel.id
        try context.save()

        // Before the departure: it now precedes A's leg, not B's.
        insertPhotoPing(context, at: at(6), metersEast: 22_000)
        try context.save()
        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1)

        #expect(try stay(departureID, in: container).transitFromPreviousRaw == nil)
        let kept = try stay(hotelID, in: container)
        #expect(kept.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(kept.distanceFromPreviousKm == 500)
    }

    @Test("a Visit-only stay inserted before the hotel clears the hotel's flight")
    func visitInsertionClearsSuccessorLeg() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (_, hotel) = departureAndHotel(context)
        let hotelID = hotel.id
        context.insert(Visit(
            arrivalDate: at(10), departureDate: at(11),
            latitude: Self.lat, longitude: longitude(metersEast: 22_000),
            horizontalAccuracy: 5, receivedAt: at(11)))
        try context.save()

        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1)

        let cleared = try stay(hotelID, in: container)
        #expect(cleared.transitFromPreviousRaw == nil)
        #expect(cleared.distanceFromPreviousKm == nil)
    }
}
