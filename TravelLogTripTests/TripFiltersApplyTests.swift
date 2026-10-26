//
//  TripFiltersApplyTests.swift
//  TravelLogTests
//
//  TripFilters.apply(to:photoService:) — the filter stage that runs BEFORE
//  TripSorter.sort in the trips-list pipeline. Covers the isActive short-
//  circuit, per-dimension predicates (year via Calendar.current, country via
//  comma-split membership, duration via DurationBucket with the ongoing-trip
//  exclusion), multi-select OR within a dimension, cross-dimension AND, and
//  order preservation. apply is @MainActor and constructs @Model objects, so
//  this suite is @MainActor; apply is reached synchronously (no actor hop —
//  it IS MainActor). PhotoService.shared returns nil counts in tests, so only
//  the requiresPhotos uncached/keep branch is exercised (the count<=0 drop
//  branch is gated on private cache state — documented as not unit-testable).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripFiltersApplyTests {

    // MARK: - Date helper (apply uses Calendar.current; build at noon)

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    private func makeTrip(in ctx: ModelContext, start: Date) -> Trip {
        let trip = Trip(startDate: start)
        ctx.insert(trip)
        return trip
    }

    // MARK: - isActive short-circuit

    @Test("an inactive filter returns the input untouched")
    func inactiveFilterReturnsInputUntouched() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeTrip(in: ctx, start: day(2024, 1, 1))
        let b = makeTrip(in: ctx, start: day(2023, 1, 1))
        let c = makeTrip(in: ctx, start: day(2022, 1, 1))
        let trips = [a, b, c]

        let result = TripFilters().apply(to: trips, photoService: .shared)
        #expect(result.map(\.id) == trips.map(\.id))
    }

    // MARK: - Year

    @Test("year filter keeps only trips whose start year is in the set")
    func yearFilterKeepsOnlyMatchingStartYear() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let in2024 = makeTrip(in: ctx, start: day(2024, 6, 1))
        let in2023 = makeTrip(in: ctx, start: day(2023, 6, 1))

        var f = TripFilters(); f.years = [2024]
        let result = f.apply(to: [in2024, in2023], photoService: .shared)
        #expect(result.map(\.id) == [in2024.id])
    }

    @Test("year filter is OR within the dimension (2023 OR 2025)")
    func yearFilterIsOrWithinDimension() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let in2023 = makeTrip(in: ctx, start: day(2023, 6, 1))
        let in2024 = makeTrip(in: ctx, start: day(2024, 6, 1))
        let in2025 = makeTrip(in: ctx, start: day(2025, 6, 1))

        var f = TripFilters(); f.years = [2023, 2025]
        let result = f.apply(to: [in2023, in2024, in2025], photoService: .shared)
        #expect(Set(result.map(\.id)) == Set([in2023.id, in2025.id]))
    }

    // MARK: - Country

    @Test("country filter keeps a trip with any matching code")
    func countryFilterKeepsTripWithAnyMatchingCode() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let itGr = makeTrip(in: ctx, start: day(2024, 1, 1)); itGr.countryCodes = "IT,GR"
        let frIt = makeTrip(in: ctx, start: day(2024, 2, 1)); frIt.countryCodes = "FR,IT"

        var f = TripFilters(); f.countryCodes = ["GR"]
        let result = f.apply(to: [itGr, frIt], photoService: .shared)
        #expect(result.map(\.id) == [itGr.id])
    }

    @Test("a trip with empty countryCodes never matches a non-empty country filter")
    func countryFilterEmptyTripCodesNeverMatches() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let empty = makeTrip(in: ctx, start: day(2024, 1, 1)); empty.countryCodes = ""

        var f = TripFilters(); f.countryCodes = ["GR"]
        let result = f.apply(to: [empty], photoService: .shared)
        #expect(result.isEmpty)
    }

    // MARK: - Duration

    @Test("duration filter buckets completed trips by durationDays")
    func durationFilterBucketsCompletedTrips() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // durationDays is inclusive: endDate - startDate days + 1.
        // start Jun 1 → end Jun 2 == 2 days (weekend bucket).
        let weekend = makeTrip(in: ctx, start: day(2024, 6, 1))
        weekend.endDate = day(2024, 6, 2)
        #expect(weekend.durationDays == 2)
        // start Jun 1 → end Jun 7 == 7 days (week bucket).
        let week = makeTrip(in: ctx, start: day(2024, 6, 1))
        week.endDate = day(2024, 6, 7)
        #expect(week.durationDays == 7)

        var f = TripFilters(); f.durations = [.weekend]
        let result = f.apply(to: [weekend, week], photoService: .shared)
        #expect(result.map(\.id) == [weekend.id])
    }

    @Test("ongoing trips (nil durationDays) are excluded when any bucket is selected")
    func durationFilterExcludesOngoingTrips() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let ongoing = makeTrip(in: ctx, start: day(2024, 6, 1)) // endDate nil
        #expect(ongoing.durationDays == nil)

        var f = TripFilters(); f.durations = [.weekend, .week, .long]
        let result = f.apply(to: [ongoing], photoService: .shared)
        #expect(result.isEmpty)
    }

    // MARK: - requiresPhotos (uncached/keep branch only)

    @Test("requiresPhotos keeps uncached trips visible (cachedPhotoCount == nil)")
    func requiresPhotosKeepsUncachedTrips() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 6, 1))

        var f = TripFilters(); f.requiresPhotos = true
        // PhotoService.shared has no cached count for this fresh id → nil → kept.
        let result = f.apply(to: [trip], photoService: .shared)
        #expect(result.map(\.id) == [trip.id])
    }

    // MARK: - Cross-dimension AND + order

    @Test("filters combine with AND across categories")
    func combinedFiltersAreAndAcrossCategories() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let gr2024 = makeTrip(in: ctx, start: day(2024, 6, 1)); gr2024.countryCodes = "GR"
        let it2024 = makeTrip(in: ctx, start: day(2024, 6, 1)); it2024.countryCodes = "IT"
        let gr2023 = makeTrip(in: ctx, start: day(2023, 6, 1)); gr2023.countryCodes = "GR"

        var f = TripFilters(); f.years = [2024]; f.countryCodes = ["GR"]
        let result = f.apply(to: [gr2024, it2024, gr2023], photoService: .shared)
        #expect(result.map(\.id) == [gr2024.id])
    }

    @Test("apply preserves the relative order of surviving trips")
    func applyPreservesRelativeOrderOfSurvivors() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeTrip(in: ctx, start: day(2024, 1, 1)); a.countryCodes = "GR"
        let b = makeTrip(in: ctx, start: day(2024, 2, 1)); b.countryCodes = "IT" // fails
        let c = makeTrip(in: ctx, start: day(2024, 3, 1)); c.countryCodes = "GR"
        let d = makeTrip(in: ctx, start: day(2024, 4, 1)); d.countryCodes = "FR" // fails

        var f = TripFilters(); f.countryCodes = ["GR"]
        let result = f.apply(to: [a, b, c, d], photoService: .shared)
        #expect(result.map(\.id) == [a, c].map(\.id))
    }
}
