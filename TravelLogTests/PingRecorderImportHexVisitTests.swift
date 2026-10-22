//
//  PingRecorderImportHexVisitTests.swift
//  TravelLogTests
//
//  Exercises PingRecorder's import-path HexVisit upsert
//  (upsertHexVisitForImport, driven via recordImportedPing) and the
//  reentry-cursor controls (resetLastImportedH3Index). Verifies the
//  import-only branches: backward firstVisited extension, forward lastVisited
//  extension, and the lastImportedH3Index reentry semantics (one count per
//  contiguous same-hex run; a reset re-arms the next same-hex ping as new).
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model types (LocationPing, HexVisit) and their
//  members MainActor-isolated; the suite fetches HexVisit rows for assertions.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder import HexVisit upsert")
struct PingRecorderImportHexVisitTests {

    // MARK: - Fixtures

    static let athens = (lat: 37.9838, lon: 23.7275)
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    static let base = Date(timeIntervalSince1970: 1_584_275_200)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.base.addingTimeInterval(seconds)
    }

    /// The res-6 hex string for a coordinate (matches what the recorder stores).
    private func hex(_ lat: Double, _ lon: Double) -> String {
        H3Service.cellIndex(latitude: lat, longitude: lon)!
    }

    private func fetchHex(_ ctx: ModelContext, _ h3: String) throws -> HexVisit? {
        let predicate = #Predicate<HexVisit> { $0.h3Index == h3 }
        return try ctx.fetch(FetchDescriptor<HexVisit>(predicate: predicate)).first
    }

    // MARK: - New hex creation

    @Test("first imported ping creates a HexVisit with count 1 and firstVisited == lastVisited == ping timestamp")
    func firstImportedPingCreatesHexVisitWithCountOne() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(
            timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hv = try #require(try fetchHex(ctx, hex(Self.athens.lat, Self.athens.lon)))
        #expect(hv.visitCount == 1)
        #expect(hv.firstVisited == Self.base)
        #expect(hv.lastVisited == Self.base)
    }

    @Test("two imported pings in two different hexes → two HexVisit rows, each count 1")
    func consecutiveDistinctImportedHexesEachCountAsNewVisit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(200), latitude: Self.ioannina.lat, longitude: Self.ioannina.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hvA = try #require(try fetchHex(ctx, hex(Self.athens.lat, Self.athens.lon)))
        let hvB = try #require(try fetchHex(ctx, hex(Self.ioannina.lat, Self.ioannina.lon)))
        #expect(hvA.visitCount == 1)
        #expect(hvB.visitCount == 1)
    }

    // MARK: - Reentry semantics on the import cursor

    @Test("reentry to a different imported hex (A → B → A) increments hex A's count to 2")
    func reentryToDifferentImportedHexIncrementsCount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        // A (Athens) → B (Ioánnina) → A (Athens). Timestamps far enough
        // apart that none dedup against each other.
        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(1000), latitude: Self.ioannina.lat, longitude: Self.ioannina.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(2000), latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hvA = try #require(try fetchHex(ctx, hex(Self.athens.lat, Self.athens.lon)))
        #expect(hvA.visitCount == 2)
    }

    @Test("same hex back-to-back does not double-count; isNewHex false on the 2nd ping")
    func sameImportedHexConsecutivelyDoesNotDoubleCount() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        // Two non-duplicate pings in the SAME res-6 hex: base and base+200 s
        // (outside the 90 s dedup window), ~278 m apart (>200 m spatial), still
        // the same ~36 km² res-6 cell.
        let p1 = (lat: Self.athens.lat, lon: Self.athens.lon)
        let p2 = (lat: Self.athens.lat + 0.0025, lon: Self.athens.lon)
        // Confirm the fixture really keeps both pings in one hex; if not, the
        // assertion would be meaningless.
        try #require(hex(p1.lat, p1.lon) == hex(p2.lat, p2.lon))

        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: p1.lat, longitude: p1.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(200), latitude: p2.lat, longitude: p2.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hv = try #require(try fetchHex(ctx, hex(p1.lat, p1.lon)))
        #expect(hv.visitCount == 1)
    }

    // MARK: - firstVisited backward / lastVisited forward extension

    @Test("import extends firstVisited backward when a later import carries an earlier timestamp")
    func importExtendsFirstVisitedBackward() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        // Seed the hex via a first import at `base`.
        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        // Record an EARLIER ping in the same hex (base-3600), spatially distinct
        // (>200 m) so it isn't deduped; well outside the 90 s window anyway.
        let earlier = at(-3600)
        _ = try await rec.recordImportedPing(timestamp: earlier, latitude: Self.athens.lat + 0.0025, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hv = try #require(try fetchHex(ctx, hex(Self.athens.lat, Self.athens.lon)))
        #expect(hv.firstVisited == earlier)
    }

    @Test("import extends lastVisited forward when a later import carries a later timestamp")
    func importExtendsLastVisitedForward() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        let later = at(3600)
        _ = try await rec.recordImportedPing(timestamp: later, latitude: Self.athens.lat + 0.0025, longitude: Self.athens.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hv = try #require(try fetchHex(ctx, hex(Self.athens.lat, Self.athens.lon)))
        #expect(hv.lastVisited == later)
    }

    // MARK: - resetLastImportedH3Index

    @Test("resetLastImportedH3Index makes the next same-hex ping count as a new visit")
    func resetLastImportedH3IndexMakesNextSameHexPingCountAgain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        let p1 = (lat: Self.athens.lat, lon: Self.athens.lon)
        let p2 = (lat: Self.athens.lat + 0.0025, lon: Self.athens.lon)
        try #require(hex(p1.lat, p1.lon) == hex(p2.lat, p2.lon))

        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: p1.lat, longitude: p1.lon, horizontalAccuracy: 10)
        await rec.resetLastImportedH3Index()
        // Same hex, non-duplicate (>200 m, >90 s); but the cursor was cleared,
        // so this counts as a fresh new-hex visit.
        _ = try await rec.recordImportedPing(timestamp: at(200), latitude: p2.lat, longitude: p2.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let hv = try #require(try fetchHex(ctx, hex(p1.lat, p1.lon)))
        #expect(hv.visitCount == 2)
    }
}
