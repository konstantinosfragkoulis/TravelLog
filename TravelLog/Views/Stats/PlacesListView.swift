//
//  PlacesListView.swift
//  TravelLog
//
//  Collections > Places: how many places in how many countries, chips
//  filtering by kind, the places first visited this year, then every
//  place ranked (or A to Z) with its days, first year, trips and a bar
//  against the most visited. Search (`searchIndex`) narrows all of it.
//

import SwiftUI

struct PlacesListView: View {
    typealias Place = CollectionsAggregator.PlaceEntry
    typealias Kind = CollectionsAggregator.PlaceKind

    let places: [Place]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .mostVisited
    /// The kind chip on; nil for All.
    @State private var kind: Kind?
    @State private var preparedIndex: ListSearchIndex<Place>?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// New This Year shows at most this many tiles, newest first.
    private static let newTileLimit = 9

    enum SortOrder: String, CaseIterable {
        case mostVisited = "mostVisited"
        case alphabetical = "alphabetical"

        var displayName: String {
            switch self {
            case .mostVisited:
                String(localized: "collections.places.sort.most-visited", defaultValue: "Most Visited", comment: "Places collection sort order for most visited first.")
            case .alphabetical:
                String(localized: "collections.places.sort.alphabetical", defaultValue: "A to Z", comment: "Places collection sort order for alphabetical order.")
            }
        }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The places the search keeps, in the aggregator's most-visited order.
    private var searched: [Place] {
        // Keep the unfiltered list visible while the current index prepares.
        if !query.isEmpty, let index = preparedIndex,
           index.entries == places, index.languageTag == AppLanguagePreference.currentTag() {
            return index.matching(searchText)
        }
        return places
    }

