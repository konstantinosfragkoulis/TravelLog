//
//  TemporaryHomeCardsTests.swift
//  TravelLogTests
//
//  The Temporary Homes section of the trips list shows one card per
//  temporary home: its state, its days, the trips taken from it and the
//  visits home, plus a hint to end it once the user is back home. The trip
//  header names the temporary home a trip left from, and "Set Up a Temporary
//  Home…" opens the form prefilled from a trip. Everything is in UTC and
//  expected values are written out by hand.
//

import CoreLocation
import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home cards")
struct TemporaryHomeCardsTests {

    private typealias Place = (lat: Double, lon: Double)

    private let athens: Place = (37.9838, 23.7275)
    private let brussels: Place = (50.8369, 4.3016)
    private let ieper: Place = (50.8515, 2.8861)
    private let rome: Place = (41.9109, 12.4103)

    private let utc = TimeZone(secondsFromGMT: 0)!

    /// An instant on a UTC civil date.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Seeding

    /// A store whose only Home is Athens, since 2020.
    private func store() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: athens.lat, longitude: athens.lon,
                        radiusKm: 25, startedAt: at(2020, 1, 1))
        home.locality = "Athens"
        home.isoCountryCode = "GR"
        context.insert(home)
        return (container, context)
    }

    @discardableResult
    private func temporaryHome(
        _ context: ModelContext, label: String = "Erasmus", locality: String? = "Brussels",
        from start: Date, to end: Date? = nil
    ) -> TemporaryHome {
        let row = TemporaryHome(
            label: label, latitude: brussels.lat, longitude: brussels.lon,
            startedAt: start, endedAt: end)
        row.locality = locality
        row.country = "Belgium"
        row.isoCountryCode = "BE"
        row.timeZoneIdentifier = "UTC"
        context.insert(row)
        return row
    }

    /// `owner` is the temporary home its home writer recorded, as the
    /// classifier stamps a stay it makes home inside a temporary home's dates.
    @discardableResult
    private func stay(
        _ context: ModelContext, _ category: StayCategory, at place: Place,
        from start: Date, to end: Date, trip: Trip? = nil, by owner: TemporaryHome? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        stay.category = category
        stay.temporaryHomeID = owner?.id
        context.insert(stay)
        if let trip { stay.trip = trip }
        return stay
    }

    /// A completed trip with one destination stay over its dates.
    @discardableResult
    private func trip(_ context: ModelContext, to place: Place, from start: Date, to end: Date) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = true
        context.insert(trip)
        stay(context, .destination, at: place, from: start, to: end, trip: trip)
        return trip
    }

    private func load(_ container: ModelContainer, now: Date) throws -> [TemporaryHomeCards.Card] {
        try TemporaryHomeCards.load(container: container, now: now, fallbackZone: utc)
    }

    /// A stay at the base, then the newest stay at home in Athens: the user
    /// has left an open-ended temporary home. Three civil days back home
    /// end at midnight three dates after the return.
    private func leftForHome(end: Date? = nil) throws -> (container: ModelContainer, context: ModelContext, id: UUID) {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0), to: end)
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 14, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 6, 15, 10), to: at(2025, 6, 19, 10))
        try context.save()
        return (container, context, base.id)
    }

    // MARK: - Cards

    @Test("an active temporary home with a side trip and a weekend home shows its day, its days away and at the base, the trip from it and the visit home")
    func activeHomeWithSideTripAndVisitHome() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        // A holiday before the temporary home: not a trip from it.
        trip(context, to: rome, from: at(2024, 11, 23, 9), to: at(2024, 11, 26, 17))
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        let sideTrip = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 27, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 6, 28, 12), to: at(2025, 6, 30, 12))
        stay(context, .home, at: brussels, from: at(2025, 7, 1, 20), to: at(2025, 7, 14, 8), by: base)
        try context.save()

        let cards = try load(container, now: at(2025, 7, 19))
        let card = try #require(cards.first)
        #expect(cards.count == 1)
        #expect(card.id == base.id)
        #expect(card.title == "Erasmus")
        #expect(card.placeLine == "Brussels, Belgium")
        #expect(card.countryCode == "BE")
        #expect(card.startedAt == at(2025, 5, 26, 0))
        #expect(card.endedAt == nil)
        #expect(card.state == .active)
        // 26 May to 19 July, both counted.
        #expect(card.dayNumber == 55)
        // 27 May to 27 June (32 dates) and 1 to 19 July (19).
        #expect(card.awayDays == 51)
        // The same dates without 4, 5 and 6 June in Ieper.
        #expect(card.stayingDays == 48)
        #expect(card.tripIDs == [sideTrip.id])
        // The days recorded at the real home, not the gap from leaving
        // the base to coming back there.
        #expect(card.visitsHome == [DateInterval(start: at(2025, 6, 28, 12), end: at(2025, 6, 30, 12))])
        // The latest stay is at the base: nothing to end.
        #expect(card.suggestedEnd == nil)
        #expect(card.backHomeSince == nil)
    }

    @Test("a temporary home with no name shows its city as the title")
    func titleFallsBackToTheCity() throws {
        let (container, context) = try store()
        temporaryHome(context, label: "", from: at(2025, 5, 26, 0))
        try context.save()
        #expect(try load(container, now: at(2025, 5, 30)).map(\.title) == ["Brussels"])
    }

    @Test("an open-ended temporary home left for home three civil days ago suggests the end of the last stay there, and still does later")
    func suggestedEndAfterThreeDaysBackHome() throws {
        let (container, _, id) = try leftForHome()
        // Midnight UTC on 18 June: the third civil day after the return on 15 June.
        for now in [at(2025, 6, 18, 0), at(2025, 6, 28, 8)] {
            let card = try #require(try load(container, now: now).first)
            #expect(card.id == id)
            #expect(card.state == .active)
            #expect(card.suggestedEnd == at(2025, 6, 14, 8))
            #expect(card.backHomeSince == at(2025, 6, 15, 10))
            // The days stop at the last stay there.
            #expect(card.awayDays == 19)
            // The visit home is the final return, still going on.
            #expect(card.visitsHome == [DateInterval(start: at(2025, 6, 15, 10), end: now)])
        }
    }

    @Test("before three civil days back home the card asks nothing yet, while the detail's End already presets the last day there")
    func noSuggestedEndBeforeThreeDays() throws {
        let (container, _, _) = try leftForHome()
        for now in [at(2025, 6, 15, 20), at(2025, 6, 17, 12), at(2025, 6, 18, 0).addingTimeInterval(-1)] {
            let card = try #require(try load(container, now: now).first)
            #expect(card.suggestedEnd == at(2025, 6, 14, 8))
            #expect(card.backHomeSince == nil)
        }
    }

    @Test("a set end still ahead keeps the detail's preset but the card never asks, a visit home being no sign it ended; once the end has passed there is no preset")
    func suggestedEndWithASetEndAhead() throws {
        let ahead = try leftForHome(end: at(2025, 9, 13, 23))
        let card = try #require(try load(ahead.container, now: at(2025, 7, 14)).first)
        #expect(card.state == .active)
        #expect(card.suggestedEnd == at(2025, 6, 14, 8))
        #expect(card.backHomeSince == nil)

        let passed = try leftForHome(end: at(2025, 6, 24, 23))
        let ended = try #require(try load(passed.container, now: at(2025, 7, 14)).first)
        #expect(ended.state == .ended)
        #expect(ended.suggestedEnd == nil)
    }

    @Test("a trip taken after three days back home keeps the suggestion")
    func suggestedEndSurvivesALaterTrip() throws {
        let (container, context, _) = try leftForHome()
        let open = Trip(startDate: at(2025, 7, 4, 9))
        context.insert(open)
        stay(context, .destination, at: rome, from: at(2025, 7, 4, 9), to: at(2025, 7, 6, 17), trip: open)
        try context.save()
        let card = try #require(try load(container, now: at(2025, 7, 14)).first)
        #expect(card.suggestedEnd == at(2025, 6, 14, 8))
        #expect(card.backHomeSince == at(2025, 6, 15, 10))
    }

    @Test("leaving home again before three civil days ends that stretch without a suggestion; a later stretch of three days asks, from its own start")
    func shortStretchHomeThenLongerOne() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 14, 8), by: base)
        // Home on 15 June, off to Rome on 17 June: two civil days.
        stay(context, .home, at: athens, from: at(2025, 6, 15, 10), to: at(2025, 6, 17, 8))
        trip(context, to: rome, from: at(2025, 6, 17, 12), to: at(2025, 6, 22, 17))
        try context.save()
        let short = try #require(try load(container, now: at(2025, 7, 4)).first)
        #expect(short.backHomeSince == nil)
        // The detail's End still presets the last day at the base.
        #expect(short.suggestedEnd == at(2025, 6, 14, 8))

        // Back home on 23 June, the newest stay: the third civil day begins on 26 June.
        stay(context, .home, at: athens, from: at(2025, 6, 23, 10), to: at(2025, 6, 25, 10))
        try context.save()
        #expect(try load(container, now: at(2025, 6, 26, 0).addingTimeInterval(-1)).first?.backHomeSince == nil)
        let later = try #require(try load(container, now: at(2025, 6, 26, 0)).first)
        #expect(later.suggestedEnd == at(2025, 6, 14, 8))
        #expect(later.backHomeSince == at(2025, 6, 23, 10))
    }

    @Test("a routine stay at home neither ends the stretch nor starts one, and a single unbacked fix at home starts none")
    func routineAndLoneFixAtHome() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 14, 8), by: base)
        let loneFix = stay(context, .home, at: athens, from: at(2025, 6, 14, 20), to: at(2025, 6, 14, 20))
        loneFix.pingCount = 1
        stay(context, .home, at: athens, from: at(2025, 6, 15, 10), to: at(2025, 6, 16, 8))
        stay(context, .routine, at: athens, from: at(2025, 6, 16, 9), to: at(2025, 6, 16, 17))
        stay(context, .home, at: athens, from: at(2025, 6, 16, 18), to: at(2025, 6, 19, 8))
        try context.save()
        // The stretch runs from the first home stay, through the routine stay.
        let card = try #require(try load(container, now: at(2025, 6, 18, 12)).first)
        #expect(card.backHomeSince == at(2025, 6, 15, 10))
        #expect(card.suggestedEnd == at(2025, 6, 14, 8))
    }

    @Test("days recorded as routine elsewhere end a stretch at home: two short stops at home around them are two visits home, and neither asks to end the temporary home")
    func longRoutineSeparatesTwoVisitsHome() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 14, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 6, 15, 10), to: at(2025, 6, 15, 20))
        // Three days at a routine place 60 km from home.
        stay(context, .routine, at: (38.2, 23.2), from: at(2025, 6, 15, 22), to: at(2025, 6, 18, 18))
        stay(context, .home, at: athens, from: at(2025, 6, 18, 20), to: at(2025, 6, 19, 9))
        trip(context, to: rome, from: at(2025, 6, 19, 12), to: at(2025, 6, 22, 17))
        try context.save()

        let card = try #require(try load(container, now: at(2025, 6, 29)).first)
        #expect(card.visitsHome == [
            DateInterval(start: at(2025, 6, 15, 10), end: at(2025, 6, 15, 20)),
            DateInterval(start: at(2025, 6, 18, 20), end: at(2025, 6, 19, 9)),
        ])
        #expect(card.backHomeSince == nil)
        #expect(card.suggestedEnd == at(2025, 6, 14, 8))
    }

    @Test("a routine stay shorter than 12 hours inside a stretch at home, a gym or an office day, neither ends nor splits it; one of 12 hours ends it",
          arguments: [2.0, 11.9, 12.0])
    func routineStayLengthAtHome(hours: Double) throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 14, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 6, 15, 10), to: at(2025, 6, 16, 8))
        let routineStart = at(2025, 6, 16, 8).addingTimeInterval(30 * 60)
        let routineEnd = routineStart.addingTimeInterval(hours * 3600)
        stay(context, .routine, at: athens, from: routineStart, to: routineEnd)
        let backFrom = routineEnd.addingTimeInterval(30 * 60)
        stay(context, .home, at: athens, from: backFrom, to: at(2025, 6, 18, 12))
        trip(context, to: rome, from: at(2025, 6, 18, 15), to: at(2025, 6, 22, 17))
        try context.save()

        // Together the stretch reaches its third civil day; the
        // part after a long routine stay alone does not.
        let card = try #require(try load(container, now: at(2025, 6, 29)).first)
        if hours < 12 {
            #expect(card.visitsHome == [DateInterval(start: at(2025, 6, 15, 10), end: at(2025, 6, 18, 12))])
            #expect(card.backHomeSince == at(2025, 6, 15, 10))
        } else {
            #expect(card.visitsHome == [
                DateInterval(start: at(2025, 6, 15, 10), end: at(2025, 6, 16, 8)),
                DateInterval(start: backFrom, end: at(2025, 6, 18, 12)),
            ])
            #expect(card.backHomeSince == nil)
        }
    }

    @Test("cards come active first, then upcoming, then ended with the latest end first")
    func ordering() throws {
        let (container, context) = try store()
        let now = at(2025, 6, 25)
        let endedLongAgo = temporaryHome(context, label: "First", from: at(2023, 10, 4, 0), to: at(2024, 3, 24, 23))
        let upcoming = temporaryHome(context, label: "Next", from: at(2025, 7, 26, 0), to: at(2025, 11, 22, 23))
        let endedLately = temporaryHome(context, label: "Second", from: at(2024, 10, 26, 0), to: at(2025, 3, 24, 23))
        let active = temporaryHome(context, label: "Now", from: at(2025, 6, 15, 0))
        try context.save()

        let cards = try load(container, now: now)
        #expect(cards.map(\.id) == [active.id, upcoming.id, endedLately.id, endedLongAgo.id])
        #expect(cards.map(\.state) == [.active, .upcoming, .ended, .ended])
        // Only the active one counts its day: 15 to 25 June.
        #expect(cards.map(\.dayNumber) == [11, nil, nil, nil])
        // No stay at any of them: a declaration alone counts no days.
        #expect(cards.allSatisfy { $0.awayDays == 0 && $0.stayingDays == 0 && $0.tripIDs.isEmpty })
    }

    // MARK: - Trips from here

    /// A semester in Brussels with three trips, each given
    /// by its id and its start: the journey out from Athens through Rome, a
    /// weekend in Ieper from the base, and the way back to the base from a
    /// weekend home in Athens.
    private func semesterWithThreeTrips() throws -> (
        container: ModelContainer,
        arrival: (id: UUID, start: Date),
        fromBase: (id: UUID, start: Date),
        fromVisitHome: (id: UUID, start: Date)
    ) {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        let arrival = trip(context, to: rome, from: at(2025, 5, 26, 9), to: at(2025, 5, 27, 8))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        let fromBase = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 27, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 6, 28, 12), to: at(2025, 6, 30, 12))
        let fromVisitHome = trip(context, to: rome, from: at(2025, 6, 30, 15), to: at(2025, 7, 1, 18))
        stay(context, .home, at: brussels, from: at(2025, 7, 1, 20), to: at(2025, 7, 14, 8), by: base)
        try context.save()
        return (
            container: container,
            arrival: (id: arrival.id, start: at(2025, 5, 26, 9)),
            fromBase: (id: fromBase.id, start: at(2025, 6, 4, 9)),
            fromVisitHome: (id: fromVisitHome.id, start: at(2025, 6, 30, 15)))
    }

    @Test("a trip that left the real home and ended at the temporary home is not one of its trips")
    func arrivalTripIsNotFromHere() throws {
        let semester = try semesterWithThreeTrips()
        let card = try #require(try load(semester.container, now: at(2025, 7, 19)).first)
        #expect(!card.tripIDs.contains(semester.arrival.id))
        // The trip's own header says the same: it reads "from home".
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: semester.arrival.start, container: semester.container) == nil)
    }

    @Test("a trip that left from the temporary home is its one trip, and its header names the temporary home's city")
    func tripFromTheBaseIsFromHere() throws {
        let semester = try semesterWithThreeTrips()
        let card = try #require(try load(semester.container, now: at(2025, 7, 19)).first)
        #expect(card.tripIDs == [semester.fromBase.id])
        #expect(TemporaryHomeCardRow.detailParts(awayDays: 0, tripCount: card.tripIDs.count) == ["1 trip"])
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: semester.fromBase.start, container: semester.container) == "Brussels")
    }

    @Test("a trip that started during a visit home and ended at the temporary home is not one of its trips")
    func tripFromAVisitHomeIsNotFromHere() throws {
        let semester = try semesterWithThreeTrips()
        let card = try #require(try load(semester.container, now: at(2025, 7, 19)).first)
        #expect(!card.tripIDs.contains(semester.fromVisitHome.id))
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: semester.fromVisitHome.start, container: semester.container) == nil)
    }

    @Test("the header's flags are the base country, then the countries of the trips from here in first-visit order, each once")
    func headerFlagsFollowTheTripsFromHere() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        // The journey out passed through Italy: not a trip from here, so no Italian flag.
        let arrival = trip(context, to: rome, from: at(2025, 5, 26, 9), to: at(2025, 5, 27, 8))
        arrival.countryCodes = "IT"
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        let first = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        first.countryCodes = "NL,BE"
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 13, 8), by: base)
        let second = trip(context, to: ieper, from: at(2025, 6, 14, 9), to: at(2025, 6, 16, 17))
        second.countryCodes = "DE,NL"
        stay(context, .home, at: brussels, from: at(2025, 6, 16, 21), to: at(2025, 6, 24, 8), by: base)
        try context.save()

        let card = try #require(try load(container, now: at(2025, 6, 25)).first)
        #expect(card.tripIDs == [first.id, second.id])
        #expect(card.tripCountryCodes == ["NL", "BE", "DE"])
        // Belgium is the base's own country: first, and not repeated for the trip there.
        let belgium = "\u{1F1E7}\u{1F1EA}"
        let netherlands = "\u{1F1F3}\u{1F1F1}"
        let germany = "\u{1F1E9}\u{1F1EA}"
        #expect(card.countryFlags == [belgium, netherlands, germany].joined(separator: " "))
    }

    @Test("a temporary home with no trip from it shows its own flag alone")
    func headerFlagWithoutTrips() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        try context.save()

        let card = try #require(try load(container, now: at(2025, 6, 9)).first)
        #expect(card.tripCountryCodes.isEmpty)
        #expect(card.countryFlags == "\u{1F1E7}\u{1F1EA}")
    }

    // MARK: - Trips list sections

    @Test("a card that ended exactly 30 days ago stays in the top section with the upcoming and active ones; one that ended a second earlier moves to the past section")
    func sectionsSplitThirtyDaysAfterTheEnd() throws {
        let (container, context) = try store()
        // Noon on 25 July; 30 days of 86,400 seconds earlier is noon on 25 June.
        let now = at(2025, 7, 25)
        let boundary = now.addingTimeInterval(-30 * 86_400)
        #expect(boundary == at(2025, 6, 25))
        let active = temporaryHome(context, label: "Now", from: at(2025, 7, 24, 13))
        let upcoming = temporaryHome(context, label: "Next", from: at(2025, 8, 25, 0), to: at(2025, 11, 22, 23))
        let endedYesterday = temporaryHome(context, label: "Yesterday", from: at(2025, 6, 26, 0), to: at(2025, 7, 24, 12))
        let endedAtTheBoundary = temporaryHome(context, label: "Boundary", from: at(2025, 5, 26, 0), to: boundary)
        let endedASecondEarlier = temporaryHome(
            context, label: "Earlier", from: at(2024, 10, 26, 0), to: boundary.addingTimeInterval(-1))
        let endedLongAgo = temporaryHome(context, label: "Long ago", from: at(2022, 10, 4, 0), to: at(2023, 3, 24, 23))
        try context.save()

        let sections = TemporaryHomeCards.sections(try load(container, now: now), now: now)
        #expect(sections.current.map(\.id) == [active.id, upcoming.id, endedYesterday.id, endedAtTheBoundary.id])
        #expect(sections.current.map(\.state) == [.active, .upcoming, .ended, .ended])
        #expect(sections.past.map(\.id) == [endedASecondEarlier.id, endedLongAgo.id])
    }

    @Test("with no ended card every card is in the top section and the past section is empty")
    func sectionsWithoutEndedCards() throws {
        let (container, context) = try store()
        let now = at(2025, 7, 25)
        let active = temporaryHome(context, label: "Now", from: at(2025, 5, 26, 0), to: at(2025, 10, 25, 23))
        try context.save()

        let sections = TemporaryHomeCards.sections(try load(container, now: now), now: now)
        #expect(sections.current.map(\.id) == [active.id])
        #expect(sections.past.isEmpty)
        #expect(TemporaryHomeCards.sections([], now: now).current.isEmpty)
    }

    #if DEBUG
    private func recordingReads(
        failing target: TemporaryHomeCards.Read? = nil
    ) -> (
        log: OSAllocatedUnfairLock<[TemporaryHomeCards.Read]>,
        hook: @Sendable (TemporaryHomeCards.Read) throws -> Void
    ) {
        let log = OSAllocatedUnfairLock(initialState: [TemporaryHomeCards.Read]())
        return (log, { read in
            log.withLock { $0.append(read) }
            if read == target { throw CocoaError(.fileReadUnknown) }
        })
    }

    @Test("with no temporary home there are no cards, after one read of the temporary-home rows")
    func noTemporaryHomeReadsOnce() throws {
        let (container, context) = try store()
        trip(context, to: rome, from: at(2024, 11, 23, 9), to: at(2024, 11, 26, 17))
        stay(context, .home, at: athens, from: at(2024, 11, 27, 10), to: at(2024, 12, 12, 10))
        try context.save()

        let (log, hook) = recordingReads()
        let cards = try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
            try load(container, now: at(2025, 6, 25))
        }
        #expect(cards.isEmpty)
        #expect(log.withLock { $0 } == [.temporaryHomes])
    }

    // The hints read the ledger's own stays, so the ledger read covers them.
    @Test("a failed read throws instead of returning a card without its days, trips or hint",
          arguments: [TemporaryHomeCards.Read.temporaryHomes, .travelDays, .ledger, .trips])
    func failedReadThrows(read failing: TemporaryHomeCards.Read) throws {
        let (container, _, _) = try leftForHome()
        let (log, hook) = recordingReads(failing: failing)
        #expect(throws: CocoaError.self) {
            try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
                try load(container, now: at(2025, 7, 14))
            }
        }
        // The store reaches every one of these reads, so each case is exercised.
        #expect(log.withLock { $0 }.last == failing)
    }

    // Recorded ownership needs no Home read.
    @Test("a failed read behind the trips from here throws instead of returning a card that lists none",
          arguments: [TemporaryHomeCards.Read.departureStays])
    func failedDepartureReadThrows(read failing: TemporaryHomeCards.Read) throws {
        let semester = try semesterWithThreeTrips()
        let (log, hook) = recordingReads(failing: failing)
        #expect(throws: CocoaError.self) {
            try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
                try load(semester.container, now: at(2025, 7, 19))
            }
        }
        #expect(log.withLock { $0 }.last == failing)
    }

    @Test("three trips after the temporary home's start cost one read of the home stays they left from")
    func tripsFromHereReadTheHomeStaysOnce() throws {
        let semester = try semesterWithThreeTrips()
        let (log, hook) = recordingReads()
        let cards = try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
            try load(semester.container, now: at(2025, 7, 19))
        }
        #expect(cards.first?.tripIDs == [semester.fromBase.id])
        #expect(log.withLock { $0 }.filter { $0 == .departureStays }.count == 1)
    }

    @Test("a load cancelled during a read stops at its next check, before any later read, and throws CancellationError",
          arguments: [TemporaryHomeCards.Read.travelDays, .ledger, .trips, .departureStays])
    func cancelledLoadStopsAtItsNextCheck(during read: TemporaryHomeCards.Read) throws {
        let semester = try semesterWithThreeTrips()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let log = OSAllocatedUnfairLock(initialState: [TemporaryHomeCards.Read]())
        let hook: @Sendable (TemporaryHomeCards.Read) throws -> Void = { seen in
            log.withLock { $0.append(seen) }
            if seen == read { cancelled.withLock { $0 = true } }
        }
        #expect(throws: CancellationError.self) {
            try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
                try TemporaryHomeCards.load(
                    container: semester.container, now: at(2025, 7, 19), fallbackZone: utc
                ) {
                    if cancelled.withLock({ $0 }) { throw CancellationError() }
                }
            }
        }
        #expect(log.withLock { $0 }.last == read)
    }

    @Test("a load its caller still awaits returns the cards, and a failed read is a failure, not a superseded load")
    func ownedLoadReturnsCardsOrFailure() async throws {
        let semester = try semesterWithThreeTrips()
        let (container, now, zone) = (semester.container, at(2025, 7, 19), utc)
        let loaded = await TemporaryHomeCards.loadDetached(container: container, now: now, fallbackZone: zone)
        guard case .loaded(let cards) = loaded else {
            Issue.record("expected cards, got \(loaded)")
            return
        }
        #expect(cards.first?.tripIDs == [semester.fromBase.id])

        let (_, hook) = recordingReads(failing: .ledger)
        let failed = await TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
            await TemporaryHomeCards.loadDetached(container: container, now: now, fallbackZone: zone)
        }
        guard case .failed(let error) = failed else {
            Issue.record("expected a failure, got \(failed)")
            return
        }
        #expect(error is CocoaError)
    }

    @Test("cancelling the task that awaits a load cancels its worker, which stops before its next read: the load is superseded, never a failure")
    func cancelledOwnerSupersedesTheLoad() async throws {
        let semester = try semesterWithThreeTrips()
        let (container, now, zone) = (semester.container, at(2025, 7, 19), utc)
        let reached = OSAllocatedUnfairLock(initialState: false)
        let workerCancelled = OSAllocatedUnfairLock(initialState: false)
        let log = OSAllocatedUnfairLock(initialState: [TemporaryHomeCards.Read]())
        let hook: @Sendable (TemporaryHomeCards.Read) throws -> Void = { read in
            log.withLock { $0.append(read) }
            guard read == .travelDays else { return }
            reached.withLock { $0 = true }
            // Hold the worker here until its own task is cancelled.
            let deadline = Date.now.addingTimeInterval(5)
            while !Task.isCancelled, Date.now < deadline { usleep(1_000) }
            workerCancelled.withLock { $0 = Task.isCancelled }
        }
        let owner = Task {
            await TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
                await TemporaryHomeCards.loadDetached(container: container, now: now, fallbackZone: zone)
            }
        }
        let deadline = Date.now.addingTimeInterval(5)
        while !reached.withLock({ $0 }), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(reached.withLock { $0 })
        owner.cancel()
        let outcome = await owner.value
        guard case .superseded = outcome else {
            Issue.record("expected a superseded load, got \(outcome)")
            return
        }
        #expect(workerCancelled.withLock { $0 })
        #expect(log.withLock { $0 } == [.temporaryHomes, .travelDays])
    }
    #endif

    // MARK: - Card copy

    @Test("the card's detail line counts days away and trips, and leaves a zero part out")
    func detailLineParts() {
        #expect(TemporaryHomeCardRow.detailParts(awayDays: 51, tripCount: 3) == ["51 days away from home", "3 trips"])
        #expect(TemporaryHomeCardRow.detailParts(awayDays: 1, tripCount: 1) == ["1 day away from home", "1 trip"])
        #expect(TemporaryHomeCardRow.detailParts(awayDays: 12, tripCount: 0) == ["12 days away from home"])
        #expect(TemporaryHomeCardRow.detailParts(awayDays: 0, tripCount: 0).isEmpty)
    }

    // MARK: - Trip header

    @Test("a trip that left from the temporary home is measured from its city, or from its name when it has no city")
    func departureFromATemporaryHome() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        try context.save()

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == "Brussels")

        base.locality = nil
        try context.save()
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == "Erasmus")
    }

    @Test("a trip that left from the real home during the temporary home keeps reading from home")
    func departureFromTheRealHome() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 27, 8), by: base)
        // A weekend home, and a trip taken from there.
        stay(context, .home, at: athens, from: at(2025, 6, 28, 12), to: at(2025, 6, 30, 12))
        try context.save()

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 30, 15), container: container) == nil)
    }

    @Test("a trip with no home stay before it keeps reading from home")
    func departureWithNoHomeStayBefore() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        // The only home stay starts after the trip does.
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 27, 8), by: base)
        try context.save()

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == nil)
    }

    #if DEBUG
    @Test("with no temporary home the trip header reads the temporary-home rows and nothing else")
    func departureWithNoTemporaryHomeReadsOnce() throws {
        let (container, context) = try store()
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        try context.save()

        let (log, hook) = recordingReads()
        let place = try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
            try TemporaryHomeCards.departurePlaceName(tripStart: at(2025, 6, 4, 9), container: container)
        }
        #expect(place == nil)
        #expect(log.withLock { $0 } == [.temporaryHomes])
    }

    @Test("a failed read behind the trip header throws instead of answering from home",
          arguments: [TemporaryHomeCards.Read.temporaryHomes, .departureStay])
    func departureFailedReadThrows(read failing: TemporaryHomeCards.Read) throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        try context.save()

        let (_, hook) = recordingReads(failing: failing)
        #expect(throws: CocoaError.self) {
            try TemporaryHomeCards.$readFailureForTesting.withValue(hook) {
                try TemporaryHomeCards.departurePlaceName(tripStart: at(2025, 6, 4, 9), container: container)
            }
        }
    }
    #endif

    // MARK: - Prefill from a trip

    private typealias Prefill = TemporaryHomeFormSheet.Prefill

    private func tripStay(
        at place: Place, hours: Double, from start: Date, destination: Bool = true, airport: Bool = false
    ) -> Prefill.TripStay {
        Prefill.TripStay(
            id: UUID(), start: start, end: start.addingTimeInterval(hours * 3_600),
            latitude: place.lat, longitude: place.lon,
            isDestination: destination, isAirport: airport)
    }

    @Test("the prefilled place is the centre of the cluster with the most time, not the longest single stay")
    func prefillPicksTheDominantCluster() throws {
        // Two stays about 350 m apart in Brussels: 18 hours together.
        let flat: Place = (50.8396, 4.3039)
        let dendermonde: Place = (51.0289, 4.1006)
        let prefill = Prefill.forTrip(
            customName: nil, startDate: at(2025, 5, 27), endDate: nil, isComplete: false,
            stays: [
                tripStay(at: dendermonde, hours: 15, from: at(2025, 5, 27)),
                tripStay(at: brussels, hours: 10, from: at(2025, 5, 29)),
                tripStay(at: flat, hours: 8, from: at(2025, 5, 31)),
            ])
        let coordinate = try #require(prefill.coordinate)
        #expect(abs(coordinate.latitude - (brussels.lat + flat.lat) / 2) < 1e-6)
        #expect(abs(coordinate.longitude - (brussels.lon + flat.lon) / 2) < 1e-6)
    }

    @Test("airport stays and stays that are not destinations never set the prefilled place")
    func prefillIgnoresAirportsAndTransit() throws {
        let zaventem: Place = (50.9010, 4.4844)
        let prefill = Prefill.forTrip(
            customName: nil, startDate: at(2025, 5, 27), endDate: nil, isComplete: false,
            stays: [
                tripStay(at: zaventem, hours: 40, from: at(2025, 5, 27), airport: true),
                tripStay(at: ieper, hours: 50, from: at(2025, 5, 29), destination: false),
                tripStay(at: brussels, hours: 5, from: at(2025, 6, 1)),
            ])
        let coordinate = try #require(prefill.coordinate)
        #expect(abs(coordinate.latitude - brussels.lat) < 1e-6)
        #expect(abs(coordinate.longitude - brussels.lon) < 1e-6)

        let none = Prefill.forTrip(
            customName: nil, startDate: at(2025, 5, 27), endDate: nil, isComplete: false,
            stays: [tripStay(at: zaventem, hours: 40, from: at(2025, 5, 27), airport: true)])
        #expect(none.coordinate == nil)
    }

    @Test("a completed trip prefills both dates and its custom name; an open trip leaves the end open")
    func prefillDatesAndName() {
        let completed = Prefill.forTrip(
            customName: "Erasmus", startDate: at(2025, 5, 27), endDate: at(2025, 10, 24),
            isComplete: true, stays: [])
        #expect(completed.name == "Erasmus")
        #expect(completed.since == at(2025, 5, 27))
        #expect(completed.until == at(2025, 10, 24))

        let open = Prefill.forTrip(
            customName: "", startDate: at(2025, 5, 27), endDate: nil, isComplete: false, stays: [])
        #expect(open.name == nil)
        #expect(open.since == at(2025, 5, 27))
        #expect(open.until == nil)
    }

    @Test("a stored trip prefills from its own name, dates and destination stays")
    func prefillFromAStoredTrip() throws {
        let (_, context) = try store()
        let semester = Trip(startDate: at(2025, 5, 27, 10))
        semester.endDate = at(2025, 10, 24, 18)
        semester.isComplete = true
        semester.customName = "Semester"
        context.insert(semester)
        stay(context, .destination, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), trip: semester)
        let zaventem: Place = (50.9010, 4.4844)
        let airport = stay(context, .destination, at: zaventem,
                           from: at(2025, 6, 3, 19), to: at(2025, 6, 14, 8), trip: semester)
        airport.isAirport = true
        stay(context, .transit, at: ieper, from: at(2025, 6, 15, 9), to: at(2025, 7, 24, 17), trip: semester)
        try context.save()

        let prefill = Prefill.forTrip(semester)
        #expect(prefill.name == "Semester")
        // The dates of the stays in the place: the arrival there, and
        // the last stay there for a completed trip, not the trip's own end.
        #expect(prefill.since == at(2025, 5, 27, 10))
        #expect(prefill.until == at(2025, 6, 3, 18))
        let coordinate = try #require(prefill.coordinate)
        #expect(abs(coordinate.latitude - brussels.lat) < 1e-6)
        #expect(abs(coordinate.longitude - brussels.lon) < 1e-6)
    }

    @Test("a journey out through Rome and a holiday at the end are not the semester: the dates are the first and last stays in the place with the most time")
    func prefillDatesAreTheArrivalAndDepartureThere() throws {
        let flat: Place = (50.8396, 4.3039)
        let stays = [
            tripStay(at: rome, hours: 30, from: at(2025, 5, 26, 8)),
            tripStay(at: brussels, hours: 400, from: at(2025, 5, 28, 9)),
            tripStay(at: ieper, hours: 40, from: at(2025, 6, 14, 9)),
            tripStay(at: flat, hours: 600, from: at(2025, 6, 17, 9)),
            tripStay(at: rome, hours: 100, from: at(2025, 7, 14, 9)),
        ]
        let completed = Prefill.forTrip(
            customName: nil, startDate: at(2025, 5, 26, 8), endDate: at(2025, 7, 18, 13),
            isComplete: true, stays: stays)
        #expect(completed.since == at(2025, 5, 28, 9))
        #expect(completed.until == at(2025, 6, 17, 9).addingTimeInterval(600 * 3_600))
        let coordinate = try #require(completed.coordinate)
        #expect(abs(coordinate.latitude - (brussels.lat + flat.lat) / 2) < 1e-6)

        let open = Prefill.forTrip(
            customName: nil, startDate: at(2025, 5, 26, 8), endDate: nil, isComplete: false, stays: stays)
        #expect(open.since == at(2025, 5, 28, 9))
        #expect(open.until == nil)
    }

    @Test("the menu offers a temporary home for an open trip and for one of 14 days or more")
    func setupIsOfferedForLongOrOpenTrips() {
        #expect(Prefill.isOffered(isComplete: false, startDate: at(2025, 5, 27), endDate: nil, timeZone: utc))
        // 27 May to 9 June is 14 days; 27 May to 8 June is 13.
        #expect(Prefill.isOffered(
            isComplete: true, startDate: at(2025, 5, 27, 20), endDate: at(2025, 6, 9, 8), timeZone: utc))
        #expect(!Prefill.isOffered(
            isComplete: true, startDate: at(2025, 5, 27, 8), endDate: at(2025, 6, 8, 20), timeZone: utc))
    }
}

