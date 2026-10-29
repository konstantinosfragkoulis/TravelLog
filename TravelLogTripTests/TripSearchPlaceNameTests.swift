//
//  TripSearchPlaceNameTests.swift
//  TravelLogTests
//
//  Trip search by a place's other-language names (`TripSearchPlaceNames`):
//  "München" finds a Munich trip strongly, matched only as typed (exact,
//  prefix while typing), never by typo, infix, a country word or a short
//  word of a longer name. Engine tests read an injected table with a few
//  well-known cities; one test reads the bundled table.
//

import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

struct TripSearchPlaceNameTests {

    // MARK: - Fixtures

    /// Rows in the shape `PlaceNameTable.names(for:isoCountryCode:)` returns, keyed "name key|ISO".
    private static let rows: [String: [String: String]] = [
        "munich|DE": ["de": "München", "es": "Múnich", "it": "Monaco di Baviera", "ja": "ミュンヘン"],
        "london|GB": ["es": "Londres", "it": "Londra", "vi": "Luân Đôn"],
        "florence|IT": ["it": "Firenze", "de": "Florenz"],
        "tokyo|JP": ["ja": "東京都", "zh-Hans": "东京", "ko": "도쿄"],
        "kyoto|JP": ["ja": "京都市"],
        "new york city|US": ["es": "Nueva York", "ko": "뉴욕 시", "zh-Hans": "紐約市"],
        "milan|IT": ["de": "Mailand", "it": "Milano"],
        "paris|FR": ["zh-Hans": "巴黎"],
        "mexico city|MX": ["es": "Ciudad de México", "fr": "Mexico"],
    ]

    private static func table() -> TripSearchPlaceNames {
        TripSearchPlaceNames { key, iso, _ in rows[key + "|" + iso] ?? [:] }
    }

    /// Stored places (name, ISO code) per trip, in index order.
    private static let trips: [[(String, String)]] = [
        [("Munich", "DE")],          // 0
        [("London", "GB")],          // 1
        [("Florence", "IT")],        // 2
        [("Tokyo", "JP")],           // 3
        [("Kyoto", "JP")],           // 4
        [("New York", "US")],        // 5, a metro stored without "City"
        [("Milan", "IT")],           // 6
        [("Bangkok", "TH")],         // 7
        [("Monaco", "MC")],          // 8
        [("Paris", "FR")],           // 9
        [("Mexico City", "MX")],     // 10
    ]

