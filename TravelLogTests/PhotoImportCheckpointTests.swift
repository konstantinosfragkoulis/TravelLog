import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Photo import atomic checkpoints")
struct PhotoImportCheckpointTests {
    private let date = Date(timeIntervalSince1970: 1_631_449_600)

    private func fileBackedContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let configuration = ModelConfiguration(
            "PhotoCheckpointTests", schema: schema, url: url, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func seed(in container: ModelContainer) throws -> PhotoImportStateSnapshot {
        let context = ModelContext(container)
        let state = PhotoImportState(originDeviceID: "test-device")
        state.status = .running
        state.startedAt = date
        context.insert(state)
        try context.save()
        return PhotoImportStateSnapshot(from: state)
    }

    private func read(_ container: ModelContainer) throws -> PhotoImportStateSnapshot {
        try #require(try PhotoImportStateSnapshot.fetch(in: ModelContext(container)))
    }

    private func candidate(offset: TimeInterval = 0, latitude: Double = 37.9838) -> ImportedPingCandidate {
        ImportedPingCandidate(
            timestamp: date.addingTimeInterval(offset), latitude: latitude,
            longitude: 23.7275, horizontalAccuracy: 10
        )
    }

    private func checkpoint(processed: Int, offset: TimeInterval = 0) -> PhotoImportCohortCheckpoint {
        PhotoImportCohortCheckpoint(
            processedIncrement: processed, creationDate: date.addingTimeInterval(offset),
            legacyLocalIdentifier: nil
        )
    }

    private func commit(
        _ recorder: PingRecorder, _ candidates: [ImportedPingCandidate],
        expected: PhotoImportStateSnapshot, checkpoint: PhotoImportCohortCheckpoint
    ) async throws -> PhotoImportStateSnapshot? {
        let result: Result<PhotoImportStateSnapshot?, Error> = await PipelineGate.shared.runReturning(
            touching: [.locationPing, .hexVisit, .stay, .trip, .photoImportState]
        ) {
            do { return .success(try await recorder.commitPhotoImportBatch(candidates, expected: expected, checkpoint: checkpoint)) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    @Test("UUID twins mutate only the validated physical row in both insertion orders",
          arguments: [false, true])
    func uuidTwinWriteTarget(reverseInsertion: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try fileBackedContainer(at: directory.appendingPathComponent("twins.sqlite"))
        let context = ModelContext(container)
        let a = PhotoImportState(originDeviceID: "A")
        let b = PhotoImportState(originDeviceID: "B")
        b.id = a.id
        for row in reverseInsertion ? [b, a] : [a, b] {
            row.startedAt = date
            row.status = .running
            context.insert(row)
            try context.save()
        }
        let initial = try read(container)
        let recorder = PingRecorder(modelContainer: container)
        // Register the recorder's target before divergent values arrive.
        _ = try await commit(
            recorder, [], expected: initial,
            checkpoint: PhotoImportCohortCheckpoint(
                processedIncrement: 0, creationDate: nil, legacyLocalIdentifier: nil
            )
        )
        let otherContext = ModelContext(container)
        let rows = try otherContext.fetch(FetchDescriptor<PhotoImportState>())
        let other = try #require(rows.first { $0.persistentModelID != initial.persistentModelID })
        other.status = .cancelled
        other.processedAssetCount = 500
        other.acceptedPingCount = 500
        other.watermarkCreationDate = date.addingTimeInterval(9000)
        try otherContext.save()
        let untouched = PhotoImportStateSnapshot(from: other)
        let prepared = try read(container)
        #expect(prepared.persistentModelID == initial.persistentModelID)
        let inputs = [candidate()]
        let next = checkpoint(processed: 1)
        let committed = try await commit(recorder, inputs, expected: prepared, checkpoint: next)
        let savedRows = try ModelContext(container).fetch(FetchDescriptor<PhotoImportState>())
        let changed = savedRows.filter { $0.acceptedPingCount == 1 }
        #expect(changed.map(\.persistentModelID) == [prepared.persistentModelID])
        let savedOther = try #require(savedRows.first { $0.persistentModelID == untouched.persistentModelID })
        #expect(PhotoImportStateSnapshot(from: savedOther) == untouched)
        #expect(committed?.acceptedPingCount == 1)
        #expect(committed?.processedAssetCount == 1)
        #expect(committed?.persistentModelID == prepared.persistentModelID)
        let service = PhotoImportService(modelContainer: container)
        #expect(await service.currentState()?.persistentModelID == prepared.persistentModelID)
        await service.updateRunStatusForTesting(prepared, to: .paused)
        #expect(try read(container).status == .paused)
    }

    @Test("a physically replaced session cannot satisfy a prepared twin checkpoint")
    func replacedPhysicalCheckpoint() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let context = ModelContext(container)
        let old = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        let replacement = PhotoImportState(originDeviceID: initial.originDeviceID)
        replacement.id = initial.id
        replacement.startedAt = initial.startedAt
        replacement.status = .running
        context.insert(replacement)
        context.delete(old)
        try context.save()
        let recorder = PingRecorder(modelContainer: container)
        let inputs = [candidate()]
        let next = checkpoint(processed: 1)
        let result = try await commit(recorder, inputs, expected: initial, checkpoint: next)
        #expect(result == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
        let service = PhotoImportService(modelContainer: container)
        await service.updateRunStatusForTesting(initial, to: .paused)
        #expect(try read(container).status == .running)
    }

    @Test("post-save older checkpoint stops the cohort instead of ratifying regressed acceptance")
    func postSaveCheckpointRegression() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try fileBackedContainer(at: directory.appendingPathComponent("readback.sqlite"))
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        let service = PhotoImportService(modelContainer: container)
        let candidates = (0..<300).map { candidate(latitude: 30 + Double($0) * 0.01) }
        var cohorts = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        let first = try cohorts.advance(dates: Array(repeating: date, count: 200), nextDate: date, isAtEnd: false)
        let oldProcessed = initial.processedAssetCount
        let oldAccepted = initial.acceptedPingCount
        let oldDate = initial.watermarkCreationDate
        let oldIdentifier = initial.watermarkLocalIdentifier
        await recorder.setAfterPhotoImportSaveForTesting {
            let external = ModelContext(container)
            let state = try #require(try external.fetch(FetchDescriptor<PhotoImportState>()).first)
            let pingCount = try external.fetchCount(FetchDescriptor<LocationPing>())
            #expect(state.acceptedPingCount == pingCount)
            #expect(pingCount == 200)
            // Deliberately ungated: models a store merge inside the local gate.
            state.processedAssetCount = oldProcessed
            state.acceptedPingCount = oldAccepted
            state.watermarkCreationDate = oldDate
            state.watermarkLocalIdentifier = oldIdentifier
            try external.save()
        }
        let firstCandidates = Array(candidates.prefix(200))
        let committed = try await commit(recorder, firstCandidates, expected: initial, checkpoint: first)
        if let committed {
            // Complete the same production cohort and finalization boundaries
            // to expose the original 300-ping / 100-accepted ratification.
            let last = try cohorts.advance(dates: Array(repeating: date, count: 100), nextDate: nil, isAtEnd: true)
            let lastCandidates = Array(candidates.suffix(100))
            let final = try await commit(recorder, lastCandidates, expected: committed, checkpoint: last)
            await service.finishFinalizedImportForTesting(try #require(final))
        } else {
            await service.stopAfterCheckpointDriftForTesting(initial)
        }
        let saved = try read(container)
        let pings = try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>())
        #expect(committed == nil)
        #expect(saved.status == .paused)
        #expect(saved.completedAt == nil)
        #expect(saved.processedAssetCount == 0)
        #expect(saved.acceptedPingCount == 200) // Recover this writer's proven durable checkpoint.
        #expect(pings == 200) // The final 100 must never be submitted.
    }

    @Test("owner resume recovers durable acceptance and invalidates the previous run")
    func resumeRepairsDriftAndFencesOldRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try fileBackedContainer(at: directory.appendingPathComponent("resume.sqlite"))
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        let inputs = (0..<300).map { candidate(latitude: 30 + Double($0) * 0.01) }
        _ = try await commit(recorder, Array(inputs.prefix(200)), expected: initial,
            checkpoint: PhotoImportCohortCheckpoint(processedIncrement: 0, creationDate: nil, legacyLocalIdentifier: nil))
        let external = ModelContext(container)
        let regressed = try #require(try external.fetch(FetchDescriptor<PhotoImportState>()).first)
        regressed.acceptedPingCount = 0
        regressed.status = .paused
        try external.save()
        let service = PhotoImportService(modelContainer: container)
        let resumed = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
        #expect(resumed.acceptedPingCount == 200)
        #expect(resumed.startedAt != initial.startedAt)
        await service.updateRunStatusForTesting(initial, to: .paused)
        #expect(try read(container).status == .running)
        let finished = try #require(try await commit(recorder, inputs, expected: resumed,
            checkpoint: checkpoint(processed: 300)))
        #expect(finished.acceptedPingCount == 300)
        #expect(finished.processedAssetCount == 300)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.committed.startedAt == resumed.startedAt)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 300)
    }

    @Test("a foreign device may resume only a stalled session and then owns it")
    func foreignDeviceResumesOnlyStalledSession() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareResumedStateForTesting(originDeviceID: "other-device")
            Issue.record("A recently updated foreign session must not be taken over")
        } catch PhotoImportError.alreadyRunning {}
        #expect(try read(container) == initial)
        #expect(!initial.canResume(onDeviceID: "other-device"))
        #expect(initial.canResume(onDeviceID: initial.originDeviceID))

        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        row.lastUpdated = Date.now.addingTimeInterval(-PhotoImportService.foreignSessionTakeoverSeconds - 1)
        try context.save()
        let resumed = try await service.prepareResumedStateForTesting(originDeviceID: "other-device")
        #expect(resumed.originDeviceID == "other-device")
        #expect(resumed.startedAt != initial.startedAt)
        #expect(resumed.status == .running)
        #expect(resumed.canResume(onDeviceID: "other-device"))
        #expect(!resumed.canResume(onDeviceID: initial.originDeviceID))
    }

    @Test("a stale journal from an older generation is discarded instead of wedging Resume")
    func staleJournalGenerationIsIgnored() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        // The row advanced to a newer generation whose journal seed never landed.
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        row.startedAt = initial.startedAt.addingTimeInterval(5)
        row.acceptedPingCount = 40
        row.processedAssetCount = 40
        try context.save()
        var stale = PhotoImportCheckpointJournal.Checkpoint(initial)
        stale.accepted = 10
        stale.processed = 10
        try PhotoImportCheckpointJournal.seed(stale, in: container)
        let service = PhotoImportService(modelContainer: container)
        let resumed = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
        #expect(resumed.acceptedPingCount == 40)
        #expect(resumed.processedAssetCount == 40)
        #expect(resumed.startedAt > row.startedAt)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.committed.startedAt == resumed.startedAt)
    }

    @Test("a stale journal on a replaced physical row still fails closed")
    func staleJournalOnReplacedRowFailsClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        var stale = PhotoImportCheckpointJournal.Checkpoint(initial)
        stale.accepted = 10
        try PhotoImportCheckpointJournal.seed(stale, in: container)
        let context = ModelContext(container)
        let previous = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        let replacement = PhotoImportState(originDeviceID: previous.originDeviceID)
        replacement.id = previous.id
        replacement.startedAt = previous.startedAt.addingTimeInterval(5)
        replacement.status = .paused
        context.delete(previous)
        context.insert(replacement)
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
            Issue.record("A replaced row must not silently drop the previous row's journal")
        } catch PhotoImportError.inconsistentLocalData {}
        #expect(try PhotoImportCheckpointJournal.read(in: container) != nil)
        #expect(try read(container).status == .paused)
    }

    @Test("an unverifiable journal on a dead same-device session still allows a fresh start")
    func unverifiableJournalLeavesFreshStartAvailable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        // A journal from a newer generation than the row: an older synced
        // generation overwrote the local row, so recovery must fail closed.
        var newer = PhotoImportCheckpointJournal.Checkpoint(initial)
        newer.startedAt = initial.startedAt.addingTimeInterval(5)
        newer.accepted = 500
        try PhotoImportCheckpointJournal.seed(newer, in: container)
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
            Issue.record("A journal newer than the row must fail closed")
        } catch PhotoImportError.inconsistentLocalData {}
        #expect(try read(container) == initial)
        // The row is still `.running` for this device, but no loop is alive in
        // this process, so "Start fresh import" must succeed rather than throw.
        let fresh = try await service.prepareNewStateForTesting(originDeviceID: initial.originDeviceID)
        #expect(fresh.status == .running)
        #expect(fresh.acceptedPingCount == 0)
        #expect(fresh.startedAt > initial.startedAt)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.committed.startedAt == fresh.startedAt)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.committed.accepted == 0)
    }

    @Test("a fresh foreign running session cannot be restarted, a stalled one can")
    func foreignRestartRespectsTakeoverWindow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        _ = try seed(in: container)
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareNewStateForTesting(originDeviceID: "other-device")
            Issue.record("A recently updated foreign session must not be restarted")
        } catch PhotoImportError.alreadyRunning {}
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        row.lastUpdated = Date.now.addingTimeInterval(-PhotoImportService.foreignSessionTakeoverSeconds - 1)
        try context.save()
        let restarted = try await service.prepareNewStateForTesting(originDeviceID: "other-device")
        #expect(restarted.originDeviceID == "other-device")
        #expect(restarted.processedAssetCount == 0)
    }

    @Test("a failed journal write prevents the database batch from committing")
    func journalWriteFailurePreventsBatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await PhotoImportCheckpointJournal.$failWriteForTesting.withValue(true) {
            do {
                _ = try await recorder.commitPhotoImportBatch([candidate()], expected: initial,
                    checkpoint: checkpoint(processed: 1))
                Issue.record("The journal write must fail before save")
            } catch {}
        }
        #expect(try read(container) == initial)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
    }

    @Test("durable pending batch recovers after final journal write fails and the store reopens")
    func pendingJournalRecoversAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending.sqlite")
        let container = try fileBackedContainer(at: url)
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await PhotoImportCheckpointJournal.$failSeedForTesting.withValue(true) {
            do {
                _ = try await recorder.commitPhotoImportBatch([candidate()], expected: initial,
                    checkpoint: checkpoint(processed: 1))
                Issue.record("Final journal write should fail after the database save")
            } catch {}
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.pending != nil)
        let reopened = try fileBackedContainer(at: url)
        let context = ModelContext(reopened)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.acceptedPingCount = 0
        state.processedAssetCount = 0
        state.watermarkCreationDate = nil
        state.status = .paused
        try context.save()
        let service = PhotoImportService(modelContainer: reopened)
        let resumed = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
        #expect(resumed.acceptedPingCount == 1)
        #expect(resumed.processedAssetCount == 1)
        #expect(resumed.watermarkCreationDate == date)
        #expect(try PhotoImportCheckpointJournal.read(in: reopened)?.pending == nil)
    }

    @Test("missing pending batch witnesses never fabricate acceptance", arguments: [0, 1])
    func missingPendingWitnessFailsClosed(retainedCount: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let context = ModelContext(container)
        let first = LocationPing(timestamp: date, latitude: 37, longitude: 23,
            horizontalAccuracy: 10, h3IndexRes6: "test", source: .photoImport)
        let secondID = UUID()
        if retainedCount == 1 { context.insert(first); try context.save() }
        var intended = PhotoImportCheckpointJournal.Checkpoint(initial)
        intended.accepted = 2
        try PhotoImportCheckpointJournal.write(.init(committed: .init(initial), pending: intended,
            insertedPingIDs: [first.id, secondID]), in: container)
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
            Issue.record("Missing witnesses must make recovery fail closed")
        } catch PhotoImportError.inconsistentLocalData {}
        #expect(try read(container) == initial)
    }

    @Test("a replacement physical row cannot inherit the previous row's local journal")
    func replacementCannotInheritCheckpointJournal() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await commit(recorder, [candidate()], expected: initial, checkpoint: checkpoint(processed: 1))
        let context = ModelContext(container)
        let previous = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        let replacement = PhotoImportState(originDeviceID: previous.originDeviceID)
        replacement.id = previous.id
        replacement.startedAt = previous.startedAt
        replacement.status = .paused
        context.delete(previous)
        context.insert(replacement)
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        do {
            _ = try await service.prepareResumedStateForTesting(originDeviceID: initial.originDeviceID)
            Issue.record("Replacement row must not inherit old acceptance")
        } catch PhotoImportError.inconsistentLocalData {}
        #expect(try read(container).acceptedPingCount == 0)
        #expect(try read(container).status == .paused)
    }

    @Test("every post-save checkpoint field is checked", arguments: ["processed", "accepted", "date", "identifier"])
    func postSaveCheckpointFieldDrift(field: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await recorder.setAfterPhotoImportSaveForTesting {
            let external = ModelContext(container)
            let state = try #require(try external.fetch(FetchDescriptor<PhotoImportState>()).first)
            switch field {
            case "processed": state.processedAssetCount = 0
            case "accepted": state.acceptedPingCount = 0
            case "date": state.watermarkCreationDate = nil
            default: state.watermarkLocalIdentifier = "remote-boundary"
            }
            try external.save()
        }
        let result = try await commit(recorder, [candidate()], expected: initial, checkpoint: checkpoint(processed: 1))
        #expect(result == nil)
        let service = PhotoImportService(modelContainer: container)
        await service.stopAfterCheckpointDriftForTesting(initial)
        #expect(try read(container).status == .paused)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)
    }

    @Test("post-save lifecycle-only changes retain cancellation and pause precedence", arguments: [false, true])
    func postSaveLifecycleChange(paused: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await recorder.setAfterPhotoImportSaveForTesting {
            let external = ModelContext(container)
            let state = try #require(try external.fetch(FetchDescriptor<PhotoImportState>()).first)
            if paused { state.status = .paused }
            else { state.cancelRequested = true }
            try external.save()
        }
        let result = try await commit(recorder, [candidate()], expected: initial, checkpoint: checkpoint(processed: 1))
        let committed = try #require(result)
        let service = PhotoImportService(modelContainer: container)
        await service.finishFinalizedImportForTesting(committed)
        let saved = try read(container)
        #expect(saved.status == (paused ? .paused : .cancelled))
        #expect(saved.completedAt == nil)
        #expect(saved.processedAssetCount == 1)
        #expect(saved.acceptedPingCount == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == saved.acceptedPingCount)
    }

    @Test("pings, accepted count and completed cohort become visible together in a fresh context")
    func commitsTogether() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
        )
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LocationPing>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<HexVisit>()) == 1)
        let saved = try read(container)
        #expect(saved.processedAssetCount == 5)
        #expect(saved.acceptedPingCount == 1)
        #expect(saved.watermarkCreationDate == date)
        #expect(saved.watermarkLocalIdentifier == nil)
    }

    @Test("failed save rolls back pings, hexes and checkpoint; retry accepts the unsaved ping")
    func rollbackAndRetry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await recorder.beginImportDedupSession()
        await recorder.setFailNextImportBatchSaveForTesting(true)
        do {
            _ = try await recorder.commitPhotoImportBatch(
                [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
            )
            Issue.record("The injected save failure must throw")
        } catch {}

        let failedContext = ModelContext(container)
        #expect(try failedContext.fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(try failedContext.fetchCount(FetchDescriptor<HexVisit>()) == 0)
        #expect(try read(container) == initial)

        _ = try await recorder.commitPhotoImportBatch(
            [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
        )
        #expect(try read(container).acceptedPingCount == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)
    }

    @Test("hex read failure rolls back the whole checkpoint batch and the same photos retry", arguments: [1, 2])
    func hexReadFailureRollsBackAndRetries(failingFetch: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await recorder.beginImportDedupSession()
        let candidates = Array([candidate(), candidate(latitude: 40.6401)].prefix(failingFetch))
        await recorder.failImportHexFetchCallForTesting(failingFetch)
        do {
            _ = try await recorder.commitPhotoImportBatch(
                candidates, expected: initial, checkpoint: checkpoint(processed: failingFetch)
            )
            Issue.record("The injected hex read failure must throw")
        } catch {
            #expect(error is PhotoImportBatchReadError)
        }
        let failed = ModelContext(container)
        #expect(try failed.fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(try failed.fetchCount(FetchDescriptor<HexVisit>()) == 0)
        #expect(try read(container) == initial)
        #expect(await recorder.affectedTripIDsForTesting().isEmpty)

        _ = try await recorder.commitPhotoImportBatch(
            candidates, expected: initial, checkpoint: checkpoint(processed: failingFetch)
        )
        let retried = ModelContext(container)
        #expect(try retried.fetchCount(FetchDescriptor<LocationPing>()) == failingFetch)
        let visits = try retried.fetch(FetchDescriptor<HexVisit>())
        #expect(visits.count == failingFetch)
        #expect(visits.allSatisfy { $0.visitCount == 1 })
        let saved = try read(container)
        #expect(saved.acceptedPingCount == failingFetch)
        #expect(saved.processedAssetCount == failingFetch)
        #expect(saved.watermarkCreationDate == date)
        #expect(saved.watermarkLocalIdentifier == nil)
    }

    @Test("a failed hex read restores the durable cursor before retrying an existing cell")
    func hexReadFailureRestoresDurableCursor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate(latitude: 40.6401), candidate(offset: 1000)],
            expected: initial, checkpoint: checkpoint(processed: 2, offset: 1000)
        )
        let durable = try read(container)
        let reentry = candidate(offset: 2000, latitude: 40.6401)
        await recorder.failImportHexFetchCallForTesting(1)
        do {
            _ = try await recorder.commitPhotoImportBatch(
                [reentry], expected: durable, checkpoint: checkpoint(processed: 1, offset: 2000)
            )
            Issue.record("The injected hex read failure must throw")
        } catch {
            #expect(error is PhotoImportBatchReadError)
        }
        // Even a subsequent save must not flush the failed unit's staged ping.
        try await recorder.saveImportBatch()
        #expect(try read(container) == durable)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 2)
        _ = try await recorder.commitPhotoImportBatch(
            [reentry], expected: durable, checkpoint: checkpoint(processed: 1, offset: 2000)
        )
        let visits = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        let h3 = try #require(H3Service.cellIndex(latitude: 40.6401, longitude: 23.7275))
        let revisited = try #require(visits.first { $0.h3Index == h3 })
        #expect(revisited.visitCount == 2)
        #expect(revisited.lastVisited == reentry.timestamp)
        #expect(try read(container).acceptedPingCount == 3)
    }

    @Test("an interrupted partial cohort replays with no repeated acceptance or processed count")
    func partialCohortRestart() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let firstRecorder = PingRecorder(modelContainer: container)
        _ = try await firstRecorder.commitPhotoImportBatch(
            [candidate()], expected: initial,
            checkpoint: PhotoImportCohortCheckpoint(
                processedIncrement: 0, creationDate: nil, legacyLocalIdentifier: nil
            )
        )
        let partial = try read(container)
        #expect(partial.processedAssetCount == 0)
        #expect(partial.acceptedPingCount == 1)

        let resumedRecorder = PingRecorder(modelContainer: container)
        _ = try await resumedRecorder.commitPhotoImportBatch(
            [candidate(), candidate(latitude: 40.6401)], expected: partial,
            checkpoint: checkpoint(processed: 2)
        )
        let completed = try read(container)
        #expect(completed.processedAssetCount == 2)
        #expect(completed.acceptedPingCount == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 2)
    }

    @Test("a reused recorder honors an externally reset session even when new counts equal its prior values")
    func externalResetToSameFinalValues() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
        )

        let resetContext = ModelContext(container)
        let state = try #require(try resetContext.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.startedAt = date.addingTimeInterval(10)
        state.processedAssetCount = 0
        state.acceptedPingCount = 0
        state.watermarkCreationDate = nil
        state.watermarkLocalIdentifier = nil
        try resetContext.save()
        let reset = try read(container)

        _ = try await recorder.commitPhotoImportBatch(
            [candidate(latitude: 40.6401)], expected: reset,
            checkpoint: checkpoint(processed: 5)
        )
        let saved = try read(container)
        #expect(saved.startedAt == reset.startedAt)
        #expect(saved.processedAssetCount == 5)
        #expect(saved.acceptedPingCount == 1)
        #expect(saved.watermarkCreationDate == date)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 2)
    }

    @Test("fresh cancellation or checkpoint drift rejects a prepared batch before insertion")
    func rejectsChangedState() async throws {
        for cancel in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let initial = try seed(in: container)
            let recorder = PingRecorder(modelContainer: container)
            // Prime the recorder's state registration without changing counters.
            _ = try await recorder.commitPhotoImportBatch(
                [], expected: initial,
                checkpoint: PhotoImportCohortCheckpoint(
                    processedIncrement: 0, creationDate: nil, legacyLocalIdentifier: nil
                )
            )
            let prepared = try read(container)
            let otherContext = ModelContext(container)
            let state = try #require(try otherContext.fetch(FetchDescriptor<PhotoImportState>()).first)
            if cancel { state.cancelRequested = true }
            else { state.processedAssetCount = 17 }
            try otherContext.save()
            let changed = try read(container)

            let result = try await recorder.commitPhotoImportBatch(
                [candidate()], expected: prepared, checkpoint: checkpoint(processed: 1)
            )
            #expect(result == nil)
            #expect(try read(container) == changed)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
        }
    }

    @Test("file-backed reset and rollback preserve checkpoint values when read through another container")
    func fileBackedResetAndRollback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photos.sqlite")
        let container = try fileBackedContainer(at: url)
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
        )

        let resetContext = ModelContext(container)
        let state = try #require(try resetContext.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.startedAt = date.addingTimeInterval(10)
        state.processedAssetCount = 0
        state.acceptedPingCount = 0
        state.watermarkCreationDate = nil
        try resetContext.save()
        let reset = try read(container)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate(latitude: 40.6401)], expected: reset, checkpoint: checkpoint(processed: 5)
        )
        let saved = try read(try fileBackedContainer(at: url))
        let localSaved = try read(container)
        #expect(saved.startedAt == reset.startedAt)
        #expect(saved.processedAssetCount == 5)
        #expect(saved.acceptedPingCount == 1)
        #expect(saved.watermarkCreationDate == date)

        await recorder.setFailNextImportBatchSaveForTesting(true)
        do {
            _ = try await recorder.commitPhotoImportBatch(
                [candidate(offset: 3600, latitude: 45)], expected: localSaved,
                checkpoint: checkpoint(processed: 2, offset: 3600)
            )
            Issue.record("The injected save failure must throw")
        } catch {}
        let reopened = try fileBackedContainer(at: url)
        let readback = try read(reopened)
        // Physical identifiers are container-local; verify every persisted
        // value after actually reopening the durable store.
        #expect(readback.id == saved.id)
        #expect(readback.status == saved.status)
        #expect(readback.startedAt == saved.startedAt)
        #expect(readback.completedAt == saved.completedAt)
        #expect(readback.totalAssetCount == saved.totalAssetCount)
        #expect(readback.processedAssetCount == saved.processedAssetCount)
        #expect(readback.acceptedPingCount == saved.acceptedPingCount)
        #expect(readback.watermarkCreationDate == saved.watermarkCreationDate)
        #expect(readback.watermarkLocalIdentifier == saved.watermarkLocalIdentifier)
        #expect(readback.lastError == saved.lastError)
        #expect(readback.lastUpdated == saved.lastUpdated)
        #expect(readback.cancelRequested == saved.cancelRequested)
        #expect(readback.originDeviceID == saved.originDeviceID)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<LocationPing>()) == 2)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<HexVisit>()) == 2)
    }

    @Test("unreadable dedup inputs stop a photo checkpoint before mutation")
    func unreadableDedupInputs() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextImportDedupFetchForTesting(true)
        do {
            _ = try await recorder.commitPhotoImportBatch(
                [candidate()], expected: initial, checkpoint: checkpoint(processed: 1)
            )
            Issue.record("The injected dedup read failure must throw")
        } catch {
            #expect(error is PhotoImportBatchReadError)
        }
        #expect(try read(container) == initial)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate()], expected: initial, checkpoint: checkpoint(processed: 1)
        )
        #expect(try read(container).acceptedPingCount == 1)
    }

    @Test("launch cancels an abandoned running import without changing its durable checkpoint")
    func launchCancelsAbandonedImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("abandoned.sqlite")
        let container = try fileBackedContainer(at: url)
        _ = try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.totalAssetCount = 1_200
        state.processedAssetCount = 875
        state.acceptedPingCount = 600
        state.watermarkCreationDate = date.addingTimeInterval(123)
        state.watermarkLocalIdentifier = "legacy-boundary"
        state.lastError = "previous-error"
        state.lastUpdated = .now.addingTimeInterval(-9 * 86_400)
        try context.save()
        let original = try read(container)
        let service = PhotoImportService(modelContainer: container)
        let beforeLaunch = Date.now

        await service.handleStaleStateOnLaunch()

        let afterLaunch = Date.now
        let reopened = try fileBackedContainer(at: url)
        let saved = try read(reopened)
        #expect(saved.status == .cancelled)
        #expect(saved.lastError == "importError.abandoned")
        #expect(saved.lastUpdated >= beforeLaunch && saved.lastUpdated <= afterLaunch)
        // PersistentIdentifier equality is local to a container's coordinator.
        // Check physical identity there; compare stored fields after reopening.
        #expect(try read(container).persistentModelID == original.persistentModelID)
        #expect(saved.id == original.id)
        #expect(saved.startedAt == original.startedAt)
        #expect(saved.originDeviceID == original.originDeviceID)
        #expect(saved.totalAssetCount == 1_200)
        #expect(saved.processedAssetCount == 875)
        #expect(saved.acceptedPingCount == 600)
        #expect(saved.watermarkCreationDate == date.addingTimeInterval(123))
        #expect(saved.watermarkLocalIdentifier == "legacy-boundary")
        #expect(saved.completedAt == nil)
        #expect(!saved.cancelRequested)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<PhotoImportState>()) == 1)
    }

    @Test("cancelling a dead session clears a crash-left pending journal so ping dedup is not wedged",
          arguments: [true, false])
    func deadSessionCancellationClearsPendingJournal(abandoned: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.lastUpdated = .now.addingTimeInterval(abandoned ? -9 * 86_400 : -60)
        try context.save()
        let snapshot = try read(container)
        var intended = PhotoImportCheckpointJournal.Checkpoint(snapshot)
        intended.processed = snapshot.processedAssetCount + 1
        try PhotoImportCheckpointJournal.write(.init(committed: .init(snapshot), pending: intended,
            insertedPingIDs: [UUID()]), in: container)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.pending != nil)
        let service = PhotoImportService(modelContainer: container)

        if abandoned { await service.handleStaleStateOnLaunch() } else { await service.cancel() }

        #expect(try read(container).status == .cancelled)
        #expect(try read(container).id == initial.id)
        #expect(try PhotoImportCheckpointJournal.read(in: container)?.pending == nil)
    }

    @Test("launch leaves recent running imports and stale non-running states untouched",
          arguments: [(ImportStatus.running, 6), (.idle, 9), (.paused, 9),
                      (.failed, 9), (.completed, 9), (.cancelled, 9)])
    func launchPreservesOtherImportStates(status: ImportStatus, ageDays: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preserved.sqlite")
        let container = try fileBackedContainer(at: url)
        _ = try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.status = status
        state.processedAssetCount = 50
        state.acceptedPingCount = 20
        state.watermarkCreationDate = date
        state.lastError = "keep-existing-error"
        state.lastUpdated = .now.addingTimeInterval(-Double(ageDays) * 86_400)
        try context.save()
        let original = try read(container)
        let service = PhotoImportService(modelContainer: container)

        await service.handleStaleStateOnLaunch()

        #expect(try read(container) == original)
    }

    @Test("fresh service reads and lifecycle saves preserve the recorder's checkpoint")
    func lifecyclePreservesCheckpoint() async throws {
        for status in [ImportStatus.paused, .completed, .cancelled] {
            let container = try TestSupport.makeInMemoryContainer()
            let initial = try seed(in: container)
            let service = PhotoImportService(modelContainer: container)
            #expect(await service.currentState() == initial)
            let recorder = PingRecorder(modelContainer: container)
            _ = try await recorder.commitPhotoImportBatch(
                [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
            )
            let committed = try read(container)
            #expect(await service.currentState() == committed)
            if status == .cancelled { await service.cancel() }
            else { await service.updateRunStatusForTesting(initial, to: status) }
            let updated = try read(container)
            #expect(updated.status == status)
            #expect(updated.processedAssetCount == committed.processedAssetCount)
            #expect(updated.acceptedPingCount == committed.acceptedPingCount)
            #expect(updated.watermarkCreationDate == committed.watermarkCreationDate)
            #expect(updated.watermarkLocalIdentifier == committed.watermarkLocalIdentifier)
        }
    }

    @Test("task cancellation stops insertion and explicit cancellation wins over completion")
    func cancellationPrecedence() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        let inputs = [candidate()]
        let next = checkpoint(processed: 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recorder.commitPhotoImportBatch(inputs, expected: initial, checkpoint: next)
        }
        #expect(try await cancelled.value == nil)
        #expect(try read(container) == initial)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)

        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.cancelRequested = true
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        await service.updateRunStatusForTesting(initial, to: .completed)
        let saved = try read(container)
        #expect(saved.status == .cancelled)
        #expect(saved.completedAt == nil)
    }

    @Test("cancellation observed at the finalization boundary still stops completion")
    func cancellationBeforeFinalizationFinishes() async throws {
        for explicit in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let expected = try seed(in: container)
            let service = PhotoImportService(modelContainer: container)
            if explicit { await service.cancel() }
            let task = Task {
                if !explicit { withUnsafeCurrentTask { $0?.cancel() } }
                await service.finishFinalizedImportForTesting(expected)
            }
            await task.value
            let saved = try read(container)
            #expect(saved.status == (explicit ? .cancelled : .paused))
            #expect(saved.completedAt == nil)
        }
    }

    @Test("explicit and task cancellation after finalization cannot replace successful completion")
    func lateCancellationAfterFinalization() async throws {
        for explicit in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let initial = try seed(in: container)
            let recorder = PingRecorder(modelContainer: container)
            _ = try await recorder.commitPhotoImportBatch(
                [candidate()], expected: initial, checkpoint: checkpoint(processed: 5)
            )
            let expected = try read(container)
            let service = PhotoImportService(modelContainer: container)
            let task = Task {
                await service.finishFinalizedImportForTesting(expected) {
                    if explicit { await service.cancel() }
                    else { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await task.value
            let saved = try read(container)
            #expect(saved.status == .completed)
            #expect(saved.completedAt != nil)
            #expect(!saved.cancelRequested)
            #expect(saved.hasSameCheckpoint(as: expected))
            await service.cancel()
            #expect(try read(container) == saved)
        }
    }

    private enum CompletionDrift: CaseIterable, Sendable {
        case id, startedAt, origin, processed, accepted, date, identifier
    }

    @Test("queued completion validates fresh identity and every durable checkpoint field")
    func completionRejectsDrift() async throws {
        for drift in CompletionDrift.allCases {
            let container = try TestSupport.makeInMemoryContainer()
            let expected = try seed(in: container)
            let service = PhotoImportService(modelContainer: container)
            await service.finishFinalizedImportForTesting(expected) {
                await MainActor.run {
                    do {
                        let context = ModelContext(container)
                        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
                        switch drift {
                        case .id: state.id = UUID()
                        case .startedAt: state.startedAt.addTimeInterval(1)
                        case .origin: state.originDeviceID = "another-device"
                        case .processed: state.processedAssetCount += 1
                        case .accepted: state.acceptedPingCount += 1
                        case .date: state.watermarkCreationDate = expected.startedAt
                        case .identifier: state.watermarkLocalIdentifier = "legacy"
                        }
                        try context.save()
                    } catch { Issue.record("Failed to inject completion drift: \(error)") }
                }
            }
            let saved = try read(container)
            #expect(saved.status == .running)
            #expect(saved.completedAt == nil)
            #expect(!saved.hasSameCheckpoint(as: expected))
        }
    }

    @Test("invalid enumeration refetch discards partial accounting and replays durable pings once")
    func invalidEnumerationRecovery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        var expected = try seed(in: container)
        let recorder = PingRecorder(modelContainer: container)
        var cohorts = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        var recovery = PhotoImportEnumerationRecovery(creationDate: nil, localIdentifier: nil)
        let later = date.addingTimeInterval(3600)
        let first = try cohorts.advance(dates: [date, later], nextDate: later, isAtEnd: false)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate(), candidate(offset: 3600)], expected: expected, checkpoint: first
        )
        expected = try read(container)
        #expect(expected.processedAssetCount == 1)
        #expect(expected.acceptedPingCount == 2)
        #expect(expected.watermarkCreationDate == date)
        // This mutates pending accounting before discovering the invalid date.
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try cohorts.advance(dates: [later, nil], nextDate: nil, isAtEnd: true)
        }
        cohorts = try recovery.restart(
            creationDate: expected.watermarkCreationDate,
            localIdentifier: expected.watermarkLocalIdentifier
        )
        let replay = try cohorts.advance(dates: [later, later], nextDate: nil, isAtEnd: true)
        _ = try await recorder.commitPhotoImportBatch(
            [candidate(offset: 3600), candidate(offset: 3600, latitude: 40.6401)],
            expected: expected, checkpoint: replay
        )
        let saved = try read(container)
        #expect(saved.processedAssetCount == 3)
        #expect(saved.acceptedPingCount == 3)
        #expect(saved.watermarkCreationDate == later)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 3)
    }

    @Test("large tied cohorts recover after partial saves and count rejected assets once")
    func largeCohortInterrupted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        var expected = try seed(in: container)
        var cohorts = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        let firstRecorder = PingRecorder(modelContainer: container)
        var offset = 0
        // Stop after two durable slices in a 451-asset cohort.
        for size in [200, 100] {
            let checkpoint = try cohorts.advance(
                dates: Array(repeating: date, count: size), nextDate: date, isAtEnd: false
            )
            let candidates = (offset..<(offset + size)).compactMap { index in
                index.isMultiple(of: 50) ? candidate(latitude: 20 + Double(index) / 100) : nil
            }
            _ = try await firstRecorder.commitPhotoImportBatch(
                candidates, expected: expected, checkpoint: checkpoint
            )
            expected = try read(container)
            offset += size
        }
        #expect(expected.processedAssetCount == 0)
        #expect(expected.acceptedPingCount == 6)

        let resumedRecorder = PingRecorder(modelContainer: container)
        var resumed = PhotoImportCohortProgress(
            creationDate: expected.watermarkCreationDate,
            localIdentifier: expected.watermarkLocalIdentifier
        )
        offset = 0
        for size in [50, 200, 100, 100, 1] {
            let end = offset + size
            let checkpoint = try resumed.advance(
                dates: Array(repeating: date, count: size),
                nextDate: end == 451 ? nil : date, isAtEnd: end == 451
            )
            let candidates = (offset..<end).compactMap { index in
                index.isMultiple(of: 50) ? candidate(latitude: 20 + Double(index) / 100) : nil
            }
            _ = try await resumedRecorder.commitPhotoImportBatch(
                candidates, expected: expected, checkpoint: checkpoint
            )
            expected = try read(container)
            offset = end
        }
        #expect(expected.processedAssetCount == 451)
        #expect(expected.acceptedPingCount == 10)
        #expect(expected.watermarkCreationDate == date)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 10)
    }

    @Test("a failed photo commit restores preattached stay scalars and generated trip title", arguments: [false, true])
    func preattachedStayRollback(hexReadFailure: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let initial = try seed(in: container)
        let context = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275))
        let originalPing = LocationPing(
            timestamp: date, latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 10, h3IndexRes6: hex, source: .liveSLC
        )
        let stay = Stay(
            startTime: date, endTime: date.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 50,
            pingIDs: [originalPing.id], source: .liveSLC
        )
        let trip = Trip(startDate: date)
        trip.endDate = stay.endTime
        trip.aiGeneratedTitle = "A saved title"
        trip.stays = [stay]
        stay.trip = trip
        originalPing.isProcessed = true
        context.insert(originalPing)
        context.insert(stay)
        context.insert(trip)
        try context.save()
        let originalID = originalPing.id

        let recorder = PingRecorder(modelContainer: container)
        var candidates = [candidate(offset: -3600, latitude: 37.988)]
        if hexReadFailure {
            candidates.append(candidate(offset: 3600, latitude: 40.6401))
            await recorder.failImportHexFetchCallForTesting(2)
        } else {
            await recorder.setFailNextImportBatchSaveForTesting(true)
        }
        do {
            _ = try await recorder.commitPhotoImportBatch(
                candidates, expected: initial,
                checkpoint: checkpoint(processed: 1, offset: -3600)
            )
            Issue.record("The injected batch failure must throw")
        } catch {}
        #expect(await recorder.affectedTripIDsForTesting().isEmpty)
        await recorder.recomputeAffectedTripSummaries()
        let failed = ModelContext(container)
        let failedStay = try #require(try failed.fetch(FetchDescriptor<Stay>()).first)
        let failedTrip = try #require(try failed.fetch(FetchDescriptor<Trip>()).first)
        #expect(failedStay.source == .liveSLC)
        #expect(failedStay.pingCount == 1)
        #expect(failedStay.startTime == date)
        #expect(failedStay.centroidLatitude == 37.9838)
        #expect(failedStay.pingIDs == [originalID])
        #expect(failedTrip.aiGeneratedTitle == "A saved title")
        #expect(failedTrip.startDate == date)
        #expect(try read(container) == initial)

        _ = try await recorder.commitPhotoImportBatch(
            candidates, expected: initial,
            checkpoint: checkpoint(processed: 1, offset: -3600)
        )
        let retried = ModelContext(container)
        let savedStay = try #require(try retried.fetch(FetchDescriptor<Stay>()).first)
        let savedTrip = try #require(try retried.fetch(FetchDescriptor<Trip>()).first)
        #expect(savedStay.source == .merged)
        #expect(savedStay.pingCount == 2)
        #expect(savedStay.startTime == date.addingTimeInterval(-3600))
        #expect(savedTrip.aiGeneratedTitle == nil)
        #expect(try read(container).acceptedPingCount == candidates.count)
    }
}
