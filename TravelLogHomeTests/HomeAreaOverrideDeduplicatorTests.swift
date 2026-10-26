//
//  HomeAreaOverrideDeduplicatorTests.swift
//  TravelLogTests
//
//  The seventh deduplicator: convergence
//  for user home-area corrections synced from two devices. Pins the identity
//  key (immutable fields only, ~11 m coordinate rounding), the deterministic
//  survivor rule (oldest createdAt, id.uuidString tiebreak), and the groups
//  that must NEVER merge (different kind / home / spot).
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct HomeAreaOverrideDeduplicatorTests {

    private func makeOverride(
        in ctx: ModelContext,
        kind: HomeAreaOverride.Kind = .include,
        lat: Double = 47.391, lon: Double = 8.045,
        homeID: UUID? = nil,
        createdAt: Date
    ) -> HomeAreaOverride {
        let row = HomeAreaOverride(kind: kind, centerLatitude: lat,
                                   centerLongitude: lon, radiusKm: 1,
                                   homeID: homeID)
        row.createdAt = createdAt
        ctx.insert(row)
        return row
    }

    @Test("duplicate rows collapse to the oldest; ties break on id.uuidString")
    func oldestSurvivorDeterministic() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let older = makeOverride(in: ctx, homeID: home, createdAt: t0)
        _ = makeOverride(in: ctx, homeID: home, createdAt: t0.addingTimeInterval(60))
        // Same instant as `older` — the uuidString tiebreak decides, so run
        // the expectation off the same rule the deduplicator uses.
        let peer = makeOverride(in: ctx, homeID: home, createdAt: t0)
        try ctx.save()

        let expectedSurvivor = [older, peer]
            .sorted { $0.id.uuidString < $1.id.uuidString }.first!.id

        await HomeAreaOverrideDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try ctx.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == expectedSurvivor)
    }

    @Test("identical (id, createdAt) twins are NEVER deleted — no strict survivor order exists")
    func identicalTwinsSurvive() async throws {
        // Two devices importing the same v6 backup mint rows with the SAME
        // id and the SAME createdAt. The sort key is then fully degenerate,
        // and the fetch order differs per device — each deleting "the
        // other" destroyed the correction on BOTH after sync. Identical twins are harmless: same geometry, same
        // membership.
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = UUID()
        let sharedID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeOverride(in: ctx, homeID: home, createdAt: t0)
        a.id = sharedID
        let b = makeOverride(in: ctx, homeID: home, createdAt: t0)
        b.id = sharedID
        try ctx.save()

        await HomeAreaOverrideDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 2,
                "convergence safety beats tidiness")

        // A distinguishable third row still collapses into the group.
        _ = makeOverride(in: ctx, homeID: home, createdAt: t0.addingTimeInterval(60))
        try ctx.save()
        await HomeAreaOverrideDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 2,
                "the strictly-newer row is a real duplicate and dies; the twins stay")
    }

    @Test("coordinate noise below ~11 m folds into one row; a different spot does not")
    func roundingTolerance() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = makeOverride(in: ctx, lat: 47.39100, homeID: home, createdAt: t0)
        _ = makeOverride(in: ctx, lat: 47.39102, homeID: home,          // same 1e-4 cell
                         createdAt: t0.addingTimeInterval(1))
        _ = makeOverride(in: ctx, lat: 47.40100, homeID: home,          // ~1.1 km away
                         createdAt: t0.addingTimeInterval(2))
        try ctx.save()

        await HomeAreaOverrideDeduplicator.deduplicateAll(modelContainer: container)
        let remaining = try ctx.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(remaining.count == 2)
    }

    @Test("different kind or different home never merge")
    func kindAndHomeSeparateGroups() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let homeA = UUID(), homeB = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = makeOverride(in: ctx, kind: .include, homeID: homeA, createdAt: t0)
        _ = makeOverride(in: ctx, kind: .exclude, homeID: homeA, createdAt: t0)
        _ = makeOverride(in: ctx, kind: .include, homeID: homeB, createdAt: t0)
        _ = makeOverride(in: ctx, kind: .include, homeID: nil, createdAt: t0)
        try ctx.save()

        await HomeAreaOverrideDeduplicator.deduplicateAll(modelContainer: container)
        let remaining = try ctx.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(remaining.count == 4)
    }

    @Test("unknown future kindRaw reads as nil kind, never crashes or misapplies")
    func forwardCompatibleKind() throws {
        let row = HomeAreaOverride(kind: .include, centerLatitude: 0,
                                   centerLongitude: 0, radiusKm: 1, homeID: nil)
        row.kindRaw = "quarantine"   // a future version's value
        #expect(row.kind == nil)
    }
}
