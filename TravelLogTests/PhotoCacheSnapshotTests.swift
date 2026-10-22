import Testing
import Foundation
import CoreLocation
import Photos
import SwiftData
@testable import TravelLog

private actor PhotoSnapshotComputeCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

@MainActor
@Suite("Photo cache snapshot", .serialized)
struct PhotoCacheSnapshotTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeTrip(in context: ModelContext, twins: Bool = false) throws -> (Trip, [Stay]) {
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(20_000)
        context.insert(trip)
        let id = UUID()
        let stays = (0..<2).map { index in
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3600),
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "86754e64fffffff", pingCount: 3,
                            distanceFromHomeKm: 200, pingIDs: [])
            if twins { stay.id = id }
            stay.category = .destination
            stay.orderInTrip = twins ? 0 : index
            context.insert(stay)
            stay.trip = trip
            return stay
        }
        try context.save()
        return (trip, stays)
    }

    @Test("gallery and count caches refresh omitted fields and cancelling UUID twins",
          arguments: ["order", "duration", "twins"], ["gallery", "count"])
    func changedInputsMissCache(change: String, consumer: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stays) = try makeTrip(in: context, twins: change == "twins")
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.authorizationOverrideForTesting = .authorized
        let counter = PhotoSnapshotComputeCounter()
        service.computeOverrideForTesting = { _ = await counter.increment(); return [] }
        service.countOverrideForTesting = { await counter.increment() }
        if consumer == "gallery" {
            _ = await service.photosForTrip(trip)
            _ = await service.photosForTrip(trip)
        } else {
            await service.prewarmPhotoCounts(for: [trip])
            await service.prewarmPhotoCounts(for: [trip])
        }
        #expect(await counter.count == 1)
        switch change {
        case "order":
            stays[0].orderInTrip = 1
            stays[1].orderInTrip = 0
        case "duration": stays[0].durationMinutes += 1
        default: stays.forEach { $0.centroidLatitude = 2 }
        }
        if consumer == "gallery" { _ = await service.photosForTrip(trip) }
        else { await service.prewarmPhotoCounts(for: [trip]) }
        #expect(await counter.count == 2)
    }

    @Test("the snapshot key follows the grouping sequence, including equal-order ties")
    func groupingSequenceAndTieArePartOfKey() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, stays) = try makeTrip(in: context)
        stays.forEach { $0.orderInTrip = 0 }
        let first = PhotoService.photoSnapshot(for: trip)
        let reversed = TripPhotoSnapshot(startDate: first.startDate, endDate: first.endDate,
                                         stays: Array(first.stays.reversed()))
        let when = start.addingTimeInterval(1800)
        let firstID = PhotoService.nearestStayID(assetLocation: nil, creationDate: when,
                                                sortedContexts: first.photoStays.map(StayGroupContext.init))
        let reversedID = PhotoService.nearestStayID(assetLocation: nil, creationDate: when,
                                                   sortedContexts: reversed.photoStays.map(StayGroupContext.init))
        #expect(firstID != reversedID, "the existing grouping rule uses the first equal-order stay")
        #expect(first.shapeToken != reversed.shapeToken)
        #expect(PhotoService.stayShapeToken(for: trip) == first.shapeToken)
    }

    @Test("identical physical rows retain multiplicity rather than cancelling to empty")
    func duplicateMultiplicityIsPartOfKey() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let (trip, _) = try makeTrip(in: context, twins: true)
        let pair = PhotoService.photoSnapshot(for: trip)
        #expect(pair.stays.count == 2)
        #expect(pair.stays[0] == pair.stays[1])
        let empty = TripPhotoSnapshot(startDate: pair.startDate, endDate: pair.endDate, stays: [])
        let single = TripPhotoSnapshot(startDate: pair.startDate, endDate: pair.endDate,
                                      stays: [pair.stays[0]])
        #expect(pair.shapeToken != empty.shapeToken)
        #expect(pair.shapeToken != single.shapeToken)
    }
}

private final class PresentationPHAsset: PHAsset, @unchecked Sendable {
    private let identifier: String
    private let date: Date?
    init(_ identifier: String, date: Date? = nil) {
        self.identifier = identifier
        self.date = date
        super.init()
    }
    override var localIdentifier: String { identifier }
    override var creationDate: Date? { date }
}

@MainActor
struct TripPhotoPresentationTests {
    @Test("preview and timeline preserve group order and first duplicate bucket; pins sort chronologically")
    func presentationPreservesGalleryRules() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let assets = (0..<25).map { PresentationPHAsset("\($0)", date: start.addingTimeInterval(Double($0))) }
        let noDate = PresentationPHAsset("no-date")
        let groups = [
            StayPhotos(stayID: id, stayLocality: nil, stayStartTime: start, assets: Array(assets.reversed())),
            StayPhotos(stayID: id, stayLocality: nil, stayStartTime: start, assets: [noDate])
        ]
        let presentation = TripPhotoPresentation(groups: groups, pinnedIdentifiers: ["no-date", "0", "24"])
        #expect(presentation.count == 26)
        #expect(presentation.preview.map(\.localIdentifier) == (5..<25).reversed().map { String($0) })
        #expect(presentation.assetsByStay[id]?.map(\.localIdentifier) == assets.reversed().map(\.localIdentifier))
        #expect(presentation.pinned.map(\.localIdentifier) == ["no-date", "0", "24"])

        // Accepted empty loads clear all derived content. A pin publication
        // keeps the groups while replacing both pin ownership and its overlay.
        let unpinned = TripPhotoPresentation(groups: presentation.groups, pinnedIdentifiers: [])
        #expect(unpinned.preview.map(\.localIdentifier) == presentation.preview.map(\.localIdentifier))
        #expect(unpinned.pinned.isEmpty && unpinned.pinnedIdentifiers.isEmpty)
        let empty = TripPhotoPresentation(groups: [], pinnedIdentifiers: presentation.pinnedIdentifiers)
        #expect(empty.count == 0 && empty.preview.isEmpty && empty.pinned.isEmpty && empty.assetsByStay.isEmpty)
    }
}
