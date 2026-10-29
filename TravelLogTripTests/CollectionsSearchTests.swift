//
//  CollectionsSearchTests.swift
//  TravelLogTests
//
//  The trip search engine on the other search surfaces: Collections > Places,
//  Collections > Airports and the two country pickers (Earlier Travels and
//  the Trips country filter). Each list builds ONE index over all its rows,
//  so typo tolerance is gated by the whole list: `athens` does not fuzz to
//  the `Αθήνα` row when an Athens row matches exactly, and `iran` does not
//  list Iraq. Pure values; no SwiftData.
//

import Testing
import Foundation
@testable import TravelLog

struct CollectionsSearchTests {

    private let day = Date(timeIntervalSince1970: 1_717_243_200) // 2024-06-01

    private func place(
        _ id: String,
        _ name: String,
        _ iso: String?,
        _ country: String?,
        localities: [String] = []
    ) -> CollectionsAggregator.PlaceEntry {
        CollectionsAggregator.PlaceEntry(
            id: id, name: name, isoCountryCode: iso, country: country, kind: .metro,
            tripCount: 1, stayCount: 1, dayCount: 1, firstVisit: day, lastVisit: day,
            localities: localities)
    }

    private func airport(
        _ code: String,
        _ name: String?,
        _ city: String?,
        _ iso: String?
    ) -> CollectionsAggregator.AirportEntry {
        CollectionsAggregator.AirportEntry(
            code: code, name: name, city: city, isoCountryCode: iso,
            hasScheduledService: true, stayCount: 1, firstVisit: day, lastVisit: day,
            flownThrough: false)
    }

    // MARK: - Places

