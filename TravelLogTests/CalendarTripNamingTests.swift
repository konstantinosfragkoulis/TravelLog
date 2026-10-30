//
//  CalendarTripNamingTests.swift
//  TravelLogTests
//
//  Calendar-hint scoring for the Stage-2 classification prompt - pure
//  functions over snapshots - plus the flight-event predicate TransitInferer's
//  corroboration path uses. The title lane that used to share this scorer
//  was removed: calendar text never reaches a title, so there
//  is nothing title-shaped left to vet here. The prompt's rendering of the
//  hint as a `CALENDAR:` line is covered at the end.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct CalendarTripNamingTests {

    private let tripStart = Date(timeIntervalSince1970: 1_790_844_800)
    private var tripEnd: Date { tripStart.addingTimeInterval(3 * 86_400) }

    private func event(
        _ title: String,
        location: String? = nil,
        startOffsetHours: Double = 0,
        durationHours: Double = 5,
        recurring: Bool = false,
        detached: Bool = false,
        localIdentifier: String = "e1"
    ) -> CalendarEventSnapshot {
        let start = tripStart.addingTimeInterval(startOffsetHours * 3600)
        return CalendarEventSnapshot(
            externalIdentifier: nil,
            localIdentifier: localIdentifier,
            title: title,
            notes: nil,
            locationText: location,
            startDate: start,
            endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: false,
            hasRecurrenceRules: recurring,
            isDetached: detached,
            calendarTitle: "Personal",
            calendarKind: .icloud
        )
    }

    // MARK: - bestCandidate

    @Test func weddingWithVenueCityBeatsRecurringOverlap() {
        let candidate = CalendarTripNaming.bestCandidate(
            events: [
                event("Book Club", startOffsetHours: 4, durationHours: 2, recurring: true, localIdentifier: "e1"),
                event("Sarah's Wedding", location: "Estufa Fria, Lisbon", startOffsetHours: 24, durationHours: 6, localIdentifier: "e2"),
            ],
            tripStart: tripStart, tripEnd: tripEnd,
            tripPlaceNames: ["Lisbon"]
        )
        #expect(candidate == "Sarah's Wedding")
    }

    @Test func genericBoilerplateTitlesAreDenied() {
        for title in ["Vacation", "OOO", "Out of office", "PTO", "busy", "Holiday"] {
            let candidate = CalendarTripNaming.bestCandidate(
                events: [event(title, durationHours: 72)],
                tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: []
            )
            #expect(candidate == nil, Comment(rawValue: title))
        }
    }

    @Test func transportBookingsAreNotCandidates() {
        let candidate = CalendarTripNaming.bestCandidate(
            events: [event("Boat: KASSANDRA LINES from Kephallenia to Lefkada", durationHours: 72)],
            tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Kephallenia"]
        )
        #expect(candidate == nil)
    }

    @Test func fullCoverageIsEvidenceEvenWithoutPlaceAgreement() {
        // A multi-day event spanning the window is classification evidence
        // whether or not its text names the place.
        let events = [event("Web Summit 2027", durationHours: 3 * 24)]
        #expect(CalendarTripNaming.bestCandidate(
            events: events, tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Lisbon"]) == "Web Summit 2027")
    }

    @Test func routePaperworkIsKept() {
        // A ferry booking is real classification evidence for an ambiguous
        // imported stay; the (removed) title lane was the only caller that
        // ever rejected these.
        let candidate = CalendarTripNaming.bestCandidate(
            events: [event("Athens - Aegina ferry", durationHours: 72)],
            tripStart: tripStart, tripEnd: tripEnd,
            tripPlaceNames: ["Aegina"]
        )
        #expect(candidate == "Athens - Aegina ferry")
    }

    @Test func birthdayCalendarsNeverQualify() {
        let birthday = CalendarEventSnapshot(
            externalIdentifier: nil, localIdentifier: "b1",
            title: "Γιάννης's birthday", notes: nil, locationText: nil,
            startDate: tripStart, endDate: tripStart.addingTimeInterval(3 * 86_400),
            isAllDay: true, hasRecurrenceRules: true, isDetached: false,
            calendarTitle: "Birthdays", calendarKind: .birthday)
        #expect(CalendarTripNaming.bestCandidate(
            events: [birthday], tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Kephallenia"]) == nil)
    }

    @Test func placeMatchingIsWholePhraseAndTransliterated() {
        // Whole tokens: "york" is not inside "Yorkshire"; a multi-word place
        // must appear as a contiguous phrase; "Κεφαλληνία" meets "kephallenia";
        // "Saint-Tropez" meets "Saint Tropez".
        #expect(CalendarTripNaming.matchedPlaces(in: "Yorkshire weekend", among: ["york"]).isEmpty)
        #expect(CalendarTripNaming.matchedPlaces(in: "New York weekend", among: ["new york"]) == ["new york"])
        #expect(CalendarTripNaming.matchedPlaces(in: "York, then New Haven", among: ["new york"]).isEmpty)
        #expect(CalendarTripNaming.matchedPlaces(in: "Γάμος στην Κεφαλληνία", among: ["kephallenia"]) == ["kephallenia"])
        #expect(CalendarTripNaming.matchedPlaces(in: "Saint-Tropez regatta", among: ["saint tropez"]) == ["saint tropez"])
        #expect(CalendarTripNaming.bestCandidate(
            events: [event("Βάφτιση", location: "Κεφαλληνία", durationHours: 5)],
            tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Kephallenia"]) == "Βάφτιση")
    }

    @Test func shortUnrelatedEventStaysBelowThreshold() {
        // A 1-hour dinner reservation with no place agreement in a 3-day
        // window must not become the hint.
        let candidate = CalendarTripNaming.bestCandidate(
            events: [event("Dinner with Alex", durationHours: 1)],
            tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Lisbon"]
        )
        #expect(candidate == nil)
    }

    @Test func recurringEventIsHeavilyDeWeighted() throws {
        let recurring = CalendarTripNaming.namingScore(
            event("Standing offsite", location: "Lisbon", durationHours: 3 * 24, recurring: true),
            tripStart: tripStart, tripEnd: tripEnd, normalizedPlaces: ["lisbon"]
        )
        let oneOff = CalendarTripNaming.namingScore(
            event("Standing offsite", location: "Lisbon", durationHours: 3 * 24),
            tripStart: tripStart, tripEnd: tripEnd, normalizedPlaces: ["lisbon"]
        )
        let recurringScore = try #require(recurring)
        let oneOffScore = try #require(oneOff)
        #expect(recurringScore < oneOffScore)
    }

    @Test func tiebreakIsDeterministic() {
        let a = event("Conference A", location: "Lisbon", durationHours: 3 * 24, localIdentifier: "aa")
        let b = event("Conference B", location: "Lisbon", durationHours: 3 * 24, localIdentifier: "bb")
        let forward = CalendarTripNaming.bestCandidate(
            events: [a, b], tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Lisbon"])
        let reversed = CalendarTripNaming.bestCandidate(
            events: [b, a], tripStart: tripStart, tripEnd: tripEnd, tripPlaceNames: ["Lisbon"])
        #expect(forward == reversed)
        #expect(forward == "Conference A")
    }

    // MARK: - Flight-event predicate (TransitInferer corroboration)

    @Test func flightEventsAreRecognized() {
        #expect(PlannedTripDetector.isFlightEvent(event("Flight BA742 boarding")))
        #expect(PlannedTripDetector.isFlightEvent(event("Flight to Rome")))
        #expect(PlannedTripDetector.isFlightEvent(event("Flight: Athens — London")))
        #expect(PlannedTripDetector.isFlightEvent(event("U2 1234 departure")))
    }

    @Test func nonFlightEventsAreNot() {
        #expect(!PlannedTripDetector.isFlightEvent(event("Trip to Kephallenia")))
        #expect(!PlannedTripDetector.isFlightEvent(event("Boat: KASSANDRA LINES from Kephallenia to Lefkada")))
        #expect(!PlannedTripDetector.isFlightEvent(event("AA123 budget review")))
        #expect(!PlannedTripDetector.isFlightEvent(event("Dinner with Alex")))
    }
}
