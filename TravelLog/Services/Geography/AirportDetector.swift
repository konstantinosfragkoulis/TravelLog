//
//  AirportDetector.swift
//  TravelLog
//
//  Detects whether a coordinate is at or near a known major airport.
//
//  Backed by `Resources/airports.json` — a curated, pre-filtered slice of
//  OurAirports.com (https://ourairports.com/data/, public domain) built by
//  `scripts/build-airports-json.py`. Contract: 6,172 entries = `large_airport`
//  + `medium_airport` + SMALL airports WITH scheduled service (island fields
//  like Syros); each record carries {code, lat, lon} plus Optional {name,
//  city, iso, svc, size, ring, isl, islid} — `svc` is the scheduled-service flag the Collections
//  dwell rules gate on, `size` the tier `AccessAirport` ranks by, `ring`
//  the airport's own `Stay.isAirport` radius, `isl` the island it stands
//  on (named as `Stay.islandName`) and `islid` that island's OSM id.
//  Rebuilding with only large/medium airports REGRESSES flight
//  detection. The JSON is bundled at design time; no network, no API calls, no
//  rate limits.
//
//  Used by:
//    - `StayClusterer` — sets `Stay.isAirport = true` at stay-creation time
//      when the centroid is inside an airport's ring (`ringMeters`).
//    - `AppDelegate.runAirportBackfillIfNeeded()` — re-stamps the flag on
//      existing stays once per bundled airport dataset version.
//    - `TripClassifier` (heuristic + Foundation Models prompt) — strong
//      transit signal for sub-24h airport stays.
//    - `TripTitlePolicy` — leaves airport-area stays out of the title so it
//      doesn't name airport-area localities such as "Jamaica" (JFK).
//    - `CollectionsAggregator` — Flight Log route codes; for an end outside
//      every ring, `AccessAirport` ranks the candidates by tier.
//

import Foundation
import CoreLocation
import OSLog

/// A single airport entry. Decoded from the bundled JSON.
///
/// The `code` is IATA when available (3 letters), falling back to ICAO or
/// `ident` for airports without an IATA assignment. Detection is purely
/// coordinate-based; `code` + the display fields feed the
/// Collections feature (airports-visited list, flight log).
///
/// `name` / `city` / `iso` / `svc` / `size` are Optional so a stale or
/// hand-trimmed JSON (the pre-Collections slice carried only code+lat+lon)
/// still decodes.
struct AirportRecord: Decodable, Sendable {
    let code: String
    let lat: Double
    let lon: Double
    let name: String?
    let city: String?
    let iso: String?
    /// OurAirports `scheduled_service` — false for military/GA fields
    /// (Tanagra LGTG). nil (old JSON) is treated as scheduled by consumers.
    let svc: Bool?
    /// The generator's tier: "L" major, "M" regional, "S" small
    /// (`scripts/build-airports-json.py`). nil in an older JSON and for a
    /// row OurAirports has since closed; read it through `tier`.
    var size: String? = nil
    /// The generator's ring in metres, from the runways' ends; nil when it
    /// is `maxRingMeters` or no runway is known. Read it through
    /// `ringMeters`.
    var ring: Double? = nil
    /// The island under `GeocodeResolver.islandAreaCapKm2` the airport
    /// stands on, named exactly as `GeocodeResolver` names
    /// `Stay.islandName`; nil on a mainland, a landmass above the cap, or
    /// in an older JSON (`scripts/build-airports-json.py`). For display.
    var isl: String? = nil
    /// That island's OSM id (`Geocoder.sqlite` `island.osm_id`), set even
    /// when the island has no name: the key `AccessAirport.reach` matches an
    /// end's island by (`AirportGround.island`). nil on a mainland, a
    /// landmass above the cap, or in an older JSON.
    var islid: Int64? = nil

    /// The widest ring, and every airport's before rings came from runways:
    /// a big airport's terminals sit up to this far from its reference point.
    nonisolated static let maxRingMeters: Double = 3000

