//
//  TitleFallbackTests.swift
//  TravelLogTests
//
//  The deterministic default title: TripClassifier.defaultTitle(for:), the
//  title every trip is given. Algorithm:
//    1. drop isAirport && transit stays (keep chronological if all drop)
//    2. buildGroups collapse (adjacent same displayName + category + airport flag)
//    3. keep only category == .destination && !isAirport groups (airport-area
//       destinations when no other destination remains)
//    3b. drop home-named groups (TripTitleStore.homePlaceNames) unless nothing else remains
//    4. merge same-name groups, rank by totalMinutes desc (tiebreaks stayCount, firstDate), take top 3
//    5. re-sort top 3 chronologically by firstDate, a base with two thirds of their time first
//    6. dedupe by displayName (order-preserving), drop "Unknown" + bare-country
//    7. format 1 → "A" / 2 → "A & B" / 3+ → "A, B & C"
//  A composition the title policy rejects gives way to the next one with fewer
//  places. Returns nil for all-transit, all-Unknown, or
//  all-bare-country trips. displayName = metroName ?? islandName ?? locality ?? "Unknown".
//  Pure → tested synchronously through the nonisolated defaultTitle adapter
//  over TripTitlePolicy.defaultTitle.
//
//  `@MainActor` because it constructs @Model Stay/Trip + instantiates the @ModelActor.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite(IsolatedTitleDefaults())
struct TitleFallbackTests {

    /// One stay spec: chronological offset (minutes), order index, display name fields,
    /// category, airport flag, and iso/country (for bare-country filtering).
    private typealias StaySpec = (
        offset: Int, order: Int,
        metro: String?, island: String?, locality: String?,
        category: StayCategory, isAirport: Bool,
        iso: String?, country: String?
    )

