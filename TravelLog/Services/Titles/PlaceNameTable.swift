//
//  PlaceNameTable.swift
//  TravelLog
//

import Foundation
import SQLite3
import os.log

// SQLite's copy-the-string destructor sentinel, as in GeocodeResolver.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

/// The bundled place-name table (`PlaceNames.sqlite`, built from GeoNames
/// by `scripts/build-place-names.py`): what a place is called in an app
/// language, looked up by its stored name, its country and its layer (a
/// city or an island). Offline and read-only. Nil means the table has no other name for the place, so a
/// title keeps the canonical spelling. Trip search also reads every
/// language's name (`TripSearchPlaceNames`). App only: the widget reads the
/// localized titles the app stored.
nonisolated final class PlaceNameTable: @unchecked Sendable {

    static let shared = PlaceNameTable(
        url: Bundle.main.url(forResource: "PlaceNames", withExtension: "sqlite"))

    private static let logger = Logger(subsystem: "com.travellog.app", category: "PlaceNameTable")

    private let url: URL?
    /// Guards the connection and its one statement; opened on first lookup.
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var statement: OpaquePointer?
    private var didOpen = false

    init(url: URL?) {
        self.url = url
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close_v2(db)
    }

    /// The table's two kinds of row (its `place.layer` column).
    enum Layer: String, Sendable {
        /// A GeoNames city, keyed by its stored name, an English alias or
        /// the metro named after it.
        case city
        /// A GeoNames island, keyed by the stored name of the geocoder
        /// island it lies on.
        case island
    }

    /// A title place's name in `languageTag`: an island-named place from
    /// the table's island rows, any other (metro, locality, region) from its
    /// city rows. An island never takes a town's name ("Ibiza-Stadt" for the
    /// island of Ibiza), and one the table has no row for keeps its
    /// canonical spelling.
    func name(for place: TripTitlePolicy.TitlePlace, languageTag: String) -> String? {
        name(for: place.name, isoCountryCode: place.isoCountryCode, languageTag: languageTag,
             layer: place.layer == .island ? .island : .city)
    }

    /// `name` (a stored metro, locality or region name, or with `.island`
    /// an island's) in `languageTag`, for the place of that name in
    /// `isoCountryCode` and `layer`.
    func name(
        for name: String, isoCountryCode: String?, languageTag rawTag: String, layer: Layer = .city
    ) -> String? {
        guard let languageTag = AppLanguagePreference.normalizedSupportedTag(rawTag),
              let iso = TripTitleStore.homeCountryCode(isoCountryCode) else { return nil }
        let sources = Self.storedLanguages(for: languageTag)
        guard !sources.isEmpty else { return nil }
        let names = lookup(key: TripTitleStore.normalizedPlaceName(name), iso: iso, layer: layer)
        guard let source = sources.first(where: { names[$0] != nil }),
              let found = names[source] else { return nil }
        switch (languageTag, source) {
        // GeoNames files some Traditional names as plain Chinese.
        case ("zh-Hans", _): return found.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? found
        case ("zh-Hant", "zh-Hans"): return found.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
        default: return found
        }
    }

    /// Every stored name of the place `name` in `isoCountryCode` and
    /// `layer` (a city, or with `.island` an island), by table language, as
    /// stored (no script conversion); empty when the table has none or the
    /// code is not a country. Search indexes all of them
    /// (`TripSearchPlaceNames`).
    func names(for name: String, isoCountryCode: String?, layer: Layer = .city) -> [String: String] {
        guard let iso = TripTitleStore.homeCountryCode(isoCountryCode) else { return [:] }
        return lookup(key: TripTitleStore.normalizedPlaceName(name), iso: iso, layer: layer)
    }

    /// The table's languages an app language reads, most specific first.
    /// English titles are the canonical ones.
    static func storedLanguages(for languageTag: String) -> [String] {
        switch languageTag {
        case "en": []
        case "pt-BR": ["pt-BR", "pt"]
        case "pt-PT": ["pt"]
        case "zh-Hant": ["zh-Hant", "zh-Hans"]
        default: [languageTag]
        }
    }

    /// Every stored name of the place keyed `key` in `iso` and `layer`, by language.
    private func lookup(key: String, iso: String, layer: Layer) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded(), let statement else { return [:] }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, iso, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, layer.rawValue, -1, SQLITE_TRANSIENT)
        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let language = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1) else { continue }
            names[String(cString: language)] = String(cString: name)
        }
        sqlite3_reset(statement)
        return names
    }

    private func openIfNeeded() -> Bool {
        guard !didOpen else { return statement != nil }
        didOpen = true
        guard let url else {
            Self.logger.error("PlaceNames.sqlite not found in bundle.")
            return false
        }
        let uri = "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, """
                SELECT name.language, name.name
                FROM place JOIN name ON name.geoname_id = place.geoname_id
                WHERE place.name_key = ?1 AND place.iso_country = ?2 AND place.layer = ?3
                """, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            Self.logger.error("Failed to open PlaceNames.sqlite: \(message, privacy: .public)")
            sqlite3_finalize(statement)
            statement = nil
            sqlite3_close_v2(db)
            db = nil
            return false
        }
        return true
    }
}
