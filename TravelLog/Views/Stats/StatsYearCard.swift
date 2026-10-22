//
//  StatsYearCard.swift
//  TravelLog
//

import Charts
import SwiftUI

/// The "This Year" card: this year's trips, countries, cities and travel
/// days side by side, and the countries recorded for the first time, with
/// their flags. Content layer: the same card as its Stats siblings.
struct StatsYearCard: View {

    let overview: StatsOverview
    /// Remembered (pre-TravelLog) countries carry no date: never first recorded.
    let rememberedCodes: Set<String>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var figureSize: CGFloat = 24

    private static let shownFlags = 4

    /// Today's Gregorian label year in the supplied calendar's time zone.
    static func currentYear(now: Date, calendar: Calendar) -> Int {
        StatsOverview.currentYear(now: now, calendar: calendar)
    }

    var body: some View {
        let firstRecorded = overview.thisYear.firstRecordedCodes.filter { !rememberedCodes.contains($0) }
        StatsSection(
            title: String(localized: "stats.this-year.title", defaultValue: "This Year", comment: "Stats card title for the current year's totals compared with last year."),
            spacing: 0, padded: false
        ) {
            Text(verbatim: String(overview.currentYear))
                .monospacedDigit()
        } content: {
            figures
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            if !firstRecorded.isEmpty {
                firstRecordedRow(firstRecorded)
            }
        }
    }

    // MARK: Figures

    /// The four figures. The days are trip days only, so they read Travel
    /// Days as the By Year bars do: Days Away (Passport) also counts the
    /// days lived at a temporary home.
    static func figureEntries(_ overview: StatsOverview) -> [(label: String, value: Int)] {
        [
            (String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), overview.thisYear.trips),
            (String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries."), overview.countriesThisYearCount),
            (String(localized: "passport.tile.cities", defaultValue: "Cities", comment: "Passport statistic tile label for cities."), overview.citiesThisYear),
            (StatsByYearCard.daysLabel, overview.thisYear.travelDays),
        ]
    }

    @ViewBuilder
    private var figures: some View {
        let entries = Self.figureEntries(overview)
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                ForEach(entries, id: \.label) { figure($0) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.label) { index, entry in
                    figure(entry)
                        .padding(.leading, index == 0 ? 0 : 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(width: 0.5)
                                    .padding(.vertical, 4)
                            }
                        }
                }
            }
        }
    }

    private func figure(_ entry: (label: String, value: Int)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StatsText.grouped(entry.value))
                .font(.system(size: figureSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(entry.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: First recorded

    /// A hairline, the saffron spark, "2 first recorded countries" (the
    /// count in saffron) and the countries' flags.
    private func firstRecordedRow(_ codes: [String]) -> some View {
        let count = codes.count
        let text = count == 1
            ? String(localized: "stats.this-year.first-recorded-row.one", defaultValue: "\(count, format: .number) first recorded country", comment: "Stats This Year row: countries recorded for the first time this year, for one. Not 'first ever': countries visited before the app was installed are not counted.")
            : String(localized: "stats.this-year.first-recorded-row.other", defaultValue: "\(count, format: .number) first recorded countries", comment: "Stats This Year row: countries recorded for the first time this year, for several. Not 'first ever': countries visited before the app was installed are not counted.")
        var line = AttributedString(text)
        if let range = line.range(of: StatsText.grouped(count)) {
            line[range].foregroundColor = AppTheme.saffronText
            line[range].font = Font.system(.subheadline, design: .rounded).weight(.semibold)
        }
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(AppTheme.saffron)
                .accessibilityHidden(true)
            Text(line)
                .font(.subheadline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize {
                FlagRow(codes: Array(codes.prefix(Self.shownFlags)), size: .small)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Travel Days by Month

/// This year's travel days per month: past months as cobalt bars, the
/// current month saffron with its value, months without travel a grey
/// stub, the months still ahead dotted placeholders, and the busiest
/// month's value above its bar.
struct StatsMonthCard: View {
    let overview: StatsOverview

    private var locale: Locale { AppLanguagePreference.currentLocale() }

    var body: some View {
        if let months = overview.monthDaysThisYear {
            let total = months.reduce(0, +)
            StatsSection(
                title: String(localized: "stats.patterns.by-month.title", defaultValue: "Travel Days by Month", comment: "Stats Travel Patterns heading for the twelve-month travel-day chart."),
                padded: false
            ) {
                Text(StatsText.emphasizing(StatsText.plain(total), in: StatsText.days(total),
                                           font: Font.system(.body, design: .rounded).weight(.bold)))
            } content: {
                chart(months)
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            }
        }
    }

    private func chart(_ months: [Int]) -> some View {
        let maxDays = max(months.max() ?? 1, 1)
        let peak = PeriodBar.peak(Array(months.enumerated()).map { ($0.offset + 1, $0.element) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let letters = calendar.veryShortStandaloneMonthSymbols
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(months.enumerated()), id: \.offset) { index, days in
                let month = index + 1
                let isCurrent = month == overview.currentMonth
                let isFuture = month > overview.currentMonth
                let showsValue = days > 0 && (isCurrent || month == peak)
                VStack(spacing: 4) {
                    Text(showsValue ? StatsText.grouped(days) : "")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? AppTheme.saffronText : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                    MonthBar(days: days, height: max(4, (70 * CGFloat(days) / CGFloat(maxDays)).rounded()),
                             isCurrent: isCurrent, isFuture: isFuture)
                    Text(letters.indices.contains(index) ? letters[index] : "")
                        .font(.caption2)
                        .fontWeight(isCurrent ? .bold : nil)
                        .foregroundStyle(isCurrent ? AppTheme.saffronText : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatsView.monthName(month, locale: locale) ?? "")
                .accessibilityValue(StatsText.travelDays(days))
            }
        }
        .frame(height: 100, alignment: .bottom)
    }
}

/// One month of the This Year chart.
private struct MonthBar: View {
    let days: Int
    let height: CGFloat
    let isCurrent: Bool
    let isFuture: Bool

    var body: some View {
        if isFuture {
            Line()
                .stroke(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2]))
                .frame(height: 3)
        } else if days == 0 {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(.systemFill))
                .frame(height: 3)
        } else {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 1.5,
                                               bottomTrailingRadius: 1.5, topTrailingRadius: 4)
            if isCurrent {
                shape.fill(AppTheme.saffron)
                    .frame(height: height)
                    .shadow(color: AppTheme.saffronGlow, radius: 6)
            } else {
                shape.fill(AppTheme.bar)
                    .frame(height: height)
            }
        }
    }

    /// A horizontal line along the top edge.
    nonisolated private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.75))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 0.75))
            return path
        }
    }
}

