//
//  TripDataExportTwinTests.swift
//  TravelLogTests
//
//  Physical Trip UUID twins (two devices regrouping one journey before sync
//  settled) leave the export as one entry, because restore keeps the first
//  entry for a Trip UUID: an empty twin never hides a populated one, and
//  populated twins merge their stays. Title prose survives only from a twin
//  holding every stay; a union no twin holds is numbered in time order and
//  names its destinations from its stays against the Homes.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("TripDataExporter UUID twins")
struct TripDataExportTwinTests {

    private static let start = Date(timeIntervalSince1970: 1_685_484_800)
    private static let hour: TimeInterval = 3_600

    @discardableResult
    private func insertTrip(
        id: UUID, startHour: Double, endHour: Double, in context: ModelContext
    ) -> Trip {
        let trip = Trip(startDate: Self.start.addingTimeInterval(startHour * Self.hour), source: .liveSLC)
        trip.id = id
        trip.endDate = Self.start.addingTimeInterval(endHour * Self.hour)
        trip.isComplete = true
        context.insert(trip)
        return trip
    }

    @discardableResult
    private func insertStay(
        id: UUID = UUID(), hour: Double, trip: Trip, order: Int, in context: ModelContext
    ) throws -> Stay {
        let stayStart = Self.start.addingTimeInterval(hour * Self.hour)
        let stay = Stay(
            startTime: stayStart, endTime: stayStart.addingTimeInterval(2 * Self.hour),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: try #require(H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275)),
            pingCount: 0, distanceFromHomeKm: 100, pingIDs: [], source: .liveSLC)
        stay.id = id
        stay.category = .destination
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = order
        return stay
    }

    nonisolated enum TwinShape: CaseIterable, Sendable {
        /// A named, edited empty twin sorts first; the populated twin holds every stay.
        case emptyFirst
        /// Each twin holds a different pair of stays, numbered 0 and 1 by each.
        case disjoint
    }

    @Test("an export of Trip UUID twins restores every stay onto one coherent trip with its name",
          arguments: TwinShape.allCases)
    func twinsRoundTripAsOneTrip(shape: TwinShape) async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        let tripID = UUID()
        let unrelated = insertTrip(id: UUID(), startHour: -200, endHour: -190, in: context)
        let unrelatedStay = try insertStay(hour: -199, trip: unrelated, order: 0, in: context)
        let expectedOrder: [UUID]
        switch shape {
        case .emptyFirst:
            // The later start date sorts the empty twin first in the export.
            let empty = insertTrip(id: tripID, startHour: 1, endHour: 10, in: context)
            empty.customName = "Island hopping"
            empty.userEdited = true
            let populated = insertTrip(id: tripID, startHour: 0, endHour: 10, in: context)
            let first = try insertStay(hour: 0, trip: populated, order: 0, in: context)
            let second = try insertStay(hour: 6, trip: populated, order: 1, in: context)
            expectedOrder = [first.id, second.id]
        case .disjoint:
            // Kept as they are, the numbers would restore the stops as 0, 6, 2, 8,
            // and one twin's summary would describe the whole trip.
            let later = insertTrip(id: tripID, startHour: 6, endHour: 10, in: context)
            later.destinationSummary = "Other Town"
            later.countryCodes = "FR"
            let laterStays = [
                try insertStay(hour: 6, trip: later, order: 0, in: context),
                try insertStay(hour: 8, trip: later, order: 1, in: context),
            ]
            let earlier = insertTrip(id: tripID, startHour: 0, endHour: 4, in: context)
            earlier.customName = "Island hopping"
            earlier.userEdited = true
            earlier.destinationSummary = "Fictional Town"
            earlier.countryCodes = "IT"
            let earlierStays = [
                try insertStay(hour: 0, trip: earlier, order: 0, in: context),
                try insertStay(hour: 2, trip: earlier, order: 1, in: context),
            ]
            for stay in earlierStays {
                stay.locality = "Fictional Town"
                stay.isoCountryCode = "IT"
            }
            for stay in laterStays {
                stay.locality = "Other Town"
                stay.isoCountryCode = "FR"
            }
            expectedOrder = (earlierStays + laterStays).map(\.id)
        }
        try context.save()

        let snapshots = try await ExportSnapshotter(modelContainer: source).snapshotTrips()
        #expect(snapshots.map(\.id) == [tripID, unrelated.id])
        let entry = try #require(snapshots.first)
        #expect(entry.stays.map(\.id) == expectedOrder)
        #expect(entry.stays.map(\.orderInTrip) == Array(0..<expectedOrder.count).map { Optional($0) })
        if shape == .disjoint {
            // Derived from the union against the Homes, as recomputeSummary would.
            #expect(entry.destinationSummary == "Fictional Town, Other Town")
            #expect(entry.countryCodes == "IT,FR")
            #expect(entry.sourceRaw == DataSource.liveSLC.rawValue)
        }
        let data = try await ExportSnapshotter(modelContainer: source).exportData()
        let payload = try TripDataImporter.parse(data)