    private func displayed(_ searched: [Place]) -> [Place] {
        var result = searched
        if let kind { result = result.filter { $0.kind == kind } }
        if sortOrder == .alphabetical {
            result = result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return result // aggregator order IS most-visited
    }

    var body: some View {
        let languageTag = AppLanguagePreference.currentTag()
        let searched = searched
        let shown = displayed(searched)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if places.isEmpty {
                    ContentUnavailableView(
                        "No Places Yet",
                        systemImage: "building.2",
                        description: Text(String(localized: "collections.places.empty.description", defaultValue: "Cities, towns, and islands from your trips appear here.", comment: "Places collection empty-state description; the list holds trip destinations only."))
                    )
                    .padding(.top, 60)
                } else {
                    if !searched.isEmpty {
                        lead(searched)
                        kindChips(searched)
                            .padding(.top, 12)
                    }
                    if query.isEmpty {
                        newThisYear(places.filter { kind == nil || $0.kind == kind })
                    }
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 24)
                    } else {
                        ranked(shown)
                    }
                }
            }
            .padding(.horizontal, AppTheme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Place or country")
        .task(id: ListSearchKey(entries: places, languageTag: languageTag)) {
            if let index = preparedIndex, index.entries == places, index.languageTag == languageTag { return }
            let places = places
            let build = Task.detached(priority: .userInitiated) {
                Self.searchIndex(places, languageTag: languageTag)
            }
            let index = await build.value
            guard !Task.isCancelled else { return }
            preparedIndex = index
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A bare menu-style Picker stretches to its widest option
                // in the toolbar; wrapping it in a Menu keeps the control
                // icon-sized.
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .accessibilityLabel("Sort order")
                }
            }
        }
    }

    // MARK: Summary

    /// "340 places in 41 countries"; while searching, of the matches.
    private func lead(_ places: [Place]) -> some View {
        let count = places.count
        let countries = PassportText.countries(PlacesDisplay.countryCount(places))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: StatsText.grouped(count))
                .font(AppTheme.stat(.largeTitle))
            Text(count == 1
                 ? String(localized: "collections.places.lead.one", defaultValue: "place in \(countries)", comment: "Places page summary beside the large number of places, for one place; the placeholder is a number of countries, such as 1 country.")
                 : String(localized: "collections.places.lead.other", defaultValue: "places in \(countries)", comment: "Places page summary beside the large number of places, for several places; the placeholder is a number of countries, such as 41 countries."))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
    }

    /// All, then each kind present with its count. The chip on stays
    /// while a search leaves it nothing, so it can be turned off.
    private func kindChips(_ places: [Place]) -> some View {
        var counts = PlacesDisplay.kindCounts(places)
        if let kind, !counts.contains(where: { $0.kind == kind }) {
            counts.append(PlacesDisplay.KindCount(kind: kind, count: 0))
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                kindChip(String(localized: "collections.places.kind.all", defaultValue: "All", comment: "Places page filter chip showing places of every kind."),
                         count: places.count, isOn: kind == nil) { kind = nil }
                ForEach(counts, id: \.kind) { entry in
                    kindChip(Self.kindsLabel(entry.kind), count: entry.count, isOn: kind == entry.kind) {
                        kind = kind == entry.kind ? nil : entry.kind
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func kindChip(_ label: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .fontWeight(.semibold)
                Text(verbatim: StatsText.grouped(count))
                    .fontWeight(.medium)
                    .foregroundStyle(isOn ? Color.white.opacity(0.78) : Color.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(isOn ? AppTheme.cobaltFill : AppTheme.inset, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: New this year

    @ViewBuilder
    private func newThisYear(_ places: [Place]) -> some View {
        let new = PlacesDisplay.newThisYear(places)
        if !new.isEmpty {
            let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 3
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppTheme.saffron)
                            .accessibilityHidden(true)
                        Text(String(localized: "collections.places.new-this-year", defaultValue: "New This Year", comment: "Places page section title over the places first visited this calendar year."))
                    }
                } trailing: {
                    Text(verbatim: StatsText.grouped(new.count))
                        .foregroundStyle(AppTheme.saffronText)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns),
                          spacing: 8) {
                    ForEach(new.prefix(Self.newTileLimit)) { place in
                        newTile(place)
                    }
                }
            }
        }
    }

    private func newTile(_ place: Place) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            FlagView(iso: place.isoCountryCode, size: .regular)
                .padding(.bottom, 8)
            Text(verbatim: place.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(verbatim: "\(Self.kindLabel(place.kind)) · \(StatsText.days(place.dayCount))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(place.firstVisit, format: .dateTime.month(.abbreviated).year())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.saffronText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: shape)
        .overlay(shape.strokeBorder(AppTheme.saffronEdge, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Ranked list

    private func ranked(_ shown: [Place]) -> some View {
        let top = max(shown.map(\.tripCount).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader {
                Text(sortOrder.displayName)
            } trailing: {
                if sortOrder == .mostVisited {
                    Text(String(localized: "collections.places.by-trips", defaultValue: "By trips", comment: "Places page: beside Most Visited, the list ranks places by their number of trips."))
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, place in
                    if index > 0 {
                        Divider().padding(.leading, 64)
                    }
                    placeRow(place, share: Double(place.tripCount) / Double(top))
                }
            }
            .background(AppTheme.card, in: .rect(cornerRadius: AppTheme.cardRadius))
        }
    }

    private func placeRow(_ place: Place, share: Double) -> some View {
        let year = Calendar.current.component(.year, from: place.firstVisit)
        let meta = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 7))
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                FlagView(iso: place.isoCountryCode, size: .large)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: place.name)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    meta {
                        kindChip(place.kind)
                        Text(verbatim: "\(StatsText.days(place.dayCount)) · \(CollectionsText.since(year))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                    .padding(.top, 4)
                    if !place.localities.isEmpty {
                        Text(includesLine(place.localities))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: StatsText.grouped(place.tripCount))
                        .font(AppTheme.stat(.title3))
                    Text(place.tripCount == 1
                         ? String(localized: "collections.places.trips-unit.one", defaultValue: "trip", comment: "Places page row: unit under the number of trips to a place, for one; the number is shown separately.")
                         : String(localized: "collections.places.trips-unit.other", defaultValue: "trips", comment: "Places page row: unit under the number of trips to a place, for several; the number is shown separately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .padding(.top, 1)
            }
            Capsule()
                .fill(AppTheme.inset)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(AppTheme.bar)
                            .frame(width: max(4, geometry.size.width * share))
                    }
                }
                .padding(.leading, 48)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func includesLine(_ localities: [String]) -> String {
        let shown = localities.prefix(3).joined(separator: ", ")
        let extra = localities.count - min(localities.count, 3)
        guard extra > 0 else {
            return String(localized: "collections.place.includes", defaultValue: "Includes \(shown)", comment: "Place row detail listing included localities without an additional count.")
        }
        return extra == 1
            ? String(localized: "collections.place.includes-more.one", defaultValue: "Includes \(shown) +\(extra, format: .number.grouping(.never))", comment: "Place row detail listing localities and one additional locality.")
            : String(localized: "collections.place.includes-more.other", defaultValue: "Includes \(shown) +\(extra, format: .number.grouping(.never))", comment: "Place row detail listing localities and multiple additional localities.")
    }

    private func kindChip(_ kind: Kind) -> some View {
        Text(Self.kindLabel(kind))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(AppTheme.inset, in: .capsule)
            .fixedSize()
    }

    private static func kindLabel(_ kind: Kind) -> String {
        switch kind {
        case .metro: String(localized: "collections.place-kind.city", defaultValue: "City", comment: "Places collection kind label for a metropolitan city.")
        case .island: String(localized: "collections.place-kind.island", defaultValue: "Island", comment: "Places collection kind label for an island.")
        case .locality: String(localized: "collections.place-kind.town", defaultValue: "Town", comment: "Places collection kind label for a town or locality.")
        case .area: String(localized: "collections.place-kind.area", defaultValue: "Area", comment: "Places collection kind label for a broader area.")
        }
    }

    /// A kind filter chip's name: the plural.
    private static func kindsLabel(_ kind: Kind) -> String {
        switch kind {
        case .metro: String(localized: "collections.places.kind.cities", defaultValue: "Cities", comment: "Places page filter chip showing only cities.")
        case .island: String(localized: "collections.places.kind.islands", defaultValue: "Islands", comment: "Places page filter chip showing only islands.")
        case .locality: String(localized: "collections.places.kind.towns", defaultValue: "Towns", comment: "Places page filter chip showing only towns.")
        case .area: String(localized: "collections.places.kind.areas", defaultValue: "Areas", comment: "Places page filter chip showing only broader areas.")
        }
    }

    private func sectionHeader<Title: View, Trailing: View>(
        @ViewBuilder _ title: () -> Title, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            title()
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            trailing()
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 26)
        .padding(.bottom, 9)
    }
}
