//
//  TripSearchRegionNameTests.swift
//  TravelLogTests
//
//  Regions people name, in the languages they type: a stay storing the
//  province "Seville" is found as "Andalusia" (its GeoNames region,
//  `StayAreaTable`) and as "Andalucía" or "Andalusien" (the region's other
//  names, `TripSearchPlaceNames` `.region`), a Cycladic island stay as "Κυκλάδες"
//  (its island group, `.group`), and a "Shibuya 1" stay as 渋谷 (its
//  neighbourhood's own name without the block number). Other names match
//  only as typed. Fictional places and a throwaway geocoder database.
//

import Foundation
import SQLite3
import Testing
@testable import TravelLog

struct TripSearchRegionNameTests {

    // MARK: - Engine

    /// Rows in the shape `PlaceNameTable.names(for:isoCountryCode:layer:)` returns, keyed "key|ISO|layer".
    private static let rows: [String: [String: String]] = [
        "valdoria|ES|region": [
            "es": "Valdoría", "de": "Valdorien", "fr": "Région de Valdoria", "ja": "ヴァルドリア州", "ko": "발도리아 주",
        ],
        "naxara|GR|group": [
            "en": "Lunades", "el": "Λουνάδες", "de": "Lunaden", "tr": "Lunades Adaları", "ja": "ルナデス諸島",
        ],
        "valdoria|ES|city": ["de": "Valdoria-Stadt"],
        "tokamachi|JP|city": ["ja": "十日町市"],
        "tokamachi|JP|region": ["ja": "十日町"],
    ]

    private static let names = TripSearchPlaceNames { key, iso, layer in rows[key + "|" + iso + "|" + layer.rawValue] ?? [:] }

