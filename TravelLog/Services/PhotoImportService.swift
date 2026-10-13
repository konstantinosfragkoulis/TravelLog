//
//  PhotoImportService.swift
//  TravelLog
//

import BackgroundTasks
import CoreLocation
import Foundation
import Photos
import SwiftData
import UIKit
import WidgetKit
import os.log

nonisolated private enum PhotoImportBatchResult: Sendable {
    case committed(PhotoImportStateSnapshot)
    case stopped
    case readFailed(String)
    case saveFailed(String)
}

/// Enumerates photos and coordinates bounded, gated PingRecorder commits.
@ModelActor
actor PhotoImportService {
    let logger = Logger(subsystem: "com.travellog.app", category: "PhotoImportService")

    /// Prevent concurrent imports on this device, including starts triggered by synced state.
    private var isRunning = false

    /// Runtime batch limit; memory and thermal pressure can reduce it without changing persisted progress.
    private static let defaultBatchSize = 200

    /// Memory-pressure override, sticky for the session and cleared on `start()`.
    private var batchSizeOverride: Int?

    /// Inter-batch pause under serious thermal pressure to let the SoC cool.
    private static let thermalSeriousBatchPauseSeconds: TimeInterval = 2.0

    /// Require 100 MB free before importing: SwiftData growth is small, but the import must leave free space.
    private static let minimumFreeDiskBytes: Int64 = 100 * 1024 * 1024

    /// Reject creation dates before 1995-01-01 UTC as implausible EXIF timestamps.
    private static let earliestPlausibleDate: Date = {
        var components = DateComponents()
        components.year = 1995
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 788918400)
    }()

    // MARK: - Public API

    /// Reset persistent progress and submit a background request handled by `AppDelegate.handleBGImport`.
    /// Reject active loops and persisted running sessions, including the submission-to-handler race window.
    /// The main-actor caller supplies `originDeviceID` because UIDevice is main-actor-bound.
    /// Call only from foreground UI: the system rejects background submissions.
    func start(originDeviceID: String) async throws {
        guard !isRunning else { throw PhotoImportError.alreadyRunning }
        // A running row owned by this device with no live loop in this
        // process is a dead session (crash, kill) and may be restarted; a
        // foreign device's running row is protected while it keeps updating.
        if let existing = currentState(), existing.status == .running,
           existing.originDeviceID != originDeviceID,
           Date.now.timeIntervalSince(existing.lastUpdated) < Self.foreignSessionTakeoverSeconds {
            throw PhotoImportError.alreadyRunning
        }
        guard await Self.hasReadAccess() else { throw PhotoImportError.noPhotoPermission }

        // Check power and disk before mutating state so a refused start preserves prior progress.
        try throwIfSystemPressureBlocksImport()

        batchSizeOverride = nil

        let preparation = await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
            do {
                return Result<PhotoImportStateSnapshot, PhotoImportError>.success(
                    try await prepareNewState(originDeviceID: originDeviceID))
            } catch {
                return .failure(error as? PhotoImportError ?? .persistenceFailure(error.localizedDescription))
            }
        }
        let session = try preparation.get()

        await recorder.clearAffectedTripIDs()

        // Reset hex reentry so the first ping counts as a new visit even if it matches the prior session’s last hex.
        await recorder.resetLastImportedH3Index()

        do {
            try await Self.submitBGImportRequest()
        } catch {
            await updateRunStatus(session, to: .failed, error: "importError.backgroundTaskStart")
            throw PhotoImportError.bgTaskSubmissionFailed(error.localizedDescription)
        }
    }

    /// Continue from the persisted watermark. Refuses if no resumable
    /// state exists (no row, or row is in `idle` / `completed` /
    /// `cancelled`). Submits a new `BGContinuedProcessingTaskRequest`
    /// just like `start()`; the handler picks up from
    /// `state.watermarkCreationDate` / `state.watermarkLocalIdentifier`.
    func resume() async throws {
        let originDeviceID = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? "" }
        guard !isRunning else { throw PhotoImportError.alreadyRunning }
        guard await Self.hasReadAccess() else { throw PhotoImportError.noPhotoPermission }

        try throwIfSystemPressureBlocksImport()

        let preparation = await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
            do {
                return Result<PhotoImportStateSnapshot, PhotoImportError>.success(try await prepareResumedState(originDeviceID: originDeviceID))
            } catch {
                return .failure(error as? PhotoImportError ?? .persistenceFailure(error.localizedDescription))
            }
        }
        let session = try preparation.get()

        do {
            try await Self.submitBGImportRequest()
        } catch {
            await updateRunStatus(session, to: .failed, error: "importError.backgroundTaskResume")
            throw PhotoImportError.bgTaskSubmissionFailed(error.localizedDescription)
        }
    }

    /// Apply the same system-pressure gates to start and resume.
    private func throwIfSystemPressureBlocksImport() throws {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            throw PhotoImportError.lowPowerMode
        }
        if let bytesAvailable = Self.availableDiskSpaceBytes(),
           bytesAvailable < Self.minimumFreeDiskBytes {
            throw PhotoImportError.insufficientDiskSpace(bytesAvailable: bytesAvailable)
        }
    }

    /// Nonisolated submission touches no actor state; queue the request when resources are unavailable.
    private nonisolated static func submitBGImportRequest() async throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: AppDelegate.bgImportIdentifier,
            title: String(
                localized: "photo-import.background-progress.title",
                defaultValue: "Reconstructing past trips",
                comment: "System background-progress title while importing photo history."
            ),
            subtitle: String(
                localized: "photo-import.background-progress.subtitle",
                defaultValue: "Scanning your photo library",
                comment: "System background-progress subtitle while importing photo history."
            )
        )
        request.strategy = .queue
        try await BackgroundTaskSubmitter.submit(request)
    }

    /// Request cancellation. The running loop observes `state.cancelRequested`
    /// at every batch boundary (after an `await Task.yield()` so this call
    /// can interleave on the actor's serial executor) and exits cleanly,
    /// preserving the watermark.
    ///
    /// If no local loop is alive but persisted state is still `.running`,
    /// transition directly to `.cancelled`. The Settings UI prevents
    /// cancellation while another device owns a fresh import; each loop
    /// also rechecks persisted status and cancellation at batch boundaries.
    /// The write gate coordinates this device, not CloudKit delivery.
    ///
    /// A no-op if no state row exists. Persistence failures are returned to Settings.
    @discardableResult
    func cancel() async -> Result<Void, PhotoImportError> {
        await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
            await persistCancellation()
        }
    }

    private func persistCancellation() -> Result<Void, PhotoImportError> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            guard let state = try freshState(in: context), state.status == .running else { return .success(()) }
            state.cancelRequested = true
            state.lastUpdated = .now
            let terminal = !isRunning && state.status == .running
            if terminal { state.status = .cancelled }
            #if DEBUG
            if Self.failCancellationSaveForTesting { throw CocoaError(.fileWriteUnknown) }
            #endif
            try context.save()
            // A cancelled session can never be resumed; drop any crash witness so it cannot wedge ping dedup.
            if terminal { try? PhotoImportCheckpointJournal.clear(in: modelContainer) }
            return .success(())
        } catch {
            context.rollback()
            logger.error("Import cancellation save failed: \(error.localizedDescription)")
            return .failure(.persistenceFailure(error.localizedDescription))
        }
    }

    /// Sendable UI snapshot; never expose actor-owned SwiftData models across actors.
    /// Nil until a state row is written or synced locally.
    func currentState() -> PhotoImportStateSnapshot? {
        try? PhotoImportStateSnapshot.fetch(in: ModelContext(modelContainer))
    }

    /// Dedup must defer Stay reconciliation during a local import to avoid cross-context save conflicts.
    func isCurrentlyRunning() -> Bool {
        isRunning
    }

    /// Discard refuses while the local import runs and, like start and resume, while another device's running session stays fresh. Cancel queued BG requests before deleting state.
    /// Manually remove HiddenPhoto/PinnedPhoto children: CloudKit-compatible models have no cascade inverse.
    /// Rebuild surviving host geometry and provenance from complete ping and Visit evidence;
    /// any unhydrated surviving UUID must roll back the entire discard for a later retry.
    /// Delete import-only rows and empty hosts; recompute surviving trip summaries and provenance.
    /// Commit all store changes atomically so a crash leaves either all or none of the deletion applied.
    /// Clear recorder cursors only after commit.
    func discard() async throws {
        guard !isRunning else { throw PhotoImportError.alreadyRunning }
        // Set single-flight before the first await so independent UI entry points cannot enqueue duplicate teardown.
        guard !isDiscarding else { throw PhotoImportError.alreadyRunning }
        isDiscarding = true
        defer { isDiscarding = false }
        let localDeviceID = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? "" }
        if let existing = currentState(), existing.status == .running,
           existing.originDeviceID != localDeviceID,
           Date.now.timeIntervalSince(existing.lastUpdated) < Self.foreignSessionTakeoverSeconds {
            throw PhotoImportError.alreadyRunning
        }

        // Cancel queued BG tasks outside the store-write gate.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.bgImportIdentifier)

        // Gate the entire fetch/rebuild/delete/save transaction against concurrent pipeline writes.
        // Capture only the actor across the Sendable boundary; fetch models inside it and never nest gates.
        // Whole-store fetches hold the gate, so live SLC writes wait for this transaction.
        let outcome = await PipelineGate.shared.runReturning(touching: [.trip, .stay, .locationPing, .photoImportState, .hiddenPhoto, .pinnedPhoto, .hexVisit, .visit]) { [self] in
            await performDiscardTeardown()
        }
        // Reload widgets after committed deletion even if sidecar cleanup failed.
        // Hop to the main actor after releasing the gate.
        if outcome.committed {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        if let error = outcome.error { throw error }
    }

    /// Single-flight guard for `discard()` — set before its first await so a
    /// second concurrent call throws rather than enqueuing duplicate teardown
    /// work (see `discard()`).
    private var isDiscarding = false

    /// On launch, cancel running state rows older than seven days to clear abandoned-import recovery UI.
    /// Allow resuming after a week-long trip without leaving months-old recovery prompts.
    func handleStaleStateOnLaunch() async {
        await PipelineGate.shared.run(touching: [.photoImportState]) { [self] in
            await persistStaleState()
        }
    }

    private func persistStaleState() {
        let context = ModelContext(modelContainer)
        do {
            guard let state = try freshState(in: context), state.status == .running,
                  Date().timeIntervalSince(state.lastUpdated) > 7 * 24 * 60 * 60 else { return }
            state.status = .cancelled
            state.lastError = "importError.abandoned"
            state.lastUpdated = .now
            try context.save()
            // A cancelled session can never be resumed; drop any crash witness so it cannot wedge ping dedup.
            try? PhotoImportCheckpointJournal.clear(in: modelContainer)
        } catch {
            logger.error("Stale import status save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal Loop

    /// Walk a fixed PhotoKit result in bounded slices. Only complete date
    /// cohorts advance the cursor; partial cohorts safely replay on resume.
    /// Return the owned session's terminal status, or failure if none can be verified.
    func runImportSession(progress: Progress?) async -> ImportStatus {
        guard !isRunning else { return .failed }
        isRunning = true
        defer { isRunning = false }
        let localDeviceID = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? "" }
        guard let initial = currentState(), initial.status == .running,
              initial.canResume(onDeviceID: localDeviceID) else { return .failed }

        await runOwnedImportSession(initial, progress: progress)

        guard let saved = currentState(), saved.persistentModelID == initial.persistentModelID,
              saved.id == initial.id, saved.startedAt == initial.startedAt,
              saved.originDeviceID == initial.originDeviceID else { return .failed }
        switch saved.status {
        case .completed, .failed, .paused, .cancelled:
            return saved.status
        case .idle, .running:
            return .failed
        }
    }

    private func runOwnedImportSession(_ initial: PhotoImportStateSnapshot, progress: Progress?) async {
        let recorder = self.recorder
        var beganDedupSession = false
        defer {
            if beganDedupSession { Task { await recorder.endImportDedupSession() } }
        }
        let recovered = await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
            try? await recoverOwnedCheckpoint(initial)
        }
        guard var expected = recovered else { return }
        if expected.cancelRequested || Task.isCancelled {
            await updateRunStatus(expected, to: expected.cancelRequested ? .cancelled : .paused)
            return
        }
        guard await Self.hasReadAccess() else {
            await updateRunStatus(expected, to: .failed, error: "importError.permissionRevoked")
            return
        }
        // Build the index at a unit boundary: a live batch suspended mid-unit
        // holds unsaved inserts in the shared recorder context.
        await PipelineGate.shared.run(touching: []) {
            await recorder.beginImportDedupSession()
        }
        beganDedupSession = true
        if expected.totalAssetCount == 0 {
            let initialCheckpoint = expected
            let initialization = await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
                do {
                    return Result<PhotoImportStateSnapshot?, PhotoImportError>.success(
                        try await initializeTotal(for: initialCheckpoint))
                } catch {
                    return .failure(.persistenceFailure(error.localizedDescription))
                }
            }
            do {
                guard let initialized = try initialization.get() else {
                    if Task.isCancelled { await updateRunStatus(expected, to: .paused) }
                    else if currentState()?.cancelRequested == true {
                        await updateRunStatus(expected, to: .cancelled)
                    }
                    return
                }
                expected = initialized
            } catch {
                logger.error("Import total save failed: \(error.localizedDescription)")
                await updateRunStatus(expected, to: .failed, error: "importError.checkpointSaveFailed")
                return
            }
        }
        let session = expected
        if Task.isCancelled {
            await updateRunStatus(session, to: .paused)
            return
        }
        var assets = fetchAssets(
            afterCreationDate: expected.watermarkCreationDate,
            replayBoundary: expected.watermarkLocalIdentifier != nil
        )
        var cohorts = PhotoImportCohortProgress(
            creationDate: expected.watermarkCreationDate,
            localIdentifier: expected.watermarkLocalIdentifier
        )
        var recovery = PhotoImportEnumerationRecovery(
            creationDate: expected.watermarkCreationDate,
            localIdentifier: expected.watermarkLocalIdentifier
        )
        var index = 0
        updateProgress(progress, from: expected)

        while true {
            guard let current = currentState(), current.persistentModelID == session.persistentModelID,
                  current.id == session.id,
                  current.startedAt == session.startedAt,
                  current.originDeviceID == session.originDeviceID else { return }
            if current.cancelRequested {
                await updateRunStatus(session, to: .cancelled)
                return
            }
            if Task.isCancelled {
                await updateRunStatus(session, to: .paused)
                return
            }
            guard current.status == .running else { return }
            guard current.hasSameCheckpoint(as: expected) else {
                await updateRunStatus(session, to: .paused)
                return
            }
            guard await Self.hasReadAccess() else {
                await updateRunStatus(session, to: .failed, error: "importError.permissionRevoked")
                return
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                await updateRunStatus(session, to: .paused, error: "importError.lowPowerMode")
                return
            }
            if ProcessInfo.processInfo.thermalState == .critical {
                await updateRunStatus(session, to: .paused, error: "importError.thermal")
                return
            }
            if index == assets.count {
                await finalizeSuccessfulImport(session: expected)
                return
            }

            let endIndex = min(index + currentBatchSize(), assets.count)
            var candidates: [ImportedPingCandidate] = []
            var dates: [Date?] = []
            candidates.reserveCapacity(endIndex - index)
            dates.reserveCapacity(endIndex - index)
            for assetIndex in index..<endIndex {
                dates.append(assets.creationDate(assetIndex))
                if let candidate = assets.candidate(assetIndex) { candidates.append(candidate) }
            }
            let isAtEnd = endIndex == assets.count
            let nextDate = isAtEnd ? nil : assets.creationDate(endIndex)
            let checkpoint: PhotoImportCohortCheckpoint
            do {
                checkpoint = try cohorts.advance(dates: dates, nextDate: nextDate, isAtEnd: isAtEnd)
            } catch {
                // advance() may have accumulated part of the invalid slice.
                // Rebuild both its accounting and the fetch from durable state.
                guard await canContinueSession(expected) else { return }
                let durable = expected
                do {
                    cohorts = try recovery.restart(
                        creationDate: durable.watermarkCreationDate,
                        localIdentifier: durable.watermarkLocalIdentifier
                    )
                } catch {
                    logger.error("Photo enumeration repeatedly made no checkpoint progress; pausing for retry.")
                    await updateRunStatus(session, to: .paused, error: "importError.libraryChanged")
                    return
                }
                logger.warning("Restarting photo enumeration from its last durable cohort checkpoint.")
                expected = durable
                assets = fetchAssets(
                    afterCreationDate: durable.watermarkCreationDate,
                    replayBoundary: durable.watermarkLocalIdentifier != nil
                )
                index = 0
                await Task.yield()
                continue
            }

            let batchCandidates = candidates
            let expectedCheckpoint = expected
            let result = await PipelineGate.shared.runReturning(
                touching: [.locationPing, .hexVisit, .stay, .trip, .photoImportState]
            ) {
                do {
                    if let committed = try await recorder.commitPhotoImportBatch(
                        batchCandidates, expected: expectedCheckpoint, checkpoint: checkpoint
                    ) {
                        return PhotoImportBatchResult.committed(committed)
                    }
                    return PhotoImportBatchResult.stopped
                } catch let error as PhotoImportBatchReadError {
                    return PhotoImportBatchResult.readFailed(error.localizedDescription)
                } catch {
                    return PhotoImportBatchResult.saveFailed(error.localizedDescription)
                }
            }
            switch result {
            case .committed(let committed):
                expected = committed
                index = endIndex
                updateProgress(progress, from: committed)
                #if DEBUG
                if let afterBatch = Self.afterBatchCommitForTesting { await afterBatch(committed) }
                #endif
            case .stopped:
                await stopAfterCheckpointDrift(session)
                return
            case .readFailed(let message):
                logger.error("Photo batch/checkpoint read failed: \(message)")
                await updateRunStatus(session, to: .failed, error: "importError.batchReadFailed")
                return
            case .saveFailed(let message):
                logger.error("Photo batch/checkpoint save failed: \(message)")
                await updateRunStatus(session, to: .failed, error: "importError.batchSaveFailed")
                return
            }
            if ProcessInfo.processInfo.thermalState == .serious {
                try? await Task.sleep(for: .seconds(Self.thermalSeriousBatchPauseSeconds))
            }
            await Task.yield()
        }
    }

    private func recoverOwnedCheckpoint(_ expected: PhotoImportStateSnapshot) throws -> PhotoImportStateSnapshot? {
        let context = ModelContext(modelContainer)
        guard let state = try freshState(in: context), state.persistentModelID == expected.persistentModelID,
              state.id == expected.id, state.startedAt == expected.startedAt,
              state.originDeviceID == expected.originDeviceID else { return nil }
        let before = PhotoImportStateSnapshot(from: state)
        try PhotoImportCheckpointJournal.restore(into: state, in: context)
        if !PhotoImportStateSnapshot(from: state).hasSameCheckpoint(as: before) { try context.save() }
        return PhotoImportStateSnapshot(from: state)
    }

    private func stopAfterCheckpointDrift(_ session: PhotoImportStateSnapshot) async {
        // The run already verified its local device ownership. Repair only
        // that exact generation; a resumed/replaced session is never touched.
        _ = await PipelineGate.shared.runReturning(touching: [.photoImportState]) { [self] in
            try? await recoverOwnedCheckpoint(session)
        }
        if let latest = currentState(), latest.persistentModelID == session.persistentModelID,
           latest.id == session.id,
           latest.startedAt == session.startedAt,
           latest.originDeviceID == session.originDeviceID {
            if latest.cancelRequested {
                await updateRunStatus(session, to: .cancelled)
            } else if Task.isCancelled {
                await updateRunStatus(session, to: .paused)
            } else if latest.status == .running {
                logger.warning("Photo checkpoint changed while its batch was queued; pausing at the current durable checkpoint.")
                await updateRunStatus(session, to: .paused)
            }
        }
    }

    private func updateProgress(_ progress: Progress?, from state: PhotoImportStateSnapshot) {
        progress?.totalUnitCount = Int64(max(state.totalAssetCount, state.processedAssetCount))
        progress?.completedUnitCount = Int64(state.processedAssetCount)
    }

    private func initializeTotal(for expected: PhotoImportStateSnapshot) throws -> PhotoImportStateSnapshot? {
        guard !Task.isCancelled else { return nil }
        let context = ModelContext(modelContainer)
        guard let state = try freshState(in: context),
              state.persistentModelID == expected.persistentModelID, state.id == expected.id,
              state.startedAt == expected.startedAt,
              state.originDeviceID == expected.originDeviceID,
              state.status == .running, !state.cancelRequested else { return nil }
        if state.totalAssetCount == 0 { state.totalAssetCount = totalAssetCountEstimate() }
        try context.save()
        return PhotoImportStateSnapshot(from: state)
    }

    private func updateRunStatus(
        _ expected: PhotoImportStateSnapshot, to status: ImportStatus, error: String? = nil,
        finalizationCompleted: Bool = false
    ) async {
        await PipelineGate.shared.run(touching: [.photoImportState]) { [self] in
            await persistRunStatus(
                expected, to: status, error: error, finalizationCompleted: finalizationCompleted
            )
        }
    }

    private func persistRunStatus(
        _ expected: PhotoImportStateSnapshot, to status: ImportStatus, error: String?,
        finalizationCompleted: Bool
    ) {
        let context = ModelContext(modelContainer)
        do {
            guard let state = try freshState(in: context),
                  state.persistentModelID == expected.persistentModelID, state.id == expected.id,
                  state.startedAt == expected.startedAt,
                  state.originDeviceID == expected.originDeviceID else { return }
            if finalizationCompleted {
                // Eligibility was captured after the required finalization
                // calls returned without observed cancellation. Only a late
                // cancel may now lose, and only for this exact checkpoint.
                guard status == .completed,
                      state.status == .running || state.status == .cancelled,
                      PhotoImportStateSnapshot(from: state).hasSameCheckpoint(as: expected) else { return }
                state.status = .completed
                state.cancelRequested = false
            } else {
                guard state.status == .running else { return }
                state.status = state.cancelRequested ? .cancelled : status
            }
            state.lastError = error
            state.lastUpdated = .now
            if state.status == .completed { state.completedAt = .now }
            try context.save()
        } catch {
            logger.error("Photo import status save failed: \(error.localizedDescription)")
        }
    }

    private func persistFinalizationHeartbeat(_ session: PhotoImportStateSnapshot) {
        let context = ModelContext(modelContainer)
        do {
            guard let state = try freshState(in: context),
                  state.status == .running, !state.cancelRequested,
                  PhotoImportStateSnapshot(from: state).hasSameCheckpoint(as: session) else { return }
            state.lastUpdated = .now
            try context.save()
        } catch {
            logger.error("Photo import heartbeat save failed: \(error.localizedDescription)")
        }
    }

    /// Validate fresh identity and progress before recovery or a finalization
    /// phase. Explicit cancellation retains precedence until all phases return.
    private func canContinueSession(_ expected: PhotoImportStateSnapshot) async -> Bool {
        guard let current = currentState(), current.persistentModelID == expected.persistentModelID,
              current.id == expected.id,
              current.startedAt == expected.startedAt,
              current.originDeviceID == expected.originDeviceID else { return false }
        if current.cancelRequested {
            await updateRunStatus(expected, to: .cancelled)
            return false
        }
        if Task.isCancelled {
            await updateRunStatus(expected, to: .paused)
            return false
        }
        guard current.status == .running else { return false }
        guard current.hasSameCheckpoint(as: expected) else {
            await updateRunStatus(expected, to: .paused)
            return false
        }
        return true
    }

    /// This boundary is reached only after enumeration and the required
    /// finalization calls. Clustering and foreground classification report a
    /// failed pass and pause the import before this; the summary and title
    /// stages do not report theirs.
    private func finishFinalizedImport(_ expected: PhotoImportStateSnapshot) async -> Bool {
        guard await canContinueSession(expected) else { return false }
        // No cancellation was observed through finalization. Cancellation
        // while notifying widgets or queued behind the gate is now late.
        #if DEBUG
        if let beforeCompletionForTesting { await beforeCompletionForTesting() }
        #endif
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        await updateRunStatus(expected, to: .completed, finalizationCompleted: true)
        guard let saved = currentState() else { return false }
        return saved.status == .completed && saved.hasSameCheckpoint(as: expected)
    }

    /// Finalize after enumeration; earlier cancellation or persistence failure defers this to resume.
    /// AppDelegate completes the BG task after this returns. Trips also picks up pending pipeline work.
    /// Run the LLM only while the app is active to avoid background thermal pressure.
    private func finalizeSuccessfulImport(session: PhotoImportStateSnapshot) async {
        guard await canContinueSession(session) else { return }
        // Finalization commits no batches, so keep lastUpdated fresh for the
        // stall banner and the foreign-device takeover window. A beat after
        // completion, pause, cancellation or takeover is a guarded no-op.
        var interval = Duration.seconds(20)
        #if DEBUG
        if let override = Self.finalizationHeartbeatIntervalForTesting { interval = override }
        #endif
        let heartbeat = Task { [self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await PipelineGate.shared.run(touching: [.photoImportState]) { [self] in
                    await persistFinalizationHeartbeat(session)
                }
            }
        }
        defer { heartbeat.cancel() }
        // Cluster unmatched pings through PipelineGate to serialize against foreground pipeline writes.
        // Pre-attached pings are already processed and must be skipped.
        let clusterer = self.clusterer
        let clustering = await PipelineGate.shared.runReturning(touching: [.stay, .locationPing, .trip, .visit]) {
            await clusterer.clusterUnprocessedPingsReportingChanges()
        }
        guard !clustering.failed else {
            // The imported pings are durable but unprocessed. Pause rather
            // than complete: the resumed run enumerates nothing new and
            // finalizes again.
            await updateRunStatus(session, to: .paused, error: "importError.finalizationSaveFailed")
            return
        }
        await clusterer.enrichPendingLocalities(clustering.pendingLocalities)
        #if DEBUG
        if let hook = Self.afterFinalizationClusteringForTesting { await hook() }
        #endif
        guard await canContinueSession(session) else { return }

        // Reconcile pending affected-trip state before title generation.
        let recorder = self.recorder
        await PipelineGate.shared.run(touching: [.trip]) {
            await recorder.recomputeAffectedTripSummaries()
        }
        guard await canContinueSession(session) else { return }

        // Historical imports skip the live pipeline’s recent-stay reclassification.
        var isForeground = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #if DEBUG
        if let pipeline = Self.pipelineForTesting { isForeground = pipeline.isForeground }
        #endif
        if isForeground {
            guard await canContinueSession(session) else { return }
            // Uncap bulk title generation; cancellation and thermal checks still bound the pass.
            let classifier = self.classifier
            // A pass already in flight may have read the store before these
            // stays: wait for it and run this one.
            let classification = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, waitingForInFlight: true
            )
            guard await canContinueSession(session) else { return }
            guard classification.completed else {
                // The stays are durable but the pass did not commit (a failed
                // read or save, or a thermal stop). Pause like a clustering
                // failure: the resumed run finalizes again.
                await updateRunStatus(session, to: .paused, error: "importError.finalizationSaveFailed")
                return
            }
            _ = await classifier.generateTitlesStage(
                maxTripsPerCall: nil)
            guard await canContinueSession(session) else { return }
            _ = await titleLocalizer
                .generateLocalizedTitlesStage(maxTripsPerCall: nil)
        } else {
            logger.info("Skipping TripClassifier — app is not foreground; next TripsListView.task will pick it up.")
        }

        guard await finishFinalizedImport(session) else { return }

        // Detached geocoding lets finalization return promptly but holds no execution assertion.
        // Background imports also need a BGProcessingTask because iOS may suspend the detached drain.
        // The drain stops on cancellation, thermal pressure, or Low Power Mode.
        Task.detached(priority: .background) {
            // The drain acquires PipelineGate per bounded chunk so live SLC saves can interleave.
            // Do NOT re-wrap in PipelineGate.run.
            await recorder.retryAllFailedGeocodingGated()
        }

        if !isForeground {
            // BGProcessingTask reschedules early stops until the backlog is drained.
            await AppDelegate.scheduleGeocodeBackfill()
        }
    }

    // MARK: - State row helpers

    /// Match snapshot selection, including the store-local UUID-twin tiebreak.
    private func freshState(in context: ModelContext) throws -> PhotoImportState? {
        try PhotoImportStateSnapshot.fetchState(in: context)
    }

    /// How long another device's `.running` row must go without a
    /// `lastUpdated` bump before this device may resume or restart it
    /// (60 s stall heuristic + 30 s CloudKit propagation slack).
    nonisolated static let foreignSessionTakeoverSeconds: TimeInterval = 90

    private func prepareNewState(originDeviceID: String) throws -> PhotoImportStateSnapshot {
        guard !isRunning else { throw PhotoImportError.alreadyRunning }
        let context = ModelContext(modelContainer)
        let state: PhotoImportState
        if let existing = try freshState(in: context) {
            guard existing.status != .running || existing.originDeviceID == originDeviceID
                || Date.now.timeIntervalSince(existing.lastUpdated) >= Self.foreignSessionTakeoverSeconds else {
                throw PhotoImportError.alreadyRunning
            }
            state = existing
        } else {
            state = PhotoImportState(originDeviceID: originDeviceID)
            context.insert(state)
        }
        state.originDeviceID = originDeviceID
        state.startedAt = max(Date.now, state.startedAt.addingTimeInterval(0.001))
        state.completedAt = nil
        state.status = .running
        state.totalAssetCount = 0
        state.processedAssetCount = 0
        state.acceptedPingCount = 0
        state.watermarkCreationDate = nil
        state.watermarkLocalIdentifier = nil
        state.lastError = nil
        state.cancelRequested = false
        state.lastUpdated = .now
        do { try context.save() }
        catch { throw PhotoImportError.persistenceFailure(error.localizedDescription) }
        try PhotoImportCheckpointJournal.seed(PhotoImportStateSnapshot(from: state), in: modelContainer)
        return PhotoImportStateSnapshot(from: state)
    }

    private func prepareResumedState(originDeviceID: String) throws -> PhotoImportStateSnapshot {
        guard !isRunning else { throw PhotoImportError.alreadyRunning }
        let context = ModelContext(modelContainer)
        guard let state = try freshState(in: context),
              state.status == .running || state.status == .paused || state.status == .failed else {
            throw PhotoImportError.noResumableState
        }
        // Another device's session may be resumed only once its loop has
        // demonstrably stopped updating; the resuming device then owns it.
        if state.status == .running, state.originDeviceID != originDeviceID,
           Date.now.timeIntervalSince(state.lastUpdated) < Self.foreignSessionTakeoverSeconds {
            throw PhotoImportError.alreadyRunning
        }
        // The local journal is authoritative only for this exact owning
        // session. It never recounts earlier imports or another device's rows.
        try PhotoImportCheckpointJournal.restore(into: state, in: context)
        state.originDeviceID = originDeviceID
        // A new invocation gets a new generation even on the same device.
        // Delayed status writes from the previous invocation cannot pause it.
        state.startedAt = max(Date.now, state.startedAt.addingTimeInterval(0.001))
        state.status = .running
        state.cancelRequested = false
        state.lastError = nil
        state.lastUpdated = .now
        do { try context.save() }
        catch { throw PhotoImportError.persistenceFailure(error.localizedDescription) }
        try PhotoImportCheckpointJournal.seed(PhotoImportStateSnapshot(from: state), in: modelContainer)
        return PhotoImportStateSnapshot(from: state)
    }

    /// The pipeline actors this import writes through.
    var recorder: PingRecorder {
        #if DEBUG
        if let pipeline = Self.pipelineForTesting { return pipeline.recorder }
        #endif
        return AppDelegate.pingRecorder
    }

    private var clusterer: StayClusterer {
        #if DEBUG
        if let pipeline = Self.pipelineForTesting { return pipeline.clusterer }
        #endif
        return AppDelegate.stayClusterer
    }

    private var classifier: TripClassifier {
        #if DEBUG
        if let classifier = Self.pipelineForTesting?.classifier { return classifier }
        #endif
        return AppDelegate.tripClassifier
    }

    private var titleLocalizer: TripTitleLocalizationService {
        #if DEBUG
        if let localizer = Self.pipelineForTesting?.titleLocalizer { return localizer }
        #endif
        return AppDelegate.tripTitleLocalizationService
    }

    #if DEBUG
    /// Fixture-store actors for a nonempty run; `isForeground` false skips
    /// the classifier and title stages, which use the app's own actors unless
    /// `classifier` and `titleLocalizer` are given.
    nonisolated struct PipelineForTesting: Sendable {
        let recorder: PingRecorder
        let clusterer: StayClusterer
        var isForeground = false
        var classifier: TripClassifier?
        var titleLocalizer: TripTitleLocalizationService?
    }

    /// One library asset as the import loop reads it.
    nonisolated struct AssetForTesting: Sendable {
        let creationDate: Date?
        let candidate: ImportedPingCandidate?
    }

    @TaskLocal static var readAccessForTesting: Bool?
    @TaskLocal static var failCancellationSaveForTesting = false
    /// Replaces the PhotoKit library; an empty array is an empty library.
    @TaskLocal static var libraryForTesting: [AssetForTesting]?
    @TaskLocal static var pipelineForTesting: PipelineForTesting?
    @TaskLocal static var afterBatchCommitForTesting: (@Sendable (PhotoImportStateSnapshot) async -> Void)?
    @TaskLocal static var finalizationHeartbeatIntervalForTesting: Duration?
    @TaskLocal static var afterFinalizationClusteringForTesting: (@Sendable () async -> Void)?

    func prepareResumedStateForTesting(originDeviceID: String) throws -> PhotoImportStateSnapshot {
        try prepareResumedState(originDeviceID: originDeviceID)
    }

    func prepareNewStateForTesting(originDeviceID: String) throws -> PhotoImportStateSnapshot {
        try prepareNewState(originDeviceID: originDeviceID)
    }

    private var beforeCompletionForTesting: (@Sendable () async -> Void)?

    func stopAfterCheckpointDriftForTesting(_ session: PhotoImportStateSnapshot) async {
        await stopAfterCheckpointDrift(session)
    }

    func updateRunStatusForTesting(_ expected: PhotoImportStateSnapshot, to status: ImportStatus) async {
        await updateRunStatus(expected, to: status)
    }

    func finishFinalizedImportForTesting(
        _ expected: PhotoImportStateSnapshot,
        beforeCompletion: (@Sendable () async -> Void)? = nil
    ) async {
        beforeCompletionForTesting = beforeCompletion
        defer { beforeCompletionForTesting = nil }
        _ = await finishFinalizedImport(expected)
    }
    #endif

    // MARK: - System Pressure

    /// Memory-pressure override wins over thermal sizing; critical thermal state exits before this call.
    private func currentBatchSize() -> Int {
        if let override = batchSizeOverride {
            return override
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            return Self.defaultBatchSize / 2
        case .nominal, .fair, .critical:
            return Self.defaultBatchSize
        @unknown default:
            return Self.defaultBatchSize
        }
    }

    /// Memory warnings reduce future batches until the next start; saving still occurs at batch boundaries.
    func handleMemoryWarning() {
        guard batchSizeOverride == nil || batchSizeOverride! > 50 else { return }
        batchSizeOverride = 50
        logger.warning("Memory warning received — pinning batch size to 50 for the rest of the session.")
    }

    /// Lookup failure permits import. Important-usage capacity includes evictable caches for this user-requested work.
    nonisolated private static func availableDiskSpaceBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
    }

    // MARK: - PhotoKit helpers

    /// Lazy PhotoKit count for progress; may drift as the library grows.
    private func totalAssetCountEstimate() -> Int {
        #if DEBUG
        if let library = Self.libraryForTesting { return library.filter { $0.creationDate != nil }.count }
        #endif
        let options = PHFetchOptions()
        // Estimate and enumeration must both exclude dateless assets to share a denominator.
        options.predicate = NSPredicate(format: "creationDate != nil")
        let result = PHAsset.fetchAssets(with: options)
        return result.count
    }

    /// Keep PhotoKit's lazy, fixed membership result for this run. Runtime
    /// indices advance through ties; only complete cohorts are persisted.
    /// New assets are picked up by a subsequent scan.
    private func fetchAssets(afterCreationDate: Date?, replayBoundary: Bool) -> PhotoImportAssets {
        #if DEBUG
        if let library = Self.libraryForTesting {
            let matching = library.filter { asset in
                guard let date = asset.creationDate else { return false }
                guard let afterCreationDate else { return true }
                return replayBoundary ? date >= afterCreationDate : date > afterCreationDate
            }.sorted { $0.creationDate! < $1.creationDate! }
            return PhotoImportAssets(count: matching.count,
                                     creationDate: { matching[$0].creationDate },
                                     candidate: { matching[$0].candidate })
        }
        #endif
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if let date = afterCreationDate {
            options.predicate = NSPredicate(
                format: replayBoundary ? "creationDate >= %@" : "creationDate > %@",
                date as NSDate
            )
        } else {
            options.predicate = NSPredicate(format: "creationDate != nil")
        }
        let result = PHAsset.fetchAssets(with: options)
        return PhotoImportAssets(count: result.count,
                                 creationDate: { result.object(at: $0).creationDate },
                                 candidate: { Self.candidate(for: result.object(at: $0)) })
    }

    /// The synthetic ping an accepted asset contributes.
    nonisolated static func candidate(for asset: PHAsset) -> ImportedPingCandidate? {
        guard shouldAccept(asset: asset),
              let creation = asset.creationDate, let location = asset.location else { return nil }
        return ImportedPingCandidate(
            timestamp: creation,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            verticalAccuracy: location.verticalAccuracy
        )
    }

    nonisolated static func shouldAccept(asset: PHAsset) -> Bool {
        guard let creationDate = asset.creationDate else { return false }
        // Impossible date — too old or in the future.
        if creationDate < earliestPlausibleDate { return false }
        if creationDate > .now { return false }
        // Screenshot (sticky even if user later "Adjust → Location" added GPS).
        if asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        // Shared-album items: someone else's photos, different PHCloudIdentifier
        // semantics from the user's own library. Match PhotoService's filter.
        if asset.sourceType == .typeCloudShared { return false }
        // Missing location: still a valid photo for `PhotoService.photosForTrip`'s
        // temporal matching at read time, but useless as a synthetic ping.
        guard let location = asset.location else { return false }
        let coord = location.coordinate
        // Null Island — almost always EXIF/zero-init garbage, never a real fix.
        if coord.latitude == 0 && coord.longitude == 0 { return false }
        // Sentinel / unusable accuracy.
        if location.horizontalAccuracy < 0 { return false }
        if location.horizontalAccuracy > 1000 { return false }
        // The 5 km cutoff rejects airborne photos while retaining high-altitude cities; rare ground visits above it are intentionally excluded.
        // It applies only with valid verticalAccuracy ≤ 200 m: uncertain or invalid EXIF altitude must not discard an otherwise usable ground fix.
        if location.altitude > 5000,
           location.verticalAccuracy >= 0,
           location.verticalAccuracy <= 200 {
            return false
        }
        return true
    }

    /// Authorized and limited access both permit import of the available library subset.
    @MainActor
    private static func hasReadAccess() -> Bool {
        #if DEBUG
        if let readAccessForTesting { return readAccessForTesting }
        #endif
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
}

