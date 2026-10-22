//
//  PingRecorderLiveSaveFailureTests.swift
//  TravelLogTests
//
//  A live ingest batch saves or rolls back as one unit. A failed save
//  discards its inserts, restores the live reentry cursor and never
//  publishes its pings to the photo session dedup index, so the bounded
//  retry buffer is the only owner of failed input: nothing beyond its
//  newest 200 candidates can be adopted by a later save, and a photo is
//  never deduplicated against a ping that did not land. Every result is
//  read through a fresh ModelContext over a file-backed store.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Live ingest save failure")
struct PingRecorderLiveSaveFailureTests {

    private let athens = (latitude: 37.9838, longitude: 23.7275)
    private let ioannina = (latitude: 39.6628, longitude: 20.8612)
    private let base = Date(timeIntervalSinceReferenceDate: 818_144_000)
    /// A fresh handle per read, so the recorder actor never shares the test's instance.
    private nonisolated var defaults: UserDefaults { TestSupport.liveFloorFreeDefaults }

    private func candidate(
        at timestamp: Date, _ place: (latitude: Double, longitude: Double)
    ) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: place.latitude, longitude: place.longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1, timestamp: timestamp),
            source: .foregroundStream)
    }

    private func pings(in container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp)]))
    }

    private func visitCounts(in container: ModelContainer) throws -> [String: Int] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.h3Index, $0.visitCount) })
    }

    @Test("a failed batch leaves no rows, and its retry matches a never-failed run")
    func failedBatchRollsBackAndRetriesOnce() async throws {
        let a = candidate(at: base, athens)
        let b = candidate(at: base.addingTimeInterval(120), ioannina)
        let c = candidate(at: base.addingTimeInterval(240), athens)

        let control = try TestSupport.makeInMemoryContainer()
        let controlRecorder = PingRecorder(modelContainer: control)
        await controlRecorder.processLocations([a, b, c], defaults: defaults)

        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextLiveSaveForTesting(true)
        let failed = await recorder.processLocations([a, b], defaults: defaults)
        #expect(failed.isSuperset(of: [.locationPing, .hexVisit, .stay]),
                "a failed unit still fails open to its declared changes")
        #expect(try pings(in: container).isEmpty)
        #expect(try visitCounts(in: container).isEmpty)

        await recorder.processLocations([c], defaults: defaults)
        #expect(try pings(in: container).map(\.timestamp) == [a.timestamp, b.timestamp, c.timestamp])
        #expect(try visitCounts(in: container) == visitCounts(in: control))
    }

    @Test("a rolled-back batch restores the durable reentry cursor")
    func rollbackRestoresDurableCursor() async throws {
        let suite = "live-save-failure-\(UUID().uuidString)"
        let suiteDefaults = try #require(UserDefaults(suiteName: suite))
        suiteDefaults.removePersistentDomain(forName: suite)
        defer { suiteDefaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let athensCell = try #require(H3Service.cellIndex(
            latitude: athens.latitude, longitude: athens.longitude))
        let context = ModelContext(container)
        context.insert(LocationPing(
            timestamp: base, latitude: athens.latitude, longitude: athens.longitude,
            horizontalAccuracy: 10, h3IndexRes6: athensCell, source: .liveSLC))
        context.insert(HexVisit(
            h3Index: athensCell, firstVisited: base,
            centerLatitude: athens.latitude, centerLongitude: athens.longitude))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.restoreLastH3Index()
        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations(
            [candidate(at: base.addingTimeInterval(600), ioannina)], defaults: UserDefaults(suiteName: suite)!)

        // Retire the failed fix without replaying it, then stay in Athens.
        suiteDefaults.set(base.addingTimeInterval(601), forKey: PingRecorder.liveAcceptanceFloorKey)
        await recorder.processLocations(
            [candidate(at: base.addingTimeInterval(1_200), athens)], defaults: UserDefaults(suiteName: suite)!)

        #expect(try visitCounts(in: container) == [athensCell: 1],
                "the cursor must describe committed rows, not the rolled-back Ioánnina fix")
        #expect(try pings(in: container).count == 2)
    }

    @Test("consecutive failures keep exactly the newest 200 candidates")
    func retryBufferBoundsFailedInput() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        // 61 s apart: outside the 60 s live dedup window at one place.
        let fixes = (0..<251).map {
            candidate(at: base.addingTimeInterval(Double($0) * 61), athens)
        }

        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations(Array(fixes[0..<150]), defaults: defaults)
        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations(Array(fixes[150..<250]), defaults: defaults)
        #expect(try pings(in: container).isEmpty)

        await recorder.processLocations([fixes[250]], defaults: defaults)
        let saved = try pings(in: container).map(\.timestamp)
        #expect(saved == fixes[50...].map(\.timestamp),
                "dropped candidates must not persist through unsaved context residue")
    }

    @Test("a photo is never deduplicated against a rolled-back live ping")
    func rolledBackLivePingDoesNotDedupPhotos() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.beginImportDedupSession()

        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations([candidate(at: base, athens)], defaults: defaults)
        let accepted = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: base, latitude: athens.latitude,
                longitude: athens.longitude, horizontalAccuracy: 10),
        ])
        try await recorder.saveImportBatch()
        #expect(accepted == 1)

        // A committed live ping still joins the session index.
        let later = base.addingTimeInterval(3_600)
        await recorder.processLocations([
            candidate(at: later, ioannina),
        ], defaults: defaults)
        let deduped = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: later, latitude: ioannina.latitude,
                longitude: ioannina.longitude, horizontalAccuracy: 10),
        ])
        #expect(deduped == 0)
        await recorder.endImportDedupSession()
    }

    /// Suspends the next live batch after its first (unsaved) insert, starts
    /// a photo dedup session there, then lets the batch finish.
    private func beginDedupSessionMidBatch(
        _ recorder: PingRecorder, batch: [LiveLocationCandidate], failSave: Bool
    ) async {
        let (reached, reachedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        await recorder.setAfterFirstLiveCandidateForTesting {
            reachedSignal.yield()
            for await _ in release { break }
        }
        await recorder.setFailNextLiveSaveForTesting(failSave)
        let live = Task { await recorder.processLocations(batch, defaults: self.defaults) }
        for await _ in reached { break }
        await recorder.beginImportDedupSession()
        releaseSignal.yield()
        _ = await live.value
    }

    @Test("a dedup session started mid-batch forgets the batch's rolled-back pings")
    func midBatchSessionForgetsRolledBackPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await beginDedupSessionMidBatch(recorder, batch: [
            candidate(at: base, athens),
            candidate(at: base.addingTimeInterval(120), ioannina),
        ], failSave: true)
        #expect(try pings(in: container).isEmpty)

        let accepted = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: base, latitude: athens.latitude,
                longitude: athens.longitude, horizontalAccuracy: 10),
        ])
        try await recorder.saveImportBatch()
        #expect(accepted == 1, "the photo must not be skipped against a ping that never landed")
        #expect(try pings(in: container).map(\.source) == [.photoImport])
        await recorder.endImportDedupSession()
    }

    @Test("a dedup session started mid-batch keeps the batch's committed pings")
    func midBatchSessionKeepsCommittedPings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let later = base.addingTimeInterval(120)
        await beginDedupSessionMidBatch(recorder, batch: [
            candidate(at: base, athens),
            candidate(at: later, ioannina),
        ], failSave: false)
        #expect(try pings(in: container).count == 2)

        let accepted = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: base, latitude: athens.latitude,
                longitude: athens.longitude, horizontalAccuracy: 10),
            ImportedPingCandidate(
                timestamp: later, latitude: ioannina.latitude,
                longitude: ioannina.longitude, horizontalAccuracy: 10),
        ])
        try await recorder.saveImportBatch()
        #expect(accepted == 0, "both committed live pings dedup their photo twins")
        #expect(try pings(in: container).count == 2)
        await recorder.endImportDedupSession()
    }

    @Test("a failed live unit leaves committed import rows alone")
    func durableImportSurvivesFailedLiveUnit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: base, latitude: ioannina.latitude,
                longitude: ioannina.longitude, horizontalAccuracy: 10),
        ])
        try await recorder.saveImportBatch()

        let live = candidate(at: base.addingTimeInterval(3_600), athens)
        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations([live], defaults: defaults)
        #expect(try pings(in: container).map(\.source) == [.photoImport])

        await recorder.processLocations(
            [candidate(at: base.addingTimeInterval(7_200), athens)], defaults: defaults)
        #expect(try pings(in: container).map(\.source)
                == [.photoImport, .foregroundStream, .foregroundStream])
    }

    @Test("retried fixes do not repeat the travel-notification check")
    func retriedFixesSkipNotificationCheck() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)

        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations([candidate(at: base, athens)], defaults: defaults)
        #expect(await recorder.travelNotificationCheckCountForTesting == 1)

        await recorder.processLocations(
            [candidate(at: base.addingTimeInterval(3_600), ioannina)], defaults: defaults)
        #expect(await recorder.travelNotificationCheckCountForTesting == 2)
        #expect(try pings(in: container).count == 2)
    }

    @Test("a failed HexVisit read rolls the batch back, and its retry restores the map row")
    func failedHexReadRollsBackAndRetries() async throws {
        let a = candidate(at: base, athens)
        let b = candidate(at: base.addingTimeInterval(120), ioannina)
        let c = candidate(at: base.addingTimeInterval(240), athens)

        let control = try TestSupport.makeInMemoryContainer()
        let controlRecorder = PingRecorder(modelContainer: control)
        await controlRecorder.processLocations([a, b, c], defaults: defaults)

        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        // Only the first fix's HexVisit read fails; the save itself would succeed.
        await recorder.setFailNextLiveHexReadForTesting(true)
        await recorder.processLocations([a, b], defaults: defaults)
        #expect(try pings(in: container).isEmpty)
        #expect(try visitCounts(in: container).isEmpty)
        // The batch still finished: each fix ran its notification check once.
        #expect(await recorder.travelNotificationCheckCountForTesting == 2)

        await recorder.processLocations([c], defaults: defaults)
        #expect(try pings(in: container).map(\.timestamp) == [a.timestamp, b.timestamp, c.timestamp])
        #expect(try visitCounts(in: container) == visitCounts(in: control))
        #expect(await recorder.travelNotificationCheckCountForTesting == 3)
    }
}
