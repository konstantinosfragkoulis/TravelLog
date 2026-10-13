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
    /// A defaults suite no test ever writes a live acceptance floor to.
    static let liveFloorFreeDefaults: UserDefaults = {
        let name = "TravelLogTests.liveFloorFree"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
}
