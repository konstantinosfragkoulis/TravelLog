//
//  YearWrapped.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Shared renderer lookup with an explicit bundle seam for host-catalog
/// goldens. Nil preserves the production `String(localized:)` lookup path.
nonisolated func localizedRendererString(
    localized key: StaticString,
    defaultValue: String.LocalizationValue,
    bundle: LocalizedStringResource.BundleDescription?,
    locale: Locale
) -> String {
    // `LocalizedStringResource.locale` controls interpolation formatting but
    // `.main` still follows the process's preferred localization. An explicit
    // bundle URL makes Foundation select the catalog matching `locale`, which
    // is required for persisted English snapshots and locale-driven rerenders
    // after a per-app language change.
    let catalogBundle = bundle ?? .atURL(Bundle.main.bundleURL)
    return String(localized: LocalizedStringResource(
        key,
        defaultValue: defaultValue,
        locale: locale,
        bundle: catalogBundle
    ))
}

nonisolated struct NarrativeInputs: Codable, Sendable, Equatable {
    let year: Int
    let tripDisplayNames: [String]
    let tripStartDates: [Date]
    let longestTripName: String?
    let longestTripDays: Int?
    let farthestPlaceName: String?
    let farthestDistanceKm: Double?
    let firstTimeCountryISOCodes: [String]
}

nonisolated enum MysteryFact: Codable, Sendable, Equatable {
    case returnedCity(name: String, times: Int)
    case airportDays(count: Int)
    case shortestTrip(name: String, days: Int)

    func render(
        locale: Locale,
        bundle: LocalizedStringResource.BundleDescription? = nil
    ) -> String {
        switch self {
        case let .returnedCity(name, times):
            // `times` counts the year's trips there, the first visit among
            // them, so the sentence says visits rather than returns.
            return localizedRendererString(
                localized: "wrapped.mystery.visited-city-trips",
                defaultValue: "You visited \(name) on \(times, format: .number.grouping(.never)) trips this year.",
                bundle: bundle,
                locale: locale
            )
        case let .airportDays(count):
            if count == 1 {
                return localizedRendererString(
                    localized: "wrapped.mystery.airport-days.one",
                    defaultValue: "You spent \(count, format: .number.grouping(.never)) day in airports this year.",
                    bundle: bundle,
                    locale: locale
                )
            }
            return localizedRendererString(
                localized: "wrapped.mystery.airport-days.other",
                defaultValue: "You spent \(count, format: .number.grouping(.never)) days in airports this year.",
                bundle: bundle,
                locale: locale
            )
        case let .shortestTrip(name, days):
            if days == 1 {
                return localizedRendererString(
                    localized: "wrapped.mystery.shortest-trip.one",
                    defaultValue: "Your shortest trip was \(days, format: .number.grouping(.never)) day to \(name).",
                    bundle: bundle,
                    locale: locale
                )
            }
            return localizedRendererString(
                localized: "wrapped.mystery.shortest-trip.other",
                defaultValue: "Your shortest trip was \(days, format: .number.grouping(.never)) days to \(name).",
                bundle: bundle,
                locale: locale
            )
        }
    }
}

/// A persisted annual recap snapshot. Once generated, a `YearWrapped` is a
/// **historical artifact** — your 2026 Wrapped in 2030 should look exactly
/// the same as it did in 2026, even if you retroactively edit 2026 trips.
///
/// ## CloudKit considerations
///
/// - **No `@Attribute(.unique)` on `year`** — CloudKit does not support
///   unique constraints. Uniqueness is enforced by fetch-before-insert in
///   `YearWrappedGenerator`, plus `YearWrappedDeduplicator` for
///   cross-device CloudKit sync convergence.
///
/// - All fields are either optional or have defaults → lightweight migration
///   from V10 is safe.
///
/// ## Stats storage
///
/// Pre-computed card data lives in `statsData` as an encoded `WrappedStats`
/// Codable struct. This keeps the schema compact (one blob instead of ~25
/// scalar columns) and lets the stats shape evolve without schema bumps.
/// Since we only ever fetch YearWrapped by year (never query by individual
/// stat values), the blob is the right trade-off.
///
/// Added in V11.
@Model
final class YearWrapped {

