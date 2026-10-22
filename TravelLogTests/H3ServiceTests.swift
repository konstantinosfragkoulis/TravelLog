//
//  H3ServiceTests.swift
//  TravelLogTests
//

import Testing
import Foundation
@testable import TravelLog

/// Pure-function tests for H3Service (lat/lon ⇄ H3 cell). Resolution-independent
/// invariants only, so they hold regardless of the cell resolution H3Service uses.
struct H3ServiceTests {

    // MARK: - Round-trip invariant (exact, resolution-independent)

    /// The center of a cell must map back to that same cell. This is exact and
    /// holds at any H3 resolution, so it's a robust correctness check on the
    /// cellIndex ⇄ centerCoordinate pair without assuming a specific cell size.
    @Test("center of a cell maps back to that cell", arguments: [
        (37.9838, 23.7275),    // Athens
        (59.9436, 10.7463),    // Oslo
        (40.7128, -74.0060),   // New York
        (-33.8688, 151.2093),  // Sydney (southern hemisphere)
        (0.0, 0.0),            // null island / equator+prime-meridian
        (64.1331, -21.8583),   // Reykjavík (high latitude)
    ])
    func centerRoundTripsToSameCell(lat: Double, lon: Double) throws {
        let cell = try #require(H3Service.cellIndex(latitude: lat, longitude: lon))
        let center = try #require(H3Service.centerCoordinate(for: cell))
        let cellOfCenter = try #require(H3Service.cellIndex(latitude: center.latitude,
                                                            longitude: center.longitude))
        #expect(cellOfCenter == cell)
    }

    // MARK: - Boundary

    @Test("cell boundary is a closed polygon of 5 (pentagon) or 6 (hexagon) vertices")
    func boundaryVertexCount() throws {
        let cell = try #require(H3Service.cellIndex(latitude: 48.8106, longitude: 2.3048)) // Paris
        let boundary = try #require(H3Service.cellBoundary(for: cell))
        // H3 cells are hexagons except 12 pentagons per resolution.
        #expect(boundary.count == 6 || boundary.count == 5)
    }

    // MARK: - Antimeridian (longitude ±180 should not crash or fold to nil)

    @Test("a coordinate near the antimeridian resolves to a cell")
    func antimeridianStable() {
        #expect(H3Service.cellIndex(latitude: 0.0, longitude: 179.9999) != nil)
    }
}