    /// How far from `lat`/`lon` a stay still counts as at this airport: its
    /// runways' reach plus a kilometre, 1.5 to 3 km
    /// (`scripts/build-airports-json.py`). A small island field's ring stops
    /// short of the town or ferry port beside it, which a flat 3 km took in;
    /// a missing value is the old 3 km.
    nonisolated var ringMeters: Double {
        guard let ring, ring > 0 else { return Self.maxRingMeters }
        return min(ring, Self.maxRingMeters)
    }

    /// `size` as a tier; a major airport on the connecting-hub list
    /// (`FlightStops.hubCodes`) is a hub. Missing or unknown reads as
    /// `.unknown`.
    nonisolated var tier: AirportTier {
        switch size {
        case "L": return AccessAirport.hubCodes.contains(code) ? .hub : .major
        case "M": return .regional
        case "S": return .small
        default: return .unknown
        }
    }
}

/// How big an airport is, for guessing which one a place flew from.
nonisolated enum AirportTier: Sendable, Equatable {
    /// A major airport on the connecting-hub list: routes nearly everywhere.
    case hub
    /// OurAirports `large_airport` with a runway long-haul aircraft use.
    case major
    /// `medium_airport`, or a `large_airport` with a shorter runway.
    case regional
    /// `small_airport` with scheduled service.
    case small
    /// No tier in the data (an older JSON, a closed row).
    case unknown
}