    var id: UUID = UUID()

    /// The calendar year this Wrapped covers (e.g., 2026).
    /// No `@Attribute(.unique)` — see class doc.
    var year: Int = 0

    /// When this snapshot was generated. The deduplicator keeps the row with
    /// the largest immutable `id.uuidString` per year (same survivor on every
    /// device) and uses `(generatedAt, id.uuidString)` only to decide whether
    /// a deleted duplicate's content is newer and gets absorbed onto it,
    /// preserving the earliest `viewedAt`.
    var generatedAt: Date = Date.now

    /// Set when the user first opens this Wrapped on any device.
    /// Syncs via CloudKit → other devices suppress the "ready" banner.
    var viewedAt: Date?

    /// Encoded `WrappedStats` containing all pre-computed card data.
    var statsData: Data?

    /// Year-level narrative paragraph (Card 10), rendered deterministically
    /// from the stats. Rows written before 2026-09-04 may hold a paragraph
    /// the on-device model wrote; the display resolver ignores it whenever
    /// `WrappedStats.narrativeInputs` is present.
    var yearNarrative: String?

    /// How the narrative was produced. Always "deterministic" for new rows;
    /// "foundationModels" survives only on rows from before 2026-09-04.
    var yearNarrativeSourceRaw: String?

    /// Fraction of the year's stays that have weather data (0.0–1.0).
    /// Card 5's LEGACY gate (≥ 0.7) — used only when the stats blob predates
    /// `WrappedStats.weatherExtremesSafe`.
    var weatherCoverage: Double = 0

    /// Fraction of the year's stays with transit != .unknown (0.0–1.0).
    var transitCoverage: Double = 0

    init(year: Int) {
        self.id = UUID()
        self.year = year
        self.generatedAt = .now
    }
}

extension YearWrapped {
    /// The row presentation shows for each year, newest year first. The
    /// deduplicator keeps every row of a year whose survivor id twins share,
    /// so readers collapse by year here: the newest stored generation by
    /// `(generatedAt, id.uuidString)`, the order the deduplicator absorbs
    /// content in, with the physical row breaking a full tie. Settings and
    /// RootView pick the same row; stored rows are never changed.
    static func presented(_ rows: [YearWrapped]) -> [YearWrapped] {
        var byYear: [Int: YearWrapped] = [:]
        for row in rows {
            if let current = byYear[row.year], !isNewerGeneration(row, than: current) { continue }
            byYear[row.year] = row
        }
        return byYear.values.sorted { $0.year > $1.year }
    }

    /// `presented`'s row for one year.
    static func presented(year: Int, in rows: [YearWrapped]) -> YearWrapped? {
        presented(rows.filter { $0.year == year }).first
    }

    /// A year is new until any of its rows was viewed, as the deduplicator
    /// keeps the earliest `viewedAt` across a year's rows.
    static func isNew(year: Int, in rows: [YearWrapped]) -> Bool {
        !rows.contains { $0.year == year && $0.viewedAt != nil }
    }

    private static func isNewerGeneration(_ a: YearWrapped, than b: YearWrapped) -> Bool {
        if a.generatedAt != b.generatedAt { return a.generatedAt > b.generatedAt }
        if a.id != b.id { return a.id.uuidString > b.id.uuidString }
        return a.persistentModelID > b.persistentModelID
    }
}

// MARK: - WrappedStats (Codable blob)

