//
//  GeoMath.swift
//  TravelLog
//
//  Shared longitude-wrap / dateline-safe geometry primitives. Use these
//  instead of raw longitude subtraction, linear longitude averaging or
//  fixed-degree longitude windows, which break at ±180° and near the poles.
//
//  Every function is pure and behavior-identical to the naive math
//  whenever the operands are less than 180° of longitude apart.
//

import Foundation
import CoreLocation

nonisolated enum GeoMath {

    /// Normalize a longitude into [-180, 180). In-range values return
    /// BIT-IDENTICAL (the fast path skips the modulo round-trip, which
    /// introduces float noise even for values it doesn't change).
    static func normalizedLongitude(_ lon: Double) -> Double {
        if lon >= -180 && lon < 180 { return lon }
        var l = (lon + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return l - 180
    }

    /// Signed shortest-arc longitude difference `a − b`, in [-180, 180].
    /// BIT-IDENTICAL to plain `a − b` whenever |a − b| ≤ 180 — that exact
    /// identity is what makes migrating call sites regression-safe.
    /// (Branching, not modulo: valid for normalized inputs, where the raw
    /// difference is always within ±360.)
    static func wrappedLongitudeDelta(_ a: Double, _ b: Double) -> Double {
        let d = a - b
        if d > 180 { return d - 360 }
        if d < -180 { return d + 360 }
        return d
    }

    /// Dateline-safe incremental running mean: the update the stay
    /// clusterer / ping-attach paths use (`c + (x − c) / n`), but stepping
    /// along the shortest arc. Identical to the linear update when the new
    /// point is < 180° from the current centroid — always true for points
    /// joining a kilometres-scale cluster.
    static func runningMeanLongitude(current: Double, adding lon: Double, newCount: Double) -> Double {
        normalizedLongitude(current + wrappedLongitudeDelta(lon, current) / newCount)
    }

    /// Longitude half-window (degrees) that spans the same GROUND distance
    /// as `equatorDegrees` does at the equator. Fixed-degree windows shrink
    /// to metres near the poles (geocoder recall loss);
    /// scaling by 1/cos(lat) keeps the search kilometre-scale everywhere,
    /// clamped to the full circle at extreme latitudes.
    static func longitudeWindowHalfWidth(equatorDegrees: Double, atLatitude latitude: Double) -> Double {
        let cosLat = cos(latitude * .pi / 180)
        guard cosLat > 0.01 else { return 180 } // past ~±89.4°: search the full circle
        return min(equatorDegrees / cosLat, 180)
    }

    /// Split the wrapped longitude interval `center ± halfWidth` into one
    /// or two in-range `[min, max]` segments. R*Tree / BETWEEN queries and
    /// simple range tests cannot wrap; callers run one pass per segment.
    static func longitudeSegments(center: Double, halfWidth: Double) -> [(min: Double, max: Double)] {
        guard halfWidth < 180 else { return [(-180, 180)] }
        let c = normalizedLongitude(center)
        let lo = c - halfWidth
        let hi = c + halfWidth
        if lo < -180 { return [(-180, hi), (lo + 360, 180)] }
        if hi > 180 { return [(lo, 180), (-180, hi - 360)] }
        return [(lo, hi)]
    }

    /// True when `lon` lies inside any of the given segments (the query-side
    /// twin of `longitudeSegments` for in-memory filtering).
    static func segmentsContain(_ segments: [(min: Double, max: Double)], longitude: Double) -> Bool {
        segments.contains { longitude >= $0.min && longitude <= $0.max }
    }

    /// Dateline-safe ray-cast point-in-polygon: vertex longitudes AND the
    /// test point are unwrapped into the frame anchored at the polygon's
    /// FIRST VERTEX before the classic crossing test — a polygon straddling
    /// ±180° stays continuous, and a point on the far side of the world
    /// unwraps far outside it (correctly "outside", where unwrapping
    /// relative to the point would smear the polygon around the globe).
    /// Valid for polygons spanning < 180° of longitude (true for every H3
    /// cell and every admin/FUA/island polygon the app ships).
    static func pointInPolygon(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        let ref = polygon[0].longitude
        let px = ref + wrappedLongitudeDelta(point.longitude, ref)
        let py = point.latitude
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].latitude, yj = polygon[j].latitude
            let xi = ref + wrappedLongitudeDelta(polygon[i].longitude, ref)
            let xj = ref + wrappedLongitudeDelta(polygon[j].longitude, ref)
            if ((yi > py) != (yj > py)) &&
                (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Bounding center/span of a set of longitudes, computed in unwrapped
    /// space relative to the first value — a cluster straddling ±180° gets
    /// its true tight box instead of a whole-world span. Valid for spreads
    /// < 180°.
    static func boundingLongitude(of lons: [Double]) -> (center: Double, span: Double)? {
        guard let first = lons.first else { return nil }
        var minU = first
        var maxU = first
        for lon in lons.dropFirst() {
            let u = first + wrappedLongitudeDelta(lon, first)
            minU = min(minU, u)
            maxU = max(maxU, u)
        }
        return (normalizedLongitude((minU + maxU) / 2), maxU - minU)
    }
}
