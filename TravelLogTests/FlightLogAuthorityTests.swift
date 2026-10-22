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

    private func projection(_ fixture: Fixture, dismissals: Set<UUID> = []) throws -> (
        flights: [CollectionsAggregator.FlightRecord], candidates: [CollectionsAggregator.PossibleFlight]
    ) {
        let stays = try fixture.context.fetch(FetchDescriptor<Stay>())
        let evidence = try FlightObservationBounds.fetch(stays: stays, in: fixture.context)
        return try CollectionsAggregator.flightLogRecords(
            rows: stays.filter {
                guard let category = StayCategory(rawValue: $0.categoryRaw) else { return false }
                return category != .unclassified
            }.map {
                CollectionsAggregator.StayRow($0, observationEvidence: evidence[$0.persistentModelID])
            }, predecessorOnly: stays.filter { $0.categoryRaw == StayCategory.unclassified.rawValue }.map {
                CollectionsAggregator.Endpoint($0, categoryRaw: $0.categoryRaw,
                                               observationEvidence: evidence[$0.persistentModelID])
            }, dismissedCandidates: dismissals,
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

    @Test("restored dismissals close only unique members of the captured candidate journey", arguments: 0...6)
    func restoredJourneyMemberDismissal(_ scenario: Int) throws {
        let fixture = try fixture()
        // ATH -> a brief intermediate observation -> AMS is one journey,
        // represented by the intermediate row rather than the destination.
        fixture.origin.endTime = base.addingTimeInterval(0.02 * 3600)
        fixture.arrival.startTime = base.addingTimeInterval(1.5 * 3600)
        fixture.arrival.endTime = base.addingTimeInterval(1.516 * 3600)
        fixture.arrival.centroidLatitude = 45
        fixture.arrival.centroidLongitude = 15
        fixture.arrival.category = .transit
        fixture.arrival.isAirport = false
        fixture.arrival.isoCountryCode = "HR"
        let destination = stay(start: 3, end: 3.016, latitude: 52.3086, longitude: 4.76389)
        destination.isAirport = true
        destination.isoCountryCode = "NL"
        fixture.context.insert(destination)
        // 0: origin; 1/2: target/later member; 3/4: recognized twins;
        // 5/6: unknown-category twins excluded by the production projection.
        let dismissed = scenario == 0 ? fixture.origin : ([1, 4, 6].contains(scenario) ? fixture.arrival : destination)
        if scenario >= 3 {
            let twin = stay(start: 100, end: 124)
            twin.id = dismissed.id
            if scenario >= 5 { twin.categoryRaw = "futureCategory" }
            fixture.context.insert(twin)
        }
        try fixture.context.save()
        let target = try candidateTarget(fixture)
        #expect(target.witness.nodes.map(\.physicalIdentifier) == [
            fixture.origin.persistentModelID, fixture.arrival.persistentModelID, destination.persistentModelID
        ])
        let epoch = FlightLogAuthority.currentEpoch
        var preferences = BackupPreferences()
        preferences.dismissedFlightCandidates = [dismissed.id.uuidString]
        #expect(BackupPreferences.restore(preferences, defaults: fixture.defaults, ubiquitous: fixture.defaults) == 1)
        #expect(FlightLogAuthority.currentEpoch == epoch)
        let visible = try projection(fixture, dismissals: [dismissed.id]).candidates.contains {
            $0.arrivalIdentifier == fixture.arrival.persistentModelID
        }
        let shouldReject = [1, 2, 5, 6].contains(scenario)
        #expect(visible == !shouldReject)
        let result = FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                             defaults: fixture.defaults)
        #expect(result.status == (shouldReject ? .rejected : .committed))
        #expect(try storedMode(fixture) == (shouldReject ? TransitMode.unknown.rawValue : TransitMode.flight.rawValue))
        #expect(fixture.defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) == [dismissed.id.uuidString])
    }

    @Test("a new intermediate predecessor invalidates the candidate the user saw")
    func insertedPredecessorRejectsConfirmation() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        fixture.context.insert(stay(start: 4, end: 4.5))
        try fixture.context.save()
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("a new long overlap is detected even when it starts before the origin")
    func overlapBeforeOriginRejectsConfirmation() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        fixture.context.insert(stay(start: -12, end: 6, latitude: -20, longitude: 100))
        try fixture.context.save()
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("a new contradictory physical overlap revokes confirmation even when it shares the target UUID")
    func overlappingUUIDTwinRejectsStaleConfirmation() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        // This later row cannot become the target's predecessor or successor:
        // the timeline excludes a row's UUID twins from its inbound chain.
        // It is still a distinct contradictory overlapping observation.
        let twin = stay(start: 6, end: 7, latitude: -20, longitude: 100)
        twin.id = fixture.arrival.id
        fixture.context.insert(twin)
        try fixture.context.save()

        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("deleting a captured temporal boundary revokes a retained candidate")
    func deletedBoundaryRejectsConfirmation() throws {
        let fixture = try fixture()
        let boundary = stay(start: -48, end: -24, latitude: 37.9364, longitude: 23.9445)
        fixture.context.insert(boundary)
        try fixture.context.save()
        let target = try candidateTarget(fixture)
        #expect(target.witness.boundaryNodes.contains { $0.physicalIdentifier == boundary.persistentModelID })
        fixture.context.delete(boundary)
        try fixture.context.save()
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
    }

    @Test("changing retained acquisition provenance invalidates a same-time same-place candidate")
    func sourceChangeRejectsConfirmation() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        fixture.origin.sourceRaw = DataSource.merged.rawValue
        try fixture.context.save()
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("a terminal Not a Flight correction is never overwritten by an older candidate")
    func terminalCorrectionWins() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        let other = ModelContext(fixture.container)
        let arrival = try #require(try other.fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == fixture.arrival.persistentModelID
        })
        arrival.transitFromPreviousRaw = TransitMode.notFlight.rawValue
        try other.save()
        #expect(FlightLogAuthority.apply(.confirm(), target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.notFlight.rawValue)
    }

    @Test("a queued action from a revoked epoch writes neither models nor preferences")
    func resetEpochRejectsOldAction() throws {
        let fixture = try fixture()
        let candidate = try #require(try projection(fixture).candidates.first)
        let now = FlightLogAuthority.currentEpoch
        let target = try #require(FlightLogAuthority.Target(candidate: candidate,
            epoch: .init(pipeline: now.pipeline - 1, snapshot: now.snapshot)))
        #expect(FlightLogAuthority.apply(.confirm(times: times(2, 5), stops: ["FRA"]),
                                         target: target, context: fixture.context,
                                         defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
    }

    @Test("a retained time editor cannot overwrite a newer imported answer")
    func newerTimesRejectOldEditor() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        let newer = times(1, 4)
        FlightTimeOverrides.set(newer, for: fixture.arrival.id, defaults: fixture.defaults)
        #expect(FlightLogAuthority.apply(.setTimes(times(2, 5)), target: target,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == newer)
    }

    @Test("auto-saving times advances only that editor's own expected answer")
    func updatedTargetDoesNotAdoptUnseenStops() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        FlightStops.set(["FRA"], for: fixture.arrival.id, defaults: fixture.defaults)
        let first = FlightLogAuthority.apply(.setTimes(times(2, 5)), target: target,
                                             context: fixture.context, defaults: fixture.defaults)
        #expect(first.status == .committed)
        let advanced = try #require(first.updatedTarget)
        #expect(FlightLogAuthority.apply(.setTimes(times(1.5, 4.5)), target: advanced,
                                         context: fixture.context, defaults: fixture.defaults).status == .committed)
        #expect(FlightLogAuthority.apply(.setStops(["CDG"]), target: advanced,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == ["FRA"])
    }

    @Test("fractional generated times advance to the persisted value for another edit and removal")
    func fractionalTimesAllowConsecutiveEditsAndRemoval() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        let draft = FlightTimeOverrides.suggested(
            windowStart: target.windowStart, windowEnd: target.windowEnd,
            estimatedHours: CollectionsAggregator.estimatedHours(distanceKm: target.distanceKm),
            earliestDeparture: target.earliestDeparture)
        FlightStops.set(["FRA"], for: fixture.arrival.id, defaults: fixture.defaults)
        let first = FlightLogAuthority.apply(.setTimes(draft), target: target,
                                             context: fixture.context, defaults: fixture.defaults)
        #expect(first.status == .committed)
        let stored = try #require(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults))
        #expect(stored != draft)
        let advanced = try #require(first.updatedTarget)
        #expect(advanced.annotations?.times == stored)
        #expect(advanced.annotations?.stops == nil)

        let edited = FlightTimeOverrides.Times(
            departure: draft.departure.addingTimeInterval(-60), arrival: draft.arrival)
        let second = FlightLogAuthority.apply(.setTimes(edited), target: advanced,
                                              context: fixture.context, defaults: fixture.defaults)
        #expect(second.status == .committed)
        let editedTarget = try #require(second.updatedTarget)
        #expect(editedTarget.annotations?.times == FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults))
        let cleared = FlightLogAuthority.apply(.setTimes(nil), target: editedTarget,
                                               context: fixture.context, defaults: fixture.defaults)
        #expect(cleared.status == .committed)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(fixture.defaults.stringArray(forKey: FlightTimeOverrides.defaultsKey) == [fixture.arrival.id.uuidString])
        let clearedTarget = try #require(cleared.updatedTarget)
        #expect(FlightLogAuthority.apply(.setStops(["CDG"]), target: clearedTarget,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == ["FRA"])
    }

    @Test("rounding beyond either allowed time boundary rejects edits and candidate confirmation")
    func roundedTimesOutsideWindowReject() throws {
        for mode in [TransitMode.flight, .unknown] {
            let fixture = try fixture(mode: mode)
            fixture.origin.startTime = fixture.origin.startTime.addingTimeInterval(0.25)
            fixture.arrival.startTime = fixture.arrival.startTime.addingTimeInterval(0.75)
            try fixture.context.save()
            let target = try (mode == .flight ? flightTarget(fixture) : candidateTarget(fixture))
            let range = FlightTimeOverrides.allowedRange(
                windowStart: target.windowStart, windowEnd: target.windowEnd,
                earliestDeparture: target.earliestDeparture)
            let drafts = [
                FlightTimeOverrides.Times(departure: range.lowerBound,
                                          arrival: range.lowerBound.addingTimeInterval(3600)),
                FlightTimeOverrides.Times(departure: range.upperBound.addingTimeInterval(-3600),
                                          arrival: range.upperBound)
            ]
            for draft in drafts {
                #expect(FlightTimeOverrides.fits(draft, windowStart: target.windowStart,
                                                windowEnd: target.windowEnd,
                                                earliestDeparture: target.earliestDeparture))
                let action: FlightLogAuthority.Action = mode == .flight ? .setTimes(draft) : .confirm(times: draft)
                #expect(FlightLogAuthority.apply(action, target: target, context: fixture.context,
                                                 defaults: fixture.defaults).status == .rejected)
                #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
                #expect(try storedMode(fixture) == mode.rawValue)
            }
        }
    }

    @Test("rounding inward preserves valid edge corrections and canonical no-op edits")
    func roundedTimesInsideWindowCommit() throws {
        for mode in [TransitMode.flight, .unknown] {
            for nearLowerBoundary in [true, false] {
                let fixture = try fixture(mode: mode)
                fixture.origin.startTime = fixture.origin.startTime.addingTimeInterval(0.25)
                fixture.arrival.startTime = fixture.arrival.startTime.addingTimeInterval(0.75)
                try fixture.context.save()
                let target = try (mode == .flight ? flightTarget(fixture) : candidateTarget(fixture))
                let range = FlightTimeOverrides.allowedRange(
                    windowStart: target.windowStart, windowEnd: target.windowEnd,
                    earliestDeparture: target.earliestDeparture)
                let departure = nearLowerBoundary
                    ? range.lowerBound.addingTimeInterval(0.3)
                    : range.upperBound.addingTimeInterval(-3600.3)
                let draft = FlightTimeOverrides.Times(departure: departure,
                                                      arrival: departure.addingTimeInterval(3600))
                let action: FlightLogAuthority.Action = mode == .flight ? .setTimes(draft) : .confirm(times: draft)
                let result = FlightLogAuthority.apply(action, target: target, context: fixture.context,
                                                      defaults: fixture.defaults)
                #expect(result.status == .committed)
                let stored = try #require(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults))
                #expect(FlightTimeOverrides.fits(stored, windowStart: target.windowStart,
                                                windowEnd: target.windowEnd,
                                                earliestDeparture: target.earliestDeparture))
                #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
                if mode == .flight {
                    let advanced = try #require(result.updatedTarget)
                    #expect(advanced.annotations?.times == stored)
                    #expect(FlightLogAuthority.apply(.setTimes(draft), target: advanced,
                                                     context: fixture.context, defaults: fixture.defaults).status == .unchanged)
                }
            }
        }
    }

    @Test("candidate confirmation never rolls old preferences over a newer answer on save failure")
    func failedConfirmationDoesNotRollbackPreferences() throws {
        let fixture = try fixture()
        let before = times(1, 4)
        FlightTimeOverrides.set(before, for: fixture.arrival.id, defaults: fixture.defaults)
        let target = try candidateTarget(fixture)
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            if case .beforeSave = point { throw CocoaError(.fileWriteUnknown) }
        }) {
            FlightLogAuthority.apply(.confirm(times: times(2, 5), stops: ["FRA"]), target: target,
                                     context: fixture.context, defaults: fixture.defaults)
        }
        #expect(result.status == .failed)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == before)
        #expect(FlightStops.stops(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
    }

    @Test("explicit candidate removal of saved times commits a backup-safe tombstone")
    func confirmationCanExplicitlyClearTimes() throws {
        let fixture = try fixture()
        FlightTimeOverrides.set(times(1, 4), for: fixture.arrival.id, defaults: fixture.defaults)
        let target = try candidateTarget(fixture)
        #expect(FlightLogAuthority.apply(.confirm(clearTimes: true), target: target,
                                         context: fixture.context, defaults: fixture.defaults).status == .committed)
        #expect(try storedMode(fixture) == TransitMode.flight.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
        #expect(fixture.defaults.stringArray(forKey: FlightTimeOverrides.defaultsKey) == [fixture.arrival.id.uuidString])
    }

    @Test("a failed explicit-clear confirmation preserves the old answer")
    func failedConfirmationDoesNotClearTimes() throws {
        let fixture = try fixture()
        let earlier = times(1, 4)
        FlightTimeOverrides.set(earlier, for: fixture.arrival.id, defaults: fixture.defaults)
        let target = try candidateTarget(fixture)
        let result = try FlightLogAuthority.withFailureForTesting({ point in
            if case .beforeSave = point { throw CocoaError(.fileWriteUnknown) }
        }) {
            FlightLogAuthority.apply(.confirm(clearTimes: true), target: target,
                                     context: fixture.context, defaults: fixture.defaults)
        }
        #expect(result.status == .failed)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == earlier)
    }

    @Test("an ambiguous set-and-clear request is rejected before either store changes")
    func contradictoryTimeCorrectionRejects() throws {
        let fixture = try fixture()
        let target = try candidateTarget(fixture)
        #expect(FlightLogAuthority.apply(.confirm(times: times(2, 5), clearTimes: true), target: target,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.unknown.rawValue)
        #expect(FlightTimeOverrides.times(for: fixture.arrival.id, defaults: fixture.defaults) == nil)
    }

    @Test("Undo cannot restore a flight over a changed current journey")
    func insertedPredecessorRejectsUndo() throws {
        let fixture = try fixture(mode: .flight)
        let target = try flightTarget(fixture)
        let first = FlightLogAuthority.apply(.markNotFlight, target: target,
                                             context: fixture.context, defaults: fixture.defaults)
        let receipt = try #require(first.receipt)
        fixture.context.insert(stay(start: 4, end: 4.5))
        try fixture.context.save()
        #expect(FlightLogAuthority.apply(.undo(receipt), target: target,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
        #expect(try storedMode(fixture) == TransitMode.notFlight.rawValue)
    }

    @Test("overlap authority uses native physical identifiers independently of twin fetch order")
    func overlapIdentifierPermutationIsStable() throws {
        let fixture = try fixture()
        let first = stay(start: 3, end: 7)
        let second = stay(start: 3, end: 7)
        second.id = first.id
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()
        #expect(first.persistentModelID != second.persistentModelID)

        func node(_ stay: Stay) -> FlightLogAuthority.Node {
            .init(endpoint: CollectionsAggregator.Endpoint(stay),
                  modeRaw: stay.transitFromPreviousRaw)
        }
        let target = node(fixture.arrival)
        // Both twins overlap the selected target and have equal start/end
        // and UUID values. The persisted physical identifiers distinguish
        // them even on OS releases whose debug descriptions do not.
        let firstOrder = [node(first), node(second), target]
        let secondOrder = [node(second), node(first), target]
        let firstWitness = FlightLogAuthority.Witness.capture(
            targetIdentifier: target.physicalIdentifier, journeyIndices: [2],
            orderedNodes: firstOrder, previous: [nil, nil, nil], next: [nil, nil, nil])
        let secondWitness = FlightLogAuthority.Witness.capture(
            targetIdentifier: target.physicalIdentifier, journeyIndices: [2],
            orderedNodes: secondOrder, previous: [nil, nil, nil], next: [nil, nil, nil])

        let expected = [first.persistentModelID, second.persistentModelID].sorted()
        #expect(firstWitness.topology.first?.overlaps == expected)
        #expect(secondWitness.topology.first?.overlaps == expected)
        #expect(firstWitness.topology == secondWitness.topology)
    }
}
