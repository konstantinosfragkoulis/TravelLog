//
//  JourneysClockBoundaryTests.swift
//  TravelLogTests
//
//  Upcoming sleeps until `nextJourneyClockBoundary` and then recomputes, so
//  a leg that ends or starts with no store write still leaves or flips the
//  list. The seam must only return strictly future instants, or the task
//  would wake at once and spin.
//

import Foundation
import Testing
@testable import TravelLog

struct JourneysClockBoundaryTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    @Test func noLegsHasNoBoundary() {
        #expect(TripsListView.nextJourneyClockBoundary(legs: [], now: now) == nil)
    }

    @Test func pastInstantsAreIgnored() {
        let legs = [(start: at(-7_200), currentUntil: at(-3_600))]
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: now) == nil)
    }

    @Test func earliestFutureStartOrEndWins() {
        let legs = [
            (start: at(86_400), currentUntil: at(172_800)),
            (start: at(-3_600), currentUntil: at(5_400)),
            (start: at(3_600), currentUntil: at(90_000)),
        ]
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: now) == at(3_600))
    }

    @Test func startedLegYieldsItsEnd() {
        let legs = [(start: at(-3_600), currentUntil: at(1_800))]
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: now) == at(1_800))
    }

    @Test func instantEqualToNowIsExcluded() {
        let legs = [(start: now, currentUntil: at(600))]
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: now) == at(600))
        let ended = [(start: at(-600), currentUntil: now)]
        #expect(TripsListView.nextJourneyClockBoundary(legs: ended, now: now) == nil)
    }

    /// The task wakes one second past the boundary; from there the same
    /// instant is behind it, so the next sleep targets the following one.
    @Test func wakingPastABoundaryMovesToTheNext() throws {
        let legs = [(start: at(600), currentUntil: at(3_600))]
        let first = try #require(TripsListView.nextJourneyClockBoundary(legs: legs, now: now))
        #expect(first == at(600))
        let woke = first.addingTimeInterval(1)
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: woke) == at(3_600))
        #expect(TripsListView.nextJourneyClockBoundary(legs: legs, now: at(3_601)) == nil)
    }
}
