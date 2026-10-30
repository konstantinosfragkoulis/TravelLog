//
//  TripSearchPlaceNames.swift
//  TravelLog
//

import Foundation
import os

/// What a trip's places are called in other languages, for search only.
/// Stays store the geocoder's English name, but a trip should also be found
/// as "München", "Londres" or "東京". The names come from the bundled
/// offline place-name table (`PlaceNameTable`, GeoNames) in every app
/// language, not only the current one (a Spanish speaker using the app in
/// English still types "Londres"), plus the few common exonyms the table
/// lacks (`TripSearchAliases.placeNameExtras`).
/// Regions ("Andalucía", "Toskana", "沖縄") and island groups ("Cyclades",
/// "Κυκλάδες") read their own layers, never a namesake city's. Documents
/// index them as alternate place and region values
/// (`TripSearchField.alternateOf`).
///
/// Read while documents are built, never per keystroke: each place's names
/// are memoized (bounded), and `TripSearchIndexStore.invalidateAll()` drops
/// the memo with the index. Thread-safe; documents build on and off main.
nonisolated final class TripSearchPlaceNames: Sendable {

    static let shared = TripSearchPlaceNames { key, iso, layer in
        PlaceNameTable.shared.names(for: key, isoCountryCode: iso, layer: layer)
    }

    /// Most places memoized before the memo starts over.
    static let memoLimit = 4096

    /// A place's stored names by table language, for a folded stored name,
    /// an uppercase ISO code and a layer
    /// (`PlaceNameTable.names(for:isoCountryCode:layer:)`).
    private let table: @Sendable (String, String, PlaceNameTable.Layer) -> [String: String]
    private let memo = OSAllocatedUnfairLock(initialState: [String: [String]]())

    init(table: @escaping @Sendable (
        _ key: String, _ isoCountryCode: String, _ layer: PlaceNameTable.Layer) -> [String: String]
    ) {
        self.table = table
    }

    /// The other names of the place stored as `name` in `isoCountryCode`
    /// (with `.island`, an island's; with `.region`, a region's; with
    /// `.group`, those of the island group the city or island `name` lies
    /// in), in a fixed order: [] without a valid country code or any name.
    func names(for name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer = .city) -> [String] {
        guard let iso = TripTitleStore.homeCountryCode(isoCountryCode) else { return [] }
        let key = TripTitleStore.normalizedPlaceName(name)
        guard !key.isEmpty else { return [] }
        let extrasKey = key + "|" + iso
        let memoKey = layer == .city ? extrasKey : extrasKey + "|" + layer.rawValue
        if let names = memo.withLock({ $0[memoKey] }) { return names }
        let names = Self.searchNames(
            stored: lookup(key, iso: iso, layer: layer), extras: TripSearchAliases.placeNameExtras[extrasKey] ?? [],
            suffixes: layer == .region || layer == .group
                ? TripSearchAliases.regionSuffixes : TripSearchAliases.administrativeSuffixes)
        memo.withLock { memo in
            if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
            memo[memoKey] = names
        }
        return names
    }

    /// Forgets every memoized place (Delete All Data).
    func removeAll() {
        memo.withLock { $0.removeAll() }
    }

    /// The table's names for `key`. A metro or locality stored without
    /// "City" also reads the city the table keys with it (a "New York"
    /// metro finds the names of New York City). An island reads its island
    /// rows, and its namesake city's in the languages those lack (Capri has
    /// only a town row). A region or group reads its own rows only.
    private func lookup(_ key: String, iso: String, layer: PlaceNameTable.Layer) -> [String: String] {
        switch layer {
        case .island:
            return table(key, iso, .island).merging(lookup(key, iso: iso, layer: .city)) { island, _ in island }
        case .region, .group:
            return table(key, iso, layer)
        case .city:
            break
        }
        let names = table(key, iso, .city)
        guard names.isEmpty, !key.hasSuffix(" city") else { return names }
        return table(key + " city", iso, .city)
    }

    private static let hantToHans = StringTransform("Hant-Hans")
    private static let hansToHant = StringTransform("Hans-Hant")

    /// The stored names in language order, then `extras`; Chinese in both
    /// scripts (GeoNames files some Traditional names as Simplified and lacks
    /// many Traditional ones, as `PlaceNameTable.name` handles for titles);
    /// each also without its administrative suffix (東京都 → 東京; for a
    /// region or group, `TripSearchAliases.regionSuffixes`).
    /// Trimmed and deduplicated.
    static func searchNames(
        stored: [String: String], extras: [String],
        suffixes: [String] = TripSearchAliases.administrativeSuffixes
    ) -> [String] {
        var values: [String] = []
        for language in stored.keys.sorted() {
            guard let name = stored[language] else { continue }
            values.append(name)
            switch language {
            case "zh-Hans":
                if let simplified = name.applyingTransform(hantToHans, reverse: false) { values.append(simplified) }
                if stored["zh-Hant"] == nil, let traditional = name.applyingTransform(hansToHant, reverse: false) {
                    values.append(traditional)
                }
            case "zh-Hant" where stored["zh-Hans"] == nil:
                if let simplified = name.applyingTransform(hantToHans, reverse: false) { values.append(simplified) }
            default:
                break
            }
        }
        values += extras
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            for form in [value, withoutAdministrativeSuffix(value, suffixes: suffixes)].compactMap({ $0 }) {
                let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted { result.append(trimmed) }
            }
        }
        return result
    }

    /// A Han, kana or Hangul name without its trailing administrative
    /// suffix (`TripSearchAliases.administrativeSuffixes`: 東京都 → 東京,
    /// 뉴욕 시 → 뉴욕; `suffixes` for others), when at least two characters
    /// remain; else nil. Queries use it too, with `islands`
    /// (`TripSearchAliases.islandSuffixes`, `TripSearch.terms`).
    static func withoutAdministrativeSuffix(
        _ name: String, suffixes: [String] = TripSearchAliases.administrativeSuffixes, islands: Bool = false
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = suffixes + (islands ? TripSearchAliases.islandSuffixes : [])
        guard trimmed.unicodeScalars.allSatisfy({ TripSearchText.isCJK($0) || $0.properties.isWhitespace }),
              let suffix = suffixes.first(where: { trimmed.hasSuffix($0) })
        else { return nil }
        let stem = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.count >= 2 ? stem : nil
    }
}
