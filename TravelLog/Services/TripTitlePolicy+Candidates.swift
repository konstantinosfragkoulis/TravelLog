//
//  TripTitlePolicy+Candidates.swift
//  TravelLog
//

import Foundation

nonisolated extension TripTitlePolicy {

    /// The name shared by title grouping and home-place exclusion.
    /// Country-sized island groups (Cyprus, Malta) cannot name a
    /// title: use their actual locality without changing stay grouping
    /// elsewhere. Missing localities still follow the country filter.
    static func titlePlaceName(
        metro: String?, island: String?, locality: String?, country: String?, iso: String?
    ) -> String? {
        // A metro names the stay whatever the island is: skip the check.
        let islandIsCountry = metro == nil && island.map {
            TripTitleStore.normalizedPlaceName($0) == TripTitleStore.normalizedPlaceName(country ?? "")
                || TripTitleStore.normalizedPlaceName($0) == TripTitleStore.normalizedPlaceName(
                    Locale(identifier: "en_US").localizedString(forRegionCode: iso ?? "") ?? "")
        } ?? false
        return islandIsCountry
            ? locality ?? island
            : metro ?? island ?? locality
    }

    /// Forbid each stay's own country words in validation, prompt candidates, and fallback titles, even if present in locality.
    /// Derive from explicit country or the en_US ISO name so unrelated homonyms remain valid.
    /// Exempt SG/VA/GI, whose country names are valid destinations; HK/MO/MC retain district-level names.
    /// Use isoRegions rather than isISORegion, which accepts the ZZ sentinel.
    static func forbiddenCountryWords(countryInputs: [(String?, String?)]) -> Set<String> {
        let cityStateISO: Set<String> = ["SG", "VA", "GI"]
        var forbidden = Set<String>()
        for (country, iso) in countryInputs {
            let code = iso?.uppercased()
            // Apply city-state exemptions before both country-name branches; GeocodeResolver supplies country and ISO together.
            if let code, cityStateISO.contains(code) { continue }
            let forbidCountryName: String? = {
                if let country, !country.isEmpty { return country }
                guard let code, !code.isEmpty,
                      Locale.Region.isoRegions.contains(Locale.Region(code)),
                      let cn = Locale(identifier: "en_US").localizedString(forRegionCode: code),
                      !cn.isEmpty, cn != "Unknown Region" else { return nil }
                return cn
            }()
            if let cn = forbidCountryName, !cn.isEmpty {
                for word in cn.toLatinAsciiStrict.split(whereSeparator: { !$0.isLetter }) {
                    forbidden.insert(word.lowercased())
                }
            }
        }
        return forbidden
    }

    /// True when `displayName`, tokenized like a title, is composed ENTIRELY of
    /// forbidden country-name words — i.e. it's just a bare country (e.g.
    /// "Greece"), which must not be used as a destination or fallback title.
    /// Uses an all-tokens-forbidden test (never substring / any-token) so a
    /// legit multi-word city ("New York") or a city that merely contains a
    /// country substring is never dropped.
    static func isBareCountryName(_ displayName: String, forbidden: Set<String>) -> Bool {
        guard !forbidden.isEmpty else { return false }
        let words = displayName.toLatinAsciiStrict
            .split(whereSeparator: { !$0.isLetter })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        return words.allSatisfy { forbidden.contains($0) }
    }
}
