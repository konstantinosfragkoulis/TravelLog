//
//  HomeShape.swift
//  TravelLog
//

import Foundation
import CoreLocation

/// The region a user's ordinary life occupies — the replacement for the
/// declared home's `radiusKm` circle.
///
/// # Why a shape and not a radius
///
/// A circle covers every direction equally; daily routines do not. A routine
/// destination can be farther from home than a nearby day-trip destination,
/// so distance from the home point alone cannot separate routines from travel.
///
/// # Composition
///
/// ```
/// shape = the GHS urban centre containing the declared home     (seed)
///      ?? a 1 km disc at the declared home                      (fallback)
/// ```
///
/// The urban centre is the *built-up city*, not a commuting zone. A GHS-FUA
/// commuting-zone seed can overstate home coverage, simultaneously shrinking
/// `D` and inflating `D*`, suppressing nearby trips through both quantities.
/// The urban-centre seed keeps coverage tied to the built-up area.
///
/// # What this type is for
///
/// Two quantities, both consumed by the trip-confidence score:
///
/// - **`distanceKm(to:)`** — `D`, the distance from a point to the *shape*,
///   zero inside it. Distance from the shape rather than from the home point
///   is what makes one threshold portable: "20 km beyond where I ordinarily
///   go" means the same thing in Athens and in a village, while "20 km from my
///   house" does not.
/// - **`areaEquivalentRadiusKm`** — `D*`, the per-user distance scale.
///
/// # Value semantics, deliberately
///
/// `GeocodeResolver` is an actor, but the consumers of a home shape
/// (`TripClassifier.matchesHome`, `StayClusterer.closestHomeDistanceKm`) are
/// `nonisolated static` pure functions on synchronous paths. So the shape is
/// resolved **once**, asynchronously, and then carried as a `Sendable` value.
/// This mirrors the existing `HomeRing` pattern and is the same reason
/// `CollectionsAggregator` could not call the resolver inline.
///
/// # Not yet included: the land clip
///
/// Clipping the shape to land (`admin1 ∪ island`) would prevent a coastal disc
/// from reaching across water. It is redundant for urban-centre seeds because
/// GHSL polygons are built-up land by construction. The fallback disc reaches
/// at most 1 km over water. Expansion discs, disabled by default, need separate
/// consideration of land clipping.
nonisolated struct HomeShape: Sendable, Equatable {

    /// Where the shape came from. Carried so callers can report honestly and
    /// so tests can assert which branch was taken.
    enum Seed: Sendable, Equatable {
        /// A GHS-UCDB R2024A urban centre containing the declared home.
        /// `name` is nil for the 14 source centres that carry none.
        case urbanCentre(id: Int64, name: String?)
        /// No urban centre contains the declared home — roughly 55 % of the
        /// world's population, and NOT only villagers: the GHS density floor
        /// (1,500 inh./km² contiguous) also excludes most North American and
        /// Australian suburbs. Expansion is what makes this case work.
        case fallbackDisc
    }

    /// Radius of the fallback disc, and the floor on `D*`.
    static let fallbackRadiusKm: Double = 1.0

    /// Kilometres per degree of latitude on the mean sphere the rest of the
    /// app measures with (`CLLocation` distances agree to well under a metre
    /// at these scales).
    private static let kmPerDegreeLatitude: Double = 6_371.0088 * .pi / 180.0

    let seed: Seed
    /// The declared home. Anchors the fallback disc, and is retained for the
    /// urban-centre case so a shape always knows the point it was resolved for.
    let centreLatitude: Double
    let centreLongitude: Double
    /// For an urban centre this is the SOURCE ATTRIBUTE `area_km2`, never the
    /// polygon's computed area: the attribute is measured on the 1 km grid the
    /// geometry derives from, and it survives any future simplification.
    let areaKm2: Double
    /// `[polygon][ring][point: lon, lat]`, outer ring first. Empty for the disc.
    let rings: [[[CLLocationDegrees]]]

    // MARK: - Construction

    /// Degenerate geometry degrades to the fallback disc rather than producing
    /// an `.urbanCentre` whose label lies about what it contains.
    ///
    /// Without this the seed and the geometry can disagree: `contains` and
    /// `distanceKm` both branch on `rings.isEmpty`, so a `.urbanCentre` with no
    /// usable ring would silently behave as a 1 km disc while still reporting
    /// an urban-centre seed and that centre's `areaKm2`. Keeping the invariant
    /// — **`.urbanCentre` ⟺ at least one outer ring with ≥ 3 points** — means
    /// every branch below is reachable only in the state it was written for.
    /// A truncated or corrupt WKB blob is the realistic way to get here.
    static func urbanCentre(
        id: Int64, name: String?, areaKm2: Double,
        rings: [[[CLLocationDegrees]]],
        centreLatitude: Double, centreLongitude: Double
    ) -> HomeShape {
        let usable = rings.contains { ($0.first?.count ?? 0) >= 6 }   // ≥3 flat pairs
        guard usable else {
            return .fallbackDisc(latitude: centreLatitude, longitude: centreLongitude)
        }
        return HomeShape(seed: .urbanCentre(id: id, name: name),
                         centreLatitude: centreLatitude, centreLongitude: centreLongitude,
                         areaKm2: areaKm2, rings: rings)
    }

    static func fallbackDisc(latitude: Double, longitude: Double) -> HomeShape {
        HomeShape(seed: .fallbackDisc,
                  centreLatitude: latitude, centreLongitude: longitude,
                  areaKm2: .pi * fallbackRadiusKm * fallbackRadiusKm,
                  rings: [])
    }

    // MARK: - The two quantities the score needs

    /// `D*` — the shape's area-equivalent radius, `√(A/π)`.
    ///
    /// **The area radius, not the shape's reach.** Using the reach makes the
    /// scale depend on the farthest outpost: one distant commute can inflate
    /// `D*` and suppress nearby trips. The area radius reflects the total area
    /// rather than the most distant point.
    ///
    /// Floored at `fallbackRadiusKm`. Without it the two smallest urban centres
    /// in the source (1 km²) would yield `D* = 0.56 km` — a *tighter* trigger
    /// than having no urban centre at all, which is perverse: the fallback disc
    /// represents our minimum belief about anyone's ordinary range, so no seed
    /// should produce less.
    var areaEquivalentRadiusKm: Double {
        max(Self.fallbackRadiusKm, (areaKm2 / .pi).squareRoot())
    }

    /// Whether a point lies inside the shape.
    func contains(latitude: Double, longitude: Double) -> Bool {
        guard !rings.isEmpty else {
            return greatCircleKm(toLatitude: latitude, longitude: longitude)
                <= Self.fallbackRadiusKm
        }
        for polygon in rings where !polygon.isEmpty {
            guard ringContains(polygon[0], longitude: longitude, latitude: latitude) else {
                continue
            }
            let inHole = polygon.dropFirst().contains {
                ringContains($0, longitude: longitude, latitude: latitude)
            }
            if !inHole { return true }
        }
        return false
    }

    /// `D` — kilometres from a point to the nearest part of the shape, and
    /// **exactly zero** anywhere inside it.
    ///
    /// Distances are computed in a local equirectangular frame anchored at the
    /// query point, with longitudes taken through `GeoMath.wrappedLongitudeDelta`
    /// so a shape near ±180° measures correctly rather than half a world away.
    /// Planar geometry is right at this scale — an urban centre spans at most
    /// 1.56° of longitude in the whole source.
    func distanceKm(toLatitude latitude: Double, longitude: Double) -> Double {
        if rings.isEmpty {
            return max(0, greatCircleKm(toLatitude: latitude, longitude: longitude)
                          - Self.fallbackRadiusKm)
        }
        if contains(latitude: latitude, longitude: longitude) { return 0 }

        let kx = Self.kmPerDegreeLatitude * cos(latitude * .pi / 180.0)
        let ky = Self.kmPerDegreeLatitude
        var best = Double.greatestFiniteMagnitude
        for polygon in rings {
            // Holes are not measured to: a point inside a hole is outside the
            // shape, and its true distance is to the hole's boundary — which is
            // part of the outer ring's complement, so the outer ring's own
            // segments give the wrong answer. Urban centres have no holes in
            // practice; measuring only outer rings keeps this honest and cheap.
            // Rings are stored FLAT — [x0, y0, x1, y1, …] — matching
            // `WKBPolygon`. Indexing them as coordinate pairs is a real bug the
            // compiler catches only because the element type is Double.
            guard let ring = polygon.first else { continue }
            let count = ring.count / 2
            guard count >= 2 else { continue }
            for index in 0..<count {
                let next = (index + 1) % count
                let ax = GeoMath.wrappedLongitudeDelta(ring[2 * index], longitude) * kx
                let ay = (ring[2 * index + 1] - latitude) * ky
                let bx = GeoMath.wrappedLongitudeDelta(ring[2 * next], longitude) * kx
                let by = (ring[2 * next + 1] - latitude) * ky
                best = min(best, Self.distanceToSegment(ax: ax, ay: ay, bx: bx, by: by))
            }
        }
        return best == .greatestFiniteMagnitude ? 0 : best
    }

    // MARK: - Geometry helpers

    /// Distance from the ORIGIN to segment a–b, both already in the local
    /// km frame centred on the query point.
    private static func distanceToSegment(
        ax: Double, ay: Double, bx: Double, by: Double
    ) -> Double {
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (ax * ax + ay * ay).squareRoot() }
        // Projection of (origin - a) onto the segment, clamped to it.
        let t = max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        let px = ax + t * dx, py = ay + t * dy
        return (px * px + py * py).squareRoot()
    }

    private func greatCircleKm(toLatitude latitude: Double, longitude: Double) -> Double {
        CLLocation(latitude: centreLatitude, longitude: centreLongitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude)) / 1000.0
    }

    /// Ray casting in the first-vertex longitude frame — the same construction
    /// as `GeocodeResolver.WKBPolygon.ringContains` and `GeoMath.pointInPolygon`,
    /// so a ring crossing ±180° never presents a 360° jump edge to the planar
    /// test. Kept byte-identical in behaviour to the resolver's version: this
    /// type must agree with the layer probe that produced its rings.
    private func ringContains(
        _ ring: [CLLocationDegrees], longitude: Double, latitude: Double
    ) -> Bool {
        // Flat layout: [x0, y0, x1, y1, …] — see `WKBPolygon.rings`.
        let count = ring.count / 2
        guard count >= 3 else { return false }
        let reference = ring[0]
        let px = reference + GeoMath.wrappedLongitudeDelta(longitude, reference)
        var inside = false
        var j = count - 1
        for i in 0..<count {
            let xi = reference + GeoMath.wrappedLongitudeDelta(ring[2 * i], reference)
            let yi = ring[2 * i + 1]
            let xj = reference + GeoMath.wrappedLongitudeDelta(ring[2 * j], reference)
            let yj = ring[2 * j + 1]
            if (yi > latitude) != (yj > latitude),
               px < (xj - xi) * (latitude - yi) / (yj - yi + 1e-30) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Resolution

/// Resolves a declared home coordinate into its `HomeShape`.
///
/// Thin by design: the urban-centre probe lives in `GeocodeResolver` so it
/// reuses the already-open SQLite handle, the cached prepared statements and
/// the shared `WKBPolygon` parser rather than opening a second connection.
///
/// `nonisolated` so a cache-miss resolve (the pipeline's own priming
/// included) goes straight from the provider actor to the geocoder actor
/// instead of detouring through the main actor. Pure glue with no state;
/// the convention for such types.
nonisolated enum HomeShapeResolver {

    /// The shape for a declared home. Never fails — a home with no urban
    /// centre, or a device whose geocoder predates the `urban_centre` layer,
    /// falls back to the disc.
    static func resolve(
        latitude: Double,
        longitude: Double,
        using resolver: GeocodeResolver = .shared
    ) async -> HomeShape {
        if let hit = await resolver.urbanCentre(latitude: latitude, longitude: longitude) {
            return .urbanCentre(id: hit.id, name: hit.name, areaKm2: hit.areaKm2,
                                rings: hit.rings,
                                centreLatitude: latitude, centreLongitude: longitude)
        }
        return .fallbackDisc(latitude: latitude, longitude: longitude)
    }
}

/// Resolves and caches one `HomeShape` per declared-home coordinate.
///
/// The pipeline asks per pass, and a resolve walks the R*Tree plus a
/// point-in-polygon test, so the result is memoised. Keyed on the rounded
/// coordinate rather than the `Home.id`: a home that is edited in place keeps
/// its id but may move, and two homes at the same spot should share the answer.
actor HomeShapeProvider {

    static let shared = HomeShapeProvider()

    private struct Key: Hashable {
        let latitude: Double
        let longitude: Double
        /// ~1 m — far below any decision this feeds, and enough that floating
        /// point noise in a re-read coordinate cannot miss the cache.
        init(latitude: Double, longitude: Double) {
            self.latitude = (latitude * 100_000).rounded() / 100_000
            self.longitude = (longitude * 100_000).rounded() / 100_000
        }
    }

    private var cache: [Key: HomeShape] = [:]

    func shape(latitude: Double, longitude: Double) async -> HomeShape {
        let key = Key(latitude: latitude, longitude: longitude)
        if let cached = cache[key] { return cached }
        let resolved = await HomeShapeResolver.resolve(latitude: latitude,
                                                       longitude: longitude)
        cache[key] = resolved
        return resolved
    }

    /// Drop the memo — call when the bundled geocoder changes underneath us.
    /// Home edits do NOT need this: a moved home is a different key.
    func invalidate() { cache.removeAll() }

    // Welcome-Home uses TripClassifier.currentHomeSeedCovers; full membership includes orbit and overrides.
}
