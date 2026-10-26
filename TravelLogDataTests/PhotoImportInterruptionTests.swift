//
//  PhotoImportInterruptionTests.swift
//  TravelLogTests
//
//  A nonempty photo import interrupted mid-run, then resumed by a fresh
//  service after relaunch: the checkpoint stops before an unfinished
//  same-date cohort, the resumed run replays that cohort without duplicating
//  its pings, and finalization clusters every ping into stays.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import TravelLog

@MainActor
@Suite("Photo import interruption and resume", .serialized)
struct PhotoImportInterruptionTests {
    private static let assetCount = 120
    /// Assets 45..<55 share one creation date, straddling the first
    /// 50-asset batch.
    private static let cohort = 45..<55
    /// Assets that contribute no ping (a screenshot, a location-less photo).
    private static let rejected: Set<Int> = [10, 100]
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func creationDate(_ index: Int) -> Date {
        let slot = cohort.contains(index) ? cohort.lowerBound : index
        return origin.addingTimeInterval(Double(slot) * 600)
    }

    /// Ten minutes and about a kilometre apart, so import dedup never merges
    /// two distinct assets.
    private static let library: [PhotoImportService.AssetForTesting] = (0..<assetCount).map { index in
        let date = creationDate(index)
        let candidate = rejected.contains(index) ? nil : ImportedPingCandidate(
            timestamp: date,
            latitude: 37.90 + Double(index) * 0.01, longitude: 23.70,
            horizontalAccuracy: 10, altitude: nil, verticalAccuracy: nil)
        return PhotoImportService.AssetForTesting(creationDate: date, candidate: candidate)
    }

    private func run(
        _ service: PhotoImportService, in container: ModelContainer,
        afterBatch: (@Sendable (PhotoImportStateSnapshot) async -> Void)? = nil
    ) async -> ImportStatus {
        let pipeline = PhotoImportService.PipelineForTesting(
            recorder: PingRecorder(modelContainer: container),
            clusterer: StayClusterer(modelContainer: container))
        // Its own task, like the background handler's, so an expiry cancels
        // only this run.
        return await PhotoImportService.$readAccessForTesting.withValue(true) {
            await PhotoImportService.$libraryForTesting.withValue(Self.library) {
                await PhotoImportService.$pipelineForTesting.withValue(pipeline) {
                    await PhotoImportService.$afterBatchCommitForTesting.withValue(afterBatch) {
                        await Task { await service.runImportSession(progress: nil) }.value
                    }
                }
            }
        }
    }

    private func pings(_ container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
    }

    @Test("an interrupted import resumes after relaunch without duplicating or skipping pings")
    func interruptedImportResumesExactlyOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let accepted = Self.assetCount - Self.rejected.count

        let first = PhotoImportService(modelContainer: container)
        _ = try await first.prepareNewStateForTesting(originDeviceID: deviceID)
        await first.handleMemoryWarning()  // 50-asset batches
        // The background task expires once the first batch is durable.
        let interrupted = await run(first, in: container) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        #expect(interrupted == .paused)
        let paused = try #require(await first.currentState())
        #expect(paused.processedAssetCount == Self.cohort.lowerBound)
        #expect(paused.watermarkCreationDate == Self.creationDate(Self.cohort.lowerBound - 1))
        let firstBatchPings = 50 - Self.rejected.filter { $0 < 50 }.count
        #expect(paused.acceptedPingCount == firstBatchPings)
        #expect(try pings(container).count == firstBatchPings)

        let relaunched = PhotoImportService(modelContainer: container)
        _ = try await relaunched.prepareResumedStateForTesting(originDeviceID: deviceID)
        let resumed = await run(relaunched, in: container)
        #expect(resumed == .completed)
        let completed = try #require(await relaunched.currentState())
        #expect(completed.completedAt != nil)
        #expect(completed.processedAssetCount == Self.assetCount)
        #expect(completed.acceptedPingCount == accepted)

