//
//  StatsSections.swift
//  TravelLog
//
//  The Stats page's cards below the Passport and This Year: Countries
//  (with the pushed All Countries page), Travel Patterns, Records and
//  Exploration (with its pushed detail). Every card renders values
//  `StatsView.apply` already holds; none computes an aggregate.
//

import SwiftUI

// MARK: - Shared text

/// Count and caption strings the Stats cards share.
enum StatsText {
    static func plain(_ value: Int) -> String {
        value.formatted(.number.grouping(.never))
    }

    /// A standalone figure (a tile or a bar value, never one inside a
    /// sentence) with the app locale's digit grouping: "12,480".
    nonisolated static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(AppLanguagePreference.currentLocale()))
    }

    static func trips(_ count: Int) -> String {
        count == 1
            ? String(localized: "stats.country.trips.one", defaultValue: "\(count, format: .number.grouping(.never)) trip", comment: "Country row caption for one trip.")
            : String(localized: "stats.country.trips.other", defaultValue: "\(count, format: .number.grouping(.never)) trips", comment: "Country row caption for multiple trips.")
    }

    static func days(_ count: Int) -> String {
        count == 1
            ? String(localized: "trip-detail.duration-days.one", defaultValue: "\(count, format: .number.grouping(.never)) day", comment: "Trip detail duration of one day.")
            : String(localized: "trip-detail.duration-days.other", defaultValue: "\(count, format: .number.grouping(.never)) days", comment: "Trip detail duration of multiple days.")
    }

    static func travelDays(_ count: Int) -> String {
        count == 1
            ? String(localized: "stats.record.travel-days.one", defaultValue: "\(count, format: .number.grouping(.never)) travel day", comment: "Record tile detail for one travel day.")
            : String(localized: "stats.record.travel-days.other", defaultValue: "\(count, format: .number.grouping(.never)) travel days", comment: "Record tile detail for multiple travel days.")
    }

    /// "4.2 days": one decimal at most; the singular form only when the
    /// rounded text reads as exactly one.
    static func averageDays(_ average: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        let text = average.formatted(style)
        return text == 1.0.formatted(style)
            ? String(localized: "stats.record.average-days.one", defaultValue: "\(text) day", comment: "Average trip length of one day; the placeholder is an already formatted number.")
            : String(localized: "stats.record.average-days.other", defaultValue: "\(text) days", comment: "Average trip length in days; the placeholder is an already formatted number with up to one decimal.")
    }

    static func regionName(_ code: String) -> String {
        AppLanguagePreference.currentLocale().localizedString(forRegionCode: code) ?? code
    }
}

/// The flat material card every Stats section wears, with its header.
private struct StatsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}

/// A trailing chevron, as the Stats link rows draw it.
private struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Countries

/// One country entry of the Countries card and page: tracked (with its
/// row stats) or remembered only (a pre-TravelLog checklist country).
private enum CountryEntry: Identifiable {
    case tracked(CountryStat)
    case remembered(String)

    var id: String {
        switch self {
        case .tracked(let stat): stat.code
        case .remembered(let code): code
        }
    }

    /// Tracked rows in `countryStats` order, then remembered-only ones by code.
    static func all(stats: [CountryStat], tracked: Set<String>, remembered: Set<String>) -> [CountryEntry] {
        stats.map(CountryEntry.tracked) + remembered.subtracting(tracked).sorted().map(CountryEntry.remembered)
    }
}

/// One country row. A row with trips taps through to the Trips tab
/// filtered to that country; zero-trip and remembered rows are static.
private struct CountryEntryRow: View {
    let entry: CountryEntry

