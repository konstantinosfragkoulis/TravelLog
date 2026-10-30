//
//  TripSearchWholeNameTests.swift
//  TravelLogTests
//
//  Place precision of the engine: a whole stored name outranks the same
//  word inside a longer different name, other spellings of stored places
//  (umlauts spelled out, Japanese long vowels, Han and kana suffixes), and
//  the query-only country aliases and abbreviations. Invented trips over
//  plain documents; nothing touches SwiftData.
//

import Foundation
import Testing
@testable import TravelLog

struct TripSearchWholeNameTests {

    // MARK: - Fixtures

    /// `custom` is the trip's custom name (a user-named title field);
    /// otherwise `title` is a generated title and its variants. `japan`
    /// and `islands` name the places and alternates that are in Japan or
    /// islands; a trip only in Japan has all of them in Japan.
    private static func doc(
        title: [String] = [],
        custom: String? = nil,
        place: [String] = [],
        region: [String] = [],
        countries: [String] = [],
        transit: [String] = [],
        alternates: [(name: String, of: String)] = [],
        japan: [String]? = nil,
        islands: [String] = []
    ) -> TripSearchDocument {
        let japan = Set(japan ?? (countries == ["JP"] ? place + region + alternates.map(\.name) : []))
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(
                    kind: .title,
                    displayValues: custom.map { [$0] } ?? (title.isEmpty ? Array(place.prefix(1)) : title),
                    isUserNamed: custom != nil),
                TripSearchField(kind: .place, displayValues: place, islandValues: Set(islands), japanValues: japan),
                TripSearchField(kind: .region, displayValues: region, japanValues: japan),
                TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(
                    for: countries, languageTag: "en")),
                TripSearchField(kind: .transit, displayValues: transit),
                TripSearchField(
                    kind: .place, displayValues: alternates.map(\.name), alternateOf: alternates.map(\.of),
                    islandValues: Set(islands), japanValues: japan),
            ],
            startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil,
            startYear: 2023, startMonth: 11, durationDays: 3, isComplete: true,
            countryCodes: Set(countries))
    }

    /// Strong and similar document indices.
    private static func run(
        _ query: String, _ docs: [TripSearchDocument], typing: Bool = false, languageTag: String = "en"
    ) -> (strong: [Int], similar: [Int]) {
        let matches = TripSearch.match(
            terms: TripSearch.terms(query, languageTag: languageTag, allowsTrailingPartial: typing),
            in: TripSearchIndex(documents: docs))
        return (matches.filter { $0.strength == .strong }.map(\.documentIndex),
                matches.filter { $0.strength == .similar }.map(\.documentIndex))
    }

    // MARK: - Whole names

    @Test("a whole region name outranks the word inside a longer one")
    func wholeRegionOutranksLongerName() {
        let docs = [
            Self.doc(place: ["Sunvale"], region: ["California"], countries: ["US"]),
            Self.doc(place: ["Puerto Fresco"], region: ["Baja California"], countries: ["MX"]),
        ]
        for typing in [false, true] {
            let result = Self.run("California", docs, typing: typing)
            #expect(result.strong == [0])
            #expect(result.similar == [1])
        }
        // Typed whole, the longer name is strong again.
        #expect(Self.run("Baja California", docs).strong == [1])
        // Without a trip that has it whole, the word inside stays strong.
        #expect(Self.run("California", [docs[1]]).strong == [0])
    }

    @Test("York lists New York below York; New York stays strong for its own name")
    func yorkAndNewYork() {
        let docs = [
            Self.doc(place: ["York"], countries: ["GB"]),
            Self.doc(place: ["New York"], region: ["New York"], countries: ["US"]),
        ]
        #expect(Self.run("York", docs).strong == [0])
        #expect(Self.run("York", docs).similar == [1])
        #expect(Self.run("New York", docs).strong == [1])
        #expect(Self.run("newyork", docs).strong == [1])
        // A same-named place in another country is just as whole.
        let paris = [
            Self.doc(place: ["Paris"], countries: ["FR"]),
            Self.doc(place: ["Paris"], region: ["Texas"], countries: ["US"]),
        ]
        #expect(Self.run("Paris", paris).strong == [0, 1])
    }

    @Test("a country name outranks a street named after it, also while typed")
    func countryOutranksStreet() {
        let docs = [
            Self.doc(place: ["Lindenau"], countries: ["AT"]),
            Self.doc(place: ["Old Town", "Paseo de Austria"], countries: ["ES"]),
            Self.doc(place: ["Santa Fe"], region: ["New Mexico"], countries: ["US"]),
            Self.doc(place: ["Oaxaca"], countries: ["MX"]),
        ]
        let typed = Self.run("Austria", docs, typing: true)
        #expect(typed.strong == [0])
        #expect(typed.similar == [1])
        // A recognized country name ranks the street similar with no trip
        // in that country too; finished, it matches whole words only.
        let noAustria = Array(docs.dropFirst())
        #expect(Self.run("Austria", noAustria, typing: true).strong.isEmpty)
        #expect(Self.run("Austria", noAustria, typing: true).similar == [0])
        #expect(Self.run("Austria", noAustria).strong.isEmpty)
        // With no trip in the country, a region of another country named
        // with it stays strong; with one, it ranks below.
        let belfast = Self.doc(place: ["Belfast"], region: ["Northern Ireland"], countries: ["GB"])
        let cork = Self.doc(place: ["Cork"], countries: ["IE"])
        #expect(Self.run("Ireland", [belfast]).strong == [0])
        #expect(Self.run("Ireland", [belfast], typing: true).strong == [0])
        #expect(Self.run("Ireland", [belfast, cork]).strong == [1])
        #expect(Self.run("Ireland", [belfast, cork]).similar == [0])
        let valdora = Self.doc(place: ["Mbeli"], region: ["Valdora"], countries: ["CD"])
        let eastValdora = Self.doc(place: ["Tsapo"], region: ["Valdora-Oriental"], countries: ["CD"])
        #expect(Self.run("Valdora", [valdora, eastValdora]).strong == [0])
        #expect(Self.run("Valdora", [valdora, eastValdora]).similar == [1])
        // Only a compass qualifier makes the same name: New Mexico is no Mexico.
        let santaFe = Self.doc(place: ["Santa Fe"], region: ["New Mexico"], countries: ["US"])
        #expect(Self.run("Mexico", [santaFe, belfast]).strong.isEmpty)
        #expect(Self.run("Mexico", [santaFe, belfast], typing: true).similar == [0])
        #expect(Self.run("Ireland", [santaFe, belfast]).strong == [1])
        let mexico = Self.run("Mexico", docs)
        #expect(mexico.strong == [3])
        #expect(mexico.similar == [2])
    }

    @Test("a name being typed is whole when the typed word completes it; only exact names demote")
    func typedCompletionsStayStrong() {
        let docs = [
            Self.doc(place: ["Bar"], countries: ["ME"]),
            Self.doc(place: ["Barcelona"], countries: ["ES"]),
        ]
        #expect(Self.run("bar", docs, typing: true).strong == [0, 1])
        // Finished, Bar is the place meant.
        #expect(Self.run("bar", docs).strong == [0])
        #expect(Self.run("bar", docs).similar == [1])
        // No trip is called "San": every San place stays strong.
        let san = [
            Self.doc(place: ["Santavelia"], countries: ["GR"]),
            Self.doc(place: ["San Diego"], countries: ["US"]),
        ]
        #expect(Self.run("san", san, typing: true).strong == [0, 1])
    }

    @Test("a trip the user named with the word stays strong; a generated title never protects")
    func ownTitleStaysStrong() {
        let docs = [
            Self.doc(place: ["Sunvale"], region: ["California"], countries: ["US"]),
            Self.doc(custom: "California Dreaming", place: ["Puerto Fresco"], region: ["Baja California"],
                     countries: ["MX"]),
            // A custom name made only of place words is still the user's.
            Self.doc(custom: "California", place: ["Puerto Fresco"], region: ["Baja California"], countries: ["MX"]),
            // Generated titles in several languages, one with a word that is
            // no place word of the trip, protect nothing.
            Self.doc(title: ["Puerto Fresco & Baja California", "Puerto Fresco und Baja California",
                             "Puerto Fresco, Baja California y más"],
                     place: ["Puerto Fresco"], region: ["Baja California"], countries: ["MX"]),
        ]
        let result = Self.run("California", docs)
        #expect(result.strong == [0, 1, 2])
        #expect(result.similar == [3])
    }

    @Test("connecting words and designators name nothing")
    func connectingWordsAreNoNames() {
        let docs = [
            Self.doc(place: ["Vessa de Lunero"], countries: ["ES"]),
            Self.doc(place: ["Kleinfeld"], countries: ["DE"]),
        ]
        #expect(Self.run("Vessa de Lunero", docs).strong == [0])
        // A leading article is part of the name: La Vessa is no Vessa.
        let vessa = [
            Self.doc(place: ["Vessa"], countries: ["ES"]),
            Self.doc(place: ["La Vessa"], countries: ["ES"]),
        ]
        #expect(Self.run("Vessa", vessa).strong == [0])
        #expect(Self.run("Vessa", vessa).similar == [1])
        #expect(Self.run("La Vessa", vessa).strong == [1])
        // An elided article is no word of the name: L'Aquila is Aquila.
        let aquila = [
            Self.doc(place: ["Aquila"], countries: ["IT"]),
            Self.doc(place: ["L'Aquila"], countries: ["IT"]),
        ]
        #expect(Self.run("Aquila", aquila).strong == [0, 1])
        let designated = [
            Self.doc(place: ["Cork"], countries: ["IE"]),
            Self.doc(place: ["Kinsale"], region: ["County Cork"], countries: ["IE"]),
            Self.doc(place: ["Madrid"], countries: ["ES"]),
            Self.doc(place: ["Alcalá"], region: ["Comunidad de Madrid"], countries: ["ES"]),
            Self.doc(place: ["Uji"], region: ["Kyoto Prefecture"], countries: ["JP"]),
            Self.doc(place: ["Kyoto"], countries: ["JP"]),
        ]
        #expect(Self.run("Cork", designated).strong == [0, 1])
        #expect(Self.run("Madrid", designated).strong == [2, 3])
        #expect(Self.run("Kyoto", designated).strong == [4, 5])
        // A place's own name keeps its designator: Seo District is no Seo.
        let seo = [
            Self.doc(place: ["Gwangju", "Seo District"], countries: ["KR"]),
            Self.doc(place: ["Seoul"], countries: ["KR"]),
        ]
        #expect(Self.run("seo", seo).strong == [0, 1])
    }

    // MARK: - Other spellings

    @Test("umlauts spelled out find stored and other-language names")
    func umlautsSpelledOut() {
        let docs = [
            Self.doc(place: ["Munich"], countries: ["DE"], alternates: [("München", "Munich")]),
            Self.doc(place: ["Lüderau"], countries: ["CH"]),
            Self.doc(place: ["Tromsø"], countries: ["NO"]),
        ]
        #expect(Self.run("Muenchen", docs).strong == [0])
        #expect(Self.run("München", docs).strong == [0])
        #expect(Self.run("Luederau", docs).strong == [1])
        #expect(Self.run("Tromsoe", docs).strong == [2])
    }

    @Test("Japanese long vowels fold in romaji and kana")
    func longVowels() {
        let docs = [
            Self.doc(place: ["Tokyo"], countries: ["JP"], alternates: [("東京", "Tokyo")]),
            Self.doc(place: ["Osaka"], countries: ["JP"]),
            Self.doc(place: ["Seoul"], countries: ["KR"], alternates: [("ソウル", "Seoul")]),
            Self.doc(place: ["Gimhae"], countries: ["KR"]),
        ]
        #expect(Self.run("Toukyou", docs).strong == [0])
        #expect(Self.run("Oosaka", docs).strong == [1])
        #expect(Self.run("とうきょう", docs, languageTag: "ja").strong == [0])
        #expect(Self.run("ソール", docs, languageTag: "ja").strong == [2])
        #expect(TripSearchText.longVowelSkeleton("kyuushuu") == "kyushu")
        #expect(TripSearchText.longVowelSkeleton("niigata") == "niigata")
        #expect(TripSearchText.kanaLongVowelSkeleton("とうきょう") == TripSearchText.kanaLongVowelSkeleton("トーキョー"))
        // A doubled e is a typo, not a long vowel: it stays similar.
        #expect(Self.run("Toukyou", docs).similar.isEmpty)
        let berlin = [Self.doc(place: ["Berlin"], countries: ["DE"])]
        #expect(Self.run("Beerlin", berlin).similar == [0])
        // Outside Japan ou, oo and uu are no long vowels: typos stay similar.
        let elsewhere = [
            Self.doc(place: ["London"], countries: ["GB"]),
            Self.doc(place: ["Horn"], countries: ["AT"]),
            Self.doc(place: ["Hoorn"], countries: ["NL"]),
        ]
        #expect(Self.run("Loundon", elsewhere).strong.isEmpty)
        #expect(Self.run("Loundon", elsewhere).similar == [0])
        #expect(Self.run("Hoorn", elsewhere).strong == [2])
        // Per place, not per trip: London on a London and Tokyo trip is no
        // Japanese spelling either.
        let mixed = [
            Self.doc(place: ["London", "Tokyo"], countries: ["GB", "JP"], japan: ["Tokyo"]),
            Self.doc(place: ["London"], countries: ["GB"]),
        ]
        #expect(Self.run("Loundon", mixed).strong.isEmpty)
        #expect(Self.run("Loundon", mixed).similar == [0, 1])
        #expect(Self.run("Toukyou", mixed).strong == [0])
        // A word in several values has every value's trait, in any order.
        for places in [["Little Tokyo", "Tokyo"], ["Tokyo", "Little Tokyo"]] {
            let trip = [Self.doc(place: places, countries: ["US", "JP"], japan: ["Tokyo"])]
            #expect(Self.run("Toukyou", trip).strong == [0], "\(places)")
        }
        // A short romanization is a whole word or nothing: ソウ is not South Korea.
        #expect(Self.run("ソウ", docs, typing: true, languageTag: "ja").strong == [2])
    }

    @Test("Han and kana names match without an administrative or island suffix")
    func cjkSuffixes() {
        // The table's names, each also without its administrative suffix
        // (`searchNames`); island suffixes are stripped on the query side.
        let jeju = TripSearchPlaceNames.searchNames(stored: ["ja": "済州市"], extras: [])
        #expect(jeju == ["済州市", "済州"])
        #expect(TripSearchPlaceNames.searchNames(stored: ["ja": "宮古島"], extras: []) == ["宮古島"])
        // An administrative stem always names the place, list and Siri.
        let tokyo = [
            Self.doc(place: ["Tokyo"], countries: ["JP"], alternates: [("東京都", "Tokyo")]),
            Self.doc(place: ["Tokyo"], countries: ["JP"], alternates: [("東京", "Tokyo")]),
        ]
        for typing in [false, true] {
            #expect(Self.run("東京都", tokyo, typing: typing, languageTag: "ja").strong == [0, 1])
        }
        // An island stem is strong only for an island.
        let docs = [
            Self.doc(place: ["Jeju Island"], countries: ["KR"], alternates: [("済州", "Jeju Island")],
                     islands: ["Jeju Island", "済州"]),
            Self.doc(place: ["Miyako"], countries: ["JP"], alternates: [("宮古", "Miyako")]),
            Self.doc(place: ["Miyakojima"], countries: ["JP"], alternates: [("宮古島", "Miyakojima")],
                     islands: ["Miyakojima", "宮古島"]),
        ]
        #expect(Self.run("済州島", docs, languageTag: "ja").strong == [0])
        for typing in [false, true] {
            #expect(Self.run("宮古島", docs, typing: typing, languageTag: "ja").strong == [2])
            #expect(Self.run("宮古島", docs, typing: typing, languageTag: "ja").similar == [1])
            let city = Array(docs.prefix(2))
            #expect(Self.run("宮古島", city, typing: typing, languageTag: "ja").strong.isEmpty)
            #expect(Self.run("宮古島", city, typing: typing, languageTag: "ja").similar == [1])
        }
        // A word in an island value and another value is the island's, in
        // any order.
        for names in [["宮古 市場", "宮古"], ["宮古", "宮古 市場"]] {
            let trip = [Self.doc(place: ["Miyakojima"], countries: ["JP"],
                                 alternates: names.map { ($0, "Miyakojima") }, islands: ["宮古"])]
            #expect(Self.run("宮古島", trip, languageTag: "ja").strong == [0], "\(names)")
        }
        #expect(TripSearchPlaceNames.withoutAdministrativeSuffix("広島", islands: true) == nil)
    }

    // MARK: - Country aliases

    @Test("country abbreviations and other-language aliases find the country, never words")
    func countryAliases() {
        let docs = [
            Self.doc(place: ["Brookmere"], countries: ["US"]),
            Self.doc(place: ["Ulm", "Stuttgart"], countries: ["DE"]),
            Self.doc(place: ["Leeds"], countries: ["GB"]),
            Self.doc(place: ["Gran Canaria"], countries: ["ES"]),
        ]
        for query in ["EEUU", "EE. UU.", "U.S.", "U.S.A.", "USA", "Amerika"] {
            #expect(Self.run(query, docs).strong == [0], "\(query)")
            #expect(Self.run(query, docs).similar.isEmpty, "\(query)")
        }
        for query in ["Großbritannien", "Grossbritannien", "Inglaterra", "U.K."] {
            #expect(Self.run(query, docs).strong == [2], "\(query)")
        }
        // Query-only: "Gran Bretaña" adds no word "gran" to British trips.
        #expect(Self.run("Gran", docs).strong == [3])
        #expect(TripSearchAliases.countryCodes(forPhrase: "vae", languageTag: "de") == ["AE"])
        #expect(TripSearchAliases.countryCodes(forPhrase: "ee uu", languageTag: "es") == ["US"])
    }
}
