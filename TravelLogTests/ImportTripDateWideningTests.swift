//
//  ImportTripDateWideningTests.swift
//  TravelLogTests
//
//  Import pre-attach grows an existing stay's bounds. No later pass revisits
//  a completed trip whose membership did not change (assembly returns when no
//  stay is unassigned, and background finalization skips the classifier), so
//  the import batch itself must widen the parent trip to cover its members,
//  in the same save as the stay change. Widen only: a wider homecoming or
//  merged end stays, and an open trip keeps its nil end.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import TravelLog

@MainActor
@Suite("Import attachment widens parent trip dates", .serialized)
struct ImportTripDateWideningTests {

    nonisolated private static let athens = (lat: 37.9838, lon: 23.7275)
    private static let base = Date(timeIntervalSince1970: 1_616_934_400)
    private static let hour: TimeInterval = 3600

    private func at(_ hours: Double) -> Date {
        Self.base.addingTimeInterval(hours * Self.hour)
    }

    @discardableResult
    private func insertStay(
        _ context: ModelContext, start: Date, end: Date,
        latitude: Double = athens.lat, trip: Trip, order: Int
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: latitude, centroidLongitude: Self.athens.lon,
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: Self.athens.lon)!,
            pingCount: 1, distanceFromHomeKm: 500, pingIDs: [UUID()])
        stay.category = .destination
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = order
        return stay
    }

    private func completedTrip(_ context: ModelContext, start: Date, end: Date?) -> Trip {
        let trip = Trip(startDate: start)
        trip.isComplete = true
        trip.endDate = end
        context.insert(trip)
        return trip
    }

    private func fetchTrip(_ id: UUID, in container: ModelContainer) throws -> Trip {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func importPings(_ hours: [Double], into container: ModelContainer) async throws {
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings(hours.map {
            ImportedPingCandidate(
                timestamp: at($0), latitude: Self.athens.lat, longitude: Self.athens.lon,
                horizontalAccuracy: 10)
        })
        try await recorder.saveImportBatch()
    }

    @Test("an earlier absorbed ping widens a completed trip's start, user-edited or not", arguments: [false, true])
    func earlierAbsorbedPingWidensCompletedTripStart(userEdited: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(0), end: at(1))
        trip.userEdited = userEdited
        insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        try context.save()

        try await importPings([-2], into: container)

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(-2))
        #expect(saved.endDate == at(1))
    }

    @Test("chained later pings in one batch widen a completed trip's end to the last absorbed ping")
    func laterAbsorbedPingsWidenCompletedTripEnd() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(0), end: at(1))
        let stay = insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        let stayID = stay.id
        try context.save()

        try await importPings([2, 5, 8], into: container)

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(0))
        #expect(saved.endDate == at(8))
        let grown = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first)
        #expect(grown.endTime == at(8))
    }

    @Test("a wider homecoming end already covering the extension is kept")
    func widerEndDateIsKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(0), end: at(10))
        insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        try context.save()

        try await importPings([3], into: container)

        #expect(try fetchTrip(trip.id, in: container).endDate == at(10))
    }

    @Test("an open trip widens its start and keeps a nil end; a completed trip with no end keeps it nil",
          arguments: [false, true])
    func nilEndStaysNil(isComplete: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: at(0))
        trip.isComplete = isComplete
        context.insert(trip)
        insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        try context.save()

        try await importPings([-2, 3], into: container)

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(-2))
        #expect(saved.endDate == nil)
    }

    @Test("the widened end follows the latest member end, not the member order")
    func widenedEndIgnoresMemberOrder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(-3), end: at(1))
        // About 11 km north, so the imported ping cannot attach to it.
        insertStay(context, start: at(-3), end: at(-2), latitude: Self.athens.lat + 0.1, trip: trip, order: 1)
        insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        try context.save()

        try await importPings([3], into: container)

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(-3))
        #expect(saved.endDate == at(3))
    }

    @Test("only the physical trip row holding the extended stay widens when a UUID twin exists")
    func onlyTheHostsPhysicalTripWidens() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let host = completedTrip(context, start: at(0), end: at(1))
        let twin = completedTrip(context, start: at(0), end: at(1))
        twin.id = host.id
        let hostStay = insertStay(context, start: at(0), end: at(1), trip: host, order: 0)
        // About 11 km north, so the imported ping cannot attach to it.
        insertStay(context, start: at(0), end: at(1), latitude: Self.athens.lat + 0.1, trip: twin, order: 0)
        let hostStayID = hostStay.id
        let tripID = host.id
        try context.save()

        try await importPings([3], into: container)

        let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID }))
        #expect(rows.count == 2)
        for row in rows {
            let holdsHost = (row.stays ?? []).contains { $0.id == hostStayID }
            #expect(row.endDate == (holdsHost ? at(3) : at(1)))
        }
    }

    @Test("a failed import batch save rolls back the trip dates with the stay extension")
    func failedBatchSaveRollsBackTripDates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(0), end: at(1))
        let stay = insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        let stayID = stay.id
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: at(-2), latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10)
        _ = try await recorder.recordImportedPing(
            timestamp: at(3), latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10)
        await recorder.setFailNextImportBatchSaveForTesting(true)
        await #expect(throws: (any Error).self) { try await recorder.saveImportBatch() }

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(0))
        #expect(saved.endDate == at(1))
        let unchanged = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first)
        #expect(unchanged.startTime == at(0))
        #expect(unchanged.endTime == at(1))
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).isEmpty)
    }

    @Test("a background photo import whose photos all attach widens the completed trip without a classifier pass")
    func backgroundPhotoImportWidensCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = completedTrip(context, start: at(0), end: at(1))
        insertStay(context, start: at(0), end: at(1), trip: trip, order: 0)
        try context.save()

        let library = [-2.0, 2, 4].map { hours in
            PhotoImportService.AssetForTesting(
                creationDate: at(hours),
                candidate: ImportedPingCandidate(
                    timestamp: at(hours), latitude: Self.athens.lat, longitude: Self.athens.lon,
                    horizontalAccuracy: 10, altitude: nil, verticalAccuracy: nil))
        }
        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(
            originDeviceID: UIDevice.current.identifierForVendor?.uuidString ?? "")
        // isForeground defaults to false: finalization skips TripClassifier.
        let pipeline = PhotoImportService.PipelineForTesting(
            recorder: PingRecorder(modelContainer: container),
            clusterer: StayClusterer(modelContainer: container))
        let status = await PhotoImportService.$readAccessForTesting.withValue(true) {
            await PhotoImportService.$libraryForTesting.withValue(library) {
                await PhotoImportService.$pipelineForTesting.withValue(pipeline) {
                    await Task { await service.runImportSession(progress: nil) }.value
                }
            }
        }
        #expect(status == .completed)

        let saved = try fetchTrip(trip.id, in: container)
        #expect(saved.startDate == at(-2))
        #expect(saved.endDate == at(4))
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 1)
    }
}
