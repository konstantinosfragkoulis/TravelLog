//
//  PlannedJourneyTemporaryHomeTests.swift
//  TravelLogTests
//
//  The Upcoming Trip widget and the Next Trip intent read their home names
//  from `PlannedTripChainer.storeInputs`. A temporary home that has not
//  ended names a return leg like a Home, so the flight back to the base
//  after a weekend away is not a destination. An ended one adds nothing, so
//  a later trip to that city keeps its name.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Planned journeys around a temporary home")
struct PlannedJourneyTemporaryHomeTests {

    private let now = Date(timeIntervalSince1970: 1_824_796_800)

    private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    /// A weekend in Rome and the flight back to Brussels, planned from an
    /// Athens home, with one temporary home in Brussels over the given dates.
    private func store(temporaryHomeFrom start: Double, to end: Double?) throws -> ModelContext {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let home = Home(label: "Home", latitude: 37.98, longitude: 23.73, startedAt: days(-1_000))
        home.locality = "Athens"
        context.insert(home)

        let temporary = TemporaryHome(
            label: "Erasmus", latitude: 50.9187, longitude: 4.3283,
            startedAt: days(start), endedAt: end.map { days($0) })
        temporary.locality = "Brussels"
        temporary.administrativeArea = "Brussels-Capital"
        context.insert(temporary)

        let rome = PlannedTrip(
            eventExternalIdentifier: nil, eventLocalIdentifier: "rome", title: "Trip to Rome",
            startDate: days(5), endDate: days(7), isAllDay: false, locationText: nil)
        rome.confidence = .high
        context.insert(rome)
        let back = PlannedTrip(
            eventExternalIdentifier: nil, eventLocalIdentifier: "back", title: "Flight to Brussels",
            startDate: days(7.1), endDate: days(7.2), isAllDay: false, locationText: nil)
        back.confidence = .high
        context.insert(back)
        try context.save()
        return context
    }

    private func nextJourney(in context: ModelContext) throws -> PlannedJourney {
        let inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        return try #require(PlannedTripChainer.nextJourney(
            from: inputs.legs, homeNames: inputs.homeNames, now: now,
            ongoingTripStartDates: inputs.ongoingTripStartDates))
    }

    @Test("an active temporary home's names end the journey like a Home's",
          arguments: [120.0, nil] as [Double?])
    func activeTemporaryHomeEndsTheJourney(end: Double?) throws {
        let context = try store(temporaryHomeFrom: -30, to: end)
        let inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        #expect(inputs.homeNames.contains("Erasmus"))
        #expect(inputs.homeNames.contains("Brussels"))
        #expect(inputs.homeNames.contains("Brussels-Capital"))
        #expect(inputs.homeNames.contains("Athens"))

        let journey = try nextJourney(in: context)
        #expect(journey.destinations == ["Rome"])
        #expect(journey.legCount == 2)
    }

    @Test("an ended temporary home's names do not, so a trip to that city keeps its name")
    func endedTemporaryHomeNamesNothing() throws {
        let context = try store(temporaryHomeFrom: -200, to: -10)
        let inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        #expect(!inputs.homeNames.contains("Erasmus"))
        #expect(!inputs.homeNames.contains("Brussels"))
        #expect(!inputs.homeNames.contains("Brussels-Capital"))
        #expect(inputs.homeNames.contains("Athens"))

        let journey = try nextJourney(in: context)
        #expect(journey.destinations == ["Rome", "Brussels"])
    }

    @Test("a temporary home that ends exactly now is still read, and one that has not started yet counts for the legs inside its dates")
    func boundaryAndFutureTemporaryHomesCount() throws {
        let endingNow = try store(temporaryHomeFrom: -30, to: 0)
        #expect(try PlannedTripChainer.storeInputs(in: endingNow, now: now).homeNames.contains("Erasmus"))
        // Its dates end before the flight back, so Brussels is a destination then.
        #expect(try nextJourney(in: endingNow).destinations == ["Rome", "Brussels"])
        let endingDuringFlight = try store(temporaryHomeFrom: -30, to: 7.15)
        #expect(try nextJourney(in: endingDuringFlight).destinations == ["Rome"])
        let notStarted = try store(temporaryHomeFrom: 6, to: 120)
        #expect(try nextJourney(in: notStarted).destinations == ["Rome"])
    }

    @Test("two rows with one id name the temporary home once")
    func twinRowsNameTheHomeOnce() throws {
        let context = try store(temporaryHomeFrom: -30, to: 120)
        let original = try #require(try context.fetch(FetchDescriptor<TemporaryHome>()).first)
        let twin = TemporaryHome(
            label: original.label, latitude: original.latitude, longitude: original.longitude,
            startedAt: original.startedAt, endedAt: original.endedAt)
        twin.id = original.id
        twin.locality = original.locality
        twin.administrativeArea = original.administrativeArea
        context.insert(twin)
        try context.save()

        let inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        #expect(inputs.homeNames.temporary.filter { $0.names.contains("Erasmus") }.count == 1)
    }
}
