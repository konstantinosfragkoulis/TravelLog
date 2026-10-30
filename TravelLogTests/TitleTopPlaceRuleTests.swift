//
//  TitleTopPlaceRuleTests.swift
//  TravelLogTests
//
//  Rank-1 rule (2026-09-04): a multi-place title must include the place
//  with the most time on the trip. `TripClassifier.missingTopPlaceFailure`
//  runs after grounding in `titleValidationFailure`, so every word it sees
//  is already a visited place; it only narrows the selection. Pure (reads
//  `trip.orderedStays`), so the trips are built in memory.
//
//  `@MainActor` because it constructs @Model Stay/Trip and instantiates the
//  @ModelActor TripClassifier (app is MainActor-by-default).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleTopPlaceRuleTests {

    /// One stay: where it is, how long it lasted, what it is.
    private struct StaySpec {
        var locality: String?
        var island: String? = nil
        var metro: String? = nil
        var hours: Double
        var category: StayCategory = .destination
        var iso: String = "GR"
        var country: String = "Greece"
    }

    private func makeTrip(_ specs: [StaySpec]) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 822_377_600)
        let trip = Trip(startDate: start)
        context.insert(trip)
        var cursor = start
        for (i, s) in specs.enumerated() {
            let end = cursor.addingTimeInterval(s.hours * 3600)
            let stay = Stay(startTime: cursor, endTime: end,
                            centroidLatitude: 37, centroidLongitude: 25,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 150, pingIDs: [])
            stay.locality = s.locality
            stay.islandName = s.island
            stay.metroName = s.metro
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.category = s.category
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
            cursor = end.addingTimeInterval(3600)
        }
        return (classifier, trip)
    }

    /// Cephalonia carries four days, Samos one: Cephalonia is rank 1.
    private func twoIslandTrip() throws -> (TripClassifier, Trip) {
        try makeTrip([
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 96),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 24),
        ])
    }

    @Test("a title naming only the second place is rejected and names the missing top place")
    func secondPlaceAloneIsRejected() throws {
        let (c, trip) = try twoIslandTrip()
        #expect(c.missingTopPlaceFailure("Samos", for: trip) == .missingTopPlace("Cephalonia"))
        #expect(c.titleValidationFailure("Samos", for: trip) == .missingTopPlace("Cephalonia"))
    }

    @Test("a title that includes the top place passes, alone or with others")
    func topPlaceIncludedPasses() throws {
        let (c, trip) = try twoIslandTrip()
        #expect(c.missingTopPlaceFailure("Cephalonia", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Cephalonia & Samos", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Samos & Cephalonia", for: trip) == nil)
        #expect(c.titleValidationFailure("Samos & Cephalonia", for: trip) == nil)
    }

    @Test("the deterministic fallback title always satisfies the rule")
    func fallbackTitleSatisfiesRule() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Kypséli", island: nil, hours: 2),
            StaySpec(locality: "Chora", island: "Aegina", hours: 72),
            StaySpec(locality: "Skála", island: nil, hours: 5),
        ])
        let fallback = try #require(c.defaultTitle(for: trip))
        #expect(fallback.contains("Aegina"))
        #expect(c.missingTopPlaceFailure(fallback, for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Kypséli", for: trip) == .missingTopPlace("Aegina"))
    }

    @Test("ranking counts total time, not stay count: many short stays lose to one long stay")
    func rankIsByTotalMinutes() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 3),
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 60),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 3),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 3),
        ])
        #expect(c.missingTopPlaceFailure("Samos", for: trip) == .missingTopPlace("Cephalonia"))
        #expect(c.missingTopPlaceFailure("Cephalonia", for: trip) == nil)
    }

    @Test("a single-place trip has nothing to miss")
    func singlePlaceTripPasses() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 96),
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 10),
        ])
        #expect(c.missingTopPlaceFailure("Cephalonia", for: trip) == nil)
    }

    @Test("transit stays never become the top place")
    func transitStaysAreIgnored() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Agios Dimitrios", metro: "Athens", hours: 30, category: .transit),
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 20),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 8),
        ])
        #expect(c.missingTopPlaceFailure("Cephalonia & Samos", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Samos", for: trip) == .missingTopPlace("Cephalonia"))
    }

    @Test("an all-transit trip is exempt")
    func allTransitTripIsExempt() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Agios Dimitrios", metro: "Athens", hours: 5, category: .transit),
            StaySpec(locality: "Agia Kyriakií Spáton", hours: 3, category: .transit),
        ])
        #expect(c.missingTopPlaceFailure("Agia Kyriakií Spáton", for: trip) == nil)
    }

    @Test("a home-named top place is excluded from the ranking")
    func homeNamedStaysAreExcluded() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Gérakas", metro: "Athens", hours: 200),
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 40),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 10),
        ])
        let home: Set<String> = [TripTitleStore.normalizedPlaceName("Athens")]
        #expect(c.missingTopPlaceFailure("Cephalonia & Samos", for: trip, homePlaceNames: home) == nil)
        #expect(c.missingTopPlaceFailure("Samos", for: trip, homePlaceNames: home) == .missingTopPlace("Cephalonia"))
    }

    @Test("the permitted abbreviations count as the full name")
    func abbreviationsCount() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Manhattan", metro: "New York", hours: 100, iso: "US", country: "United States"),
            StaySpec(locality: "White Plains", metro: "White Plains", hours: 30, iso: "US", country: "United States"),
        ])
        #expect(c.missingTopPlaceFailure("NYC & White Plains", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("White Plains", for: trip) == .missingTopPlace("New York"))
        let (c2, la) = try makeTrip([
            StaySpec(locality: "Florence-Graham", metro: "Los Angeles", hours: 100, iso: "US", country: "United States"),
            StaySpec(locality: "San Diego", metro: "San Diego", hours: 30, iso: "US", country: "United States"),
        ])
        #expect(c2.missingTopPlaceFailure("LA & San Diego", for: la) == nil)
    }

    @Test("a lone abbreviation names its multi-word top place")
    func loneAbbreviationNamesTopPlace() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Manhattan", metro: "New York", hours: 100, iso: "US", country: "United States"),
            StaySpec(locality: "White Plains", metro: "White Plains", hours: 30, iso: "US", country: "United States"),
        ])
        for title in ["NYC", "NY"] {
            #expect(c.missingTopPlaceFailure(title, for: trip) == nil, "\(title)")
            #expect(c.titleValidationFailure(title, for: trip) == nil, "\(title)")
        }
        #expect(c.titleValidationFailure("White Plains", for: trip) == .missingTopPlace("New York"))

        let (c2, la) = try makeTrip([
            StaySpec(locality: "Florence-Graham", metro: "Los Angeles", hours: 100, iso: "US", country: "United States"),
            StaySpec(locality: "San Diego", metro: "San Diego", hours: 30, iso: "US", country: "United States"),
        ])
        #expect(c2.missingTopPlaceFailure("LA", for: la) == nil)
        #expect(c2.titleValidationFailure("LA", for: la) == nil)
        #expect(c2.titleValidationFailure("San Diego", for: la) == .missingTopPlace("Los Angeles"))
    }

    @Test("an abbreviation still needs its city among the trip's places")
    func abbreviationWithoutItsCityIsUngrounded() throws {
        let (c, trip) = try twoIslandTrip()
        #expect(c.titleValidationFailure("NYC", for: trip) == .ungroundedWord("nyc"))
        #expect(c.titleValidationFailure("LA", for: trip) == .ungroundedWord("la"))
    }

    @Test("a multi-word top place must appear whole")
    func multiWordTopPlace() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Agios Nikolaos", island: nil, hours: 100),
            StaySpec(locality: "Elounda", island: nil, hours: 20),
        ])
        #expect(c.missingTopPlaceFailure("Agios Nikolaos & Elounda", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Nikolaos & Elounda", for: trip) == .missingTopPlace("Agios Nikolaos"))
    }

    @Test("a different place that shares a word with the top place does not count as naming it")
    func sharedWordIsNotTheTopPlace() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Manhattan", metro: "New York", hours: 100, iso: "US", country: "United States"),
            StaySpec(locality: "New Orleans", metro: "New Orleans", hours: 30, iso: "US", country: "United States"),
            StaySpec(locality: "York", hours: 10, iso: "GB", country: "United Kingdom"),
        ])
        #expect(c.missingTopPlaceFailure("New Orleans & York", for: trip) == .missingTopPlace("New York"))
        #expect(c.missingTopPlaceFailure("New York & York", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("NYC & New Orleans", for: trip) == nil)
    }

    @Test("places tied for the most time all satisfy the rule")
    func tiedTopPlacesBothPass() throws {
        let (c, trip) = try makeTrip([
            StaySpec(locality: "Cephalonia", island: "Cephalonia", hours: 48),
            StaySpec(locality: "Ydroússa", island: "Samos", hours: 48),
            StaySpec(locality: "Antiparos", island: "Antiparos", hours: 5),
        ])
        #expect(c.missingTopPlaceFailure("Cephalonia", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Samos", for: trip) == nil)
        #expect(c.missingTopPlaceFailure("Antiparos", for: trip) == .missingTopPlace("Cephalonia"))
    }
}