// MARK: - Countries this year

/// The countries with travel days this year, most days first: flag, name
/// and days. A country with trips opens the Trips tab filtered to it.
struct StatsYearCountriesCard: View {
    let overview: StatsOverview
    let countryStats: [CountryStat]

    var body: some View {
        let entries = overview.countriesThisYear
        if !entries.isEmpty {
            let tripCounts = Dictionary(countryStats.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            StatsSection(
                title: String(localized: "stats.countries.title", defaultValue: "Countries", comment: "Stats card title for the countries visited."),
                spacing: 0, padded: false
            ) {
                Text(String(localized: "stats.countries.this-year-count", defaultValue: "\(entries.count, format: .number) this year", comment: "Stats Countries card caption: how many countries have travel days this year, such as 9 this year."))
            } content: {
                ForEach(Array(entries.enumerated()), id: \.element.code) { index, entry in
                    YearCountryRow(entry: entry, stat: tripCounts[entry.code], showsSeparator: index > 0)
                }
            }
        }
    }
}

private struct YearCountryRow: View {
    let entry: StatsAggregator.CountryDays
    let stat: CountryStat?
    let showsSeparator: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var name: String {
        if let stat { return StatsView.countryDisplayName(stat) }
        return StatsText.regionName(entry.code)
    }

