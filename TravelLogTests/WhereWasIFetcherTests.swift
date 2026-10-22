//
//  WhereWasIFetcherTests.swift
//  TravelLogTests
//
//  Day-overlap fetch + tiering + phrasing behind `WhereWasIIntent`.
//  `WhereWasIFetcher.visits` opens its own ModelContext — seeding
//  contexts save before calling it.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct WhereWasIFetcherTests {

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func makeStay(
        in context: ModelContext,
        start: Date,
        end: Date,
        category: StayCategory,
        locality: String? = nil,
        metroName: String? = nil,
        isoCountryCode: String? = nil,
        country: String? = nil,
        trip: Trip? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: end,
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "861f01867ffffff",
            pingCount: 4,
            distanceFromHomeKm: 500,
            pingIDs: []
        )
        stay.categoryRaw = category.rawValue
        stay.locality = locality
        stay.metroName = metroName
        stay.isoCountryCode = isoCountryCode
        stay.country = country
        stay.trip = trip
        context.insert(stay)
        return stay
    }

    private func makeTrip(in context: ModelContext, start: Date, name: String) -> Trip {
        let trip = Trip(startDate: start)
        trip.customName = name
        trip.isComplete = true
        trip.endDate = start.addingTimeInterval(5 * 86400)
        context.insert(trip)
        return trip
    }

    // MARK: - Overlap semantics

    @Test func exactMidnightEndBelongsToPreviousDayOnly() throws {
        // Half-open day interval: a stay ending exactly at
        // 00:00 was occupied on the previous day only. The pre-fix `>=`
        // predicate made Siri report a place for a day the user never was
        // there.
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let midnight = Calendar.current.startOfDay(for: date(2023, 2, 4))
        makeStay(
            in: context,
            start: date(2023, 2, 3, hour: 18), end: midnight,
            category: .destination, metroName: "Athens", isoCountryCode: "GR"
        )
        try context.save()

        #expect(try WhereWasIFetcher.visits(on: date(2023, 2, 4), container: container).isEmpty)
        #expect(try WhereWasIFetcher.visits(on: date(2023, 2, 3), container: container).count == 1)
    }

    @Test func spanningStayMatchesAndNeighborDaysDoNot() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Stay spans Feb 3 18:00 to Feb 5 10:00; ask about Feb 4.
        makeStay(
            in: context,
            start: date(2023, 2, 3, hour: 18), end: date(2023, 2, 5, hour: 10),
            category: .destination, metroName: "Athens", isoCountryCode: "GR"
        )
        try context.save()

        #expect(try WhereWasIFetcher.visits(on: date(2023, 2, 4), container: container).count == 1)
        #expect(try WhereWasIFetcher.visits(on: date(2023, 2, 6), container: container).isEmpty)
        #expect(try WhereWasIFetcher.visits(on: date(2023, 2, 2), container: container).isEmpty)
    }

    @Test func unclassifiedStaysAreSkippedAndDuplicatePlacesCollapse() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let day = date(2023, 2, 4)
        makeStay(in: context, start: date(2023, 2, 4, hour: 8), end: date(2023, 2, 4, hour: 11),
                 category: .destination, metroName: "Athens", isoCountryCode: "GR")
        makeStay(in: context, start: date(2023, 2, 4, hour: 15), end: date(2023, 2, 4, hour: 20),
                 category: .destination, metroName: "Athens", isoCountryCode: "GR")
        makeStay(in: context, start: date(2023, 2, 4, hour: 12), end: date(2023, 2, 4, hour: 13),
                 category: .unclassified, metroName: "Noise")
        try context.save()

        let visits = try WhereWasIFetcher.visits(on: day, container: container)
        #expect(visits.count == 1)
        #expect(visits.first?.place == "Athens")
        #expect(visits.first?.countryName == "Greece")
        #expect(visits.first?.flag == "🇬🇷")
    }

    @Test func visitCarriesParentTripNameAndID() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: date(2023, 2, 2), name: "Greek Islands")
        makeStay(in: context, start: date(2023, 2, 3), end: date(2023, 2, 5),
                 category: .destination, metroName: "Syros", isoCountryCode: "GR", trip: trip)
        try context.save()

        let visits = try WhereWasIFetcher.visits(on: date(2023, 2, 4), container: container)
        #expect(visits.first?.tripID == trip.id)
        #expect(visits.first?.tripName == "Greek Islands")
    }

    // MARK: - Tiering

    @Test func destinationsBeatHomeBeatTransit() {
        let destination = DayVisit(place: "Paris", countryName: "France", flag: "🇫🇷",
                                   category: .destination, tripID: nil, tripName: nil)
        let home = DayVisit(place: "Gérakas", countryName: "Greece", flag: "🇬🇷",
                            category: .home, tripID: nil, tripName: nil)
        let transit = DayVisit(place: "Frankfurt", countryName: "Germany", flag: "🇩🇪",
                               category: .transit, tripID: nil, tripName: nil)

        #expect(WhereWasIFetcher.answerTier([home, destination, transit]) == [destination])
        #expect(WhereWasIFetcher.answerTier([home, transit]) == [home])
        #expect(WhereWasIFetcher.answerTier([transit]) == [transit])
        #expect(WhereWasIFetcher.answerTier([]).isEmpty)
    }

    // MARK: - Phrasing

    @Test func dialogTextCoversAllTiers() {
        let day = "February 4, 2023"
        let paris = DayVisit(place: "Paris", countryName: "France", flag: "🇫🇷",
                             category: .destination, tripID: UUID(), tripName: "France Getaway")
        let ales = DayVisit(place: "Alès", countryName: "France", flag: "🇫🇷",
                            category: .destination, tripID: paris.tripID, tripName: "France Getaway")
        let home = DayVisit(place: "Gérakas", countryName: "Greece", flag: "🇬🇷",
                            category: .home, tripID: nil, tripName: nil)
        let transit = DayVisit(place: "Frankfurt", countryName: "Germany", flag: "🇩🇪",
                               category: .transit, tripID: nil, tripName: nil)

        #expect(WhereWasIFetcher.dialogText(visits: [], dayText: day)
                == "I don't have location data for February 4, 2023.")
        #expect(WhereWasIFetcher.dialogText(visits: [paris], dayText: day)
                == "On February 4, 2023, you were in Paris (France) during your trip “France Getaway”.")
        #expect(WhereWasIFetcher.dialogText(visits: [paris, ales], dayText: day)
                == "On February 4, 2023, you were in Paris (France) and Alès (France) during your trip “France Getaway”.")
        #expect(WhereWasIFetcher.dialogText(visits: [home], dayText: day)
                == "On February 4, 2023, you were home in Gérakas.")
        #expect(WhereWasIFetcher.dialogText(visits: [transit], dayText: day)
                == "On February 4, 2023, you were in transit through Frankfurt.")
    }


    // MARK: - Inclusive date ranges

    private func rangeCalendar(_ timeZone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func rangeDate(_ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: month == 6 ? -126 : 0,
                      to: calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!)!
    }

    @Test func rangeIncludesEntireEndDateWithStrictMidnightBoundaries() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = rangeDate(6, 10, hour: 0, calendar: calendar)
        let upper = rangeDate(6, 13, hour: 0, calendar: calendar)
        makeStay(in: context, start: start.addingTimeInterval(-3600), end: start,
                 category: .destination, locality: "Before")
        makeStay(in: context, start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(3600),
                 category: .destination, locality: "Spanning")
        makeStay(in: context, start: rangeDate(6, 12, hour: 23, calendar: calendar), end: upper,
                 category: .destination, locality: "Last night")
        makeStay(in: context, start: upper, end: upper.addingTimeInterval(3600),
                 category: .destination, locality: "After")
        try context.save()

        let answer = try WhereWasIFetcher.answer(
            on: rangeDate(6, 10, calendar: calendar), through: rangeDate(6, 12, calendar: calendar),
            container: container, calendar: calendar)
        #expect(answer.compactMap(\.place) == ["Spanning", "Last night"])
    }

    @Test func springAndFallRangesEndAtLocalMidnight() throws {
        let calendar = rangeCalendar("America/New_York")
        for (month, firstDay, lastDay, hours) in [(3, 9, 10, 47), (11, 2, 3, 49)] {
            let start = rangeDate(month, firstDay, calendar: calendar)
            let end = rangeDate(month, lastDay, calendar: calendar)
            let window = try #require(WhereWasIFetcher.dateWindow(from: start, through: end, calendar: calendar))
            #expect(window.duration == Double(hours * 3600))
            #expect(window.end == rangeDate(month, lastDay + 1, hour: 0, calendar: calendar))

            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            makeStay(in: context, start: rangeDate(month, lastDay, hour: 23, calendar: calendar), end: window.end,
                     category: .destination, locality: "Included")
            makeStay(in: context, start: window.end, end: window.end.addingTimeInterval(3600),
                     category: .destination, locality: "Excluded")
            try context.save()
            let visits = try WhereWasIFetcher.answer(on: start, through: end, container: container, calendar: calendar)
            #expect(visits.compactMap(\.place) == ["Included"])
        }
    }

    @Test func sameDayEarlierClockAndOmittedEndKeepExactDayTier() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let morning = rangeDate(6, 10, hour: 8, calendar: calendar)
        let evening = rangeDate(6, 10, hour: 20, calendar: calendar)
        makeStay(in: context, start: morning, end: morning.addingTimeInterval(3600),
                 category: .home, locality: "Home")
        makeStay(in: context, start: evening, end: evening.addingTimeInterval(3600),
                 category: .destination, locality: "Paris", isoCountryCode: "FR")
        try context.save()

        #expect(WhereWasIFetcher.dateWindow(from: evening, through: morning, calendar: calendar)
                == WhereWasIFetcher.dateWindow(from: evening, through: nil, calendar: calendar))
        let exactDay = try WhereWasIFetcher.answer(on: evening, container: container, calendar: calendar)
        let sameDay = try WhereWasIFetcher.answer(on: evening, through: morning, container: container, calendar: calendar)
        #expect(exactDay == sameDay)
        #expect(sameDay.map(\.category) == [.destination])
        #expect(WhereWasIFetcher.dialogText(visits: sameDay, dayText: "February 5, 2024")
                == "On February 5, 2024, you were in Paris (France).")
    }

    @Test func reversedCalendarRangeIsInvalidEvenWithMatchingStays() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = rangeDate(6, 11, hour: 0, calendar: calendar)
        let earlier = rangeDate(6, 10, hour: 23, calendar: calendar)
        makeStay(in: context, start: earlier, end: start.addingTimeInterval(86400),
                 category: .destination, locality: "Paris")
        try context.save()

        #expect(WhereWasIFetcher.dateWindow(from: start, through: earlier, calendar: calendar) == nil)
        #expect(try WhereWasIFetcher.answer(on: start, through: earlier, container: container, calendar: calendar).isEmpty)
    }

    @Test func multiDayAnswerRetainsEveryClassifiedCategoryInVisitOrder() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for (day, category, place) in [
            (10, StayCategory.home, "Athens"), (11, .routine, "Gérakas"),
            (12, .transit, "Frankfurt"), (13, .destination, "Paris"), (14, .unclassified, "Noise")
        ] {
            let start = rangeDate(6, day, calendar: calendar)
            makeStay(in: context, start: start, end: start.addingTimeInterval(3600),
                     category: category, locality: place)
        }
        try context.save()
        let answer = try WhereWasIFetcher.answer(
            on: rangeDate(6, 10, calendar: calendar), through: rangeDate(6, 14, calendar: calendar),
            container: container, calendar: calendar)
        #expect(answer.map(\.category) == [.home, .routine, .transit, .destination])
        #expect(answer.compactMap(\.place) == ["Athens", "Gérakas", "Frankfurt", "Paris"])
    }

    @Test func sameCityNamesInDifferentCountriesRemainDistinct() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for (day, code, country) in [
            (10, "FR", "France"), (11, "US", "United States"), (12, "FR", "France"),
            (13, "", "Canada"), (14, "", "Australia"), (15, "", "Canada")
        ] {
            let start = rangeDate(6, day, calendar: calendar)
            makeStay(in: context, start: start, end: start.addingTimeInterval(3600),
                     category: .destination, locality: "Paris",
                     isoCountryCode: code.isEmpty ? nil : code, country: country)
        }
        try context.save()
        let answer = try WhereWasIFetcher.answer(
            on: rangeDate(6, 10, calendar: calendar), through: rangeDate(6, 15, calendar: calendar),
            container: container, calendar: calendar)
        #expect(answer.count == 4)
        #expect(answer.compactMap(\.countryName) == ["France", "United States", "Canada", "Australia"])
    }

    @Test func rangeTripIDsDeduplicateInFirstVisitOrder() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Creation order differs from visit order.
        let second = makeTrip(in: context, start: rangeDate(6, 11, calendar: calendar), name: "Second")
        let first = makeTrip(in: context, start: rangeDate(6, 10, calendar: calendar), name: "First")
        for (day, place, trip) in [(10, "Paris", first), (11, "Paris", second), (12, "Alès", first)] {
            let start = rangeDate(6, day, calendar: calendar)
            makeStay(in: context, start: start, end: start.addingTimeInterval(3600),
                     category: .destination, locality: place, isoCountryCode: "FR", trip: trip)
        }
        try context.save()
        let answer = try WhereWasIFetcher.answer(
            on: rangeDate(6, 10, calendar: calendar), through: rangeDate(6, 12, calendar: calendar),
            container: container, calendar: calendar)
        #expect(answer.count == 3)
        #expect(WhereWasIFetcher.tripIDs(in: answer) == [first.id, second.id])
    }

    @Test func rangeDialogIsNeutralAndUsesLocalizedListFormatting() {
        let visits = [
            DayVisit(place: "Gérakas", countryName: "Greece", flag: nil, category: .home, tripID: nil, tripName: nil),
            DayVisit(place: "Paris", countryName: "France", flag: nil, category: .destination, tripID: nil, tripName: "Holiday"),
            DayVisit(place: "Frankfurt", countryName: "Germany", flag: nil, category: .transit, tripID: nil, tripName: nil)
        ]
        let text = WhereWasIFetcher.rangeDialogText(visits: visits, rangeText: "February 4 to February 6", locale: Locale(identifier: "en_US"))
        #expect(text == "Your recorded places for February 4 to February 6 were Gérakas (Greece), Paris (France), and Frankfurt (Germany).")
    }

    @Test func emptyRangeReusesNoDataResponse() throws {
        let calendar = rangeCalendar()
        let container = try TestSupport.makeInMemoryContainer()
        let answer = try WhereWasIFetcher.answer(
            on: rangeDate(6, 10, calendar: calendar), through: rangeDate(6, 12, calendar: calendar),
            container: container, calendar: calendar)
        #expect(answer.isEmpty)
        #expect(WhereWasIFetcher.rangeDialogText(visits: answer, rangeText: "February 5 to February 7", locale: Locale(identifier: "en"))
                == "I don't have location data for February 5 to February 7.")
    }
}
