//
//  PresenceEvidenceTests.swift
//  TravelLogTests
//
import Foundation
import Testing
@testable import TravelLog

struct PresenceEvidenceTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The boundary itself

    @Test("the threshold is seven days, exclusive")
    func thresholdBoundary() {
        let base = Self.t0
        let week = PresenceEvidence.unknownGapSeconds
        #expect(week == 7 * 24 * 60 * 60)
        // Exactly seven days is still observed; a second past it is not.
        #expect(PresenceEvidence.support(
            fromEndOf: base, toStartOf: base.addingTimeInterval(week)) == .observed)
        #expect(PresenceEvidence.support(
            fromEndOf: base, toStartOf: base.addingTimeInterval(week + 1)) == .unknown)
    }

    @Test("adjacent and overlapping observations are observed, never unknown")
    func nonPositiveIntervals() {
        let base = Self.t0
        #expect(PresenceEvidence.support(fromEndOf: base, toStartOf: base) == .observed)
        // Overlap: an imported row landing before the previous row's end.
        #expect(PresenceEvidence.support(
            fromEndOf: base, toStartOf: base.addingTimeInterval(-86_400)) == .observed)
    }
}
