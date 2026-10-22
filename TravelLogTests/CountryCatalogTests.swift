//
//  CountryCatalogTests.swift
//  TravelLogTests
//
//  Covers Stats coverage statistics:
//
//  1. `CountryCatalog`: the generated data tables' shape (193 UN members,
//     fold-map integrity), the territory→sovereign fold semantics, the
//     per-country coverage cap, and the two-significant-figure formatting
//     the Exploration card renders.
//  2. `StatsAggregator.travelDays`: distinct-day union across trips,
//     ongoing-through-now, year-boundary split. UTC-pinned fixtures (the
//     helper takes a calendar seam) so day boundaries aren't
//     runner-tz-flaky.
//  3. `StatsAggregator.aggregate`: the pinned `homeHexCountries` rows:
//     count join, zero-hex home, multi-home ordering, and the empty
//     default.
//
//  `@MainActor` because `@Model` types are MainActor-isolated under the
//  app target's default-MainActor mode.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct CountryCatalogTests {

    // MARK: - Data-table shape

    @Test("generated tables: 193 UN members, folds consistent, areas present")
    func generatedTableShape() {
        #expect(CountryCatalog.unMembers.count == 193)
        #expect(CountryCatalog.unMemberTotal == 193)
        #expect(CountryCatalog.isoCodeTotal >= 249)
        // Every fold target is a UN member; no fold key is one itself.
        for (territory, sovereign) in CountryCatalog.sovereignOfTerritory {
            #expect(CountryCatalog.unMembers.contains(sovereign))
            #expect(!CountryCatalog.unMembers.contains(territory))
        }
        // Area table covers essentially the whole ISO list, positive only.
        #expect(CountryCatalog.areaKm2.count >= 240)
        #expect(CountryCatalog.areaKm2.values.allSatisfy { $0 > 0 })
        // Spot pins against known figures (total area, km²).
        #expect(CountryCatalog.areaKm2["GR"] == 131_990)
        #expect(CountryCatalog.areaKm2["MC"] == 2.02)
    }

    // MARK: - UN-member folding

    @Test("territories fold into their sovereign; non-members drop out")
    func unMemberFolding() {
        // PR folds into US; visiting both is still ONE UN country.
        #expect(CountryCatalog.unMemberCount(of: ["PR", "US", "GR"]) == 2)
        // Folds alone still count the sovereign.
        #expect(CountryCatalog.unMemberCount(of: ["GL"]) == 1)   // → DK
        #expect(CountryCatalog.unMemberCount(of: ["HK", "MO"]) == 1) // → CN
        // Standalone non-members count on the territories stat only.
        #expect(CountryCatalog.unMemberCount(of: ["TW", "XK", "VA"]) == 0)
        // Case-insensitive; empty is zero.
        #expect(CountryCatalog.unMemberCount(of: ["gr"]) == 1)
        #expect(CountryCatalog.unMemberCount(of: []) == 0)
    }

    // MARK: - Coverage math

    @Test("country coverage caps at 100 and returns nil for unknown codes")
    func countryCoverage() throws {
        // Monaco (2.02 km²) is smaller than one res-6 hex; cap, not 1788%.
        #expect(CountryCatalog.coveragePercent(code: "MC", hexCount: 1) == 100)
        #expect(CountryCatalog.coveragePercent(code: "GR", hexCount: 0) == 0)
        #expect(CountryCatalog.coveragePercent(code: "ZZ", hexCount: 5) == nil)
        // 100 hexes in Greece ≈ 100 × 36.129 / 131,990 ≈ 2.74%.
        let greece = try #require(CountryCatalog.coveragePercent(code: "GR", hexCount: 100))
        #expect(abs(greece - 2.737) < 0.01)
    }

    @Test("world fractions divide by the exact and estimated cell counts")
    func worldFractions() {
        #expect(CountryCatalog.fractionOfEarth(hexCount: 0) == 0)
        #expect(CountryCatalog.fractionOfEarth(hexCount: 14_117_882) == 1)
        let earth = CountryCatalog.fractionOfEarth(hexCount: 3000)
        #expect(abs(earth - 3000.0 / 14_117_882.0) < 1e-12)
        let land = CountryCatalog.fractionOfLand(hexCount: 3000)
        #expect(abs(land - 3000.0 / 4_122_000.0) < 1e-12)
    }

    // MARK: - Formatting

    @Test("percentText keeps two significant figures below 1%")
    func percentFormatting() {
        let locale = Locale(identifier: "en")
        #expect(CountryCatalog.percentText(0, locale: locale) == "0%")
        #expect(CountryCatalog.percentText(1, locale: locale) == "100%")
        #expect(CountryCatalog.percentText(0.5, locale: locale) == "50%")
        #expect(CountryCatalog.percentText(0.042, locale: locale) == "4.2%")
        #expect(CountryCatalog.percentText(0.005, locale: locale) == "0.50%")
        #expect(CountryCatalog.percentText(0.00021249, locale: locale) == "0.021%")
        #expect(CountryCatalog.percentText(0.0000728, locale: locale) == "0.0073%")
    }

    @Test("countryPercentText floors at <0.1% and never shows 0.0%")
    func countryPercentFormatting() {
        let locale = Locale(identifier: "en")
        #expect(CountryCatalog.countryPercentText(0, locale: locale) == "0%")
        #expect(CountryCatalog.countryPercentText(0.04, locale: locale) == "<0.1%")
        #expect(CountryCatalog.countryPercentText(4.23, locale: locale) == "4.2%")
        #expect(CountryCatalog.countryPercentText(15.4, locale: locale) == "15%")
        #expect(CountryCatalog.countryPercentText(100, locale: locale) == "100%")
    }

    @Test("countryPercentText keeps coverage below 99.95% under 100%")
    func countryPercentNoFalseHundred() {
        // [99.5, 99.95) used to escape the short-circuit and round to "100%".
        let locale = Locale(identifier: "en")
        #expect(CountryCatalog.countryPercentText(99.6, locale: locale) == "99%")
        #expect(CountryCatalog.countryPercentText(99.94, locale: locale) == "99%")
        #expect(CountryCatalog.countryPercentText(99.96, locale: locale) == "100%")
    }

    @Test("percentage decimals follow German and Greek comma separators")
    func percentageDecimalsUseLocale() {
        #expect(CountryCatalog.percentText(
            0.042,
            locale: Locale(identifier: "de")
        ) == "4,2%")
        #expect(CountryCatalog.countryPercentText(
            4.23,
            locale: Locale(identifier: "el")
        ) == "4,2%")
    }

    // MARK: - Travel days (UTC-pinned fixtures)

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeTrip(start: Date, end: Date?) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        return trip
    }

    @Test("travelDays counts distinct days; a completed trip spans inclusive")
    func travelDaysBasic() {
        let trips = [makeTrip(start: utcDate(2026, 6, 1), end: utcDate(2026, 6, 3))]
        let days = StatsAggregator.travelDays(trips: trips, now: utcDate(2026, 6, 15), calendar: Self.utc)
        #expect(days.total == 3)
        #expect(days.thisYear == 3)
    }

    @Test("a year-straddling trip splits between total and this-year")
    func travelDaysYearBoundary() {
        let trips = [makeTrip(start: utcDate(2025, 12, 30), end: utcDate(2026, 1, 2))]
        let days = StatsAggregator.travelDays(trips: trips, now: utcDate(2026, 3, 1), calendar: Self.utc)
        #expect(days.total == 4)      // Dec 30, 31, Jan 1, 2
        #expect(days.thisYear == 2)   // Jan 1, 2
    }

    @Test("an ongoing trip counts elapsed days through now")
    func travelDaysOngoing() {
        let trips = [makeTrip(start: utcDate(2026, 6, 13), end: nil)]
        let days = StatsAggregator.travelDays(trips: trips, now: utcDate(2026, 6, 15), calendar: Self.utc)
        #expect(days.total == 3)      // 13, 14, 15, ending at now
    }

    @Test("overlapping trips dedup shared days via the union")
    func travelDaysOverlapDedup() {
        let trips = [
            makeTrip(start: utcDate(2026, 6, 1), end: utcDate(2026, 6, 3)),
            makeTrip(start: utcDate(2026, 6, 3), end: utcDate(2026, 6, 5)),
        ]
        let days = StatsAggregator.travelDays(trips: trips, now: utcDate(2026, 6, 15), calendar: Self.utc)
        #expect(days.total == 5)      // June 3 counted once
    }

    @Test("no trips means zero days")
    func travelDaysEmpty() {
        let days = StatsAggregator.travelDays(trips: [], now: utcDate(2026, 6, 15), calendar: Self.utc)
        #expect(days.total == 0)
        #expect(days.thisYear == 0)
    }

    // MARK: - Pinned home countries (aggregate)

    private func makeHexVisit(_ h3Index: String, iso: String?, country: String?) -> HexVisit {
        let visit = HexVisit(h3Index: h3Index, firstVisited: .now, centerLatitude: 0, centerLongitude: 0)
        visit.isoCountryCode = iso
        visit.country = country
        return visit
    }

    @Test("homeHexCountries joins hex counts; zero-hex home still pins")
    func homeHexCountriesJoin() throws {
        let hexVisits = [
            makeHexVisit("861f19507ffffff", iso: "GR", country: "Greece"),
            makeHexVisit("861f1950fffffff", iso: "GR", country: "Greece"),
            makeHexVisit("86196d81fffffff", iso: "NL", country: "Netherlands"),
        ]
        let result = StatsAggregator.aggregate(
            visitedStays: [], transitStays: [], trips: [],
            hexVisits: hexVisits, totalPings: 0, totalStays: 0,
            flightCount: 0, trackingSince: nil,
            homeCountryCodes: ["GR", "FR"]
        )
        let homes = try #require(result.homeHexCountries)
        #expect(homes.count == 2)
        // GR has hexes (sorted first), FR pinned with zero (fresh move).
        #expect(homes[0] == StatsAggregator.HexCountry(code: "GR", name: "Greece", count: 2))
        #expect(homes[1] == StatsAggregator.HexCountry(code: "FR", name: nil, count: 0))
        // topHexCountries semantics unchanged; GR stays in the top list.
        #expect(result.topHexCountries.contains { $0.code == "GR" })
    }

    @Test("no active-home codes yields an empty (non-nil) pin list")
    func homeHexCountriesDefault() {
        let result = StatsAggregator.aggregate(
            visitedStays: [], transitStays: [], trips: [],
            hexVisits: [], totalPings: 0, totalStays: 0,
            flightCount: 0, trackingSince: nil
        )
        #expect(result.homeHexCountries == [])
        #expect(result.travelDaysTotal == 0)
    }
}
