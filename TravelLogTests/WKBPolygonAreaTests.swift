//
//  WKBPolygonAreaTests.swift
//  TravelLogTests
//
//  `WKBPolygon.areaKm2`: the spherical size the island cap reads
//  (`GeocodeResolver.islandAreaCapKm2`). Synthetic rings with known
//  areas; the shipped islands are measured in GeocodeResolverIslandCapTests.
//

import Testing
import Foundation
@testable import TravelLog

struct WKBPolygonAreaTests {

    private static func u8(_ v: UInt8, into d: inout Data) { d.append(v) }
    private static func u32(_ v: UInt32, into d: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private static func f64(_ v: Double, into d: inout Data) {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
    }
    private static func appendRing(_ points: [(lon: Double, lat: Double)], into d: inout Data) {
        u32(UInt32(points.count), into: &d)
        for p in points { f64(p.lon, into: &d); f64(p.lat, into: &d) }
    }
    private static func polygon(_ rings: [[(lon: Double, lat: Double)]]) -> Data {
        var d = Data()
        u8(0x01, into: &d); u32(3, into: &d); u32(UInt32(rings.count), into: &d)
        for ring in rings { appendRing(ring, into: &d) }
        return d
    }
    private static func multiPolygon(_ polygons: [[[(lon: Double, lat: Double)]]]) -> Data {
        var d = Data()
        u8(0x01, into: &d); u32(6, into: &d); u32(UInt32(polygons.count), into: &d)
        for rings in polygons {
            u8(0x01, into: &d); u32(3, into: &d); u32(UInt32(rings.count), into: &d)
            for ring in rings { appendRing(ring, into: &d) }
        }
        return d
    }
    private static func square(lon: Double, lat: Double, size: Double) -> [(lon: Double, lat: Double)] {
        [(lon, lat), (lon + size, lat), (lon + size, lat + size), (lon, lat + size), (lon, lat)]
    }

    /// Exact spherical area of a lon/lat rectangle: R² · Δλ · (sin φ2 − sin φ1).
    private static func exactRectangleKm2(lon1: Double, lon2: Double, lat1: Double, lat2: Double) -> Double {
        let r = 6371.0088, k = Double.pi / 180
        return r * r * abs(lon2 - lon1) * k * abs(sin(lat2 * k) - sin(lat1 * k))
    }

    @Test("a one-degree square at the equator measures about 12,364 km²")
    func equatorialSquare() throws {
        let poly = try #require(WKBPolygon(data: Self.polygon([Self.square(lon: 0, lat: 0, size: 1)])))
        let exact = Self.exactRectangleKm2(lon1: 0, lon2: 1, lat1: 0, lat2: 1)
        #expect(abs(poly.areaKm2 - exact) / exact < 0.001)
        #expect(abs(poly.areaKm2 - 12_364) < 5)
    }

    @Test("latitude shrinks the same square (Norway, 60°N)")
    func highLatitudeSquare() throws {
        let poly = try #require(WKBPolygon(data: Self.polygon([Self.square(lon: 10, lat: 60, size: 1)])))
        let exact = Self.exactRectangleKm2(lon1: 10, lon2: 11, lat1: 60, lat2: 61)
        #expect(abs(poly.areaKm2 - exact) / exact < 0.001)
        #expect(poly.areaKm2 < 12_364 * 0.55)
    }

    @Test("a hole is subtracted from its outer ring")
    func holeSubtracted() throws {
        let outer = Self.square(lon: 0, lat: 0, size: 2)
        let hole = Self.square(lon: 0.5, lat: 0.5, size: 1)
        let withHole = try #require(WKBPolygon(data: Self.polygon([outer, hole])))
        let solid = try #require(WKBPolygon(data: Self.polygon([outer])))
        let holeOnly = try #require(WKBPolygon(data: Self.polygon([hole])))
        #expect(abs(withHole.areaKm2 - (solid.areaKm2 - holeOnly.areaKm2)) < 1)
    }

    @Test("a MultiPolygon sums its parts")
    func multiPolygonSums() throws {
        let a = Self.square(lon: 0, lat: 0, size: 1)
        let b = Self.square(lon: 5, lat: 5, size: 1)
        let multi = try #require(WKBPolygon(data: Self.multiPolygon([[a], [b]])))
        let partA = try #require(WKBPolygon(data: Self.polygon([a])))
        let partB = try #require(WKBPolygon(data: Self.polygon([b])))
        #expect(abs(multi.areaKm2 - (partA.areaKm2 + partB.areaKm2)) < 1)
    }

    @Test("a ring across the antimeridian measures its own size, not the globe")
    func antimeridianRing() throws {
        // Fiji-shaped: lon runs 179.5 → 180 → -179.5, written the way OSM
        // stores it (a 359° jump between consecutive vertices).
        let ring: [(lon: Double, lat: Double)] = [
            (179.5, -17), (-179.5, -17), (-179.5, -16), (179.5, -16), (179.5, -17)
        ]
        let poly = try #require(WKBPolygon(data: Self.polygon([ring])))
        let exact = Self.exactRectangleKm2(lon1: 0, lon2: 1, lat1: -17, lat2: -16)
        #expect(abs(poly.areaKm2 - exact) / exact < 0.001)
    }

    @Test("winding direction does not change the magnitude")
    func windingIndependent() throws {
        let cw = Self.square(lon: 0, lat: 0, size: 1)
        let ccw = Array(cw.reversed())
        let a = try #require(WKBPolygon(data: Self.polygon([cw])))
        let b = try #require(WKBPolygon(data: Self.polygon([ccw])))
        #expect(abs(a.areaKm2 - b.areaKm2) < 0.001)
    }

    @Test("a degenerate ring has zero area")
    func degenerateRing() {
        #expect(WKBPolygon.ringAreaKm2([0, 0, 1, 1, 0, 0]) == 0)
        #expect(WKBPolygon.ringAreaKm2([]) == 0)
    }
}
