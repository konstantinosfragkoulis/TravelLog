//
//  TripsListPrefetchTests.swift
//  TravelLogTests
//
//  The first-page relationship prefetch picks its trips through a pure seam:
//  display order (Favorites, Currently Traveling, Past Trips), no duplicates,
//  bounded by the limit.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripsListPrefetchTests {

    private func makeTrips(_ count: Int, in context: ModelContext) -> [Trip] {
        (0..<count).map { offset in
            let trip = Trip(startDate: Date(timeIntervalSince1970: 1_780_000_000 - Double(offset) * 86_400))
            context.insert(trip)
            return trip
        }
    }

    @Test func idsFollowDisplayOrder() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pinned = makeTrips(2, in: context)
        let active = makeTrips(1, in: context)
        let completed = makeTrips(3, in: context)

        let ids = TripsListView.firstPagePrefetchIDs(pinned: pinned, active: active, completed: completed)
        #expect(ids == (pinned + active + completed).map(\.id))
    }

    @Test func idsSkipDuplicates() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trips = makeTrips(3, in: context)

        let ids = TripsListView.firstPagePrefetchIDs(
            pinned: [trips[1]], active: [trips[0], trips[1]], completed: [trips[1], trips[2]])
        #expect(ids == [trips[1].id, trips[0].id, trips[2].id])
    }

    @Test func idsStopAtTheLimit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let pinned = makeTrips(2, in: context)
        let completed = makeTrips(30, in: context)

        let ids = TripsListView.firstPagePrefetchIDs(pinned: pinned, active: [], completed: completed)
        #expect(ids == (pinned + completed.prefix(18)).map(\.id))

        let short = TripsListView.firstPagePrefetchIDs(pinned: pinned, active: [], completed: completed, limit: 3)
        #expect(short == [pinned[0].id, pinned[1].id, completed[0].id])
    }

    @Test func noTripsGiveNoIDs() {
        #expect(TripsListView.firstPagePrefetchIDs(pinned: [], active: [], completed: []).isEmpty)
    }

    @Test func idsTrackSortAndFilterChangesWithoutStoreChanges() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trips = makeTrips(30, in: context)
        let token = StoreChangeTracker.shared.token(for: .trip)
        let initial = TripsListView.firstPagePrefetchIDs(pinned: [], active: [], completed: trips)
        let reversed = TripsListView.firstPagePrefetchIDs(
            pinned: [], active: [], completed: Array(trips.reversed()))
        let filtered = TripsListView.firstPagePrefetchIDs(
            pinned: [], active: [], completed: Array(trips.dropFirst(20)))

        #expect(StoreChangeTracker.shared.token(for: .trip) == token)
        #expect(initial == Array(trips.prefix(20)).map(\.id))
        #expect(reversed == Array(trips.reversed().prefix(20)).map(\.id))
        #expect(filtered == Array(trips.dropFirst(20)).map(\.id))
        #expect(initial != reversed)
        #expect(initial != filtered)
    }
}
