//
//  PingRecorderAltitudeBackfillTests.swift
//  TravelLogTests
//
//  Pins the V13 re-import altitude backfill in `recordImportedPings(_:)`:
//  a re-imported photo that dedups against an existing ping must UPDATE that
//  ping's altitude (never create a duplicate), filling only rows that lack a
//  VALID altitude (nil OR an invalid `verticalAccuracy < 0` placeholder) and
//  never clobbering a real altitude. @MainActor for the same isolation reason
//  as the sibling import suites (MainActor-by-default makes @Model members
//  isolated; the suite seeds rows and re-fetches for assertions).
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("PingRecorder re-import altitude backfill")
struct PingRecorderAltitudeBackfillTests {

    nonisolated static let athens = (lat: 37.9838, lon: 23.7275)
    static let base = Date(timeIntervalSince1970: 1_604_233_600)
    private func at(_ s: TimeInterval) -> Date { Self.base.addingTimeInterval(s) }

    /// A re-import candidate at Athens, `s` seconds after `base`, carrying the
    /// given EXIF altitude/accuracy (within the 90 s / 200 m dedup envelope of a
    /// ping seeded at `base`).
    private func candidate(_ s: TimeInterval, altitude: Double?, verticalAccuracy: Double?) -> ImportedPingCandidate {
        ImportedPingCandidate(
            timestamp: at(s), latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10, altitude: altitude, verticalAccuracy: verticalAccuracy
        )
    }

    /// Seed one saved import ping (optionally with altitude) and return its id.
    @discardableResult
    private func seedPing(in container: ModelContainer, at timestamp: Date,
                          altitude: Double? = nil, verticalAccuracy: Double? = nil) throws -> UUID {
        let ctx = ModelContext(container)
        let hex = H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon)!
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10, h3IndexRes6: hex,
            altitude: altitude, verticalAccuracy: verticalAccuracy, source: .photoImport
        )
        ctx.insert(ping)
        try ctx.save()
        return ping.id
    }

    private func storedAltitude(of id: UUID, in container: ModelContainer) throws -> (altitude: Double?, vAcc: Double?) {
        let ctx = ModelContext(container)
        let predicate = #Predicate<LocationPing> { $0.id == id }
        let ping = try #require(try ctx.fetch(FetchDescriptor<LocationPing>(predicate: predicate)).first)
        return (ping.altitude, ping.verticalAccuracy)
    }

    @Test("a fresh imported ping stores the candidate's altitude")
    func newImportedPingStoresAltitude() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let rec = PingRecorder(modelContainer: container)

        let accepted = try await rec.recordImportedPings([candidate(0, altitude: 340, verticalAccuracy: 7)])
        try await rec.saveImportBatch()

        #expect(accepted == 1)
        #expect(await rec.totalPingCount() == 1)
        let ctx = ModelContext(container)
        let ping = try #require(try ctx.fetch(FetchDescriptor<LocationPing>()).first)
        #expect(ping.altitude == 340)               // EXIF altitude captured on the new ping
        #expect(ping.verticalAccuracy == 7)
        #expect(ping.source == .photoImport)
    }

    @Test("re-import backfills a nil-altitude ping and creates no duplicate")
    func backfillsNilAltitude() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedPing(in: container, at: Self.base)   // altitude nil (pre-V13 row)
        let rec = PingRecorder(modelContainer: container)

        let accepted = try await rec.recordImportedPings([candidate(30, altitude: 120, verticalAccuracy: 8)])
        try await rec.saveImportBatch()

        #expect(accepted == 0)                                 // deduped — no new ping inserted
        #expect(await rec.totalPingCount() == 1)               // no duplicate
        let a = try storedAltitude(of: id, in: container)
        #expect(a.altitude == 120)                             // backfilled from the EXIF candidate
        #expect(a.vAcc == 8)
    }

    @Test("re-import never overwrites an already-valid altitude")
    func doesNotOverwriteValidAltitude() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedPing(in: container, at: Self.base, altitude: 100, verticalAccuracy: 5)
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPings([candidate(30, altitude: 999, verticalAccuracy: 3)])
        try await rec.saveImportBatch()

        let a = try storedAltitude(of: id, in: container)
        #expect(a.altitude == 100)                             // unchanged
        #expect(a.vAcc == 5)
        #expect(await rec.totalPingCount() == 1)
    }

    @Test("a candidate with invalid altitude (verticalAccuracy < 0) does not backfill")
    func invalidCandidateDoesNotBackfill() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedPing(in: container, at: Self.base)   // altitude nil
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPings([candidate(30, altitude: 500, verticalAccuracy: -1)])
        try await rec.saveImportBatch()

        let a = try storedAltitude(of: id, in: container)
        #expect(a.altitude == nil)                             // an invalid reading adds nothing
        #expect(await rec.totalPingCount() == 1)
    }

    @Test("a valid EXIF re-import upgrades an invalid (non-nil) live altitude placeholder")
    func upgradesInvalidPlaceholder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        // Mimics a cell/Wi-Fi SLC fix: altitude present (0) but verticalAccuracy < 0.
        let id = try seedPing(in: container, at: Self.base, altitude: 0, verticalAccuracy: -1)
        let rec = PingRecorder(modelContainer: container)

        _ = try await rec.recordImportedPings([candidate(30, altitude: 75, verticalAccuracy: 6)])
        try await rec.saveImportBatch()

        let a = try storedAltitude(of: id, in: container)
        #expect(a.altitude == 75)                              // upgraded over the invalid placeholder
        #expect(a.vAcc == 6)
        #expect(await rec.totalPingCount() == 1)
    }
}
