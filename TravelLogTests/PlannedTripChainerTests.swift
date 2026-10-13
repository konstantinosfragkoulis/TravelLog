//
//  PlannedTripChainerTests.swift
//  TravelLogTests
//
//  Three stay events and three ferry legs form one journey.
//  The return to Agios Dimitrios is excluded from the destination list,
//  leaving the journey named "Cephalonia → Lefkada".
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct PlannedTripChainerTests {

    private let day: TimeInterval = 24 * 3600
    private let base = Date(timeIntervalSince1970: 1_784_880_000)

    private func leg(
        _ title: String,
        startDay: Double,
        endDay: Double,
        confidence: PlannedTripConfidence = .high,
        uuid: String? = nil
    ) -> PlannedTripChainer.Leg {
        PlannedTripChainer.Leg(
            id: uuid.flatMap(UUID.init(uuidString:)) ?? UUID(),
            title: title,
            startDate: base.addingTimeInterval(startDay * day),
            endDate: base.addingTimeInterval(endDay * day),
            confidence: confidence
        )
    }

    @Test("journey display dates exclude the following midnight and preserve timed endpoints")
    func displayDateRangeUsesLastCoveredDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Athens")!
        let start = calendar.date(from: DateComponents(year: 2031, month: 3, day: 4))!
        let midnight = calendar.date(from: DateComponents(year: 2031, month: 3, day: 8))!
        func journey(ending end: Date) -> PlannedJourney {
            PlannedJourney(id: UUID(), legIDs: [], destinations: [], fallbackTitle: "Trip",
                           startDate: start, endDate: end, confidence: .high)
        }
        let allDay = journey(ending: midnight).displayDateRange(calendar: calendar)
        #expect(allDay.lowerBound == start)
        #expect(allDay.upperBound == midnight.addingTimeInterval(-1))
        #expect(calendar.component(.day, from: allDay.upperBound) == 7)
        let timedEnd = midnight.addingTimeInterval(3600)
        #expect(journey(ending: timedEnd).displayDateRange(calendar: calendar).upperBound == timedEnd)
        #expect(journey(ending: start).displayDateRange(calendar: calendar) == (start..<start))
        #expect(journey(ending: start.addingTimeInterval(-3600)).displayDateRange(calendar: calendar) == (start..<start))
    }

    // MARK: - The island chain

    /// Agios Dimitrios → Cephalonia → Lefkada → Agios Dimitrios. Three stay events + three ferry
    /// legs. One carries a multiword vessel name in its "from" slot.
    private var islandHop: [PlannedTripChainer.Leg] {
        [
            leg("Boat: APOKORONAS LINES from Agios Dimitrios to Cephalonia", startDay: 0, endDay: 0.2, confidence: .medium),
            leg("Trip to Cephalonia", startDay: 0, endDay: 4),
            leg("Boat: KASSANDRA LINES from Cephalonia to Lefkada", startDay: 4, endDay: 4.1, confidence: .medium),
            leg("Trip to Lefkada", startDay: 4, endDay: 8),
            leg("Boat: SKOUROS LINES from LAVREOTIKI AKROTIRAKI to Agios Dimitrios", startDay: 8, endDay: 8.2, confidence: .medium),
            leg("Trip to Agios Dimitrios", startDay: 8, endDay: 8.5),
        ]
    }

    @Test func islandHopChainsToOneJourneyNamedByStays() {
        let journeys = PlannedTripChainer.journeys(from: islandHop, homeNames: [])

        #expect(journeys.count == 1)
        let journey = journeys[0]
        // "Trip to Agios Dimitrios" is the return to the chain's own origin
        // (leg 1's "from Agios Dimitrios"); excluded from the name even with NO
        // home data. Ferry destinations don't name the journey when stay
        // legs exist.
        #expect(journey.displayName == "Cephalonia → Lefkada")
        #expect(journey.legCount == 6)
        #expect(journey.startDate == base)
        #expect(journey.endDate == base.addingTimeInterval(8.5 * day))
        #expect(journey.confidence == .high)
    }

    @Test func homeNameExcludesReturnLegWithoutTransportOrigin() {
        // No boat events; only the three stay events. The chain has no
        // named origin, so return detection must come from Home names.
        let staysOnly = [
            leg("Trip to Cephalonia", startDay: 0, endDay: 4),
            leg("Trip to Lefkada", startDay: 4, endDay: 8),
            leg("Trip to Agios Dimitrios", startDay: 8, endDay: 8.5),
        ]
        let withHome = PlannedTripChainer.journeys(from: staysOnly, homeNames: ["Agios Dimitrios"])
        #expect(withHome.count == 1)
        #expect(withHome[0].displayName == "Cephalonia → Lefkada")

        // Without home data the heuristic honestly can't know; Agios Dimitrios
        // stays a destination.
        let withoutHome = PlannedTripChainer.journeys(from: staysOnly, homeNames: [])
        #expect(withoutHome[0].displayName == "Cephalonia → Lefkada → Agios Dimitrios")
    }

    @Test func gapBeyondToleranceSplitsJourneys() {
        let legs = [
            leg("Trip to Cephalonia", startDay: 0, endDay: 3),
            leg("Trip to Berlin", startDay: 10, endDay: 13),  // 7-day gap
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys.count == 2)
        #expect(journeys[0].displayName == "Cephalonia")
        #expect(journeys[1].displayName == "Berlin")
    }

    @Test func transitOnlyJourneyFallsBackToRouteDestinations() {
        let legs = [
            leg("Boat: KASSANDRA LINES from Cephalonia to Lefkada", startDay: 0, endDay: 0.1, confidence: .medium)
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys.count == 1)
        #expect(journeys[0].displayName == "Lefkada")
    }

    @Test func unparsableTitlesFallBackToEarliestLegTitle() {
        let legs = [leg("Sarah's Wedding", startDay: 0, endDay: 2)]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys[0].displayName == "Sarah's Wedding")
        #expect(journeys[0].destinations.isEmpty)
    }

    @Test func duplicateDestinationsCollapseCaseAndDiacriticInsensitively() {
        let legs = [
            leg("Trip to Cephalónia", startDay: 0, endDay: 2),
            leg("Ferry to cephalonia", startDay: 2, endDay: 2.1),
            leg("Trip to Lefkada", startDay: 2, endDay: 5),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys[0].displayName == "Cephalónia → Lefkada")
    }

    @Test func journeysAreDeterministicUnderInputShuffle() {
        // Same leg instances (same ids), different input order.
        let legs = islandHop
        let forward = PlannedTripChainer.journeys(from: legs, homeNames: [])
        let shuffled = PlannedTripChainer.journeys(from: legs.reversed(), homeNames: [])
        #expect(forward == shuffled)
    }

    @Test func confidenceIsMaxOfLegs() {
        let legs = [
            leg("Boat: KASSANDRA LINES from Cephalonia to Lefkada", startDay: 0, endDay: 0.1, confidence: .low),
            leg("Hotel: Lefkada Palace", startDay: 0, endDay: 3, confidence: .medium),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys[0].confidence == .medium)
    }

    // MARK: - Chain boundaries

    /// The motivating over-merge: flying home Saturday and driving to an
    /// unrelated wedding Sunday is TWO journeys, 24 h apart or not.
    @Test func returnHomeThenUnrelatedTripSplits() {
        let legs = [
            leg("Trip to Portugal", startDay: 0, endDay: 5),
            leg("Flight: TAP from Faro to London", startDay: 5, endDay: 5.1, confidence: .medium),
            leg("Drive to Sarah's Wedding", startDay: 6, endDay: 6.5),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: ["London"])
        #expect(journeys.count == 2)
        #expect(journeys[0].displayName == "Portugal")
        #expect(journeys[1].displayName == "Sarah's Wedding")
    }

    /// Without Home data the heuristic honestly can't spot the return;
    /// temporal chaining is the documented fallback.
    @Test func returnHomeSplitsOnlyWithHomeNames() {
        let legs = [
            leg("Trip to Portugal", startDay: 0, endDay: 5),
            leg("Flight: TAP from Faro to London", startDay: 5, endDay: 5.1, confidence: .medium),
            leg("Drive to Sarah's Wedding", startDay: 6, endDay: 6.5),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: [])
        #expect(journeys.count == 1)
    }

    /// The island hop must STILL merge with Home names set: the return
    /// ferry closes the chain, but the trailing "Trip to <home>" stay is
    /// itself home-referencing and belongs to the same journey.
    @Test func islandHopStaysOneJourneyWithHomeNames() {
        let journeys = PlannedTripChainer.journeys(from: islandHop, homeNames: ["Agios Dimitrios"])
        #expect(journeys.count == 1)
        #expect(journeys[0].displayName == "Cephalonia → Lefkada")
        #expect(journeys[0].legCount == 6)
    }

    /// Leaving from home toward a place the chain never mentioned starts a
    /// new journey even when no return event was booked.
    @Test func departingHomeAnewSplitsWithoutReturnEvent() {
        let legs = [
            leg("Trip to Portugal", startDay: 0, endDay: 5),
            leg("Drive from London to Cotswolds", startDay: 6, endDay: 6.5),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: ["London"])
        #expect(journeys.count == 2)
        #expect(journeys[1].displayName == "Cotswolds")
    }

    /// A home-origin transport leg stays attached when an all-day stay
    /// event for the same destination sorted ahead of it (all-day events
    /// start at midnight, before the morning flight).
    @Test func homeOriginFlightMergesWhenStayEventSortsFirst() {
        let legs = [
            leg("Trip to Rome", startDay: 0, endDay: 4),
            leg("Flight: A3 650 from Athens to Rome", startDay: 0.3, endDay: 0.4, confidence: .medium),
        ]
        let journeys = PlannedTripChainer.journeys(from: legs, homeNames: ["Athens"])
        #expect(journeys.count == 1)
        #expect(journeys[0].displayName == "Rome")
    }

    // MARK: - Widget start transition

    /// A timed first leg departing before the widget's next midnight
    /// refresh gets its own "On trip" timeline entry at departure.
    @Test func startTransitionDateFallsBetweenNowAndRefresh() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 1, day: day + 6, hour: hour, second: second))!
        }
        let now = at(19, 9)
        let refresh = at(20, 0, 60)

        #expect(PlannedTripChainer.startTransitionDate(journeyStart: at(19, 14), now: now, refresh: refresh) == at(19, 14))
        #expect(PlannedTripChainer.startTransitionDate(journeyStart: now, now: now, refresh: refresh) == nil)
        #expect(PlannedTripChainer.startTransitionDate(journeyStart: at(19, 8), now: now, refresh: refresh) == nil)
        #expect(PlannedTripChainer.startTransitionDate(journeyStart: at(20, 0, 30), now: now, refresh: refresh) == at(20, 0, 30))
        #expect(PlannedTripChainer.startTransitionDate(journeyStart: at(21, 0), now: now, refresh: refresh) == nil)
    }

    // MARK: - Route extraction

    @Test func extractRouteParsesCommonShapes() {
        #expect(PlannedTripChainer.extractRoute(title: "Trip to Cephalonia").destination == "Cephalonia")
        #expect(PlannedTripChainer.extractRoute(title: "Flight to Rome!").destination == "Rome")

        let boat = PlannedTripChainer.extractRoute(title: "Boat: APOKORONAS LINES from Agios Dimitrios to Cephalonia")
        #expect(boat.origin == "Agios Dimitrios")
        #expect(boat.destination == "Cephalonia")

        // The vessel-name-in-the-from-slot case: destination still correct.
        let vessel = PlannedTripChainer.extractRoute(title: "Boat: SKOUROS LINES from LAVREOTIKI AKROTIRAKI to Agios Dimitrios")
        #expect(vessel.origin == "LAVREOTIKI AKROTIRAKI")
        #expect(vessel.destination == "Agios Dimitrios")

        let none = PlannedTripChainer.extractRoute(title: "Team standup")
        #expect(none.origin == nil)
        #expect(none.destination == nil)
    }

    @Test func transitLegDetection() {
        #expect(PlannedTripChainer.isTransitLeg(title: "Boat: KASSANDRA LINES from Cephalonia to Lefkada"))
        #expect(PlannedTripChainer.isTransitLeg(title: "Ferry from Athens to Aegina"))
        #expect(!PlannedTripChainer.isTransitLeg(title: "Trip to Cephalonia"))
        #expect(!PlannedTripChainer.isTransitLeg(title: "Hotel: Lefkada Palace"))
    }
}
