import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// Regressions for a retained row/editor racing an import, correction, or
/// reset. These use the real projection and fresh-context action leaf.
@MainActor
struct FlightLogAuthorityTests {
    private let base = Date(timeIntervalSince1970: 1_689_718_400)

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let defaults: UserDefaults
        let origin: Stay
        let arrival: Stay
    }

    /// ATH, then AMS three hours later: one journey, on the arrival.
    private func fixture(mode: TransitMode = .unknown) throws -> Fixture {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let defaults = try #require(UserDefaults(suiteName: "FlightLogAuthorityTests.\(UUID().uuidString)"))
        let origin = stay(start: 0, end: 2, latitude: 37.9364, longitude: 23.9445)
        origin.isAirport = true
        origin.isoCountryCode = "GR"
        let arrival = stay(start: 5, end: 29, latitude: 52.3086, longitude: 4.76389)
        arrival.category = .destination
        arrival.isAirport = true
        arrival.isoCountryCode = "NL"
        arrival.transitFromPreviousRaw = mode.rawValue
        arrival.distanceFromPreviousKm = 2_180
        context.insert(origin)
        context.insert(arrival)
        try context.save()
        return Fixture(container: container, context: context, defaults: defaults, origin: origin, arrival: arrival)
    }

    private func stay(start: Double, end: Double, latitude: Double = 45, longitude: Double = 15) -> Stay {
        let stay = Stay(startTime: base.addingTimeInterval(start * 3600),
                        endTime: base.addingTimeInterval(end * 3600),
                        centroidLatitude: latitude, centroidLongitude: longitude,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [])
        stay.category = .transit
        stay.sourceRaw = DataSource.photoImport.rawValue
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        return stay
    }

    private func projection(_ fixture: Fixture) throws -> (
        flights: [CollectionsAggregator.FlightRecord], candidates: [CollectionsAggregator.PossibleFlight]
    ) {
        let stays = try fixture.context.fetch(FetchDescriptor<Stay>())
        return try CollectionsAggregator.flightLogRecords(
            rows: stays.map { CollectionsAggregator.StayRow($0) }, predecessorOnly: [],
            dismissedCandidates: [],
            flightTimes: FlightTimeOverrides.all(defaults: fixture.defaults),
            flightStops: FlightStops.all(defaults: fixture.defaults))
    }

    private func candidateTarget(_ fixture: Fixture) throws -> FlightLogAuthority.Target {
        let candidate = try #require(try projection(fixture).candidates.first {
            $0.arrivalIdentifier == fixture.arrival.persistentModelID
        })
        return try #require(FlightLogAuthority.Target(candidate: candidate))
    }

    private func flightTarget(_ fixture: Fixture) throws -> FlightLogAuthority.Target {
        let record = try #require(try projection(fixture).flights.first {
            $0.arrivalIdentifier == fixture.arrival.persistentModelID
        })
        return try #require(FlightLogAuthority.Target(record: record))
    }

    private func storedMode(_ fixture: Fixture) throws -> String? {
        try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == fixture.arrival.persistentModelID
        }).transitFromPreviousRaw
    }

    private func times(_ start: Double, _ end: Double) -> FlightTimeOverrides.Times {
        .init(departure: base.addingTimeInterval(start * 3600), arrival: base.addingTimeInterval(end * 3600))
    }

    private func dismissals(_ fixture: Fixture) -> Set<UUID> {
        Set((fixture.defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
    }

    private func apply(_ action: FlightLogAuthority.Action, _ target: FlightLogAuthority.Target,
                       _ fixture: Fixture) -> FlightLogAuthority.Status {
        FlightLogAuthority.apply(action, target: target, context: fixture.context,
                                 defaults: fixture.defaults).status
    }

    @Test("an unchanged journey confirms, and its answers land after the row")
    func unchangedJourneyConfirms() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        #expect(target.actionGuard.predecessor == fixture.origin.persistentModelID)
        // An unrelated stay elsewhere in history changes nothing here.
        fixture.context.insert(stay(start: -100, end: -90))
        try fixture.context.save()
        #expect(apply(.confirm(times: times(2.5, 4.5), stops: ["FRA"]), target, fixture) == .committed)
        #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == times(2.5, 4.5))
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == ["FRA"])
    }

    @Test("a new stay between the predecessor and the target rejects the action")
    func insertedPredecessorRejects() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        fixture.context.insert(stay(start: 3, end: 3.5))
        try fixture.context.save()
        #expect(apply(.confirm(), target, fixture) == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("a moved predecessor end or target interval rejects the action")
    func changedBoundsReject() throws {
        for change in 0..<2 {
            let fixture = try fixture()
            let target = try candidateTarget(fixture)
            if change == 0 {
                fixture.origin.endTime = base.addingTimeInterval(2.5 * 3600)
            } else {
                fixture.arrival.startTime = base.addingTimeInterval(4 * 3600)
            }
            try fixture.context.save()
            #expect(apply(.confirm(), target, fixture) == .rejected)
            #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
        }
    }

    @Test("a terminal Not a Flight saved elsewhere is never overwritten by an older candidate")
    func terminalCorrectionWins() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        let other = ModelContext(fixture.container)
        let arrival = try #require(try other.fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == fixture.arrival.persistentModelID
        })
        arrival.transitFromPreviousRaw = TransitMode.notFlight.rawValue
        try other.save()
        #expect(apply(.confirm(), target, fixture) == .rejected)
        #expect(try storedMode(fixture) == TransitMode.notFlight.rawValue)
    }

    @Test("Undo lands only while the row still holds Not a Flight")
    func notFlightUndoIsCompareAndSet() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        let marked = FlightLogAuthority.apply(.markNotFlight, target: target, context: fixture.context,
                                              defaults: fixture.defaults)
        let receipt = try #require(marked.receipt)
        #expect(try storedMode(fixture) == TransitMode.notFlight.rawValue)
        #expect(apply(.undo(receipt), receipt.target, fixture) == .committed)
        #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
        // A second Undo of the same receipt finds the row no longer holding it.
        #expect(apply(.undo(receipt), receipt.target, fixture) == .rejected)
        #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
    }

    @Test("dismissal Undo restores only while the preference holds this dismissal")
    func dismissalUndoIsCompareAndSet() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        let dismissed = FlightLogAuthority.apply(.dismiss, target: target, context: fixture.context,
                                                 defaults: fixture.defaults)
        let receipt = try #require(dismissed.receipt)
        #expect(dismissals(fixture).contains(fixture.arrival.id))
        #expect(apply(.undo(receipt), target, fixture) == .committed)
        #expect(!dismissals(fixture).contains(fixture.arrival.id))

        let again = try #require(FlightLogAuthority.apply(.dismiss, target: target, context: fixture.context,
                                                          defaults: fixture.defaults).receipt)
        fixture.defaults.removeObject(forKey: FlightCandidateDismissals.defaultsKey)
        #expect(apply(.undo(again), target, fixture) == .rejected)
    }

    @Test("a failed save writes neither the row nor any answer")
    func failedSaveWritesNoPreferences() throws {
        let fixture = try fixture()
        let before = times(1, 4)
        FlightTimeOverrides.set(before, for: fixture.arrival.id, defaults: fixture.defaults)
        let target = try candidateTarget(fixture)
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            if case .beforeSave = point { throw CocoaError(.fileWriteUnknown) }
        }) {
            FlightLogAuthority.apply(.confirm(times: times(2.5, 4.5), stops: ["FRA"]), target: target,
                                     context: fixture.context, defaults: fixture.defaults)
        }
        #expect(result.status == .failed)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == before)
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
    }

    @Test("a queued action from before a wipe writes nothing")
    func revokedEpochRejects() throws {
        let fixture = try fixture()
        let candidate = try #require(try projection(fixture).candidates.first)
        let now = FlightLogAuthority.currentEpoch
        let target = try #require(FlightLogAuthority.Target(candidate: candidate,
            epoch: .init(pipeline: now.pipeline - 1, snapshot: now.snapshot)))
        #expect(apply(.confirm(times: times(2.5, 4.5), stops: ["FRA"]), target, fixture) == .rejected)
        #expect(apply(.dismiss, target, fixture) == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(dismissals(fixture).isEmpty)
    }

    @Test("a UUID several rows share takes no answers, while the tapped row still confirms")
    func twinRefusesCorrections() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        let twin = stay(start: 100, end: 124)
        twin.id = fixture.arrival.id
        fixture.context.insert(twin)
        try fixture.context.save()
        #expect(apply(.confirm(times: times(2.5, 4.5)), target, fixture) == .rejected)
        #expect(apply(.dismiss, target, fixture) == .rejected)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(apply(.confirm(), target, fixture) == .committed)
        #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
        let storedTwin = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == twin.persistentModelID
        })
        #expect(storedTwin.transitFromPreviousRaw == TransitMode.unknown.rawValue)
    }

    @Test("an existing dismissal of the journey vetoes confirmation")
    func dismissalVetoesConfirmation() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        fixture.defaults.set([fixture.arrival.id.uuidString], forKey: FlightCandidateDismissals.defaultsKey)
        #expect(apply(.confirm(), target, fixture) == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("times save as whole seconds inside the window; edits compare what the editor saw")
    func timesAreCanonicalAndCompared() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        let draft = FlightTimeOverrides.Times(departure: base.addingTimeInterval(2.5 * 3600 + 0.4),
                                              arrival: base.addingTimeInterval(4.5 * 3600 + 0.6))
        let saved = FlightLogAuthority.apply(.setTimes(draft), target: target, context: fixture.context,
                                             defaults: fixture.defaults)
        #expect(saved.status == .committed)
        let stored = try #require(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults))
        #expect(stored.departure.timeIntervalSince1970 == stored.departure.timeIntervalSince1970.rounded())
        #expect(stored.arrival.timeIntervalSince1970 == stored.arrival.timeIntervalSince1970.rounded())
        // The original editor still expects no times: a second save is stale.
        #expect(apply(.setTimes(times(3, 4.5)), target, fixture) == .rejected)
        let advanced = try #require(saved.updatedTarget)
        #expect(apply(.setTimes(times(3, 4.5)), advanced, fixture) == .committed)
        #expect(apply(.setTimes(times(-30, -28)), target, fixture) == .rejected)
        #expect(apply(.setStops(["NOPE"]), advanced, fixture) == .rejected)
    }

    @Test("an arrival still recording grows its end, and the flight's answers still save")
    func growingLiveArrivalStillAccepts() throws {
        let live = try fixture(mode: .flight)
        let target = try flightTarget(live)
        #expect(target.actionGuard.arrival == nil)
        live.arrival.endTime = base.addingTimeInterval(31 * 3600)
        try live.context.save()
        let saved = FlightLogAuthority.apply(.setTimes(times(2.5, 4.5)), target: target,
                                             context: live.context, defaults: live.defaults)
        #expect(saved.status == .committed)
        let advanced = try #require(saved.updatedTarget)
        #expect(apply(.setStops(["FRA"]), advanced, live) == .committed)
        #expect(apply(.markNotFlight, target, live) == .committed)
        // An end that moved back is a different stay.
        let shrunk = try fixture(mode: .flight)
        let shrunkTarget = try flightTarget(shrunk)
        shrunk.arrival.endTime = base.addingTimeInterval(20 * 3600)
        try shrunk.context.save()
        #expect(apply(.markNotFlight, shrunkTarget, shrunk) == .rejected)
    }

    @Test("a moved arrival or a new stay inside the journey rejects the old answer")
    func changedArrivalRejects() throws {
        for change in 0..<3 {
            let journey = try fixture()
            // A fix on the way for minutes, then the city: the journey the
            // question names ends at the city.
            journey.arrival.endTime = base.addingTimeInterval(5.1 * 3600)
            journey.arrival.isAirport = false
            let city = stay(start: 5.5, end: 29, latitude: 52.4, longitude: 4.9)
            city.category = .destination
            city.isoCountryCode = "NL"
            journey.context.insert(city)
            try journey.context.save()
            let target = try candidateTarget(journey)
            #expect(target.actionGuard.arrival == city.persistentModelID)
            switch change {
            case 0: break
            case 1: city.startTime = base.addingTimeInterval(5.7 * 3600)
            default: journey.context.insert(stay(start: 5.2, end: 5.3, latitude: 52.3, longitude: 4.8))
            }
            try journey.context.save()
            #expect(apply(.confirm(), target, journey) == (change == 0 ? .committed : .rejected))
        }
    }
}