        let saved = try pings(container)
        #expect(saved.count == accepted)
        #expect(Set(saved.map(\.latitude)).count == accepted)
        #expect(saved.allSatisfy { $0.source == .photoImport && $0.isProcessed })
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) > 0)
    }

    @Test("a failed clustering save pauses the import instead of completing it")
    func clusteringSaveFailurePausesImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let accepted = Self.assetCount - Self.rejected.count

        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)
        let outcome = await StayClusterer.SaveTestHook.$beforeSave.withValue({
            throw CocoaError(.fileWriteUnknown)
        }) {
            await run(service, in: container)
        }
        #expect(outcome == .paused)
        let paused = try #require(await service.currentState())
        #expect(paused.completedAt == nil)
        #expect(paused.lastError == "importError.finalizationSaveFailed")
        #expect(paused.processedAssetCount == Self.assetCount)
        let saved = try pings(container)
        #expect(saved.count == accepted)
        #expect(saved.allSatisfy { !$0.isProcessed }, "durable pings wait for the next finalization")

        // Enumeration is already complete, so the resumed run finalizes again.
        let relaunched = PhotoImportService(modelContainer: container)
        _ = try await relaunched.prepareResumedStateForTesting(originDeviceID: deviceID)
        #expect(await run(relaunched, in: container) == .completed)
        #expect(try pings(container).allSatisfy { $0.isProcessed })
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) > 0)
    }

    @Test("a failed Visit backing read pauses finalization with pings unprocessed")
    func backingReadFailurePausesImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""

        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)
        let outcome = await StayClusterer.ReadTestHook.$beforeVisitBackingRead.withValue({
            throw CocoaError(.fileReadUnknown)
        }) {
            await run(service, in: container)
        }
        #expect(outcome == .paused)
        let paused = try #require(await service.currentState())
        #expect(paused.completedAt == nil)
        #expect(paused.lastError == "importError.finalizationSaveFailed")
        #expect(try pings(container).allSatisfy { !$0.isProcessed })
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 0)

        let relaunched = PhotoImportService(modelContainer: container)
        _ = try await relaunched.prepareResumedStateForTesting(originDeviceID: deviceID)
        #expect(await run(relaunched, in: container) == .completed)
        #expect(try pings(container).allSatisfy { $0.isProcessed })
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) > 0)
    }

    /// Runs the fixture import with a 50 ms finalization heartbeat and
    /// `hook` holding finalization open after clustering.
    private func runHoldingFinalization(
        _ service: PhotoImportService, in container: ModelContainer,
        hook: @escaping @Sendable () async -> Void
    ) async -> ImportStatus {
        await PhotoImportService.$finalizationHeartbeatIntervalForTesting.withValue(.milliseconds(50)) {
            await PhotoImportService.$afterFinalizationClusteringForTesting.withValue(hook) {
                await run(service, in: container)
            }
        }
    }

    @Test("finalization keeps a live import's heartbeat fresh", .timeLimit(.minutes(1)))
    func finalizationKeepsHeartbeatFresh() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)

        let outcome = await runHoldingFinalization(service, in: container) { @MainActor in
            guard let before = await service.currentState() else { Issue.record("no state row"); return }
            try? await Task.sleep(for: .milliseconds(400))
            guard let after = await service.currentState() else { Issue.record("no state row"); return }
            #expect(after.lastUpdated > before.lastUpdated)
            #expect(after.status == .running)
            #expect(!after.cancelRequested)
            #expect(after.hasSameCheckpoint(as: before))
        }
        #expect(outcome == .completed)
        let completed = try #require(await service.currentState())
        try await Task.sleep(for: .milliseconds(200))
        #expect(await service.currentState()?.lastUpdated == completed.lastUpdated,
                "no heartbeat lands after completion")
    }

    @Test("a finalization heartbeat never touches a cancelled or paused row",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func finalizationHeartbeatSkipsStoppedRow(pause: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)

        let outcome = await runHoldingFinalization(service, in: container) { @MainActor in
            guard let live = await service.currentState() else { Issue.record("no state row"); return }
            if pause {
                await service.updateRunStatusForTesting(live, to: .paused)
            } else {
                await service.cancel()
            }
            guard let stopped = await service.currentState() else { Issue.record("no state row"); return }
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await service.currentState()?.lastUpdated == stopped.lastUpdated)
        }
        #expect(outcome == (pause ? .paused : .cancelled))
    }
}
