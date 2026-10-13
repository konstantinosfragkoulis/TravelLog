//
//  PingRecorderDedupTests.swift
//  TravelLogTests
//
//  Exercises PingRecorder's import-path dedup (recordImportedPings via
//  ImportDedupIndex, the source-aware import thresholds), the batch flush
//  (saveImportBatch), and the count accessors (totalPingCount / totalHexCount).
//  The dedup fetch has no fetchLimit and must scan the
//  whole ±window so a near-duplicate beyond the first 5 rows is still caught.
//  recordImportedPing does NO geocoding and NO travel notifications, so these
//  tests never touch GeocodeResolver and are fully deterministic.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model types (LocationPing, HexVisit) and their
//  members MainActor-isolated; the suite constructs the container and fetches
//  @Model rows for assertions.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder import dedup & drain")
struct PingRecorderDedupTests {

    // MARK: - Fixtures

    /// Athens city centre.
    nonisolated static let athens = (lat: 37.9838, lon: 23.7275)
    /// Ioánnina is over 300 km from Athens, always a distinct res-6 hex and
    /// well beyond any spatial dedup threshold.
    nonisolated static let ioannina = (lat: 39.6628, lon: 20.8612)

    /// Fixed reference timestamp so all ±window arithmetic is deterministic.
    static let base = Date(timeIntervalSince1970: 1_626_006_400)

    private func recorder() throws -> PingRecorder {
        PingRecorder(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Self.base.addingTimeInterval(seconds)
    }

    // MARK: - First-ping & exact-duplicate

    @Test("first imported ping on an empty store is accepted (no-prior-ping path → not duplicate)")
    func firstImportedPingIsAccepted() async throws {
        let rec = try recorder()
        let accepted = try await rec.recordImportedPing(
            timestamp: Self.base,
            latitude: Self.athens.lat,
            longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        #expect(accepted == true)
        let count = await rec.totalPingCount()
        #expect(count == 1)
    }

    // MARK: - Second ping against one Athens ping at base

    /// The import window is 90 s (not the 60 s live default) and the import
    /// spatial threshold is 200 m. 1° latitude is about 111 km.
    struct SecondPing: Sendable, CustomTestStringConvertible {
        let name: String
        let offset: TimeInterval
        let latitude: Double
        let longitude: Double
        let accepted: Bool
        let count: Int
        var testDescription: String { name }
    }

    nonisolated static let secondPings: [SecondPing] = [
        SecondPing(name: "exact duplicate (same timestamp + coords) within the window is rejected",
                   offset: 0, latitude: athens.lat, longitude: athens.lon,
                   accepted: false, count: 1),
        SecondPing(name: "ping at base+89 s same spot is rejected, inside the 90 s import window (not the 60 s live default)",
                   offset: 89, latitude: athens.lat, longitude: athens.lon,
                   accepted: false, count: 1),
        SecondPing(name: "ping at base+91 s same spot is accepted, 1 s beyond the 90 s window, not even a candidate",
                   offset: 91, latitude: athens.lat, longitude: athens.lon,
                   accepted: true, count: 2),
        SecondPing(name: "within time but over 300 km away is accepted, beyond the 200 m import spatial threshold",
                   offset: 10, latitude: ioannina.lat, longitude: ioannina.lon,
                   accepted: true, count: 2),
        // 0.00135° latitude is about 150 m north.
        SecondPing(name: "within time and ~150 m away is rejected, distance < 200 m import threshold triggers dedup",
                   offset: 10, latitude: athens.lat + 0.00135, longitude: athens.lon,
                   accepted: false, count: 1),
        // 0.00225° latitude is about 250 m north.
        SecondPing(name: "within time and ~250 m away is accepted, distance ≥ 200 m means not a duplicate",
                   offset: 10, latitude: athens.lat + 0.00225, longitude: athens.lon,
                   accepted: true, count: 2),
    ]

    @Test("a second imported ping near the first is admitted or deduped", arguments: secondPings)
    func secondImportedPing(row: SecondPing) async throws {
        let rec = try recorder()
        _ = try await rec.recordImportedPing(
            timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        let second = try await rec.recordImportedPing(
            timestamp: at(row.offset), latitude: row.latitude, longitude: row.longitude,
            horizontalAccuracy: 10
        )
        #expect(second == row.accepted)
        let count = await rec.totalPingCount()
        #expect(count == row.count)
    }

    // MARK: - Scan the whole window, not just the first 5 rows

    @Test("dedup scans ALL rows in the window; a near-duplicate beyond the first 5 is still caught")
    func dedupScansAllRowsInWindowNotJustFirstFive() async throws {
        let rec = try recorder()
        // Insert 6 DISTINCT non-duplicate pings, all within the same ±90 s
        // window of `base`, each ≥ ~250 m apart so none dedup against another.
        // 0.0025° lat ≈ 278 m of vertical separation between consecutive pings.
        for i in 0..<6 {
            let accepted = try await rec.recordImportedPing(
                timestamp: at(Double(i)),                 // 0,1,2,3,4,5 s; all in window
                latitude: Self.athens.lat + Double(i) * 0.0025,
                longitude: Self.athens.lon,
                horizontalAccuracy: 10
            )
            #expect(accepted == true)
        }
        let afterSix = await rec.totalPingCount()
        #expect(afterSix == 6)

        // 7th duplicates the LAST-inserted ping (i == 5). It must be rejected,
        // proving the fetch has no fetchLimit and scanned the whole window.
        let seventh = try await rec.recordImportedPing(
            timestamp: at(5),
            latitude: Self.athens.lat + 5 * 0.0025,
            longitude: Self.athens.lon,
            horizontalAccuracy: 10
        )
        #expect(seventh == false)
        let final = await rec.totalPingCount()
        #expect(final == 6)
    }

    // MARK: - Batch flush + statistics

    @Test("saveImportBatch flushes accumulated inserts; a fresh context sees all N rows")
    func saveImportBatchPersistsAccumulatedPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        // Three distinct (non-duplicate) imported pings, no save in between.
        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(200), latitude: Self.ioannina.lat, longitude: Self.ioannina.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(400), latitude: 47.0, longitude: 8.0, horizontalAccuracy: 10) // Switzerland-ish, distinct hex

        try await rec.saveImportBatch()

        let ctx = ModelContext(container)
        let fetched = try ctx.fetch(FetchDescriptor<LocationPing>())
        #expect(fetched.count == 3)
    }

    @Test("totalPingCount and totalHexCount reflect inserts across two distinct hexes")
    func totalPingCountAndHexCountReflectInserts() async throws {
        let rec = try recorder()
        _ = try await rec.recordImportedPing(timestamp: Self.base, latitude: Self.athens.lat, longitude: Self.athens.lon, horizontalAccuracy: 10)
        _ = try await rec.recordImportedPing(timestamp: at(200), latitude: Self.ioannina.lat, longitude: Self.ioannina.lon, horizontalAccuracy: 10)
        try await rec.saveImportBatch()

        let pingCount = await rec.totalPingCount()
        let hexCount = await rec.totalHexCount()
        #expect(pingCount == 2)
        #expect(hexCount == 2)
    }
}
