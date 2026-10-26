//
//  PhotoImportStateDeduplicatorTests.swift
//  TravelLogTests
//
//  CloudKit-convergence deduplicator for the singleton-style PhotoImportState.
//  Pins the survivor rule: keep the SMALLEST immutable id.uuidString and
//  preserve the writer generation regardless of running status, plus order-independence and
//  run-twice idempotence (the determinism that lets two CloudKit devices
//  converge on one row).
//  Live multi-device sync is out of scope.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (PhotoImportState) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

// All dedup callers stay in this serialized suite because its lock is process-global.
@Suite(.serialized)
@MainActor
struct PhotoImportStateDeduplicatorTests {

    // MARK: - Fixtures

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
            .addingTimeInterval(20_563_200)
    }

    /// Build a PhotoImportState. The init sets startedAt=.now; override it by
    /// assignment so the test controls the absorption input.
    private func makeState(startedAt: Date, originDeviceID: String = "dev") -> PhotoImportState {
        let s = PhotoImportState(originDeviceID: originDeviceID)
        s.startedAt = startedAt
        return s
    }

    private func fetchAll(_ container: ModelContainer) throws -> [PhotoImportState] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<PhotoImportState>())
    }

    // MARK: - No-op / guard paths

    @Test("dedup passes for independent containers do not suppress each other")
    func independentContainersDoNotShareSingleFlight() async throws {
        let a = try TestSupport.makeInMemoryContainer()
        let b = try TestSupport.makeInMemoryContainer()
        for container in [a, b] {
            let context = ModelContext(container)
            context.insert(makeState(startedAt: utc(2026, 1, 1), originDeviceID: "a"))
            context.insert(makeState(startedAt: utc(2026, 1, 2), originDeviceID: "b"))
            try context.save()
        }
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            await PhotoImportStateDeduplicator.$beforeFetchForTesting.withValue({
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }) {
                await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: a)
            }
        }
        for await _ in entered.stream { break }
        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: b)
        release.continuation.yield(())
        _ = await first.value
        #expect(try fetchAll(a).count == 1)
        #expect(try fetchAll(b).count == 1)
    }

    @Test("empty store → returns without throwing, store empty (count>1 guard)")
    func emptyStoreIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try fetchAll(container).isEmpty)
    }

    @Test("single row survives untouched (count>1 guard)")
    func singleRowSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let s = makeState(startedAt: utc(2026, 1, 1))
        ctx.insert(s)
        let id = s.id
        try ctx.save()

        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
    }

    // MARK: - Collapse + survivor selection

    @Test("paused survivor retains its writer generation so its local journal remains valid")
    func smallestIdSurvivorPreservesPausedGeneration() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeState(startedAt: utc(2026, 5, 1))
        let b = makeState(startedAt: utc(2026, 1, 1))
        let c = makeState(startedAt: utc(2026, 3, 1))
        ctx.insert(a)
        ctx.insert(b)
        ctx.insert(c)
        a.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        b.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        c.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        a.status = .paused
        let expectedSurvivorID = a.id
        try ctx.save()

        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == expectedSurvivorID)
        // startedAt is now a writer-generation fence for paused sessions too.
        #expect(survivor.startedAt == utc(2026, 5, 1))
    }

    @Test("running smallest-id survivor keeps its session start while the earlier twin is deleted")
    func runningSurvivorPreservesStartedAt() async throws {
        for reversed in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let winner = makeState(startedAt: utc(2026, 5, 1), originDeviceID: "device-a")
            winner.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            winner.status = .running
            winner.processedAssetCount = 7
            winner.acceptedPingCount = 3
            winner.watermarkCreationDate = utc(2026, 4, 1)
            let twin = makeState(startedAt: utc(2026, 1, 1), originDeviceID: "device-b")
            twin.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            twin.status = .running
            for row in reversed ? [twin, winner] : [winner, twin] { context.insert(row) }
            try context.save()
            let expected = PhotoImportStateSnapshot(from: winner)

            await PipelineGate.shared.run(touching: [.photoImportState]) {
                await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
            }

            let rows = try fetchAll(container)
            #expect(rows.count == 1)
            let saved = PhotoImportStateSnapshot(from: try #require(rows.first))
            #expect(saved.id == expected.id)
            #expect(saved.startedAt == expected.startedAt)
            #expect(saved == expected)
        }
    }

    /// Two devices restoring one backup each hold both twins, in opposite
    /// local order: a pass on either keeps both, so their deletions can never
    /// add up to every copy, while checkpoint reads still select one row.
    @Test("UUID-twin maintenance keeps every twin and the row checkpoint reads select",
          arguments: [false, true])
    func uuidTwinSurvivorMatchesCheckpointSelection(reversed: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let a = makeState(startedAt: utc(2026, 1, 1), originDeviceID: "device-a")
        let b = makeState(startedAt: utc(2026, 1, 1), originDeviceID: "device-b")
        b.id = a.id
        for row in reversed ? [b, a] : [a, b] {
            context.insert(row)
            try context.save()
        }
        let selected = try #require(try PhotoImportStateSnapshot.fetchState(in: context))
        let selectedID = selected.persistentModelID
        #expect(selectedID == [a.persistentModelID, b.persistentModelID].min())
        selected.status = .running
        selected.startedAt = utc(2026, 5, 1)
        selected.processedAssetCount = 7
        selected.acceptedPingCount = 3
        selected.watermarkCreationDate = utc(2026, 4, 1)
        try context.save()
        let expected = PhotoImportStateSnapshot(from: selected)

        let twinIDs = Set([a.persistentModelID, b.persistentModelID])
        // A higher UUID is a strictly ranked duplicate every device drops.
        let higher = makeState(startedAt: utc(2026, 1, 1), originDeviceID: "device-c")
        higher.id = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        context.insert(higher)
        try context.save()

        for _ in 0..<2 {
            let completed = await PipelineGate.shared.runReturning(touching: [.photoImportState]) {
                await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
            }
            #expect(completed)
            let rows = try fetchAll(container)
            #expect(Set(rows.map(\.persistentModelID)) == twinIDs)
            let survivor = try #require(rows.first { $0.persistentModelID == selectedID })
            #expect(PhotoImportStateSnapshot(from: survivor) == expected)
            #expect(try PhotoImportStateSnapshot.fetchState(in: ModelContext(container))?.persistentModelID == selectedID)
        }
    }

    @Test("dedup preserves prepared checkpoints and lifecycle writes, but a real restart rejects them")
    func runningSessionContinuesAfterDedup() async throws {
        for status in [ImportStatus.paused, .completed] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let winner = makeState(startedAt: utc(2026, 5, 1), originDeviceID: "device-a")
            winner.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            winner.status = .running
            context.insert(winner)
            try context.save()
            let service = PhotoImportService(modelContainer: container)
            let expected = try #require(await service.currentState())
            let recorder = PingRecorder(modelContainer: container)
            let twin = makeState(startedAt: utc(2026, 1, 1), originDeviceID: "device-b")
            twin.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            twin.status = .running
            context.insert(twin)
            try context.save()

            await PipelineGate.shared.run(touching: [.photoImportState]) {
                await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
            }
            #expect(try fetchAll(container).count == 1)
            let afterDedup = try #require(await service.currentState())
            #expect(afterDedup.hasSameCheckpoint(as: expected))
            let candidate = ImportedPingCandidate(
                timestamp: utc(2026, 4, 1), latitude: 37.9838,
                longitude: 23.7275, horizontalAccuracy: 10
            )
            let checkpoint = PhotoImportCohortCheckpoint(
                processedIncrement: 5, creationDate: candidate.timestamp, legacyLocalIdentifier: nil
            )
            let committed = await PipelineGate.shared.runReturning(
                touching: [.photoImportState, .locationPing, .hexVisit, .stay, .trip]
            ) {
                do {
                    return try await recorder.commitPhotoImportBatch(
                        [candidate], expected: expected, checkpoint: checkpoint
                    )
                } catch {
                    Issue.record("Checkpoint commit failed: \(error)")
                    return nil as PhotoImportStateSnapshot?
                }
            }
            #expect(committed != nil)
            #expect(committed?.processedAssetCount == 5)
            #expect(committed?.acceptedPingCount == 1)
            #expect(committed?.watermarkCreationDate == candidate.timestamp)
            if status == .completed {
                await service.finishFinalizedImportForTesting(committed ?? expected)
            } else {
                await service.updateRunStatusForTesting(expected, to: status)
            }
            let saved = try #require(await service.currentState())
            #expect(saved.status == status)
            #expect((saved.completedAt != nil) == (status == .completed))
            #expect(saved.hasSameCheckpoint(as: committed ?? expected))
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)

            // Simulate a genuine restart, retaining UUID/origin and the old checkpoint
            // so only the new timestamp can reject the previous session's work.
            await PipelineGate.shared.run(touching: [.photoImportState]) {
                await MainActor.run {
                    do {
                        let restartContext = ModelContext(container)
                        let state = try #require(try restartContext.fetch(FetchDescriptor<PhotoImportState>()).first)
                        state.startedAt = expected.startedAt.addingTimeInterval(60)
                        state.status = .running
                        state.completedAt = nil
                        try restartContext.save()
                    } catch { Issue.record("Restart setup failed: \(error)") }
                }
            }
            let restarted = try #require(await service.currentState())
            let stale = committed ?? expected
            let rejected = await PipelineGate.shared.runReturning(touching: [.photoImportState]) {
                do {
                    return try await recorder.commitPhotoImportBatch([], expected: stale, checkpoint: checkpoint)
                } catch {
                    Issue.record("Stale checkpoint validation threw: \(error)")
                    return nil as PhotoImportStateSnapshot?
                }
            }
            #expect(rejected == nil)
            await service.updateRunStatusForTesting(stale, to: .paused)
            await service.finishFinalizedImportForTesting(stale)
            #expect(await service.currentState() == restarted)
        }
    }

    // MARK: - Idempotence + order independence

    @Test("running deduplicateAll twice → still exactly one row, same survivor id")
    func idempotentRunningTwiceStable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeState(startedAt: utc(2026, 1, 1)))
        ctx.insert(makeState(startedAt: utc(2026, 2, 1)))
        ctx.insert(makeState(startedAt: utc(2026, 3, 1)))
        try ctx.save()

        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
        let after1 = try fetchAll(container)
        #expect(after1.count == 1)
        let id1 = try #require(after1.first).id

        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: container)
        let after2 = try fetchAll(container)
        #expect(after2.count == 1)
        #expect(after2.first?.id == id1)
    }

    @Test("survivor id is independent of insertion order")
    func orderIndependentSurvivor() async throws {
        let t1 = utc(2026, 1, 1)
        let t2 = utc(2026, 2, 1)
        let t3 = utc(2026, 3, 1)

        // Store A: ascending insert order.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        let a1 = makeState(startedAt: t1)
        let a2 = makeState(startedAt: t2)
        let a3 = makeState(startedAt: t3)
        ctxA.insert(a1); ctxA.insert(a2); ctxA.insert(a3)
        try ctxA.save()
        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: containerA)
        let sA = try #require(try fetchAll(containerA).first)

        // Store B: descending insert order, same ids reused.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        let b3 = makeState(startedAt: t3); b3.id = a3.id
        let b2 = makeState(startedAt: t2); b2.id = a2.id
        let b1 = makeState(startedAt: t1); b1.id = a1.id
        ctxB.insert(b3); ctxB.insert(b2); ctxB.insert(b1)
        try ctxB.save()
        await PhotoImportStateDeduplicator.deduplicateAll(modelContainer: containerB)
        let sB = try #require(try fetchAll(containerB).first)

        #expect(sA.id == sB.id)
        #expect(sA.startedAt == sB.startedAt)
    }
}
