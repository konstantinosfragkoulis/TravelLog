//
//  WKBPolygonParseTests.swift
//  TravelLogTests
//
//  Exercises the WKB (Well-Known-Binary) Polygon/MultiPolygon decoder and its
//  ray-casting point-in-polygon (`WKBPolygon.init(data:)`, `.rings`,
//  `.contains(lon:lat:)`) in GeocodeResolver.swift. All inputs are SYNTHETIC
//  little-endian byte blobs assembled by hand — no bundled SQLite DB. The
//  highest-signal cases are the truncation (OOB-read fix) and
//  zero-count blobs: they assert a corrupt blob becomes a clean
//  nil rather than an out-of-bounds read / trap.
//
//  Not @MainActor: WKBPolygon is a `nonisolated struct`, no @Model touched.
//

import Testing
import Foundation
@testable import TravelLog

struct WKBPolygonParseTests {

    // MARK: - Little-endian byte builders

    /// Append a single byte.
    private static func u8(_ v: UInt8, into d: inout Data) {
        d.append(v)
    }

    /// Append a UInt32 in little-endian.
    private static func u32(_ v: UInt32, into d: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    /// Append a Double (f64) in little-endian. Natural WKB layout places these
    /// at offset-1-misaligned positions so the production `loadUnaligned` path
    /// is exercised.
    private static func f64(_ v: Double, into d: inout Data) {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
    }

    /// Append a ring (num_points word + flat lon/lat pairs).
    private static func appendRing(_ points: [(lon: Double, lat: Double)], into d: inout Data) {
        u32(UInt32(points.count), into: &d)
        for p in points {
            f64(p.lon, into: &d)
            f64(p.lat, into: &d)
        }
    }

    // MARK: - Fixture geometries

    /// A closed unit-square outer ring: lon ∈ [0,2], lat ∈ [0,2].
    private static let squarePoints: [(lon: Double, lat: Double)] = [
        (0, 0), (2, 0), (2, 2), (0, 2), (0, 0)
    ]

    /// Inner hole ring: lon ∈ [0.5,1.5], lat ∈ [0.5,1.5].
    private static let holePoints: [(lon: Double, lat: Double)] = [
        (0.5, 0.5), (1.5, 0.5), (1.5, 1.5), (0.5, 1.5), (0.5, 0.5)
    ]

    /// Type-3 single-ring square polygon.
    private static func simpleSquareWKB() -> Data {
        var d = Data()
        u8(0x01, into: &d)        // little-endian byte order
        u32(3, into: &d)          // geom type = Polygon
        u32(1, into: &d)          // num rings
        appendRing(squarePoints, into: &d)
        return d
    }

    /// Type-3 square with one inner hole ring (two rings).
    private static func squareWithHoleWKB() -> Data {
        var d = Data()
        u8(0x01, into: &d)
        u32(3, into: &d)
        u32(2, into: &d)          // num rings = outer + hole
        appendRing(squarePoints, into: &d)
        appendRing(holePoints, into: &d)
        return d
    }

    /// Type-6 MultiPolygon of two disjoint squares (second shifted +10 lon).
    private static func multiPolygonWKB() -> Data {
        var d = Data()
        u8(0x01, into: &d)
        u32(6, into: &d)          // geom type = MultiPolygon
        u32(2, into: &d)          // num polygons
        // sub-polygon 1: square at origin
        u8(0x01, into: &d)
        u32(3, into: &d)
        u32(1, into: &d)
        appendRing(squarePoints, into: &d)
        // sub-polygon 2: square shifted +10 lon
        u8(0x01, into: &d)
        u32(3, into: &d)
        u32(1, into: &d)
        appendRing(squarePoints.map { (lon: $0.lon + 10, lat: $0.lat) }, into: &d)
        return d
    }

    /// Smallest valid triangle (3 points) — type-3.
    private static func triangleWKB() -> Data {
        var d = Data()
        u8(0x01, into: &d)
        u32(3, into: &d)
        u32(1, into: &d)
        appendRing([(0, 0), (4, 0), (2, 4)], into: &d)
        return d
    }

    /// Degenerate ring of only 2 points (parses, but ringContains returns false).
    private static func twoPointRingWKB() -> Data {
        var d = Data()
        u8(0x01, into: &d)
        u32(3, into: &d)
        u32(1, into: &d)
        appendRing([(0, 0), (2, 2)], into: &d)
        return d
    }

    // MARK: - Happy-path parse

    @Test("a valid type-3 single-ring square decodes to one polygon entry with one flat ring")
    func parsesSimplePolygonIntoOneRingArray() throws {
        let poly = try #require(WKBPolygon(data: Self.simpleSquareWKB()))
        #expect(poly.rings.count == 1)                  // one polygon entry
        #expect(poly.rings[0].count == 1)               // one ring (outer only)
        // Flat storage contract: [lon0,lat0,lon1,lat1,...] → 2 * numPoints.
        #expect(poly.rings[0][0].count == Self.squarePoints.count * 2)
        // First stored pair is (lon0, lat0) of the first square vertex.
        #expect(poly.rings[0][0][0] == 0)
        #expect(poly.rings[0][0][1] == 0)
    }

    // MARK: - contains() ray-casting

    @Test("a point strictly inside the square is contained (odd crossing)")
    func pointStrictlyInsideSquareIsContained() throws {
        let poly = try #require(WKBPolygon(data: Self.simpleSquareWKB()))
        #expect(poly.contains(lon: 1.0, lat: 1.0))
    }

    @Test("a point clearly outside the square is not contained (even crossing)")
    func pointOutsideSquareIsNotContained() throws {
        let poly = try #require(WKBPolygon(data: Self.simpleSquareWKB()))
        #expect(poly.contains(lon: 5.0, lat: 5.0) == false)
    }

    @Test("a point inside the hole is excluded while a point in the outer band is contained")
    func pointInsideHoleIsNotContained() throws {
        let poly = try #require(WKBPolygon(data: Self.squareWithHoleWKB()))
        #expect(poly.rings[0].count == 2)                       // outer + hole
        #expect(poly.contains(lon: 1.0, lat: 1.0) == false)     // hole centroid → excluded
        #expect(poly.contains(lon: 0.2, lat: 0.2))              // outer band → contained
    }

    @Test("a MultiPolygon contains points in either sub-polygon but not between them")
    func multiPolygonContainsPointInEitherSubPolygon() throws {
        let poly = try #require(WKBPolygon(data: Self.multiPolygonWKB()))
        #expect(poly.rings.count == 2)                          // two polygon entries
        #expect(poly.contains(lon: 1.0, lat: 1.0))              // inside first square
        #expect(poly.contains(lon: 11.0, lat: 1.0))             // inside second (shifted +10)
        #expect(poly.contains(lon: 5.0, lat: 1.0) == false)     // gap between them
    }

    // MARK: - Header validation / rejection

    @Test("a big-endian byte-order marker (0x00) is rejected → nil")
    func bigEndianByteOrderRejected() {
        var d = Self.simpleSquareWKB()
        d[d.startIndex] = 0x00   // flip LE marker to BE
        #expect(WKBPolygon(data: d) == nil)
    }

    @Test("an unsupported geometry type (Point=1, LineString=2) is rejected → nil",
          arguments: [UInt32(1), UInt32(2), UInt32(4), UInt32(7)])
    func unsupportedGeometryTypeRejected(type: UInt32) {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(type, into: &d)
        Self.u32(1, into: &d)
        Self.appendRing(Self.squarePoints, into: &d)
        #expect(WKBPolygon(data: d) == nil)
    }

    @Test("a blob shorter than the 5-byte minimum is rejected → nil",
          arguments: [Data(), Data([0x01]), Data([0x01, 0x03, 0x00, 0x00])])
    func tooShortBlobRejected(blob: Data) {
        #expect(WKBPolygon(data: blob) == nil)
    }

    // MARK: - Truncation (OOB-read fix) — must NOT trap

    @Test("a square WKB truncated mid-point yields nil instead of reading past the buffer")
    func truncatedRingPointDataRejectedNotCrash() {
        let full = Self.simpleSquareWKB()
        // Cut a point's 16 bytes in half (drop the last 8 bytes of trailing pair).
        let truncated = full.prefix(full.count - 8)
        #expect(WKBPolygon(data: Data(truncated)) == nil)
    }

    @Test("a blob truncated right after num_rings (no point-count word) yields nil")
    func truncatedAfterRingCountRejected() {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(3, into: &d)
        Self.u32(1, into: &d)   // declares 1 ring, but no ring body follows
        #expect(WKBPolygon(data: d) == nil)
    }

    // MARK: - Zero-count corruption

    @Test("a type-3 polygon whose num_rings is 0 is rejected → nil")
    func zeroRingPolygonRejected() {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(3, into: &d)
        Self.u32(0, into: &d)   // num rings = 0
        #expect(WKBPolygon(data: d) == nil)
    }

    @Test("a type-3 polygon with one ring of 0 points is rejected → nil")
    func zeroPointRingRejected() {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(3, into: &d)
        Self.u32(1, into: &d)   // one ring
        Self.u32(0, into: &d)   // ...with zero points
        #expect(WKBPolygon(data: d) == nil)
    }

    @Test("a type-6 MultiPolygon whose num_polygons is 0 is rejected → nil")
    func zeroPolygonMultiPolygonRejected() {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(6, into: &d)
        Self.u32(0, into: &d)   // num polygons = 0
        #expect(WKBPolygon(data: d) == nil)
    }

    @Test("a type-6 MultiPolygon whose first sub-header declares a non-3 type is rejected → nil")
    func multiPolygonSubHeaderWrongTypeRejected() {
        var d = Data()
        Self.u8(0x01, into: &d)
        Self.u32(6, into: &d)
        Self.u32(1, into: &d)   // one sub-polygon
        // sub-header declares type 5 (not Polygon=3)
        Self.u8(0x01, into: &d)
        Self.u32(5, into: &d)
        Self.u32(1, into: &d)
        Self.appendRing(Self.squarePoints, into: &d)
        #expect(WKBPolygon(data: d) == nil)
    }

    // MARK: - Degenerate ring → contains false

    @Test("a ring with only 2 points parses but contains() returns false (n>=3 guard)")
    func degenerateRingUnderThreePointsContainsFalse() throws {
        let poly = try #require(WKBPolygon(data: Self.twoPointRingWKB()))
        #expect(poly.rings[0][0].count == 4)                   // 2 points × 2 = flat 4
        #expect(poly.contains(lon: 1.0, lat: 1.0) == false)    // ringContains n<3 → false
    }

    @Test("a minimal valid triangle reports false for a point outside it (no false positive)")
    func triangleContainsInsideButNotOutside() throws {
        let poly = try #require(WKBPolygon(data: Self.triangleWKB()))
        #expect(poly.contains(lon: 2.0, lat: 1.0))             // inside the triangle
        #expect(poly.contains(lon: 10.0, lat: 10.0) == false)  // clearly outside
    }
}

// MARK: - Bounds pre-check equivalence

/// `contains` skips the ray cast for points outside a ring's unwrapped box.
/// This pins that shortcut against a plain ray cast with no box, over random
/// rings including ones that straddle the antimeridian.
@Suite("WKBPolygon bounds pre-check")
struct WKBPolygonBoundsTests {

