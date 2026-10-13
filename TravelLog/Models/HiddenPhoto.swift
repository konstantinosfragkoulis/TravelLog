//
//  HiddenPhoto.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 12/5/26.
//

import Foundation
import SwiftData

/// A photo the user has chosen to suppress from a specific trip.
///
/// PhotoKit's own `PHAsset.isHidden` flag toggles visibility in the *system*
/// Photos library's Hidden album — we explicitly do NOT touch that. Instead,
/// we keep our own per-trip block-list keyed by `localIdentifier`, and filter
/// matched assets at fetch time in `PhotoService.photosForTrip(_:)`.
///
/// Per-trip (not global) so that if the same photo legitimately matches two
/// different trips, hiding it from one doesn't silently hide it from both.
@Model
final class HiddenPhoto {

    var id: UUID = UUID()

    /// The `PHAsset.localIdentifier` of the suppressed photo. Per-device:
    /// on iCloud Photos the same photo has a different `localIdentifier` on
    /// each device. We always store this for same-device matching, and where
    /// possible we also store `cloudIdentifier` for cross-device matching.
    var localIdentifier: String = ""

    /// The `PHCloudIdentifier.archivalStringValue` for the same photo — device-
    /// independent and stable across an iCloud-Photos-synced library.
    ///
    /// Optional because: (1) the user may not have iCloud Photos enabled,
    /// (2) the asset may not yet have a cloud ID at write time (resolved
    /// asynchronously in the background after hide/pin), (3) lightweight
    /// SwiftData migrations cannot back-fill non-optional fields, and
    /// (4) CloudKit requires new attributes on existing models to be
    /// optional or default-defaulted.
    ///
    /// Read path: `PhotoService.cloudToLocalCache` maps this back to *this
    /// device's* `PHAsset.localIdentifier` so the filter can match the
    /// same photo across devices.
    var cloudIdentifier: String?

    /// The Trip this photo was hidden from.
    var tripID: UUID = UUID()

    /// When the user hid this photo (for future "recently hidden" UI).
    var hiddenAt: Date = Date.now

    init(localIdentifier: String, tripID: UUID) {
        self.id = UUID()
        self.localIdentifier = localIdentifier
        self.tripID = tripID
        self.hiddenAt = .now
    }
}
