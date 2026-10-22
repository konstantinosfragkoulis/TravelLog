//
//  GeocodeResolver.swift
//  TravelLog
//
//  Offline reverse geocoder using bundled `Geocoder.sqlite` and R*Tree point-in-polygon lookups.
//  Built by scripts/build-geocoder-db.py; see scripts/REBUILD_GEOCODER.md for the build procedure.
//  Missing optional island/neighborhood tables silently return nil.
//

import Foundation
import CoreLocation
import SQLite3
import SwiftData
import os.log

// SQLite requires this immutable destructor sentinel to copy bound strings.
// nonisolated(unsafe) keeps it accessible from the resolver actor under default-Main isolation.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

/// Async-isolated offline geocoder. Single shared instance, lazy-opened
/// on first resolve. Thread-safe by actor isolation.
/// The SQLite handle stays open for the app's lifetime — singleton. Memory
/// pressure is handled by mmap (the kernel evicts clean pages freely).
/// `cache_size` is intentionally small (a few MB) because mmap covers the
/// rest. `query_only=1` prevents accidental writes.
actor GeocodeResolver {

    static let shared = GeocodeResolver()

    #if DEBUG
    nonisolated enum TestHook {
        @TaskLocal static var resolve: (@Sendable (Double, Double) -> Result?)?
        /// Makes `isAvailable` report a database that failed to open.
        @TaskLocal static var unavailable = false
    }
    #endif

    private static let logger = Logger(subsystem: "com.travellog.app", category: "GeocodeResolver")

    /// Accept only a real ISO-3166-1 alpha-2 code; anything else becomes nil.
    /// Natural Earth uses `-1` for undetermined territories; reject it so city ISO fallback remains available.
    /// Pure and `nonisolated` so it can be pinned without touching the actor.
    nonisolated static func sanitizedISOCountryCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 2,
              trimmed.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return trimmed.uppercased()
    }

    // MARK: - Result

    struct Result: Sendable, Equatable {
        /// Country name (English). "Greece", "United States", "Japan".
        let country: String?
        /// ISO 3166-1 alpha-2. "GR", "US", "JP".
        let isoCountryCode: String?
        /// State / region / prefecture / Bundesland. "Attiki", "California".
        let administrativeArea: String?
        /// Metropolitan area name. "Athens", "Tokyo", "Los Angeles".
        /// Nil for stays outside any tracked metro.
        let metroName: String?
        /// Nearest named populated place: a suburb, town or island settlement.
        /// The "city" the user is in or near.
        let localityName: String?
        /// Specific neighborhood / district. "Karaköy", "Beverly Hills",
        /// "Shibuya". Nil if no notable neighborhood is tagged for this
        /// coord, or if the OSM data has not been loaded yet.
        let subLocalityName: String?
        /// Island name if the coord is on a named island. "Cephalonia",
        /// "Mykonos", "Kauai". Nil for mainland or unloaded OSM data.
        let islandName: String?
        /// The landmass that contains the coordinate but is too large to
        /// be a place (`GeocodeResolver.islandAreaCapKm2`):
        /// "Great Britain" for a Snowdonia hike, "Honshu" for a mountain
        /// hut. Never a display name; it exists so the geocoder backfill
        /// can tell "this coordinate is on a demoted landmass" (clear the
        /// stale `Stay.islandName`) from "no island polygon at all" (keep
        /// whatever the stay already had). Nil whenever `islandName` is
        /// set or nothing contains the coordinate.
        var demotedIslandName: String? = nil

        /// Best available human-facing place name for `Stay.locality` /
        /// `LocationPing.locality` / `HexVisit.locality`. Falls back from
        /// nearest GeoNames city → island name → FUA metro name.
        var bestLocalityName: String? {
            localityName ?? islandName ?? metroName
        }

        /// Reject a locality equal to the country name.
        /// Test `bestLocalityName != nil` first when distinguishing a rejected candidate from no candidate.
        var localityForStorage: String? {
            guard let candidate = bestLocalityName else { return nil }
            if let country, candidate == country { return nil }
            return candidate
        }

        /// Exact-match stale landmass localities for clearing; real town names must remain untouched.
        func isStaleLandmassLocality(_ current: String?) -> Bool {
            guard bestLocalityName == nil, let demotedIslandName, let current else { return false }
            return current == demotedIslandName
        }
    }

    // MARK: - SQLite state

    private var db: OpaquePointer?
    private var didOpen = false
    private var hasNeighborhoodTable = false
    private var hasIslandTable = false

    // Reset and rebind cached statements between calls.
    private var stmtAdmin1: OpaquePointer?
    private var stmtFua: OpaquePointer?
    private var stmtFuaNearby: OpaquePointer?
    private var stmtUrbanCentre: OpaquePointer?
    private var stmtCity: OpaquePointer?
    private var stmtAdmin1Name: OpaquePointer?
    private var stmtIsland: OpaquePointer?
    private var stmtNeighborhood: OpaquePointer?
    private var stmtCityByName: OpaquePointer?
    private var stmtCityHomonyms: OpaquePointer?
    private var stmtAdmin1ByName: OpaquePointer?
    /// Every admin-1 name, case- and diacritic-folded, loaded on first use.
    private var foldedAdmin1Names: Set<String>?
    /// `metroPlaceName(_:iso:latitude:longitude:locality:)`'s placed cores, by ISO and raw metro name.
    private var twoCoreMetroCores: [String: TwoCoreMetroCores] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Open the bundled database. Idempotent. Safe to call from any context.
    /// Returns true on success.
    @discardableResult
    private func openIfNeeded() -> Bool {
        guard !didOpen else { return db != nil }
        // Latch `didOpen` only after success so failures retry; actor isolation serializes opens.

        guard let url = Bundle.main.url(forResource: "Geocoder", withExtension: "sqlite") else {
            Self.logger.error("Geocoder.sqlite not found in bundle.")
            return false
        }

        // Open read-only with URI flag so we can pass `immutable=1`. The
        // immutable flag tells SQLite the file will never change, allowing
        // it to skip stat() rechecks and lock probing on every query.
        var db: OpaquePointer?
        let uri = "file:\(url.path)?immutable=1"
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.logger.error("Failed to open Geocoder.sqlite: \(msg)")
            sqlite3_close_v2(db)
            return false
        }

        self.db = db

        // Cap mmap_size at 256 MB to bound the mapping with headroom for the bundle.
        execPragma("PRAGMA query_only = 1")
        execPragma("PRAGMA mmap_size = 268435456")
        execPragma("PRAGMA cache_size = -2000")  // 2 MB page cache
        execPragma("PRAGMA temp_store = MEMORY")

        // Require R*Tree support at startup so unsupported connections fail before queries.
        if sqlite3_compileoption_used("ENABLE_RTREE") == 0 {
            Self.logger.fault("System SQLite missing SQLITE_ENABLE_RTREE — geocoder disabled.")
            sqlite3_close_v2(db)
            self.db = nil
            return false
        }

        // Missing optional island/neighborhood tables must degrade gracefully.
        hasNeighborhoodTable = tableExists("neighborhood")
        hasIslandTable = tableExists("island")

        prepareStatements()

        // Admin-1 and city statements are required; leave `didOpen` unlatched if preparation fails.
        guard stmtAdmin1 != nil, stmtCity != nil else {
            Self.logger.fault("Geocoder statement preparation failed — bundled DB malformed or schema-drifted. Offline geocoding disabled until a successful reopen.")
            // Finalize prepared statements before closing to avoid leaking them on retry.
            finalizeStatements()
            sqlite3_close_v2(db)
            self.db = nil
            return false
        }

        didOpen = true

        Self.logger.info("""
            Opened Geocoder.sqlite (neighborhoods=\(self.hasNeighborhoodTable, privacy: .public), \
            islands=\(self.hasIslandTable, privacy: .public))
            """)
        return true
    }

    /// Whether the bundled database is open, opening it now if needed. `resolve`
    /// answers nil both for a failed open and for a point no layer covers, so a
    /// one-shot repair checks this before it may latch a pass of nil answers.
    func isAvailable() -> Bool {
        #if DEBUG
        if TestHook.unavailable { return false }
        if TestHook.resolve != nil { return true }
        #endif
        return openIfNeeded()
    }

    /// Fault hot pages in off-main. Called from `AppDelegate` at launch so
    /// the first user-facing resolve doesn't pay the cold-start cost.
    func prewarm() {
        guard openIfNeeded() else { return }
        // Touch each R*Tree's root with a dummy query — forces page-fault.
        _ = pipCandidatesAdmin1(latitude: 0, longitude: 0)
        _ = pipCandidatesFua(latitude: 0, longitude: 0)
        Self.logger.debug("Geocoder prewarm complete.")
    }

    private func execPragma(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func tableExists(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Finalize failed-open statements before retry; successful statements live for the actor lifetime.
    private func finalizeStatements() {
        sqlite3_finalize(stmtAdmin1)
        sqlite3_finalize(stmtFua)
        sqlite3_finalize(stmtFuaNearby)
        sqlite3_finalize(stmtUrbanCentre)
        sqlite3_finalize(stmtCity)
        sqlite3_finalize(stmtAdmin1Name)
        sqlite3_finalize(stmtIsland)
        sqlite3_finalize(stmtNeighborhood)
        sqlite3_finalize(stmtCityByName)
        sqlite3_finalize(stmtCityHomonyms)
        sqlite3_finalize(stmtAdmin1ByName)
        stmtAdmin1 = nil
        stmtFua = nil
        stmtFuaNearby = nil
        stmtUrbanCentre = nil
        stmtCity = nil
        stmtAdmin1Name = nil
        stmtIsland = nil
        stmtNeighborhood = nil
        stmtCityByName = nil
        stmtCityHomonyms = nil
        stmtAdmin1ByName = nil
    }

    private func prepareStatements() {
        // Admin-1 PIP candidates: bbox contains query point.
        // Same parameter is bound to two `?` placeholders by index.
        // Prefer `name_en` over the local name for English-first storage.
        prepare(&stmtAdmin1, sql: """
            SELECT admin1.name, admin1.name_en, admin1.iso_country, admin1.wkb, admin1.id
            FROM admin1_rtree
            JOIN admin1 ON admin1.id = admin1_rtree.id
            WHERE admin1_rtree.min_lat <= ?1 AND admin1_rtree.max_lat >= ?1
              AND admin1_rtree.min_lon <= ?2 AND admin1_rtree.max_lon >= ?2
            ORDER BY admin1.id
            """)

        // FUA PIP candidates.
        prepare(&stmtFua, sql: """
            SELECT fua.name, fua.iso_country, fua.uc_pop_2015, fua.wkb, fua.efua_id
            FROM fua_rtree
            JOIN fua ON fua.efua_id = fua_rtree.efua_id
            WHERE fua_rtree.min_lat <= ?1 AND fua_rtree.max_lat >= ?1
              AND fua_rtree.min_lon <= ?2 AND fua_rtree.max_lon >= ?2
            ORDER BY fua.efua_id
            """)

        // Urban centres define the built-up home region; FUA defines the commuting metro.
        // Order by id so overlapping polygons resolve deterministically.
        prepare(&stmtUrbanCentre, sql: """
            SELECT urban_centre.uc_id, urban_centre.name,
                   urban_centre.area_km2, urban_centre.wkb
            FROM urban_centre_rtree
            JOIN urban_centre ON urban_centre.uc_id = urban_centre_rtree.uc_id
            WHERE urban_centre_rtree.min_lat <= ?1 AND urban_centre_rtree.max_lat >= ?1
              AND urban_centre_rtree.min_lon <= ?2 AND urban_centre_rtree.max_lon >= ?2
            ORDER BY urban_centre.uc_id
            """)

        // FUA gravity candidates within ~55 km; bind latitude-scaled, dateline-split longitude bounds.
        // ?1 = latitude, ?2/?3 = longitude bounds, ?4 = country filter.
        prepare(&stmtFuaNearby, sql: """
            SELECT fua.name, fua.uc_pop_2015,
                   (fua_rtree.min_lat + fua_rtree.max_lat) * 0.5 AS cy,
                   (fua_rtree.min_lon + fua_rtree.max_lon) * 0.5 AS cx
            FROM fua_rtree
            JOIN fua ON fua.efua_id = fua_rtree.efua_id
            WHERE fua_rtree.min_lat <= ?1 + 0.5 AND fua_rtree.max_lat >= ?1 - 0.5
              AND fua_rtree.min_lon <= ?3 AND fua_rtree.max_lon >= ?2
              AND fua.iso_country = ?4
            """)

        // Nearest-city candidates within ~5 km; Swift ranks them by distance.
        // Scale longitude by 1/cos(lat) and split at ±180° because R*Tree ranges cannot wrap.
        prepare(&stmtCity, sql: """
            SELECT city.name, city.iso_country, city.lat, city.lon, city.population, city.admin1_code
            FROM city_rtree
            JOIN city ON city.geoname_id = city_rtree.geoname_id
            WHERE city_rtree.min_lat BETWEEN ?1 - 0.05 AND ?1 + 0.05
              AND city_rtree.min_lon BETWEEN ?2 AND ?3
            """)

        // Admin-1 name lookup by (iso_country, admin1_code). Used when an
        // admin polygon PIP misses but a city's admin1_code is known.
        prepare(&stmtAdmin1Name, sql: """
            SELECT name FROM admin1_name WHERE iso_country = ?1 AND admin1_code = ?2
            """)

        // Indexed `name_lc` uses Python str.lower with diacritics preserved.
        // Probe plain-lowercased and diacritic-folded input; ASCII-only misses use the network tier.
        // Most-populous homonym wins, optionally within one country.
        prepare(&stmtCityByName, sql: """
            SELECT name, iso_country, lat, lon, population
            FROM city
            WHERE name_lc IN (?1, ?2) AND (?3 IS NULL OR iso_country = ?3)
            ORDER BY population DESC, name, geoname_id
            LIMIT 1
            """)

        // Every same-named city with its admin-1 name, most populous first,
        // so a caller can honor place qualifiers ("London, Canada",
        // "Atlanta, Georgia") in the same text.
        prepare(&stmtCityHomonyms, sql: """
            SELECT city.name, city.iso_country, city.lat, city.lon, admin1_name.name
            FROM city
            LEFT JOIN admin1_name ON admin1_name.iso_country = city.iso_country
              AND admin1_name.admin1_code = city.admin1_code
            WHERE city.name_lc IN (?1, ?2)
            ORDER BY city.population DESC, city.name, city.geoname_id
            """)

        // Every first-level subdivision name ("Maine", "Ontario"), spelled as
        // `cityHomonyms` reports admin-1 names; `isAdmin1Name` folds them.
        prepare(&stmtAdmin1ByName, sql: """
            SELECT name FROM admin1_name
            """)

        // Island statements are optional; prefer `name_en`, then transliterate the local name.
        if hasIslandTable {
            prepare(&stmtIsland, sql: """
                SELECT island.osm_id, island.name, island.name_en, island.wkb
                FROM island_rtree
                JOIN island ON island.osm_id = island_rtree.osm_id
                WHERE island_rtree.min_lat <= ?1 AND island_rtree.max_lat >= ?1
                  AND island_rtree.min_lon <= ?2 AND island_rtree.max_lon >= ?2
                ORDER BY island.osm_id
                """)
        }

        // Optional neighborhoods prefer `name_en`, then transliterate the local name.
        // Use window overlap for mixed point/polygon rows so wide polygons match from any edge.
        // Rank by representative-point distance.
        if hasNeighborhoodTable {
            // Bind polar-scaled, dateline-split longitude bounds as for stmtCity (?2 min, ?3 max).
            prepare(&stmtNeighborhood, sql: """
                SELECT neighborhood.name, neighborhood.name_en, neighborhood.lat, neighborhood.lon
                FROM neighborhood_rtree
                JOIN neighborhood ON neighborhood.osm_id = neighborhood_rtree.osm_id
                WHERE neighborhood_rtree.min_lat <= ?1 + 0.01 AND neighborhood_rtree.max_lat >= ?1 - 0.01
                  AND neighborhood_rtree.min_lon <= ?3 AND neighborhood_rtree.max_lon >= ?2
                """)
        }
    }

    private func prepare(_ stmt: inout OpaquePointer?, sql: String) {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            Self.logger.fault("Statement prep failed (\(rc)): \(msg)\nSQL: \(sql)")
        }
    }

    // MARK: - Forward city-name lookup

    struct ForwardCityHit: Sendable, Equatable {
        let name: String
        let isoCountryCode: String
        let latitude: Double
        let longitude: Double
    }

    /// Indexed offline city lookup; misses under both name forms fall through to the caller’s network tier.
    func resolveCityName(_ raw: String, isoCountryCode: String? = nil) -> ForwardCityHit? {
        guard openIfNeeded(), let stmt = stmtCityByName else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

        let plain = trimmed.lowercased()
        let folded = trimmed
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, plain, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, folded, -1, SQLITE_TRANSIENT)
        if let isoCountryCode { sqlite3_bind_text(stmt, 3, isoCountryCode, -1, SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let namePtr = sqlite3_column_text(stmt, 0),
              let isoPtr = sqlite3_column_text(stmt, 1) else { return nil }
        return ForwardCityHit(
            name: Self.primaryPlaceName(String(cString: namePtr)),
            isoCountryCode: String(cString: isoPtr),
            latitude: sqlite3_column_double(stmt, 2),
            longitude: sqlite3_column_double(stmt, 3)
        )
    }

    nonisolated struct ForwardCityHomonym: Sendable, Equatable {
        let hit: ForwardCityHit
        /// The city's admin-1 name ("Georgia", "Ontario"), when known.
        let admin1Name: String?
    }

    /// Whether `raw`, whole, is the name of some first-level subdivision
    /// ("Maine", "Ontario"). False when the database is unavailable.
    /// Case and diacritics are ignored, so "Québec" matches the stored "Quebec".
    func isAdmin1Name(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        if foldedAdmin1Names == nil {
            guard openIfNeeded(), let stmt = stmtAdmin1ByName else { return false }
            sqlite3_reset(stmt)
            defer { sqlite3_reset(stmt) }
            var names = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
                names.insert(Self.foldedAdmin1Name(String(cString: namePtr)))
            }
            guard !names.isEmpty else { return false }
            foldedAdmin1Names = names
        }
        return foldedAdmin1Names?.contains(Self.foldedAdmin1Name(trimmed)) == true
    }

    private nonisolated static func foldedAdmin1Name(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Every city with this name (same name forms as `resolveCityName`),
    /// most populous first. Empty on a miss or when the database is unavailable.
    func cityHomonyms(named raw: String) -> [ForwardCityHomonym] {
        guard openIfNeeded(), let stmt = stmtCityHomonyms else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return [] }

        let plain = trimmed.lowercased()
        let folded = trimmed
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, plain, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, folded, -1, SQLITE_TRANSIENT)
        var homonyms: [ForwardCityHomonym] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0),
                  let isoPtr = sqlite3_column_text(stmt, 1) else { continue }
            homonyms.append(ForwardCityHomonym(
                hit: ForwardCityHit(
                    name: Self.primaryPlaceName(String(cString: namePtr)),
                    isoCountryCode: String(cString: isoPtr),
                    latitude: sqlite3_column_double(stmt, 2),
                    longitude: sqlite3_column_double(stmt, 3)
                ),
                admin1Name: placeNameColumn(stmt, 4)
            ))
        }
        return homonyms
    }

    // MARK: - Public API

    /// Resolve a coordinate into a `Result`. Returns nil when the database
    /// failed to open OR the coord is in the middle of the ocean (no
    /// country polygon, no city, no FUA — extremely rare).
    func resolve(latitude: Double, longitude: Double) -> Result? {
        #if DEBUG
        if let resolve = TestHook.resolve { return resolve(latitude, longitude) }
        #endif
        guard openIfNeeded() else { return nil }

        // Microstates without admin-1 subdivisions rely on the city ISO fallback.
        var adminName: String? = nil
        var adminIso: String? = nil
        for cand in pipCandidatesAdmin1(latitude: latitude, longitude: longitude) {
            if let poly = cand.cached ?? polygon(.init(layer: .admin1, id: cand.id), wkb: cand.wkb),
               poly.contains(lon: longitude, lat: latitude) {
                adminName = cand.displayName
                // Reject placeholder ISO values before they can outrank the nearest city’s valid code.
                adminIso = Self.sanitizedISOCountryCode(cand.iso)
                break
            }
        }

        // 2. Metro: FUA polygon PIP first; gravity-on-FUA-centres fallback.
        var metroName: String? = nil
        var metroIso: String? = nil
        for cand in pipCandidatesFua(latitude: latitude, longitude: longitude) {
            if let poly = cand.cached ?? polygon(.init(layer: .fua, id: cand.id), wkb: cand.wkb),
               poly.contains(lon: longitude, lat: latitude) {
                metroName = cand.name
                metroIso = cand.iso
                break
            }
        }

        // 3. City (locality). Nearest within 5 km box.
        let cityHit = nearestCity(latitude: latitude, longitude: longitude)

        // A two-core metro is named by the core the stay is in.
        metroName = metroName.map {
            metroPlaceName($0, iso: metroIso, latitude: latitude, longitude: longitude, locality: cityHit?.name)
        }

        // 4. Determine effective ISO for downstream lookups.
        let effectiveIso = adminIso ?? cityHit?.iso ?? metroIso

        // 5. Gravity fallback for a nearby metro when polygon PIP missed.
        // A locality near Athens can lie outside its FUA polygon.
        if metroName == nil, let iso = effectiveIso {
            if let best = bestFuaByGravity(latitude: latitude, longitude: longitude, iso: iso) {
                metroName = metroPlaceName(
                    best.name, iso: iso, latitude: latitude, longitude: longitude, locality: cityHit?.name)
            }
        }

        // 6. Sub-admin via city's admin1_code (when admin polygon PIP missed).
        if adminName == nil, let city = cityHit, !city.adminCode.isEmpty {
            adminName = adminNameLookup(iso: city.iso, code: city.adminCode)
        }

        // If the centroid misses every island polygon, use the nearest town’s island.
        // Port centroids can lie seaward; mainland towns must keep mainland ports off nearby islands.
        // The town fallback runs only when the centroid is in NO polygon:
        // a centroid on a demoted landmass must not adopt a small island
        // across the water just because its nearest town is there (a Kyle
        // of Lochalsh stay is not on Skye).
        var hits = islandHits(latitude: latitude, longitude: longitude)
        if hits.isEmpty, let city = cityHit {
            hits = islandHits(latitude: city.latitude, longitude: city.longitude)
        }
        let islandName = hits.first(where: { $0.areaKm2 < Self.islandAreaCapKm2 })?.name
        let demotedIslandName = islandName == nil ? hits.last?.name : nil

        // 8. Neighborhood nearest-within-1km.
        var subLocality: String? = nil
        if hasNeighborhoodTable {
            subLocality = nearestNeighborhood(latitude: latitude, longitude: longitude)
        }

        // Compose. If everything came back nil this isn't a useful result.
        // A demoted landmass alone still is: the backfill needs it to clear
        // a stale island or locality name.
        if adminName == nil && metroName == nil
            && cityHit == nil && islandName == nil && subLocality == nil
            && demotedIslandName == nil {
            return nil
        }

        // Store country names in English so searches remain independent of the device locale.
        var countryName: String? = nil
        if let iso = effectiveIso {
            let locale = Locale(identifier: "en_US")
            countryName = locale.localizedString(forRegionCode: iso)
        }

        // Normalize every returned name to ASCII so UI, search, and AI consumers share one script.
        return Result(
            country: countryName?.toLatinAscii,
            isoCountryCode: effectiveIso,
            administrativeArea: adminName?.toLatinAscii,
            metroName: metroName?.toLatinAscii,
            localityName: cityHit?.name.toLatinAscii,
            subLocalityName: subLocality?.toLatinAscii,
            islandName: islandName?.toLatinAscii,
            demotedIslandName: demotedIslandName?.toLatinAscii
        )
    }

    /// Opt-in MapKit fallback when offline geocoding supplies a country but no usable locality.
    /// Pure-offline callers must continue using `resolve(...)`.
    /// MapKitLocalityCache limits requests to 30 per 60 seconds; exhausted budgets return the offline result.
    /// A nil offline result stays nil. `cacheGeneration` pins the MapKit cache generation
    /// the caller checked its wipe authority under.
    func resolveWithFallback(
        latitude: Double, longitude: Double, allowRateLimitWait: Bool = true,
        cacheGeneration: UInt64? = nil
    ) async -> Result? {
        let offline = resolve(latitude: latitude, longitude: longitude)
        return await MapKitLocalityCache.shared.enrich(
            offline: offline, latitude: latitude, longitude: longitude,
            allowRateLimitWait: allowRateLimitWait, generation: cacheGeneration
        )
    }

    // MARK: - Layer queries

    private struct Admin1Candidate {
        let id: Int64
        let name: String
        let nameEn: String?
        let iso: String?
        /// Empty when `cached` holds the parsed polygon.
        let wkb: Data
        let cached: WKBPolygon?
        /// English-first display: prefers `name_en` when populated.
        var displayName: String { nameEn?.isEmpty == false ? nameEn! : name }
    }

    private func pipCandidatesAdmin1(latitude: Double, longitude: Double) -> [Admin1Candidate] {
        guard let stmt = stmtAdmin1 else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_double(stmt, 1, latitude)
        sqlite3_bind_double(stmt, 2, longitude)
        var results: [Admin1Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = placeNameColumn(stmt, 0) ?? ""
            let nameEn = placeNameColumn(stmt, 1)
            let iso = stringColumn(stmt, 2)
            let id = sqlite3_column_int64(stmt, 4)
            let cached = polygonCache[PolygonKey(layer: .admin1, id: id)]
            let wkb = cached == nil ? blobColumn(stmt, 3) : Data()
            results.append(Admin1Candidate(id: id, name: name, nameEn: nameEn, iso: iso,
                                           wkb: wkb, cached: cached))
        }
        return results
    }

    private struct FuaCandidate {
        let id: Int64
        let name: String
        let iso: String
        /// Empty when `cached` holds the parsed polygon.
        let wkb: Data
        let cached: WKBPolygon?
    }

    /// One GHS urban centre containing a point: the polygon plus the source's
    /// own `area_km2`. The area is the ATTRIBUTE, never the polygon's computed
    /// area — it is measured on the 1 km grid the geometry is derived from, and
    /// `D*` depends on it.
    struct UrbanCentreHit: Sendable, Equatable {
        let id: Int64
        /// nil for the 14 source centres that carry no name. A nameless centre
        /// is still a perfectly good home shape.
        let name: String?
        let areaKm2: Double
        let rings: [[[CLLocationDegrees]]]
    }

    /// The urban centre whose polygon contains this point, if any.
    ///
    /// Returns the FIRST containing polygon in `uc_id` order. Overlap is not
    /// expected in the source (urban centres are disjoint by construction), so
    /// this is a determinism guard rather than a tie-break with semantics.
    func urbanCentre(latitude: Double, longitude: Double) -> UrbanCentreHit? {
        // Every public entry point must open first because prepared statements do not exist until then.
        guard openIfNeeded(), let stmt = stmtUrbanCentre else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_double(stmt, 1, latitude)
        sqlite3_bind_double(stmt, 2, longitude)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let name = placeNameColumn(stmt, 1)
            let areaKm2 = sqlite3_column_double(stmt, 2)
            let key = PolygonKey(layer: .urbanCentre, id: id)
            guard let polygon = polygonCache[key] ?? self.polygon(key, wkb: blobColumn(stmt, 3)),
                  polygon.contains(lon: longitude, lat: latitude) else { continue }
            return UrbanCentreHit(id: id, name: name, areaKm2: areaKm2,
                                  rings: polygon.rings)
        }
        return nil
    }

    private func pipCandidatesFua(latitude: Double, longitude: Double) -> [FuaCandidate] {
        guard let stmt = stmtFua else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_double(stmt, 1, latitude)
        sqlite3_bind_double(stmt, 2, longitude)
        var results: [FuaCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = stringColumn(stmt, 0) ?? ""
            let iso = stringColumn(stmt, 1) ?? ""
            let id = sqlite3_column_int64(stmt, 4)
            let cached = polygonCache[PolygonKey(layer: .fua, id: id)]
            let wkb = cached == nil ? blobColumn(stmt, 3) : Data()
            results.append(FuaCandidate(id: id, name: name, iso: iso, wkb: wkb, cached: cached))
        }
        return results
    }

    /// Gravity score = pop / (distance_km + 5)². Returns highest-scoring
    /// FUA within ~55 km of the point in the same country, if any. nil
    /// when there's no FUA nearby. Used as the fallback when a coord
    /// missed all FUA polygons but is near a metro, such as a suburb near Athens.
    private func bestFuaByGravity(latitude: Double, longitude: Double, iso: String) -> (name: String, score: Double)? {
        guard let stmt = stmtFuaNearby else { return nil }
        defer { sqlite3_reset(stmt) }

        var best: (name: String, score: Double)? = nil
        let queryPt = CLLocation(latitude: latitude, longitude: longitude)
        // Query each segment of the latitude-scaled, dateline-split window before the 50 km distance filter.
        let halfWidth = GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.5, atLatitude: latitude)
        for segment in GeoMath.longitudeSegments(center: longitude, halfWidth: halfWidth) {
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, latitude)
            sqlite3_bind_double(stmt, 2, segment.min)
            sqlite3_bind_double(stmt, 3, segment.max)
            sqlite3_bind_text(stmt, 4, iso, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = stringColumn(stmt, 0) ?? ""
                let pop = Int(sqlite3_column_int64(stmt, 1))
                let cy = sqlite3_column_double(stmt, 2)
                let cx = sqlite3_column_double(stmt, 3)
                let distKm = queryPt.distance(from: CLLocation(latitude: cy, longitude: cx)) / 1000.0
                // Skip FUAs > 50 km away even if their bbox overlapped the query
                // box (large FUAs in adjacent regions can have huge bboxes).
                guard distKm <= 50, pop > 0 else { continue }
                let score = Double(pop) / pow(distKm + 5.0, 2.0)
                if best == nil || score > best!.score {
                    best = (name: name, score: score)
                }
            }
        }

        // Require pop/(d+5)² > 100 to avoid pulling in a tiny FUA.
        guard let result = best, result.score >= 100 else { return nil }
        return result
    }

    private struct CityHit {
        let name: String
        let iso: String
        let adminCode: String
        /// The GeoNames point itself — the island fallback in `resolve`
        /// asks which island the TOWN sits on when the stay centroid misses
        /// every island polygon.
        let latitude: Double
        let longitude: Double
    }

    /// Nearest city within ~5 km. Returns nil if none.
    private func nearestCity(latitude: Double, longitude: Double) -> CityHit? {
        guard let stmt = stmtCity else { return nil }
        defer { sqlite3_reset(stmt) }

        // Query each segment of the latitude-scaled window so polar and dateline candidates remain reachable.
        let halfWidth = GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.05, atLatitude: latitude)
        var best: (hit: CityHit, distSq: Double)? = nil
        for segment in GeoMath.longitudeSegments(center: longitude, halfWidth: halfWidth) {
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, latitude)
            sqlite3_bind_double(stmt, 2, segment.min)
            sqlite3_bind_double(stmt, 3, segment.max)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = placeNameColumn(stmt, 0) ?? ""
                let iso = stringColumn(stmt, 1) ?? ""
                let cyLat = sqlite3_column_double(stmt, 2)
                let cyLon = sqlite3_column_double(stmt, 3)
                // admin1_code recovers administrativeArea when admin-1 PIP misses.
                let adminCode = stringColumn(stmt, 5) ?? ""
                let dy = cyLat - latitude
                // Scale longitude by cos(latitude) for distance ranking; wrap the delta so ±180° stay adjacent.
                let dx = GeoMath.wrappedLongitudeDelta(cyLon, longitude) * cos(latitude * .pi / 180)
                let dSq = dy * dy + dx * dx
                let hit = CityHit(name: name, iso: iso, adminCode: adminCode,
                                  latitude: cyLat, longitude: cyLon)
                if best == nil || dSq < best!.distSq {
                    best = (hit: hit, distSq: dSq)
                }
            }
        }
        return best?.hit
    }

    private func adminNameLookup(iso: String, code: String) -> String? {
        guard let stmt = stmtAdmin1Name else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, code, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return placeNameColumn(stmt, 0)
        }
        return nil
    }

    private struct IslandCandidate {
        let osmID: Int64
        let name: String
        let nameEn: String?
        /// Empty when `cached` holds the parsed polygon.
        let wkb: Data
        let cached: WKBPolygon?
        /// Prefer `name_en`; otherwise use the local-script OSM name.
        var displayName: String { nameEn?.isEmpty == false ? nameEn! : name }
    }

    private func pipCandidatesIsland(latitude: Double, longitude: Double) -> [IslandCandidate] {
        guard let stmt = stmtIsland else { return [] }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_double(stmt, 1, latitude)
        sqlite3_bind_double(stmt, 2, longitude)
        var results: [IslandCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let osmID = sqlite3_column_int64(stmt, 0)
            let name = stringColumn(stmt, 1) ?? ""
            let nameEn = stringColumn(stmt, 2)
            let cached = polygonCache[PolygonKey(layer: .island, id: osmID)]
            let wkb = cached == nil ? blobColumn(stmt, 3) : Data()
            results.append(IslandCandidate(osmID: osmID, name: name, nameEn: nameEn,
                                           wkb: wkb, cached: cached))
        }
        return results
    }

    /// An island polygon that contains a coordinate, with its size.
    struct IslandHit: Sendable, Equatable {
        let name: String
        let areaKm2: Double
    }

    /// Islands above the cap are landmasses, never display places.
    /// Keeps Sicily (25,700 km²) and smaller islands; demotes Vancouver Island (31,300 km²) and larger.
    /// Measure the shipped polygon with `WKBPolygon.areaKm2`, cached per OSM id for the actor lifetime.
    static let islandAreaCapKm2: Double = 30_000

    private var islandAreaCache: [Int64: Double] = [:]

    /// Every island polygon containing the coordinate, largest first, or
    /// empty when none does. The caller applies `islandAreaCapKm2`: the
    /// largest hit under the cap is the island (Poros town sits on the
    /// islet Sphaeria inside the Poros polygon, and the stay is a Poros
    /// stay), and when every hit is over it the smallest landmass is
    /// reported as `Result.demotedIslandName`. Internal as a test seam
    /// (`GeocodeResolverIslandCapTests`).
    func islandHits(latitude: Double, longitude: Double) -> [IslandHit] {
        guard openIfNeeded(), hasIslandTable else { return [] }
        var hits: [IslandHit] = []
        for cand in pipCandidatesIsland(latitude: latitude, longitude: longitude) {
            guard let poly = cand.cached ?? polygon(.init(layer: .island, id: cand.osmID), wkb: cand.wkb),
                  poly.contains(lon: longitude, lat: latitude) else { continue }
            let area: Double
            if let cached = islandAreaCache[cand.osmID] {
                area = cached
            } else {
                area = poly.areaKm2
                islandAreaCache[cand.osmID] = area
            }
            hits.append(IslandHit(name: cand.displayName, areaKm2: area))
        }
        return hits.sorted { $0.areaKm2 > $1.areaKm2 }
    }

    // MARK: - Parsed polygon cache

    /// Ids overlap across tables, so the layer is part of the key.
    private enum PolygonLayer { case admin1, fua, island, urbanCentre }

    private struct PolygonKey: Hashable {
        let layer: PolygonLayer
        let id: Int64
    }

    /// Parsed admin-1, FUA, island and urban-centre polygons. The bundled database is
    /// immutable, so entries never go stale; the cache is cleared whole when
    /// the vertex budget would be exceeded.
    private var polygonCache: [PolygonKey: WKBPolygon] = [:]
    private var polygonCacheVertices = 0

    /// About 1.6 MB of coordinates. London's working set is about 12k
    /// vertices; the largest single row about 19k.
    static let polygonCacheVertexBudget = 100_000

    /// Cached polygon for `key`, else decode `wkb` and cache it. A blob that
    /// fails to decode is not cached.
    private func polygon(_ key: PolygonKey, wkb: Data) -> WKBPolygon? {
        if let cached = polygonCache[key] { return cached }
        guard let parsed = WKBPolygon(data: wkb) else { return nil }
        var vertices = 0
        for poly in parsed.rings {
            for ring in poly { vertices += ring.count / 2 }
        }
        if polygonCacheVertices + vertices > Self.polygonCacheVertexBudget {
            polygonCache.removeAll(keepingCapacity: true)
            polygonCacheVertices = 0
        }
        polygonCache[key] = parsed
        polygonCacheVertices += vertices
        return parsed
    }

    #if DEBUG
    func clearPolygonCacheForTesting() {
        polygonCache.removeAll()
        polygonCacheVertices = 0
    }

    func polygonCacheVertexCountForTesting() -> Int { polygonCacheVertices }
    #endif

    private func nearestNeighborhood(latitude: Double, longitude: Double) -> String? {
        guard let stmt = stmtNeighborhood else { return nil }
        defer { sqlite3_reset(stmt) }

        // Use the latitude-scaled, dateline-split window as in `nearestCity`.
        let halfWidth = GeoMath.longitudeWindowHalfWidth(equatorDegrees: 0.01, atLatitude: latitude)
        var best: (name: String, distSq: Double)? = nil
        for segment in GeoMath.longitudeSegments(center: longitude, halfWidth: halfWidth) {
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, latitude)
            sqlite3_bind_double(stmt, 2, segment.min)
            sqlite3_bind_double(stmt, 3, segment.max)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = stringColumn(stmt, 0) ?? ""
                let nameEn = stringColumn(stmt, 1)
                // Prefer `name_en`, falling back to the local-script name.
                let displayName = (nameEn?.isEmpty == false ? nameEn! : name)
                let nLat = sqlite3_column_double(stmt, 2)
                let nLon = sqlite3_column_double(stmt, 3)
                let dy = nLat - latitude
                // Scale by cos(latitude) and wrap the longitude delta as in `nearestCity`.
                let dx = GeoMath.wrappedLongitudeDelta(nLon, longitude) * cos(latitude * .pi / 180)
                let dSq = dy * dy + dx * dx
                if best == nil || dSq < best!.distSq {
                    best = (name: displayName, distSq: dSq)
                }
            }
        }
        return best?.name
    }

    // MARK: - SQLite column helpers

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    /// A place-name column in its primary form (`primaryPlaceName`).
    private func placeNameColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        stringColumn(stmt, index).map(Self.primaryPlaceName)
    }

    /// The name a place is shown and titled by, without the source's
    /// trailing bracketed qualifier. GHS-FUA and GHS-UCDB name a two-core
    /// area by its main city with the second core in brackets
    /// ("Osaka [Kyoto]"), GeoNames appends a settlement kind
    /// ("[Fraccionamiento]") and Natural Earth an admin level
    /// ("[prefecture]"). The name before the bracket
    /// is the place itself; a name that is nothing but a bracket is kept.
    nonisolated static func primaryPlaceName(_ raw: String) -> String {
        bracketParts(raw)?.primary ?? raw
    }

    /// A metro's name for a point, its two cores placed by the city table
    /// (`metroPlaceName(_:latitude:longitude:cores:locality:)`), memoized per
    /// metro since a backfill names thousands of stays in a handful of metros.
    private func metroPlaceName(
        _ raw: String, iso: String?, latitude: Double, longitude: Double, locality: String?
    ) -> String {
        guard let parts = Self.bracketParts(raw) else { return raw }
        let key = "\(iso ?? "")|\(raw)"
        let cores: TwoCoreMetroCores
        if let cached = twoCoreMetroCores[key] {
            cores = cached
        } else {
            let primary = resolveCityName(parts.primary, isoCountryCode: iso)
            let qualifier = resolveCityName(parts.qualifier, isoCountryCode: iso)
            cores = TwoCoreMetroCores(
                primary: primary.map { (latitude: $0.latitude, longitude: $0.longitude) },
                qualifier: qualifier.map { (latitude: $0.latitude, longitude: $0.longitude) })
            twoCoreMetroCores[key] = cores
        }
        return Self.metroPlaceName(
            raw, latitude: latitude, longitude: longitude, cores: cores, locality: locality)
    }

    /// Where a two-core metro's main and bracketed cities lie; nil for a
    /// core the city table does not hold.
    nonisolated struct TwoCoreMetroCores: Sendable {
        let primary: (latitude: Double, longitude: Double)?
        let qualifier: (latitude: Double, longitude: Double)?
    }

    /// A metro's name for a point. A two-core area ("Osaka [Kyoto]") is named
    /// by the core city nearer the point: a district of the bracketed city is
    /// in that city whatever its own locality is called (Kamigyo-ku, nearest
    /// Kyoto, is not in Osaka). When a core cannot be placed, the bracketed
    /// core names a stay whose locality is that core, otherwise the main city.
    nonisolated static func metroPlaceName(
        _ raw: String, latitude: Double, longitude: Double,
        cores: TwoCoreMetroCores, locality: String?
    ) -> String {
        guard let parts = bracketParts(raw) else { return raw }
        if let primary = cores.primary, let qualifier = cores.qualifier {
            // Same cos-latitude-scaled ranking as `nearestCity`; wraps at ±180°.
            func distanceSquared(_ core: (latitude: Double, longitude: Double)) -> Double {
                let dy = core.latitude - latitude
                let dx = GeoMath.wrappedLongitudeDelta(core.longitude, longitude) * cos(latitude * .pi / 180)
                return dy * dy + dx * dx
            }
            return distanceSquared(qualifier) < distanceSquared(primary) ? parts.qualifier : parts.primary
        }
        if let locality, locality.compare(
            parts.qualifier, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return parts.qualifier
        }
        return parts.primary
    }

    /// "Name [Qualifier]" split in two; nil for a name without a trailing
    /// bracket or with nothing before it.
    nonisolated private static func bracketParts(_ raw: String) -> (primary: String, qualifier: String)? {
        guard raw.hasSuffix("]"), let open = raw.range(of: " [", options: .backwards) else { return nil }
        let primary = raw[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        let qualifier = raw[open.upperBound...].dropLast().trimmingCharacters(in: .whitespaces)
        guard !primary.isEmpty else { return nil }
        return (primary, qualifier)
    }

    private func blobColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        let size = Int(sqlite3_column_bytes(stmt, index))
        guard size > 0, let bytes = sqlite3_column_blob(stmt, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: size)
    }
}

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

