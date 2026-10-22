//
//  PingRecorderPreAttachTests.swift
//  TravelLogTests
//
//  Exercises PingRecorder's import pre-attach merge: findHostStayForImportedPing + attachImportedPing, driven via
//  recordImportedPing, plus the trip-summary propagation
//  (recomputeAffectedTripSummaries / clearAffectedTripIDs). Verifies the
//  spatio-temporal envelope (StayClusterer.timeWindowSeconds = 4 h,
//  distanceThresholdMeters = 3000), the .liveSLC → .merged provenance flip,
//  start/end-time extension, running-average centroid, closest-stay-wins, and
//  the isProcessed mark. recordImportedPing returns true even when the ping is
//  pre-attached (it was still a fresh insert), so absorption is asserted via
//  Stay/Trip mutation, not the return value.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model types (Stay, Trip, LocationPing) and their
//  members MainActor-isolated; the suite builds the host graph and re-fetches
//  for assertions.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder import pre-attach merge")
struct PingRecorderPreAttachTests {

    // MARK: - Fixtures

    nonisolated static let athens = (lat: 37.9838, lon: 23.7275)
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    static let base = Date(timeIntervalSince1970: 1_628_425_600)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.base.addingTimeInterval(seconds)
    }

    /// Insert a host Stay (Athens centroid, base..base+3600, pingCount 1) into
    /// the container and save so the recorder's own context can fetch it.
    /// Returns the host Stay's id for later re-fetch.
    @discardableResult
    private func seedHostStay(
        in container: ModelContainer,
        centroidLat: Double = athens.lat,
        centroidLon: Double = athens.lon,
        startTime: Date,
        endTime: Date,
        source: DataSource = .liveSLC,
        trip: Trip? = nil
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let hex = H3Service.cellIndex(latitude: centroidLat, longitude: centroidLon)!
        let stay = Stay(
            startTime: startTime, endTime: endTime,
            centroidLatitude: centroidLat, centroidLongitude: centroidLon,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0,
            pingIDs: [UUID()], source: source
        )
        ctx.insert(stay)
        if let trip {
            ctx.insert(trip)
            stay.trip = trip
            stay.orderInTrip = 0
        }
        try ctx.save()
        return stay.id
    }

    private func fetchStay(_ container: ModelContainer, _ id: UUID) throws -> Stay? {
        let ctx = ModelContext(container)
        let predicate = #Predicate<Stay> { $0.id == id }
        return try ctx.fetch(FetchDescriptor<Stay>(predicate: predicate)).first
    }

    // MARK: - Absorption happy path

    @Test("imported ping inside the Stay envelope is absorbed (pingCount 1 → 2, new id in pingIDs)")
    func importedPingInsideStayEnvelopeIsAbsorbed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(
            timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.pingCount == 2)
        #expect(stay.pingIDs.count == 2)
    }

    @Test("first import-sourced absorption flips .liveSLC → .merged")
    func absorptionFlipsLiveSourceToMerged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600), source: .liveSLC)
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.source == .merged)
    }

    @Test("absorption does not re-flip a .photoImport host (guard is `if source == .liveSLC`)")
    func absorptionDoesNotReflipMergedOrPhotoImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600), source: .photoImport)
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.source == .photoImport)
    }

    // MARK: - Time extension

    @Test("absorbing an older ping extends startTime backward and grows durationMinutes")
    func absorptionExtendsStartTimeBackwardForOlderPing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        // Older than startTime=base but still within the 4 h findHost window.
        let older = at(-1800)
        _ = try await rec.recordImportedPing(timestamp: older, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.startTime == older)
        // (base+3600) - (base-1800) = 5400 s = 90 min
        #expect(stay.durationMinutes == 90)
    }

    @Test("absorbing a newer ping extends endTime forward; durationMinutes recomputed")
    func absorptionExtendsEndTimeForwardForNewerPing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        // After endTime=base+3600 but within the +4 h window.
        let newer = at(5400)
        _ = try await rec.recordImportedPing(timestamp: newer, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.endTime == newer)
        // (base+5400) - base = 5400 s = 90 min
        #expect(stay.durationMinutes == 90)
    }

    // MARK: - Centroid running average

    @Test("absorption updates centroid by running average: new = old + (ping - old)/n with n = 2")
    func absorptionUpdatesCentroidByRunningAverage() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        // A small offset still < 3 km so it's absorbed. 0.01° lat ≈ 1.1 km.
        let pingLat = Self.athens.lat + 0.01
        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: pingLat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let stay = try #require(try fetchStay(container, stayID))
        // n = pingCount = 2 after the append, so the centroid moves exactly
        // half the delta toward the new ping.
        let expectedLat = Self.athens.lat + (pingLat - Self.athens.lat) / 2.0
        #expect(abs(stay.centroidLatitude - expectedLat) < 1e-9)
    }

    // MARK: - Rejection (out of envelope)

    @Test("ping > 3 km away is not absorbed; host Stay unchanged (distance filter)")
    func pingBeyondThreeKmIsNotAbsorbed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        // Within the time window but about 311 km away (Ioánnina).
        let accepted = try await rec.recordImportedPing(
            timestamp: at(1800), latitude: Self.ioannina.lat, longitude: Self.ioannina.lon,
            horizontalAccuracy: 10
        )
        try await rec.saveImportBatch()

        #expect(accepted == true) // still a fresh insert
        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.pingCount == 1)
    }

    @Test("ping beyond the +4 h time window is not absorbed even at the same coords")
    func pingOutsideTimeWindowIsNotAbsorbed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        // endTime + 4 h + a bit: base + 3600 + (4*3600) + 60; outside the
        // temporal predicate window for the host.
        let farFuture = at(3600 + 4 * 3600 + 60)
        let accepted = try await rec.recordImportedPing(
            timestamp: farFuture, latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        try await rec.saveImportBatch()

        #expect(accepted == true)
        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.pingCount == 1)
    }

    // MARK: - Closest-stay-wins

    @Test("when two stays match, the closer-centroid stay absorbs the ping (viable.min by distance)")
    func closestStayWinsWhenTwoStaysMatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        // Closer host: Athens-exact.
        let closeID = try seedHostStay(in: container, centroidLat: Self.athens.lat, centroidLon: Self.athens.lon, startTime: Self.base, endTime: at(3600))
        // Farther host: ~2 km offset (0.018° lat ≈ 2 km), still < 3 km, same
        // time window.
        let farID = try seedHostStay(in: container, centroidLat: Self.athens.lat + 0.018, centroidLon: Self.athens.lon, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let close = try #require(try fetchStay(container, closeID))
        let far = try #require(try fetchStay(container, farID))
        #expect(close.pingCount == 2)
        #expect(far.pingCount == 1)
    }

    // MARK: - isProcessed

    @Test("an absorbed imported ping is marked isProcessed so the post-import cluster pass skips it")
    func absorbedPingIsMarkedProcessed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedHostStay(in: container, startTime: Self.base, endTime: at(3600))
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        // The host stay seed ping has no real LocationPing row; the only
        // LocationPing in the store is the imported one. Assert it is processed.
        let pings = try ctx.fetch(FetchDescriptor<LocationPing>())
        let imported = try #require(pings.first)
        #expect(pings.count == 1)
        #expect(imported.isProcessed == true)
    }

    // MARK: - Trip summary propagation

    @Test("recomputeAffectedTripSummaries flips the trip to .merged, then is an idempotent no-op")
    func recomputeAffectedTripSummariesFlipsTripToMergedThenClears() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = Trip(startDate: Self.base, source: .liveSLC)
        let stayID = try seedHostStay(in: container, startTime: Self.base, endTime: at(3600), source: .liveSLC, trip: trip)
        let tripID = trip.id
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        // Sanity: the host stay flipped to .merged.
        let stay = try #require(try fetchStay(container, stayID))
        #expect(stay.source == .merged)

        await rec.recomputeAffectedTripSummaries()

        let ctx1 = ModelContext(container)
        let tp = #Predicate<Trip> { $0.id == tripID }
        let trip1 = try #require(try ctx1.fetch(FetchDescriptor<Trip>(predicate: tp)).first)
        #expect(trip1.source == .merged)

        // Second call: the tracked set was already cleared → no-op, no crash.
        await rec.recomputeAffectedTripSummaries()
        let ctx2 = ModelContext(container)
        let trip2 = try #require(try ctx2.fetch(FetchDescriptor<Trip>(predicate: tp)).first)
        #expect(trip2.source == .merged)
    }

    @Test("boundary-changing absorption invalidates generated title derivatives")
    func boundaryAbsorptionInvalidatesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = Trip(startDate: Self.base, source: .liveSLC)
        trip.aiGeneratedTitle = "Athens Weekend"
        let stayID = try seedHostStay(
            in: container, startTime: Self.base, endTime: at(3600),
            source: .liveSLC, trip: trip)
        let context = ModelContext(container)
        let tripID = trip.id
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Athen-Wochenende",
            sourceTitle: "Athens Weekend", trip: stored))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: at(-1800), latitude: Self.athens.lat,
            longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await recorder.saveImportBatch()
        await recorder.recomputeAffectedTripSummaries()

        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first)
        #expect(reloaded.aiGeneratedTitle == nil)
        #expect((reloaded.localizedTitles ?? []).isEmpty)
        #expect(try #require(try fetchStay(container, stayID)).startTime == at(-1800))
    }

    @Test("a failed import-batch save rolls back both Stay changes and title invalidation")
    func failedBatchSaveIsAtomicWithTitleInvalidation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = Trip(startDate: Self.base, source: .liveSLC)
        trip.aiGeneratedTitle = "Athens Weekend"
        let stayID = try seedHostStay(
            in: container, startTime: Self.base, endTime: at(3600),
            source: .liveSLC, trip: trip)
        let seedContext = ModelContext(container)
        let tripID = trip.id
        let stored = try #require(try seedContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        seedContext.insert(TripTitleVariant(
            languageTag: "de", title: "Athen-Wochenende",
            sourceTitle: "Athens Weekend", trip: stored))
        try seedContext.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: at(-1800), latitude: Self.athens.lat,
            longitude: Self.athens.lon, horizontalAccuracy: 10)
        await recorder.setFailNextImportBatchSaveForTesting(true)
        do {
            try await recorder.saveImportBatch()
            Issue.record("injected batch save should fail")
        } catch { /* expected */ }

        var verification = ModelContext(container)
        var reloadedTrip = try #require(try verification.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first)
        #expect(reloadedTrip.aiGeneratedTitle == "Athens Weekend")
        #expect(reloadedTrip.localizedTitles?.first?.title == "Athen-Wochenende")
        #expect(try #require(try fetchStay(container, stayID)).startTime == Self.base)
        #expect(try verification.fetch(FetchDescriptor<LocationPing>()).isEmpty)

        // Retrying the same input after rollback must not be poisoned by the
        // discarded in-memory dedup index. The successful save then commits
        // the boundary change and invalidation together.
        #expect(try await recorder.recordImportedPing(
            timestamp: at(-1800), latitude: Self.athens.lat,
            longitude: Self.athens.lon, horizontalAccuracy: 10))
        try await recorder.saveImportBatch()

        verification = ModelContext(container)
        reloadedTrip = try #require(try verification.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first)
        #expect(reloadedTrip.aiGeneratedTitle == nil)
        #expect((reloadedTrip.localizedTitles ?? []).isEmpty)
        #expect(try #require(try fetchStay(container, stayID)).startTime == at(-1800))
        #expect(try verification.fetch(FetchDescriptor<LocationPing>()).count == 1)
    }

    @Test("ping-count-only absorption preserves generated title derivatives")
    func interiorAbsorptionPreservesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = Trip(startDate: Self.base, source: .liveSLC)
        trip.aiGeneratedTitle = "Athens Weekend"
        _ = try seedHostStay(
            in: container, startTime: Self.base, endTime: at(3600),
            source: .liveSLC, trip: trip)
        let context = ModelContext(container)
        let tripID = trip.id
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).first)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Athen-Wochenende",
            sourceTitle: "Athens Weekend", trip: stored))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: at(1800), latitude: Self.athens.lat,
            longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await recorder.saveImportBatch()
        await recorder.recomputeAffectedTripSummaries()

        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first)
        #expect(reloaded.aiGeneratedTitle == "Athens Weekend")
        #expect(reloaded.localizedTitles?.first?.title == "Athen-Wochenende")
    }

    @Test("clearAffectedTripIDs drops the pending set so the next recompute leaves the trip unrecomputed")
    func clearAffectedTripIDsPreventsSummaryRecompute() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = Trip(startDate: Self.base, source: .liveSLC)
        try seedHostStay(in: container, startTime: Self.base, endTime: at(3600), source: .liveSLC, trip: trip)
        let tripID = trip.id
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: at(1800), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)

        // Clear BEFORE the atomic batch save → the tracked set is emptied, so
        // neither that save nor the legacy catch-all recompute derives the
        // trip's source from its now-.merged stay.
        await rec.clearAffectedTripIDs()
        try await rec.saveImportBatch()
        await rec.recomputeAffectedTripSummaries()

        let ctx = ModelContext(container)
        let tp = #Predicate<Trip> { $0.id == tripID }
        let fetched = try #require(try ctx.fetch(FetchDescriptor<Trip>(predicate: tp)).first)
        // recomputeSummary was never called on this trip by this path, so its
        // sourceRaw stays at the seeded .liveSLC.
        #expect(fetched.source == .liveSLC)
    }

    @Test("recomputeAffectedTripSummaries on a fresh recorder (empty set) is a no-op and does not throw")
    func recomputeAffectedTripSummariesNoOpWhenSetEmpty() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)
        await rec.recomputeAffectedTripSummaries()
        // Nothing to assert beyond "did not crash"; confirm the store is empty.
        let ctx = ModelContext(container)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        #expect(trips.isEmpty)
    }
}