    var body: some View {
        if (stat?.tripCount ?? 0) > 0 {
            Button {
                TripsTabRouter.shared.requestCountryFilter(entry.code)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Trips tab filtered to \(name)")
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            FlagView(iso: entry.code, size: .large)
            Text(name)
                .font(.body)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: 8)
            Text(StatsText.emphasizing(StatsText.plain(entry.days), in: StatsText.days(entry.days),
                                       font: AppTheme.stat(.body)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(.rect)
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 0.5)
                    .padding(.leading, 64)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - By Year

/// Travel days per calendar year (zero years included), the current year
/// saffron, with the selected year's totals beneath. Every number uses the
/// `YearStat` definitions.
///
/// A tap on a bar selects that year and the selection sticks; leaving the
/// page forgets it, so the page always opens on the current year. Selection
/// is a plain tap on a chart overlay rather than `chartXSelection`, whose
/// touch gesture is press-and-hold and releases the value when the finger
/// lifts.
struct StatsByYearCard: View {

    let overview: StatsOverview

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The tapped bar's x-value (the year as a label), or nil.
    @State private var selectedLabel: String?

    private var shown: [StatsAggregator.YearStat] { overview.years }

    private var selected: StatsAggregator.YearStat? {
        if let selectedLabel,
           let match = shown.first(where: { Self.label($0.year) == selectedLabel }) {
            return match
        }
        return shown.first { $0.year == overview.currentYear } ?? shown.last
    }

    /// Year labels are categorical: a numeric x-axis would space the bars
    /// by value and group the digits ("2,026").
    private static func label(_ year: Int) -> String {
        String(year)
    }

    private static var yearAxisLabel: String {
        String(localized: "stats.by-year.axis.year", defaultValue: "Year", comment: "Axis label for the year in the per-year travel chart.")
    }

    static var daysLabel: String {
        String(localized: "stats.this-year.travel-days", defaultValue: "Travel Days", comment: "Stats label for the number of days spent on trips, in the This Year tiles and the per-year chart.")
    }

    private static var tripsLabel: String {
        String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips.")
    }

    private static var countriesLabel: String {
        String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries.")
    }

    private static func plain(_ value: Int) -> String {
        StatsText.grouped(value)
    }

    /// One bar's VoiceOver value: "46, Travel Days".
    private static func barValue(_ stat: StatsAggregator.YearStat) -> String {
        [plain(stat.days), daysLabel].joined(separator: ", ")
    }

    /// What the row shows, in its order, as VoiceOver read it when combined.
    private static func accessibilityValue(_ stat: StatsAggregator.YearStat) -> String {
        [label(stat.year),
         plain(stat.trips), tripsLabel,
         plain(stat.countries), countriesLabel,
         plain(stat.days), daysLabel]
            .joined(separator: ", ")
    }

    var body: some View {
        if shown.count > 1 {
            StatsSection(title: String(localized: "stats.by-year.title", defaultValue: "By Year", comment: "Stats card title for the per-year travel chart.")) {
                Text(Self.daysLabel)
            } content: {
                byYear

                Text(String(localized: "stats.this-year.footnote", defaultValue: "Travel days include a trip in progress. Trips and countries count finished trips in the year they started. First recorded counts countries recorded for the first time.", comment: "Stats This Year card footnote explaining what each number counts."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedLabel)
            // The Stats tab keeps its view tree; forgetting the tap here is
            // what makes the next visit open on the current year again.
            .onDisappear { selectedLabel = nil }
        }
    }

    /// Cobalt bars, the current year saffron; unselected bars fade.
    private static func barStyle(isCurrent: Bool, isSelected: Bool) -> Color {
        (isCurrent ? AppTheme.saffron : AppTheme.bar).opacity(isSelected ? 1 : 0.35)
    }

    @ViewBuilder
    private var byYear: some View {
        let shown = shown
        let selected = selected
        let peak = PeriodBar.peak(shown.map { ($0.year, $0.days) })

        Chart(shown) { stat in
            let isCurrent = stat.year == overview.currentYear
            BarMark(
                x: .value(Self.yearAxisLabel, Self.label(stat.year)),
                y: .value(Self.daysLabel, stat.days),
                width: .ratio(0.7)
            )
            .foregroundStyle(Self.barStyle(isCurrent: isCurrent, isSelected: stat.year == selected?.year))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 1.5,
                                              bottomTrailingRadius: 1.5, topTrailingRadius: 4))
            .annotation(position: .top, spacing: 4) {
                Text(stat.days, format: .number)
                    .font(.caption2.monospacedDigit())
                    .fontWeight(stat.year == peak || isCurrent ? .bold : nil)
                    .foregroundStyle(isCurrent ? AppTheme.saffronText : .secondary)
            }
            .accessibilityLabel(Self.label(stat.year))
            .accessibilityValue(Self.barValue(stat))
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        if let label: String = proxy.value(atX: x) {
                            selectedLabel = label
                        }
                    }
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let year = value.as(String.self) {
                        Text(year)
                            .font(.caption2)
                            .fontWeight(year == Self.label(overview.currentYear) ? .bold : nil)
                            .foregroundStyle(year == Self.label(overview.currentYear) ? AppTheme.saffronText : .secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 150)

        if let selected {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text(Self.label(selected.year))
                    .font(AppTheme.stat(.title3))
                    .frame(minWidth: 52, alignment: .leading)
                yearTile(value: selected.trips, label: Self.tripsLabel)
                yearTile(value: selected.countries, label: Self.countriesLabel)
                yearTile(value: selected.days, label: Self.daysLabel)
            }
            // The chart's tap has no VoiceOver equivalent, so the row is
            // adjustable: swiping up or down selects the next or the
            // previous year, and the value reads the year's totals.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.yearAxisLabel)
            .accessibilityValue(Self.accessibilityValue(selected))
            .accessibilityAdjustableAction { direction in
                guard let index = shown.firstIndex(where: { $0.year == selected.year }) else { return }
                let next: Int
                switch direction {
                case .increment: next = index + 1
                case .decrement: next = index - 1
                @unknown default: return
                }
                guard shown.indices.contains(next) else { return }
                selectedLabel = Self.label(shown[next].year)
            }
        }
    }

    private func yearTile(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value, format: .number)
                .font(AppTheme.stat(.title3, weight: .semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.inset, in: .rect(cornerRadius: AppTheme.thumbLarge))
    }
}