    private static let index: TripSearchIndex = {
        let names = table()
        return TripSearchIndex(documents: trips.map { places in
            TripSearchDocument(
                tripID: UUID(),
                fields: [
                    TripSearchField(kind: .title, displayValues: [places.map(\.0).joined(separator: " & ")]),
                    TripSearchField(kind: .place, displayValues: places.map(\.0)),
                    TripSearchField(
                        kind: .country,
                        displayValues: TripSearch.countryAliases(for: places.map(\.1), languageTag: "en")),
                    .alternatePlaceNames(of: places.map { ($0.0, $0.1, .city) }, placeNames: names),
                ],
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: nil, startYear: 2023, startMonth: 11, durationDays: 4, isComplete: true,
                countryCodes: Set(places.map(\.1)),
                normalizer: TripSearchNormalizer())
        })
    }()

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// The list's search: the last word counts as still typed unless the query ends in a separator.
    private func search(_ query: String, languageTag: String = "en") -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: Self.index, query: query,
            allowsTrailingPartial: TripsListView.allowsTrailingPartial(rawQuery: query),
            now: Self.now, languageTag: languageTag)
    }

    private func found(_ query: String, languageTag: String = "en") -> [Int] {
        search(query, languageTag: languageTag).map(\.documentIndex)
    }

    // MARK: - Matching

    @Test(
        "another language's name finds its place strongly, typed or finished, in any app language",
        arguments: [
            ("München", 0), ("munchen", 0), ("Múnich", 0), ("ミュンヘン", 0), ("Londres", 1), ("Londra", 1),
            ("Firenze", 2), ("Florenz", 2), ("東京", 3), ("东京", 3), ("도쿄", 3), ("Nueva York", 5),
            ("뉴욕", 5), ("纽约", 5), ("紐約", 5), ("Nova York", 5), ("Mailand", 6), ("巴黎", 9),
            ("Ciudad de México", 10),
        ])
    func otherNamesFindTheirPlace(query: String, expected: Int) {
        for typed in [query, query + " "] {
            for languageTag in ["en", "de", "ja"] {
                let matches = search(typed, languageTag: languageTag)
                #expect(matches.map(\.documentIndex) == [expected], "\(typed) [\(languageTag)]")
                #expect(matches.allSatisfy { $0.strength == .strong }, "\(typed) [\(languageTag)]")
            }
        }
    }

    @Test("the caption names the place as stored, not the name typed")
    func evidenceNamesTheStoredPlace() throws {
        let match = try #require(search("München ").first)
        #expect(match.evidence == [TripSearchEvidence(kind: .place, text: "Munich")])
        #expect(TripsListView.matchCaption(for: match.evidence)?.value == "Munich")
    }

    @Test("a Han name is also found without its administrative suffix, and never inside another name")
    func administrativeSuffixes() {
        #expect(found("東京都") == [3])
        #expect(found("京都") == [4])
        #expect(found("京都 ") == [4])
        #expect(found("京都市") == [4])
    }

    @Test("other names never match by typo, and by prefix only while typed", arguments: [
        "Londers", "Londers ", "Firenzi", "Firenzi ", "Mailandd ", "Munchn ",
    ])
    func noTypoTolerance(query: String) {
        #expect(!found(query).contains { [0, 1, 2, 6].contains($0) }, "\(query)")
    }

    @Test("a prefix of another name matches while it is typed, not once finished")
    func prefixWhileTyping() {
        #expect(found("Firen") == [2])
        #expect(found("Firen ").isEmpty)
        // Two typed words joined against a compound of another name: exact only.
        #expect(search("Luân Đô").map(\.strength) == [.strong])
        #expect(search("Luân Đô ").allSatisfy { $0.strength != .strong }, "\(search("Luân Đô ").map(\.strength))")
        #expect(search("Münch").map(\.strength) == [.strong])
        // Finished, only the stored name's typo tolerance remains.
        #expect(search("Münch ").map(\.strength) == [.similar])
    }

    @Test("a country word or a short word of another name does not stand for the place")
    func countryAndShortWords() {
        // Italian "Monaco di Baviera" is Munich, but "Monaco" is the country.
        #expect(found("Monaco") == [8])
        #expect(found("Monaco ") == [8])
        #expect(found("Monaco di Baviera") == [0])
        #expect(found("Baviera") == [0])
        // French "Mexico" is Mexico City, already found through its country.
        #expect(found("Mexico ") == [10])
        // "Đôn" of Vietnamese "Luân Đôn" is not London alone; the whole name is.
        #expect(found("Đôn ").isEmpty)
        #expect(found("don ").isEmpty)
        #expect(found("Luân Đôn") == [1])
        // Designators do not name a place: "Ciudad" alone is not Mexico City.
        #expect(found("ciudad ").isEmpty)
    }

    @Test("an exact other name gates weak tiers: Mailand never reaches Thailand")
    func otherNamesGateFuzzyMatches() {
        #expect(found("Mailand ") == [6])
        #expect(found("Mailand") == [6])
    }

    @Test("spelling suggestions name places as stored")
    func suggestionsUseStoredNames() {
        #expect(TripSearch.spellingSuggestion(for: "Londrs", in: Self.index, languageTag: "en") == "London")
        #expect(TripSearch.spellingSuggestion(for: "Londres", in: Self.index, languageTag: "en") == nil)
    }

    // MARK: - Names

    @Test("names: Chinese in both scripts, suffixes stripped, extras, in a fixed order")
    func searchNames() {
        let names = TripSearchPlaceNames.searchNames(
            stored: ["zh-Hans": "紐約市", "ko": "뉴욕 시", "es": "Nueva York", "de": "Nueva York"],
            extras: ["Nova York"])
        #expect(names == ["Nueva York", "뉴욕 시", "뉴욕", "紐約市", "紐約", "纽约市", "纽约", "Nova York"])
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("서울특별시") == "서울")
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("京都") == nil)
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("Kyoto-shi") == nil)
    }

    @Test("a place is read once per memo, by country, with the City fallback and the curated extras")
    func lookupAndMemo() {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let names = TripSearchPlaceNames { key, iso, _ in
            calls.withLock { $0.append(key + "|" + iso) }
            return Self.rows[key + "|" + iso] ?? [:]
        }
        let newYork = names.names(for: " New  York ", isoCountryCode: "us")
        #expect(newYork.contains("Nueva York") && newYork.contains("Nova York") && newYork.contains("뉴욕"))
        #expect(names.names(for: "New York", isoCountryCode: "US") == newYork)
        #expect(calls.withLock { $0 } == ["new york|US", "new york city|US"])
        #expect(names.names(for: "Munich", isoCountryCode: "AT").isEmpty)
        #expect(names.names(for: "Munich", isoCountryCode: nil).isEmpty)
        #expect(names.names(for: "Munich", isoCountryCode: "ZZ").isEmpty)
        names.removeAll()
        _ = names.names(for: "New York", isoCountryCode: "US")
        #expect(calls.withLock { $0.count } == 6)
    }

    @Test("an island reads its island rows, then its namesake city's in the languages those lack")
    func islandLookup() {
        let rows: [String: [String: String]] = [
            "velmora|GR|island": ["de": "Velmora-Insel", "tr": "Velmor"],
            "velmora|GR|city": ["de": "Velmora-Stadt", "ja": "ヴェルモラ"],
        ]
        let names = TripSearchPlaceNames { key, iso, layer in rows[key + "|" + iso + "|" + layer.rawValue] ?? [:] }
        #expect(names.names(for: "Velmora", isoCountryCode: "GR", layer: .island)
            == ["Velmora-Insel", "ヴェルモラ", "Velmor"])
        #expect(names.names(for: "Velmora", isoCountryCode: "GR") == ["Velmora-Stadt", "ヴェルモラ"])
    }

    @Test("the bundled table names well-known cities in other languages")
    func bundledTable() {
        let names = TripSearchPlaceNames(table: { key, iso, layer in
            PlaceNameTable.shared.names(for: key, isoCountryCode: iso, layer: layer)
        })
        #expect(names.names(for: "Munich", isoCountryCode: "DE").contains("München"))
        #expect(names.names(for: "London", isoCountryCode: "GB").contains("Londres"))
        #expect(names.names(for: "Tokyo", isoCountryCode: "JP").contains("東京"))
        #expect(names.names(for: "New York", isoCountryCode: "US").contains("Nueva York"))
    }
}