    /// 0: a stay storing the province "Corvela" in the region Valdoria.
    /// 1: a Naxara island stay. 2: a stay in a block of the Hanamachi district.
    /// 3: a Benidorm stay storing the province "Alicante" in the region
    /// Valencia. 4: a Valencia city stay. 5: a stay in a town called ルナ.
    private static let index: TripSearchIndex = {
        func document(
            place: [String], region: [String], codes: Set<String>,
            regionNamed: [(name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer)] = [],
            own: [(name: String, of: String)] = []
        ) -> TripSearchDocument {
            TripSearchDocument(
                tripID: UUID(),
                fields: [
                    TripSearchField(kind: .title, displayValues: [place.joined(separator: " & ")]),
                    TripSearchField(kind: .place, displayValues: place),
                    TripSearchField(kind: .region, displayValues: region),
                    TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(for: Array(codes), languageTag: "en")),
                    .alternatePlaceNames(of: [], placeNames: names, adding: own),
                    .alternatePlaceNames(of: regionNamed, placeNames: names, kind: .region),
                ],
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: nil, startYear: 2023, startMonth: 11, durationDays: 4, isComplete: true,
                countryCodes: codes, normalizer: TripSearchNormalizer())
        }
        return TripSearchIndex(documents: [
            document(place: ["Corvela"], region: ["Corvela", "Valdoria"], codes: ["ES"],
                     regionNamed: [("Corvela", "ES", .region), ("Valdoria", "ES", .region)]),
            document(place: ["Naxara"], region: ["South Veloria"], codes: ["GR"],
                     regionNamed: [("Naxara", "GR", .group)]),
            document(place: ["Tokyo", "Hanamachi 1"], region: ["Tokyo"], codes: ["JP"],
                     own: TripSearchPlaceNames.searchNames(stored: [:], extras: TripSearchDocument.ownNames("花町一丁目"))
                        .map { ($0, "Hanamachi 1") }),
            document(place: ["Benidorm"], region: ["Alicante", "Valencia"], codes: ["ES"]),
            document(place: ["Valencia"], region: ["Valencia"], codes: ["ES"]),
            document(place: ["ルナ"], region: [], codes: ["JP"]),
        ])
    }()

    private func search(_ query: String) -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: Self.index, query: query, allowsTrailingPartial: !TripSearchText.endsWithSeparator(query),
            now: Date(timeIntervalSince1970: 1_790_000_000), languageTag: "en")
    }

    @Test("a region, its other names and an island group's names find their trips strongly", arguments: [
        ("Valdoria", 0), ("Valdoría", 0), ("Valdorien", 0), ("ヴァルドリア", 0), ("ヴァルドリア州", 0),
        ("Lunades", 1), ("Λουνάδες", 1), ("Lunaden", 1), ("花町", 2), ("花町一丁目", 2),
        // Region and group suffixes: a finished name finds them in the list and in Siri.
        ("발도리아", 0), ("발도리아주", 0), ("ルナデス", 1),
    ])
    func regionNamesFindTheirTrips(query: String, expected: Int) {
        for typed in [query, query + " "] {
            let matches = search(typed)
            #expect(matches.map(\.documentIndex) == [expected], "\(typed)")
            #expect(matches.allSatisfy { $0.strength == .strong }, "\(typed)")
        }
    }

    @Test("the caption names the stored region, island or district")
    func evidenceNamesTheStoredValue() throws {
        #expect(try #require(search("Valdorien ").first).evidence == [TripSearchEvidence(kind: .region, text: "Valdoria")])
        #expect(try #require(search("Lunades ").first).evidence == [TripSearchEvidence(kind: .region, text: "Naxara")])
        #expect(try #require(search("花町 ").first).evidence == [TripSearchEvidence(kind: .place, text: "Hanamachi 1")])
    }

    @Test("other region names never match by typo, infix or a finished prefix")
    func onlyAsTyped() {
        #expect(search("Valdorian ").allSatisfy { $0.documentIndex != 0 || $0.strength != .strong })
        #expect(search("Lunadez ").isEmpty)
        #expect(search("Lunad ").isEmpty)
        #expect(search("Lunad").map(\.documentIndex) == [1])
        // While typed, a word that is a stored name never starts another's other name.
        #expect(search("ルナ").map(\.documentIndex) == [5])
        #expect(search("ルナデ").map(\.documentIndex) == [1])
        #expect(search("町 ").isEmpty)
        // A designator of an official name names nothing alone; the whole name does.
        #expect(search("Région ").isEmpty)
        #expect(search("Région de Valdoria ").map(\.documentIndex) == [0])
        // Nor does a word for a group of islands.
        #expect(search("Adaları ").isEmpty)
        #expect(search("Lunades Adaları ").map(\.documentIndex) == [1])
    }

    @Test("a city's name also finds the stays its GeoNames region names (Valencia, the Valencian Community)")
    func regionNamedLikeACity() {
        let matches = search("Valencia ")
        #expect(matches.map(\.documentIndex) == [3, 4])
        #expect(matches.allSatisfy { $0.strength == .strong })
        #expect(matches.first?.evidence == [TripSearchEvidence(kind: .region, text: "Valencia")])
    }

    @Test("a town or village suffix is stripped from region and group names only (十日町 is a city)")
    func townSuffixes() {
        #expect(Self.names.names(for: "Tokamachi", isoCountryCode: "JP") == ["十日町市", "十日町"])
        #expect(Self.names.names(for: "Tokamachi", isoCountryCode: "JP", layer: .region) == ["十日町", "十日"])
    }

    @Test("a Korean 도 or 주 is dropped only as a word of its own, never from a name it ends (홋카이도, 콜로라도)")
    func koreanDesignators() {
        let suffixes = TripSearchAliases.regionSuffixes
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("홋카이도", suffixes: suffixes) == nil)
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("콜로라도", suffixes: suffixes) == nil)
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("발도리아 제도", suffixes: suffixes) == "발도리아")
        #expect(TripSearchDocument.isAlternateNoise("주", inName: ["발도리아", "주"]))
        #expect(!TripSearchDocument.isAlternateNoise("홋카이도", inName: ["홋카이도"]))
    }

    @Test("a part of a country Locale lists as a region is a region name, not a country")
    func countryParts() {
        #expect(!TripSearchAliases.isCountryName("canarias"))
        #expect(TripSearchAliases.countryCodes(forPhrase: "canarias", languageTag: "es") == nil)
        #expect(TripSearchAliases.countryCodes(forPhrase: "espana", languageTag: "es") == ["ES"])
    }

    @Test("a region reads its own rows, never a namesake city's, plus curated extras")
    func regionLookup() {
        #expect(Self.names.names(for: "Valdoria", isoCountryCode: "ES", layer: .region)
            == ["Valdorien", "Valdoría", "Région de Valdoria", "ヴァルドリア州", "ヴァルドリア", "발도리아 주"])
        #expect(Self.names.names(for: "Valdoria", isoCountryCode: "ES") == ["Valdoria-Stadt"])
        #expect(Self.names.names(for: "Naxara", isoCountryCode: "GR", layer: .group)
            == ["Lunaden", "Λουνάδες", "Lunades", "ルナデス諸島", "ルナデス", "Lunades Adaları"])
        #expect(Self.names.names(for: "Naxara", isoCountryCode: "GR", layer: .region).isEmpty)
        let empty = TripSearchPlaceNames { _, _, _ in [:] }
        #expect(empty.names(for: "Canary Islands", isoCountryCode: "ES", layer: .region) == ["Kanaren"])
    }

    @Test("a neighbourhood's own name, and without a Japanese or Korean block number")
    func ownNames() {
        #expect(TripSearchDocument.ownNames("渋谷一丁目") == ["渋谷一丁目", "渋谷"])
        #expect(TripSearchDocument.ownNames("北浜3丁目") == ["北浜3丁目", "北浜"])
        #expect(TripSearchDocument.ownNames("종로1가") == ["종로1가", "종로"])
        #expect(TripSearchDocument.ownNames("Oberfeld") == ["Oberfeld"])
        #expect(TripSearchDocument.ownNames("町一丁目") == ["町一丁目"])
    }

    @Test("a GeoNames region is indexed only when it is not the stored area")
    func derivedRegion() {
        let areas = StayAreaTable.Areas(region: "Castille and León", cityGeonameID: 1)
        #expect(TripSearchDocument.derivedRegion(areas, storedArea: "Burgos") == "Castille and León")
        #expect(TripSearchDocument.derivedRegion(areas, storedArea: "Castille and Leon") == nil)
        #expect(TripSearchDocument.derivedRegion(areas, storedArea: nil) == "Castille and León")
        #expect(TripSearchDocument.derivedRegion(StayAreaTable.Areas(), storedArea: "Burgos") == nil)
    }

    // MARK: - StayAreaTable

    /// A throwaway geocoder: regions ES.51 Valdoria, ES.52 Monteral, FR.11
    /// Brisane; cities Corvela (ES.51), Ribera (FR.11, 3 km from Corvela),
    /// Alto (ES.52, 19 km away), and by a province border Lindor (ES.51)
    /// and Caudo (ES.52); an admin-1 (province) polygon around each city,
    /// the Corvela and Ribera ones meeting at 40.0265° N, the Lindor and
    /// Caudo ones at 40.1° N; neighbourhoods "Hanamachi 1" (花町一丁目) and
    /// 下目黒六丁目 (no English name).
    static func makeTable() throws -> (StayAreaTable, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("areas-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE admin1_name (iso_country TEXT, admin1_code TEXT, name TEXT);
            INSERT INTO admin1_name VALUES ('ES', '51', 'Valdoria'), ('ES', '52', 'Monteral'), ('FR', '11', 'Brisane');
            CREATE TABLE city (geoname_id INTEGER PRIMARY KEY, name TEXT, name_lc TEXT, iso_country TEXT,
                               admin1_code TEXT, population INTEGER, lat REAL, lon REAL);
            CREATE VIRTUAL TABLE city_rtree USING rtree(geoname_id, min_lat, max_lat, min_lon, max_lon);
            INSERT INTO city VALUES (1, 'Corvela', 'corvela', 'ES', '51', 1000, 40.0, -3.0),
                                    (2, 'Ribera', 'ribera', 'FR', '11', 1000, 40.027, -3.0),
                                    (3, 'Alto', 'alto', 'ES', '52', 1000, 40.17, -3.0),
                                    (4, 'Lindor', 'lindor', 'ES', '51', 1000, 40.02, 10.0),
                                    (5, 'Caudo', 'caudo', 'ES', '52', 1000, 40.11, 10.0);
            INSERT INTO city_rtree SELECT geoname_id, lat, lat, lon, lon FROM city;
            CREATE TABLE admin1 (id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_en TEXT, iso_country TEXT,
                                 wkb BLOB NOT NULL);
            CREATE VIRTUAL TABLE admin1_rtree USING rtree(id, min_lat, max_lat, min_lon, max_lon);
            INSERT INTO admin1 VALUES (1, 'Corvela Province', NULL, 'ES', \(Self.box(39.9, 40.0265, -3.1, -2.9))),
                                      (2, 'Ribera', NULL, 'FR', \(Self.box(40.0265, 40.05, -3.1, -2.9))),
                                      (3, 'Alto Province', NULL, 'ES', \(Self.box(40.05, 40.3, -3.1, -2.9))),
                                      (4, 'Lindor Province', NULL, 'ES', \(Self.box(40.0, 40.1, 9.9, 10.1))),
                                      (5, 'Caudo Province', NULL, 'ES', \(Self.box(40.1, 40.2, 9.9, 10.1)));
            INSERT INTO admin1_rtree VALUES (1, 39.9, 40.0265, -3.1, -2.9), (2, 40.0265, 40.05, -3.1, -2.9),
                                            (3, 40.05, 40.3, -3.1, -2.9), (4, 40.0, 40.1, 9.9, 10.1),
                                            (5, 40.1, 40.2, 9.9, 10.1);
            CREATE TABLE neighborhood (osm_id INTEGER PRIMARY KEY, name TEXT, name_en TEXT, lat REAL, lon REAL);
            CREATE VIRTUAL TABLE neighborhood_rtree USING rtree(osm_id, min_lat, max_lat, min_lon, max_lon);
            INSERT INTO neighborhood VALUES (1, '花町一丁目', 'Hanamachi 1', 35.0, 139.0),
                                            (2, '下目黒六丁目', NULL, 35.1, 139.0);
            INSERT INTO neighborhood_rtree SELECT osm_id, lat, lat, lon, lon FROM neighborhood;
            """, nil, nil, nil) == SQLITE_OK)
        return (StayAreaTable(url: url), url)
    }

    /// A latitude/longitude box as a little-endian WKB Polygon SQL literal.
    private static func box(_ minLat: Double, _ maxLat: Double, _ minLon: Double, _ maxLon: Double) -> String {
        var data = Data([1])
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(3).littleEndian)
        append(UInt32(1).littleEndian)
        append(UInt32(5).littleEndian)
        for (lon, lat) in [(minLon, minLat), (maxLon, minLat), (maxLon, maxLat), (minLon, maxLat), (minLon, minLat)] {
            append(lon.bitPattern.littleEndian)
            append(lat.bitPattern.littleEndian)
        }
        return "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    @Test("nothing before prepare; then the region of the nearest city of the stay's own country")
    func regions() throws {
        let (table, url) = try Self.makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(table.areas(latitude: 40.0, longitude: -3.0, isoCountryCode: "ES", subLocality: nil) == .init())
        #expect(!table.isPrepared)
        table.prepare()
        #expect(table.isPrepared)
        #expect(table.areas(latitude: 40.001, longitude: -3.0, isoCountryCode: "ES", subLocality: nil).region == "Valdoria")
        // Within 5 km the nearest city names the region in any country, as the resolver names a locality.
        #expect(table.areas(latitude: 40.001, longitude: -3.0, isoCountryCode: "ES", subLocality: nil).cityGeonameID == 1)
        // A city across the border is never the stay's, however near: Corvela, not Ribera.
        let border = table.areas(latitude: 40.026, longitude: -3.0, isoCountryCode: "ES", subLocality: nil)
        #expect(border.region == "Valdoria" && border.cityGeonameID == 1)
        // A stay without a country takes the nearest city of any country
        // in its admin-1 polygon: Corvela again, not Ribera across it.
        let countryless = table.areas(latitude: 40.026, longitude: -3.0, isoCountryCode: nil, subLocality: nil)
        #expect(countryless.region == "Valdoria" && countryless.cityGeonameID == 2)
        #expect(table.areas(latitude: 40.04, longitude: -3.0, isoCountryCode: nil, subLocality: nil).region == "Brisane")
        // Past 5 km only a city of the stay's own country does.
        #expect(table.areas(latitude: 40.1, longitude: -3.0, isoCountryCode: "ES", subLocality: nil).region == "Monteral")
        #expect(table.areas(latitude: 40.1, longitude: -3.0, isoCountryCode: "PT", subLocality: nil).region == nil)
        #expect(table.areas(latitude: 0, longitude: 0, isoCountryCode: "ES", subLocality: nil).region == nil)
    }

    @Test("a province-level stay takes the region of the nearest city in its own admin-1 polygon, else none")
    func provinceBorder() throws {
        let (table, url) = try Self.makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        table.prepare()
        // Caudo is 0.5 km away across the province border; Lindor, 8 km
        // away, is in the stay's province.
        let border = table.areas(latitude: 40.095, longitude: 10.0, isoCountryCode: "ES",
                                 administrativeArea: "Lindor Province", subLocality: nil)
        #expect(border.region == "Valdoria")
        // The group key stays the nearest city's.
        #expect(border.cityGeonameID == 5)
        // Across the border the same holds the other way.
        #expect(table.areas(latitude: 40.105, longitude: 10.0, isoCountryCode: "ES",
                            administrativeArea: "Caudo Province", subLocality: nil).region == "Monteral")
        // Outside every polygon: no region, though Alto is near.
        let outside = table.areas(latitude: 40.31, longitude: -3.0, isoCountryCode: "ES", subLocality: nil)
        #expect(outside.region == nil && outside.cityGeonameID == 3)
    }

    @Test("no region is derived for a stay storing a region of its country, however near another's city")
    func storedRegion() throws {
        let (table, url) = try Self.makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        table.prepare()
        // Alto (Monteral) is the nearest city; the stay stores Valdoria, its own region.
        #expect(table.areas(latitude: 40.1, longitude: -3.0, isoCountryCode: "ES", administrativeArea: "Valdoria",
                            subLocality: nil).region == nil)
        // A province-level area is no region: the city's is derived.
        #expect(table.areas(latitude: 40.1, longitude: -3.0, isoCountryCode: "ES", administrativeArea: "Alto Province",
                            subLocality: nil).region == "Monteral")
    }

    @Test("a neighbourhood's own name when the stay stores its English name")
    func neighbourhoods() throws {
        let (table, url) = try Self.makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        table.prepare()
        #expect(table.areas(latitude: 35.0005, longitude: 139.0, isoCountryCode: "JP", subLocality: "Hanamachi 1")
            .subLocalityName == "花町一丁目")
        #expect(table.areas(latitude: 35.0005, longitude: 139.0, isoCountryCode: "JP", subLocality: "Kitamachi 2")
            .subLocalityName == nil)
        #expect(table.areas(latitude: 36.0, longitude: 139.0, isoCountryCode: "JP", subLocality: "Hanamachi 1")
            .subLocalityName == nil)
        // Without an English name the resolver stores the own name transliterated.
        let stored = StayAreaTable.latinASCII("下目黒六丁目")
        #expect(stored.utf8.allSatisfy { $0 < 0x80 })
        #expect(table.areas(latitude: 35.1005, longitude: 139.0, isoCountryCode: "JP", subLocality: stored)
            .subLocalityName == "下目黒六丁目")
    }

    @Test("a missing database prepares to nothing")
    func missingDatabase() {
        let table = StayAreaTable(url: URL(fileURLWithPath: "/nonexistent/Geocoder.sqlite"))
        table.prepare()
        #expect(table.isPrepared)
        #expect(table.areas(latitude: 40.0, longitude: -3.0, isoCountryCode: "ES", subLocality: "Old Town") == .init())
    }
}