/// Pre-computed card data for all 10 Wrapped cards. Encoded to `Data`
/// and stored in `YearWrapped.statsData`.
///
/// **Forward-compatibility rule: every field added after first ship MUST be
/// `Optional`.** Synthesized `Codable` does NOT fall back to a property's
/// default value for a missing key — only `Optional` properties tolerate
/// absence. A new non-optional field (even a defaulted one like
/// `var x: Int = 0`) makes `decoded(from:)` fail on every blob written
/// before the field existed, silently wiping the user's Wrapped stats on
/// upgrade. `WrappedStatsForwardCompatTests` pins this rule against a
/// frozen pre-upgrade blob.
nonisolated struct WrappedStats: Codable, Sendable {

    // Card 1: Cold open
    var countriesVisited: Int = 0
    var citiesVisited: Int = 0
    var totalDaysAbroad: Int = 0

    // Card 2: Globe (hex indices stored separately — too large for this blob)
    var totalHexesVisited: Int = 0

    // Card 3: Longest trip
    var longestTripName: String?
    var longestTripDays: Int = 0

    /// Start of the longest trip. Nil on blobs written before this field
    /// existed (forward-compat rule), which simply omit the date line.
    var longestTripStartDate: Date?

    // Card 4: Farthest point
    var farthestDistanceKm: Double = 0
    var farthestPlaceName: String?

    // Card 5: Weather superlatives
    var hottestTempC: Double?
    var hottestLocality: String?
    var coldestTempC: Double?
    var coldestLocality: String?
    var rainiestTripName: String?
    var rainiestPrecipitationMm: Double?

    // Card 6: Transit breakdown
    var flightKm: Double = 0
    var driveKm: Double = 0
    var walkKm: Double = 0
    var totalGreatCircleKm: Double = 0

    // Card 7: New countries
    var newCountryCodes: [String] = []
    var mostVisitedCountryCode: String?
    var mostVisitedCountryTripCount: Int = 0

    // Card 8: Time balance
    var daysAbroad: Int = 0
    var daysAtHome: Int = 0

    /// New snapshots count all trip-span dates, including domestic travel.
    /// Absent on historical blobs, which retain their original narrative wording.
    var usesTripSpanDays: Bool?

    /// Days of the year lived at a temporary home outside any trip. They are
    /// part of `daysAbroad` on the snapshots that carry this field. Nil when
    /// no temporary home existed at generation, and on historical blobs.
    var daysStaying: Int?

    // Card 9: Mystery fact
    var mysteryFactText: String?
    var mysteryFact: MysteryFact?

    // Card 10: the structured inputs the deterministic narrative is rendered
    // from, in the viewer's language, at display time. `yearNarrative` on
    // the parent entity holds the English rendering for rows without inputs.
    var narrativeInputs: NarrativeInputs?

    // Metadata
    var tripsCompleted: Int = 0

    /// Whether the measured hottest/coldest were SAFE to display at
    /// generation time: no still-enrichable stay's seasonal ceiling/floor
    /// could plausibly beat them (`WeatherEnrichmentPlanner.extremesAreSafe`,
    /// evaluated at generation time). Replaces the blunt
    /// `weatherCoverage >= 0.7` gate for Card 5 on new artifacts; `nil` on
    /// pre-feature blobs, which keep the coverage gate (forward-compat rule:
    /// post-ship fields must be Optional).
    var weatherExtremesSafe: Bool?
}

extension WrappedStats {
    nonisolated func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// A blob synced from a newer build can carry an optional card this build cannot read
    /// (a new `MysteryFact` case, say), which fails the whole typed decode. Drop only the
    /// unreadable optional cards and retry, so the readable totals still display and the
    /// calendar privacy scrub can still inspect every name it knows. Nil means no retry helps.
    nonisolated static func decoded(from data: Data) -> WrappedStats? {
        let decoder = JSONDecoder()
        if let stats = try? decoder.decode(WrappedStats.self, from: data) { return stats }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func dropUnreadable<Card: Decodable>(_ key: String, as type: Card.Type) {
            guard let value = object[key], !(value is NSNull) else { return }
            if let card = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               (try? decoder.decode(type, from: card)) != nil { return }
            object.removeValue(forKey: key)
        }
        dropUnreadable("mysteryFact", as: MysteryFact.self)
        dropUnreadable("narrativeInputs", as: NarrativeInputs.self)
        guard let repaired = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? decoder.decode(WrappedStats.self, from: repaired)
    }
}