        let restored = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: restored).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 2)
        #expect(outcome.insertedStays == expectedOrder.count + 1)

        let fresh = ModelContext(restored)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 2)
        let trip = try #require(trips.first { $0.id == tripID })
        #expect(trip.orderedStays.map(\.id) == expectedOrder)
        #expect(trip.customName == "Island hopping")
        #expect(trip.userEdited)
        #expect(trip.startDate == Self.start)
        #expect(trip.endDate == Self.start.addingTimeInterval(10 * Self.hour))
        if shape == .disjoint {
            #expect(trip.orderedStays.map(\.orderInTrip) == [0, 1, 2, 3])
            #expect(Set(Trip.summaryComponents(trip.destinationSummary))
                == ["Fictional Town", "Other Town"])
            #expect(trip.countryCodes == "IT,FR")
        }
        let other = try #require(trips.first { $0.id == unrelated.id })
        #expect((other.stays ?? []).map(\.id) == [unrelatedStay.id])
    }

    @Test("merged twins keep title prose only from a twin holding every stay")
    func mergedTitlesNeedTheWholeMembership() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let s1 = UUID(), s2 = UUID(), s3 = UUID()

        // Whole: twin A holds both stays, B a subset; A's stays and title stand.
        let wholeID = UUID()
        let wholeA = insertTrip(id: wholeID, startHour: 0, endHour: 10, in: context)
        wholeA.aiGeneratedTitle = "Athens Weekend"
        try insertStay(id: s1, hour: 0, trip: wholeA, order: 0, in: context)
        try insertStay(id: s2, hour: 6, trip: wholeA, order: 1, in: context)
        let wholeB = insertTrip(id: wholeID, startHour: 6, endHour: 10, in: context)
        wholeB.customName = "With friends"
        try insertStay(id: s2, hour: 6, trip: wholeB, order: 0, in: context)

        // Overlap: neither twin holds the union, so no prose survives.
        let overlapID = UUID()
        let overlapA = insertTrip(id: overlapID, startHour: 20, endHour: 28, in: context)
        overlapA.aiGeneratedTitle = "Athens Again"
        overlapA.aiGeneratedSummary = "Two days in Athens."
        try insertStay(id: s3, hour: 20, trip: overlapA, order: 0, in: context)
        let s4 = try insertStay(hour: 26, trip: overlapA, order: 1, in: context)
        let overlapB = insertTrip(id: overlapID, startHour: 26, endHour: 34, in: context)
        try insertStay(id: s4.id, hour: 26, trip: overlapB, order: 0, in: context)
        let s5 = try insertStay(hour: 32, trip: overlapB, order: 1, in: context)
        try context.save()

        let snapshots = try TripDataExporter.makeSnapshots(
            from: [wholeB, overlapB, wholeA, overlapA])
        #expect(snapshots.map(\.id) == [wholeID, overlapID])

        let whole = snapshots[0]
        #expect(whole.stays.map(\.id) == [s1, s2])
        #expect(whole.aiGeneratedTitle == "Athens Weekend")
        #expect(whole.customName == "With friends")
        #expect(whole.startDate == Self.start)
        #expect(whole.endDate == Self.start.addingTimeInterval(10 * Self.hour))

        let overlap = snapshots[1]
        #expect(overlap.stays.map(\.id) == [s3, s4.id, s5.id])
        #expect(overlap.aiGeneratedTitle == nil)
        #expect(overlap.aiGeneratedSummary == nil)
        #expect(overlap.localizedTitles.isEmpty)
        #expect(overlap.startDate == Self.start.addingTimeInterval(20 * Self.hour))
        #expect(overlap.endDate == Self.start.addingTimeInterval(34 * Self.hour))
    }

    @Test("rows without a twin export exactly as before")
    func singleRowsPassThrough() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = insertTrip(id: UUID(), startHour: 0, endHour: 4, in: context)
        first.customName = "  "
        try insertStay(hour: 0, trip: first, order: 0, in: context)
        let empty = insertTrip(id: UUID(), startHour: 10, endHour: 14, in: context)
        try context.save()

        let snapshots = try TripDataExporter.makeSnapshots(from: [empty, first])
        #expect(snapshots.map(\.id) == [empty.id, first.id])
        #expect(snapshots[1].customName == "  ")
        #expect(snapshots[0].stays.isEmpty)
    }
}
