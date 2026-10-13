//
//  PhotoGalleryOutcomeTests.swift
//  TravelLogTests
//
//  Pins the gallery load contract shared by the trip detail, the trip gallery,
//  the Hidden Photos page and the On This Day cover:
//  - an unreadable hidden list is never "nothing hidden": no compute, cache,
//    count or cloud-mapping replacement, and the caller keeps its state;
//  - a row deleted while its gallery computes returns nothing publishable and
//    caches nothing, while a live UUID twin still gets the shared snapshot,
//    and the detail's initial load skips weather once its row is gone;
//  - bounded invalidation retries, or a superseded compute whose creator row
//    died, return an uncached best-effort snapshot and notify observers so
//    they reload under a fresh epoch;
//  - a trip whose visible photos are all hidden keeps its Hidden Photos
//    route, driven through the real hide/unhide writes, and a detail whose
//    first load cannot read the hidden list keeps it too;
//  - Hidden Photos offers only hidden photos this trip's gallery would show,
//    so a split piece never offers another piece's photo;
//  - a cancelled Hidden Photos refresh publishes nothing.
//

import Testing
import Foundation
import CoreLocation
import Photos
import SwiftData
@testable import TravelLog

private actor OutcomeCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

private actor OutcomeLatch {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

@MainActor
private final class InitialLoadRecorder {
    var photoLoads = 0
    var enriched: [UUID] = []
}

@MainActor
@Suite("Trip gallery load outcomes", .serialized)
struct PhotoGalleryOutcomeTests {

    // Read from the @Sendable compute overrides, so not main-actor isolated.
    nonisolated private static let start = Date(timeIntervalSince1970: 1_736_694_400)
    nonisolated private static let stayID = UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000001")!

    private func makeTrip(_ ctx: ModelContext, id: UUID? = nil) throws -> Trip {
        let trip = Trip(startDate: Self.start)
        if let id { trip.id = id }
        trip.endDate = Self.start.addingTimeInterval(48 * 3600)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = Stay(startTime: Self.start, endTime: Self.start.addingTimeInterval(6 * 3600),
                        centroidLatitude: 37.9, centroidLongitude: 23.7,
                        h3IndexRes6: "8a1ed8677ffffff", pingCount: 3,
                        distanceFromHomeKm: 200, pingIDs: [])
        // Twins share the stay identity too, so both rows produce one compute key.
        stay.id = Self.stayID
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        try ctx.save()
        return trip
    }

    private func makeService(_ container: ModelContainer) -> PhotoService {
        let service = PhotoService(forTesting: ())
        service.authorizationOverrideForTesting = .authorized
        service.mutationContainerForTesting = container
        service.mutationGateForTesting = PipelineGate(forTesting: ())
        return service
    }

    nonisolated private static func sentinel(_ label: String) -> [StayPhotos] {
        [StayPhotos(stayID: stayID, stayLocality: label, stayStartTime: start, assets: [])]
    }

    // MARK: - unreadable hidden list

    @Test("an unreadable hidden list defers the gallery; the retry filters with the stored hidden IDs",
          .timeLimit(.minutes(1)))
    func hiddenReadFailureDefersGallery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: trip.id))
        try ctx.save()
        let service = makeService(container)
        let counter = OutcomeCounter()
        service.computeOverrideForTesting = {
            _ = await counter.increment()
            return Self.sentinel("fresh")
        }
        var admittedHidden: [Set<String>] = []
        service.computeHiddenInputForTesting = { admittedHidden.append($0) }
        let generation = service.photoCacheGeneration

        service.failAnnotationReadForTesting = true
        let failed = await service.photosForTrip(trip)
        #expect(failed.groups == nil, "a failed block-list read must not be publishable")
        #expect(await counter.count == 0)
        #expect(!service.cachedGroupsExist(for: trip.id))
        #expect(service.cachedPhotoCount(for: trip.id) == nil)
        #expect(service.photoCacheGeneration == generation)

        service.failAnnotationReadForTesting = false
        let retried = await service.photosForTrip(trip)
        #expect(retried.groups?.first?.stayLocality == "fresh")
        #expect(await counter.count == 1)
        #expect(service.cachedGroupsExist(for: trip.id))
        #expect(admittedHidden == [["H1"]], "the successful retry must filter with the stored hidden identifier")
    }

    @Test("an unreadable hidden list leaves counts unresolved, and keeps a retained count")
    func hiddenReadFailureSkipsCount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let service = makeService(container)
        let counter = OutcomeCounter()
        service.countOverrideForTesting = { await counter.increment() == 1 ? 7 : 9 }

        service.failAnnotationReadForTesting = true
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == nil)
        #expect(await counter.count == 0)

        service.failAnnotationReadForTesting = false
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 7)

        // A global invalidation keeps the count readable until a recount lands;
        // a recount that cannot read the hidden list must not replace it.
        service.invalidateTripCaches()
        service.failAnnotationReadForTesting = true
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 7)
        #expect(await counter.count == 1)

        service.failAnnotationReadForTesting = false
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 9)
    }

    @Test("a cloud-ID refresh that cannot read annotations keeps its mappings and stays pending")
    func refreshFailureKeepsMappings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let service = makeService(container)
        service.seedCloudMappingsForTesting(["cloud-A": "local-A"])
        let epoch = service.cacheInvalidationEpoch
        let token = service.changeToken

        service.failAnnotationReadForTesting = true
        await service.refreshCloudIdentifierCache(modelContainer: container)
        #expect(service.cloudMappingsForTesting == ["cloud-A": "local-A"],
                "dropping the mapping would unhide photos hidden on another device")
        #expect(service.cacheInvalidationEpoch == epoch)
        #expect(service.changeToken == token)
        #expect(service.cloudRefreshPending)

        // No stored annotations: the successful refresh legitimately empties the map.
        service.failAnnotationReadForTesting = false
        await service.refreshCloudIdentifierCache(modelContainer: container)
        #expect(service.cloudMappingsForTesting.isEmpty)
        #expect(!service.cloudRefreshPending)
        #expect(service.cacheInvalidationEpoch != epoch)
    }

    @Test("the Hidden Photos list is unavailable, not empty, when its rows cannot be read")
    func hiddenAssetsReadFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let service = makeService(container)
        #expect(await service.hiddenAssets(for: trip)?.isEmpty == true)
        service.failAnnotationReadForTesting = true
        #expect(await service.hiddenAssets(for: trip) == nil)
    }

    @Test("a cancelled Hidden Photos refresh publishes nothing, so its initial load is not consumed")
    func hiddenRefreshCancelledPublishesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let service = makeService(container)

        let live = await TripHiddenPhotosView.resolveHiddenAssets(
            for: trip, service: service, isCurrent: { true })
        #expect(live?.isEmpty == true, "a current, uncancelled read publishes")

        let superseded = await TripHiddenPhotosView.resolveHiddenAssets(
            for: trip, service: service, isCurrent: { false })
        #expect(superseded == nil)

        let cancelledPublishedNothing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TripHiddenPhotosView.resolveHiddenAssets(
                for: trip, service: service, isCurrent: { true }) == nil
        }
        #expect(await cancelledPublishedNothing.value,
                "a cancelled read must not set hasLoaded, which gates the initial load")

        service.failAnnotationReadForTesting = true
        let failed = await TripHiddenPhotosView.resolveHiddenAssets(
            for: trip, service: service, isCurrent: { true })
        #expect(failed == nil)
    }

    // MARK: - row lifetime across the gallery compute

    @Test("a trip deleted during its gallery compute publishes and caches nothing",
          .timeLimit(.minutes(1)),
          arguments: [(false, false), (false, true), (true, false), (true, true)])
    func deletedDuringCompute(saved: Bool, invalidated: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let id = trip.id
        let service = makeService(container)
        let started = OutcomeLatch(), finish = OutcomeLatch()
        let counter = OutcomeCounter()
        service.computeOverrideForTesting = {
            _ = await counter.increment()
            await started.release()
            await finish.wait()
            return Self.sentinel("stale")
        }
        let work = Task { await service.photosForTrip(trip) }
        await started.wait()
        if invalidated { service.invalidateCache(for: id) }
        ctx.delete(trip)
        if saved { try ctx.save() }
        await finish.release()
        let outcome = await work.value
        #expect(outcome.groups == nil)
        #expect(await counter.count == 1, "a dead row must not recurse into another compute")
        #expect(!service.cachedGroupsExist(for: id))
    }

    @Test("a deleted twin does not deny the live twin the shared snapshot; a cancelled waiter does not cancel it",
          .timeLimit(.minutes(1)),
          arguments: [false, true])
    func joinersFenceTheirOwnRow(invalidated: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = try makeTrip(ctx)
        let twin = try makeTrip(ctx, id: first.id)
        let service = makeService(container)
        let started = OutcomeLatch(), finish = OutcomeLatch()
        let counter = OutcomeCounter()
        service.computeOverrideForTesting = {
            _ = await counter.increment()
            await started.release()
            await finish.wait()
            return Self.sentinel("shared")
        }
        var admissions: [Bool] = []
        service.singleFlightAdmissionForTesting = { admissions.append($0) }

        let creator = Task { await service.photosForTrip(first) }
        await started.wait()
        let joiner = Task { await service.photosForTrip(twin) }
        let cancelledJoiner = Task { await service.photosForTrip(twin) }
        while admissions.count < 3 { await Task.yield() }
        cancelledJoiner.cancel()
        let token = service.changeToken
        // An annotation settle or restore invalidates without notifying.
        if invalidated { service.invalidateCache(for: first.id) }
        ctx.delete(first)
        try ctx.save()
        await finish.release()

        #expect(admissions == [false, true, true])
        #expect(await creator.value.groups == nil)
        #expect(await joiner.value.groups?.first?.stayLocality == "shared",
                "the live twin keeps the best-effort snapshot")
        _ = await cancelledJoiner.value
        #expect((service.changeToken != token) == invalidated,
                "a superseded snapshot handed to a live twin must schedule its reload; an unsuperseded one must not")
        #expect(await counter.count == 1)
        #expect(!service.cachedGroupsExist(for: twin.id), "a dead creator must not cache")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 1,
                "deleting one twin must leave the other row")
    }

    @Test("the detail's initial load enriches a live trip with the UUID captured before loading")
    func initialLoadLiveTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let recorder = InitialLoadRecorder()
        await TripDetailView.runInitialLoad(
            for: trip,
            loadPhotos: { recorder.photoLoads += 1 },
            enrich: { recorder.enriched.append($0) })
        #expect(recorder.photoLoads == 1)
        #expect(recorder.enriched == [trip.id])
    }

    @Test("a detail whose trip is deleted while photos load skips weather",
          arguments: [false, true])
    func initialLoadDeletedTrip(saved: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let recorder = InitialLoadRecorder()
        await TripDetailView.runInitialLoad(
            for: trip,
            loadPhotos: {
                recorder.photoLoads += 1
                ctx.delete(trip)
                if saved { try? ctx.save() }
            },
            enrich: { recorder.enriched.append($0) })
        #expect(recorder.photoLoads == 1)
        #expect(recorder.enriched.isEmpty)
    }

    @Test("a detail torn down while photos load skips weather")
    func initialLoadCancelled() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let recorder = InitialLoadRecorder()
        let task = Task {
            await TripDetailView.runInitialLoad(
                for: trip,
                loadPhotos: {
                    recorder.photoLoads += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                enrich: { recorder.enriched.append($0) })
        }
        await task.value
        #expect(recorder.photoLoads == 1)
        #expect(recorder.enriched.isEmpty)
    }

    // MARK: - retry exhaustion

    @Test("exhausted retries return an uncached snapshot, notify observers, and never overwrite a fresher cache",
          .timeLimit(.minutes(1)))
    func exhaustionReturnsBestEffortSnapshot() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let id = trip.id
        let service = makeService(container)
        let started = (0..<4).map { _ in OutcomeLatch() }
        let finish = (0..<4).map { _ in OutcomeLatch() }
        let counter = OutcomeCounter()
        service.computeOverrideForTesting = {
            let call = await counter.increment()
            if call <= 4 {
                await started[call - 1].release()
                await finish[call - 1].wait()
            }
            return Self.sentinel("call-\(call)")
        }

        let token = service.changeToken
        let chain = Task { await service.photosForTrip(trip) }
        for attempt in 0..<3 {
            await started[attempt].wait()
            service.invalidateCache(for: id)
            await finish[attempt].release()
        }
        await started[3].wait()
        service.invalidateCache(for: id)
        #expect(service.changeToken == token, "invalidation alone does not notify")

        // A caller after the last invalidation starts its own compute under the
        // new epoch instead of joining the exhausted chain.
        var admissions: [Bool] = []
        service.singleFlightAdmissionForTesting = { admissions.append($0) }
        let followUp = await service.photosForTrip(trip)
        service.singleFlightAdmissionForTesting = nil
        #expect(admissions == [false])
        #expect(followUp.groups?.first?.stayLocality == "call-5")
        #expect(service.cachedGroupsExist(for: id))

        await finish[3].release()
        let exhausted = await chain.value
        #expect(exhausted.groups?.first?.stayLocality == "call-4",
                "a live trip keeps the best-effort snapshot")
        #expect(service.changeToken != token, "exhaustion must schedule a reload under a fresh key")
        #expect(await counter.count == 5)

        let cached = await service.photosForTrip(trip)
        #expect(cached.groups?.first?.stayLocality == "call-5",
                "the exhausted snapshot must not overwrite the fresher cache")
        #expect(await counter.count == 5)
    }

    // MARK: - route to Hidden Photos

    @Test("a detail whose first load cannot read the hidden list keeps its route to Hidden Photos",
          .timeLimit(.minutes(1)))
    func detailFirstReadFailureKeepsHiddenRoute() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let service = makeService(container)
        service.computeOverrideForTesting = { Self.sentinel("visible") }
        service.hiddenResolutionOverrideForTesting = { $0.count }
        defer { service.authorizationOverrideForTesting = nil }

        // Cold detail, unreadable hidden list: publish no photos, keep the route.
        service.failAnnotationReadForTesting = true
        let cold = await TripDetailView.resolvePhotoLoad(
            for: trip, showingPhotos: false, service: service, isCurrent: { true })
        #expect(cold != nil, "a cold failure must still publish the route")
        #expect(cold?.photos == nil, "an unreadable hidden list must not publish photos")
        #expect(cold?.hiddenRoute == true)

        // Photos already shown stay exactly as they are.
        #expect(await TripDetailView.resolvePhotoLoad(
            for: trip, showingPhotos: true, service: service, isCurrent: { true }) == nil)
        // A superseded or cancelled pass publishes nothing.
        #expect(await TripDetailView.resolvePhotoLoad(
            for: trip, showingPhotos: false, service: service, isCurrent: { false }) == nil)
        let cancelledPublishedNothing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TripDetailView.resolvePhotoLoad(
                for: trip, showingPhotos: false, service: service, isCurrent: { true }) == nil
        }
        #expect(await cancelledPublishedNothing.value)

        // The retry reads the list: visible photos publish and the link is See All.
        service.failAnnotationReadForTesting = false
        let recovered = await TripDetailView.resolvePhotoLoad(
            for: trip, showingPhotos: false, service: service, isCurrent: { true })
        #expect(recovered?.photos?.first?.stayLocality == "visible")
        #expect(recovered?.hiddenRoute == false)
    }

    @Test("hiding the only photo keeps a restorable-hidden route and restoring clears it",
          .timeLimit(.minutes(1)))
    func hiddenRouteFollowsHideAndRestore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        let tripID = trip.id
        let service = makeService(container)
        service.hiddenResolutionOverrideForTesting = { $0.count }
        service.computeOverrideForTesting = { [] }
        // hidePhoto schedules a debounced cloud-ID pass; it must not see the
        // authorized override after the test and reach the app store or PhotoKit.
        defer { service.authorizationOverrideForTesting = nil }

        #expect(!(await service.hasRestorableHiddenPhotos(for: trip)))
        #expect(await service.hidePhoto(localIdentifier: "only", tripID: tripID).value)
        // What the detail and gallery compose: nothing visible, a hidden route.
        #expect(await service.photosForTrip(trip).groups?.isEmpty == true)
        #expect(await service.hasRestorableHiddenPhotos(for: trip))

        // Rows whose asset is not on this device do not open an empty page.
        service.hiddenResolutionOverrideForTesting = { _ in 0 }
        #expect(!(await service.hasRestorableHiddenPhotos(for: trip)))
        service.hiddenResolutionOverrideForTesting = { $0.count }

        // A trip with no photo stay offers none, however many rows resolve.
        let stay = try #require(trip.stays?.first)
        stay.category = .home
        #expect(!(await service.hasRestorableHiddenPhotos(for: trip)))
        stay.category = .destination

        // Unknown keeps the route; without photo access there is none.
        service.failAnnotationReadForTesting = true
        #expect(await service.hasRestorableHiddenPhotos(for: trip))
        service.failAnnotationReadForTesting = false
        service.authorizationOverrideForTesting = .denied
        #expect(!(await service.hasRestorableHiddenPhotos(for: trip)))
        service.authorizationOverrideForTesting = .authorized

        #expect(await service.unhidePhoto(localIdentifier: "only", tripID: tripID).value)
        #expect(!(await service.hasRestorableHiddenPhotos(for: trip)))
    }

    @Test("Hidden Photos offers a hidden photo this trip would show, never one from another piece's dates or place")
    func hiddenOfferFollowsGalleryAdmission() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTrip(ctx)
        // The inputs the Hidden Photos list and route admit with: the gallery's
        // snapshot, its window and its stay geometry.
        let snapshot = PhotoService.photoSnapshot(for: trip)
        let (windowStart, windowEnd) = snapshot.photoWindow
        let contexts = PhotoService.matchContexts(for: snapshot.photoStays)
        func offered(
            _ latitude: Double, _ longitude: Double, hoursAfterStart hours: Double,
            hiddenInPhotos: Bool = false
        ) -> Bool {
            PhotoService.isOfferedHiddenAsset(
                location: CLLocation(latitude: latitude, longitude: longitude),
                creationDate: Self.start.addingTimeInterval(hours * 3600),
                mediaType: .image, mediaSubtypes: [], sourceType: .typeUserLibrary,
                isHidden: hiddenInPhotos,
                windowStart: windowStart, windowEnd: windowEnd, matchContexts: contexts)
        }

        #expect(offered(37.9, 23.7, hoursAfterStart: 2), "hidden at this trip's stay, during it")
        // The gallery's fetch leaves out a photo hidden in Photos, so restoring
        // it here would show nothing.
        #expect(!offered(37.9, 23.7, hoursAfterStart: 2, hiddenInPhotos: true), "hidden in Photos too")
        // A split copies every hidden row onto every piece, so this trip can
        // carry a row hidden on an earlier piece's dates elsewhere.
        #expect(!offered(50.85, 4.35, hoursAfterStart: -240), "another piece's dates and place")
        #expect(!offered(37.9, 23.7, hoursAfterStart: -240), "the shared base on another piece's dates")
        #expect(!offered(50.85, 4.35, hoursAfterStart: 2), "another place inside this trip's dates")
    }
}
