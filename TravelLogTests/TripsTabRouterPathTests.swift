//
//  TripsTabRouterPathTests.swift
//  TravelLogTests
//
//  The Trips tab's navigation path lives on the router: every cross-tab
//  request returns it to the list, so a Passport country, a search or a
//  requested trip never lands under a page the user had opened. An
//  extension of `TripsTabRouterSignalTests`, so both share its
//  serialization over the shared singleton; each test leaves the router
//  with no request and an empty path.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

extension TripsTabRouterSignalTests {

    /// Two pages deep: a temporary home and one pushed above it.
    private static let deepPath: [TripsRoute] = [.temporaryHome(UUID()), .temporaryHome(UUID())]

    private func reset(_ router: TripsTabRouter) {
        router.clear()
        router.clearTripRequest()
        router.clearSearchRequest()
        router.path = []
    }

    @Test func countryFilterRequestReturnsToTheList() {
        let router = TripsTabRouter.shared
        defer { reset(router) }
        router.path = Self.deepPath

        router.requestCountryFilter("GR")

        #expect(router.path.isEmpty)
        #expect(router.requestedCountryCode == "GR")
    }

    @Test func searchRequestReturnsToTheList() {
        let router = TripsTabRouter.shared
        defer { reset(router) }
        router.path = Self.deepPath

        router.requestSearch("lakes")

        #expect(router.path.isEmpty)
        #expect(router.requestedSearchQuery == "lakes")
    }

    @Test func tripRequestOpensTheTripAloneOnTheList() throws {
        let router = TripsTabRouter.shared
        defer { reset(router) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 6_652_800))
        context.insert(trip)
        try context.save()

        // The same trip opened by hand, with a page pushed above it.
        router.path = [.trip(trip), .temporaryHome(UUID())]
        router.requestTrip(trip.id)
        #expect(router.path.isEmpty)
        #expect(router.requestedTripID == trip.id)

        // The list resolves the request and opens it.
        router.clearTripRequest()
        router.showRequestedTrip(trip)
        #expect(router.path.count == 1)
        #expect(router.path.first?.trip === trip)
        let first = router.path

        // A second request for the trip on screen is a new page, never
        // equal to the one there, so the stack replaces it.
        router.requestTrip(trip.id)
        router.clearTripRequest()
        router.showRequestedTrip(trip)
        #expect(router.path.count == 1)
        #expect(router.path != first)
        #expect(router.path.first?.trip === trip)
    }

    @Test func popRoutesDropsTheGoneRouteAndEveryPageAboveIt() {
        let router = TripsTabRouter.shared
        defer { reset(router) }
        let kept = TripsRoute.temporaryHome(UUID())
        let gone = TripsRoute.temporaryHome(UUID())
        router.path = [kept, gone, .temporaryHome(UUID())]

        router.popRoutes { $0 == gone }
        #expect(router.path == [kept])

        // Nothing gone: the path stands.
        router.popRoutes { _ in false }
        #expect(router.path == [kept])
    }
}