// MARK: - String → Latin/ASCII normalisation

extension String {

    /// Force the string through ICU's Latin transliteration and then strip
    /// diacritics. Output is Latin script with diacritics stripped, not
    /// ASCII: letters such as ø, æ, ł, đ, þ, ı survive (use
    /// `toLatinAsciiStrict` when every scalar must be printable ASCII).
    /// Returns the input unchanged when ICU can't transliterate (extremely
    /// rare for real place names). Both transforms are the identity on
    /// plain ASCII, which returns unchanged without reaching ICU; each
    /// transform call builds a new ICU transliterator, so other strings are
    /// memoized.
    ///
    /// Used by `GeocodeResolver` to guarantee every consumer (UI labels,
    /// search index, AI prompt context) sees a single consistent script.
    ///
    /// Explicit `nonisolated` because the `actor GeocodeResolver`
    /// declaration earlier in this file causes Swift 6 to infer
    /// `@MainActor` on subsequent extensions — which would block the
    /// actor's resolve() (running on its own executor) from calling it.
    nonisolated var toLatinAscii: String {
        if utf8.allSatisfy({ $0 < 0x80 }) { return self }
        // Exact bytes, not String equality (canonical equivalence): two
        // equivalent spellings need not transliterate alike.
        let key = Array(utf8)
        if let memoized = Self.nonASCIILatin.withLock({ $0[key] }) { return memoized }
        let latin = self.applyingTransform(.toLatin, reverse: false)
        let stripped = (latin ?? self).applyingTransform(.stripDiacritics, reverse: false)
        let ascii = stripped ?? latin ?? self
        // A failed transform is retried next call, as before the memo.
        // Bounded like `TripTitleStore.normalizedPlaceName`'s memo.
        if latin != nil, stripped != nil, key.count <= 256 {
            Self.nonASCIILatin.withLock { memo in
                if memo.count < 2_048 { memo[key] = ascii }
            }
        }
        return ascii
    }

