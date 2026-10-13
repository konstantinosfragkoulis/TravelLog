//
//  TemporaryHomeListUITests.swift
//  TravelLogTests
//
//  The trips list and trip detail around temporary homes, through their pure
//  seams: the suggestion line's copy and which trips it is evaluated for,
//  the demotion tip skipping a suggested trip, the cards' reload key
//  for ended cards and their clock, and the map picker opening on the
//  bound pin. Dates are in UTC and written out by hand.
//

import CoreLocation
import Foundation
import MapKit
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
