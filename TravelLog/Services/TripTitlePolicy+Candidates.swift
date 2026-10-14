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

    /// One stay as titles read it: the semantic snapshot's value, in
    /// `Trip.orderedStays` order.
    typealias StayInput = TripTitleStore.SemanticSnapshot.StayInput

    /// `Stay.category` over the stored raw value: an unknown one is unclassified.
    static func category(of stay: StayInput) -> StayCategory {
        StayCategory(rawValue: stay.categoryRaw) ?? .unclassified
    }

    /// `titlePlaceName` over a stay's own fields.
    static func titlePlaceName(_ stay: StayInput) -> String? {
        titlePlaceName(metro: stay.metroName, island: stay.islandName,
            locality: stay.locality, country: stay.country, iso: stay.isoCountryCode)
    }

    /// Whether a stay's title-level name is one of the trip era's home places.
    /// Exact normalized-name match, never token overlap: a home in "New
    /// York" must not swallow a trip to York.
    static func isHomePlace(_ stay: StayInput, homePlaceNames: Set<String>) -> Bool {
        guard !homePlaceNames.isEmpty,
              let name = titlePlaceName(stay) else { return false }
        return homePlaceNames.contains(TripTitleStore.normalizedPlaceName(name))
    }

    /// Aggregated destination context shared by title grouping and ranking.
    struct PromptGroup {
        var displayName: String
        var country: String
        var totalMinutes: Int
        var firstDate: Date
        var lastDate: Date
        var category: StayCategory
        var isAirport: Bool
        var stayCount: Int
    }

    /// Collapse a stay list into adjacent-displayName groups. Stays that
    /// share a title-level name AND a category AND
    /// an airport flag merge into one group; switching any starts a new
    /// group. Order-preserving so a "Madrid → Barcelona → Madrid" round
    /// trip surfaces both cities.
    private static func buildGroups(from stays: [StayInput]) -> [PromptGroup] {
        var groups: [PromptGroup] = []
        for stay in stays {
            let displayName = titlePlaceName(stay) ?? "Unknown"
            let country = stay.country ?? "?"
            let stayCategory = category(of: stay)
            if var last = groups.last,
               last.displayName == displayName,
               last.category == stayCategory,
               last.isAirport == stay.isAirport {
                last.totalMinutes += stay.durationMinutes
                last.lastDate = max(last.lastDate, stay.endTime)
                last.stayCount += 1
                groups[groups.count - 1] = last
            } else {
                groups.append(PromptGroup(
                    displayName: displayName,
                    country: country,
                    totalMinutes: stay.durationMinutes,
                    firstDate: stay.startTime,
                    lastDate: stay.endTime,
                    category: stayCategory,
                    isAirport: stay.isAirport,
                    stayCount: 1
                ))
            }
        }
        return groups
    }

    /// Share ranked candidates between model prompts and deterministic fallback so they agree on visited places.
    /// Exclude home-named stays while an away destination remains; offer all groups when no non-airport destinations remain.
    /// isTransitFallback lets deterministic fallback decline those groups; rank merged names by time, stay count, then first visit.
    struct RankedTitleCandidates {
        var groups: [PromptGroup]
        var isTransitFallback: Bool
    }

    /// `stays` in `Trip.orderedStays` order; grouping reads them by start time.
    static func rankedTitleCandidates(
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> RankedTitleCandidates {
        let chronological = stays.sorted { $0.startTime < $1.startTime }
        let nonTransit = chronological.filter { category(of: $0) != .transit }
        let away = nonTransit.filter { !isHomePlace($0, homePlaceNames: homePlaceNames) }
        let preFiltered: [StayInput]
        if away.contains(where: { category(of: $0) == .destination }) {
            preFiltered = away
        } else {
            preFiltered = nonTransit.isEmpty ? chronological : nonTransit
        }
        let allGroups = buildGroups(from: preFiltered)
        var candidates = allGroups.filter { $0.category == .destination && !$0.isAirport }
        var isTransitFallback = false
        if candidates.isEmpty {
            candidates = allGroups
            isTransitFallback = true
        }
        // Exclude bare country candidates because validation rejects them and fallback must not persist them.
        let forbiddenCountry = forbiddenCountryWords(countryInputs: stays.map { ($0.country, $0.isoCountryCode) })
        var byName: [String: PromptGroup] = [:]
        var order: [String] = []
        for group in candidates {
            if group.displayName == "Unknown" { continue }
            if isBareCountryName(group.displayName, forbidden: forbiddenCountry) { continue }
            if var merged = byName[group.displayName] {
                merged.totalMinutes += group.totalMinutes
                merged.stayCount += group.stayCount
                merged.firstDate = min(merged.firstDate, group.firstDate)
                merged.lastDate = max(merged.lastDate, group.lastDate)
                byName[group.displayName] = merged
            } else {
                byName[group.displayName] = group
                order.append(group.displayName)
            }
        }
        let ranked = order.compactMap { byName[$0] }.sorted { lhs, rhs in
            if lhs.totalMinutes != rhs.totalMinutes { return lhs.totalMinutes > rhs.totalMinutes }
            if lhs.stayCount != rhs.stayCount { return lhs.stayCount > rhs.stayCount }
            return lhs.firstDate < rhs.firstDate
        }
        return RankedTitleCandidates(groups: ranked, isTransitFallback: isTransitFallback)
    }
}