    nonisolated private static let nonASCIILatin = OSAllocatedUnfairLock(
        initialState: [[UInt8]: String]())

    /// Prompt-only hardening for text that must stay inside Foundation
    /// Models' canonical Latin control channel, and the one normalization
    /// title validation applies to both a title and its place names. ICU
    /// `Any-Latin; Latin-ASCII` transliterates first, so Latin letters with
    /// no decomposition become ASCII instead of disappearing (Tromsø is
    /// Tromso, Wrocław Wroclaw, Gießen Giessen, and ’ is '); any scalar it
    /// still cannot reduce to printable ASCII is dropped, and whitespace
    /// runs become one ordinary space. The transform is the identity on
    /// ASCII, so ASCII input skips it.
    nonisolated var toLatinAsciiStrict: String {
        var result = String.UnicodeScalarView()
        var previousWasWhitespace = false
        let ascii = utf8.allSatisfy({ $0 < 0x80 })
            ? self : applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? toLatinAscii

        for scalar in ascii.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                    previousWasWhitespace = true
                }
                continue
            }

            guard scalar.value >= 0x21, scalar.value <= 0x7E else { continue }
            result.append(scalar)
            previousWasWhitespace = false
        }

        return String(result)
    }
}

// MARK: - LocationPing Integration

