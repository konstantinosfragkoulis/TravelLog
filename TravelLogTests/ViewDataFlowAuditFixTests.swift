//
//  ViewDataFlowAuditFixTests.swift
//  TravelLogTests
//
//  Checks three view data-flow contracts:
//
//  - `WrappedViewData` value snapshot survives
//    `YearWrappedDeduplicator` hard-deleting its source row mid-display or
//    absorbing newer content into it, `WrappedView` derives its stats from
//    each rebuilt snapshot (same-id scrub and absorption), and
//    the card-gating rule is a pure function of the snapshot values.
//  - `PhotoService.stayShapeToken` self-invalidates the
//    per-trip photo cache when the reused ongoing row's stays accrete,
//    extend, reclassify, or the trip closes (stable `Trip.id` no longer
//    implies a stable photo set).
//  - The pure pinned-overlay filter used by
//    `TripDetailView.photosSection` instead of a per-render SwiftData fetch.
//
//  `@MainActor` because the app target compiles MainActor-by-default →
//  `@Model` types are MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
import Photos
@testable import TravelLog

// MARK: - WrappedViewData snapshot liveness

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

// MARK: - stay-shape cache token

@MainActor
struct PhotoServiceStayShapeTokenTests {

    private func makeStay(start: Date, end: Date) -> Stay {
        Stay(
            startTime: start,
            endTime: end,
            centroidLatitude: 37.98,
            centroidLongitude: 23.72,
            h3IndexRes6: "861f01a07ffffff",
            pingCount: 4,
            distanceFromHomeKm: 250,
            pingIDs: []
        )
    }

    @Test("token is stable for an unchanged trip and moves on every photo-relevant mutation")
    func tokenTracksStayShape() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let base = Date(timeIntervalSince1970: 1_735_484_800)
        let trip = Trip(startDate: base)
        ctx.insert(trip)
        let first = makeStay(start: base, end: base.addingTimeInterval(7200))
        ctx.insert(first)
        first.trip = trip

        let initial = PhotoService.stayShapeToken(for: trip)
        #expect(PhotoService.stayShapeToken(for: trip) == initial,
                "same shape must produce the same token within a process")

        // Pipeline appends a stay to the reused ongoing row (stable id).
        let second = makeStay(
            start: base.addingTimeInterval(10_000),
            end: base.addingTimeInterval(14_000)
        )
        ctx.insert(second)
        second.trip = trip
        let afterAppend = PhotoService.stayShapeToken(for: trip)
        #expect(afterAppend != initial)

        // A wake ping extends the last stay's endTime.
        second.endTime = second.endTime.addingTimeInterval(3600)
        let afterExtend = PhotoService.stayShapeToken(for: trip)
        #expect(afterExtend != afterAppend)

        // Reclassification flips a category without changing the stay set.
        first.categoryRaw = StayCategory.destination.rawValue
        let afterReclassify = PhotoService.stayShapeToken(for: trip)
        #expect(afterReclassify != afterExtend)

        trip.endDate = base.addingTimeInterval(20_000)
        let afterClose = PhotoService.stayShapeToken(for: trip)
        #expect(afterClose != afterReclassify)

        // Geocoding fills the header locality in place.
        first.locality = "Athens"
        let afterLocality = PhotoService.stayShapeToken(for: trip)
        #expect(afterLocality != afterClose)
    }
}

// MARK: - pure pinned-overlay filter

/// PHAsset stub: `localIdentifier`/`creationDate` are plain readonly
/// properties on PHObject/PHAsset, overridable in a subclass; the standard
/// PhotoKit stubbing seam (no framework calls are faked).
private final class StubPHAsset: PHAsset, @unchecked Sendable {
    private let stubID: String
    private let stubDate: Date?

    init(id: String, date: Date?) {
        self.stubID = id
        self.stubDate = date
        super.init()
    }

    override var localIdentifier: String { stubID }
    override var creationDate: Date? { stubDate }
}

@MainActor
struct PinnedOverlayFilterTests {

    private func group(stayStart: Date, assets: [PHAsset]) -> StayPhotos {
        StayPhotos(
            stayID: UUID(),
            stayLocality: nil,
            stayStartTime: stayStart,
            assets: assets
        )
    }

