import Foundation
import SwiftData
import Testing
import UIKit
@testable import TravelLog

@MainActor
@Suite("Photo import session outcomes", .serialized)
struct PhotoImportSessionOutcomeTests {
    private func seed(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let state = PhotoImportState(originDeviceID: UIDevice.current.identifierForVendor?.uuidString ?? "")
        state.status = .running
        context.insert(state)
        try context.save()
    }

    @Test("revoked permission returns failure to the background handler")
    func revokedPermissionReturnsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        let service = PhotoImportService(modelContainer: container)
        let outcome = await PhotoImportService.$readAccessForTesting.withValue(false) {
            await service.runImportSession(progress: nil)
        }
        let saved = try #require(await service.currentState())
        #expect(saved.status == .failed)
        #expect(saved.lastError == "importError.permissionRevoked")
        #expect(outcome == .failed)
    }

    @Test("a normal empty-library run returns completed after finalization")
    func normalRunReturnsCompleted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        let service = PhotoImportService(modelContainer: container)
        let outcome = await PhotoImportService.$readAccessForTesting.withValue(true) {
            await PhotoImportService.$libraryForTesting.withValue([]) {
                await service.runImportSession(progress: nil)
            }
        }
        let saved = try #require(await service.currentState())
        #expect(saved.status == .completed)
        #expect(saved.completedAt != nil)
        #expect(outcome == .completed)
    }

    @Test("cancellation returns paused, with explicit cancellation taking precedence",
          arguments: [false, true])
    func cancellationReturnsTerminalStatus(explicit: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        if explicit {
            let context = ModelContext(container)
            let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
            state.cancelRequested = true
            try context.save()
        }
        let service = PhotoImportService(modelContainer: container)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.runImportSession(progress: nil)
        }
        let outcome = await task.value
        #expect(outcome == (explicit ? .cancelled : .paused))
        #expect(await service.currentState()?.status == outcome)
    }

    @Test("a missing session reports failure")
    func missingSessionReturnsFailure() async throws {
        let service = PhotoImportService(modelContainer: try TestSupport.makeInMemoryContainer())
        #expect(await service.runImportSession(progress: nil) == .failed)
    }

    @Test("checkpoint recovery failure reports failure even when durable state remains running")
    func checkpointRecoveryReturnsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        try PhotoImportCheckpointJournal.seed(PhotoImportStateSnapshot(from: state), in: container)
        state.startedAt.addTimeInterval(-1)
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        #expect(await service.runImportSession(progress: nil) == .failed)
        #expect(await service.currentState()?.status == .running)
    }

    @Test("an ineligible session cannot report a previous completion as success",
          arguments: [ImportStatus.idle, .paused, .completed, .failed, .cancelled])
    func ineligibleSessionReturnsFailure(status: ImportStatus) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.status = status
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        #expect(await service.runImportSession(progress: nil) == .failed)
        #expect(await service.currentState()?.status == status)
    }

    @Test("a running session owned by another device reports failure without mutation")
    func foreignSessionReturnsFailure() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seed(in: container)
        let context = ModelContext(container)
        let state = try #require(try context.fetch(FetchDescriptor<PhotoImportState>()).first)
        state.originDeviceID = "other-device"
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        #expect(await service.runImportSession(progress: nil) == .failed)
        #expect(await service.currentState()?.status == .running)
    }
}
