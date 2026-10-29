//
//  AirportGround.swift
//  TravelLog
//

import Foundation
import CoreLocation
import SQLite3
import os.log

/// A GHS functional urban area (a commuting zone, `Geocoder.sqlite` `fua`)
/// as airport reach reads it: its id, name, country and bounding box.
nonisolated struct CommutingArea: Sendable, Equatable {
    let id: Int64
    let name: String
    let iso: String
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    /// Whether people commute by land between this area and `other`: the
    /// same area, or the other country's part of one cross-border metro.
    /// GHS-FUA splits such a metro per country under one name (Singapore
    /// and Johor Bahru are both "Singapore"), so that part carries the same
    /// name and another country, and its box touches or overlaps this one.
    func commutes(with other: CommutingArea) -> Bool {
        if id == other.id { return true }
        return name == other.name && iso != other.iso
            && minLatitude <= other.maxLatitude && other.minLatitude <= maxLatitude
            && minLongitude <= other.maxLongitude && other.minLongitude <= maxLongitude
    }
}

/// Where a point stands, for the airports it reaches by land
/// (`AccessAirport.reach`).
nonisolated struct AirportGround: Sendable, Equatable {
    /// The OSM id of the island the point stands on, found as
    /// `GeocodeResolver` finds `Stay.islandName` (the largest island polygon
    /// under the size cap holding the point; when no island polygon holds
    /// it, the one holding its nearest town), the id `AirportRecord.islid`
    /// carries. nil on a mainland or a landmass above the cap.
    var island: Int64?
    /// The commuting area holding the point.
    var area: CommutingArea?

    init(island: Int64? = nil, area: CommutingArea? = nil) {
        self.island = island
        self.area = area
    }
}

