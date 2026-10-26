//
//  PingRecorderBatchImportTests.swift
//  TravelLogTests
//
//  Pins the semantics of the batch import API `recordImportedPings(_:)` and
//  the session dedup index (`beginImportDedupSession` /
//  `endImportDedupSession`) added for import performance. The batch path
//  must behave exactly like N sequential `recordImportedPing` calls:
//  dedup against pre-existing store rows, dedup WITHIN a batch (an accepted
//  ping must shadow later near-duplicates in the same call), dedup across
//  batches within one session via the in-memory index, and pre-attach into
//  host Stays — including a host whose window only covers the second ping
//  because the first ping extended it.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model types and their members
//  MainActor-isolated; the suite seeds rows and re-fetches for assertions.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder batch import & session dedup index")
struct PingRecorderBatchImportTests {

    // MARK: - Fixtures

    nonisolated static let athens = (lat: 37.9838, lon: 23.7275)
    nonisolated static let ioannina = (lat: 39.6628, lon: 20.8612)

    static let base = Date(timeIntervalSince1970: 1_627_820_800)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.base.addingTimeInterval(seconds)
    }

    private func candidate(
        _ seconds: TimeInterval,
        lat: Double = athens.lat,
        lon: Double = athens.lon
    ) -> ImportedPingCandidate {
        ImportedPingCandidate(
            timestamp: at(seconds), latitude: lat, longitude: lon,
            horizontalAccuracy: 10
        )
    }

    /// Seed one saved LocationPing so the recorder's own context can see it.
    private func seedPing(
        in container: ModelContainer,
        at timestamp: Date,
        lat: Double = athens.lat,
        lon: Double = athens.lon
    ) throws {
        let ctx = ModelContext(container)
        let hex = H3Service.cellIndex(latitude: lat, longitude: lon)!
        ctx.insert(LocationPing(
            timestamp: timestamp, latitude: lat, longitude: lon,
            horizontalAccuracy: 10, h3IndexRes6: hex, source: .photoImport
        ))
        try ctx.save()
    }

    // MARK: - Batch dedup vs the store (no session index → fetch fallback)

    @Test("batch dedups against a pre-existing saved ping and accepts the fresh one")
    func batchDedupsAgainstStore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedPing(in: container, at: Self.base)
        let rec = PingRecorder(modelContainer: container)

        // 30 s after the seeded Athens ping (inside 90 s / 200 m) → dup.
        // Ioánnina about 311 km away → fresh.
        let accepted = try await rec.recordImportedPings([
            candidate(30),
            candidate(40, lat: Self.ioannina.lat, lon: Self.ioannina.lon)
        ])

        #expect(accepted == 1)
        let total = await rec.totalPingCount()
        #expect(total == 2)
    }

    @Test("within-batch self-dedup: an accepted ping shadows later near-duplicates in the same call")
    func withinBatchSelfDedup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        // A accepted; A' (+30 s, same spot) must dedup against the
        // just-inserted A even though nothing has been saved yet; B is far
        // in time and space and must be accepted.
        let accepted = try await rec.recordImportedPings([
            candidate(0),
            candidate(30),
            candidate(36_000, lat: Self.ioannina.lat, lon: Self.ioannina.lon)
        ])

        #expect(accepted == 2)
        let total = await rec.totalPingCount()
        #expect(total == 2)
    }

    @Test("a failed dedup-window read throws and leaves nothing to save")
    func dedupWindowReadFailureThrows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedPing(in: container, at: Self.base)
        let rec = PingRecorder(modelContainer: container)

        await rec.setFailNextImportDedupFetchForTesting(true)
        await #expect(throws: (any Error).self) {
            try await rec.recordImportedPings([candidate(30)], source: .gpxImport)
        }
        try await rec.saveImportBatch()
        let total = await rec.totalPingCount()
        #expect(total == 1)
    }

    @Test("empty batch is a no-op")
    func emptyBatchIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)
        let accepted = try await rec.recordImportedPings([])
        #expect(accepted == 0)
    }

    // MARK: - Session index

    @Test("session index dedups against rows that existed when the session began")
    func sessionIndexSeesPreexistingRows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedPing(in: container, at: Self.base)
        let rec = PingRecorder(modelContainer: container)

        await rec.beginImportDedupSession()
        let accepted = try await rec.recordImportedPings([candidate(30)])
        await rec.endImportDedupSession()

        #expect(accepted == 0)
        let total = await rec.totalPingCount()
        #expect(total == 1)
    }

    @Test("session index carries batch 1's inserts into batch 2's dedup (no save in between)")
    func sessionIndexCarriesAcrossBatches() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        await rec.beginImportDedupSession()
        let first = try await rec.recordImportedPings([candidate(0)])
        let second = try await rec.recordImportedPings([candidate(30)])
        await rec.endImportDedupSession()

        #expect(first == 1)
        #expect(second == 0)
        let total = await rec.totalPingCount()
        #expect(total == 1)
    }

    @Test("ending the session restores fetch-based dedup (still correct after save)")
    func endSessionFallsBackToFetchDedup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        await rec.beginImportDedupSession()
        _ = try await rec.recordImportedPings([candidate(0)])
        try await rec.saveImportBatch()
        await rec.endImportDedupSession()

        // No session index any more — the fallback window fetch must still
        // see the saved ping and dedup against it.
        let accepted = try await rec.recordImportedPings([candidate(30)])
        #expect(accepted == 0)
    }

    // MARK: - Pre-attach through the batch path

    @Test("two batch pings attach to the same host Stay; the second sees the window the first extended")
    func batchPreAttachWithWindowGrowth() async throws {
        let container = try TestSupport.makeInMemoryContainer()

        // Host Stay: Athens, base ... base+1h. StayClusterer's pre-attach
        // window pads ±4 h, so ping P1 at +4.5 h is OUTSIDE the original
        // envelope's end (1 h + 4 h = 5 h → +4.5 h is inside, use further):
        // P1 at +4 h (inside +5 h cap) extends endTime to +4 h; P2 at +7.5 h
        // is inside the EXTENDED envelope (+4 h + 4 h = +8 h) but outside
        // the original one (+5 h). Both must attach.
        let ctx = ModelContext(container)
        let hex = H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon)!
        let stay = Stay(
            startTime: Self.base, endTime: at(3600),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0,
            pingIDs: [UUID()], source: .liveSLC
        )
        ctx.insert(stay)
        try ctx.save()
        let stayID = stay.id

        let rec = PingRecorder(modelContainer: container)
        let accepted = try await rec.recordImportedPings([
            candidate(4 * 3600),        // extends endTime to +4 h
            candidate(7.5 * 3600)       // only inside the extended envelope
        ])
        try await rec.saveImportBatch()

        #expect(accepted == 2)
        let freshCtx = ModelContext(container)
        let predicate = #Predicate<Stay> { $0.id == stayID }
        let refetched = try #require(try freshCtx.fetch(FetchDescriptor<Stay>(predicate: predicate)).first)
        #expect(refetched.pingCount == 3)
        #expect(refetched.source == .merged)
        #expect(refetched.endTime == at(7.5 * 3600))
    }

    // MARK: - Provenance (Timeline import)

    @Test("the source parameter stamps pings — .timelineImport rows are distinct from .photoImport")
    func sourceParameterStampsPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        let accepted = try await rec.recordImportedPings(
            [candidate(0)], source: .timelineImport
        )
        // Default parameter stays byte-identical to the photo path.
        let acceptedDefault = try await rec.recordImportedPings(
            [candidate(48 * 3600, lat: Self.ioannina.lat, lon: Self.ioannina.lon)]
        )
        try await rec.saveImportBatch()

        #expect(accepted == 1)
        #expect(acceptedDefault == 1)
        let freshCtx = ModelContext(container)
        let pings = try freshCtx.fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        ))
        #expect(pings.count == 2)
        #expect(pings.first?.source == .timelineImport)
        #expect(pings.last?.source == .photoImport)
    }
}