    var body: some View {
        switch entry {
        case .tracked(let stat):
            if stat.tripCount > 0 {
                Button {
                    TripsTabRouter.shared.requestCountryFilter(stat.code)
                } label: {
                    row(flag: stat.code, name: StatsView.countryDisplayName(stat), caption: Self.caption(for: stat), chevron: true)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Trips tab filtered to \(StatsView.countryDisplayName(stat))")
            } else {
                // Static rows keep the Button's one-element VoiceOver shape.
                row(flag: stat.code, name: StatsView.countryDisplayName(stat), caption: Self.caption(for: stat), chevron: false)
                    .accessibilityElement(children: .combine)
            }
        case .remembered(let code):
            row(flag: code, name: StatsText.regionName(code), caption: Text("before TravelLog"), chevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func row(flag code: String, name: String, caption: Text, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text(flagEmoji(for: code) ?? "🏳️")
                .accessibilityHidden(true)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            if chevron { RowChevron() }
        }
    }

    /// Where the country CAME from: trips, home, a temporary home, or (the
    /// foreign zero-trip case) time near home, since a demoted cross-border
    /// routine stamps the passport without minting trips, by design. Trip
    /// rows add the days spent there.
    static func caption(for stat: CountryStat) -> Text {
        if stat.isHome && stat.tripCount == 0 {
            return Text("home")
        } else if stat.isHome {
            return Text(stat.tripCount == 1
                 ? String(localized: "stats.country.trips-home.one", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trip · home", comment: "Country row caption for one trip to a home country.")
                 : String(localized: "stats.country.trips-home.other", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trips · home", comment: "Country row caption for multiple trips to a home country."))
        } else if stat.isTemporaryHome == true && stat.tripCount == 0 {
            return Text(String(localized: "stats.country.temporary-home", defaultValue: "temporary home", comment: "Country row caption for the country of a temporary home, such as a semester abroad, with no trips there."))
        } else if stat.isTemporaryHome == true {
            return Text(stat.tripCount == 1
                 ? String(localized: "stats.country.trips-temporary-home.one", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trip · temporary home", comment: "Country row caption for one trip to the country of a temporary home.")
                 : String(localized: "stats.country.trips-temporary-home.other", defaultValue: "\(stat.tripCount, format: .number.grouping(.never)) trips · temporary home", comment: "Country row caption for multiple trips to the country of a temporary home."))
        } else if stat.tripCount == 0 {
            return Text("time near home")
        }
        let trips = StatsText.trips(stat.tripCount)
        if let days = stat.days, days > 0 {
            return Text(verbatim: "\(trips) · \(StatsText.days(days))")
        }
        return Text(trips)
    }
}

/// "Add countries from before TravelLog": opens the remembered-countries
/// checklist.
private struct AddEarlierCountriesButton: View {
    let trackedCodes: Set<String>
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("Add countries from before TravelLog", systemImage: "plus.circle")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showPicker) {
            RememberedCountriesPicker(trackedCodes: trackedCodes)
        }
    }
}

/// The globe, the country count, the five leading countries and a link to
/// every country with the progress rings and the Earlier Travels entry.
struct StatsCountriesCard: View {
    let countryStats: [CountryStat]
    /// Tracked country codes (`uniqueCountries`).
    let trackedCodes: Set<String>

    private static let shownCount = 5

    /// Pre-TravelLog countries (KVS-synced checklist, `@Observable`): count
    /// toward the globe and the total at once, never creating trips.
    private let rememberedCountries = RememberedCountriesStorage.shared

    var body: some View {
        let remembered = rememberedCountries.codes
        let visited = trackedCodes.union(remembered)
        StatsCard(title: String(localized: "stats.countries.title", defaultValue: "Countries", comment: "Stats card title for the countries visited.")) {
            if visited.isEmpty {
                // Nothing recorded yet: the one way to add countries stays here.
                AddEarlierCountriesButton(trackedCodes: trackedCodes)
            } else {
                GlobeView(visitedCountryCodes: visited, height: 220)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(visited.count, format: .number)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text(visited.count == 1
                         ? String(localized: "stats.countries.count-caption.one", defaultValue: "country or territory", comment: "Caption after the number of countries visited, for one.")
                         : String(localized: "stats.countries.count-caption.other", defaultValue: "countries and territories", comment: "Caption after the number of countries visited, for zero or several."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Divider()

                let entries = CountryEntry.all(stats: countryStats, tracked: trackedCodes, remembered: remembered)
                ForEach(entries.prefix(Self.shownCount)) { entry in
                    CountryEntryRow(entry: entry)
                }

                Divider()

                NavigationLink {
                    StatsAllCountriesView(countryStats: countryStats, trackedCodes: trackedCodes)
                } label: {
                    HStack {
                        Text(String(localized: "stats.countries.see-all", defaultValue: "All Countries", comment: "Stats Countries card link to the page listing every country visited, with progress rings."))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                        Spacer()
                        Text(visited.count, format: .number)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        RowChevron()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Every country: the two progress rings (UN members, and every ISO code
/// with territories), the full row list and the Earlier Travels entry.
struct StatsAllCountriesView: View {
    let countryStats: [CountryStat]
    let trackedCodes: Set<String>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let rememberedCountries = RememberedCountriesStorage.shared

    var body: some View {
        let remembered = rememberedCountries.codes
        let visited = trackedCodes.union(remembered)
        let entries = CountryEntry.all(stats: countryStats, tracked: trackedCodes, remembered: remembered)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !visited.isEmpty {
                    // A filling ring per honest denominator, since neither
                    // alone satisfies: territories fold into their sovereign
                    // against the 193 UN members (visiting Puerto Rico counts
                    // the US), and count as themselves against the ISO list.
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 10))
                        : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        CountryProgressRing(
                            visited: CountryCatalog.unMemberCount(of: visited),
                            total: CountryCatalog.unMemberTotal,
                            caption: String(localized: "stats.country-progress.un-countries", defaultValue: "UN countries", comment: "Caption for passport progress against the total number of UN countries."),
                            tint: .blue
                        )
                        CountryProgressRing(
                            visited: visited.count,
                            total: CountryCatalog.isoCodeTotal,
                            caption: String(localized: "stats.country-progress.including-territories", defaultValue: "incl. territories", comment: "Caption for passport progress including territories."),
                            tint: .teal
                        )
                    }
                }

                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            CountryEntryRow(entry: entry)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }

                AddEarlierCountriesButton(trackedCodes: trackedCodes)
            }
            .padding()
        }
        .navigationTitle(String(localized: "stats.countries.see-all", defaultValue: "All Countries", comment: "Stats Countries card link to the page listing every country visited, with progress rings."))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A circular gauge that fills 0 → 100% with the share of the world's
/// countries visited, rendered as its own inset tile (a subtle fill on top
/// of the page). The center shows the percentage; below the ring sit the
/// raw "12 of 193" and which denominator this ring measures.
private struct CountryProgressRing: View {
    let visited: Int
    let total: Int
    let caption: String
    let tint: Color

    private var fraction: Double {
        total > 0 ? min(1, Double(max(0, visited)) / Double(total)) : 0
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Track in the fill's own tint, faint: reads as one coloured
                // gauge instead of a gray donut on a gray tile.
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                Text(CountryCatalog.percentText(fraction))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 84, height: 84)

            VStack(spacing: 1) {
                Text(visited == 1
                     ? String(localized: "stats.country-progress.count.one", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never))", comment: "Country progress count when one country is visited out of the total.")
                     : String(localized: "stats.country-progress.count.other", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never))", comment: "Country progress count when zero or multiple countries are visited out of the total."))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visited == 1
                            ? String(localized: "stats.country-progress.accessibility.one", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) \(caption) visited, \(CountryCatalog.percentText(fraction))", comment: "Country progress accessibility label when one country is visited.")
                            : String(localized: "stats.country-progress.accessibility.other", defaultValue: "\(visited, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) \(caption) visited, \(CountryCatalog.percentText(fraction))", comment: "Country progress accessibility label when zero or multiple countries are visited."))
    }
}

// MARK: - Travel patterns

/// When the user travels: travel days per month (all years pooled, trip
/// days only, like the year bars) and how long completed trips last.
struct StatsPatternsCard: View {
    let overview: StatsOverview
    let averageTripDays: Double?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if overview.monthDays != nil || overview.tripLengthBuckets != nil {
            StatsCard(title: String(localized: "stats.patterns.title", defaultValue: "Travel Patterns", comment: "Stats card title for when and how long the user travels.")) {
                if let months = overview.monthDays {
                    monthStrip(months)
                }
                if overview.monthDays != nil, overview.tripLengthBuckets != nil {
                    Divider()
                }
                if let buckets = overview.tripLengthBuckets {
                    tripLengths(buckets)
                }
            }
        }
    }

    // MARK: Month strip

    private var locale: Locale { AppLanguagePreference.currentLocale() }

    /// One-letter (or shortest) standalone month symbols, Gregorian.
    private var monthLetters: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.veryShortStandaloneMonthSymbols
    }

    @ViewBuilder
    private func monthStrip(_ months: [Int]) -> some View {
        let maxDays = max(months.max() ?? 1, 1)
        let letters = monthLetters
        // Values fit above the bars only at the smaller text sizes; the
        // summary line and VoiceOver carry them otherwise.
        let showsValues = dynamicTypeSize <= .xLarge
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "stats.patterns.by-month.title", defaultValue: "Travel Days by Month", comment: "Stats Travel Patterns heading for the twelve-month travel-day chart."))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(String(localized: "stats.patterns.by-month.all-years", defaultValue: "All years", comment: "Stats Travel Patterns caption: the month chart pools every year."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(months.enumerated()), id: \.offset) { index, days in
                let isPeak = index + 1 == overview.peakMonth
                VStack(spacing: 4) {
                    if showsValues {
                        Text(days, format: .number)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isPeak ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(days == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                        .opacity(days == 0 || isPeak ? 1 : 0.4)
                        .frame(height: days == 0 ? 2 : max(4, 72 * CGFloat(days) / CGFloat(maxDays)))
                    Text(letters.indices.contains(index) ? letters[index] : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatsView.monthName(index + 1, locale: locale) ?? "")
                .accessibilityValue(StatsText.travelDays(days))
            }
        }

        if let peak = overview.peakMonth, let name = StatsView.monthName(peak, locale: locale) {
            Text(String(localized: "stats.patterns.peak-month", defaultValue: "Most travel in \(name): \(StatsText.travelDays(overview.peakMonthDays))", comment: "Stats Travel Patterns line naming the month with the most travel days; the second placeholder is a count such as 38 travel days."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Trip length

    private static var bucketLabels: [String] {
        [
            String(localized: "stats.patterns.trip-length.range.1-3", defaultValue: "1 to 3 days", comment: "Stats trip-length bucket for trips of one to three days."),
            String(localized: "stats.patterns.trip-length.range.4-7", defaultValue: "4 to 7 days", comment: "Stats trip-length bucket for trips of four to seven days."),
            String(localized: "stats.patterns.trip-length.range.8-14", defaultValue: "8 to 14 days", comment: "Stats trip-length bucket for trips of eight to fourteen days."),
            String(localized: "stats.patterns.trip-length.range.15-plus", defaultValue: "15 days or more", comment: "Stats trip-length bucket for trips of fifteen days or longer."),
        ]
    }

    @ViewBuilder
    private func tripLengths(_ buckets: [Int]) -> some View {
        let labels = Self.bucketLabels
        let maxCount = max(buckets.max() ?? 1, 1)
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "stats.patterns.trip-length.title", defaultValue: "Trip Length", comment: "Stats Travel Patterns heading for completed trips grouped by length."))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let average = averageTripDays, average > 0 {
                Text(String(localized: "stats.patterns.trip-length.average", defaultValue: "Average \(StatsText.averageDays(average))", comment: "Stats Travel Patterns caption with the average trip length; the placeholder is a length such as 6.1 days."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if dynamicTypeSize.isAccessibilitySize {
            // Stacked: the label above its bar, so neither truncates.
            ForEach(Array(buckets.enumerated()), id: \.offset) { index, count in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(labels.indices.contains(index) ? labels[index] : "")
                            .font(.subheadline)
                        Spacer()
                        Text(count, format: .number)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    bucketBar(count: count, maxCount: maxCount)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(labels.indices.contains(index) ? labels[index] : "")
                .accessibilityValue(StatsText.trips(count))
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, count in
                    GridRow(alignment: .center) {
                        Text(labels.indices.contains(index) ? labels[index] : "")
                            .font(.subheadline)
                        bucketBar(count: count, maxCount: maxCount)
                        Text(count, format: .number)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(labels.indices.contains(index) ? labels[index] : "")
                    .accessibilityValue(StatsText.trips(count))
                }
            }
        }
    }

    private func bucketBar(count: Int, maxCount: Int) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(count == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.teal.opacity(0.8)))
                .frame(width: count == 0 ? 6 : max(6, proxy.size.width * CGFloat(count) / CGFloat(maxCount)))
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 12)
    }
}

// MARK: - Records

private struct RecordTileData: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String?
}

/// One superlative: a caption title, the value large, and what it belongs
/// to beneath, on a faint tint tile. Values and details wrap rather than
/// shrink, so Dynamic Type never truncates a name.
private struct RecordTile: View {
    let tile: RecordTileData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(tile.title)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: tile.icon)
                    .foregroundStyle(tile.tint)
            }
            .font(.caption)
            Text(tile.value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(3)
            if let detail = tile.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(tile.tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// The longest trip, the farthest place and the most visited place, plus
/// the last completed trip as a compact row that opens it.
struct StatsRecordsCard: View {
    let passport: PassportData
    let lastTrip: StatsAggregator.LastTrip?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tiles: [RecordTileData] {
        var tiles: [RecordTileData] = []
        if let name = passport.longestTripName, passport.longestTripDays > 0 {
            tiles.append(RecordTileData(
                id: "longest-trip", icon: "trophy.fill", tint: .yellow,
                title: String(localized: "stats.highlight.longest-trip", defaultValue: "Longest Trip", comment: "Statistics highlight title for the longest trip."),
                value: StatsText.days(passport.longestTripDays),
                detail: name
            ))
        }
        if let km = passport.furthestKm, km > 0 {
            tiles.append(RecordTileData(
                id: "farthest", icon: "location.north.line.fill", tint: .purple,
                title: String(localized: "stats.highlight.farthest-from-home", defaultValue: "Farthest From Home", comment: "Statistics highlight title for the farthest place from home."),
                value: UnitsFormatter.formatDistance(kilometers: km),
                detail: passport.furthestPlace ?? String(localized: "stats.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in the farthest-from-home statistics highlight.")
            ))
        }
        if let place = passport.mostVisitedPlace, passport.mostVisitedTripCount > 0 {
            tiles.append(RecordTileData(
                id: "most-visited", icon: "star.fill", tint: .orange,
                title: String(localized: "stats.highlight.most-visited", defaultValue: "Most Visited", comment: "Statistics highlight title for the most visited place."),
                value: place,
                detail: StatsText.trips(passport.mostVisitedTripCount)
            ))
        }
        return tiles
    }

    var body: some View {
        let tiles = tiles
        if !tiles.isEmpty || lastTrip != nil {
            StatsCard(title: String(localized: "passport.section.records", defaultValue: "Records", comment: "Passport detail section title for travel records.")) {
                if !tiles.isEmpty {
                    // Pairs side by side, an odd last tile full width; one
                    // column at accessibility sizes.
                    let paired = dynamicTypeSize.isAccessibilitySize ? 0 : tiles.count / 2 * 2
                    if paired > 0 {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10, alignment: .top),
                                      GridItem(.flexible(), spacing: 10, alignment: .top)],
                            spacing: 10
                        ) {
                            ForEach(tiles.prefix(paired)) { RecordTile(tile: $0) }
                        }
                    }
                    ForEach(tiles.dropFirst(paired)) { RecordTile(tile: $0) }
                }
                if let lastTrip {
                    if !tiles.isEmpty { Divider() }
                    lastTripRow(lastTrip)
                }
            }
        }
    }

    @ViewBuilder
    private func lastTripRow(_ trip: StatsAggregator.LastTrip) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .foregroundStyle(.blue)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "stats.highlight.last-trip", defaultValue: "Last Trip", comment: "Statistics highlight title for the most recent trip."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(trip.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(Self.lastTripDetail(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if trip.tripID != nil { RowChevron() }
        }
        .contentShape(.rect)
        if let tripID = trip.tripID {
            Button {
                TripsTabRouter.shared.requestTrip(tripID)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    /// "6 days · ended 2 weeks ago"; the start date for a pre-field
    /// snapshot that carries neither.
    private static func lastTripDetail(_ trip: StatsAggregator.LastTrip) -> String {
        let locale = AppLanguagePreference.currentLocale()
        guard let days = trip.days, let end = trip.endDate else {
            return trip.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        }
        let ago = end.formatted(Date.RelativeFormatStyle(
            presentation: .named, unitsStyle: .wide, locale: locale,
            capitalizationContext: .middleOfSentence))
        return String(localized: "stats.last-trip.detail", defaultValue: "\(StatsText.days(days)) · ended \(ago)", comment: "Stats Last Trip row detail: the trip's length, then how long ago it ended, such as 6 days · ended 2 weeks ago.")
    }
}

// MARK: - Exploration

/// Exploration strings and the country name its rows share.
private enum ExplorationText {
    /// The area one hex stands for, in the locale's units ("36 km²").
    static var hexAreaText: String {
        var one = PassportData()
        one.hexes = 1
        return one.areaText
    }

    static func newHexes(_ count: Int) -> String {
        count == 1
            ? String(localized: "stats.exploration.new-hexes.one", defaultValue: "\(count, format: .number.grouping(.never)) new hex", comment: "Exploration year bar spoken value: one hex explored for the first time that year.")
            : String(localized: "stats.exploration.new-hexes.other", defaultValue: "\(count, format: .number.grouping(.never)) new hexes", comment: "Exploration year bar spoken value: hexes explored for the first time that year.")
    }

    /// A pinned home country can predate its first `HexVisit` (fresh move),
    /// leaving the aggregator's `name` nil: fall back to the locale's region
    /// name rather than showing a bare ISO code.
    static func name(_ row: StatsOverview.ExplorationSummary.Coverage) -> String {
        AppLanguagePreference.currentLocale().localizedString(forRegionCode: row.code)
            ?? row.name
            ?? row.code
    }

    /// "≈4.2%", or the bare "<0.1%" floor; nil without an area.
    static func percent(_ row: StatsOverview.ExplorationSummary.Coverage) -> String? {
        guard let percent = row.percent else { return nil }
        // "≈" because the share uses the GLOBAL mean res-6 cell area, which
        // over/understates by latitude.
        let text = CountryCatalog.countryPercentText(percent)
        return text.hasPrefix("<") || percent == 0 ? text : "≈" + text
    }

    /// "312 hexes", the count alone.
    static func hexes(_ count: Int) -> String {
        count == 1
            ? String(localized: "stats.hex-country-detail.one", defaultValue: "\(count, format: .number.grouping(.never)) hex", comment: "Country exploration detail for one hex when no coverage percentage is available.")
            : String(localized: "stats.hex-country-detail.other", defaultValue: "\(count, format: .number.grouping(.never)) hexes", comment: "Country exploration detail for multiple hexes when no coverage percentage is available.")
    }

    /// "312 hexes · ≈4.2%": hex count plus that country's coverage share
    /// (omitted when the catalog has no area for the code).
    static func detail(_ row: StatsOverview.ExplorationSummary.Coverage) -> String {
        guard let percent = row.percent else { return hexes(row.count) }
        let pctText = CountryCatalog.countryPercentText(percent)
        if pctText.hasPrefix("<") {
            return row.count == 1
                ? String(localized: "stats.hex-country-detail.percent-floor.one", defaultValue: "\(row.count, format: .number.grouping(.never)) hex · \(pctText)", comment: "Country exploration detail for one hex with a below-threshold coverage percentage.")
                : String(localized: "stats.hex-country-detail.percent-floor.other", defaultValue: "\(row.count, format: .number.grouping(.never)) hexes · \(pctText)", comment: "Country exploration detail for multiple hexes with a below-threshold coverage percentage.")
        }
        return row.count == 1
            ? String(localized: "stats.hex-country-detail.percent.one", defaultValue: "\(row.count, format: .number.grouping(.never)) hex · ≈\(pctText)", comment: "Country exploration detail for one hex with an approximate coverage percentage.")
            : String(localized: "stats.hex-country-detail.percent.other", defaultValue: "\(row.count, format: .number.grouping(.never)) hexes · ≈\(pctText)", comment: "Country exploration detail for multiple hexes with an approximate coverage percentage.")
    }

    /// "312 of about 7400 hexes": the explored count against the country's
    /// estimated hex total; the count alone without an area.
    static func ofTotal(_ row: StatsOverview.ExplorationSummary.Coverage) -> String {
        guard let total = row.estimatedTotal else { return hexes(row.count) }
        return total == 1
            ? String(localized: "stats.exploration.home-hexes-of-total.one", defaultValue: "\(row.count, format: .number.grouping(.never)) of about \(total, format: .number.grouping(.never)) hex", comment: "Exploration home country caption: hexes explored out of the country's estimated total of one hex, for a country smaller than one hex.")
            : String(localized: "stats.exploration.home-hexes-of-total.other", defaultValue: "\(row.count, format: .number.grouping(.never)) of about \(total, format: .number.grouping(.never)) hexes", comment: "Exploration home country caption: hexes explored out of the country's estimated total number of hexes, such as 312 of about 7400 hexes.")
    }
}

/// A horizontal capsule bar: `fraction` of the width over a faint track in
/// the same tint. A nonzero value always shows a sliver.
private struct ExplorationBar: View {
    let fraction: Double
    var tint: Color = .teal
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                if clamped > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One country's explored hexes with a bar; taps through to the Map tab
/// with that country highlighted. The home rows of the card measure the
/// country (a 0 to 100% meter); the detail list compares countries (bars
/// against the leader).
private struct HexCountryRow: View {
    enum Style { case homeMeter, ranked(maxCount: Int) }

    let row: StatsOverview.ExplorationSummary.Coverage
    let isHome: Bool
    let style: Style

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let name = ExplorationText.name(row)
        Button {
            MapTabRouter.shared.requestHighlight(.country(code: row.code, name: row.name))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    // Stacked: the name above its figure, so neither truncates.
                    HStack(spacing: 6) {
                        title(name)
                        Spacer(minLength: 8)
                        RowChevron()
                    }
                    trailing
                        .monospacedDigit()
                } else {
                    HStack(spacing: 6) {
                        title(name)
                        Spacer(minLength: 8)
                        trailing
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                        RowChevron()
                    }
                }
                bar
                if case .homeMeter = style {
                    Text(ExplorationText.ofTotal(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .accessibilityHint("Shows \(name) hexes on the map")
    }

    @ViewBuilder
    private func title(_ name: String) -> some View {
        if isHome {
            Image(systemName: "house.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text(flagEmoji(for: row.code) ?? "🏳️")
        Text(name)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var trailing: some View {
        switch style {
        case .homeMeter:
            if let percent = ExplorationText.percent(row) {
                Text(verbatim: percent)
                    .fontWeight(.semibold)
            }
        case .ranked:
            Text(ExplorationText.detail(row))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch style {
        case .homeMeter:
            if let percent = row.percent {
                ExplorationBar(fraction: percent / 100)
            }
        case .ranked(let maxCount):
            ExplorationBar(fraction: maxCount > 0 ? Double(row.count) / Double(maxCount) : 0,
                           tint: isHome ? .teal : .teal.opacity(0.7), height: 6)
        }
    }
}

/// The hex map in numbers: how many hexes and how much area, what one hex
/// is, the new hexes year by year, and how much of each home country. The
/// leading countries and the world shares sit one push away. Counts match
/// the Map tab (same transit-only filter). Hidden until a hex exists.
struct StatsExplorationCard: View {
    let totalHexes: Int
    let areaText: String
    let exploration: StatsOverview.ExplorationSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if totalHexes > 0 {
            StatsCard(title: String(localized: "Exploration")) {
                hero

                if exploration.showsYears {
                    Divider()
                    yearStrip
                }

                if exploration.newThisYear > 0 {
                    newThisYearRow
                }

                if !exploration.homes.isEmpty {
                    Divider()
                    // "% of home explored" is presentation over the
                    // per-country coverage: moving countries moves the pin,
                    // and the old country keeps its row in the detail page.
                    ForEach(exploration.homes) { row in
                        HexCountryRow(row: row, isHome: true, style: .homeMeter)
                    }
                }

                Divider()

                NavigationLink {
                    StatsExplorationDetailView(totalHexes: totalHexes, exploration: exploration)
                } label: {
                    HStack {
                        Text(String(localized: "stats.exploration.top-countries", defaultValue: "Top Countries", comment: "Stats Exploration card link to the page listing the countries with the most explored hexes and the share of the world explored."))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                        Spacer()
                        RowChevron()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Hero

    /// The hex count leads, big; the area it stands for sits beside it,
    /// with the ≈ every derived number here wears; one plain line says what
    /// a hex is.
    @ViewBuilder
    private var hero: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(totalHexes, format: .number)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Image(systemName: "hexagon.fill")
                        .foregroundStyle(.teal)
                    Text("Hexes explored")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(verbatim: "≈ " + areaText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)

        Text(String(localized: "stats.exploration.hex-explainer", defaultValue: "Each hex is a map cell of about \(ExplorationText.hexAreaText). It counts once, the first time you are there.", comment: "Stats Exploration card line explaining what a hex is; the placeholder is the area of one hex, such as 36 km²."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: New hexes by year

    @ViewBuilder
    private var yearStrip: some View {
        let years = exploration.years
        let maxCount = max(years.map(\.count).max() ?? 1, 1)
        let current = years.last?.year
        Text(String(localized: "stats.exploration.by-year.title", defaultValue: "New Hexes by Year", comment: "Stats Exploration heading for the chart of hexes explored for the first time each year."))
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

        if dynamicTypeSize.isAccessibilitySize {
            // Rows: the year above its bar, so nothing truncates.
            ForEach(years, id: \.year) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: String(entry.year))
                        Spacer()
                        Text(entry.count, format: .number)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    ExplorationBar(fraction: Double(entry.count) / Double(maxCount),
                                   tint: entry.year == current ? .teal : .teal.opacity(0.5))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(entry.year))
                .accessibilityValue(ExplorationText.newHexes(entry.count))
            }
        } else {
            // Values fit above the bars only at the smaller text sizes; the
            // VoiceOver value carries them otherwise.
            let showsValues = dynamicTypeSize <= .xLarge
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(years, id: \.year) { entry in
                    let isCurrent = entry.year == current
                    VStack(spacing: 4) {
                        if showsValues {
                            Text(entry.count, format: .number)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(entry.count == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.teal))
                            .opacity(entry.count == 0 || isCurrent ? 1 : 0.45)
                            .frame(height: entry.count == 0 ? 2 : max(4, 56 * CGFloat(entry.count) / CGFloat(maxCount)))
                        Text(verbatim: String(entry.year))
                            .font(.caption2)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(entry.year))
                    .accessibilityValue(ExplorationText.newHexes(entry.count))
                }
            }
        }
    }

    /// Tap → Map tab with this year's new hexes highlighted. Highlight modes
    /// are ONLY enterable from these Stats rows (see MapTabRouter); the
    /// chevron signals the navigation.
    private var newThisYearRow: some View {
        Button {
            MapTabRouter.shared.requestHighlight(.newThisYear)
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    // The year strip's current bar already shows this
                    // count; the row repeats it only when the strip is
                    // hidden, and is otherwise just the link.
                    if !exploration.showsYears {
                        Text(exploration.newThisYear, format: .number.sign(strategy: .always()))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                    }
                    RowChevron()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                    Text("New this year")
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        // The count stays spoken even when the strip carries it visually.
        .accessibilityLabel(Text("New this year"))
        .accessibilityValue(ExplorationText.newHexes(exploration.newThisYear))
        .accessibilityHint("Shows this year's new hexes on the map")
    }
}

/// The Exploration extras: the countries with the most hexes (home pinned
/// first) as bars against the leader, then the world and land shares
/// (honest, humbling denominators) at the foot.
struct StatsExplorationDetailView: View {
    let totalHexes: Int
    let exploration: StatsOverview.ExplorationSummary

    var body: some View {
        ScrollView {
            StatsExplorationDetailContent(totalHexes: totalHexes, exploration: exploration)
                .padding()
        }
        .navigationTitle(String(localized: "Exploration"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The detail page's scrolling content (also what a headless render draws,
/// since a ScrollView renders empty there).
struct StatsExplorationDetailContent: View {
    let totalHexes: Int
    let exploration: StatsOverview.ExplorationSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !exploration.homes.isEmpty || !exploration.others.isEmpty {
                let maxCount = exploration.maxListedCount
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "stats.exploration.top-countries", defaultValue: "Top Countries", comment: "Stats Exploration card link to the page listing the countries with the most explored hexes and the share of the world explored."))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(exploration.homes) {
                        HexCountryRow(row: $0, isHome: true, style: .ranked(maxCount: maxCount))
                    }
                    ForEach(exploration.others) {
                        HexCountryRow(row: $0, isHome: false, style: .ranked(maxCount: maxCount))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                coverageTile(
                    value: CountryCatalog.percentText(CountryCatalog.fractionOfEarth(hexCount: totalHexes)),
                    label: String(localized: "stats.exploration.of-the-world", defaultValue: "Of the world", comment: "Exploration tile caption for the share of the Earth's surface explored."),
                    icon: "globe", tint: .blue
                )
                coverageTile(
                    value: CountryCatalog.percentText(CountryCatalog.fractionOfLand(hexCount: totalHexes)),
                    label: String(localized: "stats.exploration.of-land", defaultValue: "Of land", comment: "Exploration tile caption for the share of the Earth's land explored."),
                    icon: "globe.europe.africa.fill", tint: .green
                )
            }
        }
    }

    /// "≈0.02%" over its denominator caption, on a faint tint tile.
    private func coverageTile(value: String, label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "≈" + value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