/// The model bridge: `TripSearchDocument.make(from:)` indexes the other
/// names of destination places only.
@MainActor
struct TripSearchPlaceNameDocumentTests {

    @Test("destination localities, metros and islands get other names; transit stays do not")
    func documentFromTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(4 * 86_400)
        trip.isComplete = true
        trip.destinationSummary = "Munich"
        context.insert(trip)
        for (order, (locality, metro, category)) in [
            ("Schwabing", "Munich", StayCategory.destination), ("Florence", nil, .transit),
        ].enumerated() {
            let stay = Stay(startTime: start.addingTimeInterval(Double(order) * 86_400),
                            endTime: start.addingTimeInterval(Double(order + 1) * 86_400),
                            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            context.insert(stay)
            stay.category = category
            stay.locality = locality
            stay.metroName = metro
            stay.isoCountryCode = order == 0 ? "DE" : "IT"
            stay.orderInTrip = order
            stay.trip = trip
        }
        try context.save()
        let names = TripSearchPlaceNames { key, iso, _ in
            ["munich|DE": ["de": "München"], "florence|IT": ["it": "Firenze"]][key + "|" + iso] ?? [:]
        }

        let document = TripSearchDocument.make(from: trip, languageTag: "en", placeNames: names)
        let alternates = document.fields.filter(\.isAlternate)
        #expect(alternates == [TripSearchField(kind: .place, displayValues: ["München"], alternateOf: ["Munich"])])
        #expect(document == TripSearchDocument.make(from: trip, languageTag: "en", placeNames: names))
        let index = TripSearchIndex(documents: [document])
        #expect(TripSearch.match(terms: TripSearch.terms("München", languageTag: "en"), in: index)
            .map(\.strength) == [.strong])
        #expect(TripSearch.match(terms: TripSearch.terms("Firenze", languageTag: "en"), in: index).isEmpty)
    }

    @Test("an island is found by the bundled table's island names: Girit finds a Crete trip")
    func islandOtherNamesFromBundledTable() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(4 * 86_400)
        trip.isComplete = true
        trip.destinationSummary = "Crete"
        context.insert(trip)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(4 * 86_400),
                        centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                        pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = .destination
        stay.islandName = "Crete"
        stay.isoCountryCode = "GR"
        stay.orderInTrip = 0
        stay.trip = trip
        try context.save()

        let index = TripSearchIndex(documents: [TripSearchDocument.make(from: trip, languageTag: "en")])
        for query in ["Girit", "Kreta", "Κρήτη"] {
            #expect(TripSearch.match(terms: TripSearch.terms(query, languageTag: "en"), in: index)
                .map(\.strength) == [.strong], "\(query)")
        }
    }
}
