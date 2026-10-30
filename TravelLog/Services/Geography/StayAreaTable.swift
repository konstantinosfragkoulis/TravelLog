//
//  StayAreaTable.swift
//  TravelLog
//

import Foundation
import SQLite3
import os.log

/// What the bundled geocoder (`Geocoder.sqlite`) knows of a stay's areas
/// beyond the names it stored, for trip search only
/// (`TripSearchDocument.make(from:)`):
/// - `region`: the GeoNames first-level division (state, region,
///   prefecture) of the GeoNames city nearest the stay, by that city's
///   `admin1_code` in `admin1_name`. A stay stores the Natural Earth
///   admin-1 polygon's name, which in Spain, France and Italy is a
///   province or department ("Seville", "Alpes-Maritimes"), so the region
///   people name ("Andalusia", "Provence-Alpes-Côte d'Azur") is otherwise
///   unknown. The city is the nearest of the stay's country within about
///   5 km, else within about 25 km (any country only for a stay without
///   one): a region across a border is not the stay's (Gibraltar is not
///   in Andalusia). None when the
///   stored area already is a GeoNames region of the country (a stay
///   storing "California" by Stateline, Nevada): only a province or
///   department-level area lacks its region. The city must lie in the
///   admin-1 polygon the stay lies in, the one `GeocodeResolver` stored
///   the area from: the nearest that does within those radii, else none
///   (a stay in Alicante province by the Castile-La Mancha border takes
///   Valencia's region, never the nearer town's). Never by name: the
///   city table keys names with their diacritics while stays store them
///   without, so a name probe sees only some homonyms (a stay named after
///   nine accented villages would read the one unaccented one).
/// - `cityGeonameID`: that city, which keys the island group it lies in
///   (`PlaceNameTable.Layer.group`), so a town named like one in an
///   archipelago (three Greek Plakas) never takes its group.
/// - `subLocalityName`: the stay's neighbourhood under its own name
///   (OpenStreetMap `name`) where the stay stores its English or Latin
///   form ("Shibuya 1" is 渋谷一丁目; 下目黒六丁目, which has no English
///   name, is stored transliterated), found as `GeocodeResolver` found
///   it: the nearest neighbourhood within about 1 km, when the resolver
///   would store it as the stay's sub-locality.
///
/// `prepare()` reads the region names once (about 4k rows), so it runs
/// off-main: the search index build calls it. Until then lookups answer
/// nothing without touching the database; `isPrepared` is part of the
/// search index key (with `IslandAreaTable`'s), so documents built before
/// it are rebuilt off-main once it is ready. After it, a stay's areas are
/// read through the rtrees and memoized (bounded). Offline, read-only and
/// thread-safe.
nonisolated final class StayAreaTable: @unchecked Sendable {

    static let shared = StayAreaTable(url: Bundle.main.url(forResource: "Geocoder", withExtension: "sqlite"))

    private static let logger = Logger(subsystem: "com.travellog.app", category: "StayAreaTable")

    /// Most stays memoized before the memo starts over.
    static let memoLimit = 4096

    /// Most parsed admin-1 polygons kept before the cache starts over.
    static let polygonLimit = 64

    /// A stay's areas; nil where the geocoder knows nothing more.
    nonisolated struct Areas: Sendable, Equatable {
        /// The GeoNames region's name, as `admin1_name` spells it.
        var region: String?
        /// The GeoNames id of the city the region was read from.
        var cityGeonameID: Int64?
        /// The neighbourhood's own name when it differs from the stored one.
        var subLocalityName: String?

        init(region: String? = nil, cityGeonameID: Int64? = nil, subLocalityName: String? = nil) {
            self.region = region
            self.cityGeonameID = cityGeonameID
            self.subLocalityName = subLocalityName
        }
    }

    private let url: URL?
    /// Guards the connection, its statements and the tables below; never
    /// held while `prepare()` reads the names.
    private let lock = NSLock()
    /// Serializes `prepare()` calls.
    private let prepareLock = NSLock()
    private var db: OpaquePointer?
    private var nearbyCities: OpaquePointer?
    private var nearbyNeighborhoods: OpaquePointer?
    private var admin1Polygons: OpaquePointer?
    /// Parsed admin-1 polygons by id (bounded, like `memo`).
    private var polygons: [Int64: WKBPolygon] = [:]
    private var didPrepare = false
    /// Region names by "ISO|admin1 code".
    private var regions: [String: String] = [:]
    /// Folded region names (`TripTitleStore.normalizedPlaceName`) by "ISO|name".
    private var regionKeys: Set<String> = []
    private var memo: [String: Areas] = [:]

    init(url: URL?) {
        self.url = url
    }

    deinit {
        sqlite3_finalize(nearbyCities)
        sqlite3_finalize(nearbyNeighborhoods)
        sqlite3_finalize(admin1Polygons)
        sqlite3_close_v2(db)
    }

    /// Whether `prepare()` has run (successfully or not): lookups answer
    /// from the database from then on.
    var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didPrepare
    }

    /// Reads the region names once and prepares the lookups. Off-main.
    func prepare() {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        guard !isPrepared else { return }
        var connection: OpaquePointer?
        var names: [String: String] = [:]
        var statements: [OpaquePointer?] = [nil, nil, nil]
        if let url,
           sqlite3_open_v2("file:\(url.path)?immutable=1", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            == SQLITE_OK {
            var rows: OpaquePointer?
            if sqlite3_prepare_v2(connection, "SELECT iso_country, admin1_code, name FROM admin1_name", -1, &rows, nil)
                == SQLITE_OK {
                while sqlite3_step(rows) == SQLITE_ROW {
                    guard let iso = sqlite3_column_text(rows, 0), let code = sqlite3_column_text(rows, 1),
                          let name = sqlite3_column_text(rows, 2) else { continue }
                    names[String(cString: iso) + "|" + String(cString: code)] = String(cString: name)
                }
            }
            sqlite3_finalize(rows)
            let sql = [
                // Cities in a box: ?1 latitude, ?2/?3 longitude bounds, ?4 half height.
                """
                SELECT city.iso_country, city.admin1_code, city.lat, city.lon, city.geoname_id
                FROM city_rtree JOIN city ON city.geoname_id = city_rtree.geoname_id
                WHERE city_rtree.min_lat BETWEEN ?1 - ?4 AND ?1 + ?4
                  AND city_rtree.min_lon BETWEEN ?2 AND ?3
                """,
                // `GeocodeResolver`'s neighbourhood window (optional table).
                """
                SELECT neighborhood.name, neighborhood.name_en, neighborhood.lat, neighborhood.lon
                FROM neighborhood_rtree JOIN neighborhood ON neighborhood.osm_id = neighborhood_rtree.osm_id
                WHERE neighborhood_rtree.min_lat <= ?1 + 0.01 AND neighborhood_rtree.max_lat >= ?1 - 0.01
                  AND neighborhood_rtree.min_lon <= ?3 AND neighborhood_rtree.max_lon >= ?2
                """,
                // `GeocodeResolver`'s admin-1 candidates: ?1 latitude, ?2 longitude.
                """
                SELECT admin1.id, admin1.wkb FROM admin1_rtree JOIN admin1 ON admin1.id = admin1_rtree.id
                WHERE admin1_rtree.min_lat <= ?1 AND admin1_rtree.max_lat >= ?1
                  AND admin1_rtree.min_lon <= ?2 AND admin1_rtree.max_lon >= ?2
                ORDER BY admin1.id
                """,
            ]
            for (offset, text) in sql.enumerated()
            where sqlite3_prepare_v2(connection, text, -1, &statements[offset], nil) != SQLITE_OK {
                statements[offset] = nil
            }
        } else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Geocoder.sqlite not found in bundle"
            Self.logger.error("Failed to open Geocoder.sqlite areas: \(message, privacy: .public)")
            sqlite3_close_v2(connection)
            connection = nil
        }
        lock.lock()
        db = connection
        nearbyCities = statements[0]
        nearbyNeighborhoods = statements[1]
        admin1Polygons = statements[2]
        polygons = [:]
        regions = names
        regionKeys = Set(names.map { key, name in
            String(key.prefix { $0 != "|" }) + "|" + TripTitleStore.normalizedPlaceName(name)
        })
        memo = [:]
        didPrepare = true
        lock.unlock()
    }

    /// The areas of a stay at `latitude`, `longitude` that stores
    /// `isoCountryCode`, `administrativeArea` and `subLocality`; empty
    /// before `prepare()` or when the geocoder knows nothing more.
    func areas(
        latitude: Double, longitude: Double, isoCountryCode: String?, administrativeArea: String? = nil,
        subLocality: String?
    ) -> Areas {
        let iso = TripTitleStore.homeCountryCode(isoCountryCode)
        let key = [String(format: "%.4f|%.4f", latitude, longitude), iso ?? "", administrativeArea ?? "",
                   subLocality ?? ""].joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        guard didPrepare else { return Areas() }
        if let cached = memo[key] { return cached }
        var areas = Areas()
        let close = citiesNear(latitude: latitude, longitude: longitude, iso: iso, radius: 0.05)
        var wide = close.isEmpty && iso != nil
            ? citiesNear(latitude: latitude, longitude: longitude, iso: iso, radius: 0.25) : nil
        if let city = close.first ?? wide?.first {
            areas.cityGeonameID = city.id
            let storedIsRegion = administrativeArea.map {
                regionKeys.contains((iso ?? city.iso) + "|" + TripTitleStore.normalizedPlaceName($0))
            } ?? false
            if !storedIsRegion, let polygon = admin1Polygon(latitude: latitude, longitude: longitude) {
                let inside = { (city: City) in polygon.contains(lon: city.longitude, lat: city.latitude) }
                var match = close.first(where: inside)
                if match == nil, iso != nil {
                    if wide == nil {
                        wide = citiesNear(latitude: latitude, longitude: longitude, iso: iso, radius: 0.25)
                    }
                    match = wide?.first(where: inside)
                }
                areas.region = match.flatMap { regions[$0.iso + "|" + $0.code] }
            }
        }
        if let subLocality, let native = neighborhoodName(latitude: latitude, longitude: longitude, stored: subLocality),
           Self.folded(native) != Self.folded(subLocality) {
            areas.subLocalityName = native
        }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[key] = areas
        return areas
    }

    /// Forgets every memoized stay (Delete All Data: the memo is keyed by
    /// the stays' coordinates).
    func removeAll() {
        lock.lock()
        memo.removeAll()
        lock.unlock()
    }

    /// A city with an admin-1 code near a stay.
    private nonisolated struct City {
        let iso: String
        let code: String
        let id: Int64
        let latitude: Double
        let longitude: Double
    }

    /// The cities with an admin-1 code within `radius` degrees of latitude
    /// (and the same ground distance of longitude), in `iso` when there is
    /// one, nearest first. Under `lock`.
    private func citiesNear(latitude: Double, longitude: Double, iso: String?, radius: Double) -> [City] {
        guard let statement = nearbyCities else { return [] }
        let scale = cos(latitude * .pi / 180)
        var found: [(city: City, distance: Double)] = []
        for segment in Self.longitudeSegments(center: longitude, halfWidth: scale > 0.01 ? min(radius / scale, 180) : 180) {
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, segment.min)
            sqlite3_bind_double(statement, 3, segment.max)
            sqlite3_bind_double(statement, 4, radius)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cityISO = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                      let code = sqlite3_column_text(statement, 1).map({ String(cString: $0) }), !code.isEmpty,
                      iso.map({ $0 == cityISO }) ?? true else { continue }
                let cityLatitude = sqlite3_column_double(statement, 2)
                let cityLongitude = sqlite3_column_double(statement, 3)
                let dy = cityLatitude - latitude
                var dx = cityLongitude - longitude
                if dx > 180 { dx -= 360 } else if dx < -180 { dx += 360 }
                let city = City(iso: cityISO, code: code, id: sqlite3_column_int64(statement, 4),
                                latitude: cityLatitude, longitude: cityLongitude)
                found.append((city, dy * dy + dx * dx * scale * scale))
            }
        }
        sqlite3_reset(statement)
        // Stable: of equally near cities the first read wins, as before.
        return found.enumerated().sorted { ($0.element.distance, $0.offset) < ($1.element.distance, $1.offset) }
            .map(\.element.city)
    }

    /// The first admin-1 polygon containing the point, as
    /// `GeocodeResolver` resolves a stay's administrative area. Under `lock`.
    private func admin1Polygon(latitude: Double, longitude: Double) -> WKBPolygon? {
        guard let statement = admin1Polygons else { return nil }
        defer { sqlite3_reset(statement) }
        sqlite3_reset(statement)
        sqlite3_bind_double(statement, 1, latitude)
        sqlite3_bind_double(statement, 2, longitude)
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            var polygon = polygons[id]
            if polygon == nil {
                let size = Int(sqlite3_column_bytes(statement, 1))
                guard size > 0, let bytes = sqlite3_column_blob(statement, 1),
                      let parsed = WKBPolygon(data: Data(bytes: bytes, count: size)) else { continue }
                if polygons.count >= Self.polygonLimit { polygons.removeAll(keepingCapacity: true) }
                polygons[id] = parsed
                polygon = parsed
            }
            if let polygon, polygon.contains(lon: longitude, lat: latitude) { return polygon }
        }
        return nil
    }

    /// The own name of the neighbourhood nearest the point when the
    /// resolver stores its display name (English, else its own) as
    /// `stored`: transliterated to Latin without diacritics
    /// (`toLatinAscii`). Under `lock`.
    private func neighborhoodName(latitude: Double, longitude: Double, stored: String) -> String? {
        guard let statement = nearbyNeighborhoods else { return nil }
        let scale = cos(latitude * .pi / 180)
        var best: (name: String, display: String, distance: Double)?
        for segment in Self.longitudeSegments(center: longitude, halfWidth: scale > 0.01 ? min(0.01 / scale, 180) : 180) {
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, segment.min)
            sqlite3_bind_double(statement, 3, segment.max)
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let english = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let dy = sqlite3_column_double(statement, 2) - latitude
                var dx = sqlite3_column_double(statement, 3) - longitude
                if dx > 180 { dx -= 360 } else if dx < -180 { dx += 360 }
                let distance = dy * dy + dx * dx * scale * scale
                if best.map({ distance < $0.distance }) ?? true {
                    best = (name, english.isEmpty ? name : english, distance)
                }
            }
        }
        sqlite3_reset(statement)
        guard let best, !best.name.isEmpty,
              Self.folded(Self.latinASCII(best.display)) == Self.folded(stored)
        else { return nil }
        return best.name
    }

    /// `String.toLatinAscii`, the resolver's normalization of every name it
    /// stores: Any-Latin, then without diacritics.
    static func latinASCII(_ name: String) -> String {
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return name }
        let latin = name.applyingTransform(.toLatin, reverse: false)
        return (latin ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? latin ?? name
    }

    /// Case-, diacritic- and whitespace-folded: a native name that folds to
    /// the stored one adds nothing ("Gràcia" for "Gracia").
    private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `GeoMath.longitudeSegments`: the wrapped interval as one or two
    /// in-range segments.
    private static func longitudeSegments(center: Double, halfWidth: Double) -> [(min: Double, max: Double)] {
        guard halfWidth < 180 else { return [(-180, 180)] }
        let lo = center - halfWidth
        let hi = center + halfWidth
        if lo < -180 { return [(-180, hi), (lo + 360, 180)] }
        if hi > 180 { return [(lo, 180), (-180, hi - 360)] }
        return [(lo, hi)]
    }
}
