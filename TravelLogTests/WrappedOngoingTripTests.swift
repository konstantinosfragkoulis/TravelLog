//
//  WrappedOngoingTripTests.swift
//  TravelLogTests
//
//  Pins the Wrapped rules for ongoing trips: they compete in trip-level
//  cards with their elapsed-so-far duration, and the "longest trip" tie
//  rule is explicit and deterministic (most days → the year's EARLIER
//  trip → smaller id) instead of implicit fetch order.
//
//  `@MainActor` because the tests construct `@Model` Trips.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedOngoingTripTests {

    private let day: TimeInterval = 24 * 60 * 60

    private func trip(startDaysAgo: Double, lengthDays: Int?, uuid: String? = nil) -> Trip {
        let trip = Trip(startDate: Date.now.addingTimeInterval(-startDaysAgo * day))
        if let uuid, let forced = UUID(uuidString: uuid) {
            trip.id = forced
        }
        if let lengthDays {
            // durationDays = max(1, days+1), so an N-day trip ends N-1 days
            // after it starts.
            trip.endDate = trip.startDate.addingTimeInterval(Double(lengthDays - 1) * day)
            trip.isComplete = true
        }
        return trip
    }

    @Test("effectiveDurationDays: closed trips use the final duration, ongoing use elapsed")
    func effectiveDuration() {
        let closed = trip(startDaysAgo: 30, lengthDays: 7)
        #expect(YearWrappedGenerator.effectiveDurationDays(closed) == 7)

        // Started 5 days + 1 hour ago → 5 whole elapsed days → 6 by the
        // max(1, days+1) shape Trip.durationDays uses.
        let ongoing = trip(startDaysAgo: 5.05, lengthDays: nil)
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing) == 6)

        // Just started → floor of 1.
        let fresh = trip(startDaysAgo: 0.01, lengthDays: nil)
        #expect(YearWrappedGenerator.effectiveDurationDays(fresh) == 1)
    }

    @Test("an ongoing trip longer than every completed trip wins the longest-trip card")
    func ongoingTripCanWin() {
        let completed = trip(startDaysAgo: 200, lengthDays: 10)
        let ongoing = trip(startDaysAgo: 12.5, lengthDays: nil) // 13 days so far
        let winner = YearWrappedGenerator.longestTrip(in: [completed, ongoing])
        #expect(winner?.id == ongoing.id)
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing) == 13)
    }

    @Test("duration tie → the year's earlier trip wins, order-independently")
    func tieGoesToEarlierTrip() {
        let spring = trip(startDaysAgo: 200, lengthDays: 5)
        let autumn = trip(startDaysAgo: 50, lengthDays: 5)
        #expect(YearWrappedGenerator.longestTrip(in: [spring, autumn])?.id == spring.id)
        #expect(YearWrappedGenerator.longestTrip(in: [autumn, spring])?.id == spring.id)
    }

    @Test("full tie (days + start date) → smaller id wins, order-independently")
    func fullTieGoesToSmallerID() {
        let a = trip(startDaysAgo: 100, lengthDays: 4,
                     uuid: "00000000-0000-0000-0000-000000000001")
        let b = trip(startDaysAgo: 100, lengthDays: 4,
                     uuid: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        // Align the start dates exactly — `startDaysAgo` uses two separate
        // Date.now reads.
        b.startDate = a.startDate
        b.endDate = a.endDate
        #expect(YearWrappedGenerator.longestTrip(in: [a, b])?.id == a.id)
        #expect(YearWrappedGenerator.longestTrip(in: [b, a])?.id == a.id)
    }
}
