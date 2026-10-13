//
//  TripFilters.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import Foundation

/// User-configurable filter set for the trips list. Categories combine with
/// AND; values within a category with OR ("2024 or 2025"). Persisted as one
/// JSON blob in `UserDefaults`, device-local and never synced.
/// Year membership is the Gregorian year of `startDate`. Any duration
/// bucket excludes ongoing trips, whose final length is unknown.
/// `requiresPhotos` keeps a trip whose photo count is not cached yet:
/// unresolved counts never hide a trip.
nonisolated struct TripFilters: Codable, Equatable, Sendable {

    var years: Set<Int> = []
    var countryCodes: Set<String> = []
    var durations: Set<DurationBucket> = []
    var requiresPhotos: Bool = false

    /// `true` when at least one filter dimension is non-default.
    /// Drives the visibility of the "Clear" chip at the end of the
    /// filter row.
    var isActive: Bool {
        !years.isEmpty || !countryCodes.isEmpty || !durations.isEmpty || requiresPhotos
    }

    /// Year membership is Gregorian; device calendars only affect presentation.
    static var yearCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Application

    /// Filter `trips` per the current selection, in O(n) with O(1) work
    /// per trip. Each predicate short-circuits when its filter dimension
    /// is empty (no allocation, no work). Order is preserved — callers
    /// apply this BEFORE `TripSorter.sort`, so the input order doesn't
    /// matter.
    @MainActor
    func apply(to trips: [Trip], photoService: PhotoService) -> [Trip] {
        guard isActive else { return trips }

        let calendar = Self.yearCalendar
        return trips.filter { trip in
            if !years.isEmpty {
                let year = calendar.component(.year, from: trip.startDate)
                if !years.contains(year) { return false }
            }

            // Country — at least one of the trip's destination ISO codes
            // must be in the set. countryCodes is "GR,IT" comma-joined.
            if !countryCodes.isEmpty {
                let tripCodes = trip.countryCodes
                    .split(separator: ",")
                    .map { String($0) }
                if !tripCodes.contains(where: { countryCodes.contains($0) }) {
                    return false
                }
            }

            // Duration — bucket the trip's durationDays. Ongoing trips
            // (nil durationDays) are excluded when any duration bucket is
            // selected; see struct doc for rationale.
            if !durations.isEmpty {
                guard let days = trip.durationDays else { return false }
                if !durations.contains(where: { $0.matches(days: days) }) {
                    return false
                }
            }

            // Photos — at least one photo, by cached count. Uncached
            // trips (nil) stay visible while the prewarm runs.
            if requiresPhotos {
                if let count = photoService.cachedPhotoCount(for: trip.id),
                   count <= 0 {
                    return false
                }
            }

            return true
        }
    }

    // MARK: - Persistence

    /// Key under which the JSON-encoded filters live in
    /// `UserDefaults.standard`. Single blob (rather than one key per
    /// dimension) keeps the encode/decode atomic — partial writes
    /// can't produce a half-applied filter on cold launch.
    private static let storeKey = "tripFiltersJSON"

    /// Blobs without `formatVersion` (version 1) hold `years` as device
    /// calendar year numbers, which earlier builds matched against
    /// `Calendar.current`; version 2 holds Gregorian years.
    private static let formatVersion = 2

    /// Load persisted filters from `UserDefaults`. Returns an empty
    /// filter set on first launch, on decode failure (e.g. schema
    /// drift from a future build), or when the stored payload is
    /// missing. Never throws — filter state is opportunistic.
    /// A version 1 blob is upgraded once and saved back, so a later
    /// device calendar change cannot reinterpret its years.
    static func loadFromDefaults(
        defaults: UserDefaults = .standard, deviceCalendar: Calendar = .current
    ) -> TripFilters {
        guard let str = defaults.string(forKey: storeKey),
              let data = str.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return TripFilters()
        }
        guard stored.formatVersion < formatVersion else { return stored.filters }
        var upgraded = stored.filters
        upgraded.years = gregorianYears(fromLegacy: upgraded.years, deviceCalendar: deviceCalendar)
        upgraded.saveToDefaults(defaults: defaults)
        return upgraded
    }

    /// Gregorian years for version 1 `years`, read in the device calendar
    /// as the earlier build applied them. Buddhist and Minguo years share
    /// Gregorian New Year at a fixed offset. Any other calendar clears the
    /// years (any year) rather than guess: Japanese year numbers recur in
    /// every era (8 matched both 1996 and 2026) and eras begin mid-year,
    /// and lunar, lunisolar and solar years straddle two Gregorian years.
    static func gregorianYears(fromLegacy years: Set<Int>, deviceCalendar: Calendar) -> Set<Int> {
        switch deviceCalendar.identifier {
        case .gregorian, .iso8601: years
        case .buddhist: Set(years.map { $0 - 543 })
        case .republicOfChina: Set(years.map { $0 + 1911 })
        default: []
        }
    }

    /// Persist the current filters to `UserDefaults`. Called from the
    /// view's `.onChange(of: filters)` whenever a picker mutates state.
    /// Best-effort — encode failures (vanishingly unlikely for this
    /// shape) leave the previous payload in place.
    func saveToDefaults(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Stored(self)),
              let str = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: Self.storeKey)
    }

    /// The saved blob: the filter keys plus `formatVersion`, which
    /// earlier builds ignore when decoding.
    private struct Stored: Codable {
        var filters: TripFilters
        var formatVersion: Int

        private enum CodingKeys: String, CodingKey { case formatVersion }

        init(_ filters: TripFilters) {
            self.filters = filters
            formatVersion = TripFilters.formatVersion
        }

        init(from decoder: any Decoder) throws {
            filters = try TripFilters(from: decoder)
            formatVersion = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        }

        func encode(to encoder: any Encoder) throws {
            try filters.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(formatVersion, forKey: .formatVersion)
        }
    }
}

