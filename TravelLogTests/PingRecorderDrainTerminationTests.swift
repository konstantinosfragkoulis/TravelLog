//
//  PingRecorderDrainTerminationTests.swift
//  TravelLogTests
//
//  Exercises PingRecorder's geocoding-drain termination behavior:
//  retryAllFailedGeocodingGated / retryFailedGeocoding /
//  geocodeByUniqueHex must RETURN on a permanently-unresolvable backlog
//  rather than spin forever. We seed ungeocoded pings at mid-ocean coords,
//  valid H3 indices so the rows insert, yet they resolve to nil whether or not
//  Geocoder.sqlite is present in the test host, so isGeocoded stays false on
//  every iteration: exactly the no-progress condition the guard must break on.
//  The drain test carries .timeLimit(.minutes(1)) so a regression surfaces as
//  a timeout, not a hung suite.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model type (LocationPing) and its members
//  MainActor-isolated; the suite seeds rows and fetches counts for assertions.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder geocoding-drain termination")
struct PingRecorderDrainTerminationTests {

    static let base = Date(timeIntervalSince1970: 1_597_580_800)
    private static let oceanBase = Date(timeIntervalSince1970: 1_600_000_000)

    /// Permanently-unresolvable open-ocean coords (South Pacific). Each is a
    /// distinct res-6 hex; all valid H3, none geocode.
    static let midOcean: [(lat: Double, lon: Double)] = [
        (0.0, -140.0), (1.0, -141.0), (2.0, -142.0),
        (3.0, -143.0), (4.0, -144.0), (5.0, -145.0),
        (6.0, -146.0)
    ]

    /// Seed `count` ungeocoded mid-ocean pings (with valid H3 indices) and save.
    @discardableResult
    private func seedUngeocoded(in container: ModelContainer, count: Int) throws -> Int {
        let ctx = ModelContext(container)
        var inserted = 0
        for i in 0..<count {
            let coord = Self.midOcean[i % Self.midOcean.count]
            // Spread distinct coords so every ping gets a distinct hex even past
            // the fixture array length.
            let lat = coord.lat + Double(i / Self.midOcean.count) * 0.5
            let lon = coord.lon
            guard let hex = H3Service.cellIndex(latitude: lat, longitude: lon) else { continue }
            let ping = LocationPing(
                timestamp: Self.oceanBase.addingTimeInterval(Double(i)),
                latitude: lat, longitude: lon,
                horizontalAccuracy: 10,
                h3IndexRes6: hex
            )
            // LocationPing.init defaults isGeocoded = false; leave it.
            ctx.insert(ping)
            inserted += 1
        }
        try ctx.save()
        return inserted
    }

    private func ungeocodedCount(_ container: ModelContainer) throws -> Int {
        let ctx = ModelContext(container)
        let predicate = #Predicate<LocationPing> { $0.isGeocoded == false }
        return try ctx.fetchCount(FetchDescriptor<LocationPing>(predicate: predicate))
    }

    // MARK: - retryAllFailedGeocodingGated termination (the C2-DRAIN-SPIN invariant)
    //
    // Each test passes a FRESH `PipelineGate(forTesting:)` so the chunked
    // drain's per-chunk gate units never serialize against the process-global
    // `shared` gate (the same isolation precedent as PipelineGateOrderingTests).

    @Test(.timeLimit(.minutes(1)))
    func gatedDrainTerminatesOnPermanentlyUnresolvableBacklog() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUngeocoded(in: container, count: 7)
        let rec = PingRecorder(modelContainer: container)

