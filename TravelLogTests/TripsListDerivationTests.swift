//
//  TripsListDerivationTests.swift
//  TravelLogTests
//
//  Pure static seams behind the trips-list filter-chip pickers. These used to
//  be instance computed properties re-derived on every `@Query` republish; the
//  perf pass moved them into cached @State fed by `TripsListView.computeAvailable*`
//  (mirrors the `visibleCards` pure-seam pattern). Testing the pure functions
//  pins the picker semantics (dedup, sort order, per-trip country counting)
//  without a view host.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripsListDerivationTests {

    private func date(_ year: Int, _ month: Int = 6, _ day: Int = 15) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func aiCandidatesRespectYearFilterBeforeCap() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let older = (0..<40).map { _ in Trip(startDate: date(2023)) }
        let matching = Trip(startDate: date(2026))
        let trips = older + [matching]
        for trip in trips { context.insert(trip) }
        var filters = TripFilters()
        filters.years = [2026]

        let candidates = TripsListView.aiCandidateSnapshots(
            trips: trips, filters: filters, photoService: .shared)
        #expect(candidates.map(\.id) == [matching.id])
    }

    @Test func aiCandidatesWithoutFiltersIncludeEveryLiveTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = Trip(startDate: date(2023))
        let deleted = Trip(startDate: date(2024))
        let last = Trip(startDate: date(2026))
        let trips = [first, deleted, last]
        for trip in trips { context.insert(trip) }
        try context.save()
        context.delete(deleted)
        #expect(deleted.isDeleted)

        let candidates = TripsListView.aiCandidateSnapshots(
            trips: trips, filters: TripFilters(), photoService: .shared)
        #expect(candidates.map(\.id) == [first.id, last.id])
    }

    @Test func aiCandidatesAreEmptyWhenNoTripsMatchFilters() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2023))
        context.insert(trip)
        var filters = TripFilters()
        filters.years = [2026]

        #expect(TripsListView.aiCandidateSnapshots(
            trips: [trip], filters: filters, photoService: .shared).isEmpty)
    }

    // MARK: - availableYears

    @Test func availableYearsDedupesAndSortsDescending() {
        let years = TripsListView.computeAvailableYears(startDates: [
            date(2024), date(2024, 1, 1), date(2022), date(2026), date(2022, 12, 31),
        ])
        #expect(years == [2026, 2024, 2022])
    }

    @Test func availableYearsEmptyInputIsEmpty() {
        #expect(TripsListView.computeAvailableYears(startDates: []).isEmpty)
    }

    @Test func availableYearsSingleYear() {
        #expect(TripsListView.computeAvailableYears(startDates: [date(2025), date(2025, 3, 2)]) == [2025])
    }

    @Test func availableYearsIgnoreNonGregorianDeviceCalendarByDefault() {
        #expect(TripFilters.yearCalendar.identifier == .gregorian)
        let dates = [date(2016), date(2019, 4, 15), date(2019, 6, 15), date(2026)]
        #expect(TripsListView.computeAvailableYears(startDates: dates) == [2026, 2019, 2016])
        // Only the injected calendar drives membership: Heisei 31/28, Reiwa 8/1.
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = .current
        #expect(TripsListView.computeAvailableYears(startDates: dates, calendar: japanese) == [31, 28, 8, 1])
    }

    @Test("the Gregorian year filter keeps 2019 trips from both sides of the Heisei/Reiwa change")
    func yearFilterKeepsGregorianYearAcrossEraChange() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let heisei = Trip(startDate: date(2019, 4, 15))
        let reiwa = Trip(startDate: date(2019, 6, 15))
        let other = Trip(startDate: date(2020))
        for trip in [heisei, reiwa, other] { context.insert(trip) }
        var filters = TripFilters()
        filters.years = [2019]

        let kept = filters.apply(to: [heisei, reiwa, other], photoService: .shared)
        #expect(kept.map(\.id) == [heisei.id, reiwa.id])
    }

    // MARK: - availableCountries

    @Test func availableCountriesCountsTripsNotOccurrences() {
        // GR appears in 3 trips; the trip visiting GR twice ("GR,GR") counts once.
        let result = TripsListView.computeAvailableCountries(countryCodeStrings: [
            "GR,GR", "GR,IT", "GR", "IT", "FR",
        ])
        let asDict = Dictionary(uniqueKeysWithValues: result.map { ($0.code, $0.count) })
        #expect(asDict["GR"] == 3)
        #expect(asDict["IT"] == 2)
        #expect(asDict["FR"] == 1)
    }

    @Test func availableCountriesSortedByCountThenCode() {
        let result = TripsListView.computeAvailableCountries(countryCodeStrings: [
            "GR,IT", "GR", "IT", "FR", "ES",
        ])
        // GR=2, IT=2, FR=1, ES=1 → counts desc, then ISO asc within a tie.
        #expect(result.map(\.code) == ["GR", "IT", "ES", "FR"])
    }

    @Test func availableCountriesIgnoresEmptyTokens() {
        // Leading/trailing/double commas and blank strings produce no codes.
        let result = TripsListView.computeAvailableCountries(countryCodeStrings: [
            "", ",", "GR,", ",IT", "GR,,IT",
        ])
        let asDict = Dictionary(uniqueKeysWithValues: result.map { ($0.code, $0.count) })
        #expect(asDict["GR"] == 2)
        #expect(asDict["IT"] == 2)
        #expect(result.count == 2)
    }

    @Test func availableCountriesEmptyInputIsEmpty() {
        #expect(TripsListView.computeAvailableCountries(countryCodeStrings: []).isEmpty)
    }
}
