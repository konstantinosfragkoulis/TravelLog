//
//  AirportsListView.swift
//  TravelLog
//
//  Collections > Airports: a map of every airport (filled where the user
//  flew through, a hollow ring where they only set foot) under a switch
//  between their busiest region and the world, then one card per country
//  with a chip per airport. A tapped station or chip selects the airport
//  and names it on the map. Search narrows the cards (`matchingAirports`).
//  A menu in the bar picks the world or a continent holding airports.
//

import SwiftUI

struct AirportsListView: View {
    typealias Airport = CollectionsAggregator.AirportEntry

    let airports: [Airport]
    @State private var searchText = ""
    @State private var indexMemo = SearchMemo<
        ListSearchKey<Airport>,
        ListSearchIndex<Airport>>()
    @State private var preparedMemo = SearchMemo<[Airport], Prepared>()
    @State private var selection: String?
    /// The region the user picked; nil for the opening one (`Prepared.region`).
    @State private var chosenRegion: Region?
    @State private var isPastMap = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The map's height, the status bar and navigation buttons included.
    static let mapHeight: CGFloat = 440
    /// How far the title rises into the map's fade.
    private static let titleOverlap: CGFloat = 36
    private static let mapID = "airports.map"

    /// What the map frames: every airport, or one continent's.
    private enum Region: Hashable {
        case world
        case continent(String)
    }

    /// What the page derives once per list: the cards, the regions and
    /// the stations.
    private struct Prepared {
        let cards: [AirportsDisplay.CountryCard]
        /// The busiest continent, when the airports span more than one.
        let region: String?
        /// The continents holding airports, most visited first.
        let regions: [String]
        let marks: [OutlineMapMark]
        let continents: [String: String]

        /// The region the map opens on.
        var opening: Region { region.map(Region.continent) ?? .world }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [Airport] {
        guard !query.isEmpty else { return airports }
        let languageTag = AppLanguagePreference.currentTag()
        let index = indexMemo.value(for: ListSearchKey(entries: airports, languageTag: languageTag)) {
            Self.searchIndex(airports, languageTag: languageTag)
        }
        return Self.matchingAirports(in: index, query: searchText)
    }

    var body: some View {
        if airports.isEmpty {
            ContentUnavailableView(
                "No Airports Yet",
                systemImage: "airplane.circle",
                description: Text("Airports appear here after a stay near one: a flight, a layover, or a pickup.")
            )
            .navigationTitle("Airports")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            page
        }
    }

