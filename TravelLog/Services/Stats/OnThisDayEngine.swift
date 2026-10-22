//
//  OnThisDayEngine.swift
//  TravelLog
//

import Foundation

// MARK: - Inputs / Outputs (Sendable value types — pure, fully unit-testable)

/// Value mirror of the destination-stay fields the engine consumes. The
/// Stats view builds these from its existing `@Query` results; tests build
/// them directly.
nonisolated struct OnThisDayStay: Sendable {
    let stayID: UUID
    let tripID: UUID?
    /// Display place, already collapsed via the app-wide
    /// `metroName ?? islandName ?? locality` chain.
    let place: String?
    let startTime: Date
    let endTime: Date
    let weatherConditionRaw: String?
    let avgTemperatureC: Double?
    /// ISO country of the stay, for the flag tile when no photo exists.
    var isoCountryCode: String? = nil
}

/// One trip's worth of matches in a given year — multiple stays of the
/// same trip collapse into one row ("Kyoto · Osaka"). Codable because the
/// groups ride in the persisted `StatsSnapshotStore` snapshot (they are
/// NOT hydrated from it — "on this day" is date-sensitive — but a uniform
/// Codable `Aggregates` keeps the store trivial).
nonisolated struct OnThisDayTripGroup: Identifiable, Sendable, Codable {
    let id: String
    let tripID: UUID?
    /// Unique places in stay order. May be empty when no stay had a name.
    let places: [String]
    let stayCount: Int
    /// First non-nil weather among the matched stays — enough for a chip.
    let weatherConditionRaw: String?
    let avgTemperatureC: Double?
    /// Span of the matched stays and their countries, in stay order.
    /// Optional so cached `Aggregates` written before these fields decode.
    var startTime: Date? = nil
    var endTime: Date? = nil
    var isoCountryCodes: [String]? = nil
}

nonisolated struct OnThisDayYearGroup: Identifiable, Sendable, Codable {
    /// The year's chronological identity: in a calendar with eras the year
    /// number alone repeats (Heisei 8 and Reiwa 8).
    var id: String { yearStart.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "\(year)" }
    /// The year number in the injected calendar, era-relative where the
    /// calendar has eras.
    let year: Int
    let yearsAgo: Int
    let trips: [OnThisDayTripGroup]
    /// Start of the calendar year the group matched in. Optional so cached
    /// `Aggregates` written before the field decode.
    var yearStart: Date? = nil
    /// Start of the matched day, which names its era (a year can hold two).
    var day: Date? = nil
    /// The day lies in another era than today, so its year number alone
    /// does not say which year it is. Nil reads as false.
    var namesEra: Bool? = nil
}

// MARK: - Engine

