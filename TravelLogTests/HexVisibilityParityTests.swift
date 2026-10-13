//
//  HexVisibilityParityTests.swift
//  TravelLogTests
//
//  HexVisibility's boundary-failure policy: the Stats count and the map's
//  overlay build survive/drop the SAME rows.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct HexVisibilityParityTests {

    @Test("stats-side isVisible and the map's boundary drop keep the same rows")
    func statsAndMapAgreeOnBoundaryFailures() throws {
        // A guaranteed-valid index (minted by the same service the pipeline
        // uses) plus the corrupt shapes the map's guard silently drops.
        let valid = try #require(H3Service.cellIndex(latitude: 37.98, longitude: 23.72))
        let hexes = [valid, "", "not-a-hex", "ffffffffffffffff"]
        let hidden: Set<String> = []

        let isRenderable: (String) -> Bool = { H3Service.cellBoundary(for: $0) != nil }

        // Stats-side: the shared contract function.
        let counted = hexes.filter {
            HexVisibility.isVisible(h3Index: $0, hidden: hidden, isRenderable: isRenderable)
        }
        // Map-side: the real snapshot build with its default boundary lookup.
        let rows = hexes.map {
            HexVisitSnapshot(
                h3Index: $0, locality: nil, country: nil, isoCountryCode: nil,
                firstVisited: .distantPast, lastVisited: .distantPast, visitCount: 1,
                centerLatitude: 37.98, centerLongitude: 23.72)
        }
        let snapshot = try HexMapDataLoader.buildSnapshot(
            inputs: .init(transit: [], realHexes: [], rows: rows))
        let rendered = snapshot.overlays.map(\.id)

        #expect(counted == rendered)
        #expect(counted == [valid])
    }

    @Test("hidden set still wins over renderability")
    func hiddenBeatsRenderable() throws {
        let valid = try #require(H3Service.cellIndex(latitude: 37.98, longitude: 23.72))
        let visible = HexVisibility.isVisible(
            h3Index: valid,
            hidden: [valid],
            isRenderable: { _ in true }
        )
        #expect(!visible)
    }
}
