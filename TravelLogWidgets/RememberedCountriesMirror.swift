//
//  RememberedCountriesMirror.swift
//  TravelLogWidgets
//
//  Widget-side reader for the remembered pre-TravelLog countries.
//
//  `StatsAggregator.passportData`'s `countries` field is deliberately
//  tracked-only, and the CALLER owes the remembered-countries union, or a
//  widget shows a LOWER "Countries" number than the app's own Passport card
//  for the same account. `StatsView` does the union itself; the widgets
//  cannot read the checklist directly: it lives in
//  `NSUbiquitousKeyValueStore`, and this extension holds only the App Group
//  entitlement, not the ubiquity-KVS one.
//
//  The app therefore mirrors the checklist into the shared App Group
//  container on every load and save (`RememberedCountriesStorage`), and this
//  reads that copy. iCloud stays the source of truth; nothing here writes.
//  Deliberately a small local reader rather than sharing the storage type
//  with this target.
//

import Foundation

enum RememberedCountriesMirror {

    /// Must match `RememberedCountriesStorage.appGroupMirrorKey`.
    static let mirrorKey = "rememberedCountryCodesMirror_v1"

    /// Uppercased ISO alpha-2 codes, or empty when the app has not mirrored
    /// yet (fresh install, or an install predating the mirror).
    static func codes(appGroupIdentifier: String) -> Set<String> {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: mirrorKey),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(strings.map { $0.uppercased() })
    }
}