    @Test("empty pinned set short-circuits to []")
    func emptyPinnedSet() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let groups = [group(stayStart: base, assets: [StubPHAsset(id: "a", date: base)])]
        #expect(PhotoService.pinnedAssets(in: groups, pinnedIdentifiers: []).isEmpty)
    }

    @Test("filters across groups and sorts chronologically")
    func filtersAndSorts() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let early = StubPHAsset(id: "early", date: base)
        let middle = StubPHAsset(id: "middle", date: base.addingTimeInterval(600))
        let late = StubPHAsset(id: "late", date: base.addingTimeInterval(1200))
        let unpinned = StubPHAsset(id: "unpinned", date: base.addingTimeInterval(300))

        // Later stay listed first: the sort, not group order, must decide.
        let groups = [
            group(stayStart: base.addingTimeInterval(1000), assets: [late, middle]),
            group(stayStart: base, assets: [early, unpinned]),
        ]

        let pinned = PhotoService.pinnedAssets(
            in: groups,
            pinnedIdentifiers: ["early", "middle", "late"]
        )
        #expect(pinned.map(\.localIdentifier) == ["early", "middle", "late"])
    }
}


// MARK: - No-op trip edits

/// Edit then Done with an untouched name, or re-picking a stay's current
/// category, must not mark the trip `userEdited`: that flag exempts the trip
/// from reclassification and regrouping for good.
@MainActor
struct TripDetailNoOpEditTests {

    private func makeStay(start: Date, category: StayCategory) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(7200),
            centroidLatitude: 37.98,
            centroidLongitude: 23.72,
            h3IndexRes6: "861f01a07ffffff",
            pingCount: 4,
            distanceFromHomeKm: 250,
            pingIDs: []
        )
        stay.category = category
        return stay
    }

    @Test("renaming to the current name leaves the trip unedited")
    func sameNameRenameIsNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let named = Trip(startDate: base)
        named.customName = "Cephalonia"
        let unnamed = Trip(startDate: base.addingTimeInterval(86_400))
        ctx.insert(named)
        ctx.insert(unnamed)
        try ctx.save()

        #expect(TripDetailView.applyRename(tripID: named.id, tripIdentifier: named.persistentModelID, newName: "Cephalonia", in: ctx))
        #expect(named.userEdited == false)
        #expect(named.customName == "Cephalonia")

        #expect(TripDetailView.applyRename(tripID: unnamed.id, tripIdentifier: unnamed.persistentModelID, newName: nil, in: ctx))
        #expect(unnamed.userEdited == false)
        #expect(unnamed.customName == nil)

        #expect(TripDetailView.applyRename(tripID: named.id, tripIdentifier: named.persistentModelID, newName: "Samos", in: ctx))
        #expect(named.userEdited == true)
        #expect(named.customName == "Samos")
    }

    @Test("re-picking a stay's current category leaves flags and AI text alone")
    func sameCategoryChangeIsNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let trip = Trip(startDate: base)
        ctx.insert(trip)
        let stay = makeStay(start: base, category: .destination)
        ctx.insert(stay)
        stay.trip = trip
        trip.aiGeneratedTitle = "Island Hopping"
        trip.aiGeneratedSummary = "A week in the Cyclades."
        try ctx.save()

        TripDetailView.applyCategoryChange(
            stayID: stay.id, tripID: trip.id, newCategory: .destination, in: ctx)
        #expect(stay.userOverridden == false)
        #expect(trip.userEdited == false)
        #expect(trip.aiGeneratedTitle == "Island Hopping")
        #expect(trip.aiGeneratedSummary == "A week in the Cyclades.")

        TripDetailView.applyCategoryChange(
            stayID: stay.id, tripID: trip.id, newCategory: .transit, in: ctx)
        #expect(stay.category == .transit)
        #expect(stay.userOverridden == true)
        #expect(trip.userEdited == true)
    }

    @Test("a rename and a category change are the user's own edits: a temporary home's mark on the trip goes, the edit stays")
    func userEditsClearATemporaryHomesMark() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let renamed = Trip(startDate: base)
        let recategorized = Trip(startDate: base.addingTimeInterval(86_400))
        for trip in [renamed, recategorized] {
            trip.userEdited = true
            trip.keptByTemporaryHome = true
            ctx.insert(trip)
        }
        let stay = makeStay(start: base.addingTimeInterval(86_400), category: .destination)
        ctx.insert(stay)
        stay.trip = recategorized
        try ctx.save()

        #expect(TripDetailView.applyRename(tripID: renamed.id, tripIdentifier: renamed.persistentModelID, newName: "Erasmus", in: ctx))
        TripDetailView.applyCategoryChange(
            stayID: stay.id, tripID: recategorized.id, newCategory: .transit, in: ctx)

        let fresh = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(fresh.count == 2)
        for trip in fresh {
            #expect(trip.userEdited)
            #expect(!trip.keptByTemporaryHome)
        }
    }
}
