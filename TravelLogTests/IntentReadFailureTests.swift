//
//  IntentReadFailureTests.swift
//  TravelLogTests
//
//  Where Was I and Search Trips: a failed required read, or the in-memory
//  fallback store, must reach Siri as IntentDataError.unavailable, never as
//  "I don't have location data" or "No trips matched". Failures are injected
//  by name through IntentRead's task-local hook, which the detached intent
//  loader re-installs on its worker.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
@MainActor
@Suite("Siri intent read failures")
struct IntentReadFailureTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func failing(_ target: IntentRead) -> @Sendable (IntentRead) throws -> Void {
        { read in
            if read == target { throw CocoaError(.fileReadUnknown) }
        }
    }

    /// One Syros destination stay on 2023-09-30 inside a named trip.
    private func seededContainer() throws -> (container: ModelContainer, tripID: UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2023, 9, 28))
        trip.customName = "Greek Islands"
        trip.isComplete = true
        trip.endDate = date(2023, 10, 3)
        context.insert(trip)
        let stay = Stay(
            startTime: date(2023, 9, 29), endTime: date(2023, 10, 1),
            centroidLatitude: 37.4405, centroidLongitude: 24.8811, h3IndexRes6: "863f75da7ffffff",
            pingCount: 4, distanceFromHomeKm: 500, pingIDs: [])
        context.insert(stay)
        stay.category = .destination
        stay.metroName = "Syros"
        stay.isoCountryCode = "GR"
        stay.trip = trip
        try context.save()
        return (container, trip.id)
    }

    @Test("Where Was I answers with the visit and its parent trip when reads succeed")
    func whereWasIHealthy() async throws {
        let seeded = try seededContainer()
        let loaded = try await WhereWasIFetcher.load(
            on: date(2023, 9, 30), through: nil, container: seeded.container,
            calendar: calendar, isPersistentStore: true)
        #expect(loaded.visits.map(\.place) == ["Syros"])
        #expect(loaded.trips.map(\.id) == [seeded.tripID])
    }

    @Test("a failed stay or trip read in Where Was I is unavailable, not no data",
          arguments: [IntentRead.dayStays, .tripEntities])
    func whereWasIReadFailure(read: IntentRead) async throws {
        let seeded = try seededContainer()
        await #expect(throws: IntentDataError.unavailable) {
            try await IntentRead.$failureForTesting.withValue(failing(read)) {
                try await WhereWasIFetcher.load(
                    on: date(2023, 9, 30), through: nil, container: seeded.container,
                    calendar: calendar, isPersistentStore: true)
            }
        }
    }

    @Test("Where Was I refuses the in-memory fallback store before reading")
    func whereWasIFallbackStore() async throws {
        let seeded = try seededContainer()
        let log = OSAllocatedUnfairLock(initialState: [IntentRead]())
        let recording: @Sendable (IntentRead) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        await IntentRead.$failureForTesting.withValue(recording) {
            await #expect(throws: IntentDataError.unavailable) {
                try await WhereWasIFetcher.load(
                    on: date(2023, 9, 30), through: nil, container: seeded.container,
                    calendar: calendar, isPersistentStore: false)
            }
        }
        #expect(log.withLock { $0 }.isEmpty)
    }

    @Test("a failed trip read in Search Trips throws instead of returning no matches")
    func searchReadFailure() async throws {
        let seeded = try seededContainer()
        let hook = failing(.searchTrips)
        #expect(throws: CocoaError.self) {
            try IntentRead.$failureForTesting.withValue(hook) {
                try TripIntentSearch.localMatches(query: "syros", container: seeded.container)
            }
        }
        await #expect(throws: CocoaError.self) {
            try await IntentRead.$failureForTesting.withValue(hook) {
                try await TripIntentSearch.run(query: "syros", container: seeded.container)
            }
        }
        // The intent maps that storage error to the unavailable answer.
        let mapped = IntentDataError.mapped(CocoaError(.fileReadUnknown), intent: "Search Trips")
        #expect(mapped as? IntentDataError == .unavailable)
        #expect(IntentDataError.mapped(CancellationError(), intent: "Search Trips") is CancellationError)
    }

    @Test("a failed lookup of trip entities throws instead of dropping every trip")
    func entityLookupFailure() throws {
        let seeded = try seededContainer()
        #expect(try TripEntityFetcher.entities(for: [seeded.tripID], container: seeded.container).count == 1)
        #expect(throws: CocoaError.self) {
            try IntentRead.$failureForTesting.withValue(failing(.tripEntities)) {
                try TripEntityFetcher.entities(for: [seeded.tripID], container: seeded.container)
            }
        }
    }

    @Test("every entity query refuses fallback storage before reading", arguments: ["ids", "all", "suggested", "search"])
    func entityQueryFallbackStore(entry: String) async throws {
        let seeded = try seededContainer()
        let query = TripEntityQuery(container: seeded.container, isPersistentStore: false)
        let log = OSAllocatedUnfairLock(initialState: [IntentRead]())
        let recording: @Sendable (IntentRead) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        await IntentRead.$failureForTesting.withValue(recording) {
            await #expect(throws: IntentDataError.unavailable) {
                switch entry {
                case "ids": _ = try await query.entities(for: [seeded.tripID])
                case "all": _ = try await query.allEntities()
                case "suggested": _ = try await query.suggestedEntities()
                default: _ = try await query.entities(matching: "syros")
                }
            }
        }
        #expect(log.withLock { $0 }.isEmpty)
    }

    @Test("every entity query maps read failures to unavailable", arguments: ["ids", "all", "suggested", "search"])
    func entityQueryReadFailure(entry: String) async throws {
        let seeded = try seededContainer()
        let query = TripEntityQuery(container: seeded.container, isPersistentStore: true)
        let read: IntentRead = entry == "search" ? .searchTrips : .tripEntities
        await #expect(throws: IntentDataError.unavailable) {
            try await IntentRead.$failureForTesting.withValue(failing(read)) {
                switch entry {
                case "ids": _ = try await query.entities(for: [seeded.tripID])
                case "all": _ = try await query.allEntities()
                case "suggested": _ = try await query.suggestedEntities()
                default: _ = try await query.entities(matching: "syros")
                }
            }
        }
    }

    @Test("healthy entity queries retain valid entities and legitimate empty results")
    func entityQueryHealthyAndEmpty() async throws {
        let seeded = try seededContainer()
        let query = TripEntityQuery(container: seeded.container, isPersistentStore: true)
        #expect(try await query.entities(for: [seeded.tripID]).map(\.id) == [seeded.tripID])
        #expect(try await query.allEntities().map(\.id) == [seeded.tripID])
        #expect(try await query.suggestedEntities().map(\.id) == [seeded.tripID])
        #expect(try await query.entities(matching: "syros").map(\.id) == [seeded.tripID])
        #expect(try await query.entities(for: [UUID()]).isEmpty)
        #expect(try await query.entities(for: []).isEmpty)
        #expect(try await query.entities(matching: "nonexistent").isEmpty)
        let empty = TripEntityQuery(container: try TestSupport.makeInMemoryContainer(), isPersistentStore: true)
        #expect(try await empty.allEntities().isEmpty)
        #expect(try await empty.suggestedEntities().isEmpty)
    }
}
#endif
