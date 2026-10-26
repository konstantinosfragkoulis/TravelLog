//
//  TripsTabRouterSignalTests.swift
//  TravelLogTests
//
//  The three App Intents-facing router signals are independent
//  single-set / single-consume slots — clearing one must never clobber
//  another (an OpenTrip and a search request can race through Siri).
//  Uses the shared singleton (the router has no test initializer); each
//  test leaves every slot nil so ordering can't leak between tests.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized)
struct TripsTabRouterSignalTests {

    @Test func signalsSetAndClearIndependently() {
        let router = TripsTabRouter.shared
        let tripID = UUID()

        router.requestCountryFilter("GR")
        router.requestTrip(tripID)
        router.requestSearch("paris")

        #expect(router.requestedCountryCode == "GR")
        #expect(router.requestedTripID == tripID)
        #expect(router.requestedSearchQuery == "paris")

        // Clearing one slot leaves the others pending.
        router.clear()
        #expect(router.requestedCountryCode == nil)
        #expect(router.requestedTripID == tripID)
        #expect(router.requestedSearchQuery == "paris")

        router.clearTripRequest()
        #expect(router.requestedTripID == nil)
        #expect(router.requestedSearchQuery == "paris")

        router.clearSearchRequest()
        #expect(router.requestedSearchQuery == nil)
    }
}