extension TemporaryHomeCardsTests {
    @Test("two temporary homes whose dates overlap: the later one's days at its own place are days at it, not days on trips")
    func overlappingHomesCountTheirOwnStayingDays() throws {
        let (container, context) = try store()
        let first = temporaryHome(context, label: "Brussels", from: at(2025, 5, 26, 0), to: at(2025, 6, 24, 23))
        let second = temporaryHome(
            context, label: "Rome", locality: "Rome", from: at(2025, 6, 9, 0), to: at(2025, 6, 24, 23))
        second.latitude = rome.lat
        second.longitude = rome.lon
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 6, 18), by: first)
        stay(context, .home, at: rome, from: at(2025, 6, 10, 9), to: at(2025, 6, 14, 18), by: second)
        try context.save()

        let card = try #require(try load(container, now: at(2025, 6, 25)).first { $0.id == second.id })
        // 10 to 14 June, with no trip in the store.
        #expect(card.awayDays == 5)
        #expect(card.stayingDays == 5)
    }
}

// MARK: - Recorded ownership, residence barriers, visits home and ended dates

extension TemporaryHomeCardsTests {

    private var vienna: Place { (48.1813, 16.3444) }
    /// A separate Belgian centre outside the Brussels cluster.
    private var dendermonde: Place { (51.0289, 4.1006) }

