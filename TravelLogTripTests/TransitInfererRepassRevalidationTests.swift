//
//  TransitInfererRepassRevalidationTests.swift
//  TravelLogTests
//
//  The Detect Flights / Match Calendar re-passes evaluate `.unknown` legs
//  outside the gate and apply later. The apply must commit only while the
//  evaluated leg is still the leg in the store: same physical target and
//  predecessor rows, same gap bounds, same endpoint coordinates. Another
//  writer (photo import attach, Visit reconciliation, a stay clustered into
//  the gap) can change any of these between read and apply; the
//  `beforeApply` seam lands exactly those writes in that window, through a
//  separate context as the real writers do.
//

import EventKit
import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

@MainActor
struct TransitInfererRepassRevalidationTests {

    nonisolated static let ath = (lat: 37.9364, lon: 23.9445)
    nonisolated static let ams = (lat: 52.3086, lon: 4.76389)

    @discardableResult
    nonisolated static func makeStay(
        _ ctx: ModelContext,
        lat: Double, lon: Double,
        start: Date, end: Date,
        transit: TransitMode?,
        km: Double?,
        retainedObservations: Bool = false
    ) -> Stay {
        // Measured endpoint bounds keep these geometry revalidation fixtures
        // independent of the fallback for live stays without retained fixes.
        let pings: [LocationPing] = retainedObservations ? [start, end].map { timestamp in
            let ping = LocationPing(
                timestamp: timestamp, latitude: lat, longitude: lon,
                horizontalAccuracy: 5, h3IndexRes6: "", source: .liveSLC)
            ping.isProcessed = true
            ctx.insert(ping)
            return ping
        } : []
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: "", pingCount: pings.isEmpty ? 1 : pings.count,
            distanceFromHomeKm: 0, pingIDs: pings.map(\.id)
        )
        stay.transitFromPreviousRaw = transit?.rawValue
        stay.distanceFromPreviousKm = km
        ctx.insert(stay)
        return stay
    }

    nonisolated static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
            .addingTimeInterval(-27_820_800)
    }

    /// Mutates committed rows through an independent context, like the
    /// photo import and Visit writers do.
    nonisolated static func edit(
        _ container: ModelContainer,
        _ body: (ModelContext, [Stay]) -> Void
    ) {
        let other = ModelContext(container)
        do {
            let rows = try other.fetch(FetchDescriptor<Stay>())
            body(other, rows)
            try other.save()
        } catch {
            Issue.record(error)
        }
    }

    nonisolated static let predecessorEnd = utc(2025, 6, 1, 12)
    nonisolated static let targetStart = utc(2025, 6, 1, 12).addingTimeInterval(4.6 * 3600)

    /// ATH -> AMS with a 4.6 h gap passes the geometry rule. The stored
    /// 9,999 km is garbage the upgrade replaces.
    private func athAmsLeg(_ container: ModelContainer) throws -> (predecessor: UUID, target: UUID) {
        let ctx = ModelContext(container)
        let predecessor = Self.makeStay(
            ctx, lat: Self.ath.lat, lon: Self.ath.lon,
            start: Self.utc(2025, 6, 1, 10), end: Self.predecessorEnd,
            transit: .unknown, km: nil, retainedObservations: true)
        let target = Self.makeStay(
            ctx, lat: Self.ams.lat, lon: Self.ams.lon,
            start: Self.targetStart, end: Self.utc(2025, 6, 1, 22),
            transit: .unknown, km: 9999, retainedObservations: true)
        try ctx.save()
        return (predecessor.id, target.id)
    }

    private func stored(_ container: ModelContainer, _ id: UUID) throws -> [Stay] {
        try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id }))
    }

    private func runGeometry(
        _ container: ModelContainer,
        beforeApply: @escaping @Sendable () async -> Void
    ) async -> TransitInferer.UnknownLegPassOutcome {
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let visitedApply = OSAllocatedUnfairLock(initialState: false)
        let outcome = await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await TransitInferer.TestScope.$beforeApply.withValue({
                visitedApply.withLock { $0 = true }
                await beforeApply()
            }) {
                await inferer.reinferUnknownLegsGeometry(gate: gate)
            }
        }
        #expect(visitedApply.withLock { $0 }, "The qualifying fixture must reach its revalidation hook")
        return outcome
    }

    private func expectUntouched(_ container: ModelContainer, _ id: UUID) throws {
        let row = try #require(try stored(container, id).first)
        #expect(row.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(row.distanceFromPreviousKm == 9999)
    }

    // MARK: - Geometry re-pass

    @Test("control: an unchanged leg still upgrades through the hooked apply and stores its distance")
    func unchangedLegUpgrades() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)

        let outcome = await runGeometry(container) {}

        #expect(outcome.upgraded == 1 && !outcome.failed && outcome.complete)
        let row = try #require(try stored(container, leg.target).first)
        #expect(row.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect((2_000...2_300).contains(try #require(row.distanceFromPreviousKm)))
    }

    @Test("a nearer predecessor clustered into the gap before the apply blocks the upgrade")
    func insertedPredecessorBlocksUpgrade() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)

        let outcome = await runGeometry(container) {
            Self.edit(container) { ctx, _ in
                _ = Self.makeStay(ctx, lat: 52.30, lon: 4.77,
                                  start: Self.targetStart.addingTimeInterval(-7200),
                                  end: Self.targetStart.addingTimeInterval(-1800),
                                  transit: nil, km: nil)
            }
        }

        #expect(outcome.upgraded == 0 && !outcome.failed && outcome.complete)
        try expectUntouched(container, leg.target)
    }

    @Test("predecessor centroid drift saved by another context blocks the upgrade")
    func predecessorDriftBlocksUpgrade() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        let predecessorID = leg.predecessor

        let outcome = await runGeometry(container) {
            Self.edit(container) { _, rows in
                for row in rows where row.id == predecessorID {
                    row.centroidLatitude = 52.0
                    row.centroidLongitude = 5.0
                }
            }
        }

        #expect(outcome.upgraded == 0)
        try expectUntouched(container, leg.target)
    }

    @Test("coordinate-only Visit reconciliation on the target blocks the upgrade")
    func targetCoordinateDriftBlocksUpgrade() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        let targetID = leg.target

        let outcome = await runGeometry(container) {
            Self.edit(container) { _, rows in
                for row in rows where row.id == targetID {
                    row.centroidLatitude += 0.001
                }
            }
        }

        #expect(outcome.upgraded == 0)
        try expectUntouched(container, leg.target)
    }

    @Test("a sub-minute interval edit (below the Visit invalidation threshold) blocks the upgrade")
    func subMinuteStartShiftBlocksUpgrade() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        let targetID = leg.target

        let outcome = await runGeometry(container) {
            Self.edit(container) { _, rows in
                for row in rows where row.id == targetID {
                    row.startTime = row.startTime.addingTimeInterval(-30)
                }
            }
        }

        #expect(outcome.upgraded == 0)
        try expectUntouched(container, leg.target)
    }

    @Test("a replaced predecessor row with identical scalars is a different dependency")
    func replacedPredecessorBlocksUpgrade() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        let predecessorID = leg.predecessor

        let outcome = await runGeometry(container) {
            Self.edit(container) { ctx, rows in
                for row in rows where row.id == predecessorID { ctx.delete(row) }
                _ = Self.makeStay(ctx, lat: Self.ath.lat, lon: Self.ath.lon,
                                  start: Self.utc(2025, 6, 1, 10), end: Self.predecessorEnd,
                                  transit: .unknown, km: nil, retainedObservations: true)
            }
        }

        #expect(outcome.upgraded == 0)
        try expectUntouched(container, leg.target)
    }

    // MARK: - UUID twins

    /// Twin B shares the target's UUID but sits ten days later with no
    /// predecessor inside the seven-day lookback, so it is never a candidate.
    private func addTwin(_ container: ModelContainer, of target: UUID) throws {
        let ctx = ModelContext(container)
        let twin = Self.makeStay(ctx, lat: 35.0, lon: -40.0,
                                 start: Self.utc(2025, 6, 11, 12), end: Self.utc(2025, 6, 11, 18),
                                 transit: .unknown, km: 9999)
        twin.id = target
        try ctx.save()
    }

    @Test("the evaluated physical row is the one upgraded, never its UUID twin")
    func evaluatedTwinIsUpgraded() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        try addTwin(container, of: leg.target)

        let outcome = await runGeometry(container) {}

        #expect(outcome.upgraded == 1)
        let rows = try stored(container, leg.target)
        #expect(rows.count == 2)
        let evaluated = try #require(rows.first { $0.startTime == Self.targetStart })
        let twin = try #require(rows.first { $0.startTime != Self.targetStart })
        #expect(evaluated.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect(twin.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(twin.distanceFromPreviousKm == 9999)
    }

    @Test("deleting the evaluated row before the apply does not upgrade its surviving twin")
    func deletedTargetDoesNotFallBackToTwin() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try athAmsLeg(container)
        try addTwin(container, of: leg.target)
        let targetStart = Self.targetStart

        let outcome = await runGeometry(container) {
            Self.edit(container) { ctx, rows in
                for row in rows where row.startTime == targetStart { ctx.delete(row) }
            }
        }

        #expect(outcome.upgraded == 0)
        let rows = try stored(container, leg.target)
        #expect(rows.count == 1)
        #expect(rows.first?.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(rows.first?.distanceFromPreviousKm == 9999)
    }

    @Test("UUID twins co-timed at a batch boundary are each scanned")
    func twinsAtBoundaryAreEachScanned() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let shared = UUID()
        let start = Self.utc(2025, 6, 1, 12)
        for _ in 0..<3 {
            let row = Self.makeStay(ctx, lat: 37.9838, lon: 23.7275,
                                    start: start, end: start.addingTimeInterval(1800),
                                    transit: .unknown, km: nil)
            row.id = shared
        }
        try ctx.save()

        let inferer = TransitInferer(modelContainer: container)
        let result = await inferer.reinferUnknownLegsGeometryBatch(
            from: .start, batchSize: 2, gate: PipelineGate(forTesting: ()))

        // All three physical rows, not two: tie dedup is by physical identity.
        #expect(result.scanned == 3)
        #expect(!result.failed)
    }

    // MARK: - Bounded apply

    @Test("a large qualifying cohort applies in bounded gate units without skips or double counts",
          .timeLimit(.minutes(1)))
    func largeCohortAppliesInSlices() async throws {
        try #require(AirportDetector.shared.airportCount > 0, "bundled airports.json failed to load")
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Self.makeStay(ctx, lat: Self.ath.lat, lon: Self.ath.lon,
                      start: Self.utc(2025, 6, 1, 10), end: Self.predecessorEnd,
                      transit: .unknown, km: nil, retainedObservations: true)
        let count = TransitInferer.applySliceSize + 10
        for _ in 0..<count {
            Self.makeStay(ctx, lat: Self.ams.lat, lon: Self.ams.lon,
                          start: Self.targetStart, end: Self.utc(2025, 6, 1, 22),
                          transit: .unknown, km: 9999, retainedObservations: true)
        }
        try ctx.save()
        let units = OSAllocatedUnfairLock(initialState: 0)

        let outcome = await runGeometry(container) {
            units.withLock { $0 += 1 }
        }

        #expect(units.withLock { $0 } == 2)
        #expect(outcome.upgraded == count && outcome.complete)
        let flightRaw = TransitMode.flight.rawValue
        let flights = try ModelContext(container).fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.transitFromPreviousRaw == flightRaw }))
        #expect(flights == count)
    }

    // MARK: - Calendar re-pass

    /// A 150 km mid-ocean leg: below the geometry floor, above the
    /// corroborated floor. The stored 42 km is stale.
    private func calendarLeg(_ container: ModelContainer) throws -> (predecessor: UUID, target: UUID) {
        let ctx = ModelContext(container)
        let predecessor = Self.makeStay(ctx, lat: 30.0, lon: -40.0,
                                        start: Self.utc(2025, 6, 1, 8), end: Self.utc(2025, 6, 1, 10),
                                        transit: .unknown, km: nil)
        let target = Self.makeStay(ctx, lat: 31.35, lon: -40.0,
                                   start: Self.utc(2025, 6, 1, 12), end: Self.utc(2025, 6, 1, 18),
                                   transit: .unknown, km: 42)
        try ctx.save()
        return (predecessor.id, target.id)
    }

    private func runCalendar(
        _ container: ModelContainer,
        beforeApply: @escaping @Sendable () async -> Void
    ) async -> TransitInferer.UnknownLegPassOutcome {
        let inferer = TransitInferer(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        return await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await TransitInferer.TestScope.$corroborates.withValue({ _, _ in true }) {
                await TransitInferer.TestScope.$beforeApply.withValue(beforeApply) {
                    await inferer.recorroborateUnknownLegs(gate: gate)
                }
            }
        }
    }

    @Test("a calendar upgrade stores the current leg distance, replacing the stale one")
    func calendarUpgradeStoresCurrentDistance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try calendarLeg(container)

        let outcome = await runCalendar(container) {}

        #expect(outcome.upgraded == 1 && !outcome.failed && outcome.complete)
        let row = try #require(try stored(container, leg.target).first)
        #expect(row.transitFromPreviousRaw == TransitMode.flight.rawValue)
        #expect((140...160).contains(try #require(row.distanceFromPreviousKm)))
    }

    @Test("a moved gap after corroboration blocks the calendar upgrade")
    func calendarGapShiftBlocksUpgrade() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let leg = try calendarLeg(container)
        let predecessorID = leg.predecessor

        let outcome = await runCalendar(container) {
            Self.edit(container) { _, rows in
                for row in rows where row.id == predecessorID {
                    row.endTime = row.endTime.addingTimeInterval(600)
                }
            }
        }

        #expect(outcome.upgraded == 0 && !outcome.failed)
        let row = try #require(try stored(container, leg.target).first)
        #expect(row.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        #expect(row.distanceFromPreviousKm == 42)
    }
}
