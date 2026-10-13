//
//  TransitInfererCursorTests.swift
//  TravelLogTests
//
//  Both `.unknown`-leg re-passes used to
//  materialize every `.unknown` Stay, essentially the whole table, since
//  `.unknown` is the terminal value for every non-flight leg, and then pay
//  one extra fetch per admitted row.
//
//  A plain `fetchLimit` cannot fix it: the passes RETURN upgrades, not rows
//  scanned, so a caller loop that stops when a batch upgrades nothing would
//  silently truncate the scan. `fetchOffset` is wrong too; rows leave the
//  `.unknown` predicate as they upgrade, sliding later offsets backwards.
//  Hence a keyset cursor on `startTime` with a tie set, pinned here.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TransitInfererCursorTests {

    private let base = Date(timeIntervalSince1970: 1_730_844_800)

    /// Two points ~10 km apart, far below the flight floor, so these legs are
    /// scanned but never upgraded. That is deliberate: it isolates the cursor's
    /// advance from any upgrade side effect.
    private let athens = (lat: 37.9838, lon: 23.7275)

    @discardableResult
    private func makeUnknownLeg(
        in ctx: ModelContext,
        offsetHours: Double,
        lat: Double? = nil
    ) -> Stay {
        let start = base.addingTimeInterval(offsetHours * 3600)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(1800),
            centroidLatitude: lat ?? athens.lat,
            centroidLongitude: athens.lon,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 5,
            pingIDs: []
        )
        stay.category = .destination
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        ctx.insert(stay)
        return stay
    }

    /// Every leg is visited exactly once across the drain, and the run ends
    /// only when a batch comes back short.
    @Test("batching covers every leg exactly once and terminates on a short batch")
    func cursorCoversEveryLegOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for hour in 0..<5 { makeUnknownLeg(in: ctx, offsetHours: Double(hour)) }
        try ctx.save()

        let sut = TransitInferer(modelContainer: container)
        var cursor: TransitInferer.UnknownLegCursor? = .start
        var totalScanned = 0
        var batches = 0

        while let current = cursor, batches < 20 {
            batches += 1
            let result = await sut.reinferUnknownLegsGeometryBatch(from: current, batchSize: 2)
            totalScanned += result.scanned
            cursor = result.next
        }

        #expect(totalScanned == 5)
        #expect(batches == 3)   // 2 + 2 + 1(short) → terminates
    }

    /// THE defect a naive `fetchLimit` loop has: none of these legs upgrade
    /// (they are 10 km apart, far below the flight floor), yet the scan must
    /// keep going. `next` is the completion signal, never `upgraded`.
    @Test("a batch that upgrades nothing still returns a next cursor")
    func zeroUpgradesStillAdvances() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for hour in 0..<4 { makeUnknownLeg(in: ctx, offsetHours: Double(hour)) }
        try ctx.save()

        let sut = TransitInferer(modelContainer: container)
        let result = await sut.reinferUnknownLegsGeometryBatch(from: .start, batchSize: 2)

        #expect(result.upgraded == 0)
        #expect(result.scanned == 2)
        #expect(result.next != nil)
    }

    /// `Stay.startTime` is not unique: JSON/GPX/Timeline imports mint
    /// co-timed stays, and SwiftData cannot sort on `id`. An exclusive `>`
    /// bound would skip the siblings; the tie set is what prevents that.
    /// More co-timed stays than fit in one batch. The batch must EXHAUST the
    /// instant (scanning all 3) rather than either spinning on it or stepping
    /// past and dropping the siblings the limit cut off.
    @Test("a boundary wider than the batch is exhausted, not skipped")
    func saturatedBoundaryIsExhausted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for _ in 0..<3 { makeUnknownLeg(in: ctx, offsetHours: 0) }
        makeUnknownLeg(in: ctx, offsetHours: 5)
        try ctx.save()

        let sut = TransitInferer(modelContainer: container)
        // batchSize 2 with 3 co-timed rows: the second batch's fresh set is
        // empty, which is exactly the saturating case.
        var cursor: TransitInferer.UnknownLegCursor? = .start
        var batches = 0
        var totalScanned = 0
        while let current = cursor, batches < 20 {
            batches += 1
            let result = await sut.reinferUnknownLegsGeometryBatch(from: current, batchSize: 2)
            totalScanned += result.scanned
            cursor = result.next
        }
        #expect(batches < 20)      // terminated rather than spinning
        #expect(totalScanned == 4) // all 3 co-timed rows + the later one
    }

    /// The drain wrapper reports total upgrades together with whether the
    /// pass failed or reached the end of the backlog.
    @Test("the drain wrapper still returns total upgrades and terminates")
    func drainWrapperTerminates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for hour in 0..<3 { makeUnknownLeg(in: ctx, offsetHours: Double(hour)) }
        try ctx.save()

        let sut = TransitInferer(modelContainer: container)
        let outcome = await sut.reinferUnknownLegsGeometry()
        #expect(!outcome.failed)
        #expect(outcome.complete)   // terminated by exhausting the backlog
        #expect(outcome.upgraded == 0)   // all legs are 0 km apart, far below the floor
    }
}
