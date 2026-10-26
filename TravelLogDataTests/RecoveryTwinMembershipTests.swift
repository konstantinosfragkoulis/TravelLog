//
//  RecoveryTwinMembershipTests.swift
//  TravelLogTests
//
//  A removed trip whose UUID came back as several populated rows is back
//  only when no recorded stay is still unassigned: how many twins returned
//  says nothing of the membership. Restore, the rescue, the Removed Trips
//  settle and its whole-trip predicate keep the record until it is.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct RecoveryTwinMembershipTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 830_000_000)
    private static let away = (lat: 44.3, lon: 13.4)

    private func at(hours: Double) -> Date {
        Self.base.addingTimeInterval(hours * 3_600)
    }

    private func makeStay(_ ctx: ModelContext, hours: Double, id: UUID? = nil) -> Stay {
        let stay = Stay(
            startTime: at(hours: hours), endTime: at(hours: hours + 2),
            centroidLatitude: Self.away.lat, centroidLongitude: Self.away.lon,
            h3IndexRes6: "A", pingCount: 2, distanceFromHomeKm: 40, pingIDs: [])
        if let id { stay.id = id }
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    private func makeTrip(_ ctx: ModelContext, id: UUID, holding stays: [Stay]) -> Trip {
        let trip = Trip(startDate: stays.map(\.startTime).min() ?? at(hours: 0))
        trip.id = id
        trip.endDate = stays.map(\.endTime).max()
        trip.isComplete = true
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    private func record(_ id: UUID, stays: [Stay]) -> DissolvedTripRecord {
        DissolvedTripRecord(
            id: id, dissolvedAt: at(hours: 30), displayName: "Away",
            startDate: at(hours: 0), endDate: at(hours: 12), isComplete: true,
            destinationSummary: "Away", countryCodes: "", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil, userEdited: false,
            stays: stays.enumerated().map {
                .init(id: $0.element.id, categoryRaw: "destination", orderInTrip: $0.offset)
            })
    }

    /// What C, the third recorded stay, is when two populated twins hold A and B.
    enum ThirdStay: CaseIterable, Sendable {
        /// Unassigned: no twin holds it yet.
        case unassigned
        /// Two physical rows of its id, one unassigned.
        case twinRows
        /// On the second twin: the trip is back whole.
        case onTwin
        /// Gone from the store: taken as deleted, as before.
        case absent
        /// On another trip: claimed, as before.
        case claimed
    }

    @Test("two populated twins of a removed trip settle its record only when no recorded stay is left unassigned",
          arguments: ThirdStay.allCases)
    func populatedTwinsSettleOnMembership(_ third: ThirdStay) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tripID = UUID()
        let a = makeStay(ctx, hours: 0)
        let b = makeStay(ctx, hours: 4)
        let c = makeStay(ctx, hours: 8)
        let parked = record(tripID, stays: [a, b, c])
        let first = makeTrip(ctx, id: tripID, holding: [a])
        let second = makeTrip(ctx, id: tripID, holding: [b])
        switch third {
        case .unassigned, .absent:
            break
        case .twinRows:
            let copy = makeStay(ctx, hours: 8, id: c.id)
            copy.trip = first
            copy.orderInTrip = 1
        case .onTwin:
            c.trip = second
            c.orderInTrip = 1
        case .claimed:
            _ = makeTrip(ctx, id: UUID(), holding: [c])
        }
        if third == .absent { ctx.delete(c) }
        try ctx.save()
        let twinRows = Set([first.persistentModelID, second.persistentModelID])
        let back = third == .onTwin || third == .absent || third == .claimed

        let read = ModelContext(container)
        let rows = try read.fetch(FetchDescriptor<Trip>()).filter { $0.id == tripID }
        let ids = parked.stays.map(\.id)
        let stays = try read.fetch(FetchDescriptor<Stay>(predicate: #Predicate { ids.contains($0.id) }))
        #expect(rows.count == 2)
        #expect(TripClassifier.returnedTripIsWhole(parked, rows: rows, stays: stays) == back)

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.settleReturnedDissolvedTrips([parked]) == (back ? [tripID] : []))
        let rescue = await classifier.rescueDissolvedTrips([parked], pinnedTripIDs: [tripID])
        #expect(rescue.restored.isEmpty)
        #expect(rescue.prunable == (back ? [tripID] : []))
        #expect(rescue.unsettled == Set(back ? [] : [tripID]))
        let expected: TripClassifier.RestoreOutcome = back ? .alreadyExists : .staysAmbiguous
        #expect(await classifier.restoreDissolvedTrip(parked, markStaysSacred: true) == expected)

        // No path chose a twin for the outstanding stay, or minted another row.
        let after = ModelContext(container)
        let trips = try after.fetch(FetchDescriptor<Trip>())
        #expect(Set(trips.filter { $0.id == tripID }.map(\.persistentModelID)) == twinRows)
        if third == .unassigned {
            let outstanding = try #require(try after.fetch(FetchDescriptor<Stay>()).first { $0.id == c.id })
            #expect(outstanding.trip == nil)
            #expect(!outstanding.userOverridden)
        }
        if third == .twinRows {
            #expect(try after.fetch(FetchDescriptor<Stay>()).filter { $0.id == c.id && $0.trip == nil }.count == 1)
        }
    }

    @Test("one populated row with a recorded stay still unassigned is not back whole")
    func singleRowWithOutstandingStayIsNotWhole() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tripID = UUID()
        let a = makeStay(ctx, hours: 0)
        let c = makeStay(ctx, hours: 8)
        let parked = record(tripID, stays: [a, c])
        let row = makeTrip(ctx, id: tripID, holding: [a])
        try ctx.save()
        #expect(!TripClassifier.returnedTripIsWhole(parked, rows: [row], stays: [a, c]))
        c.trip = row
        #expect(TripClassifier.returnedTripIsWhole(parked, rows: [row], stays: [a, c]))
        // A stayless row is never the trip back.
        #expect(!TripClassifier.returnedTripIsWhole(
            parked, rows: [makeTrip(ctx, id: tripID, holding: [])], stays: [a, c]))
    }

    @Test("an unreadable recorded-stay read keeps the record of populated twins and changes nothing")
    func failedStayReadKeepsTwinRecord() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tripID = UUID()
        let a = makeStay(ctx, hours: 0)
        let b = makeStay(ctx, hours: 4)
        let parked = record(tripID, stays: [a, b])
        _ = makeTrip(ctx, id: tripID, holding: [a])
        _ = makeTrip(ctx, id: tripID, holding: [b])
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        // The trip identity read, then the recorded stays.
        await classifier.failDissolvedRestoreFetchCallForTesting(2)
        #expect(await classifier.restoreDissolvedTrip(parked, markStaysSacred: true) == .saveFailed)
        #expect(await classifier.restoreDissolvedTrip(parked, markStaysSacred: true) == .alreadyExists)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).count == 2)
    }
}