        // The headline assertion is that this RETURNS at all; the
        // no-progress guard (`passGeocoded == 0` → break) fires after the
        // first fruitless pass. A spin would time out instead.
        await rec.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
    }

    @Test(.timeLimit(.minutes(1)))
    func gatedDrainTerminatesAcrossMultipleHexChunks() async throws {
        // 60 distinct unresolvable hexes > the 50-hex chunk size, so the
        // hex phase must advance across chunk boundaries (a chunk that
        // geocodes nothing still consumes its hexes) and then the drain's
        // no-progress guard must end the drain.
        let container = try TestSupport.makeInMemoryContainer()
        let seeded = try seedUngeocoded(in: container, count: 60)
        let rec = PingRecorder(modelContainer: container)

        await rec.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))

        #expect(try ungeocodedCount(container) == seeded)
    }

    @Test("after the gated drain returns, all unresolvable pings remain ungeocoded")
    func gatedDrainLeavesUnresolvablePingsUngeocoded() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let seeded = try seedUngeocoded(in: container, count: 7)
        let rec = PingRecorder(modelContainer: container)

        await rec.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))

        // Resolver had nothing for mid-ocean; the guard didn't fabricate
        // geocoding. The ungeocoded count is unchanged.
        #expect(try ungeocodedCount(container) == seeded)
    }

    @Test("gated drain on an empty backlog returns immediately")
    func gatedDrainOnEmptyBacklogReturnsImmediately() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)
        await rec.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ()))
        #expect(try ungeocodedCount(container) == 0)
    }

    // MARK: - geocodeByUniqueHex

    @Test("geocodeByUniqueHex returns 0 on an empty store (empty-fetch early return)")
    func geocodeByUniqueHexReturnsZeroWhenNoUngeocodedPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)
        let geocoded = await rec.geocodeByUniqueHex()
        #expect(geocoded == 0)
    }

    @Test("geocodeByUniqueHex returns 0 when every hex is unresolvable (per-hex continue path)")
    func geocodeByUniqueHexReturnsZeroForOnlyUnresolvableHexes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedUngeocoded(in: container, count: 7)
        let rec = PingRecorder(modelContainer: container)
        let geocoded = await rec.geocodeByUniqueHex()
        #expect(geocoded == 0)
    }

    @Test("geocoding a titled trip invalidates its canonical and localized titles")
    func geocodingInvalidatesTitleDerivatives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let latitude = 37.9838
        let longitude = 23.7275
        let result = await GeocodeResolver.shared.resolve(
            latitude: latitude,
            longitude: longitude)
        _ = try #require(
            result?.localityForStorage != nil,
            "bundled geocoder did not resolve Athens")
        let hex = try #require(H3Service.cellIndex(
            latitude: latitude,
            longitude: longitude))
        let ping = LocationPing(
            timestamp: Self.base,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: hex)
        let stay = Stay(
            startTime: Self.base,
            endTime: Self.base.addingTimeInterval(3_600),
            centroidLatitude: latitude,
            centroidLongitude: longitude,
            h3IndexRes6: hex,
            pingCount: 1,
            distanceFromHomeKm: 500,
            pingIDs: [ping.id])
        stay.category = .destination
        let trip = Trip(startDate: Self.base)
        trip.aiGeneratedTitle = "Old Place Title"
        context.insert(ping)
        context.insert(stay)
        context.insert(trip)
        stay.trip = trip
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Alter Ortstitel",
            sourceTitle: "Old Place Title",
            trip: trip))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        #expect(await recorder.geocodeByUniqueHex() == 1)

        let fresh = ModelContext(container)
        let reloaded = try #require(try fresh.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedTitle == "Athens")
        #expect(try fresh.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("rolled-back hex geocoding reports zero durable progress")
    func rolledBackHexGeocodingReportsZero() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let latitude = 37.9838
        let longitude = 23.7275
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: latitude, longitude: longitude)?.localityForStorage)
        let hex = try #require(H3Service.cellIndex(
            latitude: latitude, longitude: longitude))
        context.insert(LocationPing(
            timestamp: Self.base, latitude: latitude, longitude: longitude,
            horizontalAccuracy: 10, h3IndexRes6: hex))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextGeocodeSaveForTesting(true)

        #expect(await recorder.geocodeByUniqueHex() == 0)
        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<LocationPing>()).first)
        #expect(!reloaded.isGeocoded)
    }

    @Test("drain reaches older resolvable stays behind an unresolvable newest window", arguments: [true, false])
    func centroidDrainReachesOlderResolvableStays(settled: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        #expect(await GeocodeResolver.shared.resolve(
            latitude: 0.0, longitude: -160.0) == nil)
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.9838, longitude: 23.7275)?.localityForStorage)
        var athensIDs: Set<UUID> = []
        for i in 0..<12 {
            let isAthens = i < 2
            let latitude = isAthens ? 37.9838 : 0.0
            let longitude = isAthens ? 23.7275 : -160.0
            let start = Self.base.addingTimeInterval(Double(i) * 7_200)
            let stay = Stay(
                startTime: start,
                endTime: settled ? start.addingTimeInterval(3_600) : Date.now,
                centroidLatitude: latitude,
                centroidLongitude: longitude,
                h3IndexRes6: try #require(H3Service.cellIndex(
                    latitude: latitude, longitude: longitude)),
                pingCount: 1,
                distanceFromHomeKm: 500,
                pingIDs: [])
            context.insert(stay)
            if isAthens { athensIDs.insert(stay.id) }
        }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let geocoded = await recorder.geocodeUngeocodedStays()
        #expect(geocoded == 2)

        let reloaded = try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .filter { athensIDs.contains($0.id) }
        #expect(reloaded.count == 2)
        #expect(reloaded.allSatisfy { $0.locality != nil })
    }

    @Test("drain attempt cap bounds one call")
    func centroidDrainAttemptCapBoundsOneCall() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        #expect(await GeocodeResolver.shared.resolve(
            latitude: 0.0, longitude: -160.0) == nil)
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.9838, longitude: 23.7275)?.localityForStorage)
        for i in 0..<202 {
            let latitude = i == 0 ? 37.9838 : 0.0
            let longitude = i == 0 ? 23.7275 : -160.0
            let start = Self.base.addingTimeInterval(Double(i) * 7_200)
            context.insert(Stay(
                startTime: start,
                endTime: start.addingTimeInterval(3_600),
                centroidLatitude: latitude,
                centroidLongitude: longitude,
                h3IndexRes6: try #require(H3Service.cellIndex(
                    latitude: latitude, longitude: longitude)),
                pingCount: 1,
                distanceFromHomeKm: 500,
                pingIDs: []))
        }
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        #expect(await recorder.geocodeUngeocodedStays() == 0)
        let oldest = FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)])
        #expect(try #require(try ModelContext(container).fetch(oldest).first).locality == nil)

        let geocoded = await recorder.geocodeUngeocodedStays()
        #expect(geocoded == 1)
        #expect(try #require(try ModelContext(container).fetch(oldest).first).locality != nil)
    }

    @Test("rolled-back centroid geocoding reports zero durable progress")
    func rolledBackCentroidGeocodingReportsZero() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let latitude = 37.9838
        let longitude = 23.7275
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: latitude, longitude: longitude)?.localityForStorage)
        let hex = try #require(H3Service.cellIndex(
            latitude: latitude, longitude: longitude))
        context.insert(Stay(
            startTime: Self.base,
            endTime: Self.base.addingTimeInterval(3_600),
            centroidLatitude: latitude,
            centroidLongitude: longitude,
            h3IndexRes6: hex,
            pingCount: 1,
            distanceFromHomeKm: 500,
            pingIDs: []))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextGeocodeSaveForTesting(true)

        #expect(await recorder.geocodeUngeocodedStays() == 0)
        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Stay>()).first)
        #expect(reloaded.locality == nil)
    }

    // MARK: - retryFailedGeocoding (single batch, bounded by limit)

    @Test(.timeLimit(.minutes(1)))
    func retryFailedGeocodingTerminatesOnUnresolvableBacklog() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let seeded = try seedUngeocoded(in: container, count: 7) // > limit
        let rec = PingRecorder(modelContainer: container)

        await rec.retryFailedGeocoding(limit: 5)

        // Single batch terminated and mutated nothing for unresolvable coords.
        #expect(try ungeocodedCount(container) == seeded)
    }

    @Test("retryFailedGeocoding geocodes exactly `limit` resolvable pings, newest first")
    func retryFailedGeocodingRespectsLimit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let latitude = 37.9838
        let longitude = 23.7275
        _ = try #require(await GeocodeResolver.shared.resolve(
            latitude: latitude, longitude: longitude)?.localityForStorage)
        let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
        var ids: [UUID] = []
        for i in 0..<7 {
            let ping = LocationPing(
                timestamp: Self.base.addingTimeInterval(Double(i)),
                latitude: latitude, longitude: longitude,
                horizontalAccuracy: 10, h3IndexRes6: hex)
            ctx.insert(ping)
            ids.append(ping.id)
        }
        try ctx.save()
        let rec = PingRecorder(modelContainer: container)

        let result = await rec.retryFailedGeocoding(limit: 5)

        #expect(result.progress == 5)
        #expect(result.failed == false)
        #expect(try ungeocodedCount(container) == 2)
        let ungeocoded = try ModelContext(container).fetch(FetchDescriptor<LocationPing>(
            predicate: #Predicate { $0.isGeocoded == false }))
        #expect(Set(ungeocoded.map(\.id)) == Set(ids.prefix(2)))
    }
}
