//
//  TitleGroundingTests.swift
//  TravelLogTests
//
//  The trip-title bare-country guard. Two pure helpers on TripClassifier:
//   • `forbiddenCountryWords(for:)`, the set of country-name word tokens that
//     must never appear in a title. City-states (SG/VA/GI) are exempted in
//     BOTH the explicit-`country` and iso-fallback branches, the exact bug
//     that dropped "Singapore" from multi-destination titles.
//   • `isBareCountryName(_:forbidden:)`, all-tokens-forbidden test, so a legit
//     multi-word city is never rejected for merely containing a country word.
//  Edge cases cover the iso fallback, sentinel codes, multi-word and multi-country tokens, and punctuation.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleGroundingTests {

    /// Builds a Trip with the given stays (country / isoCountryCode / locality)
    /// linked in order, in a fresh in-memory context.
    private func makeTrip(_ stays: [(country: String?, iso: String?, locality: String?)])
        throws -> (TripClassifier, Trip)
    {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, s) in stays.enumerated() {
            let stay = Stay(startTime: .now, endTime: .now,
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.country = s.country
            stay.isoCountryCode = s.iso
            stay.locality = s.locality
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
        }
        return (classifier, trip)
    }

    // MARK: - forbiddenCountryWords

    @Test("single-stay country words: normal countries forbidden, city-states exempt", arguments: [
        ("Greece", "GR", "Néon Karlovásion", "greece", true, false),        // a normal country is forbidden
        ("Singapore", "SG", "Singapore", "singapore", false, true),         // explicit-country branch exemption
        ("Vatican City", "VA", "Vatican City", "vatican", false, true),     // city-state exemption beyond Singapore
        ("Gibraltar", "GI", "Gibraltar", "gibraltar", false, true),         // city-state exemption beyond Singapore
        ("Monaco", "MC", "Monte Carlo", "monaco", true, false),             // distinct districts → NOT exempt
    ])
    func singleStayCountryWords(country: String, iso: String, locality: String,
                                word: String, isForbidden: Bool, setIsEmpty: Bool) throws {
        let (c, trip) = try makeTrip([(country: country, iso: iso, locality: locality)])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains(word) == isForbidden)
        #expect(forbidden.isEmpty == setIsEmpty)
    }

    @Test("multi-destination: Singapore survives while Malaysia is forbidden (the regression)")
    func cityStateSurvivesMultiDestination() throws {
        let (c, trip) = try makeTrip([
            (country: "Singapore", iso: "SG", locality: "Singapore"),
            (country: "Malaysia", iso: "MY", locality: "Kuala Lumpur"),
        ])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains("malaysia"))
        #expect(!forbidden.contains("singapore"))
    }

    @Test("only the stay's OWN country is forbidden, no homonym over-reach onto a locality")
    func noHomonymOverReach() throws {
        // A stay in the US state of Georgia (iso US) must forbid "united states",
        // never "georgia" (the country) or the locality.
        let (c, trip) = try makeTrip([(country: "United States", iso: "US", locality: "Atlanta")])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains("united"))
        #expect(forbidden.contains("states"))
        #expect(!forbidden.contains("georgia"))
        #expect(!forbidden.contains("atlanta"))
    }

    @Test("country nil falls back to the iso-derived en_US country name")
    func isoFallbackWhenCountryNil() throws {
        let (c, trip) = try makeTrip([(country: nil, iso: "FR", locality: "Paris")])
        #expect(c.forbiddenCountryWords(for: trip).contains("france"))
    }

    @Test("explicit country wins over a disagreeing iso code")
    func explicitCountryPreferredOverIso() throws {
        // country says France, iso says DE, explicit country branch wins.
        let (c, trip) = try makeTrip([(country: "France", iso: "DE", locality: "Somewhere")])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains("france"))
        #expect(!forbidden.contains("germany"))
    }

    @Test("an invalid/sentinel iso ('ZZ' or '') with country nil yields no forbidden word")
    func unknownOrInvalidIsoProducesNoForbiddenWord() throws {
        let (c1, trip1) = try makeTrip([(country: nil, iso: "ZZ", locality: "Nowhere")])
        #expect(c1.forbiddenCountryWords(for: trip1).isEmpty)

        let (c2, trip2) = try makeTrip([(country: nil, iso: "", locality: "Nowhere")])
        #expect(c2.forbiddenCountryWords(for: trip2).isEmpty)
    }

    @Test("a multi-word country tokenizes into separate lowercased words")
    func multiWordCountryTokenizedIntoSeparateWords() throws {
        let (c, trip) = try makeTrip([(country: "United Kingdom", iso: "GB", locality: "London")])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains("united"))
        #expect(forbidden.contains("kingdom"))
    }

    @Test("a multi-country trip forbids the union; a city-state in the mix contributes nothing")
    func multipleStaysUnionForbiddenWords() throws {
        let (c, trip) = try makeTrip([
            (country: "France", iso: "FR", locality: "Paris"),
            (country: "Italy", iso: "IT", locality: "Rome"),
            (country: "Singapore", iso: "SG", locality: "Singapore"),
        ])
        let forbidden = c.forbiddenCountryWords(for: trip)
        #expect(forbidden.contains("france"))
        #expect(forbidden.contains("italy"))
        #expect(!forbidden.contains("singapore"))
    }

    @Test("exact country words for missing, empty, unknown and native-script inputs", arguments: [
        ("", "GR", ["greece"]),
        (nil, "gr", ["greece"]),
        (nil, "ZZ", []),
        (nil, nil, []),
        ("", "", []),
        ("Ελλάδα", "GR", ["ellada"]),
        ("Côte d’Ivoire", "CI", ["cote", "d", "ivoire"]),
        (nil, "BA", ["bosnia", "herzegovina"]),
    ] as [(String?, String?, Set<String>)])
    func exactCountryWords(country: String?, iso: String?, words: Set<String>) throws {
        let (c, trip) = try makeTrip([(country: country, iso: iso, locality: "Somewhere")])
        #expect(c.forbiddenCountryWords(for: trip) == words)
    }

    // MARK: - isBareCountryName

    @Test("a bare country name is detected")
    func bareCountryDetected() throws {
        let (c, _) = try makeTrip([])
        #expect(c.isBareCountryName("Greece", forbidden: ["greece"]))
        #expect(c.isBareCountryName("United States", forbidden: ["united", "states"]))
        #expect(c.isBareCountryName("United Kingdom", forbidden: ["united", "kingdom"]))
    }

    @Test("empty forbidden set never flags anything")
    func emptyForbiddenNeverFlags() throws {
        let (c, _) = try makeTrip([])
        #expect(!c.isBareCountryName("Greece", forbidden: []))
    }

    @Test("a real city is not a bare country (all-tokens test, not any-token)")
    func realCityNotFlagged() throws {
        let (c, _) = try makeTrip([])
        // "New York", neither token is a forbidden country word.
        #expect(!c.isBareCountryName("New York", forbidden: ["united", "states"]))
        // "Athens, Greece" / "United Kingdom", one token forbidden → not ALL → not bare.
        #expect(!c.isBareCountryName("Athens, Greece", forbidden: ["greece"]))
        #expect(!c.isBareCountryName("United Kingdom", forbidden: ["united"]))
    }

    @Test("a city that merely contains a country substring is not flagged (whole-token match)")
    func substringNotMatched() throws {
        let (c, _) = try makeTrip([])
        // "Georgetown" contains "georg…" but is a distinct token from "georgia".
        #expect(!c.isBareCountryName("Georgetown", forbidden: ["georgia"]))
    }

    @Test("isBareCountryName strips punctuation and is case-insensitive")
    func isBareCountryIgnoresPunctuationAndCase() throws {
        let (c, _) = try makeTrip([])
        #expect(c.isBareCountryName("GREECE!", forbidden: ["greece"]))
        #expect(c.isBareCountryName("  Greece  ", forbidden: ["greece"]))
    }

    @Test("isBareCountryName transliterates a native-script name before comparing")
    func isBareCountryTransliterates() throws {
        let (c, _) = try makeTrip([])
        #expect(c.isBareCountryName("Ελλάδα", forbidden: ["ellada"]))
        #expect(!c.isBareCountryName("Ελλάδα", forbidden: ["greece"]))
        #expect(!c.isBareCountryName("", forbidden: ["greece"]))
    }

    @Test("isBareCountryName is false when tokenization yields no words")
    func isBareCountryEmptyAfterTokenizationIsFalse() throws {
        let (c, _) = try makeTrip([])
        #expect(!c.isBareCountryName("123 -- !!", forbidden: ["greece"]))
    }
}
