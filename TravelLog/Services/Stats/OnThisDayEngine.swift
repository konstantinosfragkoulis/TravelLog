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
    var id: Int { year }
    let year: Int
    let yearsAgo: Int
    let trips: [OnThisDayTripGroup]
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
nonisolated enum OnThisDayEngine {

    /// Defensive cap on the year span a single stay may match. Real stays
    /// are bounded by the clusterer's 12 h extension cap; a corrupt row
    /// with a decades-long interval must not spin the loop.
    private static let maxYearSpan = 80

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
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard let todayYear = todayComponents.year,
              let month = todayComponents.month,
              let day = todayComponents.day else { return [] }

        // year → matched stays (in input order)
        var matchesByYear: [Int: [OnThisDayStay]] = [:]
        var dayIntervals: [Int: (start: Date, end: Date)] = [:]
        var invalidYears = Set<Int>()

        for stay in stays {
            try checkCancellation()
            let startYear = calendar.component(.year, from: stay.startTime)
            let endYear = calendar.component(.year, from: stay.endTime)
            guard endYear >= startYear, endYear - startYear <= maxYearSpan else { continue }

            // Clamp to past years only — and skip stays that have no past
            // years at all (anything from the current year), which would
            // otherwise form an invalid `2026...2025` range and trap.
            let upperYear = min(endYear, todayYear - 1)
            guard startYear <= upperYear else { continue }

            for year in startYear...upperYear {
                try checkCancellation()
                if invalidYears.contains(year) { continue }
                if dayIntervals[year] == nil {
                    guard let target = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                        invalidYears.insert(year)
                        continue
                    }
                    // Reject auto-corrected dates (Feb 29 in a non-leap year
                    // becomes Mar 1) — the components must round-trip exactly.
                    let check = calendar.dateComponents([.month, .day], from: target)
                    guard check.month == month, check.day == day else {
                        invalidYears.insert(year)
                        continue
                    }
                    let dayStart = calendar.startOfDay(for: target)
                    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                        invalidYears.insert(year)
                        continue
                    }
                    dayIntervals[year] = (dayStart, dayEnd)
                }
                guard let interval = dayIntervals[year] else { continue }

                // Half-open day interval: a
                // stay ending EXACTLY at 00:00 belongs to the previous day —
                // `>=` counted it for both days, minting an extra place-day.
                if stay.startTime < interval.end && stay.endTime > interval.start {
                    matchesByYear[year, default: []].append(stay)
                }
            }
        }

        return try matchesByYear
            .sorted { $0.key > $1.key }
            .map { year, yearStays in
                OnThisDayYearGroup(
                    year: year,
                    yearsAgo: todayYear - year,
                    trips: try tripGroups(from: yearStays, checkCancellation: checkCancellation)
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
