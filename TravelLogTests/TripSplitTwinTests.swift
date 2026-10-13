//
//  TripSplitTwinTests.swift
//  TravelLogTests
//
//  "Split Trip Here" acts on the tapped physical Trip row and the tapped
//  physical Stay row, driven through the same static worker the gated
//  TripDetailView path calls. A UUID twin (another physical row sharing the
//  trip's or the stay's UUID) can hold a different tail, so it never stands in.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Trip split on UUID twins", .serialized)
struct TripSplitTwinTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 1_077 * 86_400)
    private func d(_ days: Double) -> Date { Self.base.addingTimeInterval(days * 86_400) }

    private func stay(_ ctx: ModelContext, trip: Trip, day: Double, order: Int, id: UUID? = nil) -> Stay {
        let stay = Stay(
            startTime: d(day), endTime: d(day + 1),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "861eda747ffffff", pingCount: 4,
            distanceFromHomeKm: 250, pingIDs: [])
        if let id { stay.id = id }
        stay.category = .destination
        stay.orderInTrip = order
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }

    private func completeTrip(_ day: Double, _ endDay: Double) -> Trip {
        let trip = Trip(startDate: d(day))
        trip.endDate = d(endDay)
        trip.isComplete = true
        return trip
    }

    /// Tapped trip [A, B, C] and an untapped twin [A', B', D'] where A'/B'
    /// share A/B's UUIDs. Either row may be the one a UUID fetch meets first.
    @Test("splitting the tapped trip moves exactly its own tail and leaves the UUID twin untouched",
          arguments: [false, true])
    func splitActsOnTappedRows(tappedFirst: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tapped = completeTrip(0, 6)
        let twin = completeTrip(0, 8)
        twin.id = tapped.id
        for row in tappedFirst ? [tapped, twin] : [twin, tapped] { ctx.insert(row) }
        let a = stay(ctx, trip: tapped, day: 0, order: 0)
        let b = stay(ctx, trip: tapped, day: 2, order: 1)
        let c = stay(ctx, trip: tapped, day: 4, order: 2)
        let aTwin = stay(ctx, trip: twin, day: 0, order: 0, id: a.id)
        let bTwin = stay(ctx, trip: twin, day: 2, order: 1, id: b.id)
        let dTwin = stay(ctx, trip: twin, day: 6, order: 2)
        try ctx.save()
        let twinRow = twin.persistentModelID
        let tappedRow = tapped.persistentModelID
        let twinStayRows = [aTwin, bTwin, dTwin].map(\.persistentModelID)

        #expect(TripDetailView.applySplit(
            tripID: tapped.id, tripIdentifier: tappedRow,
            splitStayID: b.id, splitStayIdentifier: b.persistentModelID, in: ctx))

        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 3)
        let freshTapped = try #require(trips.first { $0.persistentModelID == tappedRow })
        let freshTwin = try #require(trips.first { $0.persistentModelID == twinRow })
        let newTrip = try #require(trips.first { $0.persistentModelID != tappedRow && $0.persistentModelID != twinRow })
        #expect(freshTapped.orderedStays.map(\.persistentModelID) == [a.persistentModelID])
        #expect(freshTapped.endDate == d(1))
        #expect(freshTapped.userEdited)
        #expect(newTrip.orderedStays.map(\.persistentModelID) == [b.persistentModelID, c.persistentModelID])
        #expect(newTrip.startDate == d(2))
        #expect(freshTwin.orderedStays.map(\.persistentModelID) == twinStayRows,
                "the untapped twin keeps its whole timeline")
        #expect(freshTwin.orderedStays.map(\.orderInTrip) == [0, 1, 2])
        #expect(freshTwin.endDate == d(8))
        #expect(!freshTwin.userEdited)
    }

    @Test("a split whose tapped trip row is gone reports failure and never splits the UUID twin")
    func goneTappedRowIsNotReplacedByTwin() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tapped = completeTrip(0, 4)
        let twin = completeTrip(0, 4)
        twin.id = tapped.id
        ctx.insert(twin)
        ctx.insert(tapped)
        _ = stay(ctx, trip: tapped, day: 0, order: 0)
        let b = stay(ctx, trip: tapped, day: 2, order: 1)
        let aTwin = stay(ctx, trip: twin, day: 0, order: 0)
        let bTwin = stay(ctx, trip: twin, day: 2, order: 1, id: b.id)
        try ctx.save()
        let tripID = tapped.id
        let tappedRow = tapped.persistentModelID
        let splitStayID = b.id
        let splitStayRow = b.persistentModelID
        let twinStayRows = [aTwin, bTwin].map(\.persistentModelID)
        // A unit ahead of the split in the gate removed the tapped row.
        ctx.delete(tapped)
        try ctx.save()

        #expect(!TripDetailView.applySplit(
            tripID: tripID, tripIdentifier: tappedRow,
            splitStayID: splitStayID, splitStayIdentifier: splitStayRow, in: ctx))

        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.persistentModelID) == [twin.persistentModelID])
        #expect(trips.first?.orderedStays.map(\.persistentModelID) == twinStayRows)
        #expect(trips.first?.userEdited == false)
    }

    @Test("a split whose tapped stay left the trip reports failure even when a same-UUID stay is still there")
    func movedTappedStayIsNotReplacedByStayTwin() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = completeTrip(0, 6)
        let elsewhere = completeTrip(10, 12)
        ctx.insert(trip)
        ctx.insert(elsewhere)
        let a = stay(ctx, trip: trip, day: 0, order: 0)
        let tappedStay = stay(ctx, trip: trip, day: 2, order: 1)
        let stayTwin = stay(ctx, trip: trip, day: 2, order: 2, id: tappedStay.id)
        let c = stay(ctx, trip: trip, day: 4, order: 3)
        try ctx.save()
        // Before the unit ran, the tapped stay row was moved to another trip.
        tappedStay.trip = elsewhere
        tappedStay.orderInTrip = 0
        try ctx.save()
        let tripRow = trip.persistentModelID
        let remaining = [a, stayTwin, c].map(\.persistentModelID)

        #expect(!TripDetailView.applySplit(
            tripID: trip.id, tripIdentifier: tripRow,
            splitStayID: tappedStay.id, splitStayIdentifier: tappedStay.persistentModelID, in: ctx))

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Trip>()).count == 2)
        let freshTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first { $0.persistentModelID == tripRow })
        #expect(freshTrip.orderedStays.map(\.persistentModelID) == remaining)
        #expect(!freshTrip.userEdited)
    }

    @Test("a split is the user's own edit: both halves are edited and neither carries a temporary home's mark")
    func splitClearsATemporaryHomesMark() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = completeTrip(0, 6)
        trip.userEdited = true
        trip.keptByTemporaryHome = true
        ctx.insert(trip)
        _ = stay(ctx, trip: trip, day: 0, order: 0)
        let b = stay(ctx, trip: trip, day: 2, order: 1)
        _ = stay(ctx, trip: trip, day: 4, order: 2)
        try ctx.save()

        #expect(TripDetailView.applySplit(
            tripID: trip.id, tripIdentifier: trip.persistentModelID,
            splitStayID: b.id, splitStayIdentifier: b.persistentModelID, in: ctx))

        let halves = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(halves.count == 2)
        for half in halves {
            #expect(half.userEdited)
            #expect(!half.keptByTemporaryHome)
        }
    }
    @Test("a manual split copies all hidden choices with fresh identities and keeps the originals")
    func splitPreservesHiddenChoices() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = completeTrip(0, 6)
        ctx.insert(trip)
        _ = stay(ctx, trip: trip, day: 0, order: 0)
        let tail = stay(ctx, trip: trip, day: 2, order: 1)
        let hidden = HiddenPhoto(localIdentifier: "hidden-local", tripID: trip.id)
        hidden.cloudIdentifier = "hidden-cloud"
        hidden.hiddenAt = d(-2)
        let localOnly = HiddenPhoto(localIdentifier: "local-only", tripID: trip.id)
        localOnly.hiddenAt = d(-1)
        ctx.insert(hidden)
        ctx.insert(localOnly)
        ctx.insert(PinnedPhoto(localIdentifier: "pin", tripID: trip.id))
        try ctx.save()
        let originalID = trip.id
        let originalRowIDs = Set([hidden.id, localOnly.id])

        #expect(TripDetailView.applySplit(
            tripID: originalID, tripIdentifier: trip.persistentModelID,
            splitStayID: tail.id, splitStayIdentifier: tail.persistentModelID, in: ctx))
        let fresh = ModelContext(container)
        let newTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first { $0.id != originalID })
        let rows = try fresh.fetch(FetchDescriptor<HiddenPhoto>())
        let originals = rows.filter { $0.tripID == originalID }
        let copies = rows.filter { $0.tripID == newTrip.id }
        #expect(Set(originals.map(\.id)) == originalRowIDs)
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).isDisjoint(with: originalRowIDs))
        #expect(copies.first { $0.localIdentifier == "hidden-local" }?.cloudIdentifier == "hidden-cloud")
        #expect(copies.first { $0.localIdentifier == "hidden-local" }?.hiddenAt == d(-2))
        #expect(copies.first { $0.localIdentifier == "local-only" }?.cloudIdentifier == nil)
        #expect(copies.first { $0.localIdentifier == "local-only" }?.hiddenAt == d(-1))
        #expect(try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID) == [originalID])
    }

    #if DEBUG
    @Test("a failed split annotation read or save leaves stays and hidden choices in place",
          arguments: [TripDetailView.EditFault.splitHiddenRead, .splitSave])
    func splitHiddenFailureIsAtomic(fault: TripDetailView.EditFault) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = completeTrip(0, 6)
        let unrelated = completeTrip(10, 12)
        ctx.insert(trip)
        ctx.insert(unrelated)
        let first = stay(ctx, trip: trip, day: 0, order: 0)
        let tail = stay(ctx, trip: trip, day: 2, order: 1)
        let hidden = HiddenPhoto(localIdentifier: "hidden", tripID: trip.id)
        ctx.insert(hidden)
        try ctx.save()
        let originalID = trip.id
        let hiddenID = hidden.id
        let unrelatedID = unrelated.id
        unrelated.customName = "Earlier edit"

        TripDetailView.$editFaultForTesting.withValue(fault) {
            #expect(!TripDetailView.applySplit(
                tripID: originalID, tripIdentifier: trip.persistentModelID,
                splitStayID: tail.id, splitStayIdentifier: tail.persistentModelID, in: ctx))
        }
        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 2)
        let original = try #require(trips.first { $0.id == originalID })
        #expect(original.orderedStays.map(\.id) == [first.id, tail.id])
        #expect(original.endDate == d(6))
        #expect(!original.userEdited)
        #expect(trips.first { $0.id == unrelatedID }?.customName == "Earlier edit")
        #expect(try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.id) == [hiddenID])
        #expect(!ctx.hasChanges)
    }
    #endif

}
