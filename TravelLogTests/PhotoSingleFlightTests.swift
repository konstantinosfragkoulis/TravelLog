//
//  PhotoSingleFlightTests.swift
//  TravelLogTests
//
//  Tests photosForTrip's keyed single-flight: concurrent callers with the
//  same key, including gallery tasks, refetch and prewarm, must share
//  one compute, while invalidation creates a new key and must trigger a
//  fresh one. Uses the DEBUG seams: the auth override (the unit-test host has
//  no photo authorization, which would short-circuit before the single-flight
//  logic) and the compute override (deterministic, countable, suspends long
//  enough for the callers to genuinely overlap).
//
//  Each test uses an isolated PhotoService without system observers/timers.
//  Other suites may invalidate the app singleton without changing these
//  tests' epochs while an injected compute is suspended.
//

import Testing
import Foundation
import Photos
import SwiftData
@testable import TravelLog

private actor ComputeCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

@MainActor
@Suite("photosForTrip single-flight", .serialized)
struct PhotoSingleFlightTests {

    private func makeTripWithStay(_ ctx: ModelContext) throws -> Trip {
        let start = Date(timeIntervalSince1970: 1_725_808_000)
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(48 * 3600)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
                        centroidLatitude: 37.9, centroidLongitude: 23.7,
                        h3IndexRes6: "8a1eda62934ffff", pingCount: 3,
                        distanceFromHomeKm: 200, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        stay.trip = trip
        try ctx.save()
        return trip
    }

    private func withSeams(
        container: ModelContainer,
        _ body: (PhotoService, ComputeCounter) async -> Void
    ) async {
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let counter = ComputeCounter()
        service.authorizationOverrideForTesting = .authorized
        service.computeOverrideForTesting = { @Sendable in
            _ = await counter.increment()
            return []
        }
        defer {
            service.authorizationOverrideForTesting = nil
            service.computeOverrideForTesting = nil
        }
        await body(service, counter)
    }

