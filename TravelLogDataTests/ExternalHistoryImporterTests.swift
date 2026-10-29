//
//  ExternalHistoryImporterTests.swift
//  TravelLogTests
//
//  Pins the external-import contract: pings that pre-attach into an existing
//  completed trip's stays must leave it with `.merged` provenance and a nil
//  (invalidated) summary, so the import must run
//  `recomputeAffectedTripSummaries` after classify. Fails on the pre-fix
//  SettingsView spine, which omitted that step.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; seeding uses hand-built prior state + actor-seam reads.
//

import Testing
import Foundation
import SwiftData
import os
@testable import TravelLog

@MainActor
// `.serialized`: every `record` call toggles the process-global
// `isImportRunning` flag, and the flag-clearing pin asserts on it directly.
// In-suite parallel execution could observe another test's `true`.
@Suite("ExternalHistoryImporter spine", .serialized)
struct ExternalHistoryImporterTests {

    @MainActor
    private final class StageCounter {
        var clustered = 0
        var classified = 0
        var generatedTitles = 0
        var reloadedWidgets = 0
    }

    nonisolated static let athens = (lat: 37.9838, lon: 23.7275)
    static let base = Date(timeIntervalSince1970: 1_573_388_800)

    /// No-op stages: the spine's own obligations (record, dedup-clear,
    /// summary recompute) run for real against the in-memory container.
    private var stubStages: ExternalHistoryImporter.Stages {
        ExternalHistoryImporter.Stages(
            cluster: { true }, classify: { true }, generateTitles: {}, reloadWidgets: {})
    }

    private func ping(_ secondsAfterBase: TimeInterval) -> TimelinePing {
        TimelinePing(
            timestamp: Self.base.addingTimeInterval(secondsAfterBase),
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 30
        )
    }

    /// The stage runs a unit on the shared gate itself: if `record` still
    /// wrapped the stage in that non-reentrant gate, this would deadlock and
    /// trip the time limit. No timer race against other suites holding the
    /// shared gate.
    @Test("the cluster stage can run its own gate before classification",
          .timeLimit(.minutes(1)))
    func clusterStageOwnsItsGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let gateCompleted = OSAllocatedUnfairLock(initialState: false)
        let stages = ExternalHistoryImporter.Stages(
            cluster: {
                await PipelineGate.shared.run(touching: []) {
                    gateCompleted.withLock { $0 = true }
                }
                return true
            },
            classify: { #expect(gateCompleted.withLock { $0 }); return true },
            generateTitles: {}, reloadWidgets: {})

        let outcome = await ExternalHistoryImporter.record(
            [ping(0)], source: .timelineImport, recorder: recorder, stages: stages)
        #expect(outcome.inserted == 1 && !outcome.saveFailed)
    }

