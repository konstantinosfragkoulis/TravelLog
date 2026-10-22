//
//  PhotoImportService+StateAndRecovery.swift
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

// MARK: - Snapshot

/// Sendable value-type view of `PhotoImportState`, for cross-actor reads.
/// `@Model` types are not safely `Sendable`, so the actor never hands one
/// out — it constructs a snapshot at the read point.
struct PhotoImportStateSnapshot: Sendable, Equatable {
    let persistentModelID: PersistentIdentifier
    let id: UUID
    let status: ImportStatus
    let startedAt: Date
    let completedAt: Date?
    let totalAssetCount: Int
    let processedAssetCount: Int
    let acceptedPingCount: Int
    let watermarkCreationDate: Date?
    let watermarkLocalIdentifier: String?
    let lastError: String?
    let lastUpdated: Date
    let cancelRequested: Bool
    let originDeviceID: String

    nonisolated func canResume(onDeviceID deviceID: String) -> Bool {
        originDeviceID == deviceID
            && (status == .running || status == .paused || status == .failed)
    }

    nonisolated func hasSameCheckpoint(as other: Self) -> Bool {
        persistentModelID == other.persistentModelID
            && id == other.id && startedAt == other.startedAt && originDeviceID == other.originDeviceID
            && processedAssetCount == other.processedAssetCount
            && acceptedPingCount == other.acceptedPingCount
            && watermarkCreationDate == other.watermarkCreationDate
            && watermarkLocalIdentifier == other.watermarkLocalIdentifier
    }

    nonisolated static func fetch(in context: ModelContext) throws -> Self? {
        try fetchState(in: context).map(Self.init(from:))
    }

    nonisolated static func fetchState(in context: ModelContext) throws -> PhotoImportState? {
        let rows = try context.fetch(FetchDescriptor<PhotoImportState>())
        return selectState(from: rows)
    }

