//
//  TemporaryHomeListUITests.swift
//  TravelLogTests
//
//  The trips list and trip detail around temporary homes, through their pure
//  seams: the suggestion line's copy and which trips it is evaluated for,
//  the demotion tip skipping a suggested trip, the cards' reload key
//  for ended cards and their clock, the map picker opening on the
//  bound pin, Settings rows for removed temporary homes whose trips are
//  still owed an update, and the list's suggestion pass key. Dates are in
//  UTC and written out by hand.
//

import CoreLocation
import Foundation
import MapKit
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home list and detail")
struct TemporaryHomeListUITests {

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Suggestion line

    @Test("the suggestion asks about the city, ongoing or completed, with no dashes")
    func suggestionCopy() {
        #expect(TemporaryHomeSuggestionLine.text(placeName: "Brussels", isOngoing: true)
            == "Living in Brussels for now? Set up a temporary home so your trips from there count on their own.")
        #expect(TemporaryHomeSuggestionLine.text(placeName: "Brussels", isOngoing: false)
            == "Lived in Brussels for a while? Set up a temporary home so your trips from there count on their own.")
        // No city: an ongoing trip asks about here, a completed one about there.
        #expect(TemporaryHomeSuggestionLine.text(placeName: nil, isOngoing: true)
            == "Living here for now? Set up a temporary home so your trips from here count on their own.")
        #expect(TemporaryHomeSuggestionLine.text(placeName: "", isOngoing: false)
            == "Lived there for a while? Set up a temporary home so your trips from there count on their own.")
        for placeName in ["Brussels", nil] {
            for isOngoing in [true, false] {
                let text = TemporaryHomeSuggestionLine.text(placeName: placeName, isOngoing: isOngoing)
                #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
            }
        }
    }

    @Test("the list evaluates every open trip for its row, and only long completed trips for the tip")
    func suggestionScope() {
        // Open: the row line, whatever its age (the evaluator applies the 14 days).
        #expect(TripsListView.suggestionScope(
            isComplete: false, startDate: at(2025, 9, 1), endDate: nil, timeZone: utc) == .row)
        // Completed: 27 inclusive days or more, a day of slack under the completed rule's 28.
        #expect(TripsListView.suggestionScope(
            isComplete: true, startDate: at(2025, 9, 1), endDate: at(2025, 9, 27), timeZone: utc) == .tipOnly)
        #expect(TripsListView.suggestionScope(
            isComplete: true, startDate: at(2025, 9, 1), endDate: at(2025, 12, 20), timeZone: utc) == .tipOnly)
        #expect(TripsListView.suggestionScope(
            isComplete: true, startDate: at(2025, 9, 1), endDate: at(2025, 9, 26), timeZone: utc) == nil)
        #expect(TripsListView.suggestionScope(
            isComplete: true, startDate: at(2025, 9, 1), endDate: at(2025, 9, 3), timeZone: utc) == nil)
    }

    @Test("a suggested trip keeps the demotion tip away, answered or not; only an ongoing candidate shows a row line")
    func suggestionOutcome() {
        // An open trip with an ongoing candidate: the line, and no "Not a trip?" tip.
        var outcome = TripsListView.suggestionOutcome(scope: .row, isDismissed: false, candidateIsOngoing: true)
        #expect(outcome.showsLine && outcome.skipsTip)
        // Not Now hides the line and never brings the tip back.
        outcome = TripsListView.suggestionOutcome(scope: .row, isDismissed: true, candidateIsOngoing: nil)
        #expect(!outcome.showsLine && outcome.skipsTip)
        outcome = TripsListView.suggestionOutcome(scope: .tipOnly, isDismissed: true, candidateIsOngoing: nil)
        #expect(!outcome.showsLine && outcome.skipsTip)
        // A completed trip's candidate is asked on its detail only.
        outcome = TripsListView.suggestionOutcome(scope: .tipOnly, isDismissed: false, candidateIsOngoing: false)
        #expect(!outcome.showsLine && outcome.skipsTip)
        // No candidate: nothing changes for that trip.
        outcome = TripsListView.suggestionOutcome(scope: .row, isDismissed: false, candidateIsOngoing: nil)
        #expect(!outcome.showsLine && !outcome.skipsTip)
    }

    // MARK: - Cards reload and clock

    @Test("with only ended cards on screen, a stay or trip change still reloads them")
    func endedCardsFollowEvidence() {
        let tracker = StoreChangeTracker(forTesting: ())
        // One ended card loaded: the load reports any card, ended or not.
        let follows = TripsListView.temporaryHomeCardsFollowEvidence(cardCount: 1)
        #expect(follows)
        for change in [StoreChange.stay, .trip] {
            let before = TripsListView.makeTemporaryHomeCardsRecomputeKey(
                followEvidence: follows, clockTick: 0, cardsClockTick: 0, tracker: tracker)
            // A deleted trip or a late stay: no temporary-home write, no clock event.
            tracker.applyNowForTesting(change)
            let after = TripsListView.makeTemporaryHomeCardsRecomputeKey(
                followEvidence: follows, clockTick: 0, cardsClockTick: 0, tracker: tracker)
            #expect(after != before)
        }
    }

    @Test("a list without a temporary home observes neither stays nor trips for the cards")
    func noCardsObserveNoEvidence() {
        let tracker = StoreChangeTracker(forTesting: ())
        let follows = TripsListView.temporaryHomeCardsFollowEvidence(cardCount: 0)
        #expect(!follows)
        let before = TripsListView.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: follows, clockTick: 0, cardsClockTick: 0, tracker: tracker)
        tracker.applyNowForTesting([.stay, .trip])
        #expect(TripsListView.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: follows, clockTick: 0, cardsClockTick: 0, tracker: tracker) == before)
        // A temporary-home write and either clock still reload.
        tracker.applyNowForTesting(.temporaryHome)
        let afterRow = TripsListView.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: follows, clockTick: 0, cardsClockTick: 0, tracker: tracker)
        #expect(afterRow != before)
        #expect(TripsListView.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: follows, clockTick: 1, cardsClockTick: 0, tracker: tracker) != afterRow)
        #expect(TripsListView.makeTemporaryHomeCardsRecomputeKey(
            followEvidence: follows, clockTick: 0, cardsClockTick: 1, tracker: tracker) != afterRow)
    }

    @Test("the list wakes at the earliest card reload ahead of now")
    func nextCardsReload() {
        let now = at(2025, 9, 30, 14)
        let end = at(2025, 9, 30, 15)
        let start = at(2025, 10, 1, 0)
        #expect(TripsListView.nextTemporaryHomeCardsReload([nil, start, end], now: now) == end)
        // Instants at or before now are no wake.
        #expect(TripsListView.nextTemporaryHomeCardsReload([now, at(2025, 9, 1)], now: now) == nil)
        #expect(TripsListView.nextTemporaryHomeCardsReload([nil], now: now) == nil)
        #expect(TripsListView.nextTemporaryHomeCardsReload([], now: now) == nil)
    }

    // MARK: - Suggestion freshness

    @Test("an open trip of 13 or more civil days makes the list follow stays for the suggestion, with no temporary home; a shorter or completed one does not")
    func suggestionFollowsStaysForALongOpenTrip() {
        let start = at(2025, 9, 1, 9)
        // 1 to 13 September: 13 civil days.
        #expect(TripsListView.suggestionFollowsStays(
            isComplete: false, startDate: start, now: at(2025, 9, 13, 8), timeZone: utc))
        #expect(!TripsListView.suggestionFollowsStays(
            isComplete: false, startDate: start, now: at(2025, 9, 12, 23), timeZone: utc))
        #expect(!TripsListView.suggestionFollowsStays(
            isComplete: true, startDate: start, now: at(2025, 10, 30), timeZone: utc))
    }

    @Test("while it follows stays, a stay change alone moves the suggestion's key; otherwise the list observes none")
    func suggestionStayTokenFollowsOnlyStays() {
        let tracker = StoreChangeTracker(forTesting: ())
        let before = TripsListView.suggestionStayToken(followsStays: true, tracker: tracker)
        tracker.applyNowForTesting(.stay)
        let afterStay = TripsListView.suggestionStayToken(followsStays: true, tracker: tracker)
        #expect(afterStay != before)
        // A stay write with no trip write still reruns the suggestions.
        tracker.applyNowForTesting(.trip)
        #expect(TripsListView.suggestionStayToken(followsStays: true, tracker: tracker) == afterStay)

        #expect(TripsListView.suggestionStayToken(followsStays: false, tracker: tracker) == 0)
        tracker.applyNowForTesting(.stay)
        #expect(TripsListView.suggestionStayToken(followsStays: false, tracker: tracker) == 0)
    }

    @Test("the trip detail wakes at the next local midnight while its open trip is short of 14 days, and not after")
    func detailWakesAtTheNextCivilDay() {
        let start = at(2025, 9, 1, 9)
        // Day 13: the next midnight makes it day 14.
        #expect(TripDetailView.nextSuggestionDayBoundary(
            isComplete: false, startDate: start, now: at(2025, 9, 13, 20), timeZone: utc)
            == at(2025, 9, 14, 0))
        #expect(TripDetailView.nextSuggestionDayBoundary(
            isComplete: false, startDate: start, now: at(2025, 9, 1, 10), timeZone: utc)
            == at(2025, 9, 2, 0))
        // Day 14: the suggestion is already eligible by days.
        #expect(TripDetailView.nextSuggestionDayBoundary(
            isComplete: false, startDate: start, now: at(2025, 9, 14, 0), timeZone: utc) == nil)
        #expect(TripDetailView.nextSuggestionDayBoundary(
            isComplete: true, startDate: start, now: at(2025, 9, 5), timeZone: utc) == nil)
        // Midnight is read in the device zone.
        let athens = TimeZone(identifier: "Europe/Athens")!
        #expect(TripDetailView.nextSuggestionDayBoundary(
            isComplete: false, startDate: start, now: at(2025, 9, 5, 12), timeZone: athens)
            == at(2025, 9, 5, 21))
    }

    // MARK: - Map picker

    @Test("the picker opens on the bound pin, Athens only without one")
    func mapPickerOpensOnThePin() {
        let brussels = CLLocationCoordinate2D(latitude: 50.8445, longitude: 4.3099)
        let region = MapLocationPicker.initialRegion(selected: brussels)
        #expect(region.center.latitude == brussels.latitude)
        #expect(region.center.longitude == brussels.longitude)

        let fallback = MapLocationPicker.initialRegion(selected: nil)
        #expect(fallback.center.latitude == 37.98)
        #expect(fallback.center.longitude == 23.73)

        let invalid = MapLocationPicker.initialRegion(selected: kCLLocationCoordinate2DInvalid)
        #expect(invalid.center.latitude == 37.98)
    }
}

