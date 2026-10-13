//
//  LiveFloorTestDefaults.swift
//  TravelLogTests
//
//  `PingRecorder.processLocations` rejects fixes stamped before the live
//  acceptance floor that Delete All Data writes. The test host's `.standard`
//  defaults may carry a real floor from the simulator app, which would
//  silently drop fixture-dated fixes, so live-ingest tests read this suite.
//

import Foundation
@testable import TravelLog

extension TestSupport {
    /// The suite name, its persistent domain cleared once per test host.
    private static let liveFloorFreeSuite: String = {
        let name = "TravelLogTests.liveFloorFree"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return name
    }()

    /// A defaults suite no test ever writes a live acceptance floor to. Each
    /// read returns a fresh handle on the same suite, so no `UserDefaults`
    /// instance is shared across tests.
    static var liveFloorFreeDefaults: UserDefaults {
        UserDefaults(suiteName: liveFloorFreeSuite)!
    }
}
