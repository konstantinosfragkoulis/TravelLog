//
//  GeocoderNeighborhoodProbeTests.swift
//  TravelLogTests
//
//  Checks the app-side neighborhood lookup:
//  the neighborhood R*Tree
//  candidate probe. The `neighborhood` table mixes point rows (min == max
//  in the rtree) with polygon rows whose bbox can span tens of km; the old
//  `min_lat BETWEEN ?1 ± 0.01` idiom tested only the bbox's MIN corner, so
//  a query point near a wide polygon's far edge silently lost its
//  neighborhood. Real bundled-DB pins (same style as ForwardGeocoderLookupTests).
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct GeocoderNeighborhoodProbeTests {

    @Test("a wide polygon neighborhood is found from its far edge")
    func widePolygonFoundNearFarEdge() async throws {
        // Chaoyang District (OSM 2000003283304) in the bundled DB: polygon
        // bbox spans lat 22.83-23.52; its representative point sits at
        // (23.17, 116.62). The probe is inside the bbox near the NORTH
        // edge; ~0.6° from the min corner, so the old min-corner probe
        // returned zero candidates and subLocality came back nil.
        let result = try #require(
            await GeocodeResolver.shared.resolve(latitude: 23.45, longitude: 116.62)
        )
        #expect(result.subLocalityName == "Chaoyang District")
    }

    @Test("point-row neighborhoods still resolve exactly as before")
    func pointRowNeighborhoodUnchanged() async throws {
        // Eksoni, Athens, a point row (wkb NULL, min == max in the
        // rtree). For point rows the overlap probe reduces to the old
        // BETWEEN window, so this must keep resolving.
        let result = try #require(
            await GeocodeResolver.shared.resolve(latitude: 37.8612, longitude: 23.7660)
        )
        #expect(result.subLocalityName == "Eksoni")
    }
}
