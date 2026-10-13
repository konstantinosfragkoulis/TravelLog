//
//  ClassifierStageTwoTests.swift
//  TravelLogTests
//
//  Stage 2 of the classifier:
//    • `resolveDeterministicOutcomes` — Stage 2a decides the stays whose final
//      category is model-independent (thresholds MUST mirror
//      `sanityCheckClassifications`; the equivalence tests here pin that).
//    • `buildPrompt(stays:ordered:calendarHints:)` — timeline rendering:
//      numbered lines carry km-from-previous (true chronological
//      predecessor), island/metro identity, and the solar-03:00 overnight
//      tag; settled neighbours render as unnumbered `(context)` lines with
//      home runs ≥3 collapsed; the span extends `promptContextSpan` (3)
//      stays on each side of the batch.
//
//  Fixtures are UTC-pinned where the overnight guard is in play (solar time
//  at the fixture longitudes must not drift with the runner's timezone) —
//  same convention as ClassifierHeuristicsTests.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (Stay) MainActor-touchable here;
//  actor-isolated TripClassifier methods are awaited. Tests that hand stays
//  to the classifier build them inside `runIsolated`, so no model crosses
//  an actor boundary.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct ClassifierStageTwoTests {

    // MARK: - Fixtures

    // Nonisolated so tests can build stays inside `TripClassifier.runIsolated`.
    @discardableResult
    private nonisolated func makeStay(
        in ctx: ModelContext,
        start: Date,
        minutes: Int,
        dist: Double = 100,
        isAirport: Bool = false,
        lat: Double = 0,
        lon: Double = 0,
        locality: String? = nil,
        island: String? = nil,
        country: String = "Greece",
        category: StayCategory = .unclassified,
        userOverridden: Bool = false,
        hex: String
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(Double(minutes) * 60),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: dist, pingIDs: []
        )
        stay.isAirport = isAirport
        stay.category = category
        stay.userOverridden = userOverridden
        stay.locality = locality
        stay.islandName = island
        stay.country = country
        ctx.insert(stay)
        return stay
    }

    /// UTC-pinned instant (see file header).
    private nonisolated func utc(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 4, day: day, hour: hour, minute: minute))!
            .addingTimeInterval(56 * 86_400)
    }

    private func kmRounded(_ a: Stay, _ b: Stay) -> Int {
        let meters = CLLocation(latitude: a.centroidLatitude, longitude: a.centroidLongitude)
            .distance(from: CLLocation(latitude: b.centroidLatitude, longitude: b.centroidLongitude))
        return Int((meters / 1000.0).rounded())
    }

    // MARK: - Stage 2a: resolveDeterministicOutcomes

    @Test("airport <24h, ≤20min, and ≥5-day stays resolve deterministically; the rest stay ambiguous")
    func deterministicResolutionMatrix() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let airport = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 300, isAirport: true, hex: "a")
            let blip = makeStay(in: ctx, start: utc(1, hour: 14), minutes: 15, hex: "b")
            let week = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 8000, hex: "c")
            let airportWeek = makeStay(in: ctx, start: utc(8, hour: 8), minutes: 8000, isAirport: true, hex: "d")
            let hotel = makeStay(in: ctx, start: utc(14, hour: 8), minutes: 1500, isAirport: true, hex: "e")
            let plain = makeStay(in: ctx, start: utc(15, hour: 12), minutes: 100, hex: "f")
            try ctx.save()

            let (resolved, ambiguous) = classifier.resolveDeterministicOutcomes(
                [airport, blip, week, airportWeek, hotel, plain]
            )

            #expect(resolved.count == 4)
            #expect(airport.category == .transit)
            #expect(blip.category == .transit)
            #expect(week.category == .destination)
            // ≥5 days beats the airport rule (which only covers <24h) — matches
            // the sanity-check fixpoint, where the long-transit flip lands on
            // destination and the airport flip can't fire.
            #expect(airportWeek.category == .destination)
            // The 25h airport-hotel case is the model's to judge.
            #expect(hotel.category == .unclassified)
            #expect(plain.category == .unclassified)
            #expect(ambiguous.count == 2)
        }
    }

    @Test("boundary values: exactly 20min resolves transit; exactly 24h airport and 21min do not resolve")
    func deterministicResolutionBoundaries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let exactly20 = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 20, hex: "a")
            let just21 = makeStay(in: ctx, start: utc(1, hour: 10), minutes: 21, hex: "b")
            let exactly24hAirport = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 24 * 60, isAirport: true, hex: "c")
            try ctx.save()

            let (resolved, ambiguous) = classifier.resolveDeterministicOutcomes(
                [exactly20, just21, exactly24hAirport]
            )

            #expect(resolved.count == 1)
            #expect(exactly20.category == .transit)
            #expect(just21.category == .unclassified)
            #expect(exactly24hAirport.category == .unclassified)
            #expect(ambiguous.count == 2)
        }
    }

    @Test("user-overridden and already-classified stays are never touched and never returned as ambiguous")
    func deterministicResolutionRespectsOverrides() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            let overridden = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 15, userOverridden: true, hex: "a")
            let settled = makeStay(in: ctx, start: utc(1, hour: 10), minutes: 15, category: .destination, hex: "b")
            try ctx.save()

            let (resolved, ambiguous) = classifier.resolveDeterministicOutcomes(
                [overridden, settled]
            )

            #expect(resolved.isEmpty)
            #expect(ambiguous.isEmpty)
            #expect(overridden.category == .unclassified)
            #expect(settled.category == .destination)
        }
    }

    /// Equivalence pin: for every shape Stage 2a claims, resolving up front
    /// must land on the SAME category the sanity check would force onto a
    /// disagreeing model verdict. If someone changes a threshold on one side
    /// only, this test fails.
    @Test("Stage 2a outcome equals the sanity-check fixpoint of a disagreeing model verdict")
    func resolutionMatchesSanityFixpoint() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        try await classifier.runIsolated { classifier in
            let ctx = ModelContext(container)

            // Copy A: resolved deterministically. Copy B: the model "disagreed";
            // the sanity check must flip B to A's category.
            let airportA = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 300, isAirport: true, hex: "a1")
            let airportB = makeStay(in: ctx, start: utc(1, hour: 14), minutes: 300, isAirport: true,
                                    category: .destination, hex: "a2")
            let blipA = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 15, hex: "b1")
            let blipB = makeStay(in: ctx, start: utc(2, hour: 10), minutes: 15, category: .destination, hex: "b2")
            let weekA = makeStay(in: ctx, start: utc(3, hour: 8), minutes: 8000, hex: "c1")
            let weekB = makeStay(in: ctx, start: utc(10, hour: 8), minutes: 8000, category: .transit, hex: "c2")
            try ctx.save()

            _ = classifier.resolveDeterministicOutcomes([airportA, blipA, weekA])
            _ = classifier.sanityCheckClassifications()

            #expect(airportA.category == .transit)
            #expect(classifier.stayCategoryForTesting(airportB.id) == .transit)
            #expect(blipA.category == .transit)
            #expect(classifier.stayCategoryForTesting(blipB.id) == .transit)
            #expect(weekA.category == .destination)
            #expect(classifier.stayCategoryForTesting(weekB.id) == .destination)
        }
    }

    /// Stage-2a resolutions credit the engine that would have classified
    /// them before Stage 2a: FM lane when
    /// the model is available, heuristic lane otherwise. Without this, an
    /// all-deterministic trip (flights + a ≥5-day stay, the common
    /// single-city vacation) was stamped `classifiedByAI = false` on FM
    /// devices and sat in the Enhance-History backlog PERMANENTLY, because
    /// reclassify re-enters Stage 2a and can never flip the flag back.
    @Test("Stage-2a provenance lane drives the trip's classifiedByAI stamp")
    func resolutionProvenanceParity() async throws {
        for fmLane in [true, false] {
            let container = try TestSupport.makeInMemoryContainer()
            let classifier = TripClassifier(modelContainer: container)
            try await classifier.runIsolated { classifier in
                let ctx = ModelContext(container)

                // Qualifying home boundaries (live-SLC, ≥15 min dwell) around a
                // Stage-2a-resolvable ≥5-day stay — the whole trip is decided
                // without any engine.
                makeStay(in: ctx, start: utc(1, hour: 6), minutes: 600, dist: 0,
                         locality: "Athens", category: .home, hex: "h1")
                let week = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 8000,
                                    dist: 1200, locality: "Vienna", hex: "w")
                makeStay(in: ctx, start: utc(8, hour: 12), minutes: 600, dist: 0,
                         locality: "Athens", category: .home, hex: "h2")
                try ctx.save()

                let (resolved, _) = classifier.resolveDeterministicOutcomes([week])
                #expect(resolved.count == 1)
                classifier.registerStage2aProvenance(resolved, asFM: fmLane)
                try ctx.save()

                _ = classifier.assembleTrips()
                let trips = classifier.assembledTripsForTesting()
                let tripID = try #require(trips.first?.id)
                #expect(classifier.classifiedByAIForTesting(tripID) == fmLane,
                        Comment(rawValue: "fmLane=\(fmLane)"))
            }
        }
    }

    /// Availability alone is not proof the model
    /// ran. FM credit for Stage-2a resolutions requires the FM lane to have
    /// actually produced output, except when nothing ambiguous existed to
    /// run (the all-deterministic vacation), where availability remains the
    /// only parity signal.
    @Test("Stage-2a lane credit: FM only when the model ran or had nothing to run")
    func stage2aLaneCreditTruthTable() {
        // FM unavailable → always heuristic.
        #expect(!TripClassifier.stage2aCreditsAsFM(
            fmAvailable: false, hadAmbiguousStays: false, fmLaneProducedOutput: false))
        #expect(!TripClassifier.stage2aCreditsAsFM(
            fmAvailable: false, hadAmbiguousStays: true, fmLaneProducedOutput: false))
        // FM available, nothing ambiguous → FM (availability parity).
        #expect(TripClassifier.stage2aCreditsAsFM(
            fmAvailable: true, hadAmbiguousStays: false, fmLaneProducedOutput: false))
        // FM available, lane ran and produced output → FM.
        #expect(TripClassifier.stage2aCreditsAsFM(
            fmAvailable: true, hadAmbiguousStays: true, fmLaneProducedOutput: true))
        // FM available but the lane produced NOTHING (throw / thermal abort /
        // total skip → heuristic sweep did the work) → heuristic.
        #expect(!TripClassifier.stage2aCreditsAsFM(
            fmAvailable: true, hadAmbiguousStays: true, fmLaneProducedOutput: false))
    }

    /// The back-half dirty gate's
    /// sanity-fixpoint arm must (a) fire on exactly the states the Stage-2.5
    /// rules would correct, since clustering can create them without minting
    /// an unclassified stay, and (b) go quiet after one sanity pass, or the
    /// arm would re-run the back half on every pass forever.
    @Test("sanity-fixpoint gate arm fires on violations and converges after one sanity pass")
    func sanityFixpointGateConverges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Clean store: no violation.
        makeStay(in: ctx, start: utc(1, hour: 8), minutes: 600, category: .destination, hex: "a")
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)

        // A transit stay grown past 5 days (the endTime-extension shape) and
        // a destination re-stamped as an airport — both sanity violations
        // with zero unclassified stays anywhere.
        let longTransit = makeStay(in: ctx, start: utc(2, hour: 8), minutes: 8000,
                                   category: .transit, hex: "b")
        let airportDest = makeStay(in: ctx, start: utc(9, hour: 8), minutes: 300,
                                   category: .destination, hex: "c")
        airportDest.isAirport = true
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == true)

        // One sanity pass corrects both; the gate arm goes quiet (threshold
        // mirror + convergence in one assertion).
        _ = await classifier.sanityCheckClassifications()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
        // Read through the actor's seam — the corrections live in ITS
        // context (the file-header pattern; the seeding ctx can't see them).
        #expect(await classifier.stayCategoryForTesting(longTransit.id) == .destination)
        #expect(await classifier.stayCategoryForTesting(airportDest.id) == .transit)

        // userOverridden violations are exempt on BOTH sides — the gate
        // must not loop on a stay sanity will never touch.
        let locked = makeStay(in: ctx, start: utc(12, hour: 8), minutes: 8000,
                              category: .transit, hex: "d")
        locked.userOverridden = true
        try ctx.save()
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
    }

    // MARK: - Timeline prompt

    @Test("numbered lines carry island identity, km from true predecessor, and the overnight tag")
    func timelinePromptFeatures() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        // Settled home, then a 45-minute port stop and a 43-hour island stay.
        // Solar 03:00 is about 01:13 UTC at the port and 01:38 UTC on the
        // island. The daytime port stop never crosses it; the long stay does.
        let home = makeStay(in: ctx, start: utc(1, hour: 6), minutes: 60,
                            dist: 0, lat: 37.98, lon: 23.72,
                            locality: "Athens", category: .home, hex: "h")
        let port = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 45,
                            dist: 160, lat: 37.7796, lon: 26.7489,
                            locality: "Ydroússa", island: "Samos", hex: "p")
        let island = makeStay(in: ctx, start: utc(1, hour: 11), minutes: 2600,
                              dist: 180, lat: 38.1558, lon: 20.5321,
                              locality: "Lixoúri", island: "Cephalonia", hex: "n")
        try ctx.save()

        let prompt = await classifier.buildPrompt(stays: [port, island])

        // Island parenthetical + numbered rendering.
        #expect(prompt.contains("[0] Ydroussa (Samos), Greece | 45min"))
        #expect(prompt.contains("[1] Lixouri (Cephalonia), Greece | 2600min"))

        // km-from-prev computed from the TRUE chronological predecessor:
        // the home stay for [0], the port stay for [1].
        #expect(prompt.contains("| \(kmRounded(home, port))km from prev"))
        #expect(prompt.contains("| \(kmRounded(port, island))km from prev"))

        // Overnight tag: only the 43-hour stay crosses solar 03:00.
        let overnightLines = prompt.split(separator: "\n").filter { $0.contains("| overnight") }
        #expect(overnightLines.count == 1)
        #expect(overnightLines.first?.contains("[1]") == true)

        // The home stay renders as an unnumbered context line — the journey
        // boundary is visible to the model.
        let homeLine = prompt.split(separator: "\n").first { $0.contains("Athens") }
        #expect(homeLine?.hasPrefix("  (context)") == true)
        #expect(homeLine?.contains("| home") == true)
    }

    @Test("runs of ≥3 same-category settled stays collapse to a single context line")
    func timelinePromptCollapsesHomeRuns() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        for i in 0..<3 {
            makeStay(in: ctx, start: utc(1, hour: 6 + i), minutes: 50,
                     dist: 0, lat: 37.98, lon: 23.72,
                     locality: "Athens", category: .home, hex: "h\(i)")
        }
        let stay = makeStay(in: ctx, start: utc(1, hour: 12), minutes: 100,
                            dist: 50, lat: 38.0, lon: 23.0,
                            locality: "Thiva", hex: "s")
        try ctx.save()

        let prompt = await classifier.buildPrompt(stays: [stay])

        #expect(prompt.contains("(context) home ×3"))
        // Collapsed — the individual home lines are gone.
        #expect(!prompt.contains("Athens, Greece | 50min"))
        #expect(prompt.contains("[0] Thiva, Greece | 100min"))
    }

    @Test("place tokens transliterate to Latin so Greek script does not trip the language identifier")
    func promptTransliteratesGreekPlaceNames() async throws {
        // The offline geocoder stores native-script primary names for
        // Greece. A timeline full of Greek script can cause classification
        // to throw `unsupportedLanguageOrLocale` and fall back to heuristics.
        // The prompt latinizes place tokens; stored names stay native.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let stay = makeStay(in: ctx, start: utc(1, hour: 9), minutes: 300,
                            dist: 12, lat: 38.1558, lon: 20.5321,
                            locality: "Γέρακας", island: "Κεφαλονιά", hex: "g")
        try ctx.save()

        let prompt = await classifier.buildPrompt(
            stays: [stay], calendarHints: [stay.id: "Πτήση Κεφαλονιά"])

        #expect(prompt.contains("Gerakas (Kephalonia)"))
        let greekScalars = prompt.unicodeScalars.filter { (0x0370...0x03FF).contains($0.value) }
        #expect(greekScalars.isEmpty,
                "no Greek script may reach FoundationModels — found: \(String(String.UnicodeScalarView(greekScalars)))")
    }

    @Test("the timeline span is capped at promptContextSpan (3) stays on the lookahead side")
    func timelinePromptLookaheadCap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let batchStay = makeStay(in: ctx, start: utc(1, hour: 8), minutes: 100,
                                 dist: 50, locality: "Batch", hex: "b")
        for i in 0..<4 {
            makeStay(in: ctx, start: utc(1, hour: 10 + i), minutes: 30,
                     dist: 60, locality: "Upcoming\(i)", hex: "u\(i)")
        }
        try ctx.save()

        let prompt = await classifier.buildPrompt(stays: [batchStay])

        // The next 3 unclassified stays appear as not-yet-classified context;
        // the 4th is beyond the span.
        #expect(prompt.contains("Upcoming0"))
        #expect(prompt.contains("Upcoming2"))
        #expect(!prompt.contains("Upcoming3"))
        #expect(prompt.contains("not yet classified"))
        // They are context, not numbered ("[0]" also appears in the header's
        // "[0]…[0]" range, so count actual numbered LINES).
        let numberedLines = prompt.split(separator: "\n").filter { $0.hasPrefix("[") }
        #expect(numberedLines.count == 1)
        #expect(numberedLines.first?.hasPrefix("[0] Batch") == true)
    }
}
