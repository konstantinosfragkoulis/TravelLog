//
//  IslandAreaTable.swift
//  TravelLog
//

import Foundation
import SQLite3
import os.log

/// Island sizes from the bundled geocoder's island polygons
/// (`Geocoder.sqlite`, the layer `GeocodeResolver` names islands from), by
/// the name a stay stores: the island's English name, else its local name,
/// as `toLatinAscii` stored it. Trip search reads them to tell an island
/// trip from a city on a small island (`TripSearchDocument.make(from:)`).
///
/// `prepare()` reads every island's name once (about 30k rows, and 8k
/// non-ASCII names transliterated), so it runs off-main: the search index
/// build calls it. Until then `areaKm2(named:)` answers nil (unknown) without
/// touching the database; `isPrepared` is part of the search index key, so
/// documents built before it are rebuilt off-main once it is ready. After
/// it, a name's lookup reads its polygons by primary key and is memoized.
/// Offline, read-only and thread-safe.
nonisolated final class IslandAreaTable: @unchecked Sendable {

    static let shared = IslandAreaTable(url: Bundle.main.url(forResource: "Geocoder", withExtension: "sqlite"))

    private static let logger = Logger(subsystem: "com.travellog.app", category: "IslandAreaTable")

    private let url: URL?
    /// Guards the connection, its statement and the tables below; never
    /// held while `prepare()` reads the names.
    private let lock = NSLock()
    /// Serializes `prepare()` calls.
    private let prepareLock = NSLock()
    private var db: OpaquePointer?
    private var byID: OpaquePointer?
    private var didPrepare = false
    /// Island ids by stored name: the display name, and for a non-ASCII one
    /// also its `toLatinAscii` form.
    private var ids: [String: [Int64]] = [:]
    private var memo: [String: Double?] = [:]

    init(url: URL?) {
        self.url = url
    }

    deinit {
        sqlite3_finalize(byID)
        sqlite3_close_v2(db)
    }

    /// Whether `prepare()` has run (successfully or not): lookups answer
    /// from the table from then on.
    var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didPrepare
    }

    /// Reads the island names once. Off-main: it scans the whole table.
    func prepare() {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        guard !isPrepared else { return }
        var connection: OpaquePointer?
        var statement: OpaquePointer?
        var table: [String: [Int64]] = [:]
        if let url,
           sqlite3_open_v2("file:\(url.path)?immutable=1", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            == SQLITE_OK,
           sqlite3_prepare_v2(connection, "SELECT wkb FROM island WHERE osm_id = ?1", -1, &statement, nil)
            == SQLITE_OK {
            var names: OpaquePointer?
            if sqlite3_prepare_v2(connection, "SELECT osm_id, name, name_en FROM island", -1, &names, nil)
                == SQLITE_OK {
                while sqlite3_step(names) == SQLITE_ROW {
                    let id = sqlite3_column_int64(names, 0)
                    let local = sqlite3_column_text(names, 1).map { String(cString: $0) } ?? ""
                    let english = sqlite3_column_text(names, 2).map { String(cString: $0) } ?? ""
                    let display = english.isEmpty ? local : english
                    guard !display.isEmpty else { continue }
                    table[display, default: []].append(id)
                    if !display.utf8.allSatisfy({ $0 < 0x80 }) {
                        let latin = display.toLatinAscii
                        if latin != display { table[latin, default: []].append(id) }
                    }
                }
            }
            sqlite3_finalize(names)
        } else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Geocoder.sqlite not found in bundle"
            Self.logger.error("Failed to open Geocoder.sqlite islands: \(message, privacy: .public)")
            sqlite3_finalize(statement)
            sqlite3_close_v2(connection)
            statement = nil
            connection = nil
        }
        lock.lock()
        db = connection
        byID = statement
        ids = table
        memo = [:]
        didPrepare = true
        lock.unlock()
    }

    /// The area in km² of the island stored as `name` (the largest, when
    /// islands share the name); nil when no island has it or before
    /// `prepare()`.
    func areaKm2(named name: String) -> Double? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard didPrepare else { return nil }
        if let cached = memo[key] { return cached }
        var area: Double?
        for id in ids[key] ?? [] {
            for blob in rows(byID, id: id) {
                guard let candidate = WKBPolygon(data: blob)?.areaKm2 else { continue }
                area = max(area ?? candidate, candidate)
            }
        }
        memo[key] = .some(area)
        return area
    }

    private func rows(_ statement: OpaquePointer?, id: Int64) -> [Data] {
        guard let statement else { return [] }
        sqlite3_reset(statement)
        sqlite3_bind_int64(statement, 1, id)
        var blobs: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            blobs.append(Data(bytes: bytes, count: count))
        }
        sqlite3_reset(statement)
        return blobs
    }
}
