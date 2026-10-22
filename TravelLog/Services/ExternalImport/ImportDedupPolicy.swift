//
//  ImportDedupPolicy.swift
//  TravelLog
//
//  Source-aware import dedup thresholds.
//
//  The 90 s / 200 m rule is right for SYNTHESIZED fixes — photo EXIF (GPS
//  accuracy varies hugely, and shutter timestamps drift from device-clock
//  event time) and Google Timeline visit interiors (interpolated, not
//  measured). It is wrong for a RECORDED GPX track, whose points are real GNSS
//  fixes the parser has ALREADY thinned to >= 60 s apart:
//
//      p0 kept; p1 at +60 s is inside the 90 s window and, at walking pace,
//      ~83 m < 200 m -> dropped; p2 at +120 s is outside 90 s of p0 -> kept.
//
//  Exactly alternate points would be discarded, so a walking or running track
//  would import at half the resolution the file actually contains.
//
//  Both consumers must use this type. `PingRecorder` applies the rule at
//  insert time; `PhotoImportPingDeduplicator` re-applies it post-hoc on every
//  launch and every CloudKit push, and its own doc states the two rules must
//  agree. Relaxing only the insert path would let the launch deduplicator
//  delete the newly admitted points hours later.
//
//  Geometry is not ownership. A Timeline or GPX fix matching a photo's
//  position is still the user's own evidence after Discard Imported Photos,
//  and a photo matching a shared fix is still theirs after Remove Shared
//  Data. Both consumers therefore collapse a match only where a removal
//  cannot take the kept row while leaving the dropped one's claim
//  (`mayRepresent`, `mayCollapse`).
//

import Foundation

nonisolated enum ImportDedupPolicy {

    struct Thresholds: Sendable, Equatable {
        let windowSeconds: TimeInterval
        let radiusMeters: Double
    }

    /// Photo and Google Timeline imports — synthesized fixes.
    /// Unchanged from the original single rule.
    static let synthesized = Thresholds(windowSeconds: 90, radiusMeters: 200)

    /// GPX — a recorded track, already thinned by the parser.
    ///
    /// INVARIANT: `windowSeconds` MUST stay strictly below
    /// `GPXImportParser.minimumSpacingSeconds`, or two consecutive points the
    /// parser deliberately kept would dedup each other again. Pinned by
    /// `ImportDedupPolicyTests`.
    ///
    /// Re-import idempotence does not depend on a wide window: re-parsing the
    /// same file yields byte-identical coordinates and timestamps, so a repeat
    /// point has dt == 0 and dd == 0 and is caught by any positive window.
    static let recordedTrack = Thresholds(windowSeconds: 15, radiusMeters: 25)

    static func thresholds(for source: DataSource) -> Thresholds {
        switch source {
        case .gpxImport: recordedTrack
        default: synthesized
        }
    }

    /// Pairwise rule for the post-hoc deduplicator, where either row could be
    /// the candidate: take the NARROWEST of the two.
    ///
    /// Symmetric on purpose — two devices must compute the same delete set for
    /// CloudKit convergence — and it can never delete a pair that insert-time
    /// dedup would have admitted under either source's own rule.
    static func pair(_ a: DataSource, _ b: DataSource) -> Thresholds {
        let x = thresholds(for: a)
        let y = thresholds(for: b)
        return Thresholds(
            windowSeconds: min(x.windowSeconds, y.windowSeconds),
            radiusMeters: min(x.radiusMeters, y.radiusMeters)
        )
    }

    /// What one user action can delete as a group. Discard Imported Photos
    /// removes every `.photoImport` row; Remove Shared Data removes the rows
    /// one share's ledger recorded; nothing removes live, Timeline, GPX or
    /// backup evidence on its own.
    enum RemovalDomain: Sendable, Equatable {
        case permanent
        case photos
        case shared
    }

    static func removalDomain(of source: DataSource) -> RemovalDomain {
        switch source {
        case .photoImport: .photos
        case .sharedImport: .shared
        default: .permanent
        }
    }

    /// Whether a stored row from `existing` may stand in for a matching
    /// candidate from `candidate`, so the candidate is not stored. Only when
    /// no removal can take the stored row while leaving the candidate's own
    /// claim: a permanent row covers anything, a photo row covers only another
    /// photo (one discard removes both), and a shared row covers nothing (each
    /// share is removed on its own, and a re-import is recognized by id).
    static func mayRepresent(existing: DataSource, candidate: DataSource) -> Bool {
        switch removalDomain(of: existing) {
        case .permanent: true
        case .photos: candidate == .photoImport
        case .shared: false
        }
    }

    /// Whether the post-hoc deduplicator may delete either row of a matching
    /// pair: only inside one removal domain. Symmetric, like `pair`, so two
    /// devices holding the same rows compute the same delete set; a pair
    /// across domains is kept, which costs one redundant map dot.
    static func mayCollapse(_ a: DataSource, _ b: DataSource) -> Bool {
        removalDomain(of: a) == removalDomain(of: b)
    }

    /// The widest window any source uses.
    ///
    /// Used for the `ImportDedupIndex` bucket width. The index probes buckets
    /// b-1...b+1, so this must be >= every source's window to avoid missing rows.
    static let maxWindowSeconds: TimeInterval = 90
}
