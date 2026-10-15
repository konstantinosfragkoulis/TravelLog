//
//  RememberedCountriesPicker.swift
//  TravelLog
//

import SwiftUI

/// One-time checklist for countries visited before TravelLog existed —
/// see `RememberedCountriesStorage` for the rationale. Tracked countries
/// (real stays/trips) are listed read-only with a checkmark so the user
/// doesn't wonder where Greece went; everything else toggles.
struct RememberedCountriesPicker: View {

    /// ISO codes the app already KNOWS about from tracked/imported data —
    /// shown locked at the top, not toggleable (real data always wins).
    let trackedCodes: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery: String = ""
    @State private var selectableMemo = SearchMemo<ListSearchKey<String>, [(code: String, name: String)]>()
    @State private var indexMemo = SearchMemo<ListSearchKey<String>, ListSearchIndex<String>>()

    private let storage = RememberedCountriesStorage.shared

    /// Every ISO 3166-1 alpha-2 region with a localized name, minus the
    /// tracked set, alphabetized by display name. Computed once per tracked
    /// set and app language.
    private var selectableCountries: [(code: String, name: String)] {
        let key = ListSearchKey(entries: trackedCodes.sorted(), languageTag: AppLanguagePreference.currentTag())
        return selectableMemo.value(for: key) {
            let locale = AppLanguagePreference.currentLocale()
            return Locale.Region.isoRegions
                .map(\.identifier)
                .filter { RememberedCountriesStorage.isValidCode($0) && !trackedCodes.contains($0) }
                .compactMap { code in
                    locale.localizedString(forRegionCode: code).map { (code, $0) }
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Codes in either section that match the query (one index over both),
    /// nil when not searching.
    private var matchingCodes: Set<String>? {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let codes = selectableCountries.map(\.code) + trackedCodes.sorted()
        let languageTag = AppLanguagePreference.currentTag()
        let index = indexMemo.value(for: ListSearchKey(entries: codes, languageTag: languageTag)) {
            Self.searchIndex(codes: codes, languageTag: languageTag)
        }
        return Set(index.matching(searchQuery))
    }

    var body: some View {
        let matches = matchingCodes
        let filteredCountries: [(code: String, name: String)] = matches.map { codes in
            selectableCountries.filter { codes.contains($0.code) }
        } ?? selectableCountries
        // Tracked countries stay visible while searching, filtered by the
        // same query, so a search for Greece shows it as already counted.
        let shownTracked = trackedCodes.sorted().filter { matches?.contains($0) ?? true }
        NavigationStack {
            List {
                if let matches, matches.isEmpty {
                    ContentUnavailableView.search(text: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    Section {
                        ForEach(filteredCountries, id: \.code) { entry in
                            Button {
                                storage.toggle(entry.code)
                            } label: {
                                HStack {
                                    Text(flagEmoji(for: entry.code) ?? "🏳️")
                                        .font(.title3)
                                        .accessibilityHidden(true)
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if storage.contains(entry.code) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .fontWeight(.semibold)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            // VoiceOver reads "Country name, selected" rather than the decorations.
                            .accessibilityAddTraits(storage.contains(entry.code) ? .isSelected : [])
                        }
                    } header: {
                        let added = storage.codes.subtracting(trackedCodes).count
                        Text(added == 1
                             ? String(localized: "remembered-countries.added.one", defaultValue: "\(added, format: .number.grouping(.never)) added", comment: "Earlier Travels picker header when one remembered country is added.")
                             : String(localized: "remembered-countries.added.other", defaultValue: "\(added, format: .number.grouping(.never)) added", comment: "Earlier Travels picker header when zero or multiple remembered countries are added."))
                    } footer: {
                        Text("Countries you visited before Travel Log could track them. They count toward your passport and light up on the globe. No dates needed, and they never create trips.")
                    }

                    if !shownTracked.isEmpty {
                        Section {
                            ForEach(shownTracked, id: \.self) { code in
                                HStack {
                                    Text(flagEmoji(for: code) ?? "🏳️")
                                        .font(.title3)
                                    Text(AppLanguagePreference.currentLocale()
                                        .localizedString(forRegionCode: code) ?? code)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.tint.opacity(0.6))
                                }
                            }
                        } header: {
                            Text("Already in your travels")
                        } footer: {
                            Text("These come from your tracked and imported trips.")
                        }
                    }
                }
            }
            .navigationTitle("Earlier Travels")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: Text("Search countries"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

extension RememberedCountriesPicker {
    #if DEBUG
    /// True when `query` finds `code` through the country search both
    /// country pickers use (see `searchIndex(codes:languageTag:)`).
    nonisolated static func matchesSearch(
        code: String,
        query: String,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        !searchIndex(codes: [code], languageTag: languageTag).matching(query).isEmpty
    }
    #endif

    /// One document per ISO code: the code, English and app-language names
    /// and curated aliases as countries, `countryCodes = [code]`. Country
    /// names in other supported languages ("Grèce"), region words ("europe")
    /// and small typos ("Grece") find it.
    nonisolated static func searchIndex(codes: [String], languageTag: String) -> ListSearchIndex<String> {
        ListSearchIndex(entries: codes, languageTag: languageTag) { code in
            ([], TripSearch.countryAliases(for: [code], languageTag: languageTag), [code])
        }
    }
}
