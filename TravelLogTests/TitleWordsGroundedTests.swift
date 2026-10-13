//
//  TitleWordsGroundedTests.swift
//  TravelLogTests
//
//  Title grounding validator: TripClassifier.titleWordsAreGrounded(_:for:).
//  Every word in a candidate title must derive from a **destination** stay's
//  name (metroName / islandName / locality / administrativeArea, plus iso
//  code). Transit stays do not ground words because they are
//  not title candidates. The validator falls back to all stays when the trip has no
//  destination stays (the base helper below leaves stays `.unclassified`, so
//  those tests exercise that fallback). Alternatively a word
//  may be a generic connector/region word, OR a seeded abbreviation (NYC/NY
//  when New York is present, LA when Los Angeles is present). A forbidden
//  country word is a HARD reject (checked before allowed/connector), even if
//  a stay's stale locality contains it. Pure (reads trip.orderedStays + the
//  nonisolated forbiddenCountryWords), so these tests run synchronously.
//  The validator is internal and nonisolated.
//
//  `@MainActor` because it constructs @Model Stay/Trip and instantiates the
//  @ModelActor TripClassifier (app is MainActor-by-default).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleWordsGroundedTests {

    /// V10-shaped stay fields the validator reads.
    private typealias StaySpec = (
        metro: String?, island: String?, locality: String?,
        admin: String?, iso: String?, country: String?
    )

    private func makeTrip(_ specs: [StaySpec]) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, s) in specs.enumerated() {
            let stay = Stay(startTime: .now, endTime: .now,
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.metroName = s.metro
            stay.islandName = s.island
            stay.locality = s.locality
            stay.administrativeArea = s.admin
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
        }
        return (classifier, trip)
    }

    // MARK: - Grounded by stay names

    @Test("a title matching a stay's locality is grounded")
    func titleMatchingStayLocalityIsGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: "Paris", admin: nil, iso: "FR", country: "France")
        ])
        #expect(c.titleWordsAreGrounded("Paris", for: trip))
    }

    @Test("a title matching metroName is grounded even when the locality differs")
    func titleMatchingMetroNameIsGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: "Athens", island: nil, locality: "Néa Pentéli", admin: nil, iso: "GR", country: "Greece")
        ])
        #expect(c.titleWordsAreGrounded("Athens", for: trip))
    }

    @Test("a title matching islandName is grounded")
    func titleMatchingIslandNameIsGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: "Cephalonia", locality: nil, admin: nil, iso: "GR", country: "Greece")
        ])
        #expect(c.titleWordsAreGrounded("Cephalonia", for: trip))
    }

    @Test("a title using a word present only in administrativeArea is grounded")
    func titleMatchingAdministrativeAreaIsGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: nil, admin: "Tuscany", iso: "IT", country: "Italy")
        ])
        #expect(c.titleWordsAreGrounded("Tuscany", for: trip))
    }

    // MARK: - Hallucination rejection

    @Test("a hallucinated city (Athens, absent from a Syros-only trip) is rejected")
    func hallucinatedCityRejected() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: "Syros", locality: "Ermoúpolis", admin: nil, iso: "GR", country: "Greece")
        ])
        #expect(!c.titleWordsAreGrounded("Syros & Athens", for: trip))
    }

    @Test("'&' is split out and ignored; a multi-destination title with both cities passes")
    func ampersandIsAllowedSeparator() throws {
        let (c, trip) = try makeTrip([
            (metro: "Madrid", island: nil, locality: "Madrid", admin: nil, iso: "ES", country: "Spain"),
            (metro: "Barcelona", island: nil, locality: "Barcelona", admin: nil, iso: "ES", country: "Spain"),
        ])
        #expect(c.titleWordsAreGrounded("Madrid & Barcelona", for: trip))
    }

    @Test("connector/region words decorate a grounded place word; alone they are not a title")
    func connectorWordsAllowedWithoutStayMatch() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: "Cephalonia", locality: "Lixoúri", admin: nil, iso: "GR", country: "Greece"),
            (metro: nil, island: "Mykonos", locality: "Mykonos", admin: nil, iso: "GR", country: "Greece"),
        ])
        // "Islands" and "Greek" are connectors: fine beside a place word…
        #expect(c.titleWordsAreGrounded("Cephalonia & the Greek Islands", for: trip))
        #expect(c.titleWordsAreGrounded("Cephalonia Tour", for: trip))
        // A title made only of connector or region words names no stay.
        // These words cannot stand in for a grounded place.
        #expect(c.ungroundedTitleFailure("Greek Islands", for: trip) == .noGroundedWord("Greek Islands"))
    }

    // MARK: - Region hallucination from allow-listed parts

    @Test("a region assembled from allow-listed words rejects when nothing corroborates it")
    func regionFromConnectorPartsRejected() throws {
        let (c, trip) = try makeTrip([
            (metro: "Vienna", island: nil, locality: "Vienna", admin: nil, iso: "AT", country: "Austria")
        ])
        // Every word individually allow-listed (demonym/regional + feature
        // noun), but neither maps to a country this trip visited.
        // Neither region can stand in for a grounded place.
        #expect(!c.titleWordsAreGrounded("Bavarian Alps", for: trip))
        #expect(!c.titleWordsAreGrounded("Italian Lakes", for: trip))
        // Unmappable region words can never anchor a zero-grounded title.
        #expect(!c.titleWordsAreGrounded("Atlantic Coast", for: trip))
        // A grounded stay word restores the decoration privilege.
        #expect(c.titleWordsAreGrounded("Vienna & the Bavarian Alps", for: trip))
    }

    @Test("a visited-country demonym cannot anchor a title with no grounded place")
    func visitedDemonymAnchors() throws {
        let (c, trip) = try makeTrip([
            (metro: "Reykjavik", island: nil, locality: "Reykjavik", admin: nil, iso: "IS", country: "Iceland")
        ])
        // "Icelandic Coast" cannot stand for Reykjavik, and
        // "Swiss Alps" cannot stand for cities. A title must name a place.
        #expect(c.ungroundedTitleFailure("Icelandic Coast", for: trip) == .noGroundedWord("Icelandic Coast"))
        #expect(!c.titleWordsAreGrounded("Norwegian Coast", for: trip))
        #expect(c.titleWordsAreGrounded("Reykjavik & the Icelandic Coast", for: trip))
    }

    @Test("Swiss Alps cannot replace the cities of a Swiss trip")
    func swissAlpsRejected() throws {
        let (c, trip) = try makeTrip([
            (metro: "Renens", island: nil, locality: "Renens", admin: nil, iso: "CH", country: "Switzerland"),
            (metro: "Bellinzona", island: nil, locality: "Bellinzona", admin: nil, iso: "CH", country: "Switzerland"),
            (metro: "Ajaccio", island: nil, locality: "Ajaccio", admin: nil, iso: "FR", country: "France"),
        ])
        for stay in trip.orderedStays { stay.category = .destination }
        #expect(c.ungroundedTitleFailure("Swiss Alps", for: trip) == .noGroundedWord("Swiss Alps"))
        #expect(c.ungroundedTitleFailure("Swiss Alps", for: trip)
                == .noGroundedWord("Swiss Alps"))
        #expect(c.titleWordsAreGrounded("Renens & Bellinzona", for: trip))
    }

    @Test("island feature words are corroborated by island stays, not by city-only trips")
    func islandWordsNeedIslandStays() throws {
        let (c, athensTrip) = try makeTrip([
            (metro: "Athens", island: nil, locality: "Athens", admin: nil, iso: "GR", country: "Greece")
        ])
        // GR is visited (the demonym would corroborate) but no stay has an
        // islandName; the false "Islands" claim rejects regardless.
        #expect(!c.titleWordsAreGrounded("Greek Islands", for: athensTrip))
    }

    // MARK: - Abbreviation seeding

    @Test("NYC/NY allowed only when New York is present in the allowed set")
    func nycAbbreviationAllowedWhenNewYorkPresent() throws {
        let (c, trip) = try makeTrip([
            (metro: "White Plains", island: nil, locality: "Scarsdale", admin: nil, iso: "US", country: "United States"),
            (metro: "New York", island: nil, locality: "New York", admin: nil, iso: "US", country: "United States"),
        ])
        #expect(c.titleWordsAreGrounded("White Plains & NYC", for: trip))

        // Without a New York stay, NYC is rejected.
        let (c2, trip2) = try makeTrip([
            (metro: "White Plains", island: nil, locality: "Scarsdale", admin: nil, iso: "US", country: "United States")
        ])
        #expect(!c2.titleWordsAreGrounded("White Plains & NYC", for: trip2))
    }

    @Test("LA allowed only when Los Angeles is present in the allowed set")
    func laAbbreviationAllowedWhenLosAngelesPresent() throws {
        let (c, trip) = try makeTrip([
            (metro: "Los Angeles", island: nil, locality: "Florence-Graham", admin: nil, iso: "US", country: "United States")
        ])
        #expect(c.titleWordsAreGrounded("LA", for: trip))

        let (c2, trip2) = try makeTrip([
            (metro: "White Plains", island: nil, locality: "White Plains", admin: nil, iso: "US", country: "United States")
        ])
        #expect(!c2.titleWordsAreGrounded("LA", for: trip2))
    }

    // MARK: - Forbidden country hard reject

    @Test("a forbidden country word is hard-rejected even when a stay's locality contains it")
    func forbiddenCountryWordHardRejectedEvenIfInStayName() throws {
        // Stale-locality residue: locality literally "Greece" for a GR stay.
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: "Greece", admin: nil, iso: "GR", country: "Greece")
        ])
        #expect(!c.titleWordsAreGrounded("Greece", for: trip))
    }

    @Test("the forbidden-country check runs before allowed/connector; a forbidden word is rejected regardless")
    func forbiddenCountryWordRejectedOverConnector() throws {
        // "France" is the stay's country (forbidden) AND appears in the locality.
        let (c, trip) = try makeTrip([
            (metro: "Paris", island: nil, locality: "France", admin: nil, iso: "FR", country: "France")
        ])
        // A title that mixes a grounded city with the forbidden country word still fails.
        #expect(!c.titleWordsAreGrounded("Paris & France", for: trip))
    }

    @Test("a city whose name contains its country's name is grounded as a whole name")
    func countryWordInsideCityNameGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: "Mexico City", island: nil, locality: "Mexico City", admin: nil, iso: "MX", country: "Mexico")
        ])
        #expect(c.titleWordsAreGrounded("Mexico City", for: trip))
        #expect(c.titleValidationFailure("Mexico City", for: trip) == nil)
        // The bare country and a trailing country residue still reject.
        #expect(c.ungroundedTitleFailure("Mexico", for: trip) == .forbiddenCountryWord("mexico"))
        #expect(!c.titleWordsAreGrounded("Mexico City, Mexico", for: trip))

        let (c2, trip2) = try makeTrip([
            (metro: nil, island: nil, locality: "San Salvador", admin: nil, iso: "SV", country: "El Salvador")
        ])
        #expect(c2.titleWordsAreGrounded("San Salvador", for: trip2))

        let (c3, trip3) = try makeTrip([
            (metro: nil, island: nil, locality: "New Plymouth", admin: nil, iso: "NZ", country: "New Zealand")
        ])
        #expect(c3.titleWordsAreGrounded("New Plymouth", for: trip3))
    }

    @Test("a multi-place trip led by a country-named city validates and falls back")
    func countryWordCityLeadsMultiPlaceTitle() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let trip = Trip(startDate: start)
        context.insert(trip)
        let specs: [(metro: String?, locality: String, days: Double)] = [
            (metro: "Mexico City", locality: "Mexico City", days: 5),
            (metro: nil, locality: "Oaxaca", days: 2),
        ]
        var cursor = start
        for (i, s) in specs.enumerated() {
            let end = cursor.addingTimeInterval(s.days * 86_400)
            let stay = Stay(startTime: cursor, endTime: end,
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.metroName = s.metro
            stay.locality = s.locality
            stay.isoCountryCode = "MX"
            stay.country = "Mexico"
            stay.category = .destination
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
            cursor = end
        }
        #expect(classifier.titleValidationFailure("Mexico City & Oaxaca", for: trip) == nil)
        #expect(classifier.computeFallbackTitle(for: trip) == "Mexico City & Oaxaca")
    }

    @Test("a city-state's country word (Singapore) is grounded; exemption flows through the validator")
    func cityStateCountryWordGroundedWhenExempted() throws {
        let (c, trip) = try makeTrip([
            (metro: "Singapore", island: nil, locality: "Singapore", admin: nil, iso: "SG", country: "Singapore")
        ])
        #expect(c.titleWordsAreGrounded("Singapore", for: trip))
    }

    // MARK: - Transit grounding (July-2026: destination stays only)

    /// Category-aware variant of `makeTrip` for the transit-grounding rules
    /// (the base helper leaves every stay `.unclassified`, which exercises
    /// the no-destination fallback path; see below).
    private func makeCategorizedTrip(
        _ specs: [(locality: String, category: StayCategory, iso: String, country: String)]
    ) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, s) in specs.enumerated() {
            let stay = Stay(startTime: .now, endTime: .now,
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.locality = s.locality
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.category = s.category
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
        }
        return (classifier, trip)
    }

    @Test("a transit-only location does not ground a title when the trip has destinations")
    func transitOnlyLocationRejected() throws {
        let (c, trip) = try makeCategorizedTrip([
            (locality: "Paris", category: .destination, iso: "FR", country: "France"),
            (locality: "Alès", category: .transit, iso: "FR", country: "France"),
        ])
        #expect(!c.titleWordsAreGrounded("Alès", for: trip))
        #expect(!c.titleWordsAreGrounded("Paris & Alès", for: trip))
        #expect(c.titleWordsAreGrounded("Paris", for: trip))
    }

    @Test("a location that is BOTH transit and destination grounds via its destination stay")
    func transitPlusDestinationLocationGrounded() throws {
        let (c, trip) = try makeCategorizedTrip([
            (locality: "Milan", category: .transit, iso: "IT", country: "Italy"),
            (locality: "Florence", category: .destination, iso: "IT", country: "Italy"),
            (locality: "Milan", category: .destination, iso: "IT", country: "Italy"),
        ])
        #expect(c.titleWordsAreGrounded("Milan & Florence", for: trip))
    }

    @Test("an all-transit trip falls back to grounding on every stay (mirrors the prompt's fallback)")
    func allTransitTripFallsBackToAllStays() throws {
        let (c, trip) = try makeCategorizedTrip([
            (locality: "Alès", category: .transit, iso: "FR", country: "France")
        ])
        #expect(c.titleWordsAreGrounded("Alès", for: trip))
    }

    @Test("a transit stay's ISO code does not ground a title when destinations exist")
    func transitIsoCodeNotGrounded() throws {
        // Destination in France, transit in Germany: "DE" must not ground.
        let (c, trip) = try makeCategorizedTrip([
            (locality: "Paris", category: .destination, iso: "FR", country: "France"),
            (locality: "Cologne", category: .transit, iso: "DE", country: "Germany"),
        ])
        #expect(!c.titleWordsAreGrounded("DE Tour", for: trip))
        #expect(c.titleWordsAreGrounded("FR Tour", for: trip))
    }

    // MARK: - Case sensitivity + empty trip

    @Test("matching is case-insensitive on both sides")
    func caseInsensitiveMatching() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: "Paris", admin: nil, iso: "FR", country: "France")
        ])
        #expect(c.titleWordsAreGrounded("PARIS", for: trip))
        #expect(c.titleWordsAreGrounded("paris", for: trip))
    }

    @Test("a trip with no stays grounds nothing (place words and bare connectors alike)")
    func emptyTripWithNoStaysRejectsAnyPlaceWord() throws {
        let (c, trip) = try makeTrip([])
        #expect(!c.titleWordsAreGrounded("Paris", for: trip))
        // A pure-connector title names no place either.
        #expect(c.ungroundedTitleFailure("Tour", for: trip) == .noGroundedWord("Tour"))
    }

    // MARK: - Home-named stays

    @Test("a home-named destination stops grounding its name once another destination exists")
    func homeNamedStayDoesNotGround() throws {
        let (c, trip) = try makeTrip([
            (metro: "Athens", island: nil, locality: "Agia Kyriakií Spáton", admin: "Attica", iso: "GR", country: "Greece"),
            (metro: nil, island: "Aegina", locality: "Kypséli", admin: nil, iso: "GR", country: "Greece"),
        ])
        for stay in trip.orderedStays { stay.category = .destination }

        #expect(c.ungroundedTitleFailure("Aegina & Athens", for: trip, homePlaceNames: ["athens"])
                == .homePlaceWord("athens"))
        #expect(c.ungroundedTitleFailure("Aegina & Agia Kyriakií Spáton", for: trip, homePlaceNames: ["athens"])
                == .homePlaceWord("agia"))
        #expect(c.titleWordsAreGrounded("Aegina", for: trip, homePlaceNames: ["athens"]))
        // Without the home set the old grounding stands.
        #expect(c.titleWordsAreGrounded("Aegina & Athens", for: trip))
    }

    @Test("a trip made only of home-named stays still grounds the home name")
    func homeOnlyTripStillGrounds() throws {
        let (c, trip) = try makeTrip([
            (metro: "Athens", island: nil, locality: "Agios Dimitrios", admin: "Attica", iso: "GR", country: "Greece"),
        ])
        for stay in trip.orderedStays { stay.category = .destination }
        #expect(c.titleWordsAreGrounded("Athens", for: trip, homePlaceNames: ["athens"]))
    }

    @Test("a word shared by a home-named stay and a real destination stays grounded")
    func sharedWordStaysGrounded() throws {
        let (c, trip) = try makeTrip([
            (metro: "New York", island: nil, locality: "Brooklyn", admin: nil, iso: "US", country: "United States"),
            (metro: nil, island: nil, locality: "York", admin: nil, iso: "GB", country: "United Kingdom"),
        ])
        for stay in trip.orderedStays { stay.category = .destination }
        #expect(c.titleWordsAreGrounded("York", for: trip, homePlaceNames: ["new york"]))
        #expect(c.ungroundedTitleFailure("New York", for: trip, homePlaceNames: ["new york"])
                == .homePlaceWord("new"))
    }
}
