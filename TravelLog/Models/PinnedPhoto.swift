//
//  PinnedPhoto.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 12/5/26.
//

import Foundation
import SwiftData

/// A photo the user has pinned to the top of a specific trip.
///
/// Mirrors `HiddenPhoto` in shape (per-trip, keyed by `PHAsset.localIdentifier`)
/// but with the opposite effect: pinned photos surface in a new "Pinned"
/// section at the top of the trip's photo UI. They still appear in their
/// normal stay grouping below — pinning is additive promotion, not filtering.
///
/// Per-trip (not global) so that a photo pinned in Trip A leaves it un-pinned
/// in Trip B even if it also matches there.
@Model
final class PinnedPhoto {

    var id: UUID = UUID()

    /// The `PHAsset.localIdentifier` of the pinned photo. Per-device:
    /// on iCloud Photos the same photo has a different `localIdentifier`
    /// on each device. See `HiddenPhoto.localIdentifier` for full details.
    var localIdentifier: String = ""

    /// The `PHCloudIdentifier.archivalStringValue` for the same photo — device-
    /// independent and stable across an iCloud-Photos-synced library.
    /// Resolved asynchronously after pin; optional for the same reasons
    /// documented on `HiddenPhoto.cloudIdentifier`.
    var cloudIdentifier: String?

    /// The Trip this photo is pinned within.
    var tripID: UUID = UUID()

    /// When the user pinned this photo (for sorting "recently pinned" if needed).
    var pinnedAt: Date = Date.now

    init(localIdentifier: String, tripID: UUID) {
        self.id = UUID()
        self.localIdentifier = localIdentifier
        self.tripID = tripID
        self.pinnedAt = .now
    }
}