    private func baseDate(_ offsetMinutes: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 2, day: 20, hour: 12))!
        return day.addingTimeInterval(Double(offsetMinutes) * 60)
    }

    private func makeTrip(_ specs: [StaySpec]) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: baseDate(0))
        context.insert(trip)
        for (i, s) in specs.enumerated() {
            let start = baseDate(s.offset)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3600),
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.metroName = s.metro
            stay.islandName = s.island
            stay.locality = s.locality
            stay.category = s.category
            stay.isAirport = s.isAirport
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.orderInTrip = s.order
            stay.trip = trip
            context.insert(stay)
        }
        try context.save()
        return (classifier, trip)
    }

    @Test("the title keeps letters outside ASCII and still validates")
    func fallbackKeepsStoredSpelling() throws {
        let (one, tromso) = try makeTrip([
            (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway"),
        ])
        #expect(one.defaultTitle(for: tromso) == "Tromsø")

        let (two, arctic) = try makeTrip([
            (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway"),
            (120, 1, nil, nil, "Bodø", .destination, false, "NO", "Norway"),
        ])
        #expect(two.defaultTitle(for: arctic) == "Tromsø & Bodø")

        // Imported names in other spellings store the geocoder's form.
        let (imported, mixed) = try makeTrip([
            (0, 0, nil, "Σύρος", "Σύρος", .destination, false, "GR", "Greece"),
            (120, 1, nil, nil, "Köniz", .destination, false, "CH", "Switzerland"),
        ])
        #expect(imported.defaultTitle(for: mixed) == "Syros & Koniz")
    }

    @Test("titles and place names normalize identically before grounding")
    func groundingNormalizesTitleLikeVocabulary() throws {
        let (c, trip) = try makeTrip([
            (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway"),
        ])
        #expect(c.titleWordsAreGrounded("Tromsø", for: trip))
        #expect(c.titleWordsAreGrounded("Tromso", for: trip))
        // The letter the old prompt transform deleted no longer grounds.
        #expect(!c.titleWordsAreGrounded("Troms", for: trip))
        #expect(c.titleValidationFailure("Troms", for: trip) == .ungroundedWord("troms"))
    }

    @Test("country-named islands use visited localities in titles")
    func countryIslandsUseLocalities() throws {
        for (iso, country, cities) in [("CY", "Cyprus", ["Limassol", "Paphos"]),
                                       ("MT", "Malta", ["Valletta", "Mdina"])] {
            let (classifier, trip) = try makeTrip([
                (0, 0, nil, country, cities[0], .destination, false, iso, country),
                (100, 1, nil, country, cities[1], .destination, false, iso, country),
            ])
            let title = "\(cities[0]) & \(cities[1])"
            #expect(classifier.defaultTitle(for: trip) == title)
            #expect(classifier.titleValidationFailure(title, for: trip) == nil)
        }
    }

    @Test("country-island locality fallback preserves metro priority and country rejection")
    func countryIslandFallbackBoundaries() throws {
        let (classifier, trip) = try makeTrip([
            (0, 0, "Valletta", "Malta", "Floriana", .destination, false, "MT", "Malta"),
        ])
        #expect(classifier.defaultTitle(for: trip) == "Valletta")
        let (missingClassifier, missingTrip) = try makeTrip([
            (0, 0, nil, "Cyprus", nil, .destination, false, "CY", "Cyprus"),
        ])
        #expect(missingClassifier.defaultTitle(for: missingTrip) == nil)
    }

    // MARK: - Basic formatting

    @Test("a single destination group returns the bare name")
    func singleDestinationReturnsBareName() throws {
        let (c, trip) = try makeTrip([
            (0, 0, nil, "Syros", "Ermoúpolis", .destination, false, "GR", "Greece")
        ])
        #expect(c.defaultTitle(for: trip) == "Syros")
    }

    @Test("a title rejected by title validation is never stored")
    func invalidTitleIsNotStored() async throws {
        let longName = "Fraccionamiento Nuevo Orizatlan (Fraccionamiento Magisterial)"
        let (classifier, trip) = try makeTrip([
            (0, 0, nil, nil, longName, .destination, false, "MX", "Mexico")
        ])
        let tripID = trip.id
        #expect(await classifier.generateTitlesStage(maxTripsPerCall: nil) == 0)
        #expect(await classifier.ensureCanonicalTitle(for: tripID) == nil)
        let context = ModelContext(classifier.modelContainer)
        let stored = try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == tripID })).first
        #expect(stored?.aiGeneratedTitle == nil)
    }

    @Test("the default title is the first composition the title policy accepts, or none")
    func defaultTitleOutcomes() {
        func stay(_ locality: String, category: String = "destination", minutes: Int = 60, offset: Int = 0,
                  country: String = "Greece", iso: String = "GR") -> TripTitlePolicy.StayInput {
            TripTitlePolicy.StayInput(
                id: UUID(), orderInTrip: 0, startTime: baseDate(offset), endTime: baseDate(offset + minutes),
                durationMinutes: minutes, categoryRaw: category, isAirport: false,
                metroName: nil, islandName: nil, locality: locality,
                administrativeArea: nil, country: country, isoCountryCode: iso)
        }
        #expect(TripTitlePolicy.defaultTitle(stays: [stay("Corinth")], homePlaceNames: []) == "Corinth")
        #expect(TripTitlePolicy.defaultTitle(stays: [stay("Corinth", category: "transit")], homePlaceNames: []) == nil)
        #expect(TripTitlePolicy.defaultTitle(stays: [], homePlaceNames: []) == nil)
        let longName = "Fraccionamiento Nuevo Orizatlan (Fraccionamiento Magisterial)"
        #expect(TripTitlePolicy.defaultTitle(
            stays: [stay(longName, country: "Mexico", iso: "MX")], homePlaceNames: []) == nil)
        // Three long names pass 60 characters together; the best two do not.
        let stays = [
            stay("Agios Konstantinos Fthiotida", minutes: 300, offset: 0),
            stay("Kato Velmara Dorno", minutes: 200, offset: 400),
            stay("Nea Lindora Kavros", minutes: 100, offset: 700),
        ]
        #expect(TripTitlePolicy.defaultTitle(stays: stays, homePlaceNames: [])
            == "Agios Konstantinos Fthiotida & Kato Velmara Dorno")
    }

    @Test("two destinations join with ' & ' in chronological order")
    func twoDestinationsJoinedWithAmpersand() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Madrid", nil, "Madrid", .destination, false, "ES", "Spain"),
            (100, 1, "Barcelona", nil, "Barcelona", .destination, false, "ES", "Spain"),
        ])
        #expect(c.defaultTitle(for: trip) == "Madrid & Barcelona")
    }

    @Test("three destinations use comma + ' & ' before the last")
    func threeOrMoreDestinationsCommaAndAmpersand() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Munich", nil, "Munich", .destination, false, "DE", "Germany"),
            (100, 1, "Löbtau", nil, "Löbtau", .destination, false, "DE", "Germany"),
            (200, 2, "Klagenfurt am Wörthersee", nil, "Klagenfurt am Wörthersee", .destination, false, "AT", "Austria"),
        ])
        #expect(c.defaultTitle(for: trip) == "Munich, Lobtau & Klagenfurt am Worthersee")
    }

    // MARK: - Top-3-by-stayCount ranking

    @Test("with 4+ destinations only the top 3 by stayCount survive, then re-sorted chronologically")
    func topThreeByStayCountSelected() throws {
        // A: 5 stays (earliest), B: 3, C: 2, D: 1 (latest). D drops; A,B,C kept.
        // Chronological order A < B < C < D, so output is "A, B & C".
        var specs: [StaySpec] = []
        var order = 0
        var offset = 0
        // A x5
        for _ in 0..<5 { specs.append((offset, order, "Alpha", nil, "Alpha", .destination, false, "XA", "Aland")); order += 1; offset += 10 }
        // B x3
        for _ in 0..<3 { specs.append((offset, order, "Bravo", nil, "Bravo", .destination, false, "XB", "Bland")); order += 1; offset += 10 }
        // C x2
        for _ in 0..<2 { specs.append((offset, order, "Charlie", nil, "Charlie", .destination, false, "XC", "Cland")); order += 1; offset += 10 }
        // D x1
        specs.append((offset, order, "Delta", nil, "Delta", .destination, false, "XD", "Dland"))

        let (c, trip) = try makeTrip(specs)
        #expect(c.defaultTitle(for: trip) == "Alpha, Bravo & Charlie")
    }

    @Test("kept picks are re-sorted by firstDate so the highest-stayCount city can appear last")
    func topPicksResortedChronologically() throws {
        // Two destinations only. The dominant (more stays) one is chronologically LAST.
        // X: 2 stays early; Y: 3 stays later, short of a base's two thirds.
        // Both kept; output sorted by firstDate → "X & Y".
        var specs: [StaySpec] = []
        specs.append((0, 0, "Xanadu", nil, "Xanadu", .destination, false, "XX", "Xland"))
        specs.append((10, 1, "Xanadu", nil, "Xanadu", .destination, false, "XX", "Xland"))
        var offset = 100
        var order = 2
        for _ in 0..<3 { specs.append((offset, order, "Yonder", nil, "Yonder", .destination, false, "XY", "Yland")); order += 1; offset += 10 }

        let (c, trip) = try makeTrip(specs)
        #expect(c.defaultTitle(for: trip) == "Xanadu & Yonder")
    }

    // MARK: - nil cases

    @Test("an all-transit trip returns nil")
    func allTransitTripReturnsNil() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .transit, false, "FR", "France"),
            (100, 1, "Alès", nil, "Alès", .transit, false, "FR", "France"),
        ])
        #expect(c.defaultTitle(for: trip) == nil)
    }

    @Test("a destination group that is an airport names the trip when it's the only destination")
    func airportDestinationGroupsExcluded() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .destination, true, "DE", "Germany")
        ])
        #expect(c.defaultTitle(for: trip) == "Frankfurt")
    }

    @Test("airport-transit stays are pre-filtered before grouping; a real destination still titles")
    func airportTransitStaysPreFilteredBeforeGrouping() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .destination, false, "FR", "France"),
            (100, 1, "London", nil, "Heathrow", .transit, true, "GB", "United Kingdom"),
        ])
        #expect(c.defaultTitle(for: trip) == "Paris")
    }

    @Test("when every stay is airport-transit, the fallback keeps chronological but destinationGroups is empty → nil")
    func allAirportTransitFallbackKeepsChronological() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "London", nil, "Heathrow", .transit, true, "GB", "United Kingdom"),
            (100, 1, "Frankfurt", nil, "Frankfurt Airport", .transit, true, "DE", "Germany"),
        ])
        #expect(c.defaultTitle(for: trip) == nil)
    }

    @Test("a destination group whose displayName resolves to 'Unknown' is skipped → nil when all Unknown")
    func unknownDisplayNameGroupsSkipped() throws {
        let (c, trip) = try makeTrip([
            (0, 0, nil, nil, nil, .destination, false, "FR", "France")
        ])
        #expect(c.defaultTitle(for: trip) == nil)
    }

    @Test("a bare-country destination group is filtered; only a real city survives")
    func bareCountryGroupSkipped() throws {
        // Bare-country only → nil.
        let (c, trip) = try makeTrip([
            (0, 0, nil, nil, "Greece", .destination, false, "GR", "Greece")
        ])
        #expect(c.defaultTitle(for: trip) == nil)

        // Bare-country + real city → only the city survives.
        let (c2, trip2) = try makeTrip([
            (0, 0, nil, nil, "Greece", .destination, false, "GR", "Greece"),
            (100, 1, nil, "Mykonos", "Mykonos", .destination, false, "GR", "Greece"),
        ])
        #expect(c2.defaultTitle(for: trip2) == "Mykonos")
    }

    // MARK: - Dedupe + grouping

    @Test("a round trip (Athens → Mykonos → Athens) dedupes to 'Athens & Mykonos' in first-seen order")
    func roundTripDestinationDeduped() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", nil, "Athens", .destination, false, "GR", "Greece"),
            (100, 1, nil, "Mykonos", "Mykonos", .destination, false, "GR", "Greece"),
            (200, 2, "Athens", nil, "Athens", .destination, false, "GR", "Greece"),
        ])
        #expect(c.defaultTitle(for: trip) == "Athens & Mykonos")
    }

    @Test("metroName is preferred over islandName and locality for grouping/title")
    func metroNamePreferredOverIslandAndLocality() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", "SomeIsland", "Néa Pentéli", .destination, false, "GR", "Greece")
        ])
        #expect(c.defaultTitle(for: trip) == "Athens")
    }

    @Test("two adjacent same-name destination stays merge into one group (never 'Madrid & Madrid')")
    func adjacentSameNameStaysFormOneGroup() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Madrid", nil, "Madrid", .destination, false, "ES", "Spain"),
            (100, 1, "Madrid", nil, "Madrid", .destination, false, "ES", "Spain"),
        ])
        #expect(c.defaultTitle(for: trip) == "Madrid")
    }

    // MARK: - Home-named destinations (2026-09)

    @Test("a destination named like the home area is not a title candidate")
    func homeNamedGroupExcluded() throws {
        // Athens resident: the port wait at Agia Kyriakií Spáton carries metro "Athens".
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", nil, "Agia Kyriakií Spáton", .destination, false, "GR", "Greece"),
            (100, 1, nil, "Aegina", "Kypséli", .destination, false, "GR", "Greece"),
            (200, 2, "Athens", nil, "Agia Kyriakií Spáton", .destination, false, "GR", "Greece"),
        ])
        #expect(c.defaultTitle(for: trip, homePlaceNames: ["athens"]) == "Aegina")
        // Without the home set the old behaviour stands.
        #expect(c.defaultTitle(for: trip) == "Athens & Aegina")
    }

    @Test("a trip made only of home-named stays is named by their first layer that is not home, else keeps its name")
    func homeOnlyTripKeepsName() throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", nil, "Agios Dimitrios", .destination, false, "GR", "Greece"),
        ])
        #expect(c.defaultTitle(for: trip, homePlaceNames: ["athens"]) == "Agios Dimitrios")
        #expect(c.defaultTitle(for: trip, homePlaceNames: ["athens", "agios dimitrios"]) == "Athens")
    }

    @Test("home matching is by whole normalized name, so a New York home does not swallow York")
    func homeMatchIsWholeName() throws {
        let (c, trip) = try makeTrip([
            (0, 0, nil, nil, "York", .destination, false, "GB", "United Kingdom"),
            (100, 1, "New York", nil, "Brooklyn", .destination, false, "US", "United States"),
        ])
        #expect(c.defaultTitle(for: trip, homePlaceNames: ["new york"]) == "York")
    }

    // MARK: - Time-spent ranking (2026-09)

    @Test("with 4+ destinations the three with the most time survive, same-name groups merged")
    func topThreeByTimeSpent() throws {
        // Alpha 600 min (one stay), Bravo 60, Charlie 500, Delta 3 × 60 =
        // 180 split across two non-adjacent groups. By time: Alpha, Charlie,
        // Delta. (Stay-count ranking would give Delta, Alpha, Bravo; unmerged
        // groups would give Alpha, Charlie, Bravo; both distinguishable.)
        let (c, trip) = try makeTrip([
            (0, 0, "Alpha", nil, "Alpha", .destination, false, "XA", "Aland"),
            (100, 1, "Bravo", nil, "Bravo", .destination, false, "XB", "Bland"),
            (200, 2, "Delta", nil, "Delta", .destination, false, "XD", "Dland"),
            (300, 3, "Charlie", nil, "Charlie", .destination, false, "XC", "Cland"),
            (400, 4, "Delta", nil, "Delta", .destination, false, "XD", "Dland"),
            (500, 5, "Delta", nil, "Delta", .destination, false, "XD", "Dland"),
        ])
        for stay in trip.orderedStays {
            switch stay.metroName {
            case "Alpha": stay.durationMinutes = 600
            case "Charlie": stay.durationMinutes = 500
            default: stay.durationMinutes = 60
            }
        }
        #expect(c.defaultTitle(for: trip) == "Alpha, Delta & Charlie")
    }
}