/// **Lives here, not in `Models/LocationPing.swift`,** because
/// `LocationPing` is shared with the `TravelLogWidgetsExtension`
/// target. The widget does not bundle `Geocoder.sqlite` and does not
/// link `GeocodeResolver` — keeping the resolver-typed extension in
/// `Services/` (main-app-only) keeps the widget's compile graph clean.
/// `nil` resolver result clears `isGeocoded`. The existing place-name
/// fields are NOT overwritten in that case (legacy data preserved).
extension LocationPing {
    /// Writes only the fields whose value changes (`setIfChanged`) and
    /// reports whether any did, so re-resolving an unchanged ping leaves
    /// the row clean.
    @discardableResult
    func applyResolverResult(_ r: GeocodeResolver.Result?) -> Bool {
        guard let r = r else {
            return setIfChanged(\.isGeocoded, false)
        }
        var changed = false
        // Never store the country as locality: a rejected candidate clears stale country-as-locality,
        // while no candidate preserves the existing value (`Result.localityForStorage`).
        if r.bestLocalityName != nil {
            changed = setIfChanged(\.locality, r.localityForStorage) || changed
        } else if r.isStaleLandmassLocality(self.locality) {
            // Clear a locality matching the demoted landmass; it must not survive the coalesce below.
            changed = setIfChanged(\.locality, nil) || changed
        }
        // Coalesce missing country fields: an island-only match must not erase existing country data.
        changed = setIfChanged(\.subLocality, r.subLocalityName ?? self.subLocality) || changed
        changed = setIfChanged(\.administrativeArea, r.administrativeArea ?? self.administrativeArea) || changed
        changed = setIfChanged(\.country, r.country ?? self.country) || changed
        changed = setIfChanged(\.isoCountryCode, r.isoCountryCode ?? self.isoCountryCode) || changed
        changed = setIfChanged(\.isGeocoded, self.locality != nil || self.country != nil) || changed
        return changed
    }
}

extension PersistentModel {
    /// Writes `value` only when it differs from the stored one. SwiftData
    /// records even a same-value write as a change, which saves the row and
    /// exports it to CloudKit again; re-resolving passes compare first.
    @discardableResult
    nonisolated func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>, _ value: Value
    ) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }
}