    private var page: some View {
        let prepared = preparedMemo.value(for: airports) { Self.prepare(airports) }
        let shown = filtered
        let cards = query.isEmpty ? prepared.cards : AirportsDisplay.countryCards(shown)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    map(prepared)
                        .id(Self.mapID)
                    VStack(alignment: .leading, spacing: 0) {
                        heading(shown, countries: cards.count(where: { $0.isoCountryCode != nil }))
                        searchField
                            .padding(.top, 14)
                        if shown.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .padding(.top, 24)
                        }
                        LazyVStack(spacing: 12) {
                            ForEach(cards) { card in
                                countryCard(card) { code in
                                    select(code, prepared: prepared)
                                    withAnimation { proxy.scrollTo(Self.mapID, anchor: .top) }
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.top, -Self.titleOverlap)
                    .padding(.bottom, 32)
                }
                // Fills the page's width (not `containerRelativeFrame`, which
                // resolves too wide under the status bar on the iPhone Duo).
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .scrollDismissesKeyboard(.immediately)
            // With the map under the status bar the system draws no scroll
            // edge, so once it has scrolled away the page colour fades in
            // behind the buttons.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.mapHeight - 140
            } action: { _, isPast in
                isPastMap = isPast
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemGroupedBackground), location: 0),
                    .init(color: Color(.systemGroupedBackground), location: 0.72),
                    .init(color: Color(.systemGroupedBackground).opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 152)
                .ignoresSafeArea(edges: .top)
                .opacity(isPastMap ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isPastMap)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Airports")
        .navigationBarTitleDisplayMode(.inline)
        // The page's own title names it; the bar keeps the buttons over
        // the map, and the title still names the page for the back stack.
        .toolbar(removing: .title)
        .toolbar {
            // One compact menu in the bar's own glass: the world, then each
            // continent holding airports. Nothing to pick in one continent.
            if prepared.regions.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    regionMenu(prepared)
                }
            }
        }
    }

    private func regionMenu(_ prepared: Prepared) -> some View {
        let current = chosenRegion ?? prepared.opening
        let label = String(localized: "collections.airports.region.label", defaultValue: "Region", comment: "Airports page: accessibility label of the menu choosing the world or a continent for the map.")
        return Menu {
            Picker(label, selection: Binding(get: { current }, set: { region in
                withAnimation(.easeOut(duration: 0.2)) { chosenRegion = region }
            })) {
                Text(Self.worldName).tag(Region.world)
                ForEach(prepared.regions, id: \.self) { continent in
                    Text(Self.regionName(continent)).tag(Region.continent(continent))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(Self.name(of: current))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel(label)
            .accessibilityValue(Self.name(of: current))
        }
    }

    private static var worldName: String {
        String(localized: "collections.airports.region.world", defaultValue: "World", comment: "Airports page: map region menu choice showing every airport.")
    }

    private static func name(of region: Region) -> String {
        switch region {
        case .world: worldName
        case .continent(let continent): regionName(continent)
        }
    }

    private static func prepare(_ airports: [Airport]) -> Prepared {
        let busiest = airports.max {
            $0.visitCount != $1.visitCount ? $0.visitCount < $1.visitCount : $0.code > $1.code
        }
        var marks: [OutlineMapMark] = []
        var continents: [String: String] = [:]
        for airport in airports {
            if let continent = AirportsDisplay.continent(of: airport) { continents[airport.code] = continent }
            guard let record = AirportDetector.shared.airport(code: airport.code) else { continue }
            marks.append(OutlineMapMark(id: airport.code, latitude: record.lat, longitude: record.lon,
                                        style: airport.flownThrough ? .filled : .hollow,
                                        emphasized: airport.code == busiest?.code && airports.count > 1))
        }
        // Hollow rings under the filled stations, the busiest on top.
        marks.sort { lhs, rhs in
            let rank = { (mark: OutlineMapMark) in mark.emphasized ? 2 : (mark.style == .hollow ? 0 : 1) }
            return rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : lhs.id < rhs.id
        }
        let regions = AirportsDisplay.continents(airports)
        return Prepared(cards: AirportsDisplay.countryCards(airports),
                        region: regions.count > 1 ? regions.first : nil, regions: regions,
                        marks: marks, continents: continents)
    }

    private static func regionName(_ continent: String) -> String {
        AppLanguagePreference.currentLocale()
            .localizedString(forRegionCode: AirportsDisplay.regionCode(forContinent: continent)) ?? continent
    }

    /// Selects `code` (again: clears it), moving the map to the airport's
    /// continent (the world for one in none) when it lies outside the
    /// region shown.
    private func select(_ code: String, prepared: Prepared) {
        withAnimation(.easeOut(duration: 0.15)) {
            if selection == code {
                selection = nil
            } else {
                selection = code
                if case .continent(let shown) = chosenRegion ?? prepared.opening,
                   prepared.continents[code] != shown {
                    chosenRegion = prepared.continents[code].map(Region.continent) ?? .world
                }
            }
        }
    }

    // MARK: Map

    private func map(_ prepared: Prepared) -> some View {
        let byCode = Dictionary(airports.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let fitted = prepared.marks.filter { mark in
            guard case .continent(let region) = chosenRegion ?? prepared.opening else { return true }
            return prepared.continents[mark.id] == region
        }
        return GeometryReader { geometry in
            let projection = OutlineProjection.fitting(
                fitted.map { ($0.latitude, $0.longitude) }, kind: .mercator, size: geometry.size,
                insets: EdgeInsets(top: 112, leading: 28, bottom: 64, trailing: 28), minimumSpanDegrees: 14)
            OutlineMap(projection: projection, marks: prepared.marks, selection: $selection,
                       callout: { code in byCode[code].map { callout($0) } },
                       calloutTop: 108, calloutWidth: 230)
        }
        .frame(height: Self.mapHeight)
        .overlay(alignment: .top) {
            LinearGradient(colors: [AppTheme.mapEdge, AppTheme.mapEdge.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 112)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
                .allowsHitTesting(false)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "collections.airports.map.label", defaultValue: "Map of airports", comment: "Airports page: accessibility label of the map of every airport visited."))
        .accessibilityValue(selection.flatMap { byCode[$0] }.map { callout($0).title } ?? "")
    }

    /// "Josep Tarradellas Barcelona-El Prat Airport", then "BCN · 23
    /// visits · since 2012".
    private func callout(_ airport: Airport) -> (title: String, detail: String) {
        let year = Calendar.current.component(.year, from: airport.firstVisit)
        let detail = [airport.code, Self.visitsText(airport.visitCount), CollectionsText.since(year)]
            .joined(separator: " · ")
        return (airport.name ?? airport.city ?? airport.code, detail)
    }

    private static func visitsText(_ visits: Int) -> String {
        visits == 1
            ? String(localized: "collections.airport.visits.one", defaultValue: "\(visits, format: .number.grouping(.never)) visit", comment: "Airport row count for one visit.")
            : String(localized: "collections.airport.visits.other", defaultValue: "\(visits, format: .number.grouping(.never)) visits", comment: "Airport row count for multiple visits.")
    }

    // MARK: Heading

    /// The title, "138 airports in 44 countries" and the legend. While
    /// searching they count the airports shown.
    private func heading(_ shown: [Airport], countries: Int) -> some View {
        let flown = shown.count(where: \.flownThrough)
        let notFlown = shown.count - flown
        let legend = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 16))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Airports")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "collections.airports.summary.in-countries", defaultValue: "\(CollectionsText.airports(shown.count)) in \(PassportText.countries(countries))", comment: "Airports page subtitle: the number of airports, then of countries, such as 138 airports in 44 countries."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            if !shown.isEmpty {
                legend {
                    if flown > 0 {
                        legendItem(String(localized: "collections.airports.legend.flown", defaultValue: "Flown through", comment: "Airports page legend beside the filled circle of an airport flown through."),
                                   count: flown, hollow: false)
                    }
                    if notFlown > 0 {
                        legendItem(String(localized: "collections.airports.legend.not-flown", defaultValue: "Not flown through", comment: "Airports page legend beside the hollow ring of an airport only set foot in, never flown through."),
                                   count: notFlown, hollow: true)
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 4)
    }

    private func legendItem(_ label: String, count: Int, hollow: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hollow ? OutlineMapTint.station : AppTheme.routeLine)
                .overlay(Circle().strokeBorder(hollow ? Color.secondary : AppTheme.routeCasing, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(.secondary)
            Text(verbatim: StatsText.grouped(count))
                .font(AppTheme.stat(.footnote))
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Code, name, or city", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(AppTheme.inset, in: .capsule)
    }

    // MARK: Country cards

    private func countryCard(_ card: AirportsDisplay.CountryCard, onSelect: @escaping (String) -> Void) -> some View {
        let name = card.isoCountryCode.flatMap { localizedCountryName(iso: $0, fallback: nil) }
            ?? String(localized: "collections.airports.country.unknown", defaultValue: "Other", comment: "Airports page: card title for airports in no known country.")
        let count = card.airports.count
        let flown = card.flownCount
        let detail = [CollectionsText.airports(count),
                      flown == count && count > 1
                        ? String(localized: "collections.airports.card.all-flown", defaultValue: "all flown through", comment: "Airports page country card: every one of the country's airports was flown through. Lowercase; follows the airport count and a middle dot.")
                        : CollectionsText.flownThrough(flown)]
            .joined(separator: " · ")
        let visits = card.visits
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : 4
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FlagView(iso: card.isoCountryCode, size: .large)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: name)
                        .font(.body.weight(.semibold))
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: StatsText.grouped(visits))
                        .font(AppTheme.stat(.title3))
                    Text(visits == 1
                         ? String(localized: "collections.airports.visits-unit.one", defaultValue: "visit", comment: "Airports page country card: unit under the number of visits, for one; the number is shown separately.")
                         : String(localized: "collections.airports.visits-unit.other", defaultValue: "visits", comment: "Airports page country card: unit under the number of visits, for several; the number is shown separately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(card.airports) { airport in
                    airportChip(airport, onSelect: onSelect)
                }
            }
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: .rect(cornerRadius: AppTheme.cardRadius))
    }

    /// A code and its visits: filled where flown through, a ring where
    /// not, saffron while selected.
    private func airportChip(_ airport: Airport, onSelect: @escaping (String) -> Void) -> some View {
        let isSelected = selection == airport.code
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            onSelect(airport.code)
        } label: {
            VStack(spacing: 1) {
                Text(verbatim: airport.code)
                    .font(.body.weight(.bold))
                    .monospaced()
                    .foregroundStyle(isSelected ? AppTheme.saffronText
                                     : airport.flownThrough ? Color.primary : Color.secondary)
                Text(verbatim: StatsText.grouped(airport.visitCount))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                if isSelected {
                    shape.fill(AppTheme.saffronSoft)
                    shape.strokeBorder(AppTheme.saffron, lineWidth: 1.5)
                } else if airport.flownThrough {
                    shape.fill(AppTheme.inset)
                } else {
                    shape.strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: ([airport.name ?? airport.code, Self.visitsText(airport.visitCount)]
            + (airport.flownThrough ? [] : [String(localized: "collections.airports.legend.not-flown", defaultValue: "Not flown through", comment: "Airports page legend beside the hollow ring of an airport only set foot in, never flown through.")]))
            .joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
