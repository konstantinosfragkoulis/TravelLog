//
//  StatsYearCard.swift
//  TravelLog
//

import Charts
import SwiftUI

/// The "This Year" card: this year's travel days, trips, countries and
/// first-recorded countries, each against last year, over the By Year bars
/// (travel days per calendar year, zero years included) with the selected
/// year's totals beneath. Every number uses the `YearStat` definitions, so
/// the tiles and the current year's bar always agree.
///
/// A tap on a bar selects that year and the selection sticks; leaving the
/// page forgets it, so the page always opens on the current year. Selection
/// is a plain tap on a chart overlay rather than `chartXSelection`, whose
/// touch gesture is press-and-hold and releases the value when the finger
/// lifts. Content layer: the same flat material card as its Stats siblings.
struct StatsYearCard: View {

    let overview: StatsOverview
    /// Remembered (pre-TravelLog) countries carry no date: never first recorded.
    let rememberedCodes: Set<String>

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

    /// Today's Gregorian label year in the supplied calendar's time zone.
    static func currentYear(now: Date, calendar: Calendar) -> Int {
        StatsOverview.currentYear(now: now, calendar: calendar)
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

    private static var firstRecordedLabel: String {
        String(localized: "stats.this-year.first-recorded", defaultValue: "First Recorded", comment: "Stats This Year tile label for countries recorded for the first time this year. Not 'first ever': countries visited before the app was installed are not counted.")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "stats.this-year.title", defaultValue: "This Year", comment: "Stats card title for the current year's totals compared with last year."))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(String(localized: "stats.this-year.so-far", defaultValue: "\(Self.label(overview.currentYear)) so far", comment: "Stats This Year card caption; the placeholder is the current year, such as 2026."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            tiles

            if shown.count > 1 {
                Divider()
                byYear
            }

            Text(String(localized: "stats.this-year.footnote", defaultValue: "Travel days include a trip in progress. Trips and countries count finished trips in the year they started. First recorded counts countries recorded for the first time.", comment: "Stats This Year card footnote explaining what each number counts."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: selectedLabel)
        // The Stats tab keeps its view tree; forgetting the tap here is
        // what makes the next visit open on the current year again.
        .onDisappear { selectedLabel = nil }
    }

    // MARK: - Tiles

    private var tiles: some View {
        let thisYear = overview.thisYear
        let lastYear = overview.lastYear
        let firstRecorded = thisYear.firstRecordedCount(excluding: rememberedCodes)
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            YearDeltaTile(
                title: Self.daysLabel, icon: "suitcase.fill", tint: .teal,
                value: thisYear.travelDays, previous: comparing(lastYear.travelDays))
            YearDeltaTile(
                title: Self.tripsLabel, icon: "map.fill", tint: .blue,
                value: thisYear.trips, previous: comparing(lastYear.trips))
            YearDeltaTile(
                title: Self.countriesLabel, icon: "flag.fill", tint: .indigo,
                value: thisYear.countries, previous: comparing(lastYear.countries))
            YearDeltaTile(
                title: Self.firstRecordedLabel, icon: "sparkles", tint: .orange,
                value: firstRecorded,
                unit: firstRecorded == 1
                    ? String(localized: "stats.this-year.first-recorded.unit.one", defaultValue: "country", comment: "Unit after the number on the First Recorded tile, for one country.")
                    : String(localized: "stats.this-year.first-recorded.unit.other", defaultValue: "countries", comment: "Unit after the number on the First Recorded tile, for zero or several countries."),
                previous: comparing(lastYear.firstRecordedCount(excluding: rememberedCodes)))
        }
    }

    /// Last year's value, or nil when last year was not tracked (no delta).
    private func comparing(_ value: Int) -> Int? {
        overview.comparesWithLastYear ? value : nil
    }

    // MARK: - By Year

    @ViewBuilder
    private var byYear: some View {
        let shown = shown
        let selected = selected
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "stats.by-year.title", defaultValue: "By Year", comment: "Stats card title for the per-year travel chart."))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(Self.daysLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Chart(shown) { stat in
            BarMark(
                x: .value(Self.yearAxisLabel, Self.label(stat.year)),
                y: .value(Self.daysLabel, stat.days)
            )
            .foregroundStyle(.tint)
            .opacity(stat.year == selected?.year ? 1 : 0.35)
            .cornerRadius(5)
            .annotation(position: .top, spacing: 4) {
                Text(stat.days, format: .number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
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
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
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
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

/// One This Year number with its change against last year. The change is
/// neutral (secondary colour and an arrow): travelling less is not bad.
private struct YearDeltaTile: View {
    let title: String
    let icon: String
    let tint: Color
    let value: Int
    var unit: String? = nil
    /// Last year's value; nil hides the change (last year was not tracked).
    let previous: Int?

    private var valueText: String { StatsText.grouped(value) }

    private var delta: Int? { previous.map { value - $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valueText)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let delta {
                HStack(spacing: 3) {
                    Image(systemName: delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "equal")
                        .font(.caption2.weight(.semibold))
                    Text(delta == 0
                         ? String(localized: "stats.this-year.delta.same", defaultValue: "Same as last year", comment: "Stats This Year tile: the number equals last year's.")
                         : String(localized: "stats.this-year.delta.vs-last-year", defaultValue: "\(abs(delta), format: .number.grouping(.never)) vs last year", comment: "Stats This Year tile: the difference from last year, after an up or down arrow; the placeholder is the absolute difference."))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let amount = [valueText, unit].compactMap { $0 }.joined(separator: " ")
        guard let delta else { return amount }
        let change: String
        if delta > 0 {
            change = String(localized: "stats.this-year.delta.up.accessibility", defaultValue: "up \(delta, format: .number.grouping(.never)) from last year", comment: "VoiceOver change on a Stats This Year tile when the number grew; follows the value and a comma.")
        } else if delta < 0 {
            change = String(localized: "stats.this-year.delta.down.accessibility", defaultValue: "down \(-delta, format: .number.grouping(.never)) from last year", comment: "VoiceOver change on a Stats This Year tile when the number shrank; follows the value and a comma.")
        } else {
            change = String(localized: "stats.this-year.delta.same", defaultValue: "Same as last year", comment: "Stats This Year tile: the number equals last year's.")
        }
        return "\(amount), \(change)"
    }
}