    private static func wkb(rings: [[(lon: Double, lat: Double)]]) -> Data {
        var d = Data()
        d.append(0x01)
        withUnsafeBytes(of: UInt32(3).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(rings.count).littleEndian) { d.append(contentsOf: $0) }
        for ring in rings {
            withUnsafeBytes(of: UInt32(ring.count).littleEndian) { d.append(contentsOf: $0) }
            for p in ring {
                withUnsafeBytes(of: p.lon.bitPattern.littleEndian) { d.append(contentsOf: $0) }
                withUnsafeBytes(of: p.lat.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    /// The production ray cast before the bounds shortcut existed.
    private static func referenceRingContains(_ ring: [Double], x: Double, y: Double) -> Bool {
        let n = ring.count / 2
        guard n >= 3 else { return false }
        let ref = ring[0]
        let px = ref + GeoMath.wrappedLongitudeDelta(x, ref)
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = ref + GeoMath.wrappedLongitudeDelta(ring[2 * i], ref)
            let yi = ring[2 * i + 1]
            let xj = ref + GeoMath.wrappedLongitudeDelta(ring[2 * j], ref)
            let yj = ring[2 * j + 1]
            if ((yi > y) != (yj > y)) && (px < (xj - xi) * (y - yi) / (yj - yi + 1e-30) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func referenceContains(_ poly: WKBPolygon, lon: Double, lat: Double) -> Bool {
        for rings in poly.rings where !rings.isEmpty {
            if referenceRingContains(rings[0], x: lon, y: lat) {
                let inHole = rings.dropFirst().contains { referenceRingContains($0, x: lon, y: lat) }
                if !inHole { return true }
            }
        }
        return false
    }

    @Test("random rings, including antimeridian ones, agree with the plain ray cast")
    func boundsShortcutMatchesPlainRayCast() throws {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {   // deterministic LCG in [0, 1)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for polygonIndex in 0..<200 {
            let centerLon = polygonIndex % 4 == 0 ? 179.5 : next() * 360 - 180
            let centerLat = next() * 160 - 80
            let radius = 0.5 + next() * 20
            let count = 3 + Int(next() * 12)
            var outer: [(lon: Double, lat: Double)] = []
            for k in 0..<count {
                let angle = Double(k) / Double(count) * 2 * .pi
                let r = radius * (0.4 + next() * 0.6)
                var lon = centerLon + cos(angle) * r
                if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
                outer.append((lon, min(89, max(-89, centerLat + sin(angle) * r))))
            }
            outer.append(outer[0])
            let hole = outer.map { (lon: centerLon + ($0.lon - centerLon) * 0.3, lat: centerLat + ($0.lat - centerLat) * 0.3) }
            let poly = try #require(WKBPolygon(data: Self.wkb(rings: [outer, hole])))
            for _ in 0..<60 {
                let lon = centerLon + (next() * 2 - 1) * radius * 1.5
                let lat = centerLat + (next() * 2 - 1) * radius * 1.5
                let wrapped = lon > 180 ? lon - 360 : (lon < -180 ? lon + 360 : lon)
                #expect(poly.contains(lon: wrapped, lat: lat) == Self.referenceContains(poly, lon: wrapped, lat: lat),
                        "polygon \(polygonIndex) point (\(wrapped), \(lat))")
            }
        }
    }
}
