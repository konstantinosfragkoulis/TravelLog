import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Country restore latch", .serialized)
struct CountryRestoreLatchTests {
    @discardableResult
    private func seedStay(_ context: ModelContext, withDonor: Bool) -> Stay {
        let start = Date(timeIntervalSinceReferenceDate: 492 * 86_400)
        let trip = Trip(startDate: start)
        trip.countryCodes = "GR"
        context.insert(trip)
        let ping = LocationPing(
            timestamp: start, latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 30, h3IndexRes6: "hexA", source: .liveSLC)
        ping.isoCountryCode = "GR"
        ping.country = "Greece"
        if withDonor { context.insert(ping) }
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "hexA", pingCount: 1, distanceFromHomeKm: 10,
            pingIDs: [ping.id])
        stay.trip = trip
        context.insert(stay)
        return stay
    }

    @Test("a failed donor read leaves country restore unsaved and retryable")
    func donorReadFailureIsNotSaved() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        seedStay(ctx, withDonor: true)
        try ctx.save()

        AppDelegate.failStayCountryDonorFetchForTesting = true
        defer { AppDelegate.failStayCountryDonorFetchForTesting = false }
        let result = await AppDelegate.restoreWipedStayCountry(modelContainer: container)
        #expect(!result.saved)
        #expect(result.attempted == 1)
        #expect(result.restored == 0)
        let fresh = ModelContext(container)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        #expect(stays.first?.country == nil)
        #expect(stays.first?.isoCountryCode == nil)
        #expect(try fresh.fetchCount(FetchDescriptor<LocationPing>()) == 1)
        #expect(try fresh.fetchCount(FetchDescriptor<Trip>()) == 1)
    }

    @Test("a successful empty donor read still restores country from the trip")
    func absentDonorKeepsTripFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        seedStay(ctx, withDonor: false)
        try ctx.save()

        let result = await AppDelegate.restoreWipedStayCountry(modelContainer: container)
        #expect(result.saved)
        #expect(result.restored == 1)
        #expect(result.viaTrip == 1)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.isoCountryCode == "GR")
        #expect(stays.first?.country == "Greece")
    }

    /// Runs the pass with a stubbed offline answer and counts MapKit fallback calls,
    /// cached or not: the pass holds the global writer gate, so it must stay offline.
    private func restoreCountingFallback(
        _ container: ModelContainer, offline: GeocodeResolver.Result?
    ) async -> (result: (attempted: Int, restored: Int, viaPing: Int, viaTrip: Int, viaResolver: Int, saved: Bool), fallbackCalls: Int) {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let result = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await MapKitLocalityCache.TestHook.$enrich.withValue({ offline, _, _, _ in
                calls.withLock { $0 += 1 }
                return offline
            }) {
                await AppDelegate.restoreWipedStayCountry(modelContainer: container)
            }
        }
        return (result, calls.withLock { $0 })
    }

    @Test("an ambiguous trip falls back to the offline resolver, never to MapKit")
    func resolverStepStaysOffline() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        seedStay(ctx, withDonor: false).trip?.countryCodes = "GR,TR"
        try ctx.save()

        let nameless = GeocodeResolver.Result(
            country: "Greece", isoCountryCode: "GR", administrativeArea: "Attiki",
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)
        let run = await restoreCountingFallback(container, offline: nameless)
        #expect(run.fallbackCalls == 0)
        #expect(run.result.saved)
        #expect(run.result.restored == 1)
        #expect(run.result.viaResolver == 1)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.isoCountryCode == "GR")
        #expect(stays.first?.country == "Greece")
    }

    @Test("no offline answer, or one without ISO, restores nothing and never calls MapKit",
          arguments: [false, true])
    func missingOfflineCountryRestoresNothing(hasResult: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        seedStay(ctx, withDonor: false).trip?.countryCodes = "GR,TR"
        try ctx.save()

        let offline = hasResult ? GeocodeResolver.Result(
            country: nil, isoCountryCode: nil, administrativeArea: "Attiki",
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil) : nil
        let run = await restoreCountingFallback(container, offline: offline)
        #expect(run.fallbackCalls == 0)
        #expect(run.result.saved)
        #expect(run.result.restored == 0)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.country == nil)
        #expect(stays.first?.isoCountryCode == nil)
    }
}
