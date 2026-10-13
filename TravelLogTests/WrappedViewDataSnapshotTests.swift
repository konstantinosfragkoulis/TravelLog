//
//  WrappedViewDataSnapshotTests.swift
//  TravelLogTests
//
//  `WrappedViewData` value snapshot survives `YearWrappedDeduplicator`
//  hard-deleting its source row mid-display or absorbing newer content
//  into it, `WrappedView` derives its stats from each rebuilt snapshot
//  (same-id scrub and absorption), and the card-gating rule is a pure
//  function of the snapshot values.
//
//  `@MainActor` because the app target compiles MainActor-by-default →
//  `@Model` types are MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedViewDataSnapshotTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Fixed ids decide the dedup survivor (largest `id.uuidString`), so each
    /// case pins one branch instead of whichever a random UUID picked.
    private static let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let highID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

    @Test("snapshot keeps its values whether dedup deletes its source row or absorbs newer content into it",
          arguments: [false, true])
    func snapshotSurvivesDedupSwap(olderSurvives: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        var oldStats = WrappedStats()
        oldStats.countriesVisited = 7
        oldStats.longestTripName = "Cephalonia Hop"
        var newStats = WrappedStats()
        newStats.countriesVisited = 3
        newStats.longestTripName = "Crete Loop"

        // The row the view is presented with.
        let older = YearWrapped(year: 2026)
        older.id = olderSurvives ? Self.highID : Self.lowID
        older.generatedAt = utc(2026, 12, 30)
        older.statsData = oldStats.encoded()
        older.yearNarrative = "Old narrative"
        older.weatherCoverage = 0.9
        older.transitCoverage = 0.8

        let newer = YearWrapped(year: 2026)
        newer.id = olderSurvives ? Self.lowID : Self.highID
        newer.generatedAt = utc(2026, 12, 31)
        newer.statsData = newStats.encoded()
        newer.yearNarrative = "New narrative"
        newer.weatherCoverage = 0.1
        newer.transitCoverage = 0.2

        ctx.insert(older)
        ctx.insert(newer)
        try ctx.save()

        // Capture identities and the snapshot BEFORE the dedup. Reading a
        // deleted row afterwards is exactly the tombstone access the
        // snapshot prevents.
        let olderID = older.id
        let olderPID = older.persistentModelID
        let newerPID = newer.persistentModelID
        let newerStatsData = try #require(newer.statsData)
        let snapshot = WrappedViewData(wrapped: older)

        #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))

        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<YearWrapped>())
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        if olderSurvives {
            // In-place branch: the presented row survives and absorbs the
            // newer content, coverage included.
            #expect(survivor.persistentModelID == olderPID)
            #expect(survivor.id == olderID)
            #expect(!rows.contains(where: { $0.persistentModelID == newerPID }))
            #expect(survivor.statsData == newerStatsData)
            #expect(survivor.yearNarrative == "New narrative")
            #expect(survivor.weatherCoverage == 0.1)
            #expect(survivor.transitCoverage == 0.2)
            #expect(survivor.generatedAt == utc(2026, 12, 31))
            // Value path of an open recap: RootView rebuilds WrappedView from
            // the same-id row, and it now derives stats from that row.
            // (Mounted refresh itself needs a manual check on device.)
            let rebuilt = WrappedView(wrapped: survivor, onDismiss: {})
            #expect(rebuilt.data.id == olderID)
            #expect(rebuilt.stats.countriesVisited == 3)
            #expect(rebuilt.stats.longestTripName == "Crete Loop")
            #expect(rebuilt.data.weatherCoverage == 0.1)
        } else {
            // Deleted-source branch: the presented row is physically gone.
            #expect(survivor.persistentModelID == newerPID)
            #expect(!rows.contains(where: { $0.persistentModelID == olderPID }))
            let byOlderID = try verify.fetch(FetchDescriptor<YearWrapped>(
                predicate: #Predicate { $0.id == olderID }))
            #expect(byOlderID.isEmpty)
            #expect(survivor.statsData == newerStatsData)
        }

        // The captured value itself never changes: it is what an already
        // exported share or an older body pass saw.
        #expect(snapshot.id == olderID)
        #expect(snapshot.year == 2026)
        #expect(snapshot.yearNarrative == "Old narrative")
        #expect(snapshot.weatherCoverage == 0.9)
        let decoded = try #require(snapshot.statsData.flatMap(WrappedStats.decoded(from:)))
        #expect(decoded.countriesVisited == 7)
        #expect(decoded.longestTripName == "Cephalonia Hop")
    }

    @Test("an open recap rebuilt after the calendar scrub renders and shares only scrubbed names")
    func rebuiltViewFollowsCalendarScrub() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sentinel = "PRIVATE_CALENDAR_OCCASION"
        let trip = Trip(startDate: utc(2025, 2, 1))
        trip.aiGeneratedTitle = sentinel
        trip.destinationSummary = "Lisbon"
        ctx.insert(trip)

        var stats = WrappedStats()
        stats.countriesVisited = 4
        stats.longestTripName = sentinel
        stats.longestTripDays = 6
        stats.rainiestTripName = sentinel
        stats.rainiestPrecipitationMm = 12
        stats.mysteryFact = .shortestTrip(name: sentinel, days: 2)
        stats.mysteryFactText = "Two days at \(sentinel)"
        stats.narrativeInputs = NarrativeInputs(
            year: 2025, tripDisplayNames: [sentinel], tripStartDates: [trip.startDate],
            longestTripName: sentinel, longestTripDays: 6, farthestPlaceName: nil,
            farthestDistanceKm: nil, firstTimeCountryISOCodes: [])
        let row = YearWrapped(year: 2025)
        row.statsData = stats.encoded()
        ctx.insert(row)
        try ctx.save()
        let rowID = row.id

        let before = WrappedView(wrapped: row, onDismiss: {})
        #expect(before.stats.longestTripName == sentinel)

        // The production clear transaction, in its own isolated gate unit.
        let gate = PipelineGate(forTesting: ())
        let classifier = TripClassifier(modelContainer: container)
        let cleared = await gate.runReturning(touching: [.trip, .yearWrapped]) {
            await classifier.clearCalendarTitlesForTesting()
        }
        #expect(cleared)

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let after = WrappedView(wrapped: saved, onDismiss: {})
        // Same id: RootView keeps the mounted view, so only a view that
        // derives its stats from the rebuilt input drops the names.
        #expect(after.data.id == rowID)
        #expect(after.stats.countriesVisited == 4)
        #expect(after.stats.longestTripName == "Lisbon")
        #expect(after.stats.rainiestTripName == "Lisbon")
        #expect(after.stats.mysteryFact == .shortestTrip(name: "Lisbon", days: 2))
        #expect(after.stats.mysteryFactText == nil)
        #expect(after.stats.narrativeInputs?.tripDisplayNames == ["Lisbon"])

        let en = Locale(identifier: "en")
        let narrative = WrappedDisplayResolver.resolvedNarrative(
            storedProse: after.data.yearNarrative, stats: after.stats, locale: en)
        #expect(!(narrative ?? "").contains(sentinel))
        let share = WrappedNarrativeShare(
            year: after.data.year, narrative: narrative, stats: after.stats,
            appLocaleIdentifier: en.identifier)
        #expect(!share.content.narrative.contains(sentinel))
    }

    @Test("a card that disappears under an open legacy recap moves the pager to the last remaining card")
    func legacyScrubClampsCurrentPage() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sentinel = "PRIVATE_CALENDAR_OCCASION"
        let trip = Trip(startDate: utc(2025, 2, 1))
        trip.aiGeneratedTitle = sentinel
        trip.destinationSummary = "Lisbon"
        ctx.insert(trip)
        // Legacy blob: the mystery card exists only as stored English text,
        // which the scrub removes.
        var stats = WrappedStats()
        stats.mysteryFactText = "Two days at \(sentinel)"
        let row = YearWrapped(year: 2025)
        row.statsData = stats.encoded()
        ctx.insert(row)
        try ctx.save()

        let before = WrappedView(wrapped: row, onDismiss: {})
        let beforeCards = WrappedView.visibleCards(
            stats: before.stats, weatherCoverage: before.data.weatherCoverage)
        #expect(beforeCards.contains(.mystery))

        let gate = PipelineGate(forTesting: ())
        let classifier = TripClassifier(modelContainer: container)
        let cleared = await gate.runReturning(touching: [.trip, .yearWrapped]) {
            await classifier.clearCalendarTitlesForTesting()
        }
        #expect(cleared)

        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let after = WrappedView(wrapped: saved, onDismiss: {})
        let afterCards = WrappedView.visibleCards(
            stats: after.stats, weatherCoverage: after.data.weatherCoverage)
        #expect(!afterCards.contains(.mystery))
        #expect(afterCards.count == beforeCards.count - 1)

        // A reader resting on the old last card lands on the new last card;
        // any page that still exists stays put.
        let lastBefore = beforeCards.count - 1
        #expect(WrappedView.clampedPage(lastBefore, cardCount: afterCards.count)
            == afterCards.count - 1)
        #expect(WrappedView.clampedPage(2, cardCount: afterCards.count) == 2)
    }

    @Test("page clamp keeps an existing page, clamps a vanished one and leaves nil alone")
    func clampedPagePolicy() {
        #expect(WrappedView.clampedPage(3, cardCount: 10) == 3)
        #expect(WrappedView.clampedPage(9, cardCount: 9) == 8)
        #expect(WrappedView.clampedPage(12, cardCount: 7) == 6)
        #expect(WrappedView.clampedPage(nil, cardCount: 7) == nil)
        #expect(WrappedView.clampedPage(4, cardCount: 0) == 4)
        // Equal-count replacement (weather and top destinations swap) keeps
        // the reader on the same page.
        var legacy = WrappedStats()
        legacy.hottestTempC = 31
        legacy.hottestLocality = "Athens"
        let withWeather = WrappedView.visibleCards(stats: legacy, weatherCoverage: 0.9)
        let withoutWeather = WrappedView.visibleCards(stats: legacy, weatherCoverage: 0.3)
        #expect(withWeather.contains(.weather))
        #expect(withoutWeather.contains(.topDestinations))
        #expect(withWeather.count == withoutWeather.count)
        #expect(WrappedView.clampedPage(2, cardCount: withoutWeather.count) == 2)
    }

    @Test("card gating is a pure function of the passed stats + coverages")
    func visibleCardsGating() {
        var richStats = WrappedStats()
        richStats.longestTripName = "The Long One"
        richStats.farthestDistanceKm = 9000
        richStats.mysteryFactText = "You crossed the equator."
        // The transit card gates on
        // renderable CONTENT (any mode ≥ transitCardMinimumKm), not the
        // coverage fraction; which was permanently unsatisfiable
        // post-CoreMotion (only .flight/.unknown are ever produced).
        richStats.flightKm = 4200
        // The weather card
        // also requires a renderable row; a measured extreme WITH a place
        // name; for the same reason the transit card requires renderable
        // distance. A "rich" stats blob has one.
        richStats.hottestTempC = 31.4
        richStats.hottestLocality = "Athens"

        let richCards = WrappedView.visibleCards(
            stats: richStats, weatherCoverage: 0.7
        )
        let expectedRich: [WrappedCardKind] = [
            .coldOpen, .globe, .longestTrip, .farthest, .weather, .transit,
            .newCountries, .timeBalance, .mystery, .yearNarrative,
        ]
        #expect(richCards == expectedRich)

        let sparseCards = WrappedView.visibleCards(
            stats: WrappedStats(), weatherCoverage: 0.69
        )
        let expectedSparse: [WrappedCardKind] = [
            .coldOpen, .globe, .topDestinations, .totalDistance,
            .newCountries, .timeBalance, .yearNarrative,
        ]
        #expect(sparseCards == expectedSparse)
    }
}