// MARK: - Pending removals and the suggestion pass key

extension TemporaryHomeListUITests {

    private typealias Status = CoverageReconciliationQueue.TemporaryHomeStatus

    /// A 2025 date in UTC, moved 273 days later unless `shiftDates` is false.
    private func fixtureDate(_ month: Int, _ day: Int, _ hour: Int = 12, shiftDates: Bool = true) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
            .addingTimeInterval(shiftDates ? 23_587_200 : 0)
    }

    private func anchor(id: UUID = UUID(), from start: Date, to end: Date? = nil) -> HomeAnchor {
        HomeAnchor(
            id: id, kind: .temporary, label: "", latitude: 50.8132, longitude: 4.3502,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    // MARK: - Removed temporary homes still owed an update

    @Test("Settings lists a removed temporary home while its update is owed, by its name and status; a live one or a settled removal is not listed")
    func pendingRemovalsFollowTheQueue() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let live = TemporaryHome(label: "Erasmus", latitude: 50.8132, longitude: 4.3502, startedAt: fixtureDate(9, 1))
        let failed = TemporaryHome(label: "", latitude: 41.4021, longitude: 2.2394, startedAt: fixtureDate(3, 1))
        failed.locality = "Barcelona"
        failed.removedAt = fixtureDate(9, 20)
        // A live twin of a removed id: the id reads as removed.
        let twin = TemporaryHome(label: "", latitude: 41.4021, longitude: 2.2394, startedAt: fixtureDate(3, 1))
        twin.id = failed.id
        twin.locality = "Barcelona"
        let waiting = TemporaryHome(label: "Lisbon flat", latitude: 38.6835, longitude: -9.1346, startedAt: fixtureDate(6, 1))
        waiting.removedAt = fixtureDate(9, 21)
        let settled = TemporaryHome(label: "Beringen", latitude: 51.0495, longitude: 5.2294, startedAt: fixtureDate(1, 1))
        settled.removedAt = fixtureDate(9, 22)
        for row in [live, failed, twin, waiting, settled] { context.insert(row) }
        try context.save()
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())

        let statuses: [UUID: Status] = [
            live.id: .updating, failed.id: .failed, waiting.id: .waiting,
        ]
        let listed = TemporaryHomesSettingsSection.pendingRemovals(rows) { statuses[$0] }
        // Newest first, one row per id.
        #expect(listed == [
            .init(id: waiting.id, title: "Lisbon flat", status: .waiting),
            .init(id: failed.id, title: "Barcelona", status: .failed),
        ])
        // The status goes: so does the row.
        #expect(TemporaryHomesSettingsSection.pendingRemovals(rows) { _ in nil }.isEmpty)
    }

    @Test("a pending removal row reads its status from the queue: owed is updating, settled is nil")
    func pendingRemovalReadsTheQueue() throws {
        let suite = "TemporaryHomeListUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let removed = TemporaryHome(label: "Erasmus", latitude: 50.8132, longitude: 4.3502, startedAt: fixtureDate(9, 1))
        removed.removedAt = fixtureDate(9, 20)
        context.insert(removed)
        try context.save()
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
        func listed() -> [TemporaryHomesSettingsSection.PendingRemoval] {
            TemporaryHomesSettingsSection.pendingRemovals(rows) {
                CoverageReconciliationQueue.temporaryHomeStatus(id: $0, defaults: defaults)
            }
        }
        #expect(listed().isEmpty)
        let staged = CoverageReconciliationQueue.stage(.temporaryHome, id: removed.id, defaults: defaults)
        #expect(listed() == [.init(id: removed.id, title: "Erasmus", status: .updating)])
        CoverageReconciliationQueue.complete(staged.entry, defaults: defaults)
        #expect(listed().isEmpty)
    }

    // MARK: - The suggestion pass key

    @Test("the Trips list's suggestion pass key: the same inputs give the same key, any input moves it, the zone included")
    func passKeyFollowsItsInputs() throws {
        let erasmus = anchor(from: fixtureDate(9, 20, 14))
        func passKey(
            trips: Int = 1, stays: Int = 1, declarations: [HomeAnchor]? = nil, now: Date? = nil,
            zone: TimeZone? = nil, tipLearned: Bool = false, dismissals: [String] = []
        ) -> TripsListView.SuggestionPassKey {
            TripsListView.suggestionPassKey(
                trips: trips, stays: stays, declarations: declarations ?? [erasmus],
                now: now ?? fixtureDate(9, 20, 12), timeZone: zone ?? utc, tipLearned: tipLearned,
                dismissals: dismissals)
        }
        let base = passKey()
        // The slice recompute, the card load and the stay observer for one update.
        #expect(passKey() == base)
        #expect(passKey(now: fixtureDate(9, 20, 13)) == base)
        #expect(passKey(trips: 2) != base)
        #expect(passKey(stays: 2) != base)
        #expect(passKey(declarations: []) != base)
        #expect(passKey(declarations: [anchor(id: erasmus.id, from: fixtureDate(9, 20, 14), to: fixtureDate(12, 20))]) != base)
        // A declaration that starts later today covers now from its start.
        #expect(passKey(now: fixtureDate(9, 20, 15)) != base)
        #expect(passKey(now: fixtureDate(9, 21, 0)) != passKey(now: fixtureDate(9, 20, 23)))
        #expect(passKey(tipLearned: true) != base)
        #expect(passKey(dismissals: [UUID().uuidString]) != base)
        // New York and La Paz share midnight on 6 October 2026, not a January night.
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let laPaz = try #require(TimeZone(identifier: "America/La_Paz"))
        let sixOctober = Date(timeIntervalSince1970: 1_791_288_000)
        #expect(passKey(now: sixOctober, zone: newYork).day == passKey(now: sixOctober, zone: laPaz).day)
        #expect(passKey(now: sixOctober, zone: newYork) != passKey(now: sixOctober, zone: laPaz))
    }
}
