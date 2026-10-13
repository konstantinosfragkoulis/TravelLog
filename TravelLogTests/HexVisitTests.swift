//
//  HexVisitTests.swift
//  TravelLogTests
//
//  Covers `HexVisit` init invariants (firstVisited == lastVisited, visitCount
//  == 1, center coords stored as passed) and `recordReentry(at:)` semantics
//  (advances lastVisited, increments count, never touches firstVisited). The
//  last case documents that the method does NO min/max guard, an earlier
//  date still becomes lastVisited (last-write-wins, by design).
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes the `@Model` `HexVisit` MainActor-isolated.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct HexVisitTests {

    nonisolated static let base = Date(timeIntervalSinceReferenceDate: 0)
    nonisolated static let lat = 37.9838
    nonisolated static let lon = 23.7275

    private func makeVisit(at date: Date = Self.base) -> HexVisit {
        HexVisit(h3Index: "861eda747ffffff", firstVisited: date,
                 centerLatitude: Self.lat, centerLongitude: Self.lon)
    }

    @Test("init: firstVisited == lastVisited == passed date, visitCount == 1, coords stored")
    func initSetsFirstAndLastVisitedEqualAndCountOne() {
        let v = makeVisit()
        #expect(v.firstVisited == Self.base)
        #expect(v.lastVisited == Self.base)
        #expect(v.visitCount == 1)
        #expect(v.centerLatitude == Self.lat)
        #expect(v.centerLongitude == Self.lon)
    }

    @Test("recordReentry advances lastVisited, increments count, leaves firstVisited")
    func recordReentryAdvancesLastVisitedAndIncrementsCount() {
        let v = makeVisit()
        let later = Self.base.addingTimeInterval(3600)
        v.recordReentry(at: later)
        #expect(v.lastVisited == later)
        #expect(v.firstVisited == Self.base)
        #expect(v.visitCount == 2)
    }

    @Test("recordReentry accumulates across multiple entries (last write wins for lastVisited)")
    func recordReentryAccumulatesAcrossMultipleEntries() {
        let v = makeVisit()
        let d1 = Self.base.addingTimeInterval(100)
        let d2 = Self.base.addingTimeInterval(200)
        let d3 = Self.base.addingTimeInterval(300)
        v.recordReentry(at: d1)
        v.recordReentry(at: d2)
        v.recordReentry(at: d3)
        #expect(v.visitCount == 4)
        #expect(v.lastVisited == d3)
        #expect(v.firstVisited == Self.base)
    }

    @Test("recordReentry with an EARLIER date still stores it and counts (no min/max guard)")
    func recordReentryWithEarlierDateStillStoredAndCounted() {
        let v = makeVisit()
        let earlier = Self.base.addingTimeInterval(-3600)
        v.recordReentry(at: earlier)
        #expect(v.lastVisited == earlier)
        #expect(v.visitCount == 2)
        #expect(v.firstVisited == Self.base)
    }
}