/// The island and commuting area under a point, from the bundled
/// geocoder's polygons (`Geocoder.sqlite` `island` and `fua`, through their
/// R-trees). Its own read-only connection opens on first use, and every
/// lookup runs under one lock, so it is thread-safe; the callers (the
/// Collections aggregate, the flight judge in `TransitInferer`) run off the
/// main thread. Answers are memoized per point and parsed polygons kept
/// within a vertex budget; a database that fails to open answers no island
/// and no area, so every airport stays eligible.
nonisolated final class AirportGroundTable: @unchecked Sendable {

    static let shared = AirportGroundTable(url: Bundle.main.url(forResource: "Geocoder", withExtension: "sqlite"))

    private static let logger = Logger(subsystem: "com.travellog.app", category: "AirportGroundTable")

    /// Islands above this are landmasses (`GeocodeResolver.islandAreaCapKm2`).
    static let islandAreaCapKm2: Double = 30_000
    /// Parsed polygons kept, in vertices (about 3 MB); cleared whole past it.
    static let polygonCacheVertexBudget = 200_000
    /// Points answered and kept; cleared whole past it.
    static let memoLimit = 50_000

    private enum Layer { case island, area }

    private struct PolygonKey: Hashable {
        let layer: Layer
        let id: Int64
    }

    private struct PointKey: Hashable {
        let latitude: Double
        let longitude: Double
    }

    private struct IslandHit {
        let id: Int64
        let areaKm2: Double
    }

    private let url: URL?
    /// Guards everything below.
    private let lock = NSLock()
    private var didOpen = false
    private var db: OpaquePointer?
    private var islandStatement: OpaquePointer?
    private var areaStatement: OpaquePointer?
    private var townStatement: OpaquePointer?
    private var islandAreas: [Int64: Double] = [:]
    private var polygons: [PolygonKey: WKBPolygon] = [:]
    private var polygonVertices = 0
    private var memo: [PointKey: AirportGround] = [:]

    init(url: URL?) {
        self.url = url
    }

    deinit {
        sqlite3_finalize(islandStatement)
        sqlite3_finalize(areaStatement)
        sqlite3_finalize(townStatement)
        sqlite3_close_v2(db)
    }

    /// The island and commuting area at a point.
    func ground(latitude: Double, longitude: Double) -> AirportGround {
        guard latitude.isFinite, longitude.isFinite else { return AirportGround() }
        let key = PointKey(latitude: latitude, longitude: longitude)
        lock.lock()
        defer { lock.unlock() }
        if let cached = memo[key] { return cached }
        guard openIfNeeded() else { return AirportGround() }
        // As `GeocodeResolver.resolve`: a point in no island polygon (a
        // waterfront the simplified outline leaves offshore) takes its
        // nearest town's island; one on a landmass above the cap keeps none.
        var hits = islandHits(latitude: latitude, longitude: longitude)
        if hits.isEmpty, let town = nearestTown(latitude: latitude, longitude: longitude) {
            hits = islandHits(latitude: town.latitude, longitude: town.longitude)
        }
        var island: IslandHit?
        for hit in hits where hit.areaKm2 < Self.islandAreaCapKm2 {
            if let current = island, hit.areaKm2 <= current.areaKm2 { continue }
            island = hit
        }
        let result = AirportGround(island: island?.id, area: area(latitude: latitude, longitude: longitude))
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[key] = result
        return result
    }

    // MARK: - Database

    /// Opens the database once; a failed open stays failed.
    private func openIfNeeded() -> Bool {
        if didOpen { return db != nil }
        didOpen = true
        var connection: OpaquePointer?
        guard let url,
              sqlite3_open_v2("file:\(url.path)?immutable=1", &connection,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Geocoder.sqlite not found in bundle"
            Self.logger.error("Failed to open Geocoder.sqlite for airport reach: \(message, privacy: .public)")
            sqlite3_close_v2(connection)
            return false
        }
        db = connection
        islandStatement = prepare("""
            SELECT island.osm_id, island.wkb
            FROM island_rtree
            JOIN island ON island.osm_id = island_rtree.osm_id
            WHERE island_rtree.min_lat <= ?1 AND island_rtree.max_lat >= ?1
              AND island_rtree.min_lon <= ?2 AND island_rtree.max_lon >= ?2
            ORDER BY island.osm_id
            """)
        areaStatement = prepare("""
            SELECT fua.efua_id, fua.name, fua.iso_country, fua.wkb,
                   fua_rtree.min_lat, fua_rtree.max_lat, fua_rtree.min_lon, fua_rtree.max_lon
            FROM fua_rtree
            JOIN fua ON fua.efua_id = fua_rtree.efua_id
            WHERE fua_rtree.min_lat <= ?1 AND fua_rtree.max_lat >= ?1
              AND fua_rtree.min_lon <= ?2 AND fua_rtree.max_lon >= ?2
            ORDER BY fua.efua_id
            """)
        // `GeocodeResolver.nearestCity`'s window: about 5 km.
        townStatement = prepare("""
            SELECT city.lat, city.lon
            FROM city_rtree
            JOIN city ON city.geoname_id = city_rtree.geoname_id
            WHERE city_rtree.min_lat BETWEEN ?1 - 0.05 AND ?1 + 0.05
              AND city_rtree.min_lon BETWEEN ?2 AND ?3
            """)
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            Self.logger.error("Airport reach statement failed: \(message, privacy: .public)")
            sqlite3_finalize(statement)
            return nil
        }
        return statement
    }

    /// Every island polygon holding the point, any size.
    private func islandHits(latitude: Double, longitude: Double) -> [IslandHit] {
        guard let statement = islandStatement else { return [] }
        sqlite3_reset(statement)
        defer { sqlite3_reset(statement) }
        sqlite3_bind_double(statement, 1, latitude)
        sqlite3_bind_double(statement, 2, longitude)
        var hits: [IslandHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let key = PolygonKey(layer: .island, id: id)
            if let cached = polygons[key] {
                guard cached.contains(lon: longitude, lat: latitude) else { continue }
                hits.append(IslandHit(id: id, areaKm2: islandAreas[id] ?? cached.areaKm2))
                continue
            }
            guard let parsed = WKBPolygon(data: blob(statement, 1)) else { continue }
            let area = islandAreas[id] ?? parsed.areaKm2
            islandAreas[id] = area
            cache(parsed, key)
            guard parsed.contains(lon: longitude, lat: latitude) else { continue }
            hits.append(IslandHit(id: id, areaKm2: area))
        }
        return hits
    }

    /// The first commuting area (by id) holding the point.
    private func area(latitude: Double, longitude: Double) -> CommutingArea? {
        guard let statement = areaStatement else { return nil }
        sqlite3_reset(statement)
        defer { sqlite3_reset(statement) }
        sqlite3_bind_double(statement, 1, latitude)
        sqlite3_bind_double(statement, 2, longitude)
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let key = PolygonKey(layer: .area, id: id)
            let polygon: WKBPolygon
            if let cached = polygons[key] {
                polygon = cached
            } else {
                guard let parsed = WKBPolygon(data: blob(statement, 3)) else { continue }
                cache(parsed, key)
                polygon = parsed
            }
            guard polygon.contains(lon: longitude, lat: latitude) else { continue }
            return CommutingArea(
                id: id,
                name: text(statement, 1) ?? "",
                iso: text(statement, 2) ?? "",
                minLatitude: sqlite3_column_double(statement, 4),
                maxLatitude: sqlite3_column_double(statement, 5),
                minLongitude: sqlite3_column_double(statement, 6),
                maxLongitude: sqlite3_column_double(statement, 7))
        }
        return nil
    }

    /// The nearest GeoNames town within about 5 km, as
    /// `GeocodeResolver.nearestCity` ranks them.
    private func nearestTown(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double)? {
        guard let statement = townStatement else { return nil }
        defer { sqlite3_reset(statement) }
        let halfWidth = GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.05, atLatitude: latitude)
        var best: (latitude: Double, longitude: Double, distanceSquared: Double)?
        for segment in GeoMath.longitudeSegments(center: longitude, halfWidth: halfWidth) {
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, segment.min)
            sqlite3_bind_double(statement, 3, segment.max)
            while sqlite3_step(statement) == SQLITE_ROW {
                let townLatitude = sqlite3_column_double(statement, 0)
                let townLongitude = sqlite3_column_double(statement, 1)
                let dy = townLatitude - latitude
                let dx = GeoMath.wrappedLongitudeDelta(townLongitude, longitude) * cos(latitude * .pi / 180)
                let distanceSquared = dy * dy + dx * dx
                if let current = best, distanceSquared >= current.distanceSquared { continue }
                best = (townLatitude, townLongitude, distanceSquared)
            }
        }
        return best.map { (latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func cache(_ polygon: WKBPolygon, _ key: PolygonKey) {
        var vertices = 0
        for rings in polygon.rings {
            for ring in rings { vertices += ring.count / 2 }
        }
        if polygonVertices + vertices > Self.polygonCacheVertexBudget {
            polygons.removeAll(keepingCapacity: true)
            polygonVertices = 0
        }
        polygons[key] = polygon
        polygonVertices += vertices
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
