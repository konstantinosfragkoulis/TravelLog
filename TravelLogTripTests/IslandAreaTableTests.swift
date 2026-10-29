//
//  IslandAreaTableTests.swift
//  TravelLogTests
//
//  `IslandAreaTable`: nothing is read before `prepare()` (the off-main
//  index build calls it), then a stored name finds its island by display
//  name or by the Latin form of a non-ASCII one, the largest island when
//  several share it. A throwaway database with invented square islands.
//

import Foundation
import SQLite3
import Testing
@testable import TravelLog

struct IslandAreaTableTests {

    private static func square(lon: Double, lat: Double, size: Double) -> Data {
        var data = Data([0x01])
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func f64(_ value: Double) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        u32(3); u32(1); u32(5)
        for (x, y) in [(lon, lat), (lon + size, lat), (lon + size, lat + size), (lon, lat + size), (lon, lat)] {
            f64(x); f64(y)
        }
        return data
    }

    /// Islands: 1 "Big Isle" (1°), 2 "Big Isle" (0.1°), 3 local-only "Κάλος" (0.2°).
    private func makeTable() throws -> (IslandAreaTable, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("islands-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE island (osm_id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_en TEXT, wkb BLOB NOT NULL)
            """, nil, nil, nil) == SQLITE_OK)
        let rows: [(Int64, String, String?, Data)] = [
            (1, "Big Isle", "Big Isle", Self.square(lon: 12.0, lat: 44.0, size: 1)),
            (2, "Megalo", "Big Isle", Self.square(lon: 13.0, lat: 44.0, size: 0.1)),
            (3, "Κάλος", nil, Self.square(lon: 14.0, lat: 44.0, size: 0.2)),
        ]
        for (id, name, english, wkb) in rows {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "INSERT INTO island VALUES (?1, ?2, ?3, ?4)", -1, &statement, nil)
                == SQLITE_OK)
            let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_bind_text(statement, 2, name, -1, transient)
            if let english { sqlite3_bind_text(statement, 3, english, -1, transient) } else { sqlite3_bind_null(statement, 3) }
            _ = wkb.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(wkb.count), transient) }
            try #require(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return (IslandAreaTable(url: url), url)
    }

    @Test("before prepare nothing is known; after it names find their largest island")
    func lookups() throws {
        let (table, url) = try makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!table.isPrepared)
        #expect(table.areaKm2(named: "Big Isle") == nil)
        table.prepare()
        #expect(table.isPrepared)
        let big = try #require(table.areaKm2(named: "Big Isle"))
        #expect(big > 8_000 && big < 9_500)
        let small = try #require(table.areaKm2(named: "Κάλος"))
        #expect(small > 300 && small < 400)
        // A stay stores a non-ASCII name in Latin letters.
        #expect(table.areaKm2(named: "Kalos") == small)
        #expect(table.areaKm2(named: "Megalo") == nil)
        #expect(table.areaKm2(named: "Nowhere Isle") == nil)
    }

    @Test("a missing database prepares to an empty table")
    func missingDatabase() {
        let table = IslandAreaTable(url: URL(fileURLWithPath: "/nonexistent/islands.sqlite"))
        table.prepare()
        #expect(table.isPrepared)
        #expect(table.areaKm2(named: "Big Isle") == nil)
    }
}