    @Test("Places search uses localized countries and symmetric transliteration")
    func placesSearchMatchesLocalizedCountry() {
        let athens = place("Athens|GR", "Athens", "GR", "Greece")

        #expect(PlacesListView.placeMatches(athens, query: "Ελλάδα", languageTag: "el"))
        #expect(PlacesListView.placeMatches(athens, query: "Ellada", languageTag: "el"))
        #expect(PlacesListView.placeMatches(athens, query: "Greece", languageTag: "el"))
        #expect(!PlacesListView.placeMatches(athens, query: "Japan", languageTag: "el"))

        let others: [(String, String?, String?)] = [
            ("Αθήνα", "GR", "Ελλάδα"), ("Tokyo", "JP", "Japan"),
            ("London", "GB", "United Kingdom"), ("Unknown", nil, nil),
            ("Paris", "fr", "France")]
        let places = [athens] + others.enumerated().map { index, fields in
            place("fixture-\(index)", fields.0, fields.1, fields.2, localities: ["Café", "Maroussi"])
        }
        let everyone = places.map(\.name)
        let withLocalities = Array(everyone.dropFirst())
        for language in ["en", "el", "de", "ja", "fr"] {
            let expectations: [(query: String, names: [String])] = [
                ("", everyone),
                ("   ", everyone),
                // A query of only symbols has no terms: no match.
                (",.;-", []),
                // The native name is recognized in any UI language.
                ("Ελλάδα", ["Athens", "Αθήνα"]),
                // Ellada is a curated alias of Greece, so the Athens row has it in every UI.
                ("Ellada", ["Athens", "Αθήνα"]),
                ("Greece", ["Athens", "Αθήνα"]),
                ("Griechenland", ["Athens", "Αθήνα"]),
                // An exact Athens row gates typo tolerance for the whole list.
                ("athens", ["Athens"]),
                ("toyko", ["Tokyo"]),
                ("londno", ["London"]),
                ("uk", ["London"]),
                ("cafe", withLocalities),
                ("maroussi greece", ["Αθήνα"]),
                ("europe", ["Athens", "Αθήνα", "London", "Paris"]),
                ("東京", []),
                ("missing", []),
            ]
            for (query, names) in expectations {
                #expect(
                    PlacesListView.matchingPlaces(places, query: query, languageTag: language).map(\.name) == names,
                    "\(language) \(query)")
            }
        }
    }

    @Test("Places: one index per list, so iran does not list Iraq when an Iran row exists")
    func placesGateTyposOverTheWholeList() {
        let places = [
            place("tehran", "Tehran", "IR", "Iran"),
            place("baghdad", "Baghdad", "IQ", "Iraq"),
        ]
        #expect(PlacesListView.matchingPlaces(places, query: "iran", languageTag: "en").map(\.id) == ["tehran"])
        #expect(PlacesListView.matchingPlaces(places, query: "iraq", languageTag: "en").map(\.id) == ["baghdad"])
        // Alone, the Iraq row stays out too: "iran" names a country exactly, so it never fuzzes.
        #expect(!PlacesListView.placeMatches(places[1], query: "iran", languageTag: "en"))
    }

    @Test("Places indexes built off-main preserve list order and language matching")
    func placesIndexBuildsOffMain() async {
        let places = [
            place("athens", "Athens", "GR", "Greece", localities: ["Maroussi"]),
            place("paris", "Paris", "FR", "France"),
            place("baghdad", "Baghdad", "IQ", "Iraq"),
            place("tehran", "Tehran", "IR", "Iran"),
        ]
        let index = await Task.detached {
            PlacesListView.searchIndex(places, languageTag: "el")
        }.value

        #expect(index.entries == places)
        #expect(index.languageTag == "el")
        #expect(index.matching("").map(\.id) == places.map(\.id))
        #expect(index.matching("europe").map(\.id) == ["athens", "paris"])
        #expect(index.matching("Ellada").map(\.id) == ["athens"])
        #expect(index.matching("maroussi").map(\.id) == ["athens"])
        #expect(index.matching("iran").map(\.id) == ["tehran"])
    }

    // MARK: - Airports

    private var airports: [CollectionsAggregator.AirportEntry] {
        [
            airport("AHN", "Athens Ben Epps Airport", "Athens", "US"),
            airport("ATH", "Athens International Airport Eleftherios Venizelos", "Athens", "GR"),
            airport("JFK", "John F Kennedy International Airport", "New York", "US"),
            airport("LHR", "London Heathrow Airport", "London", "GB"),
            airport("NRT", "Narita International Airport", "Narita", "JP"),
            airport("ZRH", "Zürich Airport", "Zürich", "CH"),
        ]
    }

    private func airportCodes(_ query: String, _ language: String = "en") -> [String] {
        AirportsListView.matchingAirports(airports, query: query, languageTag: language).map(\.code)
    }

    @Test("Airports: diacritics fold, so zurich finds Zürich Airport")
    func airportsFoldDiacritics() {
        #expect(airportCodes("zurich") == ["ZRH"])
        #expect(airportCodes("Zürich") == ["ZRH"])
        #expect(airportCodes("heatrow") == ["LHR"])
    }

    @Test("Airports: an exact IATA code, in any case, lists that airport first")
    func airportsExactCodeFirst() {
        #expect(airportCodes("ath").first == "ATH")
        #expect(airportCodes("ATH").first == "ATH")
        // "ath" also starts the Athens (Georgia) airport's city.
        #expect(Set(airportCodes("ath")) == ["ATH", "AHN"])
        #expect(airportCodes("jfk") == ["JFK"])
    }

    @Test("Airports: country aliases and region words find airports by country")
    func airportsMatchCountriesAndRegions() {
        #expect(airportCodes("greece") == ["ATH"])
        #expect(airportCodes("Ελλάδα") == ["ATH"])
        #expect(airportCodes("Schweiz", "de") == ["ZRH"])
        #expect(airportCodes("europe") == ["ATH", "LHR", "ZRH"])
        #expect(airportCodes("asia") == ["NRT"])
    }

    @Test("Airports: empty query lists everything, symbols list nothing")
    func airportsEmptyAndSymbolQueries() {
        #expect(airportCodes("") == airports.map(\.code))
        #expect(airportCodes("  ") == airports.map(\.code))
        #expect(airportCodes("---").isEmpty)
        #expect(airportCodes("tokyo").isEmpty)
    }

    // MARK: - Country pickers

    private var allCountryCodes: [String] {
        Locale.Region.isoRegions.map(\.identifier).filter(RememberedCountriesStorage.isValidCode)
    }

    private func countries(_ query: String, _ language: String) -> [String] {
        RememberedCountriesPicker.searchIndex(codes: allCountryCodes, languageTag: language).matching(query)
    }

    @Test("Pickers: English names work in every UI, app-language names in their own")
    func pickersMatchEnglishAndAppLanguageNames() {
        #expect(countries("Greece", "de") == ["GR"])
        #expect(countries("Griechenland", "de") == ["GR"])
        #expect(countries("Ellada", "el") == ["GR"])
        #expect(countries("Germany", "el") == ["DE"])
        #expect(RememberedCountriesPicker.matchesSearch(code: "GR", query: "Greece", languageTag: "de"))
        #expect(RememberedCountriesPicker.matchesSearch(code: "GR", query: "Ellada", languageTag: "el"))
        #expect(RememberedCountriesPicker.matchesSearch(code: "DE", query: "Germany", languageTag: "el"))
    }

    @Test("Pickers: a small typo still finds the country")
    func pickersTolerateTypos() {
        #expect(countries("Grece", "en") == ["GR"])
        #expect(RememberedCountriesPicker.matchesSearch(code: "GR", query: "Grece", languageTag: "en"))
    }

    @Test("Pickers: europe lists European countries")
    func pickersMatchRegionWords() {
        let europe = Set(countries("europe", "en"))
        #expect(europe.isSuperset(of: ["GR", "FR", "DE", "IT", "ES", "GB", "SE"]))
        #expect(europe.isDisjoint(with: ["JP", "US", "BR", "AU"]))
    }

    @Test("Pickers: one index per list, so iran does not list Iraq")
    func pickersGateTyposOverTheWholeList() {
        #expect(countries("iran", "en") == ["IR"])
        #expect(countries("iraq", "en") == ["IQ"])
    }

    @Test("Pickers: connecting words of country names are not searchable on their own")
    func pickersDropNameStopWords() {
        #expect(countries("of", "en").isEmpty)
        #expect(countries("bosnia and herzegovina", "en") == ["BA"])
    }
}
