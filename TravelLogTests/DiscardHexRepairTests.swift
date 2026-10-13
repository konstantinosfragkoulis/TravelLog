//
//  DiscardHexRepairTests.swift
//  TravelLogTests
//
//  Photo-discard repair uses the HexVisit evidence window. CloudKit can
//  sync a row before its live pings arrive, so zero surviving local pings
//  does not prove the import created the row. Deleting a remote-backed row
//  would sync that deletion to every device.
//
//  The rule: the import upsert only EXTENDS a row's window to its own ping
//  timestamps, so a boundary outside the import's per-cell window is
//  evidence the import did not create → the row is never deleted and that
//  boundary is never clobbered.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct DiscardHexRepairTests {

    private func d(_ days: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: days * 86_400)
    }

    @Test("import-born row with no survivors deletes; phantom-hex repair")
    func importOnlyRowDeletes() {
        // Row window == import window, nothing else backs it.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(10), rowLastVisited: d(12),
            importFirst: d(10), importLast: d(12),
            survivingFirst: nil, survivingLast: nil
        ) == .delete)
    }

    @Test("a remote-backed row survives even with zero local surviving pings")
    func remoteBackedRowKept() {
        // lastVisited AFTER the import's last ping: another device's live
        // visit extended it, so the row must survive.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(10), rowLastVisited: d(500),
            importFirst: d(10), importLast: d(12),
            survivingFirst: nil, survivingLast: nil
        ) == .keep)
        // firstVisited BEFORE the import's first ping; same verdict.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(1), rowLastVisited: d(12),
            importFirst: d(10), importLast: d(12),
            survivingFirst: nil, survivingLast: nil
        ) == .keep)
    }

    @Test("recompute from survivors shrinks only the boundaries the import extended")
    func recomputePreservesRemoteBoundaries() {
        // Import extended BOTH boundaries (row window == import window);
        // survivors define the honest new window.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(10), rowLastVisited: d(12),
            importFirst: d(10), importLast: d(12),
            survivingFirst: d(11), survivingLast: d(11.5)
        ) == .recompute(first: d(11), last: d(11.5)))

        // Remote-owned firstVisited (before the import window): kept, even
        // though the local survivors start later.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(1), rowLastVisited: d(12),
            importFirst: d(10), importLast: d(12),
            survivingFirst: d(11), survivingLast: d(11.5)
        ) == .recompute(first: d(1), last: d(11.5)))

        // Remote-owned lastVisited symmetrically.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(10), rowLastVisited: d(500),
            importFirst: d(10), importLast: d(12),
            survivingFirst: d(11), survivingLast: d(11.5)
        ) == .recompute(first: d(11), last: d(500)))
    }

    @Test("a lone surviving ping collapses the window to itself")
    func singleSurvivorWindow() {
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: d(10), rowLastVisited: d(12),
            importFirst: d(10), importLast: d(12),
            survivingFirst: d(11), survivingLast: nil
        ) == .recompute(first: d(11), last: d(11)))
    }
}
