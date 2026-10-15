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
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, distanceKm: 312, modelContext: ctx))

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
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, distanceKm: 312, modelContext: ctx))

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
            stayID: UUID(), arrivalIdentifier: nil, distanceKm: 312, modelContext: ctx))

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
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, distanceKm: 312, modelContext: ctx,
            beforeFetch: { throw CocoaError(.fileReadUnknown) })
        #expect(!succeeded)
        #expect(!ctx.hasChanges)
        let untouched = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(untouched.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(untouched.distanceFromPreviousKm == 999)

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, distanceKm: 312, modelContext: ctx))
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
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, distanceKm: 312, modelContext: ctx,
            beforeFetch: { throw CocoaError(.fileReadUnknown) })
        #expect(!succeeded)

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(stored.locality == "Pending edit")
        #expect(stored.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(stored.distanceFromPreviousKm == 999)
    }

    @Test("confirm writes to the candidate's own arrival row, never a same-id twin, and is a no-op once that row is gone")
    func confirmActsOnTheCandidateRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeStay(in: ctx, storedKm: 999)
        let twin = makeStay(in: ctx, storedKm: 999)
        twin.id = original.id
        try ctx.save()

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: twin.id, arrivalIdentifier: twin.persistentModelID, distanceKm: 312, modelContext: ctx))
        #expect(twin.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(twin.distanceFromPreviousKm == 312)
        #expect(original.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(original.distanceFromPreviousKm == 999)

        let gone = original.persistentModelID
        ctx.delete(original)
        try ctx.save()
        twin.transitFromPreviousRaw = TransitMode.unknown.rawValue
        try ctx.save()
        #expect(FlightLogView.applyConfirmedFlight(
            stayID: twin.id, arrivalIdentifier: gone, distanceKm: 500, modelContext: ctx))
        #expect(twin.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(twin.distanceFromPreviousKm == 312)
    }

    @Test("a candidate without its row (read back from the stats snapshot) confirms an id that names one row, and writes nothing when it names several")
    func confirmWithoutRowFailsClosedOnTwins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let single = makeStay(in: ctx, storedKm: 999)
        let original = makeStay(in: ctx, storedKm: 999)
        let twin = makeStay(in: ctx, storedKm: 999)
        twin.id = original.id
        try ctx.save()

        #expect(FlightLogView.applyConfirmedFlight(
            stayID: single.id, arrivalIdentifier: nil, distanceKm: 312, modelContext: ctx))
        #expect(single.transitFromPreviousRaw == TransitMode.flight.rawValue)

        #expect(!FlightLogView.applyConfirmedFlight(
            stayID: original.id, arrivalIdentifier: nil, distanceKm: 312, modelContext: ctx))
        #expect(!ctx.hasChanges)
        for row in [original, twin] {
            #expect(row.transitFromPreviousRaw == TransitMode.unknown.rawValue)
            #expect(row.distanceFromPreviousKm == 999)
        }
    }

    @Test("Not a Flight writes the correction to the flight's own row, keeps its distance, and Undo puts the flight back")
    func notAFlightAndUndoActOnTheFlightRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeStay(in: ctx, storedKm: 312)
        let twin = makeStay(in: ctx, storedKm: 312)
        twin.id = original.id
        for row in [original, twin] { row.transitFromPreviousRaw = TransitMode.flight.rawValue }
        try ctx.save()

        #expect(FlightLogView.applyNotAFlight(
            stayID: twin.id, arrivalIdentifier: twin.persistentModelID, modelContext: ctx))
        let stored = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let storedTwin = try #require(stored.first { $0.persistentModelID == twin.persistentModelID })
        let storedOriginal = try #require(stored.first { $0.persistentModelID == original.persistentModelID })
        #expect(storedTwin.transitFromPreviousRaw == TransitMode.notFlight.rawValue)
        #expect(storedTwin.distanceFromPreviousKm == 312)
        #expect(storedOriginal.transitFromPreviousRaw == TransitMode.flight.rawValue)

        #expect(FlightLogView.applyNotAFlight(
            stayID: twin.id, arrivalIdentifier: twin.persistentModelID, undo: true, modelContext: ctx))
        let restored = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let restoredTwin = try #require(restored.first { $0.persistentModelID == twin.persistentModelID })
        #expect(restoredTwin.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(restoredTwin.distanceFromPreviousKm == 312)
    }

    @Test("Undo of Not a Flight checks the committed row, not the correction a long-lived context still holds")
    func notAFlightUndoReadsTheCommittedRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 312)
        stay.transitFromPreviousRaw = TransitMode.notFlight.rawValue
        try ctx.save()

        // Another writer (clustering after the start moved) replaces the
        // correction; `ctx` keeps the row it registered.
        let other = ModelContext(container)
        let committed = try #require(try other.fetch(FetchDescriptor<Stay>()).first)
        committed.transitFromPreviousRaw = TransitMode.unknown.rawValue
        try other.save()
        #expect(stay.transitFromPreviousRaw == TransitMode.notFlight.rawValue)

        #expect(FlightLogView.applyNotAFlight(
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, undo: true, modelContext: ctx))
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(stored.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(stored.distanceFromPreviousKm == 312)
    }

    @Test("Undo of Not a Flight leaves a row alone once something else replaced the correction")
    func notAFlightUndoNeedsTheCorrection() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: 312)
        try ctx.save()

        // The row holds `.unknown` (say, re-inferred after its start moved).
        #expect(FlightLogView.applyNotAFlight(
            stayID: stay.id, arrivalIdentifier: stay.persistentModelID, undo: true, modelContext: ctx))
        #expect(stay.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(!ctx.hasChanges)
    }

    @Test("the arrival row is not written to the stats snapshot: a snapshot encodes as before and decodes without it")
    func candidateSnapshotOmitsTheRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, storedKm: nil)
        try ctx.save()
        let record = CollectionsAggregator.FlightRecord(
            id: stay.id, departureCode: "ATH", arrivalCode: "JSI", departurePlace: nil,
            arrivalPlace: nil, departureISO: "GR", arrivalISO: "GR", date: stay.startTime,
            distanceKm: 130, estimatedHours: 0.7, isInternational: false, timeZonesCrossed: 0,
            isOvernight: false, departureWindowStart: nil)
        let candidate = CollectionsAggregator.PossibleFlight(
            record: record, evidenceRaw: "bothAirports", gapHours: 2,
            arrivalIdentifier: stay.persistentModelID)

        let data = try JSONEncoder().encode(candidate)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["record", "evidenceRaw", "gapHours"])
        let decoded = try JSONDecoder().decode(CollectionsAggregator.PossibleFlight.self, from: data)
        #expect(decoded.arrivalIdentifier == nil)
        #expect(decoded == CollectionsAggregator.PossibleFlight(
            record: record, evidenceRaw: "bothAirports", gapHours: 2))

        // A confirmed flight's row stays out of the snapshot the same way.
        var flight = record
        flight.arrivalIdentifier = stay.persistentModelID
        let flightData = try JSONEncoder().encode(flight)
        let flightKeys = try #require(try JSONSerialization.jsonObject(with: flightData) as? [String: Any]).keys
        #expect(!flightKeys.contains("arrivalIdentifier"))
        #expect(try JSONDecoder().decode(CollectionsAggregator.FlightRecord.self, from: flightData) == record)
    }
}
