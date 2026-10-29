//
//  TripTitlePolicy.swift
//  TravelLog
//

import Foundation

/// The value-only half of canonical trip titles: how places are ranked and
/// a title is composed, spelled and validated. Every title is derived here,
/// deterministically, from the trip's stays and the home places of its era.
/// It reads no model, context or defaults, so callers keep every storage
/// read and write and tests call it directly.
nonisolated enum TripTitlePolicy {

    /// The most places a title names.
    static let maximumTitlePlaces = 3

    /// Format up to three places: "A", "A & B", "A, B & C". A blank or
    /// repeated name is dropped rather than leaving a dangling separator.
    static func composeTitle(places: [String]) -> String {
        let names = titleNameIndices(places).map {
            places[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !names.isEmpty else { return "" }
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) & \(names[2])"
        }
    }

    /// The indices of the names `composeTitle` keeps: the first
    /// `maximumTitlePlaces` that are neither blank nor a repeat.
    private static func titleNameIndices(_ places: [String]) -> [Int] {
        var seen = Set<String>()
        var indices: [Int] = []
        for (index, raw) in places.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            indices.append(index)
            if indices.count == maximumTitlePlaces { break }
        }
        return indices
    }

    /// The spelling a canonical title stores for a place: its display name
    /// in the geocoder's stored form (`toLatinAscii`: Latin, diacritics
    /// stripped, letters such as ø and ł kept), so "Tromsø" stays Tromsø
    /// and an imported "Σύρος" becomes Syros.
    static func canonicalTitleSpelling(_ displayName: String) -> String {
        displayName.toLatinAscii
    }

    /// Why a composed title cannot be stored; nil from validation means it can.
    nonisolated enum ValidationFailure: Equatable {
        case empty
        case tooShort
        case tooLong
        case containsErrorWord(String)
        case multiLine
        case tooManyWords(Int)
        case forbiddenCountryWord(String)
        case ungroundedWord(String)
        case noGroundedWord(String)
        /// Grounded place words can still omit the time-dominant place, which needs a distinct rejection reason.
        case missingTopPlace(String)
        /// A word naming the user's home area: a home-named stay the
        /// candidates deliberately left out (`TripTitleStore.homePlaceNames`).
        case homePlaceWord(String)
    }

    /// The titles a trip's stays can take, the default first: the
    /// `maximumTitlePlaces` best-ranked places, then the best two, then the
    /// best one (each in `titleOrder`), then the region every named
    /// place shares, when there is one. A composition the title policy
    /// rejects is left out, so the default is the first that passes. Empty
    /// for a trip with no destination and when no place resolved
    /// to a name: the generated title then stays nil and `Trip.displayName`
    /// falls through to `destinationSummary`. A stored generated title
    /// stands while it is the first (`TripTitleStore.titleStands`).
    static func titleAlternatives(
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> [String] {
        titleOptions(stays: stays, homePlaceNames: homePlaceNames).map(\.title)
    }

    /// The layer of a stay's place that names it in a title: its metro,
    /// island or locality (`titlePlace`), or the region a title names for
    /// every place. A localized title looks an island up in the place-name
    /// table's island rows and any other layer in its city rows
    /// (`PlaceNameTable.name(for:languageTag:)`).
    enum TitlePlaceLayer: Equatable, Sendable {
        case metro, island, locality, region

        /// The layer of a group whose stays two layers named: an island when
        /// either is, so a town named like its island never lends it its name.
        static func mergedLayer(_ lhs: TitlePlaceLayer?, _ rhs: TitlePlaceLayer?) -> TitlePlaceLayer? {
            lhs == .island || rhs == .island ? .island : lhs ?? rhs
        }
    }

    /// One place a title names: its stored name, its stay's country and the
    /// layer that named it.
    struct TitlePlace: Equatable {
        let name: String
        let isoCountryCode: String?
        let layer: TitlePlaceLayer?
    }

    /// One of `titleAlternatives` with the places it names, in title order.
    struct TitleOption: Equatable {
        let title: String
        let places: [TitlePlace]
    }

    /// `titleAlternatives` with the places each names.
    static func titleOptions(
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> [TitleOption] {
        let ranked = rankedTitleCandidates(stays: stays, homePlaceNames: homePlaceNames)
        guard !ranked.isTransitFallback, !ranked.groups.isEmpty else { return [] }
        var options: [TitleOption] = []
        for count in stride(from: min(maximumTitlePlaces, ranked.groups.count), through: 1, by: -1) {
            let groups = titleOrder(Array(ranked.groups.prefix(count)))
            let names = groups.map { canonicalTitleSpelling($0.displayName) }
            let title = composeTitle(places: names)
            guard !title.isEmpty, !options.contains(where: { $0.title == title }),
                  titleValidationFailure(title, stays: stays, homePlaceNames: homePlaceNames) == nil else {
                continue
            }
            options.append(TitleOption(title: title, places: titleNameIndices(names).map {
                TitlePlace(
                    name: groups[$0].displayName, isoCountryCode: groups[$0].isoCountryCode,
                    layer: groups[$0].layer)
            }))
        }
        if let region = sharedRegion(ranked.groups, stays: stays, homePlaceNames: homePlaceNames),
           !options.isEmpty, !options.contains(where: { $0.title == region.title }) {
            options.append(region)
        }
        return options
    }

    /// `groups`, best-ranked first, in the order a title names them: visit
    /// order, except that a base holding at least two thirds of their time
    /// leads ("Rome & Florence" for a week in Rome with a day trip before it).
    private static func titleOrder(_ groups: [PlaceGroup]) -> [PlaceGroup] {
        let visitOrder = groups.sorted { $0.firstDate < $1.firstDate }
        guard groups.count > 1, let top = groups.first,
              3 * top.totalMinutes >= 2 * groups.reduce(0, { $0 + $1.totalMinutes }) else { return visitOrder }
        return [top] + visitOrder.filter { $0.displayName != top.displayName }
    }

    /// The trip's title in `languageTag`: the places of the option whose
    /// title is `canonicalTitle`, each named by `placeName` (nil keeps its
    /// canonical spelling), in the language's list connectors. Nil when
    /// `canonicalTitle` is none of the trip's `titleOptions`, since then
    /// nothing says which places it names.
    static func localizedTitle(
        canonicalTitle: String,
        stays: [StayInput],
        homePlaceNames: Set<String>,
        languageTag: String,
        placeName: (TitlePlace) -> String?
    ) -> String? {
        guard let option = titleOptions(stays: stays, homePlaceNames: homePlaceNames)
            .first(where: { $0.title == canonicalTitle }) else { return nil }
        let names = option.places.map { place in
            placeName(place) ?? canonicalTitleSpelling(place.name)
        }
        return Trip.placeList(names, languageTag: languageTag)
    }

    /// The trip's default title (`titleAlternatives`' first), or nil.
    static func defaultTitle(
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> String? {
        titleAlternatives(stays: stays, homePlaceNames: homePlaceNames).first
    }

    /// The administrative region (a state, province or island region) that
    /// every stay of two or more named places lies in, as a title, or nil.
    /// It must not be a country, a home place or one of the places itself,
    /// and it must pass the title policy's form and grounding checks; it
    /// need not name the top place, since it names all of them.
    private static func sharedRegion(
        _ groups: [PlaceGroup],
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> TitleOption? {
        guard groups.count > 1 else { return nil }
        let names = Set(groups.map(\.displayName))
        let placeStays = stays.filter { stay in
            category(of: stay) == .destination && !stay.isAirport
                && titlePlaceName(stay).map(names.contains) == true
        }
        var regions = Set<String>()
        for stay in placeStays {
            guard let region = TripTitleStore.normalized(stay.administrativeArea) else { return nil }
            regions.insert(region)
        }
        guard regions.count == 1, let region = regions.first else { return nil }
        let key = TripTitleStore.normalizedPlaceName(region)
        guard !names.contains(where: { TripTitleStore.normalizedPlaceName($0) == key }),
              !placeStays.contains(where: {
                  TripTitleStore.isHomePlace(region, isoCountryCode: $0.isoCountryCode, in: homePlaceNames)
              }) else { return nil }
        let title = canonicalTitleSpelling(region)
        guard formFailure(title) == nil,
              ungroundedTitleFailure(title, stays: stays, homePlaceNames: homePlaceNames) == nil else {
            return nil
        }
        return TitleOption(
            title: title,
            places: [TitlePlace(name: region, isoCountryCode: placeStays.first?.isoCountryCode, layer: .region)])
    }
}
