//
//  PlannedTripModelTests.swift
//  TravelLogTests
//
//  Phase 0 of the calendar integration: the `PlannedTrip` model (new in V14),
//  its string-backed enums, and the `CalendarEventSnapshot` value type.
//  EventKit round-trips themselves are device-verification territory
//  (no in-memory EKEventStore fake exists) — same constraint accepted for
//  PhotoService / WeatherEnricher.
//

import Foundation
import SwiftData
import EventKit
import Testing
@testable import TravelLog

@MainActor
struct PlannedTripModelTests {

    private func makePlannedTrip() -> PlannedTrip {
        PlannedTrip(
            eventExternalIdentifier: "ext-abc",
            eventLocalIdentifier: "local-123",
            title: "Flight to Rome",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_086_400),
            isAllDay: false,
            locationText: "Rome, Italy"
        )
    }

    @Test func insertAndFetchRoundTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        context.insert(makePlannedTrip())
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PlannedTrip>())
        #expect(fetched.count == 1)
        let row = try #require(fetched.first)
        #expect(row.eventExternalIdentifier == "ext-abc")
        #expect(row.eventLocalIdentifier == "local-123")
        #expect(row.title == "Flight to Rome")
        #expect(row.status == .upcoming)
        #expect(row.confidence == .low)
        #expect(row.matchedTripID == nil)
        #expect(row.resolvedLatitude == nil)
        #expect(row.forecastWeatherData == nil)
    }

    @Test func statusPredicateFetch() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let upcoming = makePlannedTrip()
        let matched = makePlannedTrip()
        matched.status = .matched
        matched.matchedTripID = UUID()
        context.insert(upcoming)
        context.insert(matched)
        try context.save()

        let upcomingRaw = PlannedTripStatus.upcoming.rawValue
        let predicate = #Predicate<PlannedTrip> { $0.statusRaw == upcomingRaw }
        let rows = try context.fetch(FetchDescriptor<PlannedTrip>(predicate: predicate))
        #expect(rows.count == 1)
        #expect(rows.first?.id == upcoming.id)
    }

    @Test func enumDecodeFallsBackOnUnknownRaw() {
        #expect(PlannedTripConfidence.decode("nonsense") == .low)
        #expect(PlannedTripStatus.decode("nonsense") == .upcoming)
        #expect(PlannedTripConfidence.decode("high") == .high)
        #expect(PlannedTripStatus.decode("dismissed") == .dismissed)
    }

    @Test func signalsRoundTripThroughCommaJoinedRaw() {
        let trip = makePlannedTrip()
        #expect(trip.signals.isEmpty)

        trip.signals = ["flightCode", "bookingKeyword"]
        #expect(trip.signalsRaw == "flightCode,bookingKeyword")
        #expect(trip.signals == ["flightCode", "bookingKeyword"])

        trip.signals = []
        #expect(trip.signalsRaw == "")
        #expect(trip.signals.isEmpty)
    }

    @Test func typedAccessorsWriteRawFields() {
        let trip = makePlannedTrip()
        trip.confidence = .high
        trip.status = .expired
        #expect(trip.confidenceRaw == "high")
        #expect(trip.statusRaw == "expired")
    }

    // MARK: - CalendarEventSnapshot

    @Test func snapshotAdapterRejectsEventWithoutIdentifier() {
        // An EKEvent constructed in memory and never saved has a nil
        // `eventIdentifier` — the adapter must skip it, not trap on the
        // implicitly-unwrapped optional.
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Unsaved"
        event.startDate = .now
        event.endDate = .now.addingTimeInterval(3600)
        #expect(CalendarEventSnapshot(event: event) == nil)
    }

    @Test func calendarKindMapsNilCalendarToOther() {
        #expect(CalendarKind(calendar: nil) == .other)
    }
}
