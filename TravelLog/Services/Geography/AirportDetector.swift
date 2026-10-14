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
//  city, iso, svc} — `svc` is the scheduled-service flag the Collections dwell
//  rules gate on. Rebuilding with only large/medium airports REGRESSES flight
//  detection. The JSON is bundled at design time; no network, no API calls, no
//  rate limits.
//
//  Used by:
//    - `StayClusterer` — sets `Stay.isAirport = true` at stay-creation time
//      when the centroid is within ~3 km of an airport.
//    - `AppDelegate.runAirportBackfillIfNeeded()` — re-stamps the flag on
//      existing stays once per bundled airport dataset version.
//    - `TripClassifier` (heuristic + Foundation Models prompt) — strong
//      transit signal for sub-24h airport stays.
//    - `TripTitleSchema` generator — flags airport-area stays so the AI
//      title doesn't include airport-area localities such as "Jamaica" (JFK).
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
/// `name` / `city` / `iso` are Optional so a stale or hand-trimmed JSON
/// (the pre-Collections slice carried only code+lat+lon) still decodes.
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
            didLoad = true
            logger.info("Loaded \(self.airportsByLat.count) airports from bundle.")
        } catch {
            // didLoad stays false — the next caller retries (bounded above).
            logger.error("Failed to load airports.json (attempt \(self.loadAttempts)/\(Self.maxLoadAttempts)): \(error.localizedDescription)")
        }
    }

    /// True iff `coordinate` falls within `radiusMeters` (default 3 km) of
    /// any bundled airport.
    nonisolated func isNearAirport(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double = 3000) -> Bool {
        loadIfNeeded()
        // Copy under the lock: with the bounded retry, a concurrent caller's
        // loadIfNeeded can assign the index while this thread reads it.
        // COW makes the copy cheap.
        loadLock.lock()
        let airports = self.airportsByLat
        loadLock.unlock()
        guard !airports.isEmpty else { return false }
        let radiusSq = radiusMeters * radiusMeters
        let band = latitudeBand(
            in: airports, latitude: coordinate.latitude,
            radiusMeters: radiusMeters)
        for airport in airports[band] {
            // Latitude-band prefilter: d² = dx² + dy² ≥ dy², so
            // a record whose latitude delta alone exceeds the radius can never
            // be in range — provably non-culling, skips the cos() for the
            // vast majority of the table.
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radiusMeters else { continue }
            let d = approxDistanceSquared(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: airport.lat, lon2: airport.lon
            )
            if d <= radiusSq { return true }
        }
        return false
    }

    /// The single closest airport within `radiusMeters` of the coordinate,
    /// or nil when none is in range. Ties on distance (impossible in practice for real
    /// airports, cheap to make explicit) break on `code` so two devices
    /// attribute the same stay to the same airport. Powers the Collections
    /// feature's airport attribution ("this stay was at AMS").
    nonisolated func nearestAirport(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double = 3000) -> AirportRecord? {
        loadIfNeeded()
        loadLock.lock()
        let airports = self.airportsByLat
        loadLock.unlock()
        guard !airports.isEmpty else { return nil }
        let radiusSq = radiusMeters * radiusMeters
        var best: (record: AirportRecord, distanceSq: Double)?
        let band = latitudeBand(
            in: airports, latitude: coordinate.latitude,
            radiusMeters: radiusMeters)
        for airport in airports[band] {
            // Same provably non-culling latitude-band prefilter as
            // `isNearAirport`.
            guard abs(airport.lat - coordinate.latitude) * 111_320 <= radiusMeters else { continue }
            let d = approxDistanceSquared(
                lat1: coordinate.latitude, lon1: coordinate.longitude,
                lat2: airport.lat, lon2: airport.lon
            )
            guard d <= radiusSq else { continue }
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
