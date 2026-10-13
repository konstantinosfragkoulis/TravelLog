//
//  H3ServiceGeometryTests.swift
//  TravelLogTests
//
//  Additional, NON-OVERLAPPING H3Service invariants (the existing
//  H3ServiceTests already covers determinism, center round-trip, boundary
//  vertex count, and the antimeridian). This file adds: the fixed resolution
//  constant, nearby/distant cell discrimination, the nil paths for invalid
//  hex strings, geographic-range invariants on the radians→degrees conversion
//  (centerCoordinate / cellBoundary), and a sanity-bound on the cell centroid.
//
//  Not @MainActor: H3Service is a pure static enum with `nonisolated` members
//  (mirrors the existing H3ServiceTests); no @Model is touched.
//

import Testing
import Foundation
@testable import TravelLog

struct H3ServiceGeometryTests {

    // MARK: - Fixtures

    /// Athens centre.
    static let athens = (lat: 37.9838, lon: 23.7275)
    /// Ioánnina is over 300 km from Athens, never the same res-6 cell.
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    // MARK: - Resolution constant

    @Test("the fixed app resolution is 6")
    func resolutionConstantIsSix() {
        #expect(H3Service.resolution == 6)
    }

    // MARK: - Spatial coherence

    @Test("two coordinates a few tens of metres apart map to the same res-6 cell")
    func nearbyCoordsWithinACellMapToSameCell() throws {
        let a = try #require(H3Service.cellIndex(latitude: Self.athens.lat,
                                                 longitude: Self.athens.lon))
        // +0.0003° ≈ 30-40 m; far smaller than a ~36 km² res-6 hex.
        let b = try #require(H3Service.cellIndex(latitude: Self.athens.lat + 0.0003,
                                                 longitude: Self.athens.lon + 0.0003))
        #expect(a == b)
    }

    @Test("two cities over 300 km apart map to different res-6 cells")
    func farApartCoordsMapToDifferentCells() throws {
        let a = try #require(H3Service.cellIndex(latitude: Self.athens.lat,
                                                 longitude: Self.athens.lon))
        let b = try #require(H3Service.cellIndex(latitude: Self.ioannina.lat,
                                                 longitude: Self.ioannina.lon))
        #expect(a != b)
    }

    // MARK: - Invalid-hex nil paths

    @Test("centerCoordinate rejects the zero hex and the empty string → nil")
    func centerCoordinateRejectsZeroHex() {
        #expect(H3Service.centerCoordinate(for: "0") == nil)   // rawValue != 0 guard
        #expect(H3Service.centerCoordinate(for: "") == nil)    // UInt64 parse fails
    }

    @Test("centerCoordinate rejects non-hex garbage → nil",
          arguments: ["zzzz", "not-a-hex", "gggg"])
    func centerCoordinateRejectsNonHexGarbage(garbage: String) {
        #expect(H3Service.centerCoordinate(for: garbage) == nil)
    }

    @Test("cellBoundary rejects the zero hex and garbage → nil")
    func cellBoundaryRejectsZeroAndGarbageHex() {
        #expect(H3Service.cellBoundary(for: "0") == nil)
        #expect(H3Service.cellBoundary(for: "xyz") == nil)
    }

    // MARK: - Geographic-range invariants

    @Test("every cellBoundary vertex has lat ∈ [-90,90] and lon ∈ [-180,180]")
    func cellBoundaryVerticesAllInValidRanges() throws {
        let cell = try #require(H3Service.cellIndex(latitude: Self.athens.lat,
                                                    longitude: Self.athens.lon))
        let boundary = try #require(H3Service.cellBoundary(for: cell))
        for vertex in boundary {
            #expect(vertex.latitude >= -90 && vertex.latitude <= 90)
            #expect(vertex.longitude >= -180 && vertex.longitude <= 180)
        }
    }

    @Test("a cell's centerCoordinate sits within ~0.1° of the input coordinate (sane, not antipodal)")
    func centerCoordinateOfCellIsNearOriginalCoordinate() throws {
        let cell = try #require(H3Service.cellIndex(latitude: Self.athens.lat,
                                                    longitude: Self.athens.lon))
        let center = try #require(H3Service.centerCoordinate(for: cell))
        #expect(abs(center.latitude - Self.athens.lat) < 0.1)
        #expect(abs(center.longitude - Self.athens.lon) < 0.1)
    }
}
