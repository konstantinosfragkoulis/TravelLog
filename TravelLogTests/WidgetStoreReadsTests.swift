//
//  WidgetStoreReadsTests.swift
//  TravelLogTests
//
//  The widget providers' required reads live in widget-shared files
//  (Stay.swift, Trip.swift, PlannedTripChainer.swift) so they can be pinned
//  here. A failed read, including one after an earlier page or count already
//  succeeded, must throw rather than return a partial or empty value; the
//  providers turn that throw into the redacted placeholder on the short
//  retry cadence. The Next Trip intent shares the planned-trip read.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
@MainActor
@Suite("Widget store reads")
struct WidgetStoreReadsTests {

    private let base = Date(timeIntervalSince1970: 1_763_910_400)

    /// Fails the `occurrence`-th check of `target` (1-based), passing all
    /// earlier ones and every other read.
    private func failing(
        _ target: WidgetStoreRead, onOccurrence occurrence: Int = 1
    ) -> (hook: @Sendable (WidgetStoreRead) throws -> Void, log: OSAllocatedUnfairLock<[WidgetStoreRead]>) {
        let log = OSAllocatedUnfairLock(initialState: [WidgetStoreRead]())
        let hook: @Sendable (WidgetStoreRead) throws -> Void = { read in
            let seen = log.withLock { reads -> Int in
                reads.append(read)
                return reads.filter { $0 == target }.count
            }
            if read == target, seen == occurrence { throw CocoaError(.fileReadUnknown) }
        }
        return (hook, log)
    }

    @discardableResult
    private func stay(
        _ context: ModelContext, _ category: StayCategory, hex: String, iso: String?,
        offsetHours: Double, flight: Bool = false, trip: Trip? = nil
    ) -> Stay {
        let start = base.addingTimeInterval(offsetHours * 3_600)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(1_800),
            centroidLatitude: 10 + offsetHours, centroidLongitude: 20 + offsetHours,
            h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.isoCountryCode = iso
        if flight { stay.transitMode = .flight }
        stay.trip = trip
        return stay
    }

    // MARK: - Travel Stats / Travel Counter

