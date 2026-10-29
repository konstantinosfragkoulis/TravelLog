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
    /// A blank layer (empty or whitespace, as a backup can carry) is a
    /// missing one, as `Stay.placeGroupName` reads it: it never shadows the
    /// locality under it, and a stay with no named layer has no name.
    static func titlePlaceName(
        metro rawMetro: String?, island rawIsland: String?, locality rawLocality: String?,
        country: String?, iso: String?
    ) -> String? {
        titlePlace(metro: rawMetro, island: rawIsland, locality: rawLocality, country: country, iso: iso)?.name
    }

    /// A title place's name with the layer it came from.
    typealias LayeredPlaceName = (name: String, layer: TitlePlaceLayer)

    /// `titlePlaceName` with the layer that gave the name.
    static func titlePlace(
        metro rawMetro: String?, island rawIsland: String?, locality rawLocality: String?,
        country: String?, iso: String?
    ) -> LayeredPlaceName? {
        let metro = TripTitleStore.normalized(rawMetro).map { (name: $0, layer: TitlePlaceLayer.metro) }
        let island = TripTitleStore.normalized(rawIsland).map { (name: $0, layer: TitlePlaceLayer.island) }
        let locality = TripTitleStore.normalized(rawLocality).map { (name: $0, layer: TitlePlaceLayer.locality) }
        // A metro names the stay whatever the island is: skip the check.
        let islandIsCountry = metro == nil
            && island.map { isCountryNamed($0.name, country: country, iso: iso) } ?? false
        return islandIsCountry
            ? locality ?? island
            : metro ?? island ?? locality
    }

    /// Whether an island is named like its own country (Cyprus, Malta).
    private static func isCountryNamed(_ island: String, country: String?, iso: String?) -> Bool {
        let key = TripTitleStore.normalizedPlaceName(island)
        return key == TripTitleStore.normalizedPlaceName(country ?? "")
            || key == TripTitleStore.normalizedPlaceName(
                Locale(identifier: "en_US").localizedString(forRegionCode: iso ?? "") ?? "")
    }

    /// A home-named stay's first layer (metro, island, locality) that is
    /// not a home place, or nil when every layer is. A country-named island
    /// never names it, as in `titlePlaceName`.
    private static func nonHomeLayerName(_ stay: StayInput, homePlaceNames: Set<String>) -> LayeredPlaceName? {
        let island = TripTitleStore.normalized(stay.islandName)
        let countryNamedIsland = island.map {
            isCountryNamed($0, country: stay.country, iso: stay.isoCountryCode)
        } ?? false
        let layers: [LayeredPlaceName?] = [
            TripTitleStore.normalized(stay.metroName).map { (name: $0, layer: TitlePlaceLayer.metro) },
            countryNamedIsland ? nil : island.map { (name: $0, layer: TitlePlaceLayer.island) },
            TripTitleStore.normalized(stay.locality).map { (name: $0, layer: TitlePlaceLayer.locality) },
        ]
        return layers.lazy.compactMap { $0 }.first {
            !TripTitleStore.isHomePlace($0.name, isoCountryCode: stay.isoCountryCode, in: homePlaceNames)
        }
    }

    /// How a trip's titles name each of its stays: `titlePlaceName`, except
    /// on a trip none of whose destinations lies away from home (a day on a
    /// home-metro island, a weekend in a suburb), where a home-named stay is
    /// named by its first layer that is not a home place, so the trip is
    /// titled by where it went rather than left untitled or named after
    /// home. A stay whose every layer is home keeps its name.
    static func titlePlaceNamer(
        stays: [StayInput], homePlaceNames: Set<String>
    ) -> (StayInput) -> String? {
        let namer = titlePlaceLayerNamer(stays: stays, homePlaceNames: homePlaceNames)
        return { namer($0)?.name }
    }

    /// `titlePlaceNamer` with the layer that gave each name.
    static func titlePlaceLayerNamer(
        stays: [StayInput], homePlaceNames: Set<String>
    ) -> (StayInput) -> LayeredPlaceName? {
        let isHome: (StayInput, String) -> Bool = {
            TripTitleStore.isHomePlace($1, isoCountryCode: $0.isoCountryCode, in: homePlaceNames)
        }
        guard !homePlaceNames.isEmpty,
              !stays.contains(where: { stay in
                  category(of: stay) == .destination && titlePlaceName(stay).map { !isHome(stay, $0) } == true
              }) else { return { titlePlace($0) } }
        return { stay in
            guard let place = titlePlace(stay), isHome(stay, place.name) else { return titlePlace(stay) }
            return nonHomeLayerName(stay, homePlaceNames: homePlaceNames) ?? place
        }
    }

    /// Forbid each stay's own country words in validation and title candidates, even if present in locality.
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
    /// "Greece"), which must not be used as a destination or title.
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
        titlePlace(stay)?.name
    }

    /// `titlePlace` over a stay's own fields.
    static func titlePlace(_ stay: StayInput) -> LayeredPlaceName? {
        titlePlace(metro: stay.metroName, island: stay.islandName,
            locality: stay.locality, country: stay.country, iso: stay.isoCountryCode)
    }

    /// Whether a stay's title-level name is one of the trip era's home places.
    /// Exact normalized-name match, never token overlap: a home in "New
    /// York" must not swallow a trip to York. A known country that differs
    /// from every country the home name is known in keeps a foreign namesake.
    static func isHomePlace(_ stay: StayInput, homePlaceNames: Set<String>) -> Bool {
        isHomePlace(stay, named: titlePlaceName(stay), homePlaceNames: homePlaceNames)
    }

    /// `isHomePlace` for a stay named `name` (`titlePlaceNamer`).
    private static func isHomePlace(_ stay: StayInput, named name: String?, homePlaceNames: Set<String>) -> Bool {
        guard !homePlaceNames.isEmpty, let name else { return false }
        return TripTitleStore.isHomePlace(name, isoCountryCode: stay.isoCountryCode, in: homePlaceNames)
    }

    /// Aggregated destination context shared by title grouping and ranking.
    struct PlaceGroup {
        var displayName: String
        var country: String
        /// The first stay's country code: the one a localized title looks the name up in.
        var isoCountryCode: String?
        /// The layer that named its stays; an island when any stay's island did
        /// (`TitlePlaceLayer.mergedLayer`). Nil for a group no layer named.
        var layer: TitlePlaceLayer?
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
    private static func buildGroups(
        from stays: [StayInput], named name: (StayInput) -> LayeredPlaceName?
    ) -> [PlaceGroup] {
        var groups: [PlaceGroup] = []
        for stay in stays {
            let place = name(stay)
            let displayName = place?.name ?? "Unknown"
            let country = stay.country ?? "?"
            let stayCategory = category(of: stay)
            if var last = groups.last,
               last.displayName == displayName,
               last.category == stayCategory,
               last.isAirport == stay.isAirport {
                last.totalMinutes += stay.durationMinutes
                last.lastDate = max(last.lastDate, stay.endTime)
                last.stayCount += 1
                last.layer = TitlePlaceLayer.mergedLayer(last.layer, place?.layer)
                groups[groups.count - 1] = last
            } else {
                groups.append(PlaceGroup(
                    displayName: displayName,
                    country: country,
                    isoCountryCode: stay.isoCountryCode,
                    layer: place?.layer,
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

    typealias PlaceWeight = TripTitleStore.PlaceWeight

    /// The places a title may name, best first (`TripTitleStore.ranksAbove`),
    /// each stay named by `titlePlaceNamer`. Home-named stays are left out
    /// while an away destination remains. Airport-flagged destinations are
    /// offered only when the trip has no other destination: the classifier
    /// said destination, and the airport ring only says where the user
    /// stood. With no destination at all every group is offered and
    /// `isTransitFallback` lets titles decline them.
    struct RankedTitleCandidates {
        var groups: [PlaceGroup]
        var isTransitFallback: Bool
    }

    /// `stays` in `Trip.orderedStays` order; grouping reads them by start time.
    static func rankedTitleCandidates(
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> RankedTitleCandidates {
        let name = titlePlaceLayerNamer(stays: stays, homePlaceNames: homePlaceNames)
        let chronological = stays.sorted { $0.startTime < $1.startTime }
        let nonTransit = chronological.filter { category(of: $0) != .transit }
        let away = nonTransit.filter { !isHomePlace($0, named: name($0)?.name, homePlaceNames: homePlaceNames) }
        let preFiltered: [StayInput]
        if away.contains(where: { category(of: $0) == .destination }) {
            preFiltered = away
        } else {
            preFiltered = nonTransit.isEmpty ? chronological : nonTransit
        }
        let allGroups = buildGroups(from: preFiltered, named: name)
        var candidates = allGroups.filter { $0.category == .destination && !$0.isAirport }
        if candidates.isEmpty {
            candidates = allGroups.filter { $0.category == .destination }
        }
        var isTransitFallback = false
        if candidates.isEmpty {
            candidates = allGroups
            isTransitFallback = true
        }
        // Exclude bare country candidates: validation rejects them and no title may name them.
        let forbiddenCountry = forbiddenCountryWords(countryInputs: stays.map { ($0.country, $0.isoCountryCode) })
        var byName: [String: PlaceGroup] = [:]
        var order: [String] = []
        for group in candidates {
            if group.displayName == "Unknown" { continue }
            if isBareCountryName(group.displayName, forbidden: forbiddenCountry) { continue }
            if var merged = byName[group.displayName] {
                merged.totalMinutes += group.totalMinutes
                merged.stayCount += group.stayCount
                merged.firstDate = min(merged.firstDate, group.firstDate)
                merged.lastDate = max(merged.lastDate, group.lastDate)
                merged.layer = TitlePlaceLayer.mergedLayer(merged.layer, group.layer)
                byName[group.displayName] = merged
            } else {
                byName[group.displayName] = group
                order.append(group.displayName)
            }
        }
        // `order` is visit order: the stays were sorted by start time.
        let weighted = order.enumerated().compactMap { index, name in
            byName[name].map {
                (group: $0, weight: PlaceWeight(
                    minutes: $0.totalMinutes, stayCount: $0.stayCount, visitOrder: index))
            }
        }
        let ranked = weighted.sorted { TripTitleStore.ranksAbove($0.weight, $1.weight) }.map(\.group)
        return RankedTitleCandidates(groups: ranked, isTransitFallback: isTransitFallback)
    }
}
