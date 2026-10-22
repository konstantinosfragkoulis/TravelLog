//
//  TripSplitHint.swift
//  TravelLog
//

import Foundation

/// The retired split hint's device-local keys. The trip page's "Did you go
/// home?" question replaced the hint card; the keys stay because backups
/// carry them (`BackupPreferences`) and `dismissedKey` still records that the
/// user has split a trip, so the Split Trip tip never shows again.
///
/// Deliberately NOT synced and NOT reset by Delete All Data: this is
/// feature-education history, not travel data.
nonisolated enum TripSplitHint {
    nonisolated static let dismissedKey = "splitHintDismissed_v1"
    /// Written only by older builds; read back only to round-trip backups.
    nonisolated static let seenTripIDsKey = "splitHintSeenTripIDs_v1"
}
