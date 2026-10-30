//
//  TripSearchPrecisionTests.swift
//  TravelLogTests
//
//  Precision guards: a finished country or region name matches its words
//  only exactly (Austria is not Plaza Austriana), a word some trip has
//  as typed is never "corrected" into another place (a transit town named
//  like a country), and a transit stay's island is transit evidence like
//  its locality. Invented trips only.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TripSearchPrecisionTests {

    private func document(
        place: [String] = [], transit: [String] = [], code: String
    ) -> TripSearchDocument {
        TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [(place + transit).first ?? code]),
                TripSearchField(kind: .place, displayValues: place),
                TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(for: [code], languageTag: "en")),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil,
            startYear: 2023, startMonth: 11, durationDays: 3, isComplete: true, countryCodes: [code])
    }

    private func found(_ query: String, in documents: [TripSearchDocument], typing: Bool = false) -> [Int] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
            languageTag: "en")
            .filter { $0.strength != .partial }
            .map(\.documentIndex)
    }

    @Test("a finished country name matches its words only exactly; while typed it still prefixes")
    func countryNamesMatchExactly() {
        let documents = [
            document(place: ["Plaza Austriana"], code: "ES"),
            document(place: ["Vienna"], code: "AT"),
        ]
        #expect(found("Austria", in: documents) == [1])
        #expect(found("trips to Austria", in: documents) == [1])
        #expect(found("Austria", in: documents, typing: true).contains(1))
        // A place word that is no country name keeps its prefix match.
        #expect(found("Plaza", in: documents) == [0])
    }

    @Test("a word some trip has as typed gets no spelling suggestion")
    func noSuggestionForAKnownWord() {
        let madrid = document(place: ["Madrid"], code: "ES")
        let viaSpaxa = document(place: ["Lima"], transit: ["Spaxa"], code: "PE")
        #expect(TripSearch.spellingSuggestion(for: "Spaxa", in: TripSearchIndex(documents: [madrid]), languageTag: "en")
            == "Spain")
        #expect(TripSearch.spellingSuggestion(
            for: "Spaxa", in: TripSearchIndex(documents: [madrid, viaSpaxa]), languageTag: "en") == nil)
    }

    // MARK: - Documents

    @Test("a transit stay's island is transit evidence")
    func transitIsland() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(trip)
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = .transit
        stay.locality = "Port Town"
        stay.islandName = "Ferry Isle"
        stay.isoCountryCode = "GR"
        stay.trip = trip
        stay.orderInTrip = 0

        let document = TripSearchDocument.make(from: trip, languageTag: "en", islandAreaKm2: { _, _, _ in nil })
        #expect(document.fields.first { $0.kind == .transit }?.displayValues == ["Port Town", "Ferry Isle"])
        #expect(document.fields.first { $0.kind == .place }?.displayValues.contains("Ferry Isle") != true)
        #expect(document.facets.isEmpty)
        let match = TripSearch.match(
            terms: TripSearch.terms("Ferry Isle", languageTag: "en", allowsTrailingPartial: false),
            in: TripSearchIndex(documents: [document]))
        #expect(match.first?.strength == .similar)
        #expect(match.first?.evidence.first?.kind == .transit)
    }
}
