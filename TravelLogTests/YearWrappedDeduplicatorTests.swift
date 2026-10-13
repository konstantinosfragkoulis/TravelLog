//
//  YearWrappedDeduplicatorTests.swift
//  TravelLogTests
//
//  CloudKit-convergence deduplicator for YearWrapped.
//  Pins the per-year survivor rule (keep the LARGEST
//  immutable id.uuidString and absorb newest content onto it), the
//  earliest-viewedAt preservation onto the survivor (so a regenerated recap
//  isn't re-flagged "New"), per-year independence, and order-independence +
//  run-twice idempotence. Live multi-device sync is out of scope.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (YearWrapped) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct YearWrappedDeduplicatorTests {

    // MARK: - Fixtures

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Build a YearWrapped. The init only takes `year` (sets generatedAt=.now);
    /// override generatedAt/viewedAt by assignment so the test controls the key.
    private func makeWrapped(year: Int, generatedAt: Date, viewedAt: Date? = nil) -> YearWrapped {
        let w = YearWrapped(year: year)
        w.generatedAt = generatedAt
        w.viewedAt = viewedAt
        return w
    }

    private func fetchAll(_ container: ModelContainer) throws -> [YearWrapped] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<YearWrapped>())
    }

    // MARK: - No-op / guard paths

    @Test("empty store → no-op, store stays empty (count>1 guard)")
    func emptyStoreIsNoOp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try fetchAll(container).isEmpty)
    }

    @Test("single row for a year survives unchanged (count>1 guard)")
    func singleRowSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let w = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31), viewedAt: utc(2027, 1, 2))
        ctx.insert(w)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.year == 2026)
        #expect(survivor.viewedAt == utc(2027, 1, 2))
    }

    @Test("three distinct years all kept (one entry per year, toDelete empty)")
    func distinctYearsAllKept() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeWrapped(year: 2024, generatedAt: utc(2024, 12, 31)))
        ctx.insert(makeWrapped(year: 2025, generatedAt: utc(2025, 12, 31)))
        ctx.insert(makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31)))
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try fetchAll(container).count == 3)
    }

    // MARK: - Survivor selection

    /// Row survival uses the immutable `id` so devices agree on the survivor.
    /// A mutable `generatedAt` could make devices delete each other's row.
    /// The surviving row absorbs the newest content regardless of its own age.
    @Test("duplicate year → the surviving row carries the NEWEST content (keep-newest)")
    func duplicateYearKeepsNewestGeneratedAt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31))
        let new = makeWrapped(year: 2026, generatedAt: utc(2027, 3, 1))
        // Force the older row to survive, so fresh content must be copied.
        old.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        new.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        old.yearNarrative = "stale"
        new.yearNarrative = "fresh"
        ctx.insert(old)
        ctx.insert(new)
        let expectedID = old.id
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.year == 2026 }
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.id == expectedID)
        #expect(survivor.generatedAt == utc(2027, 3, 1))
        #expect(survivor.yearNarrative == "fresh")
    }

    /// Legacy blob (no `weatherExtremesSafe`): the weather card is gated on
    /// the row's `weatherCoverage`.
    private func legacyWeatherStats() -> WrappedStats {
        var stats = WrappedStats()
        stats.countriesVisited = 5
        stats.hottestTempC = 34
        stats.hottestLocality = "Seville"
        return stats
    }

    @Test("absorbed legacy content brings its own coverage gate",
          arguments: zip([0.95, 0.3], [0.3, 0.95]))
    func absorbedContentCarriesCoverage(survivorCoverage: Double, donorCoverage: Double) async throws {
        // Legacy gate: coverage >= 0.7 shows the weather card.
        let donorShowsWeather = donorCoverage >= 0.7
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31), viewedAt: utc(2027, 1, 5))
        old.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        old.statsData = WrappedStats().encoded()
        old.yearNarrative = "stale"
        old.yearNarrativeSourceRaw = SummarySource.foundationModels.rawValue
        old.weatherCoverage = survivorCoverage
        old.transitCoverage = 0.9
        let new = makeWrapped(year: 2026, generatedAt: utc(2027, 3, 1))
        new.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        new.statsData = legacyWeatherStats().encoded()
        new.yearNarrative = "fresh"
        new.yearNarrativeSourceRaw = SummarySource.deterministic.rawValue
        new.weatherCoverage = donorCoverage
        new.transitCoverage = 0.2
        ctx.insert(old)
        ctx.insert(new)
        try ctx.save()
        let survivorPID = old.persistentModelID
        let donorStats = try #require(new.statsData)

        #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))

        var rows = try fetchAll(container)
        #expect(rows.count == 1)
        var survivor = try #require(rows.first)
        #expect(survivor.persistentModelID == survivorPID)
        #expect(survivor.id.uuidString == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(survivor.statsData == donorStats)
        #expect(survivor.yearNarrative == "fresh")
        #expect(survivor.yearNarrativeSourceRaw == SummarySource.deterministic.rawValue)
        #expect(survivor.weatherCoverage == donorCoverage)
        #expect(survivor.transitCoverage == 0.2)
        #expect(survivor.generatedAt == utc(2027, 3, 1))
        #expect(survivor.viewedAt == utc(2027, 1, 5))

        var decoded = try #require(survivor.statsData.flatMap(WrappedStats.decoded(from:)))
        let cards = WrappedView.visibleCards(stats: decoded, weatherCoverage: survivor.weatherCoverage)
        #expect(cards.contains(.weather) == donorShowsWeather)
        #expect(cards.contains(.topDestinations) == !donorShowsWeather)
        // An explicit verdict still overrides coverage on current blobs.
        decoded.weatherExtremesSafe = false
        #expect(!WrappedView.visibleCards(stats: decoded, weatherCoverage: 0.95).contains(.weather))

        // A second pass is a no-op.
        #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))
        rows = try fetchAll(container)
        #expect(rows.count == 1)
        survivor = try #require(rows.first)
        #expect(survivor.persistentModelID == survivorPID)
        #expect(survivor.weatherCoverage == donorCoverage)
        #expect(survivor.transitCoverage == 0.2)
        #expect(survivor.statsData == donorStats)
    }

    @Test("a survivor that is already the newest keeps its own content and coverage")
    func newestSurvivorKeepsOwnCoverage() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let survivor = makeWrapped(year: 2026, generatedAt: utc(2027, 3, 1))
        survivor.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        survivor.statsData = legacyWeatherStats().encoded()
        survivor.yearNarrative = "fresh"
        survivor.weatherCoverage = 0.3
        survivor.transitCoverage = 0.2
        let donor = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31))
        donor.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        donor.statsData = WrappedStats().encoded()
        donor.yearNarrative = "stale"
        donor.weatherCoverage = 0.95
        donor.transitCoverage = 0.9
        ctx.insert(survivor)
        ctx.insert(donor)
        try ctx.save()
        let ownStats = try #require(survivor.statsData)

        #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try fetchAll(container)
        #expect(rows.count == 1)
        let kept = try #require(rows.first)
        #expect(kept.id.uuidString == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(kept.statsData == ownStats)
        #expect(kept.yearNarrative == "fresh")
        #expect(kept.weatherCoverage == 0.3)
        #expect(kept.transitCoverage == 0.2)
        #expect(kept.generatedAt == utc(2027, 3, 1))
    }

    /// UUID twins of the winning id name no single row: opposite fetch orders
    /// would let two devices delete each other's twin, and the twin carrying
    /// newer content went without absorption.
    @Test("twins sharing the winning id keep every row of their year")
    func ambiguousSurvivorTwinsAreRetained() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let winningID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let older = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31))
        older.id = winningID
        older.yearNarrative = "stale"
        let newer = makeWrapped(year: 2026, generatedAt: utc(2027, 3, 1))
        newer.id = winningID
        newer.yearNarrative = "fresh"
        let loser = makeWrapped(year: 2026, generatedAt: utc(2027, 1, 1))
        loser.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ctx.insert(older)
        ctx.insert(newer)
        ctx.insert(loser)
        try ctx.save()

        #expect(await YearWrappedDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try fetchAll(container)
        #expect(rows.count == 3)
        #expect(Set(rows.filter { $0.id == winningID }.compactMap(\.yearNarrative)) == ["stale", "fresh"])
    }

    // MARK: - viewedAt preservation

    @Test("survivor (newer recap, viewedAt nil) inherits the loser's earlier viewedAt")
    func earliestViewedAtPreservedOntoSurvivor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Loser is older + already viewed; survivor is newer (regenerated) + nil.
        let loser = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31), viewedAt: utc(2027, 1, 5))
        let survivor = makeWrapped(year: 2026, generatedAt: utc(2027, 6, 1), viewedAt: nil)
        // The larger id survives, so the viewed row is the one that must be absorbed.
        loser.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        survivor.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        ctx.insert(loser)
        ctx.insert(survivor)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.year == 2026 }
        #expect(rows.count == 1)
        let s = try #require(rows.first)
        #expect(s.id.uuidString == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(s.viewedAt == utc(2027, 1, 5))
    }

    @Test("both viewed → survivor's viewedAt becomes the EARLIER of the two")
    func minViewedAtWinsWhenBothViewed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Survivor is the newer recap with a LATER viewedAt; loser viewed earlier.
        let loser = makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31), viewedAt: utc(2027, 1, 2))
        let survivor = makeWrapped(year: 2026, generatedAt: utc(2027, 6, 1), viewedAt: utc(2027, 7, 1))
        loser.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        survivor.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        ctx.insert(loser)
        ctx.insert(survivor)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try fetchAll(container).filter { $0.year == 2026 }
        #expect(rows.count == 1)
        let s = try #require(rows.first)
        #expect(s.id.uuidString == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(s.viewedAt == utc(2027, 1, 2))
    }

    // MARK: - Multi-year + idempotence + order independence

    @Test("two years, each with a duplicate pair → collapse to exactly 2 rows (one survivor per year)")
    func perYearIndependentSurvivors() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let new2025 = makeWrapped(year: 2025, generatedAt: utc(2026, 3, 1))
        ctx.insert(makeWrapped(year: 2025, generatedAt: utc(2025, 12, 31)))
        ctx.insert(new2025)
        let new2026 = makeWrapped(year: 2026, generatedAt: utc(2027, 3, 1))
        ctx.insert(makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31)))
        ctx.insert(new2026)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let all = try fetchAll(container)
        #expect(all.count == 2)
        let s2025 = try #require(all.first { $0.year == 2025 })
        let s2026 = try #require(all.first { $0.year == 2026 })
        // Each year collapses to exactly one row carrying that year's newest
        // content (row identity is the immutable id).
        #expect(s2025.generatedAt == utc(2026, 3, 1))
        #expect(s2026.generatedAt == utc(2027, 3, 1))
    }

    @Test("running deduplicateAll twice is stable; count + survivor id/viewedAt unchanged on 2nd pass")
    func idempotentRunningTwiceStable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeWrapped(year: 2026, generatedAt: utc(2026, 12, 31), viewedAt: utc(2027, 1, 5)))
        ctx.insert(makeWrapped(year: 2026, generatedAt: utc(2027, 6, 1), viewedAt: nil))
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)
        let after1 = try fetchAll(container).filter { $0.year == 2026 }
        #expect(after1.count == 1)
        let s1 = try #require(after1.first)
        let id1 = s1.id
        let viewed1 = s1.viewedAt

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)
        let after2 = try fetchAll(container).filter { $0.year == 2026 }
        #expect(after2.count == 1)
        let s2 = try #require(after2.first)
        #expect(s2.id == id1)
        #expect(s2.viewedAt == viewed1)
    }

    @Test("survivor id per year is independent of insertion order")
    func orderIndependentSurvivor() async throws {
        let oldGen = utc(2026, 12, 31)
        let newGen = utc(2027, 6, 1)

        // Store A: old inserted first.
        let containerA = try TestSupport.makeInMemoryContainer()
        let ctxA = ModelContext(containerA)
        let a1 = makeWrapped(year: 2026, generatedAt: oldGen)
        let a2 = makeWrapped(year: 2026, generatedAt: newGen)
        ctxA.insert(a1); ctxA.insert(a2)
        try ctxA.save()
        await YearWrappedDeduplicator.deduplicateAll(modelContainer: containerA)
        let sA = try #require(try fetchAll(containerA).first { $0.year == 2026 })

        // Store B: new inserted first (opposite order), same ids reused.
        let containerB = try TestSupport.makeInMemoryContainer()
        let ctxB = ModelContext(containerB)
        let b2 = makeWrapped(year: 2026, generatedAt: newGen)
        b2.id = a2.id
        let b1 = makeWrapped(year: 2026, generatedAt: oldGen)
        b1.id = a1.id
        ctxB.insert(b2); ctxB.insert(b1)
        try ctxB.save()
        await YearWrappedDeduplicator.deduplicateAll(modelContainer: containerB)
        let sB = try #require(try fetchAll(containerB).first { $0.year == 2026 })

        #expect(sA.id == sB.id)
    }
}