    private func labels(_ year: Int, _ month: Int, _ range: ClosedRange<Int>) -> Set<Date> {
        Set(range.map {
            TravelDays.labelCalendar.date(from: DateComponents(year: year, month: month, day: $0))!
        })
    }

    @Test("Brussels left open, then Vienna declared with no real-home visit between: Vienna's residence days are not days at Brussels, and the lifetime union is unchanged")
    func secondTemporaryHomeEndsTheFirstOnesResidence() throws {
        let (container, context) = try store()
        let first = temporaryHome(context, label: "Brussels semester", from: at(2025, 5, 26, 0))
        let second = temporaryHome(
            context, label: "Vienna internship", locality: "Vienna", from: at(2025, 7, 25, 0))
        second.latitude = vienna.lat
        second.longitude = vienna.lon
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 24, 20), by: first)
        stay(context, .home, at: brussels, from: at(2025, 6, 25, 8), to: at(2025, 7, 25, 8), by: first)
        stay(context, .home, at: vienna, from: at(2025, 7, 25, 20), to: at(2025, 8, 14, 8), by: second)
        stay(context, .home, at: vienna, from: at(2025, 8, 14, 20), to: at(2025, 9, 3, 8), by: second)
        try context.save()
        let now = at(2025, 9, 3, 18)

        let ledger = try TemporaryHomeLedger.result(
            travelling: [], container: container, now: now, fallbackZone: utc, checkCancellation: {})
        let laterResidence = labels(2025, 7, 26...31).union(labels(2025, 8, 1...24)).union(labels(2025, 8, 25...31).union(labels(2025, 9, 1...3)))
        // The union does not depend on attribution: 27 May to 3 September.
        #expect(ledger.away == labels(2025, 5, 27...31).union(labels(2025, 6, 1...24)).union(labels(2025, 6, 25...30).union(labels(2025, 7, 1...25))).union(laterResidence))
        // Brussels' residence ends at its last stay there, the move to Vienna.
        #expect(ledger.spansByHome[first.id]?.last?.end == at(2025, 7, 25, 8))
        #expect((ledger.stayingByHome[first.id] ?? []).isDisjoint(with: laterResidence))
        #expect((ledger.stayingByHome[second.id] ?? []).isSuperset(of: laterResidence))

        let cards = try load(container, now: now)
        // 27 May to 25 July: 60 dates. 25 July to 3 September: 41.
        #expect(cards.first { $0.id == first.id }?.stayingDays == 60)
        #expect(cards.first { $0.id == second.id }?.stayingDays == 41)
    }

    @Test("Visits Home lists the dates recorded at the real home (28 to 30 June), not the gap from leaving the base to returning (27 June to 1 July)")
    func visitsHomeAreTheRecordedHomeDates() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 27, 8), by: base)
        let athensStay = stay(context, .home, at: athens, from: at(2025, 6, 28, 12), to: at(2025, 6, 30, 12))
        stay(context, .home, at: brussels, from: at(2025, 7, 1, 20), to: at(2025, 7, 14, 8), by: base)
        try context.save()

        let card = try #require(try load(container, now: at(2025, 7, 19)).first)
        let english = Locale(identifier: "en_US")
        let shown = card.visitsHome.map {
            TemporaryHomeDetailView.dateRange($0, timeZoneIdentifier: "UTC", locale: english)
        }
        let recorded = TemporaryHomeDetailView.dateRange(
            DateInterval(start: athensStay.startTime, end: athensStay.endTime),
            timeZoneIdentifier: "UTC", locale: english)
        #expect(shown == [recorded])
    }

    @Test("a Rome trip taken from the real home during a visit home splits the visit in two around it")
    func aTripFromTheRealHomeIsNotPartOfAVisit() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 9, 1, 0))
        stay(context, .home, at: brussels, from: at(2025, 9, 2, 10), to: at(2025, 12, 19, 8), by: base)
        stay(context, .home, at: athens, from: at(2025, 12, 20, 12), to: at(2025, 12, 26, 12))
        trip(context, to: rome, from: at(2025, 12, 27, 9), to: at(2025, 12, 30, 17))
        stay(context, .home, at: athens, from: at(2025, 12, 31, 12), to: at(2026, 1, 5, 12))
        stay(context, .home, at: brussels, from: at(2026, 1, 6, 20), to: at(2026, 1, 20, 8), by: base)
        try context.save()

        let card = try #require(try load(container, now: at(2026, 1, 25)).first)
        #expect(card.visitsHome == [
            DateInterval(start: at(2025, 12, 20, 12), end: at(2025, 12, 26, 12)),
            DateInterval(start: at(2025, 12, 31, 12), end: at(2026, 1, 5, 12)),
        ])
    }

    @Test("Visits Home leave out the time at home before the first stay at the temporary home and stop at its end")
    func visitsHomeStayInsideTheResidence() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0), to: at(2025, 9, 13, 23))
        // Still at home on the first days of the dates: not a visit home.
        stay(context, .home, at: athens, from: at(2025, 5, 26, 10), to: at(2025, 5, 28, 8))
        stay(context, .home, at: brussels, from: at(2025, 5, 29, 10), to: at(2025, 9, 7, 8), by: base)
        // The final return, past the end.
        stay(context, .home, at: athens, from: at(2025, 9, 8, 12), to: at(2025, 9, 24, 12))
        try context.save()

        let card = try #require(try load(container, now: at(2025, 10, 4)).first)
        #expect(card.visitsHome == [DateInterval(start: at(2025, 9, 8, 12), end: at(2025, 9, 13, 23))])
    }

    @Test("a home stay that records no temporary home is the real Home's, even at the temporary home's own centre")
    func unrecordedHomeStayIsTheRealHomes() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        // A home stay the real Home's area claimed, or one the user marked home.
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18))
        let weekend = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        try context.save()

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == nil)
        let card = try #require(try load(container, now: at(2025, 6, 14)).first)
        #expect(card.id == base.id)
        #expect(!card.tripIDs.contains(weekend.id))
        #expect(card.awayDays == 0)
    }

    @Test("of two overlapping temporary homes, a stay counts for the one it records, not the nearer centre")
    func recordedOwnerWinsOverTheNearerCentre() throws {
        let (container, context) = try store()
        let brusselsHome = temporaryHome(context, label: "Brussels", from: at(2025, 5, 26, 0))
        let dendermondeHome = temporaryHome(context, label: "Dendermonde", locality: "Dendermonde", from: at(2025, 5, 26, 0))
        dendermondeHome.latitude = dendermonde.lat
        dendermondeHome.longitude = dendermonde.lon
        // Recorded for Brussels, closer to Dendermonde's centre than to Brussels.
        let nearDendermonde: Place = (51.024, 4.045)
        stay(context, .home, at: nearDendermonde, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: brusselsHome)
        let weekend = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        try context.save()

        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == "Brussels")
        let cards = try load(container, now: at(2025, 6, 14))
        #expect(cards.first { $0.id == brusselsHome.id }?.tripIDs == [weekend.id])
        #expect(cards.first { $0.id == dendermondeHome.id }?.tripIDs == [])
        #expect(cards.first { $0.id == dendermondeHome.id }?.awayDays == 0)
    }

    @Test("a stay that records a temporary home this store does not hold, or a removed one, belongs to no card and reads from home")
    func unsyncedOrRemovedOwnerIsNobodys() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0))
        let removed = temporaryHome(context, label: "Old", from: at(2025, 5, 26, 0))
        removed.removedAt = at(2025, 6, 9)
        let unsynced = stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18))
        unsynced.temporaryHomeID = UUID()
        trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 13, 8), by: removed)
        trip(context, to: rome, from: at(2025, 6, 14, 9), to: at(2025, 6, 16, 17))
        try context.save()

        for tripStart in [at(2025, 6, 4, 9), at(2025, 6, 14, 9)] {
            #expect(try TemporaryHomeCards.departurePlaceName(tripStart: tripStart, container: container) == nil)
        }
        let cards = try load(container, now: at(2025, 6, 19))
        #expect(cards.map(\.id) == [base.id])
        #expect(cards.first?.tripIDs == [])
        #expect(cards.first?.awayDays == 0)
    }

    /// Brussels has a fixed end, saved at its civil day's last second;
    /// a weekend in Ieper leaves from the base; the last night there crosses
    /// its end. The holiday starts after that end and goes on to Rome,
    /// with no real-home stay before it; then the user returns to Athens.
    /// The holiday left
    /// from the base, and the classifier measures it from there too.
    @Test("a trip that leaves the base just after the temporary home ended, with no real-home stay between, still left from it: it is one of its trips and reads from it, like the trip inside its dates")
    func tripJustAfterTheEndStillLeftFromTheBase() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2025, 5, 26, 0), to: at(2025, 6, 24, 23).addingTimeInterval(59 * 60 + 59))
        stay(context, .home, at: athens, from: at(2025, 5, 14, 10), to: at(2025, 5, 25, 20))
        stay(context, .home, at: brussels, from: at(2025, 5, 27, 10), to: at(2025, 6, 3, 18), by: base)
        let fromBase = trip(context, to: ieper, from: at(2025, 6, 4, 9), to: at(2025, 6, 6, 17))
        stay(context, .home, at: brussels, from: at(2025, 6, 6, 21), to: at(2025, 6, 23, 20), by: base)
        stay(context, .home, at: brussels, from: at(2025, 6, 24, 21), to: at(2025, 6, 25, 8), by: base)
        let holiday = Trip(startDate: at(2025, 6, 25, 10))
        holiday.endDate = at(2025, 7, 11, 18)
        holiday.isComplete = true
        context.insert(holiday)
        stay(context, .destination, at: brussels, from: at(2025, 6, 25, 10), to: at(2025, 7, 3, 8), trip: holiday)
        stay(context, .destination, at: rome, from: at(2025, 7, 4, 9), to: at(2025, 7, 11, 18), trip: holiday)
        stay(context, .home, at: athens, from: at(2025, 7, 12, 10), to: at(2025, 7, 19, 10))
        try context.save()

        let card = try #require(try load(container, now: at(2025, 7, 19)).first)
        try #require(card.state == .ended)
        #expect(card.tripIDs == [fromBase.id, holiday.id])
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 25, 10), container: container) == "Brussels")
        #expect(try TemporaryHomeCards.departurePlaceName(
            tripStart: at(2025, 6, 4, 9), container: container) == "Brussels")
    }
}