    @Test("three concurrent same-key callers share one compute",
          .timeLimit(.minutes(1)))
    func concurrentCallersCoalesce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)

        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let counter = ComputeCounter()
        let latch = TestLatch()
        service.authorizationOverrideForTesting = .authorized
        service.computeOverrideForTesting = { @Sendable in
            _ = await counter.increment()
            await latch.wait()
            return []
        }
        defer {
            service.authorizationOverrideForTesting = nil
            service.computeOverrideForTesting = nil
            service.invalidateCache(for: trip.id)
        }

        var admissions: [Bool] = []
        service.singleFlightAdmissionForTesting = { joined in
            admissions.append(joined)
            if admissions.count == 3 { Task { await latch.release() } }
        }
        defer { service.singleFlightAdmissionForTesting = nil }
        async let a = service.photosForTrip(trip)
        async let b = service.photosForTrip(trip)
        async let c = service.photosForTrip(trip)

        let results = await [a, b, c]
        #expect(admissions == [false, true, true], "all three callers must reach admission before compute completes")
        #expect(results.allSatisfy { $0.groups?.isEmpty == true })
        #expect(await counter.count == 1,
                "same-key concurrent callers must share one compute")
    }

    @Test("a sequential call after completion hits the stored cache — still one compute")
    func sequentialCallHitsCache() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)

        await withSeams(container: container) { service, counter in
            defer { service.invalidateCache(for: trip.id) }
            _ = await service.photosForTrip(trip)
            _ = await service.photosForTrip(trip)
            #expect(await counter.count == 1,
                    "the second call must be served by the (token-matched) cache")
        }
    }

    @Test("a locality filled in place recomputes the gallery groups")
    func localityChangeMissesCache() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)

        await withSeams(container: container) { service, counter in
            defer { service.invalidateCache(for: trip.id) }
            _ = await service.photosForTrip(trip)
            trip.stays?.first?.locality = "Agia Kyriakií Spáton"
            _ = await service.photosForTrip(trip)
            #expect(await counter.count == 2,
                    "group headers carry the locality, so a new one must not hit the cache")
        }
    }

    @Test("prewarming fills only the count mirror without computing or caching gallery groups")
    func prewarmRetainsOnlyCount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        await withSeams(container: container) { service, counter in
            service.countOverrideForTesting = { 7 }
            await service.prewarmPhotoCounts(for: [trip])
            #expect(service.cachedPhotoCount(for: trip.id) == 7)
            #expect(!service.cachedGroupsExist(for: trip.id))
            #expect(await counter.count == 0)
        }
    }

    @Test("prewarming skips valid mirrors and refreshes changed shapes")
    func prewarmValidatesShape() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let counter = ComputeCounter()
        service.authorizationOverrideForTesting = .limited
        service.countOverrideForTesting = { await counter.increment() }
        await service.prewarmPhotoCounts(for: [trip])
        await service.prewarmPhotoCounts(for: [trip])
        #expect(await counter.count == 1)
        trip.endDate = trip.endDate!.addingTimeInterval(3600)
        await service.prewarmPhotoCounts(for: [trip])
        #expect(await counter.count == 2)
        #expect(service.cachedPhotoCount(for: trip.id) == 2)
        #expect(!service.cachedGroupsExist(for: trip.id))
    }

    @Test("prewarming joins an already-running gallery compute", .timeLimit(.minutes(1)))
    func prewarmJoinsGallery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let started = TestLatch(), finish = TestLatch()
        let galleryCounter = ComputeCounter(), countCounter = ComputeCounter()
        service.authorizationOverrideForTesting = .authorized
        service.computeOverrideForTesting = {
            _ = await galleryCounter.increment()
            await started.release()
            await finish.wait()
            return []
        }
        service.countOverrideForTesting = {
            _ = await countCounter.increment()
            await finish.release()
            return 7
        }
        var joined = false
        service.singleFlightAdmissionForTesting = { isJoin in
            if isJoin {
                joined = true
                Task { await finish.release() }
            }
        }
        let gallery = Task { await service.photosForTrip(trip) }
        await started.wait()
        await service.prewarmPhotoCounts(for: [trip])
        _ = await gallery.value
        #expect(joined)
        #expect(await galleryCounter.count == 1)
        #expect(await countCounter.count == 0)
        #expect(service.cachedPhotoCount(for: trip.id) == 0)
    }

    @Test("cancelled, superseded, reshaped, or deleted count work cannot publish",
          .timeLimit(.minutes(1)),
          arguments: ["cancel", "supersede", "reshape", "delete"])
    func prewarmRejectsStaleWork(reason: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let id = trip.id
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let started = TestLatch(), finish = TestLatch()
        let counter = ComputeCounter()
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = {
            let call = await counter.increment()
            if call == 1 {
                await started.release()
                await finish.wait()
            }
            return call
        }
        let work = Task { await service.prewarmPhotoCounts(for: [trip]) }
        await started.wait()
        switch reason {
        case "cancel": work.cancel()
        case "supersede": await service.prewarmPhotoCounts(for: [trip])
        case "reshape": trip.endDate = trip.endDate!.addingTimeInterval(3600)
        default:
            ctx.delete(trip)
            try ctx.save()
        }
        await finish.release()
        await work.value
        #expect(service.cachedPhotoCount(for: id) == (reason == "supersede" ? 2 : nil))
        #expect(!service.cachedGroupsExist(for: id))
    }

    @Test("invalidation while counting retries with the new epoch", .timeLimit(.minutes(1)))
    func prewarmRetriesInvalidation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let started = TestLatch(), finish = TestLatch()
        let counter = ComputeCounter()
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = {
            let call = await counter.increment()
            if call == 1 {
                await started.release()
                await finish.wait()
            }
            return call
        }
        let work = Task { await service.prewarmPhotoCounts(for: [trip]) }
        await started.wait()
        service.invalidateCache(for: trip.id)
        await finish.release()
        await work.value
        #expect(await counter.count == 2)
        #expect(service.cachedPhotoCount(for: trip.id) == 2)
    }

    @Test("a global invalidation keeps the last count until the recount lands")
    func globalInvalidationKeepsCount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = { 7 }
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 7)
        service.invalidateTripCaches()
        #expect(service.cachedPhotoCount(for: trip.id) == 7)
        service.countOverrideForTesting = { 9 }
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 9)
    }

    @Test("a retained zero stays authoritative for the photo filter until the recount lands")
    func globalInvalidationKeepsZeroUntilRecount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = { 0 }
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 0)
        service.invalidateTripCaches()
        // The trip stays out of a "has photos" list, instead of every trip
        // flashing back in, until its recount replaces the zero.
        #expect(service.cachedPhotoCount(for: trip.id) == 0)
        service.countOverrideForTesting = { 3 }
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 3)
    }

    @Test("a retained count does not outlive photo access")
    func deniedAccessClearsRetainedCounts() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = { 7 }
        await service.prewarmPhotoCounts(for: [trip])
        service.invalidateTripCaches()
        #expect(service.cachedPhotoCount(for: trip.id) == 7)
        service.authorizationOverrideForTesting = .denied
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == nil)
    }

    @Test("invalidateAllCaches clears counts")
    func invalidateAllCachesClearsCounts() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.authorizationOverrideForTesting = .authorized
        service.countOverrideForTesting = { 7 }
        await service.prewarmPhotoCounts(for: [trip])
        #expect(service.cachedPhotoCount(for: trip.id) == 7)
        service.invalidateAllCaches()
        #expect(service.cachedPhotoCount(for: trip.id) == nil)
    }

    @Test("denied authorization and deleted trips skip count work")
    func prewarmGuardsInputs() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let id = trip.id
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        let counter = ComputeCounter()
        service.countOverrideForTesting = { await counter.increment() }
        service.authorizationOverrideForTesting = .denied
        await service.prewarmPhotoCounts(for: [trip])
        service.authorizationOverrideForTesting = .authorized
        ctx.delete(trip)
        try ctx.save()
        await service.prewarmPhotoCounts(for: [trip])
        #expect(await counter.count == 0)
        #expect(service.cachedPhotoCount(for: id) == nil)
    }

    @Test("an invalidation between calls produces a NEW key and a fresh compute")
    func invalidationForcesFreshCompute() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)

        await withSeams(container: container) { service, counter in
            defer { service.invalidateCache(for: trip.id) }
            _ = await service.photosForTrip(trip)
            service.invalidateCache(for: trip.id)   // bumps the per-trip epoch
            _ = await service.photosForTrip(trip)
            #expect(await counter.count == 2,
                    "different epochs must never coalesce")
        }
    }

    @Test("a deleted stay is not admitted to the gallery compute")
    func deletedStayIsNotAdmitted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = try makeTripWithStay(ctx)
        let stay = try #require(trip.stays?.first)
        ctx.delete(stay)
        #expect(trip.stays?.contains { $0 === stay } == true,
                "the unsaved deletion must still be reachable through trip.stays")

        await withSeams(container: container) { service, counter in
            defer { service.invalidateCache(for: trip.id) }
            let outcome = await service.photosForTrip(trip)
            #expect(outcome.groups?.isEmpty == true)
            #expect(await counter.count == 0,
                    "a deleted stay must not reach the gallery compute")
        }
    }
}
