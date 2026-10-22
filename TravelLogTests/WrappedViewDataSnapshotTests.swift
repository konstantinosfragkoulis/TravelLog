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
        // What the cards draw: the longest trip, the weather rows and the
        // closing footnote all follow the scrub.
        #expect(after.content.longestTripName == "Lisbon")
        #expect(before.content.footnote?.contains(sentinel) == true)
        #expect(!(after.content.footnote ?? "").contains(sentinel))
        let share = WrappedShare(year: after.data.year, stats: after.stats,
                                 appLocaleIdentifier: en.identifier)
        #expect(!share.content.allText.contains { $0.contains(sentinel) })
    }

    @Test("a legacy footnote scrubbed under an open recap leaves the card list and the pager in place")
    func legacyScrubKeepsCardsAndPage() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sentinel = "PRIVATE_CALENDAR_OCCASION"
        let trip = Trip(startDate: utc(2025, 2, 1))
        trip.aiGeneratedTitle = sentinel
        trip.destinationSummary = "Lisbon"
        ctx.insert(trip)
        // Legacy blob: the mystery fact exists only as stored English text,
        // which the scrub removes. It is a footnote on the closing card, not
        // a card of its own, so no page disappears.
        var stats = WrappedStats()
        stats.mysteryFactText = "Two days at \(sentinel)"
        let row = YearWrapped(year: 2025)
        row.statsData = stats.encoded()
        ctx.insert(row)
        try ctx.save()

        let before = WrappedView(wrapped: row, onDismiss: {})
        let beforeCards = WrappedView.visibleCards(
            stats: before.stats, weatherCoverage: before.data.weatherCoverage)
        #expect(before.content.footnote == "Two days at \(sentinel)")

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
        #expect(after.content.footnote == nil)
        #expect(afterCards == beforeCards)
        let lastBefore = beforeCards.count - 1
        #expect(WrappedView.clampedPage(lastBefore, cardCount: afterCards.count) == lastBefore)
    }

    @Test("page clamp keeps an existing page, clamps a vanished one and leaves nil alone")
    func clampedPagePolicy() {
        #expect(WrappedView.clampedPage(3, cardCount: 10) == 3)
        #expect(WrappedView.clampedPage(9, cardCount: 9) == 8)
        #expect(WrappedView.clampedPage(12, cardCount: 7) == 6)
        #expect(WrappedView.clampedPage(nil, cardCount: 7) == nil)
        #expect(WrappedView.clampedPage(4, cardCount: 0) == 4)
        // A weather card that loses its gate under an open recap removes a
        // page: a reader on the old last card lands on the new last card,
        // and an earlier page stays put.
        var legacy = WrappedStats()
        legacy.hottestTempC = 31
        legacy.hottestLocality = "Port Halven"
        let withWeather = WrappedView.visibleCards(stats: legacy, weatherCoverage: 0.9)
        let withoutWeather = WrappedView.visibleCards(stats: legacy, weatherCoverage: 0.3)
        #expect(withWeather.contains(.weather))
        #expect(!withoutWeather.contains(.weather))
        #expect(withWeather.count == withoutWeather.count + 1)
        #expect(WrappedView.clampedPage(withWeather.count - 1, cardCount: withoutWeather.count)
            == withoutWeather.count - 1)
        #expect(WrappedView.clampedPage(1, cardCount: withoutWeather.count) == 1)
    }

    @Test("card gating is a pure function of the passed stats + coverages")
    func visibleCardsGating() {
        var richStats = WrappedStats()
        richStats.longestTripName = "Ostrel Highlands Loop"
        richStats.longestTripDays = 12
        richStats.farthestDistanceKm = 9000
        richStats.mysteryFactText = "You visited Vellmora on 3 trips this year."
        // The distance card gates on renderable CONTENT (a measured total, or
        // any mode at least transitCardMinimumKm), not a coverage fraction.
        richStats.flightKm = 4200
        richStats.daysAbroad = 30
        richStats.daysAtHome = 335
        richStats.newCountryCodes = ["QP"]
        richStats.narrativeInputs = Self.inputs(year: 2025, starts: [utc(2025, 3, 2), utc(2025, 8, 9)])
        // The weather card also requires a renderable row: a measured
        // extreme WITH a place name.
        richStats.hottestTempC = 31.4
        richStats.hottestLocality = "Port Halven"

        let richCards = WrappedView.visibleCards(
            stats: richStats, weatherCoverage: 0.7
        )
        let expectedRich: [WrappedCardKind] = [
            .title, .places, .longestTrip, .farthest, .months, .distance,
            .homeAway, .firstVisits, .weather, .closing,
        ]
        #expect(richCards == expectedRich)

        // Title, places and closing always show; everything else needs data.
        // The mystery fact never earns a card (it is the closing footnote).
        var sparse = WrappedStats()
        sparse.mysteryFactText = "You spent 2 days in airports this year."
        #expect(WrappedView.visibleCards(stats: sparse, weatherCoverage: 0.69)
            == [.title, .places, .closing])
    }

    @Test("each optional card appears exactly when its own data exists")
    func perCardGates() {
        func cards(_ change: (inout WrappedStats) -> Void) -> [WrappedCardKind] {
            var stats = WrappedStats()
            change(&stats)
            return WrappedView.visibleCards(stats: stats, weatherCoverage: 0)
        }
        // Longest trip: a name AND a length.
        #expect(!cards { $0.longestTripName = "Kelden Pass Weekend" }.contains(.longestTrip))
        #expect(cards { $0.longestTripName = "Kelden Pass Weekend"; $0.longestTripDays = 2 }.contains(.longestTrip))
        // Months: two trips starting in the recap's own year; rows without
        // narrative inputs (older recaps) never show it.
        #expect(!cards { $0.narrativeInputs = Self.inputs(year: 2025, starts: [utc(2025, 4, 1)]) }.contains(.months))
        #expect(!cards { $0.narrativeInputs = Self.inputs(year: 2025, starts: [utc(2024, 12, 30), utc(2025, 4, 1)]) }.contains(.months))
        #expect(cards { $0.narrativeInputs = Self.inputs(year: 2025, starts: [utc(2025, 4, 1), utc(2025, 4, 20)]) }.contains(.months))
        // Distance: a measured total, or one mode with a meaningful distance.
        #expect(cards { $0.totalGreatCircleKm = 12 }.contains(.distance))
        #expect(cards { $0.walkKm = WrappedView.transitCardMinimumKm }.contains(.distance))
        #expect(!cards { $0.walkKm = WrappedView.transitCardMinimumKm - 1 }.contains(.distance))
        // Home and away: any counted day.
        #expect(cards { $0.daysAtHome = 365 }.contains(.homeAway))
        // First visits: at least one new country.
        #expect(!cards { $0.mostVisitedCountryCode = "QN" }.contains(.firstVisits))
        #expect(cards { $0.newCountryCodes = ["QN"] }.contains(.firstVisits))
    }

    @Test("trips per month count the recap year's trip starts in UTC and need narrative inputs")
    func tripsPerMonthBuckets() {
        var stats = WrappedStats()
        #expect(WrappedView.tripsPerMonth(stats: stats) == nil)
        stats.narrativeInputs = Self.inputs(year: 2025, starts: [
            utc(2025, 1, 31, 23), utc(2025, 2, 1, 0), utc(2025, 2, 14), utc(2026, 1, 2),
        ])
        let months = WrappedView.tripsPerMonth(stats: stats)
        #expect(months == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    private static func inputs(year: Int, starts: [Date]) -> NarrativeInputs {
        NarrativeInputs(
            year: year, tripDisplayNames: starts.indices.map { "Trip \($0)" }, tripStartDates: starts,
            longestTripName: nil, longestTripDays: nil, farthestPlaceName: nil,
            farthestDistanceKm: nil, firstTimeCountryISOCodes: [])
    }
}