    /// Keep the smallest logical UUID. Equal-UUID twins use the smallest
    /// persistent identifier within this store; this is not a cross-device key.
    nonisolated static func selectState(from rows: [PhotoImportState]) -> PhotoImportState? {
        rows.filter { !$0.isDeleted }.min {
            $0.id == $1.id
                ? $0.persistentModelID < $1.persistentModelID
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Fraction in [0, 1]. Returns 0 if `totalAssetCount` hasn't been
    /// estimated yet. Clamped at 1 in case the library grew mid-import.
    var progress: Double {
        guard totalAssetCount > 0 else { return 0 }
        return min(1.0, Double(processedAssetCount) / Double(totalAssetCount))
    }

    /// Construct on the executor that owns the model's context, before
    /// passing the snapshot across actors. `nonisolated` avoids inferring
    /// main-actor isolation from the model type.
    nonisolated init(from state: PhotoImportState) {
        self.persistentModelID = state.persistentModelID
        self.id = state.id
        self.status = state.status
        self.startedAt = state.startedAt
        self.completedAt = state.completedAt
        self.totalAssetCount = state.totalAssetCount
        self.processedAssetCount = state.processedAssetCount
        self.acceptedPingCount = state.acceptedPingCount
        self.watermarkCreationDate = state.watermarkCreationDate
        self.watermarkLocalIdentifier = state.watermarkLocalIdentifier
        self.lastError = state.lastError
        self.lastUpdated = state.lastUpdated
        self.cancelRequested = state.cancelRequested
        self.originDeviceID = state.originDeviceID
    }
}

// MARK: - Errors

/// Public errors thrown by `PhotoImportService`. `Sendable` so they can
/// cross actor boundaries naturally.
enum PhotoImportError: Error, Sendable {
    /// `start()` or `resume()` invoked while an import is already running.
    case alreadyRunning

    /// Photo library access is `.denied` / `.notDetermined` / `.restricted`.
    /// The caller should route the user to the system Settings or to the
    /// in-app onboarding photo permission step.
    case noPhotoPermission

    /// `resume()` invoked with no recoverable state (no state row, or row is
    /// in `idle` / `completed` / `cancelled`).
    case noResumableState

    /// SwiftData write failed. The underlying error message is forwarded so
    /// `state.lastError` and the Settings UI can surface it verbatim.
    case persistenceFailure(String)

    /// A destructive repair could not prove that every ping referenced by a
    /// touched Stay is present locally. Usually transient CloudKit hydration;
    /// callers should leave the import intact and offer a later retry.
    case incompleteLocalData

    /// Referenced rows are present, but their immutable identity/coordinates
    /// disagree or cannot produce valid geometry. Discard remains untouched
    /// because choosing an arbitrary survivor would sync fabricated data.
    case inconsistentLocalData

    /// Forward BG submission errors to Settings; submissions require foreground execution and a registered identifier.
    case bgTaskSubmissionFailed(String)

    /// Low Power Mode blocks both new imports and resumes.
    case lowPowerMode

    /// Insufficient disk space; forward available bytes for the Settings message.
    case insufficientDiskSpace(bytesAvailable: Int64)

    /// iCloud is on, this device has not imported yet, and the account may
    /// hold another device's history: a fresh scan would duplicate its trips.
    case awaitingCloudHistory
}

extension PhotoImportError {
    var userFacingMessage: String {
        switch self {
        case .alreadyRunning:
            return String(localized: "settings.photo-import.error.already-running", defaultValue: "An import is already in progress. Wait for it to finish or cancel it first.", comment: "Photo import error when another import is already running.")
        case .noPhotoPermission:
            return String(localized: "settings.photo-import.error.no-permission", defaultValue: "Photo access is required. Grant access in iOS Settings → Privacy → Photos → TravelLog.", comment: "Photo import error when photo permission is missing.")
        case .noResumableState:
            return String(localized: "settings.photo-import.error.no-resumable-state", defaultValue: "There's no paused import to resume.", comment: "Photo import error when no resumable import exists.")
        case .persistenceFailure(let detail):
            return String(localized: "settings.photo-import.error.persistence", defaultValue: "Could not save import state: \(detail)", comment: "Photo import error when its state could not be saved.")
        case .incompleteLocalData:
            return String(localized: "settings.photo-import.error.incomplete-local-data", defaultValue: "Some location records are still syncing from iCloud. No imported data was deleted. Wait for sync to finish, then try again.", comment: "Photo import deletion error when required iCloud data is still syncing.")
        case .inconsistentLocalData:
            return String(localized: "settings.photo-import.error.inconsistent-local-data", defaultValue: "The imported data could not be safely reconstructed, so nothing was deleted. Close and reopen TravelLog, then try again.", comment: "Photo import deletion error when local imported data is inconsistent.")
        case .bgTaskSubmissionFailed(let detail):
            return String(localized: "settings.photo-import.error.background-task", defaultValue: "Could not start background task: \(detail)", comment: "Photo import error when the background task could not start.")
        case .lowPowerMode:
            return String(localized: "settings.photo-import.error.low-power-mode", defaultValue: "Low Power Mode is enabled. Disable it (Settings → Battery → Low Power Mode) or plug in your iPhone, then try again.", comment: "Photo import error when Low Power Mode prevents importing.")
        case .insufficientDiskSpace(let bytesAvailable):
            let mb = bytesAvailable / (1024 * 1024)
            return String(localized: "settings.photo-import.error.insufficient-storage", defaultValue: "Not enough free space (\(mb, format: .number.grouping(.never)) MB available). Free up some storage and try again. The import needs at least 100 MB.", comment: "Photo import error showing available storage in megabytes.")
        case .awaitingCloudHistory:
            return String(localized: "settings.photo-import.error.awaiting-cloud-history", defaultValue: "Your trips may still be arriving from iCloud. Scanning now could duplicate them, so try again once they have.", comment: "Photo import error when another device's history may still be syncing from iCloud.")
        }
    }
}

/// Device-local write-ahead record for the one photo-import batch in flight.
/// This file is beside the local SwiftData store, never synchronized by CloudKit.
/// The saved state row is a progress mirror; only the originating device may
/// recover it from this journal. Existing sessions without a journal retain
/// their historical counters because those cannot safely be reconstructed.
nonisolated enum PhotoImportCheckpointJournal {
    struct Checkpoint: Codable, Sendable {
        var id: UUID
        var startedAt: Date
        var originDeviceID: String
        var physicalRow: Data?
        var processed: Int
        var accepted: Int
        var watermark: Date?
        var legacyIdentifier: String?

        init(_ snapshot: PhotoImportStateSnapshot) {
            id = snapshot.id
            startedAt = snapshot.startedAt
            originDeviceID = snapshot.originDeviceID
            physicalRow = Self.physicalIdentity(snapshot.persistentModelID)
            processed = snapshot.processedAssetCount
            accepted = snapshot.acceptedPingCount
            watermark = snapshot.watermarkCreationDate
            legacyIdentifier = snapshot.watermarkLocalIdentifier
        }

        private static func physicalIdentity(_ identifier: PersistentIdentifier) -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(identifier)
        }

        func matches(_ state: PhotoImportState) -> Bool {
            state.id == id && state.startedAt == startedAt && state.originDeviceID == originDeviceID
                && samePhysicalRow(as: state)
        }

        func samePhysicalRow(as state: PhotoImportState) -> Bool {
            guard let physicalRow,
                  let currentPhysicalRow = Self.physicalIdentity(state.persistentModelID) else { return false }
            return physicalRow == currentPhysicalRow
        }

        func apply(to state: PhotoImportState) {
            state.processedAssetCount = processed
            state.acceptedPingCount = accepted
            state.watermarkCreationDate = watermark
            state.watermarkLocalIdentifier = legacyIdentifier
        }
    }

    struct Entry: Codable, Sendable {
        var committed: Checkpoint
        var pending: Checkpoint?
        var insertedPingIDs: [UUID] = []
    }

    // In-memory stores have no durable lifetime. Keep their journals isolated
    // just like their rows; they must never touch the application's sidecar.
    private final class MemoryEntry: @unchecked Sendable {
        weak var container: ModelContainer?
        let entry: Entry
        init(container: ModelContainer, entry: Entry) {
            self.container = container
            self.entry = entry
        }
    }
    private static let memory = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: MemoryEntry]())

    private static func fileURL(in container: ModelContainer) -> URL? {
        guard let configuration = container.configurations.first,
              !configuration.isStoredInMemoryOnly else { return nil }
        return configuration.url.appendingPathExtension("photo-import-checkpoint.json")
    }

    static func read(in container: ModelContainer) throws -> Entry? {
        guard let url = fileURL(in: container) else {
            return memory.withLock {
                guard let value = $0[ObjectIdentifier(container)], value.container === container else { return nil }
                return value.entry
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
    }

    #if DEBUG
    @TaskLocal static var failWriteForTesting = false
    @TaskLocal static var failSeedForTesting = false
    @TaskLocal static var failClearForTesting = false
    #endif

    static func write(_ entry: Entry, in container: ModelContainer) throws {
        #if DEBUG
        if failWriteForTesting { throw CocoaError(.fileWriteUnknown) }
        #endif
        guard let url = fileURL(in: container) else {
            memory.withLock {
                $0 = $0.filter { $0.value.container != nil }
                $0[ObjectIdentifier(container)] = MemoryEntry(container: container, entry: entry)
            }
            return
        }
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    static func seed(_ snapshot: PhotoImportStateSnapshot, in container: ModelContainer) throws {
        try seed(Checkpoint(snapshot), in: container)
    }

    static func seed(_ checkpoint: Checkpoint, in container: ModelContainer) throws {
        #if DEBUG
        if failSeedForTesting { throw CocoaError(.fileWriteUnknown) }
        #endif
        try write(Entry(committed: checkpoint), in: container)
    }

    static func begin(previous: PhotoImportStateSnapshot, intended: Checkpoint,
                      insertedPingIDs: [UUID], in container: ModelContainer) throws {
        try write(Entry(committed: Checkpoint(previous), pending: intended,
                        insertedPingIDs: insertedPingIDs), in: container)
    }

    /// Resolve a crash after the write-ahead record but before its finalization.
    /// All freshly generated IDs present proves the atomic database save landed.
    /// Missing IDs cannot distinguish an interrupted save from a later deletion
    /// or incomplete hydration, so that ambiguous recovery fails closed.
    static func restore(into state: PhotoImportState, in context: ModelContext) throws {
        guard var entry = try read(in: context.container) else { return }
        guard entry.committed.id == state.id, entry.committed.originDeviceID == state.originDeviceID else { return }
        // A journal left behind by an OLDER generation of the SAME physical
        // row (its replacement's seed never landed) describes progress the
        // newer generation already absorbed when it was prepared; drop it
        // rather than wedge Resume. A different physical row at a newer
        // generation proves nothing about that progress and fails closed.
        if entry.committed.startedAt < state.startedAt {
            guard entry.committed.samePhysicalRow(as: state) else { throw PhotoImportError.inconsistentLocalData }
            try clear(in: context.container)
            return
        }
        // A journal NEWER than the row means an older synced generation
        // overwrote the local row, and a different physical row with the same
        // generation is a replacement. Neither proves ownership of that
        // progress; recovery fails closed and Settings offers a fresh scan.
        guard entry.committed.matches(state) else { throw PhotoImportError.inconsistentLocalData }
        if let pending = entry.pending {
            let ids = entry.insertedPingIDs
            if !ids.isEmpty {
                var present: Set<UUID> = []
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let rows = try context.fetch(FetchDescriptor<LocationPing>(predicate: #Predicate { chunk.contains($0.id) }))
                    present.formUnion(rows.filter { !$0.isDeleted }.map(\.id))
                }
                guard present.count == Set(ids).count else {
                    throw PhotoImportError.inconsistentLocalData
                }
                entry.committed = pending
            } else if state.processedAssetCount == pending.processed,
                      state.acceptedPingCount == pending.accepted,
                      state.watermarkCreationDate == pending.watermark,
                      state.watermarkLocalIdentifier == pending.legacyIdentifier {
                entry.committed = pending
            }
            // With no inserted pings and no checkpoint witness, replaying from
            // the previous cohort is safe; acceptance has not increased.
            entry.pending = nil
            entry.insertedPingIDs = []
            try write(entry, in: context.container)
        }
        entry.committed.apply(to: state)
    }

    static func clear(in container: ModelContainer) throws {
        #if DEBUG
        if failClearForTesting { throw CocoaError(.fileWriteUnknown) }
        #endif
        guard let url = fileURL(in: container) else {
            _ = memory.withLock { $0.removeValue(forKey: ObjectIdentifier(container)) }
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// The fixed, creation-date-ordered asset list one import pass walks.
nonisolated struct PhotoImportAssets {
    let count: Int
    let creationDate: (Int) -> Date?
    /// Nil for an asset that contributes no ping.
    let candidate: (Int) -> ImportedPingCandidate?
}
