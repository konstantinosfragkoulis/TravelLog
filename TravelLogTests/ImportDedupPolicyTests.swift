//
//  ImportDedupPolicyTests.swift
//  TravelLogTests
//
//  Pins the invariants that make the
//  source-aware import dedup safe — above all that a recorded GPX track's
//  window stays strictly below the parser's own thinning interval, which is
//  the whole reason the fix works.
//

import Foundation
import Testing
@testable import TravelLog

struct ImportDedupPolicyTests {

    /// THE invariant. If the dedup window ever reaches the parser's thinning
    /// interval, two consecutive points the parser deliberately kept would
    /// dedup each other again and the bug returns.
    @Test("a recorded track's window is strictly below the parser's thinning interval")
    func recordedTrackWindowIsBelowThinningInterval() {
        #expect(ImportDedupPolicy.recordedTrack.windowSeconds < GPXImportParser.minimumSpacingSeconds)
    }

    @Test("GPX uses the recorded-track rule; every other source uses the synthesized one")
    func sourceRouting() {
        #expect(ImportDedupPolicy.thresholds(for: .gpxImport) == ImportDedupPolicy.recordedTrack)
        #expect(ImportDedupPolicy.thresholds(for: .photoImport) == ImportDedupPolicy.synthesized)
        #expect(ImportDedupPolicy.thresholds(for: .timelineImport) == ImportDedupPolicy.synthesized)
        #expect(ImportDedupPolicy.thresholds(for: .liveSLC) == ImportDedupPolicy.synthesized)
        #expect(ImportDedupPolicy.thresholds(for: .foregroundStream) == ImportDedupPolicy.synthesized)
    }

    /// Symmetry is the convergence requirement: two devices must compute the
    /// same delete set regardless of which row they consider the candidate.
    @Test("pair() is symmetric and never wider than either side")
    func pairIsSymmetricAndNarrowest() {
        let sources: [DataSource] = [
            .gpxImport, .photoImport, .timelineImport, .liveSLC,
            .foregroundStream,
        ]
        for a in sources {
            for b in sources {
                let ab = ImportDedupPolicy.pair(a, b)
                let ba = ImportDedupPolicy.pair(b, a)
                #expect(ab == ba)

                let x = ImportDedupPolicy.thresholds(for: a)
                let y = ImportDedupPolicy.thresholds(for: b)
                #expect(ab.windowSeconds <= x.windowSeconds)
                #expect(ab.windowSeconds <= y.windowSeconds)
                #expect(ab.radiusMeters <= x.radiusMeters)
                #expect(ab.radiusMeters <= y.radiusMeters)
            }
        }
    }

    /// The index buckets and the deduplicator's sliding-window break bound are
    /// only correct while this is >= every per-source window.
    @Test("maxWindowSeconds bounds every source's window")
    func maxWindowBoundsAllSources() {
        for source in [
            DataSource.gpxImport, .photoImport, .timelineImport, .liveSLC,
            .foregroundStream,
        ] {
            #expect(ImportDedupPolicy.thresholds(for: source).windowSeconds <= ImportDedupPolicy.maxWindowSeconds)
        }
    }
}
