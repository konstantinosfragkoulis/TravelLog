//
//  PhotoImportState.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Singleton-style state record tracking the user's photo-library import.
///
/// Pings, acceptance counts and completed-date checkpoints commit together.
/// Incomplete timestamp cohorts replay after interruption; their processed
/// count is committed only when the whole cohort has been examined.
///
/// One row at steady state. CloudKit-synced
/// so a second device sees "import in progress on another device" and can
/// disable its own Start button. The "singleton across devices" guarantee
/// is enforced by `PhotoImportStateDeduplicator`, which keeps the smallest
/// immutable `id.uuidString` and deletes the rest.
///
/// Added in V8.
@Model
final class PhotoImportState {

    var id: UUID = UUID()

    /// Writer generation: refreshed for each start or resume invocation.
    var startedAt: Date = Date.now

    /// When it finished cleanly. Nil while running, paused, or after a crash.
    var completedAt: Date?

    /// Backs `ImportStatus`. Stored as `String` for the same reasons as
    /// `LocationPing.sourceRaw` (see DataSource.swift).
    var statusRaw: String = ImportStatus.idle.rawValue

    /// Best-effort estimate of the total `PHAsset` count at start. Used by
    /// the BG task's `NSProgress.totalUnitCount` and the Live-Activity-less
    /// system progress UI. May drift if the library changes during the scan.
    var totalAssetCount: Int = 0

    /// Assets in fully examined timestamp cohorts, including rejected and
    /// deduped assets. Progress can pause while a large cohort is incomplete.
    /// Legacy checkpoints retain their historical, approximate counts.
    var processedAssetCount: Int = 0

    /// Committed new pings, including those in an unfinished date cohort.
    /// This can exceed processedAssetCount until that cohort completes.
    var acceptedPingCount: Int = 0

    /// Latest fully examined creation-date cohort when the identifier is nil.
    /// A nonnil identifier marks a legacy partial cohort to replay inclusively.
    var watermarkCreationDate: Date?

    /// Legacy boundary identifier. Cleared after its entire date cohort has
    /// replayed; new checkpoints leave this nil. That replay preserves the
    /// historical processed count because the previously counted subset is
    /// unknowable. No identifier ordering or encoded cursor is persisted.
    var watermarkLocalIdentifier: String?

    /// Last human-readable error message. Nil on success. Surfaced in the
    /// launch banner and the Settings row.
    var lastError: String?

    /// Bumped on every checkpoint. Used exclusively by **this app's** UI
    /// heuristics and tiebreaks — NOT by CloudKit itself.
    ///   - `RootView` shows the recovery banner when a `.running` row's
    ///     `lastUpdated > 60s` ago (heuristic that the BG task died).
    ///   - `SettingsView` shows "Import in progress on another device" only
    ///     when another device's row was updated within the last 90 seconds.
    ///   - `PhotoImportStateDeduplicator` keeps the row with the smallest
    ///     `id.uuidString` (immutable key), preserving its `startedAt` writer
    ///     generation in every lifecycle state.
    ///     `lastUpdated` is not part of the deduplicator's tiebreak, and
    ///     `PhotoImportService.fetchState()` selects by the same key.
    /// `NSPersistentCloudKitContainer` does last-writer-wins per its own
    /// internal record-modification metadata; the app's `lastUpdated`
    /// field plays no part in CloudKit-side merge resolution.
    var lastUpdated: Date = Date.now

    /// Set by the cancel button. Observed by the import loop at every batch
    /// boundary; the loop checkpoints and exits cleanly on `true`.
    var cancelRequested: Bool = false

    /// Identifier of the device that wrote this row. Used by other devices'
    /// Settings UI to display "Import in progress on another device" when
    /// `statusRaw == "running"` and `originDeviceID != ours`. Resume and
    /// restart transfer ownership to the resuming device once the previous
    /// owner's row has stopped updating for 90 s. Best-effort —
    /// `UIDevice.identifierForVendor` can rotate when the user reinstalls.
    var originDeviceID: String = ""

    init(originDeviceID: String) {
        self.id = UUID()
        self.startedAt = .now
        self.statusRaw = ImportStatus.idle.rawValue
        self.lastUpdated = .now
        self.originDeviceID = originDeviceID
    }

    func canResume(onDeviceID deviceID: String) -> Bool {
        originDeviceID == deviceID
            && (status == .running || status == .paused || status == .failed)
    }

    /// Type-safe accessor for `statusRaw`. Unknown raw values fall back to
    /// `.idle` so a row written by a future build doesn't crash today's UI.
    var status: ImportStatus {
        get { ImportStatus(rawValue: statusRaw) ?? .idle }
        set { statusRaw = newValue.rawValue }
    }
}

// MARK: - ImportStatus

/// Lifecycle states for a photo-library import. Persisted via
/// `PhotoImportState.statusRaw`.
enum ImportStatus: String, Codable, CaseIterable, Sendable {
    /// No import has started, or the previous one was discarded.
    case idle = "idle"

    /// A `BGContinuedProcessingTask` is currently working (or was, before a
    /// crash or force-quit; see `PhotoImportService` recovery).
    case running = "running"

    /// Cleanly paused via `BGContinuedProcessingTask.expirationHandler`.
    /// The watermark is valid; calling `resume()` continues from it.
    case paused = "paused"

    /// All assets walked, all stays clustered, post-processing done.
    case completed = "completed"

    /// Unrecoverable error during the run. `lastError` carries detail.
    case failed = "failed"

    /// User-initiated cancellation. Watermark may still be valid (for a
    /// future fresh-start re-scan) but `resume()` is not offered.
    case cancelled = "cancelled"
}