    @Test("a pre-attaching import reconciles the host trip and flips provenance")
    func preAttachReconcilesTripAndFlipsProvenance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon))
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(7200),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 500,
            pingIDs: [UUID()]
        )
        let trip = Trip(startDate: Self.base)
        trip.isComplete = true
        trip.endDate = Self.base.addingTimeInterval(7200)
        ctx.insert(stay)
        ctx.insert(trip)
        stay.trip = trip
        try ctx.save()

        let recorder = PingRecorder(modelContainer: container)
        // One fix inside the stay's time window and distance envelope →
        // pre-attaches instead of minting a new unprocessed ping.
        let outcome = await ExternalHistoryImporter.record(
            [ping(3600)], source: .timelineImport,
            recorder: recorder, stages: stubStages
        )
        #expect(outcome.inserted == 1)
        #expect(!outcome.saveFailed)

        let verify = ModelContext(container)
        let freshTrip = try #require(try verify.fetch(FetchDescriptor<Trip>()).first)
        // The regression: the import skipped the affected-trip
        // reconciliation, so the trip kept provenance its stays no longer had.
        #expect(freshTrip.source == .merged)
        let freshStay = try #require(try verify.fetch(FetchDescriptor<Stay>()).first)
        #expect(freshStay.source == .merged)
    }

    @Test("pre-attach title invalidation completes before classification")
    func titleInvalidationPrecedesClassification() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(
            latitude: Self.athens.lat, longitude: Self.athens.lon))
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(7200),
            centroidLatitude: Self.athens.lat,
            centroidLongitude: Self.athens.lon,
            h3IndexRes6: hex, pingCount: 2, distanceFromHomeKm: 500,
            pingIDs: [UUID(), UUID()])
        stay.category = .destination
        stay.locality = "Athens"
        let trip = Trip(startDate: Self.base)
        trip.isComplete = true
        trip.endDate = stay.endTime
        trip.aiGeneratedTitle = "Old Athens Title"
        ctx.insert(stay)
        ctx.insert(trip)
        stay.trip = trip
        ctx.insert(TripTitleVariant(
            languageTag: "de", title: "Alter Athen-Titel",
            sourceTitle: "Old Athens Title", trip: trip))
        try ctx.save()

        let stages = ExternalHistoryImporter.Stages(
            cluster: { true },
            classify: {
                let current = try? ModelContext(container).fetch(
                    FetchDescriptor<Trip>()).first
                #expect(current != nil)
                if let current {
                    #expect(current.aiGeneratedTitle == "Athens")
                    #expect((current.localizedTitles ?? []).isEmpty)
                }
                return true
            },
            generateTitles: {},
            reloadWidgets: {})
        let recorder = PingRecorder(modelContainer: container)
        let outcome = await ExternalHistoryImporter.record(
            [ping(-1800)], source: .timelineImport,
            recorder: recorder, stages: stages)

        #expect(outcome.inserted == 1)
        #expect(!outcome.saveFailed)
    }

    @Test("an import that only dedups (zero inserted) leaves existing summaries alone")
    func zeroInsertedIsANoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon))
        // Seed the exact ping the import will offer, so it dedups away.
        ctx.insert(LocationPing(
            timestamp: Self.base.addingTimeInterval(3600),
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 10, h3IndexRes6: hex, source: .timelineImport
        ))
        let trip = Trip(startDate: Self.base)
        trip.isComplete = true
        trip.aiGeneratedSummary = "Untouched story."
        ctx.insert(trip)
        try ctx.save()

        let recorder = PingRecorder(modelContainer: container)
        let outcome = await ExternalHistoryImporter.record(
            [ping(3600)], source: .timelineImport,
            recorder: recorder, stages: stubStages
        )
        #expect(outcome.inserted == 0)
        #expect(!outcome.saveFailed)

        let verify = ModelContext(container)
        let freshTrip = try #require(try verify.fetch(FetchDescriptor<Trip>()).first)
        #expect(freshTrip.aiGeneratedSummary == "Untouched story.")
    }

    @Test("record() clears stale affected-trip IDs at start (photo-import parity)")
    func staleAffectedTripIDsAreClearedAtStart() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        // A stale ID left by an earlier interrupted import operation.
        // Pre-fix (no clear-at-start), it survives into this run and the
        // spine's recompute would nil the summary of a trip this import
        // never touched.
        await recorder.seedAffectedTripIDsForTesting([UUID()])

        _ = await ExternalHistoryImporter.record(
            [], source: .gpxImport, recorder: recorder, stages: stubStages
        )

        #expect(await recorder.affectedTripIDsForTesting().isEmpty)
    }
    // MARK: - Batching durability across 500-row gate units

    @Test("a 520-ping import crosses the 500 batch boundary: all inserted, order preserved")
    func multiBatchImportPreservesCountAndOrder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        // 300 s spacing clears every source's dedup window, so each ping is
        // genuinely unique; 520 > batchSize forces two gate units.
        let pings = (0..<520).map { ping(Double($0) * 300) }
        #expect(pings.count > ExternalHistoryImporter.batchSize)

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)

        #expect(outcome.inserted == 520)
        #expect(!outcome.saveFailed)
        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp)]))
        #expect(rows.count == 520)
        // Chronological order survives the batch split.
        #expect(rows.map(\.timestamp) == pings.map(\.timestamp))
        #expect(rows.allSatisfy { $0.sourceRaw == DataSource.timelineImport.rawValue })
    }

    @Test("dedup works ACROSS the batch boundary: batch 2's first ping dedups against batch 1's last")
    func crossBatchDedupCollapsesBoundaryDuplicate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        var pings = (0..<520).map { ping(Double($0) * 300) }
        // Index 500 opens batch 2; make it a near-duplicate (same coord,
        // +10 s) of batch 1's final ping. The cross-unit dedup window must
        // collapse it, the contract the per-unit flush exists to serve.
        pings[500] = TimelinePing(
            timestamp: pings[499].timestamp.addingTimeInterval(10),
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 30)

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)

        #expect(outcome.inserted == 519,
                "the boundary duplicate must dedup across gate units")
        #expect(!outcome.saveFailed)
        let verify = ModelContext(container)
        #expect(try verify.fetchCount(FetchDescriptor<LocationPing>()) == 519)
    }

    @Test("a later batch-save failure finalizes committed pings and reports partial failure")
    func partialSaveFailureRunsPostPipelineAndReportsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.failImportBatchSaveCallForTesting(2)
        let pings = (0..<520).map { ping(Double($0) * 300) }
        let counter = StageCounter()
        let stages = ExternalHistoryImporter.Stages(
            cluster: { counter.clustered += 1; return true },
            classify: { counter.classified += 1; return true },
            generateTitles: { counter.generatedTitles += 1 },
            reloadWidgets: { counter.reloadedWidgets += 1 })

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport,
            recorder: recorder, stages: stages)

        #expect(outcome.inserted == ExternalHistoryImporter.batchSize)
        #expect(outcome.saveFailed)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<LocationPing>()) == ExternalHistoryImporter.batchSize)
        #expect(counter.clustered == 1)
        #expect(counter.classified == 1)
        #expect(counter.generatedTitles == 1)
        #expect(counter.reloadedWidgets == 1)
        #expect(!ExternalHistoryImporter.isImportRunning)
    }

    @Test("hex read failures use the save-failure outcome and preserve only durable batches", arguments: [1, 2])
    func hexReadFailureRetriesWithoutLosingVisits(failingFetch: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.failImportHexFetchCallForTesting(failingFetch)
        let pings = (0..<520).map { ping(Double($0) * 300) }
        let counter = StageCounter()
        let stages = ExternalHistoryImporter.Stages(
            cluster: { counter.clustered += 1; return true },
            classify: { counter.classified += 1; return true },
            generateTitles: { counter.generatedTitles += 1 },
            reloadWidgets: { counter.reloadedWidgets += 1 })
        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stages)
        let durable = failingFetch == 1 ? 0 : ExternalHistoryImporter.batchSize
        #expect(outcome.inserted == durable)
        #expect(outcome.saveFailed)
        let failed = ModelContext(container)
        #expect(try failed.fetchCount(FetchDescriptor<LocationPing>()) == durable)
        #expect(try failed.fetchCount(FetchDescriptor<HexVisit>()) == (durable == 0 ? 0 : 1))
        let expectedStages = durable == 0 ? 0 : 1
        #expect(counter.clustered == expectedStages)
        #expect(counter.classified == expectedStages)
        #expect(counter.generatedTitles == expectedStages)
        #expect(counter.reloadedWidgets == expectedStages)
        #expect(!ExternalHistoryImporter.isImportRunning)

        let retry = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)
        #expect(retry.inserted == pings.count - durable)
        #expect(!retry.saveFailed)
        let retried = ModelContext(container)
        #expect(try retried.fetchCount(FetchDescriptor<LocationPing>()) == pings.count)
        let visits = try retried.fetch(FetchDescriptor<HexVisit>())
        #expect(visits.count == 1)
        let visit = try #require(visits.first)
        #expect(visit.visitCount == 1)
        #expect(visit.firstVisited == pings.first?.timestamp)
        #expect(visit.lastVisited == pings.last?.timestamp)
    }

    @Test("a failed dedup-window read saves nothing instead of duplicating the batch")
    func dedupWindowReadFailureInsertsNoDuplicates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let pings = (0..<520).map { ping(Double($0) * 300) }
        let seeded = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)
        #expect(seeded.inserted == pings.count && !seeded.saveFailed)

        await recorder.setFailNextImportDedupFetchForTesting(true)
        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)
        #expect(outcome.saveFailed)
        #expect(outcome.inserted == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == pings.count)
    }

    @Test("a failed host-stay read saves nothing and a retry pre-attaches")
    func hostStayReadFailureRetriesWithPreAttach() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon))
        let stay = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(7200),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 500,
            pingIDs: [UUID()]
        )
        ctx.insert(stay)
        try ctx.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextImportHostStayFetchForTesting(true)
        let failed = await ExternalHistoryImporter.record(
            [ping(3600)], source: .timelineImport, recorder: recorder, stages: stubStages)
        #expect(failed.saveFailed)
        #expect(failed.inserted == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)

        let retry = await ExternalHistoryImporter.record(
            [ping(3600)], source: .timelineImport, recorder: recorder, stages: stubStages)
        #expect(retry.inserted == 1 && !retry.saveFailed)
        let verify = ModelContext(container)
        let saved = try #require(try verify.fetch(FetchDescriptor<LocationPing>()).first)
        #expect(saved.isProcessed)
        let freshStay = try #require(try verify.fetch(FetchDescriptor<Stay>()).first)
        #expect(freshStay.pingIDs.contains(saved.id))
    }

    @Test("partial-failure finalization ignores the rolled-back batch's trips")
    func partialFailureFinalizesOnlyCommittedBatchTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let hostTime: TimeInterval = 1_000_000
        let hostStart = Self.base.addingTimeInterval(hostTime - 3_600)
        let hostEnd = Self.base.addingTimeInterval(hostTime + 3_600)
        let hex = try #require(H3Service.cellIndex(
            latitude: Self.athens.lat, longitude: Self.athens.lon))
        let stay = Stay(
            startTime: hostStart, endTime: hostEnd,
            centroidLatitude: Self.athens.lat,
            centroidLongitude: Self.athens.lon,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: 500, pingIDs: [UUID()])
        stay.category = .destination
        let trip = Trip(startDate: hostStart, source: .liveSLC)
        trip.isComplete = true
        trip.endDate = hostEnd
        trip.aiGeneratedSummary = "Committed summary"
        trip.summaryGeneratedAt = Self.base
        context.insert(stay)
        context.insert(trip)
        stay.trip = trip
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.failImportBatchSaveCallForTesting(2)
        var pings = (0..<ExternalHistoryImporter.batchSize).map {
            ping(Double($0) * 300)
        }
        // Only the failed second batch overlaps the seeded Trip. Its staged
        // pre-attach and reconciliation must disappear with the rollback.
        pings.append(ping(hostTime))

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport,
            recorder: recorder, stages: stubStages)

        #expect(outcome.inserted == ExternalHistoryImporter.batchSize)
        #expect(outcome.saveFailed)
        #expect(await recorder.affectedTripIDsForTesting().isEmpty)
        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedSummary == "Committed summary")
        #expect(reloaded.summaryGeneratedAt == Self.base)
        #expect(reloaded.source == .liveSLC)
    }

    @Test("isImportRunning is cleared after both the inserted and the all-deduped path")
    func importRunningFlagAlwaysClears() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        #expect(ExternalHistoryImporter.isImportRunning == false)

        _ = await ExternalHistoryImporter.record(
            [ping(0)], source: .gpxImport, recorder: recorder, stages: stubStages)
        #expect(ExternalHistoryImporter.isImportRunning == false)

        // Re-importing the same fix dedups to zero, the early-return path
        // must clear the flag too (it does, via defer; pin it so a future
        // restructure can't drop the defer).
        let second = await ExternalHistoryImporter.record(
            [ping(0)], source: .gpxImport, recorder: recorder, stages: stubStages)
        #expect(second.inserted == 0)
        #expect(!second.saveFailed)
        #expect(ExternalHistoryImporter.isImportRunning == false)
    }

    /// A corrupt Timeline file can carry a timestamp no Date arithmetic or
    /// Int64 bucket conversion survives. The recorder ingress drops it
    /// wherever it sits in the batch, and valid siblings still commit.
    @Test("corrupt timestamps are dropped at the import ingress without trapping",
          arguments: [0, 1, 2])
    func corruptTimestampsAreDroppedAtIngress(corruptPosition: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let corrupt = [
            TimelinePing(
                timestamp: Date(timeIntervalSinceReferenceDate: -6e31),
                latitude: Self.athens.lat, longitude: Self.athens.lon,
                horizontalAccuracy: 30),
            TimelinePing(
                timestamp: Date(timeIntervalSinceReferenceDate: .nan),
                latitude: Self.athens.lat, longitude: Self.athens.lon,
                horizontalAccuracy: 30),
        ]
        var pings = [ping(0), ping(600)]
        pings.insert(contentsOf: corrupt, at: corruptPosition)

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)

        #expect(outcome.inserted == 2)
        #expect(!outcome.saveFailed)
        let rows = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { PingRecorder.isImportableTimestamp($0.timestamp) })
    }

    @Test("an all-corrupt batch inserts nothing and reports no failure")
    func allCorruptBatchInsertsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let pings = [-6e31, 6e31, -Double.infinity, Double.nan].map {
            TimelinePing(
                timestamp: Date(timeIntervalSinceReferenceDate: $0),
                latitude: Self.athens.lat, longitude: Self.athens.lon,
                horizontalAccuracy: 30)
        }

        let outcome = await ExternalHistoryImporter.record(
            pings, source: .timelineImport, recorder: recorder, stages: stubStages)

        #expect(outcome.inserted == 0)
        #expect(!outcome.saveFailed)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<LocationPing>()) == 0)
    }

    /// The session index is built from every stored ping, bypassing the
    /// candidate filter. A stored extreme timestamp must not trap the Int64
    /// bucket conversion or its neighbour probe.
    @Test("a stored extreme timestamp neither traps the session index nor blocks valid imports")
    func storedExtremeTimestampDoesNotTrapSessionIndex() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(
            latitude: Self.athens.lat, longitude: Self.athens.lon))
        for seconds in [-6e31, 6e31] {
            context.insert(LocationPing(
                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                latitude: Self.athens.lat, longitude: Self.athens.lon,
                horizontalAccuracy: 30, h3IndexRes6: hex,
                source: .timelineImport))
        }
        try context.save()
        let recorder = PingRecorder(modelContainer: container)

        await recorder.beginImportDedupSession()
        let first = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: Self.base, latitude: Self.athens.lat,
                longitude: Self.athens.lon, horizontalAccuracy: 30),
        ], source: .timelineImport)
        try await recorder.saveImportBatch()
        // The session index still dedups the valid row it just admitted.
        let repeated = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: Self.base.addingTimeInterval(5),
                latitude: Self.athens.lat,
                longitude: Self.athens.lon, horizontalAccuracy: 30),
        ], source: .timelineImport)
        await recorder.endImportDedupSession()

        #expect(first == 1)
        #expect(repeated == 0)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<LocationPing>()) == 3)
    }

    @Test("the importable timestamp domain is finite and within distant past and future")
    func importableTimestampDomain() {
        #expect(PingRecorder.isImportableTimestamp(Self.base))
        #expect(PingRecorder.isImportableTimestamp(.distantPast))
        #expect(PingRecorder.isImportableTimestamp(.distantFuture))
        #expect(!PingRecorder.isImportableTimestamp(
            Date(timeIntervalSinceReferenceDate: -6e31)))
        #expect(!PingRecorder.isImportableTimestamp(
            Date(timeIntervalSinceReferenceDate: 6e31)))
        #expect(!PingRecorder.isImportableTimestamp(
            Date(timeIntervalSinceReferenceDate: .nan)))
        #expect(!PingRecorder.isImportableTimestamp(
            Date(timeIntervalSinceReferenceDate: .infinity)))
    }
}
