//
//  StayClustererPingAppendTests.swift
//  TravelLogTests
//
//  Pins the clusterer's incremental ping-id append to the canonical bytes
//  produced by the former parse-append-rejoin path.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct StayClustererPingAppendTests {

    @Test("stay extension preserves canonical ping-id order and count")
    func extensionAppendsCanonicalPingIDsInOrder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_697_580_800)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        ]

        for (index, id) in ids.enumerated() {
            let ping = LocationPing(
                timestamp: base.addingTimeInterval(Double(index) * 300),
                latitude: 37.9838,
                longitude: 23.7275,
                horizontalAccuracy: 10,
                h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? "",
                source: .liveSLC
            )
            ping.id = id
            ctx.insert(ping)
        }
        try ctx.save()

        let sut = StayClusterer(modelContainer: container)
        _ = await sut.clusterUnprocessedPings()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let stay = try #require(stays.first)
        #expect(stays.count == 1)
        #expect(stay.pingIDsString == ids.map(\.uuidString).joined(separator: ","))
        #expect(stay.pingCount == ids.count)
    }

    @Test("extending an attached stay invalidates canonical and localized titles")
    func extensionInvalidatesTitleDerivatives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: 797_580_800)
        let hex = try #require(H3Service.cellIndex(
            latitude: 37.9838,
            longitude: 23.7275))
        let existingPingID = UUID()
        let stay = Stay(
            startTime: base,
            endTime: base,
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: hex,
            pingCount: 1,
            distanceFromHomeKm: 500,
            pingIDs: [existingPingID])
        stay.category = .destination
        stay.locality = "Athens"
        let trip = Trip(startDate: base)
        trip.aiGeneratedTitle = "Athens Evening"
        let nextPing = LocationPing(
            timestamp: base.addingTimeInterval(300),
            latitude: 37.9838,
            longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: hex,
            source: .liveSLC)
        context.insert(stay)
        context.insert(trip)
        context.insert(nextPing)
        stay.trip = trip
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athener Abend",
            sourceTitle: "Athens Evening",
            trip: trip))
        try context.save()

        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()

        let fresh = ModelContext(container)
        let reloaded = try #require(try fresh.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedTitle == nil)
        #expect(try fresh.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("stay extension invalidates only its physical parent when trip UUIDs collide")
    func extensionTargetsPhysicalTripTwin() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: 797_580_800)
        let hex = try #require(H3Service.cellIndex(
            latitude: 37.9838,
            longitude: 23.7275))
        let sharedTripID = UUID()

        func seedTrip(offset: TimeInterval, title: String) -> Trip {
            let start = base.addingTimeInterval(offset)
            let trip = Trip(startDate: start)
            trip.id = sharedTripID
            trip.aiGeneratedTitle = title
            let stay = Stay(
                startTime: start,
                endTime: start,
                centroidLatitude: 37.9838,
                centroidLongitude: 23.7275,
                h3IndexRes6: hex,
                pingCount: 1,
                distanceFromHomeKm: 500,
                pingIDs: [UUID()])
            stay.category = .destination
            stay.locality = "Athens"
            context.insert(trip)
            context.insert(stay)
            stay.trip = trip
            context.insert(TripTitleVariant(
                languageTag: "de",
                title: "\(title) DE",
                sourceTitle: title,
                trip: trip))
            return trip
        }

        _ = seedTrip(offset: 0, title: "Older Twin")
        _ = seedTrip(offset: 3_600, title: "Newer Twin")
        context.insert(LocationPing(
            timestamp: base.addingTimeInterval(3_900),
            latitude: 37.9838,
            longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: hex,
            source: .liveSLC))
        try context.save()

        let clusterer = StayClusterer(modelContainer: container)
        _ = await clusterer.clusterUnprocessedPings()

        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]))
        #expect(trips.count == 2)
        #expect(trips[0].aiGeneratedTitle == "Older Twin")
        #expect((trips[0].localizedTitles ?? []).count == 1)
        #expect(trips[1].aiGeneratedTitle == nil)
        #expect((trips[1].localizedTitles ?? []).isEmpty)
    }
}
