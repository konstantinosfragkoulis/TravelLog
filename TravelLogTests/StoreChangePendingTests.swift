//
//  StoreChangePendingTests.swift
//  TravelLogTests
//
//  Pins `StoreChange.pending(in:)`, the set the live ping unit and the
//  foreground fast path publish instead of a static declaration: each dirty
//  model maps to its own bit, a stay with a trip and a deleted stay also
//  report `.trip`, and the set is empty once the context has saved.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("StoreChange derived from a context")
struct StoreChangePendingTests {

    private let base = Date(timeIntervalSince1970: 1_721_168_000)

    private func makeStay() -> Stay {
        Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "pending", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
    }

    @Test("a fresh context reports nothing")
    func emptyContextReportsNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        #expect(StoreChange.pending(in: context).isEmpty)
    }

    @Test("an insert reports exactly its own type")
    func insertMapsEachModelToItsBit() throws {
        let cases: [(make: () -> any PersistentModel, expected: StoreChange)] = [
            ({ LocationPing(
                timestamp: self.base, latitude: 37.9838, longitude: 23.7275,
                horizontalAccuracy: 10, h3IndexRes6: "pending") }, .locationPing),
            ({ HexVisit(
                h3Index: "pending", firstVisited: self.base,
                centerLatitude: 37.9838, centerLongitude: 23.7275) }, .hexVisit),
            ({ Visit(
                arrivalDate: self.base, departureDate: self.base.addingTimeInterval(3600),
                latitude: 37.9838, longitude: 23.7275, horizontalAccuracy: 5,
                receivedAt: self.base.addingTimeInterval(3600)) }, .visit),
            ({ PlannedTrip(
                eventExternalIdentifier: nil, eventLocalIdentifier: "pending",
                title: "Trip", startDate: self.base, endDate: self.base.addingTimeInterval(86400),
                isAllDay: false, locationText: nil) }, .plannedTrip),
            ({ Home(
                label: "Home", latitude: 37.9838, longitude: 23.7275,
                radiusKm: 25, startedAt: self.base) }, .home),
            ({ RoutinePlace(
                label: "Gym", latitude: 37.9838, longitude: 23.7275,
                startedAt: self.base) }, .routinePlace),
            ({ Trip(startDate: self.base) }, .trip),
            ({ self.makeStay() }, .stay),
            ({ TripTitleVariant(
                languageTag: "de", title: "Athen", sourceTitle: "Athens") }, .trip),
            ({ PhotoImportState(originDeviceID: "device-A") }, .photoImportState),
            ({ HiddenPhoto(localIdentifier: "asset-1", tripID: UUID()) }, .hiddenPhoto),
            ({ PinnedPhoto(localIdentifier: "asset-2", tripID: UUID()) }, .pinnedPhoto),
            ({ YearWrapped(year: 2023) }, .yearWrapped),
            ({ HomeAreaOverride(
                kind: .include, centerLatitude: 37.9838, centerLongitude: 23.7275,
                radiusKm: 1, homeID: nil) }, .homeAreaOverride),
            ({ TemporaryHome(
                label: "Erasmus", latitude: 50.8386, longitude: 4.4099,
                startedAt: self.base) }, .temporaryHome),
        ]
        #expect(cases.count == 15)
        for testCase in cases {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            context.insert(testCase.make())
            #expect(StoreChange.pending(in: context) == testCase.expected)
        }
    }

    @Test("title invalidation reports only the trip")
    func variantDeleteMapsToTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        trip.aiGeneratedTitle = "Athens"
        context.insert(trip)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Athen", sourceTitle: "Athens", trip: trip))
        try context.save()

        TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
        #expect(StoreChange.pending(in: context) == .trip)
    }

    @Test("a change to a stay without a trip reports only the stay")
    func triplessStayChangeIsStayOnly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = makeStay()
        context.insert(stay)
        try context.save()

        stay.endTime = base.addingTimeInterval(7200)
        #expect(StoreChange.pending(in: context) == .stay)
    }

    @Test("a change to a stay with a trip also reports the trip")
    func tripStayChangeAlsoReportsTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        let stay = makeStay()
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        try context.save()

        stay.endTime = base.addingTimeInterval(7200)
        let changes = StoreChange.pending(in: context)
        #expect(changes.isSuperset(of: [.stay, .trip]))
    }

    @Test("a deleted stay reports its trip")
    func deletedStayReportsTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        let stay = makeStay()
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        try context.save()

        stay.trip = nil
        context.delete(stay)
        let changes = StoreChange.pending(in: context)
        #expect(changes.isSuperset(of: [.stay, .trip]))
    }

    @Test("a deleted stay whose trip is already nil still reports the trip")
    func deletedTriplessStayReportsTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = makeStay()
        context.insert(stay)
        try context.save()

        context.delete(stay)
        #expect(StoreChange.pending(in: context) == [.stay, .trip])
    }

    @Test("a saved context reports nothing")
    func savedContextReportsNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(makeStay())
        #expect(!StoreChange.pending(in: context).isEmpty)
        try context.save()
        #expect(StoreChange.pending(in: context).isEmpty)
    }
}
