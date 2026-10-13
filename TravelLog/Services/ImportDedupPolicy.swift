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

    /// The widest window any source uses.
    ///
    /// Used for the `ImportDedupIndex` bucket width. The index probes buckets
    /// b-1...b+1, so this must be >= every source's window to avoid missing rows.
    static let maxWindowSeconds: TimeInterval = 90
}
