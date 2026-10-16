//
//  StatsOverview.swift
//  TravelLog
//

import Foundation

/// The Stats page's derived values: the This year comparison, the
/// zero-filled By Year bars, the month strip, the trip-length buckets, the
/// Collections subtitles and the Exploration years and coverage. Built
/// once per applied aggregate (`StatsView.apply`), never in `body`: the
/// aggregator owns the raw
/// reductions, this value owns everything the page derives from them. The
/// one live overlay, remembered countries, stays in the view (they carry
/// no date, so they are never first recorded and are subtracted there).
nonisolated struct StatsOverview: Equatable, Sendable {

    /// One year's totals, by the `YearStat` definitions the By Year bars use.
    struct YearTotals: Equatable, Sendable {
        var travelDays = 0
        var trips = 0
        var countries = 0
        /// Countries first recorded in the year, by Wrapped's rule. Tracked
        /// data only; the view drops remembered countries.
        var firstRecordedCodes: [String] = []

        func firstRecordedCount(excluding remembered: Set<String>) -> Int {
            firstRecordedCodes.count { !remembered.contains($0) }
        }
    }

    /// What the Collections card says under each row.
    struct CollectionsSummary: Equatable, Sendable {
        var placeCount = 0
        /// The most visited places, at most three.
        var topPlaceNames: [String] = []
        var airportCount = 0
        var topAirportCode: String?
        var topAirportVisits = 0
        var flightCount = 0
        var reviewCount = 0
        var kmFlown: Double = 0
        var longestFlightKm: Double = 0
        var longestFlightRoute: String?

        var isEmpty: Bool { placeCount == 0 && airportCount == 0 && flightCount == 0 && reviewCount == 0 }
    }

    /// The Exploration card and its detail page: new hexes per year and each
    /// country's coverage, home countries first.
    struct ExplorationSummary: Equatable, Sendable {
        /// One country's explored hexes against its area.
        struct Coverage: Equatable, Sendable, Identifiable {
            let code: String
            let name: String?
            let count: Int
            /// Share of the country's area (0...100), by the mean hex area;
            /// nil when the catalog has no area for the code.
            var percent: Double?
            /// About how many hexes the country holds; nil without an area.
            var estimatedTotal: Int?
            var id: String { code }
        }

        var newThisYear = 0
        /// Contiguous years, oldest first, ending at the current year (or a
        /// later first-visit year): a year without new hexes is a zero
        /// entry. At most `maxYears`; empty when no hex has a year.
        var years: [StatsAggregator.HexYear] = []
        /// Countries hosting an active Home, most hexes first, zero-hex
        /// homes included.
        var homes: [Coverage] = []
        /// The leading countries by hexes that are not homes.
        var others: [Coverage] = []

        /// The strip needs two years to say anything a single number does not.
        var showsYears: Bool { years.count >= 2 }
        /// The longest bar of the country list.
        var maxListedCount: Int { (homes + others).map(\.count).max() ?? 0 }
    }

    /// The By Year card shows at most this many years.
    static let maxYears = 8

    var currentYear = 0
    var thisYear = YearTotals()
    var lastYear = YearTotals()
    /// Last year was tracked (some data or the first ping predates this
    /// year), so a delta compares two recorded years.
    var comparesWithLastYear = false
    /// Contiguous years, oldest first, ending at the current year (or the
    /// latest year with data): a year without travel is a zero entry.
    /// Empty when nothing was ever recorded.
    var years: [StatsAggregator.YearStat] = []
    /// Travel days per month, January first; nil when there is none.
    var monthDays: [Int]?
    /// The busiest month (1...12) and its days; nil without travel days.
    var peakMonth: Int?
    var peakMonthDays = 0
    /// Completed trips per length bucket; nil when there is none.
    var tripLengthBuckets: [Int]?
    var collections = CollectionsSummary()
    var exploration = ExplorationSummary()

    /// Anything to show in the This year card.
    var hasYearData: Bool { !years.isEmpty }

    init() {}

    /// `countryArea` is the km² lookup behind the coverage shares
    /// (`CountryCatalog`); tests pass invented areas.
    init(_ aggregates: StatsAggregator.Aggregates, now: Date, calendar: Calendar,
         countryArea: (String) -> Double? = CountryCatalog.area(code:)) {
        let current = Self.currentYear(now: now, calendar: calendar)
        currentYear = current
        let stats = aggregates.yearStats ?? []
        let byYear = Dictionary(stats.map { ($0.year, $0) }, uniquingKeysWith: { first, _ in first })
        let firstRecorded = Dictionary(
            (aggregates.firstRecordedCountries ?? []).map { ($0.year, $0.codes) },
            uniquingKeysWith: { first, _ in first })
        func totals(_ year: Int) -> YearTotals {
            let stat = byYear[year]
            return YearTotals(travelDays: stat?.days ?? 0, trips: stat?.trips ?? 0,
                              countries: stat?.countries ?? 0,
                              firstRecordedCodes: firstRecorded[year] ?? [])
        }
        thisYear = totals(current)
        lastYear = totals(current - 1)
        let firstDataYear = stats.map(\.year).min()
        comparesWithLastYear = (firstDataYear.map { $0 < current } ?? false)
            || (aggregates.passportData.sinceYear.map { $0 < current } ?? false)
        if let firstDataYear, let lastDataYear = stats.map(\.year).max() {
            let end = max(lastDataYear, current)
            let start = max(firstDataYear, end - (Self.maxYears - 1))
            years = (start...end).map { byYear[$0] ?? StatsAggregator.YearStat(year: $0) }
        }

        if let bins = aggregates.monthTravelDays, bins.count == 12, bins.contains(where: { $0 > 0 }) {
            monthDays = bins
            if let peak = StatsAggregator.favoriteMonth(bins: bins) {
                peakMonth = peak.month
                peakMonthDays = peak.days
            }
        }
        if let buckets = aggregates.tripLengthBuckets, buckets.contains(where: { $0 > 0 }) {
            tripLengthBuckets = buckets
        }

        let source = aggregates.collections
        var summary = CollectionsSummary()
        summary.placeCount = source.places.count
        summary.topPlaceNames = source.places.prefix(3).map(\.name)
        summary.airportCount = source.airports.count
        // Most dwells, ties to the alphabetically first code.
        if let top = source.airports.max(by: { lhs, rhs in
            if lhs.stayCount != rhs.stayCount { return lhs.stayCount < rhs.stayCount }
            return lhs.code > rhs.code
        }), top.stayCount > 0 {
            summary.topAirportCode = top.code
            summary.topAirportVisits = top.stayCount
        }
        summary.flightCount = source.flights.count
        summary.reviewCount = source.possibleFlights.count
        summary.kmFlown = source.flightStats.totalKm
        summary.longestFlightKm = source.flightStats.longestKm
        summary.longestFlightRoute = source.flightStats.longestRouteLabel
        collections = summary
        exploration = Self.exploration(aggregates, currentYear: current, countryArea: countryArea)
    }

    static func exploration(
        _ aggregates: StatsAggregator.Aggregates, currentYear: Int,
        countryArea: (String) -> Double?
    ) -> ExplorationSummary {
        var summary = ExplorationSummary()
        summary.newThisYear = aggregates.newHexesThisYear
        let byYear = Dictionary(
            (aggregates.newHexesByYear ?? []).map { ($0.year, $0.count) },
            uniquingKeysWith: { first, _ in first })
        if let first = byYear.keys.min(), let last = byYear.keys.max() {
            let end = max(last, currentYear)
            let start = max(first, end - (maxYears - 1))
            summary.years = (start...end).map { StatsAggregator.HexYear(year: $0, count: byYear[$0] ?? 0) }
        }
        func coverage(_ entry: StatsAggregator.HexCountry) -> ExplorationSummary.Coverage {
            let area = countryArea(entry.code)
            return .init(code: entry.code, name: entry.name, count: entry.count,
                         percent: CountryCatalog.coveragePercent(hexCount: entry.count, areaKm2: area),
                         estimatedTotal: area.flatMap { $0 > 0 ? CountryCatalog.estimatedHexCount(areaKm2: $0) : nil })
        }
        let homes = aggregates.homeHexCountries ?? []
        let homeCodes = Set(homes.map(\.code))
        summary.homes = homes.map(coverage)
        // The aggregator hands over six leaders, so pinned homes never take
        // a slot from the others.
        summary.others = aggregates.topHexCountries.filter { !homeCodes.contains($0.code) }.map(coverage)
        return summary
    }

    /// Today's Gregorian label year in the supplied calendar's time zone.
    static func currentYear(now: Date, calendar: Calendar) -> Int {
        var gregorian = TravelDays.labelCalendar
        gregorian.timeZone = calendar.timeZone
        return gregorian.component(.year, from: now)
    }
}
