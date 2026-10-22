//
//  ImportStatusTests.swift
//  TravelLogTests
//
//  Covers the PhotoImportState.status accessor: the documented forward-compat
//  fallback ImportStatus(rawValue:) ?? .idle so a row written by a future
//  build doesn't crash today's UI, the setter's raw write, and the fresh-row
//  defaults. (The ImportStatus persisted-token table lives in
//  ModelEnumRawValueTests.)
//
//  Pure-enum cases need no isolation; the PhotoImportState.status accessor
//  tests construct the @Model type, which the app target's MainActor-by-default
//  isolation makes MainActor-isolated — hence the suite is @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
@Suite("ImportStatus + PhotoImportState.status")
struct ImportStatusTests {

    // MARK: - PhotoImportState.status accessor

    @Test("status getter falls back to .idle for an unknown statusRaw (forward-compat guard)")
    func stateStatusGetterFallsBackToIdleForUnknownRaw() {
        let state = PhotoImportState(originDeviceID: "dev-A")
        state.statusRaw = "some_future_value"
        #expect(state.status == .idle)
    }

    @Test("status setter writes the underlying raw string the model persists")
    func stateStatusSetterWritesRawValue() {
        let state = PhotoImportState(originDeviceID: "dev-A")
        state.status = .running
        #expect(state.statusRaw == "running")
        state.status = .cancelled
        #expect(state.statusRaw == "cancelled")
    }

    @Test("a fresh PhotoImportState has the documented starting shape (idle, not completed, not cancelled)")
    func freshStateDefaultsToIdle() {
        let state = PhotoImportState(originDeviceID: "dev-A")
        #expect(state.status == .idle)
        #expect(state.statusRaw == ImportStatus.idle.rawValue)
        #expect(state.completedAt == nil)
        #expect(state.cancelRequested == false)
        // Zero-count starting shape: the resume/watermark math in
        // PhotoImportSnapshotTests builds on these baselines.
        #expect(state.processedAssetCount == 0)
        #expect(state.acceptedPingCount == 0)
        #expect(state.totalAssetCount == 0)
    }
}