/// The airport a place outside every airport's ring most likely flew from or
/// to: what the Flight Log shows on a route whose end is a town, not a
/// terminal. A small or regional airport next door rarely has a far or
/// international route, so the guess weighs the drive against the airport's
/// tier: door-to-airport road hours at `roadKmh` plus the expected cost of
/// the route not being there (`penaltyHours`), cheapest first.
///
/// - The user's own airports come first, as before tiers: the nearest one
///   they have been at within `FlightJudge.servingRadiusKm`. An airport they
///   were at carries no penalty either.
/// - Any scheduled airport within `FlightJudge.servingRadiusKm` competes; a
///   hub or major one also out to `majorReachKm`. Nothing within the serving
///   radius, no airport: the judge's "served" test is unchanged.
/// - Penalties, in hours. On a near flight (same country and under
///   `farFlightKm`), where a small field usually has the hop to its hub:
///   hub and major 0, regional 0.25, small 0.75. On a far one (another
///   country, or `farFlightKm` and more), where a regional airport lacks the
///   route about nine times in ten and a connection costs some 3.5 hours:
///   hub 0, major 0.5, regional 3, small 4. Unknown counts as regional, so a
///   JSON without tiers ranks by distance alone, as before.
///
/// A town 4 km from a regional airport and 125 km from a hub, on a flight
/// abroad: 0.08 + 3 = 3.1 hours against 2.5, the hub. The same town on a
/// domestic hop keeps the regional airport (0.33 against 2.5). Between a
/// hub and another major airport on a far flight, the hub wins unless the
/// other is more than 25 km (half an hour) closer.
///
/// Pure: the caller supplies the candidates (`AirportDetector.airports(near:)`)
/// and knows what the end is. `reach` narrows them first: an end on an
/// island (`AirportGround.island`, from its own coordinates) with a
/// scheduled airport among them ranks only the airports it reaches by land,
/// as for a near flight: the island's own (`AirportRecord.islid`), and
/// those in its commuting area or the same-named part of it over a border
/// (`CommutingArea.commutes(with:)`), the best evidence of daily road access
/// (Copenhagen's CPH on Amager, Singapore's Johor Bahru). An airport across
/// the water otherwise is a ferry away, and an island's own airport serves
/// its flights of any length. An end on the mainland, or on an island
/// without an airport, ranks every candidate.
nonisolated enum AccessAirport {
    /// Door to airport, at the judge's usual access speed.
    static let roadKmh: Double = FlightJudge.flightAccessUsualKmh
    /// A hub or major airport serves a place this far: 3 hours at `roadKmh`,
    /// the regional penalty on a far flight, so it can only win where the
    /// drive costs less than the connection it saves.
    static let majorReachKm: Double = 150
    /// A flight at least this long counts as far even at home.
    static let farFlightKm: Double = 1000
    /// `FlightStops.hubCodes`, as a set.
    static let hubCodes: Set<String> = Set(FlightStops.hubCodes)

    static func penaltyHours(_ tier: AirportTier, far: Bool) -> Double {
        switch tier {
        case .hub: return 0
        case .major: return far ? 0.5 : 0
        case .regional, .unknown: return far ? 3 : 0.25
        case .small: return far ? 4 : 0.75
        }
    }

    /// The likely airport for a place at `latitude`/`longitude`, nil when no
    /// scheduled airport is within `FlightJudge.servingRadiusKm` and none of
    /// `visited` is either. Ties break on distance, then code.
    static func choose(
        latitude: Double, longitude: Double,
        candidates: [AirportRecord], visited: [AirportRecord], far: Bool
    ) -> AirportRecord? {
        func km(_ airport: AirportRecord) -> Double {
            CollectionsAggregator.haversineKm(lat1: latitude, lon1: longitude,
                                              lat2: airport.lat, lon2: airport.lon)
        }
        var nearestVisited: (record: AirportRecord, km: Double)?
        for airport in visited where airport.svc != false {
            let distance = km(airport)
            guard distance <= FlightJudge.servingRadiusKm else { continue }
            if let current = nearestVisited,
               distance > current.km || (distance == current.km && airport.code >= current.record.code) {
                continue
            }
            nearestVisited = (airport, distance)
        }
        if let nearestVisited { return nearestVisited.record }

        let visitedCodes = Set(visited.map(\.code))
        var served = false
        var best: (record: AirportRecord, hours: Double, km: Double)?
        for airport in candidates where airport.svc != false {
            let distance = km(airport)
            let tier = airport.tier
            let withinServing = distance <= FlightJudge.servingRadiusKm
            guard withinServing || ((tier == .hub || tier == .major) && distance <= majorReachKm) else { continue }
            served = served || withinServing
            let hours = distance / roadKmh
                + (visitedCodes.contains(airport.code) ? 0 : penaltyHours(tier, far: far))
            if let current = best {
                if hours > current.hours { continue }
                if hours == current.hours {
                    if distance > current.km { continue }
                    if distance == current.km, airport.code >= current.record.code { continue }
                }
            }
            best = (airport, hours, distance)
        }
        return served ? best?.record : nil
    }

    /// What an end at a point may fly from (`reach`).
    nonisolated struct Reach {
        /// The nearest eligible scheduled airport within
        /// `FlightJudge.servingRadiusKm`: the judge times the end's flights
        /// through it. nil when none serves the place.
        let serving: AirportRecord?
        /// The eligible candidates `choose` ranks; empty when none serves
        /// the place.
        let candidates: [AirportRecord]
        /// The end's island when it restricts the candidates to the airports
        /// it reaches by land.
        let island: Int64?
        /// The end's ground, when it was read (only near island airports).
        let ground: AirportGround?

        /// Whether the user's airport `airport` may serve the end, by the
        /// same test as the candidates: any may, unless the end's island
        /// restricts it; then the island's own, and one in the end's
        /// commuting area or its cross-border part (`area` reads the
        /// airport's, only when asked).
        func admitsVisited(_ airport: AirportRecord, area: () -> CommutingArea?) -> Bool {
            guard let island else { return true }
            if airport.islid == island { return true }
            guard let here = ground?.area, let there = area() else { return false }
            return here.commutes(with: there)
        }
    }

    /// The airports an end at `latitude`/`longitude` may fly from, given
    /// `nearest` (the nearest scheduled airport within
    /// `FlightJudge.servingRadiusKm`, the judge's "served" test) and the
    /// `candidates` out to `majorReachKm`. Reads `ground` only when an
    /// airport among them stands on an island, and `area` (an airport's
    /// commuting area) only for an end that island restricts. When the end's
    /// island has a scheduled airport among them, only the island's and
    /// those in the end's commuting area or its cross-border part compete,
    /// and the nearest of those serves; otherwise every candidate does and
    /// `nearest` serves, as on a mainland.
    static func reach(
        latitude: Double, longitude: Double,
        nearest: AirportRecord?, candidates: [AirportRecord], ground: () -> AirportGround,
        area: (AirportRecord) -> CommutingArea?
    ) -> Reach {
        let pool = (nearest.map { [$0] } ?? []) + candidates
        guard pool.contains(where: { $0.islid != nil }) else {
            return Reach(serving: nearest, candidates: nearest == nil ? [] : pool, island: nil, ground: nil)
        }
        let here = ground()
        guard let island = here.island, pool.contains(where: { $0.islid == island && $0.svc != false }) else {
            return Reach(serving: nearest, candidates: nearest == nil ? [] : pool, island: nil, ground: here)
        }
        let own = pool.filter { airport in
            guard airport.svc != false else { return false }
            if airport.islid == island { return true }
            guard let home = here.area, let there = area(airport) else { return false }
            return home.commutes(with: there)
        }
        var serving: (record: AirportRecord, km: Double)?
        for airport in own {
            let distance = CollectionsAggregator.haversineKm(lat1: latitude, lon1: longitude,
                                                             lat2: airport.lat, lon2: airport.lon)
            guard distance <= FlightJudge.servingRadiusKm else { continue }
            if let current = serving,
               distance > current.km || (distance == current.km && airport.code >= current.record.code) {
                continue
            }
            serving = (airport, distance)
        }
        return Reach(serving: serving?.record, candidates: serving == nil ? [] : own,
                     island: island, ground: here)
    }
}

