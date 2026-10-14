//
//  StatsYearCard.swift
//  TravelLog
//

import Charts
import SwiftUI

/// The "By Year" card: travel days per calendar year as a bar chart, with
/// the selected year's trips, countries and days beneath it. A tap on a
/// bar selects that year and the selection sticks; leaving the page
/// forgets it, so the page always opens on the current year (or, before
/// the first trip of the year, the latest year with data). Content layer:
/// the same flat material card as its Stats siblings.
///
/// Selection is a plain tap on a chart overlay rather than
/// `chartXSelection`, whose touch gesture is press-and-hold and releases
/// the value when the finger lifts.
struct StatsYearCard: View {

    /// Ascending by year, as `StatsAggregator` hands them over.
    let years: [StatsAggregator.YearStat]

    /// The tapped bar's x-value (the year as a label), or nil.
    @State private var selectedLabel: String?

    /// Beyond this many bars the labels collide; the far past is the
    /// passport's job.
    private static let maxBars = 8

    private var shown: [StatsAggregator.YearStat] {
        Array(years.suffix(Self.maxBars))
    }

    private var selected: StatsAggregator.YearStat? {
        if let selectedLabel,
           let match = shown.first(where: { Self.label($0.year) == selectedLabel }) {
            return match
        }
        let currentYear = Self.currentYear(now: .now, calendar: .current)
        return shown.first { $0.year == currentYear } ?? shown.last
    }

    /// Today's Gregorian label year in the supplied calendar's time zone.
    static func currentYear(now: Date, calendar: Calendar) -> Int {
        var gregorian = TravelDays.labelCalendar
        gregorian.timeZone = calendar.timeZone
        return gregorian.component(.year, from: now)
    }

    /// Year labels are categorical: a numeric x-axis would space the bars
    /// by value and group the digits ("2,026").
    private static func label(_ year: Int) -> String {
        String(year)
    }

    private static var yearAxisLabel: String {
        String(localized: "stats.by-year.axis.year", defaultValue: "Year", comment: "Axis label for the year in the per-year travel chart.")
    }

    private static var daysLabel: String {
        String(localized: "stats.highlight.days-traveling", defaultValue: "Days Traveling", comment: "Statistics highlight title for travel days.")
    }

    private static var tripsLabel: String {
        String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips.")
    }

    private static var countriesLabel: String {
        String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries.")
    }

    /// What the row shows, in its order, as VoiceOver read it when combined.
    private static func accessibilityValue(_ stat: StatsAggregator.YearStat) -> String {
        [label(stat.year),
         stat.trips.formatted(.number.grouping(.never)), tripsLabel,
         stat.countries.formatted(.number.grouping(.never)), countriesLabel,
         stat.days.formatted(.number.grouping(.never)), daysLabel]
            .joined(separator: ", ")
    }

    var body: some View {
        let shown = shown
        let selected = selected
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "stats.by-year.title", defaultValue: "By Year", comment: "Stats card title for the per-year travel chart."))
                .font(.headline)

            Chart(shown) { stat in
                BarMark(
                    x: .value(Self.yearAxisLabel, Self.label(stat.year)),
                    y: .value(Self.daysLabel, stat.days)
                )
                .foregroundStyle(.tint)
                .opacity(stat.year == selected?.year ? 1 : 0.35)
                .cornerRadius(5)
                .annotation(position: .top, spacing: 4) {
                    Text(stat.days, format: .number.grouping(.never))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
                HStack(spacing: 8) {
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
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: selectedLabel)
        // The Stats tab keeps its view tree; forgetting the tap here is
        // what makes the next visit open on the current year again.
        .onDisappear { selectedLabel = nil }
    }

    private func yearTile(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value, format: .number.grouping(.never))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}
