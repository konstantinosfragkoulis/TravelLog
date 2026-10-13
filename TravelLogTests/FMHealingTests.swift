//
//  FMHealingTests.swift
//  TravelLogTests
//
//  The Wrapped narrative lost its model lane on 2026-09-04 and is
//  deterministic everywhere; this file pins its display and existing-row
//  contracts.
//
//  @MainActor because it constructs `@Model` fixtures (MainActor-isolated
//  under the app's default-MainActor build); async where it awaits the actors.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct FMHealingTests {

    // MARK: - Wrapped narrative display (deterministic since 2026-09-04)

    @Test("Wrapped narrative display renders live from structured inputs and ignores stored model prose")
    func wrappedNarrativeDisplayTruthTable() {
        var stats = WrappedStats()
        stats.countriesVisited = 1
        stats.citiesVisited = 1
        stats.tripsCompleted = 1
        let inputs = NarrativeInputs(
            year: 2025,
            tripDisplayNames: ["Athens"],
            tripStartDates: [Date(timeIntervalSinceReferenceDate: 6_652_800)],
            longestTripName: nil,
            longestTripDays: nil,
            farthestPlaceName: nil,
            farthestDistanceKm: nil,
            firstTimeCountryISOCodes: []
        )
        stats.narrativeInputs = inputs
        let locale = Locale(identifier: "en")
        let rendered = YearWrappedGenerator.deterministicNarrative(
            from: inputs,
            stats: stats,
            locale: locale
        )

        #expect(WrappedDisplayResolver.resolvedNarrative(
            storedProse: "Stored deterministic prose.",
            stats: stats,
            locale: locale
        ) == rendered)
        // A paragraph the on-device model wrote on an older build is never
        // shown once the blob carries inputs.
        #expect(WrappedDisplayResolver.resolvedNarrative(
            storedProse: "Foundation Models prose.",
            stats: stats,
            locale: locale
        ) == rendered)

        var legacyStats = stats
        legacyStats.narrativeInputs = nil
        #expect(WrappedDisplayResolver.resolvedNarrative(
            storedProse: "Legacy deterministic prose.",
            stats: legacyStats,
            locale: locale
        ) == "Legacy deterministic prose.")
    }

    // MARK: - Wrapped existing-row contract

    private func wrappedContainer() throws -> (ModelContainer, ModelContext) {
        let container = try TestSupport.makeInMemoryContainer()
        return (container, ModelContext(container))
    }

    private static func realisticStats() -> WrappedStats {
        var stats = WrappedStats()
        stats.countriesVisited = 3
        stats.citiesVisited = 5
        stats.tripsCompleted = 2
        stats.daysAbroad = 12
        stats.daysAtHome = 353
        stats.longestTripName = "Cephalonia & Samos"
        stats.longestTripDays = 8
        stats.farthestPlaceName = "Lisbon"
        stats.farthestDistanceKm = 2850
        stats.totalGreatCircleKm = 6100
        stats.newCountryCodes = ["PT"]
        return stats
    }

    private func makeWrapped(_ ctx: ModelContext, year: Int, narrative: String, source: SummarySource?) -> YearWrapped {
        let w = YearWrapped(year: year)
        w.yearNarrative = narrative
        w.yearNarrativeSourceRaw = source?.rawValue
        w.statsData = Self.realisticStats().encoded()
        ctx.insert(w)
        return w
    }

    private func fetchWrapped(_ ctx: ModelContext, year: Int) throws -> YearWrapped? {
        let y = year
        return try ctx.fetch(FetchDescriptor<YearWrapped>(predicate: #Predicate { $0.year == y })).first
    }

    @Test("generateIfNeeded on an existing row returns .existing and leaves the row untouched, id stable")
    func generateIfNeededExistingRow() async throws {
        let (container, ctx) = try wrappedContainer()
        let original = "Deterministic."
        let w = makeWrapped(ctx, year: 2025, narrative: original, source: .deterministic)
        let originalID = w.id
        let originalGeneratedAt = w.generatedAt
        try ctx.save()

        let gen = YearWrappedGenerator(modelContainer: container)
        // Existing row → .existing (the caller contract), nothing rewritten.
        #expect(await gen.generateIfNeeded(forYear: 2025) == .existing)

        let after = try #require(try fetchWrapped(ModelContext(container), year: 2025))
        #expect(after.id == originalID)
        #expect(after.yearNarrative == original)
        #expect(after.yearNarrativeSourceRaw == SummarySource.deterministic.rawValue)
        #expect(after.generatedAt == originalGeneratedAt)
    }

    @Test("a stored model-written narrative is left in place; display ignores it")
    func storedFMNarrativeUntouched() async throws {
        let (container, ctx) = try wrappedContainer()
        let w = makeWrapped(ctx, year: 2025, narrative: "An FM narrative.", source: .foundationModels)
        let originalID = w.id
        try ctx.save()

        let gen = YearWrappedGenerator(modelContainer: container)
        #expect(await gen.generateIfNeeded(forYear: 2025) == .existing)

        let after = try #require(try fetchWrapped(ModelContext(container), year: 2025))
        #expect(after.id == originalID)
        #expect(after.yearNarrative == "An FM narrative.")
        #expect(after.yearNarrativeSourceRaw == SummarySource.foundationModels.rawValue)
    }

    // MARK: - tripLines (pure)
    // MARK: - tripLines (pure, shared by generate + heal)

    @Test("tripLines renders completed trips as \"(N days)\" and ongoing as \"…still ongoing)\", capped at 8")
    func tripLinesFormatting() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let completed = Trip(startDate: Date(timeIntervalSinceReferenceDate: 6_652_800))
        completed.endDate = Date(timeIntervalSinceReferenceDate: 6_652_800 + 4 * 86_400)  // durationDays = 5
        completed.isComplete = true
        completed.customName = "Athens"
        ctx.insert(completed)

        let ongoing = Trip(startDate: Date(timeIntervalSinceReferenceDate: 6_652_800 + 10 * 86_400))
        ongoing.customName = "Ios"
        ctx.insert(ongoing)

        let lines = YearWrappedGenerator.tripLines(from: [completed, ongoing])
        #expect(lines.count == 2)
        // Compute the expected day count via the same accessor so the format
        // assertion doesn't hardcode a figure that a runner's timezone/DST
        // could shift.
        #expect(lines[0] == "Athens (\(completed.durationDays ?? 0) days)")
        #expect(lines[1].hasPrefix("Ios ("))
        #expect(lines[1].hasSuffix("days so far, still ongoing)"))

        // Cap: 10 trips → at most 8 lines.
        let many = (0..<10).map { i -> Trip in
            let t = Trip(startDate: Date(timeIntervalSinceReferenceDate: Double(i) * 86_400))
            t.endDate = Date(timeIntervalSinceReferenceDate: Double(i) * 86_400 + 86_400)
            t.isComplete = true
            return t
        }
        #expect(YearWrappedGenerator.tripLines(from: many).count == 8)
    }

    /// Red/green pin: `deterministicNarrativeText`
    /// builds "The year ran from X to Y" out of `tripLines`' first and LAST
    /// entries. A plain `.prefix(8)` therefore named the 8th-earliest trip as
    /// the year's close for anyone with more than 8 trips — a definite factual
    /// claim, wrong, in the only Wrapped story a non-FM device ever renders.
    @Test("the trip-line cap keeps the year's true last trip, not the Nth-earliest")
    func tripLinesCapPreservesTheYearsClose() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // 12 trips, chronologically named so position is unambiguous.
        let trips = (0..<12).map { i -> Trip in
            let t = Trip(startDate: Date(timeIntervalSinceReferenceDate: Double(i) * 30 * 86_400))
            t.endDate = Date(timeIntervalSinceReferenceDate: Double(i) * 30 * 86_400 + 86_400)
            t.isComplete = true
            t.customName = "Trip \(i)"
            ctx.insert(t)
            return t
        }

        // Shuffled input: ordering must come from startDate, not array order.
        let lines = YearWrappedGenerator.tripLines(from: trips.reversed())

        #expect(lines.count == YearWrappedGenerator.narrativeTripLineCap)
        #expect(lines.first?.hasPrefix("Trip 0 (") == true)
        // Pre-fix this was "Trip 7" — the 8th-earliest.
        #expect(lines.last?.hasPrefix("Trip 11 (") == true)

        // And the sentence built from those lines names the real endpoints.
        var stats = WrappedStats()
        stats.tripsCompleted = 12
        let text = YearWrappedGenerator.deterministicNarrativeText(
            stats: stats, year: 2026, tripLines: lines
        )
        #expect(text.contains("The year ran from Trip 0 to Trip 11."))
    }

    // MARK: - deterministicNarrativeText (pure fallback narrative)

    @Test("deterministic narrative names the arc, longest trip, farthest point and first-time countries when present")
    func deterministicNarrativeRich() {
        var stats = WrappedStats()
        stats.countriesVisited = 3
        stats.citiesVisited = 7
        stats.tripsCompleted = 4
        stats.totalGreatCircleKm = 5_200
        stats.daysAbroad = 21
        stats.daysAtHome = 344
        stats.longestTripName = "Athens & Cephalonia"
        stats.longestTripDays = 9
        stats.farthestPlaceName = "Tokyo"
        stats.farthestDistanceKm = 9_500
        stats.newCountryCodes = ["JP", "VN"]

        let text = YearWrappedGenerator.deterministicNarrativeText(
            stats: stats,
            year: 2025,
            tripLines: ["Vienna (3 days)", "Athens & Cephalonia (9 days)", "Tokyo (6 days so far, still ongoing)"]
        )

        #expect(text.contains("In 2025, you visited 3 countries and 7 cities across 4 trips."))
        // Arc uses first/last trip names with the duration parenthetical stripped.
        #expect(text.contains("The year ran from Vienna to Tokyo."))
        #expect(text.contains("Your longest trip, Athens & Cephalonia, lasted 9 days."))
        #expect(text.contains("You made it as far as Tokyo, 9500 km from home."))
        #expect(text.contains("You covered 5200 km in total."))
        // ISO codes render as English names via the en_US region table.
        #expect(text.contains("You set foot in Japan and Vietnam for the first time."))
        #expect(text.contains("You spent 21 days abroad and 344 at home."))
    }

    @Test("deterministic narrative degrades gracefully: no arc for a single trip, optional sentences dropped, singulars correct")
    func deterministicNarrativeSparse() {
        var stats = WrappedStats()
        stats.countriesVisited = 1
        stats.citiesVisited = 0
        stats.tripsCompleted = 1

        let text = YearWrappedGenerator.deterministicNarrativeText(
            stats: stats,
            year: 2024,
            tripLines: ["Syros (2 days)"]
        )

        #expect(text == "In 2024, you visited 1 country across 1 trip.")
    }

    @Test("deterministic narrative skips the arc when first and last trips share a name, and counts >3 new countries instead of naming them")
    func deterministicNarrativeArcAndCountryCap() {
        var stats = WrappedStats()
        stats.countriesVisited = 5
        stats.citiesVisited = 5
        stats.tripsCompleted = 2
        stats.newCountryCodes = ["JP", "VN", "TH", "KH"]

        let text = YearWrappedGenerator.deterministicNarrativeText(
            stats: stats,
            year: 2025,
            tripLines: ["Athens (3 days)", "Athens (2 days)"]
        )

        #expect(!text.contains("The year ran from"))
        #expect(text.contains("You set foot in 4 countries for the first time."))
    }

    @Test("structured narrative inputs render byte-identically to the legacy English path")
    func deterministicNarrativeStructuredParityMatrix() {
        func inputs(year: Int, names: [String], stats: WrappedStats) -> NarrativeInputs {
            NarrativeInputs(
                year: year,
                tripDisplayNames: names,
                tripStartDates: names.indices.map { Date(timeIntervalSinceReferenceDate: 6_652_800 + Double($0)) },
                longestTripName: stats.longestTripName,
                longestTripDays: stats.longestTripDays > 0 ? stats.longestTripDays : nil,
                farthestPlaceName: stats.farthestPlaceName,
                farthestDistanceKm: stats.farthestDistanceKm > 0 ? stats.farthestDistanceKm : nil,
                firstTimeCountryISOCodes: stats.newCountryCodes
            )
        }

        var single = WrappedStats()
        single.countriesVisited = 1
        single.tripsCompleted = 1

        var rich = WrappedStats()
        rich.countriesVisited = 3
        rich.citiesVisited = 7
        rich.tripsCompleted = 4
        rich.longestTripName = "Athens & Cephalonia"
        rich.longestTripDays = 9
        rich.farthestPlaceName = "Tokyo"
        rich.farthestDistanceKm = 9_500
        rich.totalGreatCircleKm = 5_200
        rich.newCountryCodes = ["JP", "VN"]
        rich.daysAbroad = 21
        rich.daysAtHome = 344

        var manyCountries = WrappedStats()
        manyCountries.countriesVisited = 5
        manyCountries.citiesVisited = 5
        manyCountries.tripsCompleted = 2
        manyCountries.newCountryCodes = ["JP", "VN", "TH", "KH"]

        var singulars = WrappedStats()
        singulars.countriesVisited = 1
        singulars.citiesVisited = 1
        singulars.tripsCompleted = 1
        singulars.longestTripName = "Milan"
        singulars.longestTripDays = 1
        singulars.farthestPlaceName = "Antipode"
        singulars.farthestDistanceKm = 40_075
        singulars.totalGreatCircleKm = 40_075
        singulars.daysAbroad = 1
        singulars.daysAtHome = 364

        var threeNamedCountries = WrappedStats()
        threeNamedCountries.countriesVisited = 3
        threeNamedCountries.citiesVisited = 3
        threeNamedCountries.tripsCompleted = 3
        threeNamedCountries.newCountryCodes = ["JP", "VN", "TH"]

        let fixtures: [(stats: WrappedStats, year: Int, names: [String], lines: [String])] = [
            (single, 2024, ["Syros"], ["Syros (2 days)"]),
            (rich, 2025, ["Vienna", "Athens & Cephalonia", "Tokyo"],
             ["Vienna (3 days)", "Athens & Cephalonia (9 days)", "Tokyo (6 days so far, still ongoing)"]),
            (manyCountries, 2025, ["Athens", "Athens"],
             ["Athens (3 days)", "Athens (2 days)"]),
            (singulars, 2026, ["Milan"], ["Milan (1 day)"]),
            (threeNamedCountries, 2026, ["Tokyo", "Hanoi", "Bangkok"],
             ["Tokyo (2 days)", "Hanoi (2 days)", "Bangkok (2 days)"])
        ]

        for fixture in fixtures {
            let legacy = YearWrappedGenerator.deterministicNarrativeText(
                stats: fixture.stats,
                year: fixture.year,
                tripLines: fixture.lines
            )
            let structured = YearWrappedGenerator.deterministicNarrative(
                from: inputs(year: fixture.year, names: fixture.names, stats: fixture.stats),
                stats: fixture.stats,
                locale: Locale(identifier: "en")
            )
            #expect(structured == legacy)
        }

        let fiveDigitText = YearWrappedGenerator.deterministicNarrative(
            from: inputs(year: 2026, names: ["Milan"], stats: singulars),
            stats: singulars,
            locale: Locale(identifier: "en")
        )
        #expect(fiveDigitText.hasPrefix("In 2026, you visited 1 country and 1 city across 1 trip."))
        #expect(fiveDigitText.contains("lasted 1 day"))
        #expect(fiveDigitText.contains("spent 1 day abroad"))
        #expect(fiveDigitText.contains("40075 km from home"))
        #expect(fiveDigitText.contains("covered 40075 km"))
    }

    @Test("narrative country joins preserve legacy English and render the selected catalog otherwise")
    func deterministicNarrativeCountryListJoinPolicy() {
        var stats = WrappedStats()
        stats.countriesVisited = 3
        stats.citiesVisited = 3
        stats.tripsCompleted = 3

        let inputs = NarrativeInputs(
            year: 2026,
            tripDisplayNames: [],
            tripStartDates: [],
            longestTripName: nil,
            longestTripDays: nil,
            farthestPlaceName: nil,
            farthestDistanceKm: nil,
            firstTimeCountryISOCodes: ["JP", "VN", "TH"]
        )
        let english = YearWrappedGenerator.deterministicNarrative(
            from: inputs, stats: stats, locale: Locale(identifier: "en")
        )
        #expect(english.contains("You set foot in Japan, Vietnam and Thailand for the first time."))

        for identifier in ["und", "zz"] {
            let unknown = YearWrappedGenerator.deterministicNarrative(
                from: inputs, stats: stats, locale: Locale(identifier: identifier)
            )
            #expect(unknown.contains("You set foot in Japan, Vietnam and Thailand for the first time."))
        }

        let greek = Locale(identifier: "el")
        let names = inputs.firstTimeCountryISOCodes.map {
            localizedCountryName(iso: $0, fallback: $0, locale: greek) ?? $0
        }
        let formatter = ListFormatter()
        formatter.locale = greek
        let list = formatter.string(from: names)!
        let localized = YearWrappedGenerator.deterministicNarrative(
            from: inputs, stats: stats, locale: greek
        )
        #expect(localized.contains("Χώρες που επισκέφθηκες για πρώτη φορά: \(list)."))
    }
}
