//
//  TitlePromptShapeTests.swift
//  TravelLogTests
//
//  Title-prompt construction — TripClassifier.buildTitlePrompt(for:) plus the two
//  pure formatters TripTitlePolicy.formattedMinutes(_:) and
//  TripClassifier.formattedHomeDistance(_:). The prompt
//  is a deterministic newline-joined text: a ranked place
//  list and the "Title:" ask, nothing else. We assert
//  presence/absence and ORDER of markers (robust to wording):
//    • transit stays are pre-filtered out entirely (only destinations are title
//      candidates) — EXCEPT for the all-transit fallback trip, where every
//      group is offered
//    • airport-area destinations are left out while another destination exists
//    • the list is ranked by time spent, same-name groups merged
//    • bare-country names never appear
//    • no home lines, no dates, no countries, no calendar text: nothing the
//      model could copy
//  buildTitlePrompt is actor-isolated → awaited; the two formatters are
//  nonisolated → called synchronously.
//
//  `@MainActor` because it constructs @Model Stay/Trip + instantiates the @ModelActor.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitlePromptShapeTests {

    private typealias StaySpec = (
        offset: Int, order: Int,
        metro: String?, island: String?, locality: String?,
        category: StayCategory, isAirport: Bool,
        iso: String?, country: String?,
        minutes: Int
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
            stay.orderInTrip = s.order
            stay.trip = trip
            context.insert(stay)
        }
        return trip
    }

    private func placeLines(_ prompt: String) -> [String] {
        prompt.split(separator: "\n").map(String.init).filter { $0.first?.isNumber == true }
    }

    // MARK: - What is and is not offered

    @Test("a non-airport transit stay is omitted from the prompt entirely")
    func transitStayOmittedFromPrompt() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .destination, false, "FR", "France", 600),
            (1000, 1, "Alès", nil, "Alès", .transit, false, "FR", "France", 100),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        // The model cannot title what it cannot see.
        #expect(!prompt.contains("Ales"))
        #expect(!prompt.lowercased().contains("transit"))
        #expect(prompt.contains("1. Paris"))
    }

    @Test("a place that is BOTH transit and destination stays in the prompt via its destination stay")
    func transitPlusDestinationPlaceRemainsCandidate() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Milan", nil, "Milan", .transit, false, "IT", "Italy", 60),
            (100, 1, "Florence", nil, "Florence", .destination, false, "IT", "Italy", 600),
            (800, 2, "Milan", nil, "Milan", .destination, false, "IT", "Italy", 300),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        let lines = placeLines(prompt)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("1. Florence"))
        #expect(lines[1].hasPrefix("2. Milan"))
    }

    @Test("an airport-area destination is left out while another destination exists")
    func airportAreaDroppedBesideRealDestination() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .destination, true, "DE", "Germany", 1500),
            (2000, 1, "Berlin", nil, "Berlin", .destination, false, "DE", "Germany", 600),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(!prompt.contains("Frankfurt"))
        #expect(prompt.contains("1. Berlin"))
        #expect(!prompt.contains("AIRPORT"))
    }

    @Test("an airport-only trip still offers the airport place (better some title than nothing)")
    func airportOnlyTripOffersThePlace() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Frankfurt", nil, "Frankfurt", .destination, true, "DE", "Germany", 1500)
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(prompt.contains("1. Frankfurt"))
    }

    @Test("when every stay is transit, every group is offered and the ask still appears")
    func allTransitFallbackOffersEveryGroup() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .transit, false, "FR", "France", 120),
            (200, 1, "Alès", nil, "Alès", .transit, false, "FR", "France", 60),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(prompt.contains("1. Paris"))
        #expect(prompt.contains("2. Ales"))
        #expect(prompt.hasSuffix("Title:"))
    }

    @Test("a bare-country destination name is not offered")
    func bareCountryNotOffered() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, nil, nil, "Greece", .destination, false, "GR", "Greece", 600)
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(!prompt.contains("Greece"))
        #expect(placeLines(prompt).isEmpty)
    }

    // MARK: - Ranking and merging

    @Test("places are listed by time spent, most first, regardless of visit order")
    func placesRankedByTime() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Riehen", nil, "Riehen", .destination, false, "CH", "Switzerland", 360),
            (400, 1, "Renens", nil, "Renens", .destination, false, "CH", "Switzerland", 2880),
            (3400, 2, "Bellinzona", nil, "Bellinzona", .destination, false, "CH", "Switzerland", 2160),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        let lines = placeLines(prompt)
        #expect(lines.map { $0.prefix(2) } == ["1.", "2.", "3."])
        #expect(lines[0].contains("Renens"))
        #expect(lines[1].contains("Bellinzona"))
        #expect(lines[2].contains("Riehen"))
        #expect(lines[0].contains("2d"))
    }

    @Test("a place visited twice with something in between is one line with its stay count and summed time")
    func sameNameGroupsMerge() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", nil, "Athens", .destination, false, "GR", "Greece", 600),
            (700, 1, "Mykonos", nil, "Mykonos", .destination, false, "GR", "Greece", 1440),
            (2200, 2, "Athens", nil, "Athens", .destination, false, "GR", "Greece", 1200),
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        let lines = placeLines(prompt)
        #expect(lines.count == 2)
        // 600 + 1200 = 1800 minutes = 1d 6h beats Mykonos' 1d.
        #expect(lines[0].hasPrefix("1. Athens (1d 6h, 2 stays)"))
        #expect(lines[1].hasPrefix("2. Mykonos (1d)"))
    }

    @Test("metroName is preferred over islandName and locality for the listed name")
    func metroPreferredForName() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Athens", "Salamina", "Gérakas", .destination, false, "GR", "Greece", 600)
        ])
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(prompt.contains("1. Athens"))
        #expect(!prompt.contains("Gerakas"))
        #expect(!prompt.contains("Salamina"))
    }

    // MARK: - Nothing the model could copy

    @Test("the prompt carries no home lines, no dates, no countries, no calendar text")
    func promptCarriesNothingCopyable() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Paris", nil, "Paris", .destination, false, "FR", "France", 600)
        ], endDateOffset: 2 * 24 * 60)
        let prompt = await c.buildTitlePrompt(for: trip)
        #expect(!prompt.contains("Home"))
        #expect(!prompt.contains("France"))
        #expect(!prompt.contains("duration"))
        #expect(!prompt.contains("May"))
        #expect(!prompt.contains("CALENDAR"))
        #expect(prompt == "Places visited, the place with the most time first:\n1. Paris (10h)\n\nTitle:")
    }

    // MARK: - Exact prompt material

    @Test("exact prompt, candidates, spellings and fallback across ties, scripts and unknown categories")
    func exactPromptMaterial() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway", 600),
                // Ties Tromsø on time and stays: the earlier first visit ranks first.
                (700, 1, nil, nil, "Σύρος", .destination, false, "GR", "Greece", 600),
                // Recategorized below to a raw value no case matches.
                (1400, 2, nil, nil, "Bodø", .destination, false, "NO", "Norway", 5000),
                // No name at all: never offered, however long.
                (6500, 3, nil, nil, nil, .destination, false, nil, nil, 9000),
                (15600, 4, "Athens", nil, "Athína", .destination, false, "GR", "Greece", 150),
                (15800, 5, nil, nil, "Corinth", .destination, false, "GR", "Greece", 100),
                (16000, 6, "Athens", nil, "Athína", .destination, false, "GR", "Greece", 150),
                // Ties Athens on time with fewer stays.
                (16200, 7, nil, nil, "Nafplio", .destination, false, "GR", "Greece", 300),
                // Same start: time, stays and first visit all tie.
                (16600, 8, nil, nil, "Sparti", .destination, false, "GR", "Greece", 100),
                (16600, 9, nil, nil, "Mystras", .destination, false, "GR", "Greece", 100),
            ], into: container)
            trip.orderedStays[2].categoryRaw = "bogus"
            let material = c.titlePromptMaterial(for: trip)
            #expect(material.prompt == """
                Places visited, the place with the most time first:
                1. Tromso (10h)
                2. Syros (10h)
                3. Athens (5h, 2 stays)
                4. Nafplio (5h)
                5. Corinth (1h 40m)
                6. Sparti (1h 40m)
                7. Mystras (1h 40m)

                Title:
                """)
            #expect(material.candidates == ["Tromso", "Syros", "Athens", "Nafplio", "Corinth", "Sparti", "Mystras"])
            #expect(material.titleSpellings == ["Tromsø", "Syros", "Athens", "Nafplio", "Corinth", "Sparti", "Mystras"])
            #expect(c.computeFallbackTitle(for: trip) == "Tromsø, Syros & Athens")
            // Home names compare folded but keep ø, so only the second set names Tromsø.
            #expect(c.computeFallbackTitle(for: trip, homePlaceNames: ["tromso"]) == "Tromsø, Syros & Athens")
            #expect(c.computeFallbackTitle(for: trip, homePlaceNames: ["tromsø"]) == "Syros, Athens & Nafplio")
        }
    }

    @Test("an empty name is a missing one: an empty island leaves the locality, and a stay with no name is no place")
    func exactPromptMaterialForEmptyNames() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "", .destination, false, "GR", "", 300),
                // An empty island no longer shadows the locality.
                (400, 1, nil, "", "Oia", .destination, false, "GR", "Greece", 200),
                (700, 2, nil, nil, "Fira", .destination, false, "GR", nil, 100),
            ], into: container)
            let material = c.titlePromptMaterial(for: trip)
            #expect(material.prompt == """
                Places visited, the place with the most time first:
                1. Oia (3h 20m)
                2. Fira (1h 40m)

                Title:
                """)
            #expect(material.candidates == ["Oia", "Fira"])
            #expect(material.titleSpellings == ["Oia", "Fira"])
            #expect(c.computeFallbackTitle(for: trip) == "Oia & Fira")
        }
    }

    @Test("ranking regroups stays by start time, whatever their stored order")
    func exactPromptMaterialWhenOrderDisagreesWithTime() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                // Stored first, visited later: its group starts at the earlier visit.
                (1200, 0, nil, nil, "Corinth", .destination, false, "GR", "Greece", 60),
                (0, 1, nil, nil, "Corinth", .destination, false, "GR", "Greece", 60),
                (600, 2, nil, nil, "Fira", .destination, false, "GR", "Greece", 120),
                // Same start: the stored order breaks the tie, not insertion.
                (1800, 4, nil, nil, "Sparti", .destination, false, "GR", "Greece", 30),
                (1800, 3, nil, nil, "Mystras", .destination, false, "GR", "Greece", 30),
            ], into: container)
            let material = c.titlePromptMaterial(for: trip)
            #expect(material.prompt == """
                Places visited, the place with the most time first:
                1. Corinth (2h, 2 stays)
                2. Fira (2h)
                3. Mystras (30m)
                4. Sparti (30m)

                Title:
                """)
            #expect(c.computeFallbackTitle(for: trip) == "Corinth, Fira & Mystras")
            // A tie in minutes with the top place qualifies.
            #expect(c.titleValidationFailure("Fira", for: trip) == nil)
            #expect(c.titleValidationFailure("Sparti", for: trip) == .missingTopPlace("Corinth"))
        }
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

    @Test("the prompt's candidates are the listed names, in order and spelling, and nothing else")
    func candidatesMirrorThePromptLines() async throws {
        let (c, trip) = try makeTrip([
            (0, 0, "Ioánnina", nil, "Ioánnina", .destination, false, "GR", "Greece", 2000),
            (2100, 1, "Κοντακαίικα", nil, "Κοντακαίικα", .destination, false, "GR", "Greece", 300),
            (2500, 2, "Athens", nil, "Athens", .transit, false, "GR", "Greece", 60),
        ])
        let material = await c.titlePromptMaterial(for: trip)
        #expect(material.candidates == ["Ioannina", "Kontakaiika"])
        let lines = placeLines(material.prompt)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("1. Ioannina"))
        #expect(lines[1].hasPrefix("2. Kontakaiika"))
        #expect(!material.candidates.contains("Athens"))
    }

    @Test("the prompt spells names in ASCII while chosen places are saved in their stored spelling")
    func chosenCandidatesMapToStoredSpelling() async throws {
        // `trip` is read again after the actor call: build and read it on the actor.
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "Tromsø", .destination, false, "NO", "Norway", 2000),
                (2100, 1, nil, nil, "Bodø", .destination, false, "NO", "Norway", 300),
            ], into: container)
            let material = c.titlePromptMaterial(for: trip)
            #expect(material.candidates == ["Tromso", "Bodo"])
            #expect(material.titleSpellings == ["Tromsø", "Bodø"])
            #expect(material.prompt.contains("1. Tromso"))
            #expect(!material.prompt.contains("Troms "))
            let composed = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: ["Tromso", "Bodo"], candidates: material.candidates, titleSpellings: material.titleSpellings))
            #expect(composed == "Tromsø & Bodø")
            #expect(c.titleValidationFailure(composed, for: trip) == nil)
        }
    }

    @Test("a one-place trip's only choice is saved in its stored spelling and validates")
    func singleChoiceUsesStoredSpelling() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier(modelContainer: container).runIsolated { c in
            let trip = insertTrip([
                (0, 0, nil, nil, "Wrocław", .destination, false, "PL", "Poland", 600),
            ], into: container)
            let material = c.titlePromptMaterial(for: trip)
            let choices = TripTitleSchema.choices(for: material.candidates)
            #expect(choices == ["Wroclaw"])
            let only = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: [choices[0]], candidates: material.candidates, titleSpellings: material.titleSpellings))
            #expect(only == "Wrocław")
            #expect(c.titleValidationFailure(only, for: trip) == nil)
        }
    }

    @Test("stored-spelling composition keeps rank precedence, abbreviations and dedupe")
    func canonicalCompositionEdgeCases() {
        // Two places sharing one prompt spelling: the better-ranked one wins.
        #expect(TripTitlePolicy.composeCanonicalTitle(
            places: ["Tromso"], candidates: ["Tromso", "Tromso"], titleSpellings: ["Tromsø", "Tromso"]) == "Tromsø")
        // Abbreviations are no candidate and pass through, still folding onto their full name.
        #expect(TripTitlePolicy.composeCanonicalTitle(
            places: ["NYC", "New York", "White Plains"], candidates: ["New York", "White Plains"],
            titleSpellings: ["New York", "White Plains"]) == "NYC & White Plains")
        #expect(TripTitlePolicy.composeCanonicalTitle(
            places: ["LA"], candidates: ["Los Angeles"], titleSpellings: ["Los Angeles"]) == "LA")
        #expect(TripTitlePolicy.composeCanonicalTitle(places: [], candidates: ["Oslo"], titleSpellings: ["Oslo"]) == "")
    }

    @Test("the decode grammar admits only the listed names plus NYC and LA, and never more places than the trip has")
    func schemaChoicesAreClosed() throws {
        #expect(TripTitleSchema.choices(for: ["Livadeia"]) == ["Livadeia"])
        #expect(TripTitleSchema.choices(for: ["White Plains", "New York", "Los Angeles", "White Plains", " "])
                == ["White Plains", "New York", "NYC", "Los Angeles", "LA"])
        #expect(TripTitleSchema.placeLimit(candidateCount: 1) == 1)
        #expect(TripTitleSchema.placeLimit(candidateCount: 2) == 2)
        #expect(TripTitleSchema.placeLimit(candidateCount: 3) == 3)
        #expect(TripTitleSchema.placeLimit(candidateCount: 9) == 3)
        #expect(TripTitleSchema.placeLimit(candidateCount: 0) == 1)
        // The grammar builds for real lists and refuses an empty one.
        _ = try TripTitleSchema.schema(candidates: ["Livadeia"])
        _ = try TripTitleSchema.schema(candidates: ["Mykonos", "Paxos", "Cephalonia", "Samos", "Milos"])
        #expect(throws: TripTitleSchema.Failure.noCandidates) {
            try TripTitleSchema.schema(candidates: [])
        }
    }

    @Test("a place and its permitted abbreviation are one place")
    func composeTitleFoldsAbbreviations() {
        // A model may return a place, its full name and its abbreviation together.
        #expect(TripTitlePolicy.composeTitle(places: ["White Plains", "New York", "NYC"]) == "White Plains & New York")
        #expect(TripTitlePolicy.composeTitle(places: ["NYC", "New York"]) == "NYC")
        #expect(TripTitlePolicy.composeTitle(places: ["Los Angeles", "LA", "London"]) == "Los Angeles & London")
    }

    // MARK: - formattedMinutes (pure)

    @Test("formattedMinutes(45) == '45m' (under an hour)")
    func formattedMinutesUnderAnHour() {
        #expect(TripTitlePolicy.formattedMinutes(45) == "45m")
    }

    @Test("formattedMinutes hours+minutes: 200 → '3h 20m', 180 → '3h' (no trailing 0m)")
    func formattedMinutesHoursAndMinutes() {
        #expect(TripTitlePolicy.formattedMinutes(200) == "3h 20m")
        #expect(TripTitlePolicy.formattedMinutes(180) == "3h")
    }

    @Test("formattedMinutes days+hours: 1500 → '1d 1h', 1440 → '1d' (exact-day boundary)")
    func formattedMinutesDaysAndHours() {
        #expect(TripTitlePolicy.formattedMinutes(1500) == "1d 1h")
        #expect(TripTitlePolicy.formattedMinutes(1440) == "1d")
    }

    // MARK: - formattedHomeDistance (pure)

    @Test("formattedHomeDistance(100.0) == '100km from home' (integer truncation)")
    func formattedHomeDistanceNormal() throws {
        let c = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        #expect(c.formattedHomeDistance(100.0) == "100km from home")
    }

    @Test("formattedHomeDistance maps greatestFiniteMagnitude / NaN / infinity to 'no home configured'")
    func formattedHomeDistanceNoHomeSentinel() throws {
        let c = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        #expect(c.formattedHomeDistance(.greatestFiniteMagnitude) == "no home configured")
        #expect(c.formattedHomeDistance(.nan) == "no home configured")
        #expect(c.formattedHomeDistance(.infinity) == "no home configured")
    }
}
