//
//  PhotoImportSnapshotTests.swift
//  TravelLogTests
//
//  Covers PhotoImportStateSnapshot: the progress math (zero-guard,
//  exact fraction, parity, and the min(1.0, …) clamp for the
//  "library grew mid-import" case) and the nonisolated init(from:)
//  faithful field copy. This is the
//  framework-free decision surface of the photo-import subsystem;
//  shouldAccept(asset:) is PHAsset-bound and documented as notTestable.
//
//  @MainActor because these tests construct the @Model type
//  PhotoImportState, which the app target's MainActor-by-default
//  isolation makes MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("PhotoImportStateSnapshot")
struct PhotoImportSnapshotTests {

    // MARK: - Fixtures

    /// Constructs a fresh @Model PhotoImportState. The snapshot init only
    /// reads stored properties, so no ModelContext is required.
    private func makeState(originDeviceID: String = "dev-A") -> PhotoImportState {
        PhotoImportState(originDeviceID: originDeviceID)
    }

    /// Convenience: a state with the two progress counters preset.
    private func makeState(total: Int, processed: Int) -> PhotoImportState {
        let state = PhotoImportState(originDeviceID: "dev-A")
        state.totalAssetCount = total
        state.processedAssetCount = processed
        return state
    }

    // MARK: - progress

    @Test("progress is 0 when totalAssetCount has not been estimated yet (guard against /0)")
    func progressIsZeroWhenTotalNotYetEstimated() {
        let zeroProcessed = PhotoImportStateSnapshot(from: makeState(total: 0, processed: 0))
        #expect(zeroProcessed.progress == 0)

        // Even with a nonzero processed count, total==0 short-circuits to 0.
        let someProcessed = PhotoImportStateSnapshot(from: makeState(total: 0, processed: 5))
        #expect(someProcessed.progress == 0)
    }

    @Test("progress is processed/total, clamped to 1.0 (fraction, parity, overshoot)",
          arguments: [(50, 200, 0.25), (200, 200, 1.0), (137, 100, 1.0), (4, 3, 1.0)])
    func progressFractionAndClamp(processed: Int, total: Int, expected: Double) {
        let snap = PhotoImportStateSnapshot(from: makeState(total: total, processed: processed))
        #expect(abs(snap.progress - expected) < 1e-12)
    }

    @Test("selection orders logical UUID before physical identity and ignores mutable lifecycle fields")
    func deterministicTwinSelection() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let higher = makeState()
        higher.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        context.insert(higher)
        try context.save()
        let twins = (0..<12).map { _ in makeState() }
        for row in twins {
            row.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            context.insert(row)
            try context.save()
        }
        let selectedID = try #require(twins.map(\.persistentModelID).min())
        #expect(try PhotoImportStateSnapshot.fetch(in: ModelContext(container))?.persistentModelID == selectedID)
        let selected = try #require(twins.first { $0.persistentModelID == selectedID })
        selected.status = .cancelled
        selected.startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        selected.processedAssetCount = 500
        try context.save()
        #expect(try PhotoImportStateSnapshot.fetch(in: ModelContext(container))?.persistentModelID == selectedID)
    }

    // MARK: - init(from:) faithful copy

    @Test("snapshot round-trips every field from the source PhotoImportState")
    func snapshotRoundTripsEveryFieldFromState() {
        let state = makeState(originDeviceID: "origin-XYZ")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let completed = Date(timeIntervalSince1970: 1_700_003_600)
        let watermark = Date(timeIntervalSince1970: 1_699_999_000)
        let updated = Date(timeIntervalSince1970: 1_700_004_000)

        state.status = .paused
        state.startedAt = started
        state.completedAt = completed
        state.totalAssetCount = 4242
        state.processedAssetCount = 1234
        state.acceptedPingCount = 999
        state.watermarkCreationDate = watermark
        state.watermarkLocalIdentifier = "ABCD-1234/L0/001"
        state.lastError = "disk full"
        state.lastUpdated = updated
        state.cancelRequested = true

        let snap = PhotoImportStateSnapshot(from: state)

        #expect(snap.persistentModelID == state.persistentModelID)
        #expect(snap.id == state.id)
        #expect(snap.status == .paused)
        #expect(snap.startedAt == started)
        #expect(snap.completedAt == completed)
        #expect(snap.totalAssetCount == 4242)
        #expect(snap.processedAssetCount == 1234)
        #expect(snap.acceptedPingCount == 999)
        #expect(snap.watermarkCreationDate == watermark)
        #expect(snap.watermarkLocalIdentifier == "ABCD-1234/L0/001")
        #expect(snap.lastError == "disk full")
        #expect(snap.lastUpdated == updated)
        #expect(snap.cancelRequested == true)
        #expect(snap.originDeviceID == "origin-XYZ")
    }
}
