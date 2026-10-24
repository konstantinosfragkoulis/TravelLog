//
//  TransitBatchOutsideGateTests.swift
//  TravelLogTests
//
//  The foreground drain's inbound-leg batch gathers its evidence outside
//  the PipelineGate: reading and evaluating a leg must never hold the gate
//  that live saves and deletion wait on. The batch applies in short gated
//  units that revalidate each leg, so a leg another writer moved between
//  the read and the apply is left for a later batch.
//

import EventKit
import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

@MainActor
@Suite("Transit batch outside the gate", .serialized)
struct TransitBatchOutsideGateTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 722 * 86_400)

    /// Two stays about 145 km apart with a three-hour gap: insufficient
    /// geometry evidence for a flight, even if a calendar booking exists.
    private func seedLeg(_ container: ModelContainer) throws -> (predecessor: UUID, target: UUID) {
        let ctx = ModelContext(container)
        let predecessor = Stay(
            startTime: Self.base, endTime: Self.base.addingTimeInterval(3_600),
            centroidLatitude: 44.3, centroidLongitude: 12.9, h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
        let target = Stay(
            startTime: Self.base.addingTimeInterval(4 * 3_600), endTime: Self.base.addingTimeInterval(8 * 3_600),
            centroidLatitude: 45.6, centroidLongitude: 12.9, h3IndexRes6: "", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: [])
        ctx.insert(predecessor)
        ctx.insert(target)
        try ctx.save()
        return (predecessor.id, target.id)
    }

    private func stay(_ container: ModelContainer, _ id: UUID) throws -> Stay {
        try #require(try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test("local evidence is evaluated while another unit holds the gate", .timeLimit(.minutes(1)))
    func evaluationHoldsNoGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try seedLeg(container)
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())

        // A live save holds the gate for as long as the test says.
        let holderStarted = TestLatch()
        let release = TestLatch()
        let holder = Task {
            await gate.run(touching: .all) {
                await holderStarted.release()
                await release.wait()
            }
        }
        await holderStarted.wait()

        let evaluations = OSAllocatedUnfairLock(initialState: 0)
        let batch = Task {
            // This seam is reached after the production read/decision phase
            // and before its first gated apply. Calendar corroboration is no
            // longer an inference operation and cannot prove this property.
            await TransitInferer.TestScope.$beforeApply.withValue({
                evaluations.withLock { $0 += 1 }
            }) {
                await inferer.inferTransitBatchOutsideGate(gate: gate, publishing: false)
            }
        }
        var polls = 0
        while evaluations.withLock({ $0 }) == 0, polls < 300 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(evaluations.withLock { $0 } == 1, "evidence evaluation waited for the gate another unit held")
        #expect(try stay(container, leg.target).transitFromPreviousRaw == nil,
                "the evaluated leg must not be written before the gate is available")

        await release.release()
        let outcome = await batch.value
        await holder.value
        #expect(!outcome.failed)
        #expect(outcome.fetched == 2)
        #expect(outcome.classified == 2)
        #expect(outcome.flights == 0)
        let target = try stay(container, leg.target)
        #expect(target.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect((target.distanceFromPreviousKm ?? 0) > 100)
        #expect(try stay(container, leg.predecessor).transitFromPreviousRaw == TransitMode.unknown.rawValue)
    }

    @Test("a leg moved between the read and the apply is left pending for the next batch",
          .timeLimit(.minutes(1)))
    func movedLegIsLeftPending() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try seedLeg(container)
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let targetID = leg.target

        let first = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await TransitInferer.TestScope.$beforeApply.withValue({
                // A Visit moves the target stay after the batch evaluated it.
                let other = ModelContext(container)
                guard let row = try? other.fetch(FetchDescriptor<Stay>(
                    predicate: #Predicate { $0.id == targetID })).first else { return }
                row.centroidLatitude = 44.9
                try? other.save()
            }) {
                await inferer.inferTransitBatchOutsideGate(gate: gate, publishing: false)
            }
        }
        #expect(!first.failed)
        #expect(first.fetched == 2)
        #expect(first.classified == 1, "only the unmoved predecessor's leg applies")
        #expect(try stay(container, leg.target).transitFromPreviousRaw == nil)

        let second = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await inferer.inferTransitBatchOutsideGate(gate: gate, publishing: false)
        }
        #expect(second.fetched == 1)
        #expect(second.classified == 1)
        let target = try stay(container, leg.target)
        #expect(target.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        // The distance of the leg as it is now, not as the first read saw it.
        #expect((target.distanceFromPreviousKm ?? 0) < 100)
    }
}
