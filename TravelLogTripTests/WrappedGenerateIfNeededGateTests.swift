//
//  WrappedGenerateIfNeededGateTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator subsystem: the short-circuit branches of
//  `generateIfNeeded(forYear:)`: (1) an existing YearWrapped row returns
//  `.existing` immediately and never inserts a duplicate, and (2) the minimum-data gate
//  (`meetsMinimumDataThreshold` = early-stay-before-Oct-1 AND
//  completedTrips >= 3, AND-ed) returns `.insufficientData` without creating a
//  row. Generation itself is deterministic (no Foundation Models); the success
//  and failure paths are pinned in `WrappedGenerationFailureTests`.
//  @MainActor + async: instantiates the `@ModelActor`, awaits its method, and
//  builds `@Model` fixtures. Fixtures are inserted + saved via a separate
//  ModelContext(container); the actor's private context reads the same shared
//  in-memory store.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedGenerateIfNeededGateTests {

    /// UTC builder; the threshold predicates use a UTC gregorian frame.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeStay(_ ctx: ModelContext, start: Date) -> Stay {
        let s = Stay(startTime: start, endTime: start.addingTimeInterval(3600),
                     centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        ctx.insert(s)
        return s
    }

    private func makeCompletedTrip(_ ctx: ModelContext, start: Date) -> Trip {
        let t = Trip(startDate: start)
        t.endDate = start.addingTimeInterval(86_400)
        t.isComplete = true
        ctx.insert(t)
        return t
    }

    private func save(_ ctx: ModelContext) throws {
        try ctx.save()
    }

    private func wrappedCount(_ ctx: ModelContext, year: Int) throws -> Int {
        let y = year
        let predicate = #Predicate<YearWrapped> { $0.year == y }
        return try ctx.fetch(FetchDescriptor<YearWrapped>(predicate: predicate)).count
    }

    // MARK: - Existing-row short-circuit

    @Test("returns .existing immediately when a Wrapped already exists for the year")
    func returnsTrueWhenWrappedAlreadyExists() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(YearWrapped(year: 2026))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        let result = await gen.generateIfNeeded(forYear: 2026)
        #expect(result == .existing)
    }

    @Test("does not create a duplicate when a Wrapped already exists")
    func doesNotCreateDuplicateWhenWrappedExists() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(YearWrapped(year: 2026))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        _ = await gen.generateIfNeeded(forYear: 2026)

        #expect(try wrappedCount(ctx, year: 2026) == 1)
    }

    // MARK: - Minimum-data gate

    @Test("returns .insufficientData on an empty container and creates no row")
    func returnsFalseWhenNoData() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let gen = YearWrappedGenerator(modelContainer: container)
        let result = await gen.generateIfNeeded(forYear: 2026)
        #expect(result == .insufficientData)
        #expect(try wrappedCount(ctx, year: 2026) == 0)
    }

    @Test("returns .insufficientData with an early stay but fewer than three completed trips (minimumTrips boundary)")
    func returnsFalseWithStaysButFewerThanThreeCompletedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Early stay (before Oct 1) satisfies hasEarlyData.
        _ = makeStay(ctx, start: utc(2026, 3, 1))
        // Only 2 completed trips → tripCount 2 < 3 → AND fails.
        _ = makeCompletedTrip(ctx, start: utc(2026, 4, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 5, 1))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        let result = await gen.generateIfNeeded(forYear: 2026)
        #expect(result == .insufficientData)
        #expect(try wrappedCount(ctx, year: 2026) == 0)
    }

    @Test("later years' trips do not satisfy a prior year's minimum-trips gate")
    func laterYearTripsDoNotSatisfyPriorYearGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 2025 has the early stay but ZERO trips of its own; 2026 has three.
        // Both the early-stay and completed-trip predicates must be limited
        // to the requested year when generating a prior year's recap.
        _ = makeStay(ctx, start: utc(2025, 3, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 3, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 4, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 5, 1))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        #expect(try await gen.meetsMinimumDataThreshold(forYear: 2025) == false)
    }

    @Test("the year's own three completed trips still satisfy the gate (upper bound is exclusive, not over-tight)")
    func sameYearTripsStillSatisfyGate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = makeStay(ctx, start: utc(2025, 3, 1))
        _ = makeCompletedTrip(ctx, start: utc(2025, 4, 1))
        _ = makeCompletedTrip(ctx, start: utc(2025, 5, 1))
        _ = makeCompletedTrip(ctx, start: utc(2025, 12, 30))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        #expect(try await gen.meetsMinimumDataThreshold(forYear: 2025) == true)
    }

    @Test("returns .insufficientData when 3 completed trips exist but no stay before the Oct-1 cutoff")
    func returnsFalseWhenTripsPresentButNoEarlyStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 3 completed trips → tripCount side of the AND passes.
        _ = makeCompletedTrip(ctx, start: utc(2026, 3, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 4, 1))
        _ = makeCompletedTrip(ctx, start: utc(2026, 5, 1))
        // Single stay on/after the Oct-1 cutoff → hasEarlyData side fails.
        _ = makeStay(ctx, start: utc(2026, 11, 1))
        try save(ctx)

        let gen = YearWrappedGenerator(modelContainer: container)
        let result = await gen.generateIfNeeded(forYear: 2026)
        #expect(result == .insufficientData)
        #expect(try wrappedCount(ctx, year: 2026) == 0)
    }
}
