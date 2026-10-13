//
//  StayClustererConstantsTests.swift
//  TravelLogTests
//
//  Pins the internal static threshold constants that govern StayClusterer's
//  ingestion envelope (TravelLog/Services/StayClusterer.swift). These values are
//  shared with PingRecorder's import pre-attach merge, so the invariant that the
//  import candidate-fetch window (`timeWindowSeconds`) can never drift from the
//  live-path gap threshold (`timeGapThresholdSeconds`) is load-bearing — they
//  MUST stay identical. Also documents the 12h still-here extension cap that
//  prevents a sparse historical import ping from inflating a closed stay's
//  endTime by years.
//
//  NOT @MainActor: these are plain static Double/TimeInterval reads on the actor
//  type's metatype (no @Model construction, no actor instantiation), which is
//  allowed off-main.
//

import Testing
import Foundation
@testable import TravelLog

struct StayClustererConstantsTests {

    @Test("the ingestion-envelope constants are frozen (3 km / 4 h gap / 12 h cap)")
    func envelopeConstantsAreFrozen() {
        #expect(StayClusterer.distanceThresholdMeters == 3000.0)
        #expect(StayClusterer.timeGapThresholdSeconds == 14_400)
        #expect(StayClusterer.maxStayExtensionSeconds == 43_200)
    }

    @Test("cross-component invariants: import window == live gap; cap never truncates a normal-gap midpoint")
    func crossComponentInvariantsHold() {
        // PingRecorder's import candidate-fetch window must equal the live
        // path's gap threshold — drift here silently changes import folding.
        #expect(StayClusterer.timeWindowSeconds == StayClusterer.timeGapThresholdSeconds)
        // The still-here extension cap must exceed half the gap threshold, or
        // the cap would truncate the midpoint of a normal-gap extension.
        #expect(StayClusterer.maxStayExtensionSeconds > StayClusterer.timeGapThresholdSeconds / 2)
    }
}
