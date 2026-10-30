//
//  TitleCandidateTests.swift
//  TravelLogTests
//
//  Title candidates and alternatives: which places a trip may be named
//  after (`TripTitlePolicy.rankedTitleCandidates`), in what rank, and the
//  titles composed from them (`TripTitlePolicy.titleAlternatives`):
//    • transit stays are left out (only destinations are title candidates),
//      except for the all-transit trip, which offers every group and no title
//    • airport-area destinations are left out while another destination exists,
//      and name a trip that has no other
//    • on a trip with no away destination, a home-named stay is named by its
//      first layer that is not home
//    • the list is ranked by time spent, then stays, then first visit,
//      same-name groups merged
//    • bare-country names never appear
//    • a title names the best-ranked places in visit order, a base holding two
//      thirds of their time first, and the display fallback names the same places
//  The trip is read on the main actor; `runIsolated` cases read it on the actor.
//
//  `@MainActor` because it constructs @Model Stay/Trip + instantiates the @ModelActor.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleCandidateTests {

    private typealias StaySpec = (
        offset: Int, order: Int,
        metro: String?, island: String?, locality: String?,
        category: StayCategory, isAirport: Bool,
        iso: String?, country: String?,
        minutes: Int, region: String?
    )

    private nonisolated func baseDate(_ offsetMinutes: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
        return day.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    /// Returns (classifier, trip). `endDateOffset` nil leaves the trip open.
    /// Nonisolated, so the trip is not main-actor state: each test hands it
    /// to the classifier once and never touches it again.
    private nonisolated func makeTrip(_ specs: [StaySpec], endDateOffset: Int? = nil) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        return (classifier, insertTrip(specs, endDateOffset: endDateOffset, into: container))
    }

    /// Builds the trip in a fresh context on `container`. Tests that read the
    /// trip again after an actor call build it inside `runIsolated` with this.
    private nonisolated func insertTrip(
        _ specs: [StaySpec], endDateOffset: Int? = nil, into container: ModelContainer
    ) -> Trip {
        let context = ModelContext(container)

        let trip = Trip(startDate: baseDate(0))
        if let e = endDateOffset { trip.endDate = baseDate(e) }
        context.insert(trip)
        for (i, s) in specs.enumerated() {
            let start = baseDate(s.offset)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(Double(s.minutes) * 60),
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.durationMinutes = s.minutes
            stay.metroName = s.metro
            stay.islandName = s.island
            stay.locality = s.locality
            stay.category = s.category
            stay.isAirport = s.isAirport
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.administrativeArea = s.region
            stay.orderInTrip = s.order
            stay.trip = trip
            context.insert(stay)
        }
        return trip
    }

    private nonisolated func ranked(_ trip: Trip, home: Set<String> = []) -> TripTitlePolicy.RankedTitleCandidates {
        TripTitlePolicy.rankedTitleCandidates(
            stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: home)
    }

    private nonisolated func names(_ trip: Trip, home: Set<String> = []) -> [String] {
        ranked(trip, home: home).groups.map(\.displayName)
    }

    private nonisolated func alternatives(_ trip: Trip, home: Set<String> = []) -> [String] {
        TripTitlePolicy.titleAlternatives(
            stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: home)
    }

    // MARK: - What is and is not offered

    @Test("a non-airport transit stay is never a candidate")
    func transitStayOmitted() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .destination, false, "FR", "France", 600, nil),
            (1000, 1, "Alès", nil, "Alès", .transit, false, "FR", "France", 100, nil),
        ])
        #expect(names(trip) == ["Paris"])
        #expect(alternatives(trip) == ["Paris"])
    }

    @Test("a place that is BOTH transit and destination stays a candidate via its destination stay")
    func transitPlusDestinationPlaceRemainsCandidate() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Milan", nil, "Milan", .transit, false, "IT", "Italy", 60, nil),
            (100, 1, "Florence", nil, "Florence", .destination, false, "IT", "Italy", 600, nil),
            (800, 2, "Milan", nil, "Milan", .destination, false, "IT", "Italy", 300, nil),
        ])
        #expect(names(trip) == ["Florence", "Milan"])
    }

    @Test("an airport-area destination is left out while another destination exists")
    func airportAreaDroppedBesideRealDestination() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .destination, true, "DE", "Germany", 1500, nil),
            (2000, 1, "Berlin", nil, "Berlin", .destination, false, "DE", "Germany", 600, nil),
        ])
        #expect(names(trip) == ["Berlin"])
        #expect(alternatives(trip) == ["Berlin"])
    }

    @Test("airport-area destinations name a trip that has no other destination")
    func airportAreaDestinationsNameAnAirportOnlyTrip() throws {
        let (_, airport) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .destination, true, "DE", "Germany", 1500, nil),
            (1600, 1, "Mainz", nil, "Mainz", .transit, false, "DE", "Germany", 60, nil),
            (1700, 2, "Wiesbaden", nil, "Wiesbaden", .destination, true, "DE", "Germany", 300, nil),
        ])
        #expect(names(airport) == ["Frankfurt", "Wiesbaden"])
        #expect(!ranked(airport).isTransitFallback)
        #expect(alternatives(airport) == ["Frankfurt & Wiesbaden", "Frankfurt"])
    }

    @Test("an all-transit trip offers its places but takes no title, airport-area or not")
    func transitFallbackHasNoTitle() throws {
        let (_, airport) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .transit, true, "DE", "Germany", 1500, nil)
        ])
        #expect(names(airport) == ["Frankfurt"])
        #expect(ranked(airport).isTransitFallback)
        #expect(alternatives(airport).isEmpty)
        let (_, transit) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .transit, false, "FR", "France", 120, nil),
            (200, 1, "Alès", nil, "Alès", .transit, false, "FR", "France", 60, nil),
        ])
        #expect(names(transit) == ["Paris", "Alès"])
        #expect(alternatives(transit).isEmpty)
    }

    @Test("a bare-country destination name is not offered")
    func bareCountryNotOffered() throws {
        let (_, trip) = try makeTrip([
            (0, 0, nil, nil, "Greece", .destination, false, "GR", "Greece", 600, nil)
        ])
        #expect(names(trip).isEmpty)
        #expect(alternatives(trip).isEmpty)
    }

    // MARK: - Home-area trips

    @Test("a trip that never leaves the home metro is named by the island it went to")
    func homeMetroIslandTakesIslandName() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Velmora", "Ostrel", "Dunvar", .destination, false, "QX", "Velandia", 600, nil),
            (700, 1, "Velmora", nil, "Velmora", .destination, false, "QX", "Velandia", 120, nil),
        ])
        #expect(names(trip, home: ["velmora"]) == ["Ostrel"])
        #expect(alternatives(trip, home: ["velmora"]) == ["Ostrel"])
        // Without the home set the metro names it.
        #expect(alternatives(trip) == ["Velmora"])
    }

    @Test("a trip to a town in the home metro is named by the town")
    func homeMetroTownTakesLocality() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Velmora", nil, "Kastrel", .destination, false, "QX", "Velandia", 600, nil),
        ])
        #expect(alternatives(trip, home: ["velmora"]) == ["Kastrel"])
        // A town that is home too leaves the home name.
        #expect(alternatives(trip, home: ["velmora", "kastrel"]) == ["Velmora"])
    }

    @Test("a trip with an away destination leaves its home-metro stays out, unchanged")
    func awayDestinationKeepsHomeExclusion() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Velmora", "Ostrel", "Dunvar", .destination, false, "QX", "Velandia", 600, nil),
            (700, 1, nil, nil, "Brask", .destination, false, "QX", "Velandia", 300, nil),
        ])
        #expect(names(trip, home: ["velmora"]) == ["Brask"])
        #expect(alternatives(trip, home: ["velmora"]) == ["Brask"])
    }

    // MARK: - Ranking and merging

    @Test("places rank by time spent, most first, and the title shows them in visit order")
    func placesRankedByTime() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Riehen", nil, "Riehen", .destination, false, "CH", "Switzerland", 360, nil),
            (400, 1, "Renens", nil, "Renens", .destination, false, "CH", "Switzerland", 2880, nil),
            (3400, 2, "Bellinzona", nil, "Bellinzona", .destination, false, "CH", "Switzerland", 2160, nil),
        ])
        #expect(names(trip) == ["Renens", "Bellinzona", "Riehen"])
        #expect(alternatives(trip).first == "Riehen, Renens & Bellinzona")
    }

    @Test("a place visited twice with something in between is one candidate with its stays and summed time")
    func sameNameGroupsMerge() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Athens", nil, "Athens", .destination, false, "GR", "Greece", 600, nil),
            (700, 1, "Mykonos", nil, "Mykonos", .destination, false, "GR", "Greece", 1440, nil),
            (2200, 2, "Athens", nil, "Athens", .destination, false, "GR", "Greece", 1200, nil),
        ])
        let groups = ranked(trip).groups
        #expect(groups.map(\.displayName) == ["Athens", "Mykonos"])
        #expect(groups.map(\.totalMinutes) == [1800, 1440])
        #expect(groups.map(\.stayCount) == [2, 1])
        #expect(alternatives(trip) == ["Athens & Mykonos", "Athens"])
    }

    @Test("metroName is preferred over islandName and locality for the candidate name")
    func metroPreferredForName() throws {
        let (_, trip) = try makeTrip([
            (0, 0, "Athens", "Salamina", "Gérakas", .destination, false, "GR", "Greece", 600, nil)
        ])
        #expect(names(trip) == ["Athens"])
    }

    @Test("exact ranking and titles across ties, scripts and unknown categories")
    func exactRankingAndTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway", 600, nil),
                // Ties Tromsø on time and stays: the earlier first visit ranks first.
                (700, 1, nil, nil, "Σύρος", .destination, false, "GR", "Greece", 600, nil),
                // Recategorized below to a raw value no case matches.
                (1400, 2, nil, nil, "Bodø", .destination, false, "NO", "Norway", 5000, nil),
                // No name at all: never offered, however long.
                (6500, 3, nil, nil, nil, .destination, false, nil, nil, 9000, nil),
                (15600, 4, "Athens", nil, "Athína", .destination, false, "GR", "Greece", 150, nil),
                (15800, 5, nil, nil, "Corinth", .destination, false, "GR", "Greece", 100, nil),
                (16000, 6, "Athens", nil, "Athína", .destination, false, "GR", "Greece", 150, nil),
                // Ties Athens on time with fewer stays.
                (16200, 7, nil, nil, "Nafplio", .destination, false, "GR", "Greece", 300, nil),
                // Same start: time, stays and first visit all tie.
                (16600, 8, nil, nil, "Sparti", .destination, false, "GR", "Greece", 100, nil),
                (16600, 9, nil, nil, "Mystras", .destination, false, "GR", "Greece", 100, nil),
            ], into: container)
            trip.orderedStays[2].categoryRaw = "bogus"
            #expect(names(trip) == ["Tromsø", "Σύρος", "Athens", "Nafplio", "Corinth", "Sparti", "Mystras"])
            #expect(c.titleAlternatives(for: trip) == ["Tromsø, Syros & Athens", "Tromsø & Syros", "Tromsø"])
            // Home names compare folded but keep ø, so only the second set names Tromsø.
            #expect(c.defaultTitle(for: trip, homePlaceNames: ["tromso"]) == "Tromsø, Syros & Athens")
            #expect(c.defaultTitle(for: trip, homePlaceNames: ["tromsø"]) == "Syros, Athens & Nafplio")
        }
    }

    @Test("an empty name is a missing one: an empty island leaves the locality, and a stay with no name is no place")
    func emptyNamesAreMissing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "", .destination, false, "GR", "", 300, nil),
                // An empty island no longer shadows the locality.
                (400, 1, nil, "", "Oia", .destination, false, "GR", "Greece", 200, nil),
                (700, 2, nil, nil, "Fira", .destination, false, "GR", nil, 100, nil),
            ], into: container)
            #expect(names(trip) == ["Oia", "Fira"])
            #expect(c.defaultTitle(for: trip) == "Oia & Fira")
        }
    }

    @Test("ranking regroups stays by start time, whatever their stored order")
    func rankingFollowsStartTime() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                // Stored first, visited later: its group starts at the earlier visit.
                (1200, 0, nil, nil, "Corinth", .destination, false, "GR", "Greece", 60, nil),
                (0, 1, nil, nil, "Corinth", .destination, false, "GR", "Greece", 60, nil),
                (600, 2, nil, nil, "Fira", .destination, false, "GR", "Greece", 120, nil),
                // Same start: the stored order breaks the tie, not insertion.
                (1800, 4, nil, nil, "Sparti", .destination, false, "GR", "Greece", 30, nil),
                (1800, 3, nil, nil, "Mystras", .destination, false, "GR", "Greece", 30, nil),
            ], into: container)
            #expect(names(trip) == ["Corinth", "Fira", "Mystras", "Sparti"])
            #expect(c.defaultTitle(for: trip) == "Corinth, Fira & Mystras")
            // A tie in minutes with the top place qualifies.
            #expect(c.titleValidationFailure("Fira", for: trip) == nil)
            #expect(c.titleValidationFailure("Sparti", for: trip) == .missingTopPlace("Corinth"))
        }
    }

    @Test("a base holding two thirds of the named places' time leads the title; a closer split keeps visit order")
    func baseLeadsTheTitle() throws {
        let (_, based) = try makeTrip([
            (0, 0, nil, nil, "Brask", .destination, false, "QX", "Velandia", 200, nil),
            (300, 1, nil, nil, "Velmora", .destination, false, "QX", "Velandia", 2400, nil),
            (2800, 2, nil, nil, "Ostrel", .destination, false, "QX", "Velandia", 300, nil),
        ])
        #expect(alternatives(based) == ["Velmora, Brask & Ostrel", "Velmora & Ostrel", "Velmora"])
        let (_, split) = try makeTrip([
            (0, 0, nil, nil, "Brask", .destination, false, "QX", "Velandia", 470, nil),
            (500, 1, nil, nil, "Velmora", .destination, false, "QX", "Velandia", 530, nil),
        ])
        #expect(alternatives(split) == ["Brask & Velmora", "Velmora"])
    }

    // MARK: - composeTitle (pure)

    @Test("composeTitle joins one, two, and three places; blanks and duplicates collapse; the cap is three")
    func composeTitleJoins() {
        #expect(TripTitlePolicy.composeTitle(places: ["Paris"]) == "Paris")
        #expect(TripTitlePolicy.composeTitle(places: ["White Plains", "New York"]) == "White Plains & New York")
        #expect(TripTitlePolicy.composeTitle(places: ["Munich", "Löbtau", "Klagenfurt am Wörthersee"]) == "Munich, Löbtau & Klagenfurt am Wörthersee")
        #expect(TripTitlePolicy.composeTitle(places: [" Aegina ", "", "aegina", "Kypséli"]) == "Aegina & Kypséli")
        #expect(TripTitlePolicy.composeTitle(places: ["A", "B", "C", "D"]) == "A, B & C")
        #expect(TripTitlePolicy.composeTitle(places: []) == "")
    }

    // MARK: - Spelling

    @Test("titles store each place in its stored spelling")
    func titlesUseStoredSpelling() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway", 2000, nil),
                (2100, 1, nil, nil, "Bodø", .destination, false, "NO", "Norway", 300, nil),
                (2500, 2, "Ioánnina", nil, "Ioánnina", .destination, false, "GR", "Greece", 200, nil),
                (2800, 3, "Κοντακαίικα", nil, "Κοντακαίικα", .destination, false, "GR", "Greece", 100, nil),
            ], into: container)
            let titles = c.titleAlternatives(for: trip)
            #expect(titles == ["Tromsø, Bodø & Ioannina", "Tromsø & Bodø", "Tromsø"])
            for title in titles {
                #expect(c.titleValidationFailure(title, for: trip) == nil)
            }
        }
    }

    // MARK: - Alternatives

    @Test("a one-place trip has one title and nothing else to offer")
    func onePlaceTripHasNoAlternative() throws {
        let (_, trip) = try makeTrip([
            (0, 0, nil, nil, "Wrocław", .destination, false, "PL", "Poland", 600, "Lower Silesia"),
        ])
        #expect(alternatives(trip) == ["Wrocław"])
    }

    @Test("a shared region is offered last when every place lies in it")
    func sharedRegionIsLastAlternative() throws {
        let (_, trip) = try makeTrip([
            (0, 0, nil, nil, "Arvena", .destination, false, "GR", "Greece", 900, "Delvaria"),
            (1000, 1, nil, nil, "Belmora", .destination, false, "GR", "Greece", 300, "Delvaria"),
            (1400, 2, nil, nil, "Corvala", .destination, false, "GR", "Greece", 600, "Delvaria"),
            // A transit stay elsewhere never decides the region.
            (2100, 3, "Athens", nil, "Athens", .transit, false, "GR", "Greece", 60, "Attica"),
        ])
        #expect(alternatives(trip) == [
            "Arvena, Belmora & Corvala", "Arvena & Corvala", "Arvena", "Delvaria",
        ])
    }

    @Test("no region is offered when the places differ in region, lack one, or the region is a country, a place or home")
    func regionNeedsOneSharedEligibleName() throws {
        let (_, mixed) = try makeTrip([
            (0, 0, nil, nil, "Arvena", .destination, false, "GR", "Greece", 900, "Delvaria"),
            (1000, 1, nil, nil, "Estrona", .destination, false, "GR", "Greece", 300, "North Estria"),
        ])
        #expect(alternatives(mixed) == ["Arvena & Estrona", "Arvena"])
        let (_, missing) = try makeTrip([
            (0, 0, nil, nil, "Arvena", .destination, false, "GR", "Greece", 900, "Delvaria"),
            (1000, 1, nil, nil, "Belmora", .destination, false, "GR", "Greece", 300, nil),
        ])
        #expect(alternatives(missing) == ["Arvena & Belmora", "Arvena"])
        let (_, country) = try makeTrip([
            (0, 0, nil, nil, "Esch-sur-Alzette", .destination, false, "LU", "Luxembourg", 900, "Luxembourg"),
            (1000, 1, nil, nil, "Dudelange", .destination, false, "LU", "Luxembourg", 300, "Luxembourg"),
        ])
        #expect(alternatives(country) == ["Esch-sur-Alzette & Dudelange", "Esch-sur-Alzette"])
        let (_, place) = try makeTrip([
            (0, 0, nil, nil, "Madrid", .destination, false, "ES", "Spain", 900, "Madrid"),
            (1000, 1, nil, nil, "Alcalá de Henares", .destination, false, "ES", "Spain", 300, "Madrid"),
        ])
        #expect(alternatives(place) == ["Madrid & Alcala de Henares", "Madrid"])
        let (_, home) = try makeTrip([
            (0, 0, nil, nil, "Getafe", .destination, false, "ES", "Spain", 900, "Madrid"),
            (1000, 1, nil, nil, "Alcalá de Henares", .destination, false, "ES", "Spain", 300, "Madrid"),
        ])
        #expect(alternatives(home, home: ["madrid"]) == ["Getafe & Alcala de Henares", "Getafe"])
    }

    // MARK: - One order rule

    @Test("the title and the display fallback name the same places in the same order")
    func titleAndDisplayFallbackAgree() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                // Ties Bern on time, visited first, but with fewer stays: the
                // stay count drops it, in the title and the summary alike.
                (0, 0, nil, nil, "Lugano", .destination, false, "CH", "Switzerland", 600, nil),
                (700, 1, nil, nil, "Riehen", .destination, false, "CH", "Switzerland", 900, nil),
                (1700, 2, nil, nil, "Bern", .destination, false, "CH", "Switzerland", 300, nil),
                (2100, 3, nil, nil, "Renens", .destination, false, "CH", "Switzerland", 2880, nil),
                (5100, 4, nil, nil, "Bern", .destination, false, "CH", "Switzerland", 300, nil),
            ], into: container)
            trip.recomputeSummary()
            let title = c.defaultTitle(for: trip)
            #expect(title == "Riehen, Bern & Renens")
            #expect(Trip.curatedJoin(trip.destinationSummary, languageTag: "en") == title)
        }
    }

}
