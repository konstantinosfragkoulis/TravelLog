//
//  FlightTotalsSheet.swift
//  TravelLog
//
//  Every total of the Flight Log's selection, opened from its summary:
//  the route map, the distance with one globe per lap of the Earth, the
//  four counts, the record flights, the flights by year and the busiest
//  airports. Derived once per selection (`FlightTotalsSummary`).
//

import SwiftUI

struct FlightTotalsSheet: View {
    typealias Flight = CollectionsAggregator.FlightRecord

    let flights: [Flight]
    /// "All years", or the year the totals cover.
    let selection: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var memo = SearchMemo<[Flight], Totals>()
    @State private var selectedStation: String?
    /// The distance figure's 46 pt, scaled with the reader's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var distanceSize: CGFloat = 46

    private struct Totals {
        let stats: CollectionsAggregator.FlightStats
        let summary: FlightTotalsSummary
    }

    static let mapHeight: CGFloat = 236

    var body: some View {
        let totals = memo.value(for: flights) {
            Totals(stats: CollectionsAggregator.flightStats(from: flights),
                   summary: FlightTotalsSummary(flights, currentYear: Self.currentYear))
        }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    routeMap(totals.summary)
                    distance(totals.stats)
                    glance(totals.stats)
                    records(totals.summary)
                    byYear(totals.summary)
                    busiestAirports(totals.summary)
                    Text(String(localized: "collections.flights.totals.footer.tap", defaultValue: "Routes are inferred from location data. Durations are estimates unless you set a flight's times: tap a flight to set them.", comment: "Flight Log footer under the totals: routes are inferred, durations estimated unless the user set the times, which tapping a flight offers."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                }
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            // The app's page ground, the sections on their cards.
            .background(TotalsTint.ground)
            .navigationTitle("Totals")
            .navigationSubtitle(selection)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationBackground(TotalsTint.ground)
    }

    private static var currentYear: Int {
        Calendar.current.component(.year, from: .now)
    }

    // MARK: Route map

    @ViewBuilder
    private func routeMap(_ summary: FlightTotalsSummary) -> some View {
        let stations = summary.stations.filter { $0.latitude != nil && $0.longitude != nil }
        if !stations.isEmpty {
            let byID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let arcs = summary.routes.compactMap { route -> OutlineMapArc? in
                guard let from = byID[route.from], let to = byID[route.to],
                      let lat1 = from.latitude, let lon1 = from.longitude,
                      let lat2 = to.latitude, let lon2 = to.longitude else { return nil }
                return OutlineMapArc(from: (lat1, lon1), to: (lat2, lon2), flights: route.flights)
            }
            let marks = stations.enumerated().map { index, station in
                OutlineMapMark(id: station.id, latitude: station.latitude ?? 0, longitude: station.longitude ?? 0,
                               style: .routeStation, emphasized: index == 0 && stations.count > 1)
            }
            GeometryReader { geometry in
                let projection = OutlineProjection.fitting(
                    stations.map { ($0.latitude ?? 0, $0.longitude ?? 0) }, kind: .equalEarth,
                    size: geometry.size, insets: EdgeInsets(top: 54, leading: 22, bottom: 20, trailing: 22),
                    minimumSpanDegrees: 36)
                OutlineMap(projection: projection, marks: marks, arcs: arcs, selection: $selectedStation,
                           callout: { id in byID[id].map { callout($0) } }, calloutTop: 52)
            }
            .frame(height: Self.mapHeight)
            .overlay(alignment: .topLeading) {
                if !summary.routes.isEmpty {
                    routeChip(summary.routes.count)
                        .padding(10)
                }
            }
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "flight-totals.map.label", defaultValue: "Route map", comment: "Flight totals: accessibility label of the map of every route flown."))
            .accessibilityValue(Text(verbatim: "\(StatsText.grouped(summary.routes.count)) \(Self.routesUnit(summary.routes.count))"))
        }
    }

    private func routeChip(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: StatsText.grouped(count))
                .font(AppTheme.stat(.subheadline))
            Text(Self.routesUnit(count))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 13)
        .frame(minHeight: 34)
        .glassEffect(in: .capsule)
    }

    private static func routesUnit(_ count: Int) -> String {
        count == 1
            ? String(localized: "flight-totals.routes.unit.one", defaultValue: "route", comment: "Flight totals map: unit beside the number of routes drawn, for one; the number is shown separately.")
            : String(localized: "flight-totals.routes.unit.other", defaultValue: "routes", comment: "Flight totals map: unit beside the number of routes drawn, for several; the number is shown separately.")
    }

    /// "Singapore Changi Airport", then "SIN · 2 flights · since 2017".
    private func callout(_ station: FlightTotalsSummary.Station) -> (title: String, detail: String) {
        var parts: [String] = []
        if let code = station.code { parts.append(code) }
        parts.append(Self.flightsText(station.flights))
        if let year = station.firstYear { parts.append(CollectionsText.since(year)) }
        return (station.name, parts.joined(separator: " · "))
    }

    private static func flightsText(_ count: Int) -> String {
        count == 1
            ? String(localized: "collections.flights.year-count.one", defaultValue: "\(count, format: .number.grouping(.never)) flight", comment: "Flight Log year section count for one flight.")
            : String(localized: "collections.flights.year-count.other", defaultValue: "\(count, format: .number.grouping(.never)) flights", comment: "Flight Log year section count for multiple flights.")
    }

    private static func flightsUnit(_ count: Int) -> String {
        count == 1
            ? String(localized: "flight-log.summary.flights.one", defaultValue: "flight", comment: "Flight Log summary label under the number of flights, for one flight.")
            : String(localized: "flight-log.summary.flights.other", defaultValue: "flights", comment: "Flight Log summary label under the number of flights, for several flights.")
    }

    // MARK: Distance

    /// The distance flown, the flights and their time under it, then a
    /// globe for every lap of the Earth, the last one filled as far as it
    /// got. Under a tenth of a lap the globes say nothing and stay out.
    @ViewBuilder
    private func distance(_ stats: CollectionsAggregator.FlightStats) -> some View {
        let around = stats.totalKm / FlightTotalsSummary.earthCircumferenceKm
        // Unknown without any route geometry or estimate.
        if stats.totalKm.isFinite, stats.totalKm > 0 {
            let parts = UnitsFormatter.distanceParts(kilometers: stats.totalKm)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "collections.flight-stat.distance-flown", defaultValue: "Distance flown", comment: "Flight Log total statistic label for distance flown."))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: parts.value)
                        .font(.system(size: distanceSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .tracking(-0.8)
                    Text(verbatim: parts.unit)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 2)
                Text(subline(stats))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if around >= 0.1 {
                    LapGlobes(laps: FlightTotalsSummary.laps(km: stats.totalKm))
                        .padding(.top, 14)
                    captionRow {
                        Text(String(localized: "flight-totals.globes.caption", defaultValue: "Each globe is one trip around the Earth", comment: "Flight totals: caption under the row of globes, one per time the distance flown goes around the Earth; the last is filled as far as it got."))
                    } trailing: {
                        Text(String(localized: "collections.flight-stat.around-world.value", defaultValue: "\(around, format: .number.precision(.fractionLength(1)))×", comment: "Flight Log value showing an equivalent number of trips around Earth."))
                            .font(AppTheme.stat(.subheadline))
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 20)
            .accessibilityElement(children: .combine)
        }
    }

    /// "212 flights · ≈ 631h in the air".
    private func subline(_ stats: CollectionsAggregator.FlightStats) -> String {
        let flights = Self.flightsText(stats.totalFlights)
        guard stats.totalEstimatedHours > 0 else { return flights }
        let hours = FlightLogView.summaryHours(stats.totalEstimatedHours)
        return String(localized: "flight-totals.distance.subtitle", defaultValue: "\(flights) · ≈ \(hours) in the air", comment: "Flight totals: line under the distance flown: the number of flights, then the estimated time in the air, such as 212 flights · ≈ 631h in the air.")
    }

    /// A caption and its figure on one line, the figure under it at
    /// accessibility sizes.
    private func captionRow<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            leading()
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            trailing()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    // MARK: At a glance

    private func glance(_ stats: CollectionsAggregator.FlightStats) -> some View {
        let tiles: [(icon: String, value: Int, label: String)] = [
            ("airplane", stats.totalFlights, String(localized: "collections.flight-stat.flights", defaultValue: "Flights", comment: "Flight Log total statistic label for flights.")),
            ("globe", stats.internationalCount, String(localized: "collections.flight-stat.international", defaultValue: "International", comment: "Flight Log total statistic label for international flights.")),
            ("moon", stats.overnightCount, String(localized: "collections.flight-stat.overnight", defaultValue: "Overnight", comment: "Flight Log total statistic label for overnight flights.")),
            ("clock", stats.timeZonesCrossedTotal, String(localized: "collections.flight-stat.time-zones-crossed", defaultValue: "Time zones crossed", comment: "Flight Log total statistic label for time zones crossed.")),
        ]
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "flight-totals.section.at-a-glance", defaultValue: "At a Glance", comment: "Flight totals section title over the four counts: flights, international, overnight and time zones crossed."))
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + columns, tiles.count), id: \.self) { index in
                            glanceTile(icon: tiles[index].icon, value: tiles[index].value, label: tiles[index].label)
                        }
                    }
                }
            }
        }
    }

    private func glanceTile(icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(AppTheme.cobaltFill, in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: StatsText.grouped(value))
                    .font(AppTheme.stat(.title2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TotalsTint.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Records

    @ViewBuilder
    private func records(_ summary: FlightTotalsSummary) -> some View {
        if summary.longest != nil || summary.mostFlown != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(String(localized: "flight-totals.section.records", defaultValue: "Records", comment: "Flight totals section title over the longest, shortest and most flown flights."))
                    .padding(.bottom, -8)
                if let longest = summary.longest {
                    ticket(String(localized: "collections.flight-stat.longest-flight", defaultValue: "Longest flight", comment: "Flight Log statistic label for the longest flight."),
                           trailing: "≈ \(FlightLogView.summaryHours(longest.estimatedHours))",
                           from: longest.from, to: longest.to,
                           middle: UnitsFormatter.formatDistance(kilometers: longest.distanceKm))
                }
                if let shortest = summary.shortest {
                    ticket(String(localized: "collections.flight-stat.shortest-flight", defaultValue: "Shortest flight", comment: "Flight Log statistic label for the shortest flight."),
                           trailing: "≈ \(FlightLogView.summaryHours(shortest.estimatedHours))",
                           from: shortest.from, to: shortest.to,
                           middle: UnitsFormatter.formatDistance(kilometers: shortest.distanceKm))
                }
                if let route = summary.mostFlown {
                    ticket(String(localized: "collections.flight-stat.most-flown-route", defaultValue: "Most flown route", comment: "Flight Log statistic label for the route flown most often."),
                           trailing: String(localized: "flight-totals.record.both-ways", defaultValue: "Both ways", comment: "Flight totals: beside the most flown route, which counts flights in either direction."),
                           from: route.first, to: route.second,
                           middle: "×\(StatsText.grouped(route.flights))")
                }
            }
        }
    }

    /// A record as a ticket: the codes at either end over their cities and
    /// flags, an arc between them with the figure under it.
    private func ticket(_ title: String, trailing: String, from: FlightTotalsSummary.End,
                        to: FlightTotalsSummary.End, middle: String) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(verbatim: trailing)
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            if stacked {
                ticketEnd(from, trailing: false)
                Text(verbatim: middle)
                    .font(AppTheme.stat(.subheadline))
                ticketEnd(to, trailing: false)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ticketEnd(from, trailing: false)
                        .layoutPriority(1)
                    VStack(spacing: 0) {
                        TicketArc()
                            .stroke(AppTheme.routeLine, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .frame(height: 30)
                        Text(verbatim: middle)
                            .font(AppTheme.stat(.subheadline))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(minWidth: 44, maxWidth: .infinity)
                    ticketEnd(to, trailing: true)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .background(TotalsTint.card, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func ticketEnd(_ end: FlightTotalsSummary.End, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(verbatim: end.label)
                .font(AppTheme.stat(.title))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 5) {
                if !trailing { FlagView(iso: end.isoCountryCode, size: .small) }
                if let city = end.city {
                    Text(verbatim: city)
                        .lineLimit(1)
                }
                if trailing { FlagView(iso: end.isoCountryCode, size: .small) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64, alignment: trailing ? .trailing : .leading)
    }

    // MARK: By year

    @ViewBuilder
    private func byYear(_ summary: FlightTotalsSummary) -> some View {
        let years = summary.years
        if !years.isEmpty {
            let current = Self.currentYear
            let peak = summary.busiestYear
            let top = max(peak?.flights ?? 1, 1)
            // Past sixteen years every other label shows, the current one kept.
            let thin = years.count > 16
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(String(localized: "flight-totals.section.by-year", defaultValue: "Flights by Year", comment: "Flight totals section title over the bars of flights per year."),
                              trailing: years.count == 1
                                ? String(localized: "flight-totals.years.one", defaultValue: "\(years.count, format: .number.grouping(.never)) year", comment: "Flight totals: beside Flights by Year, how many years the bars span, for one.")
                                : String(localized: "flight-totals.years.other", defaultValue: "\(years.count, format: .number.grouping(.never)) years", comment: "Flight totals: beside Flights by Year, how many years the bars span, for several."))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: years.count > 20 ? 2 : 5) {
                        ForEach(years, id: \.year) { entry in
                            let isCurrent = entry.year == current
                            let showsValue = entry.flights > 0 && (isCurrent || entry.year == peak?.year)
                            let showsLabel = !thin || (current - entry.year).isMultiple(of: 2)
                            VStack(spacing: 4) {
                                Text(verbatim: showsValue ? StatsText.grouped(entry.flights) : " ")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(isCurrent ? AppTheme.saffronText : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .fixedSize(horizontal: false, vertical: true)
                                YearBar(height: entry.flights == 0 ? 0 : max(4, (CGFloat(entry.flights) / CGFloat(top) * 86).rounded()),
                                        isCurrent: isCurrent)
                                Text(verbatim: showsLabel ? "\u{2019}" + String(String(entry.year).suffix(2)) : " ")
                                    .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                                    .foregroundStyle(isCurrent ? AppTheme.saffronText : .secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "flight-totals.section.by-year", defaultValue: "Flights by Year", comment: "Flight totals section title over the bars of flights per year."))
                    .accessibilityValue(Text(verbatim: years
                        .map { "\($0.year), \(Self.flightsText($0.flights))" }
                        .joined(separator: "; ")))

                    let thisYear = years.first { $0.year == current }?.flights ?? 0
                    if peak != nil || thisYear > 0 {
                        captionRow {
                            if let peak, years.count > 1 {
                                Text(String(localized: "flight-totals.years.busiest", defaultValue: "Busiest: \(String(peak.year)), \(Self.flightsText(peak.flights))", comment: "Flight totals: caption under the year bars naming the busiest year and its flights, such as Busiest: 2024, 24 flights."))
                            }
                        } trailing: {
                            if thisYear > 0 {
                                Text(thisYear == 1
                                     ? String(localized: "flight-totals.years.so-far.one", defaultValue: "\(thisYear, format: .number.grouping(.never)) so far this year", comment: "Flight totals: caption under the year bars, the flights so far in the current year, for one.")
                                     : String(localized: "flight-totals.years.so-far.other", defaultValue: "\(thisYear, format: .number.grouping(.never)) so far this year", comment: "Flight totals: caption under the year bars, the flights so far in the current year, for several."))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(AppTheme.saffronText)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 13)
                .background(TotalsTint.card, in: .rect(cornerRadius: 22, style: .continuous))
            }
        }
    }

    // MARK: Busiest airports

    @ViewBuilder
    private func busiestAirports(_ summary: FlightTotalsSummary) -> some View {
        let airports = summary.airports
        if !airports.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(String(localized: "flight-totals.section.busiest-airports", defaultValue: "Busiest Airports", comment: "Flight totals section title over the airports with the most flights."),
                              trailing: CollectionsText.flownThrough(airports.count))
                VStack(spacing: 0) {
                    ForEach(Array(airports.prefix(5).enumerated()), id: \.element.id) { index, airport in
                        if index > 0 {
                            Divider().padding(.leading, 64)
                        }
                        airportRow(airport)
                    }
                }
                .background(TotalsTint.card, in: .rect(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func airportRow(_ airport: FlightTotalsSummary.Station) -> some View {
        HStack(spacing: 12) {
            FlagView(iso: airport.isoCountryCode, size: .large)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: airport.code ?? airport.id)
                    .font(.body.weight(.bold))
                    .monospaced()
                if airport.name != airport.code {
                    Text(verbatim: airport.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: StatsText.grouped(airport.flights))
                    .font(AppTheme.stat(.body))
                Text(Self.flightsUnit(airport.flights))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if let trailing {
                Text(verbatim: trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 26)
        .padding(.bottom, 9)
    }
}

/// The page ground and card fill as the app's pages draw them. A sheet
/// resolves system colours a level up (lighter grays in dark), which would
/// set the totals apart from every other page.
private enum TotalsTint {
    static let ground = baseLevel(.systemGroupedBackground)
    static let card = baseLevel(.secondarySystemGroupedBackground)

    private static func baseLevel(_ color: UIColor) -> Color {
        Color(UIColor { traits in
            color.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .base })
        })
    }
}

/// One year's bar: cobalt, the current year saffron with its glow, a
/// stub for a year without flights.
private struct YearBar: View {
    let height: CGFloat
    let isCurrent: Bool

    var body: some View {
        if height == 0 {
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
}

/// The globes in a wrapping row: one per lap of the Earth, whole ones
/// cobalt, the last one saffron as far as it got.
private struct LapGlobes: View {
    let laps: [Double]

    var body: some View {
        let size: CGFloat = laps.count > 24 ? 16 : 22
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size), spacing: 5)],
                  alignment: .leading, spacing: 5) {
            ForEach(Array(laps.enumerated()), id: \.offset) { _, fill in
                LapGlobe(fill: fill)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LapGlobe: View {
    /// 1 for a whole lap; the share of the last one.
    let fill: Double

    var body: some View {
        Canvas { context, size in
            let disc = Path(ellipseIn: CGRect(origin: .zero, size: size))
            if fill >= 1 {
                context.fill(disc, with: .color(AppTheme.bar))
            } else {
                context.fill(disc, with: .color(Color(.systemFill)))
                var clipped = context
                clipped.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * fill, height: size.height)))
                clipped.fill(disc, with: .color(AppTheme.saffron))
            }
            // A meridian and the equator.
            var lines = Path(ellipseIn: CGRect(x: size.width * 0.31, y: 0.6,
                                               width: size.width * 0.38, height: size.height - 1.2))
            lines.move(to: CGPoint(x: 0.6, y: size.height / 2))
            lines.addLine(to: CGPoint(x: size.width - 0.6, y: size.height / 2))
            context.stroke(lines, with: .color(.white.opacity(0.32)), lineWidth: 1)
        }
    }
}

/// The ticket's arc, rising between the two codes.
private struct TicketArc: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 3))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 3),
                          control: CGPoint(x: rect.midX, y: rect.minY - 8))
        return path
    }
}

/// Phrases the Collections pages share.
enum CollectionsText {
    /// "since 2012": the year of the first visit or flight.
    static func since(_ year: Int) -> String {
        String(localized: "collections.since-year", defaultValue: "since \(String(year))", comment: "Collections: the year of a first visit or flight, after a count and a middle dot, such as since 2012. Lowercase.")
    }

    /// "124 flown through": airports with a flight.
    static func flownThrough(_ count: Int) -> String {
        count == 1
            ? String(localized: "collections.airports.flown-through.one", defaultValue: "\(count, format: .number.grouping(.never)) flown through", comment: "Collections: how many airports had a flight through them, for one.")
            : String(localized: "collections.airports.flown-through.other", defaultValue: "\(count, format: .number.grouping(.never)) flown through", comment: "Collections: how many airports had a flight through them, for several.")
    }

    /// "138 airports".
    static func airports(_ count: Int) -> String {
        count == 1
            ? String(localized: "collections.airports.count.one", defaultValue: "\(count, format: .number) airport", comment: "Collections: a number of airports, for one.")
            : String(localized: "collections.airports.count.other", defaultValue: "\(count, format: .number) airports", comment: "Collections: a number of airports, for several.")
    }
}
