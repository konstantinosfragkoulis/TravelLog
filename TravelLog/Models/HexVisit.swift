//
//  HexVisit.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData

/// Tracks how many times a specific H3 resolution-6 hexagon has been visited.
///
/// This is the secondary "exploration map" feature. Each hex is ~36 km².
/// A visit is counted when a Significant Location Change ping falls in a hex
/// that differs from the previous ping's hex (reentry detection).
@Model
final class HexVisit {

    /// Per-record identity, the survivor key in `HexVisitDeduplicator`.
    /// CloudKit-safe: defaulted, non-unique. Added in
    /// schema V12. Never rewritten after insert.
    ///
    /// Only a MINTED id (`mintID()`, assigned by `init`) is replica-stable: it
    /// is set before the row's first save, so its first CloudKit export
    /// carries it. The schema default below is evaluated once per process: the
    /// V11→V12 migration gave every existing row one shared plain value, a
    /// record hydrated without `CD_id` would get that launch's value too, and
    /// different replicas can hold different plain values for the same record.
    /// Dedup therefore never keys a deletion on a plain id.
    var id: UUID = UUID()

    /// The H3 cell index as a hex string (e.g., "862a1072fffffff"). Primary key.
    var h3Index: String = ""

    /// When this hex was first entered.
    var firstVisited: Date = Date.now

    /// When this hex was most recently entered.
    var lastVisited: Date = Date.now

    /// Number of distinct entries into this hex.
    /// An entry is: first time ever, or arriving from a different hex.
    var visitCount: Int = 1

    /// Geocoded place information for display in the hex popup.
    var locality: String?
    var country: String?
    var isoCountryCode: String?

    /// The center latitude of this hex (for rendering).
    var centerLatitude: Double = 0

    /// The center longitude of this hex (for rendering).
    var centerLongitude: Double = 0

    init(
        h3Index: String,
        firstVisited: Date,
        centerLatitude: Double,
        centerLongitude: Double
    ) {
        self.id = HexVisit.mintID()
        self.h3Index = h3Index
        self.firstVisited = firstVisited
        self.lastVisited = firstVisited
        self.visitCount = 1
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
    }

    /// A random UUID (version 4 bits kept) whose first 48 bits are zero. The
    /// zero prefix marks provenance without a schema field, and it sorts every
    /// minted id before every plain one under `uuidString` order, so builds
    /// that predate minting pick the same minted survivor. 74 random bits
    /// remain; the chance that a plain UUID looks minted is 2^-48.
    nonisolated static func mintID() -> UUID {
        var bytes = UUID().uuid
        bytes.0 = 0; bytes.1 = 0; bytes.2 = 0
        bytes.3 = 0; bytes.4 = 0; bytes.5 = 0
        return UUID(uuid: bytes)
    }

    /// True for ids produced by `mintID()`.
    nonisolated static func isMintedID(_ id: UUID) -> Bool {
        let b = id.uuid
        return b.0 == 0 && b.1 == 0 && b.2 == 0 && b.3 == 0 && b.4 == 0 && b.5 == 0
    }

    /// Record a new entry into this hex.
    func recordReentry(at date: Date) {
        lastVisited = date
        visitCount += 1
    }
}
