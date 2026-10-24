//
//  FlightConfirmFlowTests.swift
//  TravelLogTests
//
//  Exercise the same fresh-row authority leaf used by Flight Log actions.
//  Displayed candidates supply a transient journey witness, never UUID-only
//  permission to mutate whichever row an import later places in the store.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct FlightConfirmFlowTests {

    private struct Pair {
        let origin: Stay
        let arrival: Stay
    }

    private func makePair(in context: ModelContext, storedKm: Double?, dayOffset: Int = 0,
                          mode: TransitMode = .unknown) -> Pair {
        let base = Date(timeIntervalSince1970: 1_689_718_400)
            .addingTimeInterval(Double(dayOffset) * 86_400)
        let origin = Stay(
            startTime: base, endTime: base.addingTimeInterval(2 * 3600),
            centroidLatitude: 37.9364, centroidLongitude: 23.9445,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 30, pingIDs: [])
        origin.category = .transit
        origin.isAirport = true
        origin.isoCountryCode = "GR"
        origin.sourceRaw = DataSource.photoImport.rawValue
        let arrival = Stay(
            startTime: base.addingTimeInterval(5 * 3600),
            endTime: base.addingTimeInterval(29 * 3600),
            centroidLatitude: 52.3086, centroidLongitude: 4.76389,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 2_000, pingIDs: [])
        arrival.category = .destination
        arrival.isAirport = true
        arrival.isoCountryCode = "NL"
        arrival.sourceRaw = DataSource.photoImport.rawValue
        arrival.transitFromPreviousRaw = mode.rawValue
        arrival.distanceFromPreviousKm = storedKm
        context.insert(origin)
        context.insert(arrival)
        return Pair(origin: origin, arrival: arrival)
    }

    /// Capture an actual projection's action guard, exactly as a displayed
    /// row receives it.
    private func records(in context: ModelContext) throws -> (
        flights: [CollectionsAggregator.FlightRecord], candidates: [CollectionsAggregator.PossibleFlight]
    ) {
        let stays = try context.fetch(FetchDescriptor<Stay>())
        return try CollectionsAggregator.flightLogRecords(
            rows: stays.map { CollectionsAggregator.StayRow($0) },
            predecessorOnly: [], dismissedCandidates: [], flightTimes: [:], flightStops: [:])
    }

    private func candidate(for stay: Stay, in context: ModelContext) throws -> CollectionsAggregator.PossibleFlight {
        try #require(try records(in: context).candidates.first {
            $0.arrivalIdentifier == stay.persistentModelID
        })
    }

    private func flight(for stay: Stay, in context: ModelContext) throws -> CollectionsAggregator.FlightRecord {
        try #require(try records(in: context).flights.first {
            $0.arrivalIdentifier == stay.persistentModelID
        })
    }

    private func stored(_ identifier: PersistentIdentifier, in container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == identifier
        })
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "FlightConfirmFlowTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("confirm stores the current candidate's distance, replacing stale imported distance")
    func confirmOverwritesStaleDistance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let displayed = try candidate(for: pair.arrival, in: ctx)
        let target = try #require(FlightLogAuthority.Target(candidate: displayed))
        let result = FlightLogAuthority.apply(.confirm(), target: target, context: ctx,
                                             defaults: try isolatedDefaults())
        #expect(result.status == .committed)
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(saved.distanceFromPreviousKm == displayed.record.distanceKm)
        #expect(displayed.record.distanceKm > 2_000 && displayed.record.distanceKm < 2_300)
    }

    @Test("confirm fills a missing distance with the current journey's distance")
    func confirmFillsMissingDistance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: nil)
        try ctx.save()
        let displayed = try candidate(for: pair.arrival, in: ctx)
        let target = try #require(FlightLogAuthority.Target(candidate: displayed))
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: ctx,
                                        defaults: try isolatedDefaults()).status == .committed)
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(saved.distanceFromPreviousKm == displayed.record.distanceKm)
    }

    @Test("a disappeared physical row is rejected, even when its UUID now names one replacement")
    func confirmMissingRowDoesNotChooseReplacement() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(candidate: try candidate(for: pair.arrival, in: ctx)))
        let oldID = pair.arrival.id
        ctx.delete(pair.arrival)
        let replacement = makePair(in: ctx, storedKm: 700, dayOffset: 3).arrival
        replacement.id = oldID
        try ctx.save()

        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: ctx,
                                        defaults: try isolatedDefaults()).status == .rejected)
        let saved = try stored(replacement.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(saved.distanceFromPreviousKm == 700)
    }

    @Test("a failed authoritative read reports failure, changes nothing, and permits a retry")
    func fetchFailureIsNotSuccess() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(candidate: try candidate(for: pair.arrival, in: ctx)))
        let defaults = try isolatedDefaults()
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            switch point {
            case .beforeRead: throw CocoaError(.fileReadUnknown)
            case .beforeSave: break
            }
        }) {
            FlightLogAuthority.apply(.confirm(), target: target, context: ctx, defaults: defaults)
        }
        #expect(result.status == .failed)
        #expect(!ctx.hasChanges)
        let untouched = try stored(pair.arrival.persistentModelID, in: container)
        #expect(untouched.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(untouched.distanceFromPreviousKm == 999)
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: ctx,
                                        defaults: defaults).status == .committed)
    }

    @Test("pre-saving an unrelated edit survives an action read failure")
    func fetchFailureKeepsPreSavedPendingEdit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(candidate: try candidate(for: pair.arrival, in: ctx)))
        pair.origin.subLocality = "Pending edit"
        let defaults = try isolatedDefaults()
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            switch point {
            case .beforeRead: throw CocoaError(.fileReadUnknown)
            case .beforeSave: break
            }
        }) {
            FlightLogAuthority.apply(.confirm(), target: target, context: ctx, defaults: defaults)
        }
        #expect(result.status == .failed)
        #expect(try stored(pair.origin.persistentModelID, in: container).subLocality == "Pending edit")
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(saved.distanceFromPreviousKm == 999)
    }

    @Test("save failure rolls back only the action, retaining unrelated pre-saved edits")
    func saveFailureKeepsPendingEditAndDistance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(candidate: try candidate(for: pair.arrival, in: ctx)))
        pair.origin.subLocality = "Pending edit"
        let defaults = try isolatedDefaults()
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            switch point {
            case .beforeRead: break
            case .beforeSave: throw CocoaError(.fileWriteUnknown)
            }
        }) {
            FlightLogAuthority.apply(.confirm(), target: target, context: ctx, defaults: defaults)
        }
        #expect(result.status == .failed)
        #expect(try stored(pair.origin.persistentModelID, in: container).subLocality == "Pending edit")
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(saved.distanceFromPreviousKm == 999)
    }

    @Test("confirm changes only the captured physical arrival among UUID twins")
    func confirmActsOnTheCandidateRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makePair(in: ctx, storedKm: 999)
        let twin = makePair(in: ctx, storedKm: 888, dayOffset: 3)
        twin.arrival.id = original.arrival.id
        try ctx.save()
        let displayed = try candidate(for: twin.arrival, in: ctx)
        let target = try #require(FlightLogAuthority.Target(candidate: displayed))
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: ctx,
                                        defaults: try isolatedDefaults()).status == .committed)
        let savedTwin = try stored(twin.arrival.persistentModelID, in: container)
        let savedOriginal = try stored(original.arrival.persistentModelID, in: container)
        #expect(savedTwin.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(savedTwin.distanceFromPreviousKm == displayed.record.distanceKm)
        #expect(savedOriginal.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(savedOriginal.distanceFromPreviousKm == 999)
    }

    @Test("a cached candidate cannot authorize writes even when its UUID names exactly one row")
    func candidateSnapshotCannotGrantWriteAuthority() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 999)
        try ctx.save()
        let displayed = try candidate(for: pair.arrival, in: ctx)
        let decoded = try JSONDecoder().decode(CollectionsAggregator.PossibleFlight.self,
                                               from: JSONEncoder().encode(displayed))
        #expect(decoded.arrivalIdentifier == nil)
        #expect(decoded.record.arrivalIdentifier == nil)
        #expect(decoded.record.actionGuard == nil)
        #expect(FlightLogAuthority.Target(candidate: decoded) == nil)
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(saved.distanceFromPreviousKm == 999)
    }

    @Test("Not a Flight and its receipt-based Undo act on one physical UUID twin and retain distance")
    func notAFlightAndUndoActOnTheFlightRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makePair(in: ctx, storedKm: 312, mode: .flight)
        let twin = makePair(in: ctx, storedKm: 312, dayOffset: 3, mode: .flight)
        twin.arrival.id = original.arrival.id
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(record: try flight(for: twin.arrival, in: ctx)))
        let defaults = try isolatedDefaults()
        let result = FlightLogAuthority.apply(.markNotFlight, target: target, context: ctx, defaults: defaults)
        #expect(result.status == .committed)
        let receipt = try #require(result.receipt)
        #expect(try stored(twin.arrival.persistentModelID, in: container).transitFromPreviousRaw == TransitMode.notFlight.rawValue)
        #expect(try stored(original.arrival.persistentModelID, in: container).transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(try stored(twin.arrival.persistentModelID, in: container).distanceFromPreviousKm == 312)
        #expect(FlightLogAuthority.apply(.undo(receipt), target: target, context: ctx,
                                        defaults: defaults).status == .committed)
        let restored = try stored(twin.arrival.persistentModelID, in: container)
        #expect(restored.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(restored.distanceFromPreviousKm == 312)
    }

    @Test("Undo re-reads committed authority and refuses a correction replaced by another writer")
    func notAFlightUndoReadsTheCommittedRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: 312, mode: .flight)
        try ctx.save()
        let target = try #require(FlightLogAuthority.Target(record: try flight(for: pair.arrival, in: ctx)))
        let defaults = try isolatedDefaults()
        let correction = FlightLogAuthority.apply(.markNotFlight, target: target, context: ctx, defaults: defaults)
        let receipt = try #require(correction.receipt)
        // The caller retains its pre-action model while another context
        // replaces the committed correction. Undo must not restore a flight.
        let other = ModelContext(container)
        let row = try #require(try other.fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == pair.arrival.persistentModelID
        })
        row.transitFromPreviousRaw = TransitMode.unknown.rawValue
        try other.save()
        #expect(FlightLogAuthority.apply(.undo(receipt), target: target, context: ctx,
                                        defaults: defaults).status == .rejected)
        let saved = try stored(pair.arrival.persistentModelID, in: container)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(saved.distanceFromPreviousKm == 312)
    }

    @Test("physical arrival and action authority never enter the stats snapshot")
    func candidateSnapshotOmitsTheRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let pair = makePair(in: ctx, storedKm: nil)
        try ctx.save()
        let displayed = try candidate(for: pair.arrival, in: ctx)
        let data = try JSONEncoder().encode(displayed)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!object.keys.contains("arrivalIdentifier"))
        let record = try #require(object["record"] as? [String: Any])
        for forbidden in ["arrivalIdentifier", "actionGuard", "annotationSnapshot"] {
            #expect(!record.keys.contains(forbidden))
        }
        let decoded = try JSONDecoder().decode(CollectionsAggregator.PossibleFlight.self, from: data)
        #expect(decoded.arrivalIdentifier == nil)
        #expect(decoded.record.actionGuard == nil)
        #expect(FlightLogAuthority.Target(candidate: decoded) == nil)

        let flightData = try JSONEncoder().encode(displayed.record)
        let decodedFlight = try JSONDecoder().decode(CollectionsAggregator.FlightRecord.self, from: flightData)
        #expect(decodedFlight.arrivalIdentifier == nil)
        #expect(decodedFlight.actionGuard == nil)
        #expect(FlightLogAuthority.Target(record: decodedFlight) == nil)
    }
}