/// "On This Day" matching: which past-year destination stays were active on
/// today's calendar (month, day)?
///
/// Rules:
///   - Only PAST years (a stay from earlier today is not a memory).
///   - A stay matches year `Y` when its `[startTime, endTime]` interval
///     overlaps the calendar day `(Y, month, day)` — so a week-long stay
///     matches every day it covers, and a stay spanning New Year matches
///     dates in both of its years.
///   - Feb 29 only matches in actual leap years (no Feb 28 aliasing —
///     `Calendar.date(from:)` auto-correction is detected and skipped).
///   - Multiple matches are expected and preserved: results are grouped by
///     year (newest first), then by trip within the year.
///   - Years are the injected calendar's chronological year intervals, not
///     bare year numbers: a calendar with eras restarts its numbering (the
///     Japanese calendar's Showa 63, Heisei 30, Reiwa 5), so the target day
///     is built from each interval's own era and year, and years ago counts
///     elapsed calendar years.
nonisolated enum OnThisDayEngine {

    /// Defensive cap on the span a single stay may match. Real stays
    /// are bounded by the clusterer's 12 h extension cap; a corrupt row
    /// with a decades-long interval must not spin the loop.
    private static let maxYearSpan = 80
    private static let maxSpanSeconds = TimeInterval(maxYearSpan + 1) * 366 * 86_400

    static func yearGroups(
        on date: Date, stays: [OnThisDayStay], calendar: Calendar = .current
    ) -> [OnThisDayYearGroup] {
        yearGroups(on: date, stays: stays, calendar: calendar, checkCancellation: {})
    }

    static func yearGroups(
        on date: Date,
        stays: [OnThisDayStay],
        calendar: Calendar = .current,
        checkCancellation: () throws -> Void
    ) rethrows -> [OnThisDayYearGroup] {
        try checkCancellation()
        let todayComponents = calendar.dateComponents([.era, .month, .day, .isLeapMonth], from: date)
        guard let month = todayComponents.month,
              let day = todayComponents.day,
              let currentYear = calendar.dateInterval(of: .year, for: date) else { return [] }
        let leapMonth = todayComponents.isLeapMonth ?? false
        // The last instant of today: a day that starts after midnight (a
        // midnight DST change) then still counts its whole years.
        let todayStart = calendar.startOfDay(for: date)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)?.addingTimeInterval(-1) ?? date

        /// Today's month and day inside one year interval.
        struct Target {
            let dayStart: Date
            let dayEnd: Date
            let year: Int
            let era: Int?
        }
        /// An era can begin inside a calendar year (Reiwa on 1 May 2019 in a
        /// year that began in Heisei), so try the era and year at each end.
        func target(in interval: DateInterval) -> Target? {
            var tried: [DateComponents] = []
            for instant in [interval.start, max(interval.start, interval.end.addingTimeInterval(-1))] {
                let eraYear = calendar.dateComponents([.era, .year], from: instant)
                guard !tried.contains(eraYear) else { continue }
                tried.append(eraYear)
                if let found = eraTarget(eraYear, in: interval) { return found }
            }
            return nil
        }
        func eraTarget(_ eraYear: DateComponents, in interval: DateInterval) -> Target? {
            guard let year = eraYear.year else { return nil }
            var components = DateComponents(era: eraYear.era, year: year, month: month, day: day)
            components.isLeapMonth = leapMonth
            guard let target = calendar.date(from: components),
                  target >= interval.start, target < interval.end else { return nil }
            // Reject auto-corrected dates (Feb 29 in a non-leap year becomes
            // Mar 1; a day past an era's end lands in the next era): the
            // components must round-trip exactly.
            let check = calendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: target)
            guard check.era == eraYear.era, check.year == year,
                  check.month == month, check.day == day,
                  (check.isLeapMonth ?? false) == leapMonth else { return nil }
            let dayStart = calendar.startOfDay(for: target)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return Target(dayStart: dayStart, dayEnd: dayEnd, year: year, era: eraYear.era)
        }

        // year interval start → matched stays (in input order)
        var matchesByYear: [Date: [OnThisDayStay]] = [:]
        var targets: [Date: Target] = [:]
        var invalidYears = Set<Date>()

        for stay in stays {
            try checkCancellation()
            guard stay.endTime.timeIntervalSince(stay.startTime) <= maxSpanSeconds,
                  var interval = calendar.dateInterval(of: .year, for: stay.startTime) else { continue }

            // Past years only (a stay from earlier this year is not a
            // memory): walk the year intervals the stay touches, in order.
            while interval.start < currentYear.start, interval.start <= stay.endTime {
                try checkCancellation()
                let key = interval.start
                if targets[key] == nil, !invalidYears.contains(key) {
                    if let found = target(in: interval) {
                        targets[key] = found
                    } else {
                        invalidYears.insert(key)
                    }
                }
                // Half-open day interval: a
                // stay ending EXACTLY at 00:00 belongs to the previous day —
                // `>=` counted it for both days, minting an extra place-day.
                if let found = targets[key], stay.startTime < found.dayEnd, stay.endTime > found.dayStart {
                    matchesByYear[key, default: []].append(stay)
                }
                guard let next = calendar.dateInterval(of: .year, for: interval.end),
                      next.start > interval.start else { break }
                interval = next
            }
        }

        return try matchesByYear
            .sorted { $0.key > $1.key }
            .compactMap { yearStart, yearStays in
                guard let found = targets[yearStart] else { return nil }
                // Elapsed calendar years from that day to today; the year
                // starts are the fallback when the calendar cannot say.
                let yearsAgo = calendar.dateComponents([.year], from: found.dayStart, to: todayEnd).year
                    ?? calendar.dateComponents([.year], from: yearStart, to: currentYear.start).year
                    ?? 0
                return OnThisDayYearGroup(
                    year: found.year,
                    yearsAgo: yearsAgo,
                    trips: try tripGroups(from: yearStays, checkCancellation: checkCancellation),
                    yearStart: yearStart,
                    day: found.dayStart,
                    namesEra: found.era != todayComponents.era ? true : nil
                )
            }
    }

    /// Collapse a year's matched stays into per-trip rows. Stays without a
    /// parent trip each form their own group (keyed by stay id) rather
    /// than being silently dropped.
    private static func tripGroups(
        from stays: [OnThisDayStay], checkCancellation: () throws -> Void
    ) rethrows -> [OnThisDayTripGroup] {
        var order: [String] = []
        var grouped: [String: [OnThisDayStay]] = [:]

        for stay in stays {
            try checkCancellation()
            let key = stay.tripID?.uuidString ?? "stay-\(stay.stayID.uuidString)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(stay)
        }

        return try order.compactMap { key in
            try checkCancellation()
            guard let members = grouped[key], let first = members.first else { return nil }
            var seenPlaces = Set<String>()
            var places: [String] = []
            for member in members {
                try checkCancellation()
                if let place = member.place, !place.isEmpty, seenPlaces.insert(place).inserted {
                    places.append(place)
                }
            }
            let weatherStay = members.first { $0.weatherConditionRaw != nil }
            var seenCountries = Set<String>()
            var countries: [String] = []
            for member in members {
                try checkCancellation()
                if let code = member.isoCountryCode, !code.isEmpty, seenCountries.insert(code).inserted {
                    countries.append(code)
                }
            }
            return OnThisDayTripGroup(
                id: key,
                tripID: first.tripID,
                places: places,
                stayCount: members.count,
                weatherConditionRaw: weatherStay?.weatherConditionRaw,
                avgTemperatureC: weatherStay?.avgTemperatureC,
                startTime: members.map(\.startTime).min(),
                endTime: members.map(\.endTime).max(),
                isoCountryCodes: countries
            )
        }
    }
}
