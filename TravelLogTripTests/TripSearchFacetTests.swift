//
//  TripSearchFacetTests.swift
//  TravelLogTests
//
//  Trip facets (`TripSearchFacet`): island, abroad and domestic trips from
//  `TripSearchDocument.make(from:)`, the facet words that ask for them
//  ("islands", "abroad", "νησιά", "yurt dışı"), a facet word next to place
//  text tried as a place first (Rhode Island), and language names read as
//  their country's adjective ("Greek islands"). Invented trips only.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TripSearchFacetTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    // MARK: - Parsing

    @Test(
        "facet words are consumed syntax in every language that has them",
        arguments: [
            ("islands", "en", TripSearchFacet.island), ("island trips", "en", .island), ("isles", "en", .island),
            ("trips abroad", "en", .abroad), ("overseas", "en", .abroad), ("domestic trips", "en", .domestic),
            ("νησιά", "el", .island), ("ταξίδια στο εξωτερικό", "el", .abroad), ("εσωτερικού", "el", .domestic),
            // Greek script with the app in English.
            ("νησιά", "en", .island),
            ("Inseln", "de", .island), ("Ausland", "de", .abroad), ("islas", "es", .island),
            ("viajes al extranjero", "es", .abroad), ("îles", "fr", .island), ("à l'étranger", "fr", .abroad),
            ("isole", "it", .island), ("eilanden", "nl", .island), ("buitenland", "nl", .abroad),
            ("ilhas", "pt-BR", .island), ("utomlands", "sv", .abroad), ("adalar", "tr", .island),
            ("yurt dışı", "tr", .abroad), ("해외 여행", "ko", .abroad),
        ] as [(String, String, TripSearchFacet)]
    )
    func facetWords(query: String, languageTag: String, facet: TripSearchFacet) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.facets == [facet], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.hasStructuredFilter, "\(query)")
        #expect(p.placeInterpretation == nil, "\(query)")
    }

    @Test("a facet word inside a name some trip has is place text; elsewhere a facet")
    func facetWordInsideKnownName() {
        let corpus = TripSearchIndex(documents: [
            document("Providence", region: "Rhode Island", code: "US", facets: []),
            document("Isla Mujeres", code: "MX", facets: [.island]),
        ])
        func parse(_ query: String, _ tag: String = "en") -> TripQueryParser.ParsedQuery {
            TripQueryParser.parse(query, now: date(2026, 7, 14), calendar: utcCal, languageTag: tag, corpus: corpus)
        }
        #expect(parse("rhode island").facets.isEmpty)
        #expect(parse("rhode island").placeTerms.map(\.raw) == ["rhode", "island"])
        #expect(parse("rhode island").namePhrases == ["rhode island"])
        #expect(parse("isla mujeres", "es").facets.isEmpty)
        // Without a trip of that name, the facet.
        #expect(parse("long island").facets == [.island])
        #expect(parse("islands in 2024").placeInterpretation == nil)
    }

    @Test("a facet word inside a place name is place text: hyphenated, a region alias or a trip's name")
    func facetWordsInsidePlaceNames() {
        // A region name ("British Isles") with or without trips; a part of a
        // country with a reserved code ("Canary Islands") is a region name
        // some trip has (its GeoNames region), not a country.
        #expect(parse("British Isles").facets.isEmpty)
        #expect(parse("British Isles").placeTerms.first?.countryCodes.contains("GB") == true)
        let canaries = TripSearchIndex(documents: [
            document("Kalmora", region: "Canary Islands", code: "ES", facets: [.island]),
        ])
        #expect(TripQueryParser.parse(
            "Canary Islands", now: date(2026, 7, 14), calendar: utcCal, languageTag: "en", corpus: canaries
        ).facets.isEmpty)
        #expect(parse("trips to the British Isles").facets.isEmpty)
        // Hyphenated: one name.
        #expect(parse("Île-de-France", languageTag: "fr").facets.isEmpty)
        #expect(parse("Île-de-France", languageTag: "fr").placeTerms.map(\.raw).contains("ile"))
        // With the corpus, a two- or three-word name some trip has.
        let paris = document("Paris", region: "Île-de-France", code: "FR", facets: [.abroad])
        let corpus = TripSearchIndex(documents: [paris])
        let spaced = TripQueryParser.parse(
            "Île de France", now: date(2026, 7, 14), calendar: utcCal, languageTag: "fr", corpus: corpus)
        #expect(spaced.facets.isEmpty)
        #expect(parse("Île de France", languageTag: "fr").facets == [.island])
        for query in ["Île de France", "Île-de-France", "île-de-france"] {
            let hits = TripQueryParser.searchTrips(
                index: corpus, query: query, allowsTrailingPartial: false, now: date(2026, 7, 14),
                calendar: utcCal, languageTag: "fr")
            #expect(hits.filter { $0.strength != .partial }.map(\.documentIndex) == [0], "\(query)")
        }
        // A facet word beside an adjective stays a facet.
        #expect(parse("Greek islands").facets == [.island])
        #expect(parse("îles grecques", languageTag: "fr").facets == [.island])
    }

    @Test("language names read as their country's adjective, Latin ones from five letters")
    func languageAdjectives() {
        func codes(_ query: String) -> Set<String> {
            TripSearch.terms(query, languageTag: "en", allowsTrailingPartial: false).first?.countryCodes ?? []
        }
        #expect(codes("Greek") == ["GR"])
        #expect(codes("ελληνικά") == ["GR"])
        #expect(codes("Spanish") == ["ES"])
        // The country the adjective names, not where most speakers live.
        #expect(codes("Portuguese") == ["PT"])
        #expect(codes("πορτογαλικά") == ["PT"])
        #expect(codes("Chinese") == ["CN"])
        #expect(codes("Thai").isEmpty)
        #expect(codes("English").isEmpty)
        // Languages of several countries or of a region.
        #expect(codes("Arabic").isEmpty)
        #expect(codes("Welsh").isEmpty)
    }

    // MARK: - Search

    private func document(
        _ place: String, region: String? = nil, code: String, facets: Set<TripSearchFacet>
    ) -> TripSearchDocument {
        let start = date(2024, 6, 3)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(kind: .region, displayValues: region.map { [$0] } ?? []),
                TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(for: [code], languageTag: "en")),
            ],
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400), startYear: 2024, startMonth: 6,
            durationDays: 4, isComplete: true, countryCodes: [code], facets: facets)
    }

    /// 0 Marelos, 1 Athens, 2 Corfu (Ionian Islands), 3 Porto Lume (Lume Islands), 4 Providence (Rhode Island), 5 Paris.
    private var documents: [TripSearchDocument] {
        [
            document("Marelos", region: "Coastal Region", code: "GR", facets: [.island, .domestic]),
            document("Athens", region: "Attica", code: "GR", facets: [.domestic]),
            document("Corfu", region: "Ionian Islands", code: "GR", facets: [.island, .domestic]),
            document("Porto Lume", region: "Lume Islands", code: "ES", facets: [.island, .abroad]),
            document("Providence", region: "Rhode Island", code: "US", facets: [.abroad]),
            document("Paris", region: "Ile-de-France", code: "FR", facets: [.abroad]),
        ]
    }

    private func found(_ query: String, languageTag: String = "en") -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    @Test("facet words keep the trips of that kind")
    func facetSearch() {
        #expect(found("islands") == [0, 2, 3])
        #expect(found("Greek islands") == [0, 2])
        #expect(found("ελληνικά νησιά", languageTag: "el") == [0, 2])
        #expect(found("Spanish islands") == [3])
        #expect(found("trips abroad") == [3, 4, 5])
        #expect(found("domestic trips") == [0, 1, 2])
        #expect(found("islands abroad") == [3])
    }

    @Test("a language's adjective keeps the trips of its own country")
    func adjectiveCountry() {
        let index = TripSearchIndex(documents: [
            document("Vila Serena", code: "PT", facets: [.island, .abroad]),
            document("Ilha Clara", code: "BR", facets: [.island, .abroad]),
            document("Alvorada", code: "PT", facets: [.abroad]),
        ])
        for (query, tag) in [("Portuguese islands", "en"), ("πορτογαλικά νησιά", "el")] {
            for typing in [false, true] {
                let hits = TripQueryParser.searchTrips(
                    index: index, query: query, allowsTrailingPartial: typing, now: date(2026, 7, 14),
                    calendar: utcCal, languageTag: tag)
                    .filter { $0.strength != .partial }
                    .map(\.documentIndex)
                #expect(hits == [0], "\(query) \(typing)")
            }
        }
    }

    @Test("a place named with a facet word is found as that place")
    func placeNamesWithFacetWords() {
        #expect(found("Rhode Island") == [4])
        #expect(found("Ionian Islands") == [2])
        #expect(found("Lume Islands") == [3])
    }

    // MARK: - Documents

    private func makeTrip(in context: ModelContext, start: Date, codes: String) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(3 * 86_400)
        trip.isComplete = true
        trip.countryCodes = codes
        context.insert(trip)
        return trip
    }

    private func addStay(
        to trip: Trip, in context: ModelContext, category: StayCategory = .destination,
        iso: String, metro: String? = nil, island: String? = nil, latitude: Double = 0, longitude: Double = 0
    ) {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: latitude, centroidLongitude: longitude,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.locality = "Town"
        stay.isoCountryCode = iso
        stay.metroName = metro
        stay.islandName = island
        stay.trip = trip
        stay.orderInTrip = 0
    }

    @Test("an island trip has a destination island without a city on it, or a large island")
    func islandFacet() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let areas = ["Small Isle": 40.0, "Big Isle": 3_000.0]
        func facets(_ setup: (Trip) -> Void) -> Set<TripSearchFacet> {
            let trip = makeTrip(in: context, start: date(2024, 6, 3), codes: "GR")
            setup(trip)
            // The island facet alone (country counts: TripSearchTripKindTests).
            return TripSearchDocument.make(
                from: trip, languageTag: "en", calendar: utcCal, islandAreaKm2: { name, _, _ in areas[name] }).facets
                .intersection([.island])
        }
        #expect(facets { addStay(to: $0, in: context, iso: "GR", island: "Small Isle") } == [.island])
        #expect(facets { addStay(to: $0, in: context, iso: "GR", metro: "Harbour City", island: "Small Isle") }.isEmpty)
        #expect(facets { addStay(to: $0, in: context, iso: "GR", metro: "Harbour City", island: "Big Isle") } == [.island])
        #expect(facets { addStay(to: $0, in: context, iso: "GR", metro: "Harbour City", island: "Unknown Isle") }.isEmpty)
        #expect(facets { addStay(to: $0, in: context, category: .transit, iso: "GR", island: "Small Isle") }.isEmpty)
        #expect(facets { addStay(to: $0, in: context, iso: "GR") }.isEmpty)
    }

    @Test("an island name two islands share is sized by the island the stay stands on")
    func islandFacetSharedName() throws {
        // The shipped geocoder names New York's Staten Island (about 150 km²)
        // and Isla de los Estados (about 500 km²) both "Staten Island".
        IslandAreaTable.shared.prepare()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        func facets(iso: String, latitude: Double, longitude: Double) -> Set<TripSearchFacet> {
            let trip = makeTrip(in: context, start: date(2024, 6, 3), codes: iso)
            addStay(to: trip, in: context, iso: iso, metro: "Harbour City", island: "Staten Island",
                    latitude: latitude, longitude: longitude)
            return TripSearchDocument.make(from: trip, languageTag: "en", calendar: utcCal).facets
                .intersection([.island])
        }
        #expect(facets(iso: "US", latitude: 40.6, longitude: -74.15).isEmpty)
        #expect(facets(iso: "AR", latitude: -54.8, longitude: -64.2) == [.island])
    }

    @Test("abroad and domestic follow the Homes lived in at the trip's start")
    func homeFacets() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let greece = [TripSearchHome(isoCountryCode: "GR", startedAt: .distantPast, endedAt: nil)]
        func facets(_ codes: String, homes: [TripSearchHome], start: Date = Date(timeIntervalSince1970: 1_700_000_000))
            -> Set<TripSearchFacet> {
            let trip = makeTrip(in: context, start: start, codes: codes)
            return TripSearchDocument.make(from: trip, languageTag: "en", homes: homes, islandAreaKm2: { _, _, _ in nil }).facets
                .intersection([.abroad, .domestic])
        }
        #expect(facets("GR", homes: greece) == [.domestic])
        #expect(facets("ES", homes: greece) == [.abroad])
        #expect(facets("GR,ES", homes: greece) == [.abroad])
        #expect(facets("ES", homes: []).isEmpty)
        #expect(facets("", homes: greece).isEmpty)

        // A move: the Home of the trip's date decides; before any Home, every Home counts.
        let moved = [
            TripSearchHome(isoCountryCode: "GR", startedAt: date(2020, 1, 1), endedAt: date(2023, 1, 1)),
            TripSearchHome(isoCountryCode: "PT", startedAt: date(2023, 1, 1), endedAt: nil),
        ]
        #expect(facets("GR", homes: moved, start: date(2021, 5, 1)) == [.domestic])
        #expect(facets("GR", homes: moved, start: date(2024, 5, 1)) == [.abroad])
        #expect(TripSearchDocument.homeCountryCodes(at: date(2010, 5, 1), homes: moved) == ["GR", "PT"])
    }
}
