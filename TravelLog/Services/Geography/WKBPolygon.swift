//
//  WKBPolygon.swift
//  TravelLog
//

import Foundation
import CoreLocation

// MARK: - WKB Polygon Parser + Point-in-Polygon

/// Minimal Well-Known-Binary decoder, restricted to Polygon (type 3) and
/// MultiPolygon (type 6). Sufficient for our admin-1 / FUA / island layers.
///
/// `nonisolated` because under Swift 6 default-Main isolation a plain
/// `struct` here would be @MainActor — preventing access from
/// `GeocodeResolver`'s actor context.
/// The build pipeline emits little-endian WKB.
/// PIP uses planar ray-casting; source polygon-edge uncertainty exceeds projection error at this scale.
nonisolated struct WKBPolygon {

    /// Each entry is one polygon's rings; rings[0] is the outer ring, the
    /// rest are holes. For MultiPolygon, we have multiple entries.
    let rings: [[[CLLocationDegrees]]]   // [poly][ring][pt: [lon, lat]]

    /// Per-ring bounds in the ring's own unwrapped frame (longitudes are
    /// `ring[0] + wrappedLongitudeDelta`, exactly as `ringContains` sees
    /// them), so a point outside the box can skip the ray cast. Shape
    /// mirrors `rings`.
    let ringBounds: [[RingBounds]]

    nonisolated struct RingBounds {
        let minX: Double, maxX: Double, minY: Double, maxY: Double

        init(ring: [CLLocationDegrees]) {
            let ref = ring.first ?? 0
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            var i = 0
            while i + 1 < ring.count {
                let x = ref + GeoMath.wrappedLongitudeDelta(ring[i], ref)
                let y = ring[i + 1]
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                i += 2
            }
            self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
        }
    }

    init?(data: Data) {
        guard data.count >= 5 else { return nil }
        var offset = 0
        let parsed: [[[CLLocationDegrees]]]? = data.withUnsafeBytes { raw -> [[[CLLocationDegrees]]]? in
            guard let base = raw.baseAddress else { return nil }
            // WKB’s one-byte marker misaligns UInt32 fields; use loadUnaligned for ARM safety.
            let byteOrder = base.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            guard byteOrder == 0x01 else { return nil }  // we only emit LE
            offset += 1
            let geomType = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4

            // Bounds-check every read; return zero on overflow so callers reject truncated polygons.
            func readU32() -> UInt32 {
                guard offset + 4 <= data.count else { return 0 }
                let v = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
                return v
            }
            func readF64() -> Double {
                guard offset + 8 <= data.count else { return 0 }
                let v = base.loadUnaligned(fromByteOffset: offset, as: Double.self)
                offset += 8
                return v
            }
            func readRing() -> [CLLocationDegrees]? {
                let nPts = Int(readU32())
                guard nPts > 0, offset + nPts * 16 <= data.count else { return nil }
                // Store flat: [lon0, lat0, lon1, lat1, ...] for cache locality
                var pts = [CLLocationDegrees](); pts.reserveCapacity(nPts * 2)
                for _ in 0..<nPts {
                    pts.append(readF64())   // lon
                    pts.append(readF64())   // lat
                }
                return pts
            }
            func readPolygonBody() -> [[CLLocationDegrees]]? {
                let nRings = Int(readU32())
                guard nRings > 0 else { return nil }
                var rs: [[CLLocationDegrees]] = []
                // Cap the reservation by the blob size: a corrupt-but-in-bounds
                // count word could otherwise request a multi-GB allocation. A
                // ring occupies >1 byte, so the count can't exceed data.count.
                rs.reserveCapacity(min(nRings, data.count))
                for _ in 0..<nRings {
                    guard let r = readRing() else { return nil }
                    rs.append(r)
                }
                return rs
            }

            switch geomType {
            case 3:
                guard let r = readPolygonBody() else { return nil }
                return [r]
            case 6:
                let nPolys = Int(readU32())
                guard nPolys > 0 else { return nil }
                var result: [[[CLLocationDegrees]]] = []
                result.reserveCapacity(min(nPolys, data.count))  // bound vs corrupt count
                for _ in 0..<nPolys {
                    // Validate each sub-polygon’s own byte-order marker before decoding its little-endian header.
                    guard offset + 5 <= data.count else { return nil }
                    guard base.loadUnaligned(fromByteOffset: offset, as: UInt8.self) == 0x01 else { return nil }
                    offset += 1
                    let subType = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    offset += 4
                    guard subType == 3, let r = readPolygonBody() else { return nil }
                    result.append(r)
                }
                return result
            default:
                return nil
            }
        }

        guard let r = parsed else { return nil }
        self.rings = r
        self.ringBounds = r.map { poly in poly.map { RingBounds(ring: $0) } }
    }

    /// Mean Earth radius, kilometres (IUGG R1).
    private static let earthRadiusKm = 6371.0088

    /// Surface area in km² on the sphere: every outer ring minus its
    /// holes, summed over the MultiPolygon. Spherical, not planar, so a
    /// Norwegian island is not stretched by its latitude, and each
    /// longitude step is wrapped into (-180°, 180°] so a ring that crosses
    /// the antimeridian (Fiji, Chukotka) measures its true size instead
    /// of the whole globe. Cost is one pass over the vertices, the same
    /// order as `contains`; `GeocodeResolver` caches the value per island.
    var areaKm2: Double {
        var total = 0.0
        for poly in rings {
            for (index, ring) in poly.enumerated() {
                let area = Self.ringAreaKm2(ring)
                total += index == 0 ? area : -area
            }
        }
        return max(0, total)
    }

    /// Unsigned spherical area of one flat `[lon, lat, …]` ring via
    /// Σ (λ(i+1) − λ(i−1)) · sin φ(i) · R² / 2 over the cyclic vertex
    /// list (the closing duplicate vertex WKB writes is dropped first).
    static func ringAreaKm2(_ ring: [CLLocationDegrees]) -> Double {
        var count = ring.count / 2
        if count >= 2, ring[0] == ring[(count - 1) * 2], ring[1] == ring[(count - 1) * 2 + 1] {
            count -= 1
        }
        guard count >= 3 else { return 0 }
        let toRadians = Double.pi / 180
        var sum = 0.0
        for i in 0..<count {
            let previous = (i + count - 1) % count
            let next = (i + 1) % count
            var deltaLon = ring[next * 2] - ring[previous * 2]
            if deltaLon > 180 { deltaLon -= 360 } else if deltaLon < -180 { deltaLon += 360 }
            sum += deltaLon * toRadians * sin(ring[i * 2 + 1] * toRadians)
        }
        return abs(sum) * earthRadiusKm * earthRadiusKm / 2
    }

    /// Ray-casting point-in-polygon. Iterates outer ring of each polygon
    /// and counts edge crossings; even = outside, odd = inside. If the
    /// point is in the outer ring, we then verify it's NOT in any hole.
    func contains(lon: Double, lat: Double) -> Bool {
        for (polyIndex, poly) in rings.enumerated() where !poly.isEmpty {
            let outer = poly[0]
            let bounds = ringBounds[polyIndex]
            if Self.ringContains(ring: outer, bounds: bounds[0], x: lon, y: lat) {
                var inHole = false
                if poly.count > 1 {
                    for i in 1..<poly.count {
                        if Self.ringContains(ring: poly[i], bounds: bounds[i], x: lon, y: lat) {
                            inHole = true
                            break
                        }
                    }
                }
                if !inHole { return true }
            }
        }
        return false
    }

    /// Classic ray-casting. Ring is stored flat: [x0, y0, x1, y1, ...].
    /// Edge from (x_i, y_i) to (x_j, y_j); test if a horizontal ray from
    /// (x, y) going +x crosses the edge.
    ///
    /// Unwrap vertices and the test point around the ring’s FIRST VERTEX, as in `GeoMath.pointInPolygon`.
    /// This prevents ±180° edges from spanning the globe and keeps distant points outside the ring.
    private static func ringContains(
        ring: [CLLocationDegrees], bounds: RingBounds, x: Double, y: Double
    ) -> Bool {
        let n = ring.count / 2
        guard n >= 3 else { return false }
        let ref = ring[0]
        let px = ref + GeoMath.wrappedLongitudeDelta(x, ref)
        // A point strictly outside the ring's box has an even crossing count
        // (zero to the right of it, or every straddling edge to its left), so
        // the ray cast below could only answer false. The margin keeps a point
        // on the box edge on the exact path.
        if y < bounds.minY || y > bounds.maxY
            || px < bounds.minX - 1e-9 || px > bounds.maxX + 1e-9 {
            return false
        }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = ref + GeoMath.wrappedLongitudeDelta(ring[2 * i], ref)
            let yi = ring[2 * i + 1]
            let xj = ref + GeoMath.wrappedLongitudeDelta(ring[2 * j], ref)
            let yj = ring[2 * j + 1]
            if ((yi > y) != (yj > y)) &&
               (px < (xj - xi) * (y - yi) / (yj - yi + 1e-30) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
