//
//  WrappedOngoingTripTests.swift
//  TravelLogTests
//
//  Pins the Wrapped rules for ongoing trips: they compete in trip-level
//  cards with their civil-date duration so far, and the "longest trip" tie
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

    private let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

    private let day: TimeInterval = 24 * 60 * 60

    private func trip(startDaysAgo: Double, lengthDays: Int?, uuid: String? = nil) -> Trip {
        let trip = Trip(startDate: now.addingTimeInterval(-startDaysAgo * day))
        if let uuid, let forced = UUID(uuidString: uuid) {
            trip.id = forced
        }
        if let lengthDays {
            // durationDays = max(1, days+1), so an N-day trip ends N-1 days
            // after it starts.
            trip.endDate = trip.startDate.addingTimeInterval(Double(lengthDays - 1) * day)
            trip.isComplete = true
        }
        trip.stays = [Stay(
            startTime: trip.startDate, endTime: trip.endDate ?? now,
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "h",
            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], timeZoneIdentifier: "UTC")]
        return trip
    }

    @Test("effectiveDurationDays: closed trips use final duration, ongoing count civil dates")
    func effectiveDuration() {
        let closed = trip(startDaysAgo: 30, lengthDays: 7)
        #expect(YearWrappedGenerator.effectiveDurationDays(closed, now: now) == 7)
        let ongoing = trip(startDaysAgo: 5.05, lengthDays: nil)
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now) == 6)
        let fresh = trip(startDaysAgo: 0.01, lengthDays: nil)
        #expect(YearWrappedGenerator.effectiveDurationDays(fresh, now: now) == 1)
    }

    @Test("an ongoing overnight counts two civil dates even before 24 hours elapse")
    func ongoingOvernightCountsCivilDates() {
        let ongoing = trip(startDaysAgo: 13.0 / 24, lengthDays: nil)
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now) == 2)
        let closed = trip(startDaysAgo: 0.1, lengthDays: 1)
        #expect(YearWrappedGenerator.longestTrip(in: [closed, ongoing], now: now)?.id == ongoing.id)
    }

    @Test("ongoing duration reads now in the latest boundary stay's zone")
    func ongoingDurationUsesBoundaryZones() {
        let ongoing = trip(startDaysAgo: 13.0 / 24, lengthDays: nil)
        ongoing.stays?.first?.timeZoneIdentifier = "Asia/Tokyo"
        // Both boundaries are October 14 in Tokyo.
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now) == 1)
        let first = ongoing.stays![0]
        first.timeZoneIdentifier = "UTC"
        first.endTime = first.startTime.addingTimeInterval(3600)
        let last = Stay(
            startTime: now.addingTimeInterval(-3600), endTime: now,
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "last",
            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], timeZoneIdentifier: "Pacific/Honolulu")
        ongoing.stays = [first, last]
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now) == 2)
        last.timeZoneIdentifier = "Etc/GMT+12"
        // Now is midnight October 14 at UTC-12; a minute earlier is October 13.
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now.addingTimeInterval(-60)) == 1)
    }

    @Test("an ongoing trip longer than every completed trip wins the longest-trip card")
    func ongoingTripCanWin() {
        let completed = trip(startDaysAgo: 200, lengthDays: 10)
        let ongoing = trip(startDaysAgo: 12.75, lengthDays: nil) // 14 civil dates so far
        let winner = YearWrappedGenerator.longestTrip(in: [completed, ongoing], now: now)
        #expect(winner?.id == ongoing.id)
        #expect(YearWrappedGenerator.effectiveDurationDays(ongoing, now: now) == 14)
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
        // Align the boundaries exactly for a full tie.
        b.startDate = a.startDate
        b.endDate = a.endDate
        #expect(YearWrappedGenerator.longestTrip(in: [a, b])?.id == a.id)
        #expect(YearWrappedGenerator.longestTrip(in: [b, a])?.id == a.id)
    }
}
