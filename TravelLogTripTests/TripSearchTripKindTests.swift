//
//  TripSearchTripKindTests.swift
//  TravelLogTests
//
//  Trip kinds beyond places and dates: trips with a flight, long-haul
//  trips, multi- and single-country trips (`TripSearchFacet`), and "via X"
//  (a transit stop, `ParsedQuery.viaTerms`). Invented trips only.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TripSearchTripKindTests {

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: Date(timeIntervalSince1970: 1_780_000_000), languageTag: languageTag)
    }

    // MARK: - Parsing

    @Test(
        "kind words are consumed syntax",
        arguments: [
            ("flights", "en", TripSearchFacet.flight), ("trips by plane", "en", .flight), ("πτήσεις", "el", .flight),
            ("Flugreisen", "de", .flight), ("long-haul trips", "en", .longHaul), ("long haul", "en", .longHaul),
            ("Langstrecke", "de", .longHaul), ("multi-country trips", "en", .multiCountry),
            ("trips to several countries", "en", .multiCountry), ("πολλές χώρες", "el", .multiCountry),
            ("single country trips", "en", .singleCountry), ("plusieurs pays", "fr", .multiCountry),
        ] as [(String, String, TripSearchFacet)]
    )
    func kindWords(query: String, languageTag: String, facet: TripSearchFacet) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.facets == [facet], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        // "long-haul" is no length bound.
        #expect(p.minDurationDays == nil, "\(query)")
    }

    @Test(
        "via words mark the place after them (or before, in postpositional languages) as a stop",
        arguments: [
            ("via Valdoria", "en"), ("layover in Valdoria", "en"), ("trips to Marenza via Valdoria", "en"),
            ("μέσω Valdoria", "el"), ("Valdoria üzerinden", "tr"), ("über Valdoria", "de"),
        ]
    )
    func viaWords(query: String, languageTag: String) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.viaTerms.map(\.raw) == ["valdoria"], "\(query)")
        #expect(p.placeTerms.map(\.raw).contains("valdoria"), "\(query)")
    }

    // MARK: - Search

    private func document(
        _ place: String, transit: [String] = [], codes: Set<String>, facets: Set<TripSearchFacet>
    ) -> TripSearchDocument {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: start, endDate: start.addingTimeInterval(4 * 86_400), startYear: 2023, startMonth: 11,
            durationDays: 5, isComplete: true, countryCodes: codes, facets: facets)
    }

    /// 0 Marenza by long-haul flight via Valdoria, 1 Kostavo by flight, two
    /// countries, 2 Valdoria by road, 3 Port Ellis by road.
    private var documents: [TripSearchDocument] {
        [
            document("Marenza", transit: ["Valdoria"], codes: ["US"], facets: [.flight, .longHaul, .singleCountry]),
            document("Kostavo", codes: ["FR", "IT"], facets: [.flight, .multiCountry]),
            document("Valdoria", codes: ["DE"], facets: [.singleCountry]),
            document("Port Ellis", codes: ["DE"], facets: [.singleCountry]),
        ]
    }

    private func found(_ query: String, languageTag: String = "en") -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
            languageTag: languageTag)
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    @Test("kind words keep the trips of that kind; via keeps trips that stopped there")
    func search() {
        #expect(found("flights") == [0, 1])
        #expect(found("long-haul trips") == [0])
        #expect(found("multi-country trips") == [1])
        #expect(found("single country trips") == [0, 2, 3])
        #expect(found("Valdoria") == [0, 2])
        #expect(found("via Valdoria") == [0])
        #expect(found("layover in Valdoria") == [0])
        #expect(found("Marenza via Valdoria") == [0])
        #expect(found("Kostavo via Valdoria").isEmpty)
    }

    @Test("a via place keeps a leading function word that a trip's stop has (Spanish la of La Paz)")
    func viaKeepsFunctionWords() {
        let index = TripSearchIndex(documents: [
            document("La Paz", codes: ["BO"], facets: []),
            document("Kostavo", transit: ["La Paz"], codes: ["BO"], facets: [.flight]),
        ])
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(TripQueryParser.parse("via La Paz", now: now, languageTag: "es", corpus: index).viaTerms.map(\.raw)
            == ["la", "paz"])
        let found = TripQueryParser.searchTrips(
            index: index, query: "via La Paz", allowsTrailingPartial: false, languageTag: "es")
            .filter { $0.strength != .partial }.map(\.documentIndex)
        #expect(found == [1])
    }

    @Test("a via place ends at a destination connector")
    func viaEndsAtConnector() {
        let index = TripSearchIndex(documents: [
            document("Marenza", transit: ["Valdoria"], codes: ["IT"], facets: [.flight]),
            document("Marenza", codes: ["IT"], facets: [.flight]),
        ])
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        for (query, tag) in [("via Valdoria para Marenza", "pt-BR"), ("via Valdoria a Marenza", "es"),
                             ("via Valdoria to Marenza", "en")] {
            #expect(TripQueryParser.parse(query, now: now, languageTag: tag, corpus: index).viaTerms.map(\.raw)
                == ["valdoria"], "\(query)")
            let found = TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: false, languageTag: tag)
                .filter { $0.strength != .partial }.map(\.documentIndex)
            #expect(found == [0], "\(query)")
        }
    }

    @Test("a via place is a place before it is a holiday or date word (Portuguese via Natal)")
    func viaPlaceBeforeOtherSyntax() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)  // June 2026
        let june = TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: ["Kostavo"]),
                TripSearchField(kind: .place, displayValues: ["Kostavo"]),
                TripSearchField(kind: .transit, displayValues: ["Natal"]),
            ],
            startDate: start, endDate: start.addingTimeInterval(4 * 86_400), startYear: 2026, startMonth: 5,
            durationDays: 5, isComplete: true, facets: [.flight])
        let index = TripSearchIndex(documents: [june])
        func found(_ query: String, _ tag: String) -> Int {
            TripQueryParser.searchTrips(index: index, query: query, allowsTrailingPartial: false, languageTag: tag)
                .filter { $0.strength != .partial }.count
        }
        #expect(found("via Natal", "pt-BR") == 1)
        #expect(found("Natal üzerinden", "tr") == 1)
        // Without a via word, Natal is Christmas (the trip is in June).
        #expect(found("Natal", "pt-BR") == 0)
        // A via word before vocabulary no trip has as a place leaves it vocabulary.
        #expect(TripQueryParser.parse("über Weihnachten", languageTag: "de").holidays == [.christmas])
    }

    @Test(
        "a via place is the longest name a trip's stop or place has, claimed whole",
        arguments: [
            ("via Christmas Island", "en", ["christmas", "island"]),
            ("via La Paz", "es", ["la", "paz"]),
            ("via Three Rivers", "en", ["three", "rivers"]),
            ("Christmas Island üzerinden", "tr", ["christmas", "island"]),
        ]
    )
    func viaClaimsKnownNames(query: String, languageTag: String, via: [String]) {
        // 0 stops at each name; 1 stops at a place sharing only its last word.
        let index = TripSearchIndex(documents: [
            document("Marenza", transit: ["Christmas Island", "La Paz", "Three Rivers"], codes: ["IT"], facets: [.flight]),
            document("Kostavo", transit: ["Island", "Paz", "Rivers"], codes: ["IT"], facets: [.flight]),
        ])
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let parsed = TripQueryParser.parse(query, now: now, languageTag: languageTag, corpus: index)
        // A country-like name reads as one term ("christmas island").
        #expect(parsed.viaTerms.map(\.raw).joined(separator: " ") == via.joined(separator: " "), "\(query)")
        #expect(parsed.facets.isEmpty && parsed.holidays.isEmpty, "\(query)")
        let found = TripQueryParser.searchTrips(
            index: index, query: query, allowsTrailingPartial: false, languageTag: languageTag)
            .filter { $0.strength != .partial }.map(\.documentIndex)
        #expect(found == [0], "\(query)")
    }

    @Test("a via word inside a trip's place name stays that place")
    func viaInsidePlaceName() {
        let index = TripSearchIndex(documents: [
            document("Via Appia", codes: ["IT"], facets: []),
            document("Kostavo", transit: ["Appia"], codes: ["IT"], facets: [.flight]),
        ])
        let found = TripQueryParser.searchTrips(
            index: index, query: "Via Appia", allowsTrailingPartial: false, languageTag: "en")
            .filter { $0.strength != .partial }.map(\.documentIndex)
        #expect(found.contains(0))
        #expect(parse("via Appia").viaTerms.map(\.raw) == ["appia"])
    }

    // MARK: - Documents

    private func makeTrip(in context: ModelContext, codes: String) -> Trip {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(3 * 86_400)
        trip.isComplete = true
        trip.countryCodes = codes
        context.insert(trip)
        return trip
    }

    private func addStay(
        to trip: Trip, in context: ModelContext, category: StayCategory = .destination, iso: String,
        transit: TransitMode? = nil, legKm: Double? = nil, fromHomeKm: Double = 300, airport: Bool = false
    ) {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: fromHomeKm, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.locality = "Town"
        stay.isoCountryCode = iso
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = legKm
        stay.isAirport = airport
        stay.trip = trip
        stay.orderInTrip = 0
    }

    @Test("flight, long-haul and country-count facets of a trip")
    func documentFacets() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        func facets(_ codes: String, _ setup: (Trip) -> Void) -> Set<TripSearchFacet> {
            let trip = makeTrip(in: context, codes: codes)
            setup(trip)
            return TripSearchDocument.make(from: trip, languageTag: "en", islandAreaKm2: { _ in nil }).facets
        }
        // A recorded flight leg.
        #expect(facets("FR") { addStay(to: $0, in: context, iso: "FR", transit: .flight, legKm: 1_200) }
            == [.flight, .singleCountry])
        // An airport stop alone.
        #expect(facets("FR") {
            addStay(to: $0, in: context, category: .transit, iso: "FR", airport: true)
            addStay(to: $0, in: context, iso: "FR")
        } == [.flight, .singleCountry])
        // Long-haul: far from home, or one long leg.
        #expect(facets("US") { addStay(to: $0, in: context, iso: "US", transit: .flight, fromHomeKm: 8_000) }
            == [.flight, .longHaul, .singleCountry])
        #expect(facets("US") { addStay(to: $0, in: context, iso: "US", transit: .flight, legKm: 5_000, fromHomeKm: 900) }
            == [.flight, .longHaul, .singleCountry])
        // Far without a flight is no long-haul trip.
        #expect(facets("US") { addStay(to: $0, in: context, iso: "US", fromHomeKm: 8_000) } == [.singleCountry])
        #expect(facets("FR,IT") {
            addStay(to: $0, in: context, iso: "FR")
            addStay(to: $0, in: context, iso: "IT")
        } == [.multiCountry])
    }
}