/// Discrete duration buckets for the trip-length filter. Chosen to
/// match how people actually describe trips:
/// - **Weekend**: 1–3 days. Quick getaway, a city break.
/// - **Week**: 4–10 days. A standard vacation.
/// - **Long**: 11+ days. Sabbatical, extended travel, multi-leg trip.
///
/// Boundaries are inclusive at both ends. The 4-day cutoff between
/// weekend and week is slightly arbitrary but matches how the travel
/// industry segments trip lengths (Booking.com, Expedia). The 11-day
/// cutoff for "long" mirrors the conventional 10-day "two-week
/// vacation" rounding.
nonisolated enum DurationBucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekend
    case week
    case long

    var id: String { rawValue }

    /// Full display label for picker rows.
    var label: String {
        switch self {
        case .weekend:
            String(localized: "trip-filter.duration.weekend.label", defaultValue: "Weekend (1–3 days)", comment: "Full trip-duration filter label.")
        case .week:
            String(localized: "trip-filter.duration.week.label", defaultValue: "Week (4–10 days)", comment: "Full trip-duration filter label.")
        case .long:
            String(localized: "trip-filter.duration.long.label", defaultValue: "Long (11+ days)", comment: "Full trip-duration filter label.")
        }
    }

    /// Short label for the chip itself when the bucket is the only one
    /// selected ("Duration: Weekend" rather than "Duration: Weekend
    /// (1–3 days)").
    var shortLabel: String {
        switch self {
        case .weekend:
            String(localized: "trip-filter.duration.weekend.short-label", defaultValue: "Weekend", comment: "Compact trip-duration filter label.")
        case .week:
            String(localized: "trip-filter.duration.week.short-label", defaultValue: "Week", comment: "Compact trip-duration filter label.")
        case .long:
            String(localized: "trip-filter.duration.long.short-label", defaultValue: "Long", comment: "Compact trip-duration filter label.")
        }
    }

    /// `true` when `days` falls into this bucket. Boundary days are
    /// inclusive.
    func matches(days: Int) -> Bool {
        switch self {
        case .weekend: return days >= 1 && days <= 3
        case .week:    return days >= 4 && days <= 10
        case .long:    return days >= 11
        }
    }
}
