//
//  FlightConfirmFlowTests.swift
//  TravelLogTests
//
//  `FlightLogView.applyConfirmedFlight` confirms a queued flight and writes
//  its distance, replacing any stored value. A later import can change the
//  predecessor used to calculate the distance, so confirmation must replace
//  the stale value to keep the flight log consistent with the review queue.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct FlightConfirmFlowTests {

    private func makeStay(in context: ModelContext, storedKm: Double?) -> Stay {
        let base = Date(timeIntervalSince1970: 1_689_718_400)
        let stay = Stay(
            startTime: base, endTime: base.addingTimeInterval(3600),
            centroidLatitude: 38.9933, centroidLongitude: 24.5686,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 130, pingIDs: []
        )
        stay.category = .transit
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        stay.distanceFromPreviousKm = storedKm
        context.insert(stay)
        return stay
    }

    @Test("confirm writes terminal .flight and overwrites a stale stored distance with the vouched-for value")
    func confirmOverwritesStaleDistance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 999) // stale
        try ctx.save()

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: stay.id, distanceKm: 312, modelContext: ctx))

        #expect(stay.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(stay.distanceFromPreviousKm == 312)
    }

    @Test("confirm fills the distance when none was stored (beyond-7-day photo-era legs)")
    func confirmFillsMissingDistance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: nil)
        try ctx.save()

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: stay.id, distanceKm: 312, modelContext: ctx))

        #expect(stay.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(stay.distanceFromPreviousKm == 312)
    }

    @Test("confirm with an unknown stay id is a safe no-op")
    func confirmUnknownIDNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 999)
        try ctx.save()

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: UUID(), distanceKm: 312, modelContext: ctx))

        #expect(stay.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(stay.distanceFromPreviousKm == 999)
    }

    @Test("a failed fetch is not a missing row: confirm reports failure, writes nothing, and a retry succeeds")
    func fetchFailureIsNotSuccess() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 999)
        try ctx.save()

        // `confirmCandidate` restores the candidate and raises the shared
        // save-error alert exactly when the worker returns false.
        let succeeded = FlightLogView.applyConfirmedFlightForTesting(
            stayID: stay.id, distanceKm: 312, modelContext: ctx,
            beforeFetch: { throw CocoaError(.fileReadUnknown) })
        #expect(!succeeded)
        #expect(!ctx.hasChanges)
        let untouched = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(untouched.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(untouched.distanceFromPreviousKm == 999)

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: stay.id, distanceKm: 312, modelContext: ctx))
        let confirmed = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(confirmed.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(confirmed.distanceFromPreviousKm == 312)
    }

    @Test("an unrelated pending edit pre-saved before a failed fetch stays committed")
    func fetchFailureKeepsPreSavedPendingEdit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 999)
        try ctx.save()
        stay.locality = "Pending edit"

        let succeeded = FlightLogView.applyConfirmedFlightForTesting(
            stayID: stay.id, distanceKm: 312, modelContext: ctx,
            beforeFetch: { throw CocoaError(.fileReadUnknown) })
        #expect(!succeeded)

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(stored.locality == "Pending edit")
        #expect(stored.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(stored.distanceFromPreviousKm == 999)
    }
}