/// Loads the bundled airport database lazily and answers proximity queries.
///
/// Thread-safe (the data is immutable after `load()`). `isNearAirport` and
/// `nearestAirport` use a latitude-sorted index to visit only records inside
/// the query's provably sufficient band.
final class AirportDetector: @unchecked Sendable {

    nonisolated static let shared = AirportDetector()

    nonisolated private let logger = Logger(subsystem: "com.travellog.app", category: "AirportDetector")

    nonisolated(unsafe) private var airportsByLat: [AirportRecord] = []
    nonisolated(unsafe) private var airportsByCode: [String: AirportRecord] = [:]
    nonisolated(unsafe) private var didLoad = false
    nonisolated(unsafe) private var loadAttempts = 0
    nonisolated private let loadLock = NSLock()

    /// Bounded retry for transient read/decode failures (disk pressure
    /// during a mapped read). A missing bundle resource is terminal; latching
    /// a failed read would silently disable airport — and therefore flight —
    /// detection for the whole process lifetime. Bounded so a genuinely
    /// corrupt file can't make every stay creation re-pay a failed decode
    /// forever.
    nonisolated private static let maxLoadAttempts = 3

    nonisolated private init() {}

    /// Idempotent. Safe to call from any thread; first caller pays the cost.
    nonisolated private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !didLoad else { return }
        guard loadAttempts < Self.maxLoadAttempts else { return }
        loadAttempts += 1

        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json") else {
            // Terminal — the bundle's contents won't change mid-process.
            didLoad = true
            logger.error("airports.json not found in bundle — airport detection disabled.")
            return
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let loaded = try JSONDecoder().decode([AirportRecord].self, from: data)
            airportsByLat = loaded.sorted { $0.lat < $1.lat }
            airportsByCode = Dictionary(loaded.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            didLoad = true
            logger.info("Loaded \(self.airportsByLat.count) airports from bundle.")
        } catch {
            // didLoad stays false — the next caller retries (bounded above).
            logger.error("Failed to load airports.json (attempt \(self.loadAttempts)/\(Self.maxLoadAttempts)): \(error.localizedDescription)")
        }
    }

    /// True iff `coordinate` falls within `radiusMeters` of any bundled
    /// airport (by default, inside the airport's own ring, `ringMeters`);
    /// with `scheduledOnly`, of one with scheduled service (`svc` nil counts
    /// as scheduled, as everywhere else).
    nonisolated func isNearAirport(
        _ coordinate: CLLocationCoordinate2D, radiusMeters: Double? = nil, scheduledOnly: Bool = false
    ) -> Bool {
        loadIfNeeded()
        // Copy under the lock: with the bounded retry, a concurrent caller's
        // loadIfNeeded can assign the index while this thread reads it.
        // COW makes the copy cheap.
        loadLock.lock()
        let airports = self.airportsByLat
        loadLock.unlock()
        guard !airports.isEmpty else { return false }
        let band = latitudeBand(
            in: airports, latitude: coordinate.latitude,
            radiusMeters: radiusMeters ?? AirportRecord.maxRingMeters)
        for airport in airports[band] {
            let radius = radiusMeters ?? airport.ringMeters
            // Latitude-band prefilter: d² = dx² + dy² ≥ dy², so
            // a record whose latitude delta alone exceeds the radius can never
            // be in range — provably non-culling, skips the cos() for the
            // vast majority of the table.
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radius else { continue }
            if scheduledOnly, airport.svc == false { continue }
            let d = approxDistanceSquared(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: airport.lat, lon2: airport.lon
            )
            if d <= radius * radius { return true }
        }
        return false
    }

    /// The single closest airport within `radiusMeters` of the coordinate
    /// (by default, of those whose own ring holds it, `ringMeters`), or nil
    /// when none is in range. Ties on distance (impossible in practice for real
    /// airports, cheap to make explicit) break on `code` so two devices
    /// attribute the same stay to the same airport. Powers the Collections
    /// feature's airport attribution ("this stay was at AMS"). With
    /// `scheduledOnly`, the closest with scheduled service (`svc` nil counts
    /// as scheduled).
    nonisolated func nearestAirport(
        _ coordinate: CLLocationCoordinate2D, radiusMeters: Double? = nil, scheduledOnly: Bool = false
    ) -> AirportRecord? {
        loadIfNeeded()
        loadLock.lock()
        let airports = self.airportsByLat
        loadLock.unlock()
        guard !airports.isEmpty else { return nil }
        var best: (record: AirportRecord, distanceSq: Double)?
        let band = latitudeBand(
            in: airports, latitude: coordinate.latitude,
            radiusMeters: radiusMeters ?? AirportRecord.maxRingMeters)
        for airport in airports[band] {
            let radius = radiusMeters ?? airport.ringMeters
            // Same provably non-culling latitude-band prefilter as
            // `isNearAirport`.
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radius else { continue }
            if scheduledOnly, airport.svc == false { continue }
            let d = approxDistanceSquared(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: airport.lat, lon2: airport.lon
            )
            guard d <= radius * radius else { continue }
            if let current = best {
                if d < current.distanceSq
                    || (d == current.distanceSq && airport.code < current.record.code) {
                    best = (airport, d)
                }
            } else {
                best = (airport, d)
            }
        }
        return best?.record
    }

    /// Every bundled airport within `radiusMeters` of the coordinate, in no
    /// set order; with `scheduledOnly`, those with scheduled service. The
    /// candidates `AccessAirport` ranks.
    nonisolated func airports(
        near coordinate: CLLocationCoordinate2D, radiusMeters: Double, scheduledOnly: Bool = false
    ) -> [AirportRecord] {
        loadIfNeeded()
        loadLock.lock()
        let airports = self.airportsByLat
        loadLock.unlock()
        guard !airports.isEmpty else { return [] }
        let radiusSq = radiusMeters * radiusMeters
        var result: [AirportRecord] = []
        for airport in airports[latitudeBand(in: airports, latitude: coordinate.latitude,
                                             radiusMeters: radiusMeters)] {
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radiusMeters else { continue }
            if scheduledOnly, airport.svc == false { continue }
            let d = approxDistanceSquared(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: airport.lat, lon2: airport.lon
            )
            if d <= radiusSq { result.append(airport) }
        }
        return result
    }

    /// The bundled airport with this code, or nil. Powers the stops a user
    /// adds to a flight (`FlightStops`).
    nonisolated func airport(code: String) -> AirportRecord? {
        loadIfNeeded()
        loadLock.lock()
        defer { loadLock.unlock() }
        return airportsByCode[code]
    }

    /// Every bundled airport, in latitude order: the stop search's corpus.
    nonisolated var allAirports: [AirportRecord] {
        loadIfNeeded()
        loadLock.lock()
        defer { loadLock.unlock() }
        return airportsByLat
    }

    /// Total bundled airports. Exposed for diagnostics / Settings.
    nonisolated var airportCount: Int {
        loadIfNeeded()
        // Read under the lock like every other accessor: a concurrent retry
        // in loadIfNeeded can assign `airportsByLat` while this thread reads it.
        loadLock.lock()
        defer { loadLock.unlock() }
        return airportsByLat.count
    }

    /// Indices whose latitude lies inside the same inclusive band used by
    /// the distance prefilter. The lower bound is the first `lat >= min`;
    /// the upper bound is the first `lat > max`.
    nonisolated private func latitudeBand(
        in airports: [AirportRecord],
        latitude: Double,
        radiusMeters: Double
    ) -> Range<Int> {
        guard radiusMeters >= 0, latitude.isFinite else { return 0..<0 }
        let latitudeDelta = radiusMeters / 111_320
        let minimum = latitude - latitudeDelta
        let maximum = latitude + latitudeDelta

        var low = 0
        var high = airports.count
        while low < high {
            let middle = low + (high - low) / 2
            if airports[middle].lat < minimum {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let lowerBound = low

        low = lowerBound
        high = airports.count
        while low < high {
            let middle = low + (high - low) / 2
            if airports[middle].lat <= maximum {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return lowerBound..<low
    }

    /// Equirectangular approximation of squared great-circle distance, in
    /// meters squared. Accurate to <0.5% at airport-proximity scales (3 km)
    /// and ~100× faster than `CLLocation.distance(from:)` because it avoids
    /// trig at call time (we cache cos at the equator and rely on the small-
    /// angle approximation valid up to ±60° latitude).
    @inline(__always)
    nonisolated private func approxDistanceSquared(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let metersPerDegreeLat = 111_320.0
        let avgLatRad = (lat1 + lat2) * 0.5 * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(avgLatRad)
        // Wrapped delta (geometry sweep): raw subtraction made a stay at
        // −179.9° read ~40,000 km from an airport at +179.9°.
        let dx = GeoMath.wrappedLongitudeDelta(lon1, lon2) * metersPerDegreeLon
        let dy = (lat1 - lat2) * metersPerDegreeLat
        return dx * dx + dy * dy
    }
}

extension FlightJudge.Airport {
    nonisolated init(_ record: AirportRecord) {
        self.init(code: record.code, latitude: record.lat, longitude: record.lon,
                  scheduled: record.svc ?? true)
    }
}

extension FlightJudge.Airports {
    /// The bundled dataset: the `Stay.isAirport` ring for `at`; for
    /// `serving`, the nearest scheduled airport within
    /// `FlightJudge.servingRadiusKm` the place may fly from
    /// (`AccessAirport.reach`, as the Flight Log reads it).
    nonisolated static var bundled: FlightJudge.Airports {
        let detector = AirportDetector.shared
        return FlightJudge.Airports(
            at: { latitude, longitude in
                detector.nearestAirport(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    .map(FlightJudge.Airport.init)
            },
            serving: { latitude, longitude in
                let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                return AccessAirport.reach(
                    latitude: latitude, longitude: longitude,
                    nearest: CollectionsAggregator.bundledServingAirport(point),
                    candidates: CollectionsAggregator.bundledAccessAirports(point),
                    ground: { CollectionsAggregator.bundledAirportGround(point) },
                    area: { CollectionsAggregator.bundledAirportGround(
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)).area }
                ).serving.map(FlightJudge.Airport.init)
            })
    }
}