    /// Three visited stays in three countries, one surface and one flight-only
    /// transit hex, HexVisit rows for every hex, and one completed trip.
    private func statsStore() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        trip.isComplete = true
        trip.endDate = base.addingTimeInterval(86_400)
        context.insert(trip)
        stay(context, .destination, hex: "86a", iso: "FR", offsetHours: 0, trip: trip)
        stay(context, .home, hex: "86b", iso: "GR", offsetHours: 1)
        stay(context, .routine, hex: "86c", iso: "IT", offsetHours: 2)
        stay(context, .transit, hex: "86road", iso: nil, offsetHours: 3)
        stay(context, .transit, hex: "86sky", iso: nil, offsetHours: 4, flight: true)
        for hex in ["86a", "86b", "86c", "86road", "86sky"] {
            context.insert(HexVisit(h3Index: hex, firstVisited: base, centerLatitude: 0, centerLongitude: 0))
        }
        try context.save()
        return container
    }

    @Test("healthy travel stats match the widget arithmetic, with the flyover hex hidden")
    func healthyTravelStats() throws {
        let container = try statsStore()
        let stats = try Stay.widgetTravelStats(in: container, pageSize: 1)
        #expect(stats.countryCodes == ["FR", "GR", "IT"])
        #expect(stats.tripCount == 1)
        #expect(stats.hexCount == 4)
        #expect(stats.cityCount >= 1)
        let hidden = HexVisibility.hiddenHexes(
            transit: [
                .init(h3Index: "86road", isFlight: false, isAirport: false),
                .init(h3Index: "86sky", isFlight: true, isAirport: false),
            ],
            realHexes: ["86a", "86b", "86c"])
        #expect(try HexVisibility.visibleHexVisitCount(hidden: hidden, in: ModelContext(container))
            == stats.hexCount)
        #expect(try Stay.widgetVisitedCountryCodes(in: container, pageSize: 1) == ["FR", "GR", "IT"])
    }

    @Test("a failed visited page after a successful one throws instead of a partial set")
    func laterVisitedPageFailureThrows() throws {
        let container = try statsStore()
        let stats = failing(.visitedPage, onOccurrence: 2)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(stats.hook) {
                try Stay.widgetTravelStats(in: container, pageSize: 1)
            }
        }
        #expect(stats.log.withLock { $0 }.filter { $0 == .visitedPage }.count == 2)

        let counter = failing(.visitedPage, onOccurrence: 2)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(counter.hook) {
                try Stay.widgetVisitedCountryCodes(in: container, pageSize: 1)
            }
        }
    }

    @Test("a failed trip count, transit page or hidden-hex chunk count throws",
          arguments: [
            (WidgetStoreRead.completedTripCount, 1),
            (WidgetStoreRead.transitPage, 2),
            // The first count is the table total; the second is a hidden chunk.
            (WidgetStoreRead.hexVisitCount, 2),
          ])
    func laterStatsReadFailureThrows(read: WidgetStoreRead, occurrence: Int) throws {
        let container = try statsStore()
        let injected = failing(read, onOccurrence: occurrence)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(injected.hook) {
                try Stay.widgetTravelStats(in: container, pageSize: 1)
            }
        }
        #expect(injected.log.withLock { $0 }.filter { $0 == read }.count == occurrence)
    }

    // MARK: - Current Trip

    private func currentTripStore(ongoing: Bool) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let finished = Trip(startDate: base)
        finished.isComplete = true
        finished.endDate = base.addingTimeInterval(3 * 86_400)
        finished.customName = "Finished"
        finished.countryCodes = "FR"
        context.insert(finished)
        stay(context, .destination, hex: "86a", iso: "FR", offsetHours: 1, trip: finished)
        if ongoing {
            let current = Trip(startDate: base.addingTimeInterval(10 * 86_400))
            current.customName = "Current"
            current.countryCodes = "IT"
            context.insert(current)
            stay(context, .destination, hex: "86b", iso: "IT", offsetHours: 241, trip: current)
        }
        try context.save()
        return container
    }

    @Test("a failed ongoing-trip read never falls through to the finished trip")
    func ongoingFailureDoesNotShowFinishedTrip() throws {
        let container = try currentTripStore(ongoing: true)
        let now = base.addingTimeInterval(12 * 86_400)
        let healthy = try Trip.widgetSnapshot(in: ModelContext(container), now: now, languageTag: "en")
        #expect(healthy?.title == "Current")
        #expect(healthy?.isOngoing == true)
        #expect(healthy?.dayCount == 3)

        let injected = failing(.ongoingTrip)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(injected.hook) {
                try Trip.widgetSnapshot(in: ModelContext(container), now: now, languageTag: "en")
            }
        }
        #expect(!injected.log.withLock { $0 }.contains(.completedTrip))
    }

    @Test("with no ongoing trip, the finished trip shows, and a failed read of it throws")
    func completedReadFailureThrows() throws {
        let container = try currentTripStore(ongoing: false)
        let now = base.addingTimeInterval(12 * 86_400)
        let healthy = try #require(
            try Trip.widgetSnapshot(in: ModelContext(container), now: now, languageTag: "en"))
        #expect(healthy.title == "Finished")
        #expect(healthy.isOngoing == false)
        #expect(healthy.endDate == base.addingTimeInterval(3 * 86_400))

        let injected = failing(.completedTrip)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(injected.hook) {
                try Trip.widgetSnapshot(in: ModelContext(container), now: now, languageTag: "en")
            }
        }
        #expect(try Trip.widgetSnapshot(
            in: ModelContext(TestSupport.makeInMemoryContainer()), now: now, languageTag: "en") == nil)
    }

    // MARK: - Upcoming Trip / Next Trip intent

    private func plannedStore() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let planned = PlannedTrip(
            eventExternalIdentifier: nil, eventLocalIdentifier: "event-1", title: "Trip to Lisbon",
            startDate: base.addingTimeInterval(5 * 86_400), endDate: base.addingTimeInterval(8 * 86_400),
            isAllDay: false, locationText: nil)
        planned.confidence = .high
        context.insert(planned)
        let home = Home(label: "Athens", latitude: 37.98, longitude: 23.73)
        home.locality = "Athens"
        context.insert(home)
        let ongoing = Trip(startDate: base.addingTimeInterval(-86_400))
        context.insert(ongoing)
        try context.save()
        return container
    }

    @Test("healthy planned-trip inputs carry legs, Home names and ongoing starts")
    func healthyPlannedInputs() throws {
        let container = try plannedStore()
        let inputs = try PlannedTripChainer.storeInputs(in: ModelContext(container), now: base)
        #expect(inputs.legs.map(\.title) == ["Trip to Lisbon"])
        #expect(inputs.homeNames.contains("Athens"))
        #expect(inputs.ongoingTripStartDates == [base.addingTimeInterval(-86_400)])
        let journey = PlannedTripChainer.nextJourney(
            from: inputs.legs, homeNames: inputs.homeNames, now: base,
            ongoingTripStartDates: inputs.ongoingTripStartDates)
        #expect(journey?.startDate == base.addingTimeInterval(5 * 86_400))
    }

    @Test("a failed planned-trip, Home or ongoing-trip read is unavailable, not no journey",
          arguments: [WidgetStoreRead.plannedTrips, .homes, .ongoingTrips])
    func plannedInputFailureThrows(read: WidgetStoreRead) throws {
        let container = try plannedStore()
        let injected = failing(read)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(injected.hook) {
                try PlannedTripChainer.storeInputs(in: ModelContext(container), now: base)
            }
        }
    }
}
#endif
