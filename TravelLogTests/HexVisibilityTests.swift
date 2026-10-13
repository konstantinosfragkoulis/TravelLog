//
//  HexVisibilityTests.swift
//  TravelLogTests
//
//  Pins the shared map/Stats hide rule: a hex is hidden only when EVERY transit
//  stay touching it is aerial (flight or airport). Surface transit (driving,
//  ferry, walking, unknown ground) and real visits keep the hex visible — the
//  fix for road-trip hexes vanishing from the Exploration map.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@Suite("HexVisibility hide rule")
struct HexVisibilityTests {

    private func stay(_ hex: String, flight: Bool = false, airport: Bool = false) -> HexVisibility.TransitStay {
        HexVisibility.TransitStay(h3Index: hex, isFlight: flight, isAirport: airport)
    }

    @Test("a surface (driving / unknown-ground) transit hex is shown")
    func surfaceTransitShown() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("A")], realHexes: [])
        #expect(hidden.isEmpty)
    }

    @Test("a flight transit hex is hidden")
    func flightHidden() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("A", flight: true)], realHexes: [])
        #expect(hidden == ["A"])
    }

    @Test("an airport transit hex is hidden")
    func airportHidden() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("A", airport: true)], realHexes: [])
        #expect(hidden == ["A"])
    }

    @Test("a hex with both a flight stay and a surface stay is shown (surface wins)")
    func mixedAerialAndSurfaceShown() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("A", flight: true), stay("A")], realHexes: [])
        #expect(hidden.isEmpty)
    }

    @Test("an aerial transit hex that is also a real-visit hex is shown")
    func realVisitWins() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("A", flight: true)], realHexes: ["A"])
        #expect(hidden.isEmpty)
    }

    @Test("an empty h3 index is ignored")
    func emptyHexIgnored() {
        let hidden = HexVisibility.hiddenHexes(transit: [stay("", flight: true)], realHexes: [])
        #expect(hidden.isEmpty)
    }

    @Test("mixed fixture: only the all-aerial, non-real hexes are hidden")
    func mixedFixture() {
        let transit = [
            stay("road1"), stay("road2"),                  // road trip → shown
            stay("flight1", flight: true),                 // flight → hidden
            stay("airport1", airport: true),               // airport → hidden
            stay("mixed", flight: true), stay("mixed"),    // flight + ground → shown
            stay("realFlight", flight: true),              // flight but also a real hex → shown
        ]
        let hidden = HexVisibility.hiddenHexes(transit: transit, realHexes: ["realFlight"])
        #expect(hidden == ["flight1", "airport1"])
    }

    @Test("paged visible hexes equal the distinct-cell scan, across pages")
    func pagedCountMatchesCellScan() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let day = Date(timeIntervalSince1970: 1_750_000_000)
        // 1,300 hidden hexes, only every other one with a row; one hidden and
        // one visible hex hold two rows each (a retained dedup group), and 40
        // cells are visible: the count is per cell, not per row.
        let hidden = Set((0..<1_300).map { "hidden\($0)" })
        for index in stride(from: 0, to: 1_300, by: 2) {
            context.insert(HexVisit(h3Index: "hidden\(index)", firstVisited: day, centerLatitude: 0, centerLongitude: 0))
        }
        context.insert(HexVisit(h3Index: "hidden0", firstVisited: day, centerLatitude: 0, centerLongitude: 0))
        for index in 0..<40 {
            context.insert(HexVisit(h3Index: "visible\(index)", firstVisited: day, centerLatitude: 0, centerLongitude: 0))
        }
        context.insert(HexVisit(h3Index: "visible0", firstVisited: day, centerLatitude: 0, centerLongitude: 0))
        try context.save()

        let cells = Set(try context.fetch(FetchDescriptor<HexVisit>()).map(\.h3Index))
        let scanned = cells.count {
            HexVisibility.isVisible(h3Index: $0, hidden: hidden, isRenderable: { _ in true })
        }
        #expect(scanned == 40)
        for pageSize in [7, 2_000] {
            #expect(try HexVisibility.visibleHexVisitCount(
                hidden: hidden, in: container, pageSize: pageSize) == scanned)
        }
        #expect(try HexVisibility.visibleHexVisitCount(hidden: [], in: container) == cells.count)
        #expect(try HexVisibility.visibleHexVisitCount(hidden: ["absent"], in: container) == cells.count)
    }

    @Test("paged visible hexes are zero on an empty store")
    func countOnlyEmptyStore() throws {
        let container = try TestSupport.makeInMemoryContainer()
        #expect(try HexVisibility.visibleHexVisitCount(hidden: ["a"], in: container) == 0)
    }
}
