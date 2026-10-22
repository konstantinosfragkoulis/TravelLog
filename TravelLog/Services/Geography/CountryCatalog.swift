//
//  CountryCatalog.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 16/7/26.
//

import Foundation

/// Pure reference data + math behind the Stats page's coverage statistics:
/// what share of the world (and of each country) the explored hexes cover,
/// and how many of the world's countries the passport has seen.
///
/// The data tables (`areaKm2`, `unMembers`, `sovereignOfTerritory`,
/// `isoCodeTotal`) live in the GENERATED `CountryCatalogData.swift` —
/// regenerate with `scripts/build-country-catalog.py`, never edit by hand.
nonisolated enum CountryCatalog {

    // MARK: - H3 resolution-6 facts

    /// Exact number of H3 cells at resolution 6 (`H3Service.resolution`,
    /// the app-wide resolution) — the canonical figure from the H3
    /// cell-count table.
    static let res6CellCount = 14_117_882

    /// Mean res-6 cell area: Earth's ~510.066M km² surface ÷ cell count.
    /// Matches the 36.13 the Exploration card already multiplies by.
    static let averageHexAreaKm2 = 36.129

    /// ≈ res-6 cells over land: Earth's land ≈ 148.94M km² (29.2% of the
    /// surface) ÷ mean cell area. An estimate by definition — cells
    /// straddle coastlines — so the UI renders it behind a ≈.
    static let res6LandCellEstimate = 4_122_000

    /// UN member states — the "X of 193 countries" denominator.
    static let unMemberTotal = 193

    // MARK: - World coverage

    /// Fraction (0…1) of all res-6 cells the explored count covers.
    static func fractionOfEarth(hexCount: Int) -> Double {
        min(1, Double(max(0, hexCount)) / Double(res6CellCount))
    }

    /// Fraction (0…1) of LAND res-6 cells. Ferry/open-water hexes stay in
    /// the numerator — a handful of cells against a 4.1M denominator.
    static func fractionOfLand(hexCount: Int) -> Double {
        min(1, Double(max(0, hexCount)) / Double(res6LandCellEstimate))
    }

    /// % of a country's area the explored hexes cover, capped at 100 (a
    /// microstate smaller than one hex would otherwise exceed it). `nil`
    /// when the code has no area entry — the row just omits its %.
    static func coveragePercent(code: String, hexCount: Int) -> Double? {
        coveragePercent(hexCount: hexCount, areaKm2: area(code: code))
    }

    /// The same share against a supplied country area; `nil` without one.
    static func coveragePercent(hexCount: Int, areaKm2 area: Double?) -> Double? {
        guard let area, area > 0 else { return nil }
        return min(100, Double(max(0, hexCount)) * averageHexAreaKm2 / area * 100)
    }

    /// The country's area in km², `nil` when the catalog has no entry.
    static func area(code: String) -> Double? {
        areaKm2[code.uppercased()]
    }

    /// About how many res-6 hexes a country of this area holds, by the mean
    /// cell area, to two significant figures (an estimate, shown behind
    /// "about"). At least one, so a microstate still has a denominator.
    static func estimatedHexCount(areaKm2 area: Double) -> Int {
        let cells = max(1, area / averageHexAreaKm2)
        guard cells >= 100 else { return max(1, Int(cells.rounded())) }
        let magnitude = pow(10, floor(log10(cells)) - 1)
        return Int((cells / magnitude).rounded() * magnitude)
    }

    // MARK: - Country counting

    /// Distinct UN members the visited codes cover: members count as
    /// themselves, dependent territories fold into their sovereign
    /// (Puerto Rico → US, Greenland → DK), and non-member codes
    /// (TW, XK, VA, PS, AQ, EH) drop out — those count only on the
    /// countries-&-territories stat, whose numerator is plain
    /// `codes.count` against `isoCodeTotal`.
    static func unMemberCount(of codes: Set<String>) -> Int {
        var members = Set<String>()
        for code in codes {
            let upper = code.uppercased()
            if unMembers.contains(upper) {
                members.insert(upper)
            } else if let sovereign = sovereignOfTerritory[upper] {
                members.insert(sovereign)
            }
        }
        return members.count
    }

    // MARK: - Formatting

    /// A fraction as a percentage with two significant figures below 1% —
    /// "0.021%", not "0.02%" (one figure hides a 2× difference) and not
    /// "0.0210419%" (noise). Whole percents above 10, one decimal in
    /// between.
    static func percentText(_ fraction: Double, locale: Locale = .current) -> String {
        let percent = fraction * 100
        guard percent > 0 else {
            return String(localized: "stats.percentage.zero", defaultValue: "0%", locale: locale, comment: "Zero percent value.")
        }
        guard percent < 100 else {
            return String(localized: "stats.percentage.complete", defaultValue: "100%", locale: locale, comment: "One hundred percent value.")
        }
        let decimals: Int
        if percent >= 10 {
            decimals = 0
        } else if percent >= 1 {
            decimals = 1
        } else {
            decimals = Int(ceil(-log10(percent))) + 1
        }
        let value = percent.formatted(
            FloatingPointFormatStyle<Double>.number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(decimals))
        )
        return String(
            localized: "stats.percentage.value",
            defaultValue: "\(value)%",
            locale: locale,
            comment: "Percentage value with a preformatted decimal number."
        )
    }

    /// Country coverage for row display: one decimal under 10%, whole
    /// percents above, with a "<0.1%" floor so a single hex in Russia
    /// never reads "0.0%".
    static func countryPercentText(_ percent: Double, locale: Locale = .current) -> String {
        guard percent > 0 else {
            return String(localized: "stats.country-percentage.zero", defaultValue: "0%", locale: locale, comment: "Zero country coverage.")
        }
        guard percent >= 0.1 else {
            // The floor is a number like its neighbours: "<0,1%" where the locale writes a decimal comma.
            let floor = 0.1.formatted(
                FloatingPointFormatStyle<Double>.number
                    .locale(locale)
                    .grouping(.never)
                    .precision(.fractionLength(1))
            )
            return String(
                localized: "stats.country-percentage.below",
                defaultValue: "<\(floor)%",
                locale: locale,
                comment: "Country coverage below one tenth of one percent. The placeholder is 0.1, formatted for the locale."
            )
        }
        guard percent < 99.95 else {
            return String(localized: "stats.country-percentage.complete", defaultValue: "100%", locale: locale, comment: "Complete country coverage.")
        }
        // Clamp the whole-percent branch at 99: `%.0f` rounds [99.5, 99.95)
        // up to "100", showing full coverage for a country that isn't.
        // "100%" is reserved for the short-circuit above.
        if percent >= 10 {
            return String(
                localized: "stats.country-percentage.whole",
                defaultValue: "\(min(99, Int(percent.rounded())), format: .number.grouping(.never))%",
                locale: locale,
                comment: "Country coverage as a whole-number percentage."
            )
        }
        let value = percent.formatted(
            FloatingPointFormatStyle<Double>.number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(1))
        )
        return String(
            localized: "stats.country-percentage.decimal",
            defaultValue: "\(value)%",
            locale: locale,
            comment: "Country coverage as a preformatted decimal percentage."
        )
    }
}
