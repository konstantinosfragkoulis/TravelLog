//
//  PassportDetailView.swift
//  TravelLog
//
//  The expanded Passport, zoomed open from the Stats page's Passport card:
//  a full-screen cobalt passport in both appearances. The cover (crest,
//  title, the four figures, member since), then one stamp page per year
//  with travel behind a year switcher (arrows, a horizontal swipe, or the
//  year itself for a decade picker), every country with its days, the
//  lifetime totals and records, and the machine-readable lines that close
//  the book. Every value comes from the Stats aggregates already on screen.
//

import SwiftUI
import UIKit

struct PassportDetailView: View {

    /// The zoom transition's id, shared with the card that is its source.
    static let zoomID = "passport"

    let data: PassportData
    /// Forwarded from the card; an open page follows revocation too.
    let canShare: Bool
    let continents: Int
    let book: PassportBook

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 34
    private let rememberedCountries = RememberedCountriesStorage.shared

    /// The year on the page; nil shows the most recent.
    @State private var selectedYear: Int?
    /// The direction of the last year change, for the page's push.
    @State private var stepsForward = true
    /// Which switcher's year picker is open, if any.
    @State private var pickerSource: PickerSource?
    @State private var scroll = PassportScroll()
    /// The year page's top and bottom in the scroll content.
    @State private var pageSpan: PageSpan?
    /// The scroll view's top inset: the status and navigation bars.
    @State private var topInset: CGFloat = 0

    private nonisolated static let contentSpace = "passport.content"
    private static let yearPageID = "passport.year-page"

    var body: some View {
        let remembered = rememberedCountries.codes
        let pages = StampPage.pages(book.stampYears, firstRecorded: book.firstRecordedByYear,
                                    remembered: remembered, perPage: nil)
        let index = pages.firstIndex { $0.year == selectedYear } ?? pages.count - 1
        let stats = sortedCountryStats
        let rememberedOnly = remembered.subtracting(book.trackedCodes).sorted()
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    cover
                        .padding(.top, 16)

                    if pages.indices.contains(index) {
                        yearPage(pages, index: index)
                            .id(Self.yearPageID)
                            .padding(.top, 22)
                            .onGeometryChange(for: PageSpan.self) { proxy in
                                let frame = proxy.frame(in: .named(Self.contentSpace))
                                return PageSpan(top: frame.minY, bottom: frame.maxY)
                            } action: { pageSpan = $0 }
                    }

                    countries(stats, rememberedOnly: rememberedOnly, remembered: remembered)
                        .padding(.top, 20)
                    totals
                        .padding(.top, 24)
                    if hasRecords {
                        records
                            .padding(.top, 24)
                    }
                    machineReadable(stats, rememberedOnly: rememberedOnly)
                        .padding(.top, 26)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .coordinateSpace(.named(Self.contentSpace))
                .background(alignment: .topTrailing) {
                    // The foil lattice is printed on the cover: it scrolls with it,
                    // anchored at the screen's top trailing corner.
                    PassportLattice(scale: 1.45, extent: 14, lineWidth: 0.7 * 1.45.squareRoot())
                        .frame(width: 220 * 1.45, height: 190 * 1.45)
                        .offset(y: -topInset)
                }
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .onChange(of: selectedYear) {
                // A year changed while its page was scrolled under the bar (from
                // the pinned switcher, say): show the new year from its top.
                guard let pageSpan, scroll.y > pageSpan.top + 4 else { return }
                withAnimation(.snappy(duration: 0.32)) {
                    reader.scrollTo(Self.yearPageID, anchor: .top)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scroll.y = offset
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentInsets.top
            } action: { _, inset in
                topInset = inset
            }
        }
        .overlay(alignment: .top) {
            PassportTopFade(scroll: scroll, inset: topInset, span: pageSpan)
        }
        .overlay(alignment: .top) {
            if pages.indices.contains(index), let pageSpan {
                PassportPinnedSwitcher(scroll: scroll, span: pageSpan) {
                    switcher(pages, index: index, compact: true)
                }
            }
        }
        .overlay {
            // The open year picker dims the passport behind it.
            Color(UIColor(hex: 0x030722, alpha: 0.5))
                .ignoresSafeArea()
                .opacity(pickerSource == nil ? 0 : 1)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: pickerSource == nil)
        }
        .background {
            PassportBackdrop(scroll: scroll)
                .ignoresSafeArea()
        }
        .navigationTitle(String(localized: "passport.title", defaultValue: "Passport", comment: "Title of the expanded Passport page, which shows the stamp book and every country visited."))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title shows only once the cover has scrolled away.
            ToolbarItem(placement: .principal) {
                PassportBarTitle(scroll: scroll)
            }
            .sharedBackgroundVisibility(.hidden)
            if data.isShareable(aggregatesComplete: canShare) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: PassportShare(data: data),
                        preview: SharePreview(String(localized: "passport.share-preview", defaultValue: "TravelLog Passport", comment: "Share preview title for the TravelLog Passport image; keep TravelLog verbatim."))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share your passport")
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // The passport is the brand object: cobalt in both appearances.
        .environment(\.colorScheme, .dark)
    }

    // MARK: Cover

    private var cover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PassportCrest(side: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PASSPORT")
                        .font(.system(size: 12, weight: .bold).width(.expanded))
                        .tracking(2.88)
                        .foregroundStyle(AppTheme.foil)
                    Text("A lifetime of travel")
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(AppTheme.onField)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            FoilRule()
                .padding(.top, 16)
            coverFigures
                .padding(.top, 14)
            if let year = data.sinceYear {
                Text(PassportText.memberSince(year))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.onFieldSecondary)
                    .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private var coverFigures: some View {
        let figures = PassportText.coverFigures(data, continents: continents)
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 6, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                ForEach(figures, id: \.label) { coverFigure($0) }
            }
        } else {
            // The design's columns: 1.05, 1, 1, 1.
            CoverFigureRow(spacing: 6) {
                ForEach(figures, id: \.label) { coverFigure($0) }
            }
        }
    }

    private func coverFigure(_ entry: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.value)
                .font(.system(size: figureSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppTheme.onField)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(entry.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.onFieldSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Year pages

    private func yearPage(_ pages: [StampPage], index: Int) -> some View {
        PassportYearPage(page: pages[index], stepsForward: stepsForward,
                         canStepBack: index > 0, canStepForward: index < pages.count - 1,
                         step: { step(by: $0, in: pages, from: index) }) {
            switcher(pages, index: index, compact: false)
        }
    }

    private func switcher(_ pages: [StampPage], index: Int, compact: Bool) -> PassportYearSwitcher {
        let source: PickerSource = compact ? .pinned : .page
        return PassportYearSwitcher(
            page: pages[index], compact: compact,
            canStepBack: index > 0, canStepForward: index < pages.count - 1,
            step: { step(by: $0, in: pages, from: index) },
            showsPicker: Binding(get: { pickerSource == source },
                                 set: { pickerSource = $0 ? source : nil }),
            picker: PassportYearPicker(
                years: pages.map { ($0.year, $0.yearStampCount) },
                selected: pages[index].year,
                pick: { pick($0, in: pages, from: index) }))
    }

    private func step(by delta: Int, in pages: [StampPage], from index: Int) {
        let target = index + delta
        guard pages.indices.contains(target) else { return }
        stepsForward = delta > 0
        withAnimation(.snappy(duration: 0.32)) {
            selectedYear = pages[target].year
        }
    }

    private func pick(_ year: Int, in pages: [StampPage], from index: Int) {
        pickerSource = nil
        guard year != pages[index].year else { return }
        stepsForward = year > pages[index].year
        withAnimation(.snappy(duration: 0.32)) {
            selectedYear = year
        }
    }

    // MARK: Countries

    /// Tracked countries, most days first.
    private var sortedCountryStats: [CountryStat] {
        book.countryStats.sorted { lhs, rhs in
            let l = lhs.days ?? 0, r = rhs.days ?? 0
            if l != r { return l > r }
            if lhs.tripCount != rhs.tripCount { return lhs.tripCount > rhs.tripCount }
            return StatsView.countryDisplayName(lhs)
                .localizedCaseInsensitiveCompare(StatsView.countryDisplayName(rhs)) == .orderedAscending
        }
    }

    /// Tracked countries, then the remembered-only ones.
    private func countries(_ stats: [CountryStat], rememberedOnly: [String], remembered: Set<String>) -> some View {
        let total = book.trackedCodes.union(remembered).count
        return VStack(alignment: .leading, spacing: 0) {
            PassportSectionHeader(
                title: String(localized: "stats.countries.title", defaultValue: "Countries", comment: "Stats card title for the countries visited."),
                trailing: StatsText.grouped(total))
            LazyVStack(alignment: .leading, spacing: 0) {
                if stats.isEmpty && rememberedOnly.isEmpty {
                    Text(String(localized: "passport.countries.empty", defaultValue: "Countries you visit appear here.", comment: "Expanded Passport: shown in the Countries card before any country is recorded."))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.onFieldSecondary)
                        .padding(AppTheme.cardPadding)
                }
                ForEach(Array(stats.enumerated()), id: \.element.code) { index, stat in
                    PassportCountryRow(stat: stat, showsSeparator: index > 0)
                }
                ForEach(Array(rememberedOnly.enumerated()), id: \.element) { index, code in
                    PassportRememberedRow(code: code, showsSeparator: index > 0 || !stats.isEmpty)
                }
            }
            .passportPanel()
        }
    }

    // MARK: Totals and records

    private var totals: some View {
        VStack(alignment: .leading, spacing: 0) {
            PassportSectionHeader(title: String(localized: "passport.section.totals", defaultValue: "Totals", comment: "Passport detail section title for totals."))
            // Top-aligned, so a row's numbers share a line when one label wraps.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 14) {
                tile(String(localized: "passport.tile.cities", defaultValue: "Cities", comment: "Passport statistic tile label for cities."), StatsText.grouped(data.cities))
                tile(String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), StatsText.grouped(data.trips))
                tile(String(localized: "passport.tile.stays", defaultValue: "Stays", comment: "Passport statistic tile label for stays."), StatsText.grouped(data.totalStays))
                tile(String(localized: "passport.tile.pings", defaultValue: "Pings", comment: "Passport statistic tile label for location pings."), StatsText.grouped(data.totalPings))
                tile(String(localized: "passport.tile.hexes", defaultValue: "Hexes", comment: "Passport statistic tile label for explored hexes."), StatsText.grouped(data.hexes))
                tile(String(localized: "passport.tile.explored", defaultValue: "Explored", comment: "Passport statistic tile label for explored area."), data.areaText)
                if data.flights > 0 {
                    tile(String(localized: "passport.tile.flights", defaultValue: "Flights", comment: "Passport statistic tile label for flights."), StatsText.grouped(data.flights))
                }
                if let days = data.daysAtTemporaryHomes, days > 0 {
                    tile(String(localized: "passport.tile.days-at-temporary-homes", defaultValue: "Days at Temporary Homes", comment: "Passport statistic tile label for days lived at temporary homes, such as a semester abroad, outside of trips."), StatsText.grouped(days))
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .passportPanel()
        }
    }

    private var hasRecords: Bool {
        data.longestTripName != nil
            || (data.furthestKm ?? 0) > 0
            || data.mostVisitedPlace != nil
            || data.hottestTempC != nil
            || data.coldestTempC != nil
    }

    private var recordRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let name = data.longestTripName, data.longestTripDays > 0 {
            rows.append((String(localized: "passport.field.longest-trip", defaultValue: "Longest trip", comment: "Passport record label for the longest trip."), data.longestTripDays == 1
                         ? String(localized: "passport.record.longest-trip.one", defaultValue: "\(name) · \(data.longestTripDays, format: .number.grouping(.never)) day", comment: "Passport longest-trip value lasting one day.")
                         : String(localized: "passport.record.longest-trip.other", defaultValue: "\(name) · \(data.longestTripDays, format: .number.grouping(.never)) days", comment: "Passport longest-trip value lasting multiple days.")))
        }
        if let km = data.furthestKm, km > 0, let place = data.furthestPlace {
            rows.append((String(localized: "passport.field.farthest-from-home", defaultValue: "Farthest from home", comment: "Passport record label for the farthest place from home."), "\(place) · \(UnitsFormatter.formatDistance(kilometers: km))"))
        }
        if let place = data.mostVisitedPlace, data.mostVisitedTripCount > 0 {
            rows.append((String(localized: "passport.field.most-visited", defaultValue: "Most visited", comment: "Passport record label for the most visited place."), data.mostVisitedTripCount == 1
                         ? String(localized: "passport.record.most-visited.one", defaultValue: "\(place) · \(data.mostVisitedTripCount, format: .number.grouping(.never)) trip", comment: "Passport most-visited-place value for one trip.")
                         : String(localized: "passport.record.most-visited.other", defaultValue: "\(place) · \(data.mostVisitedTripCount, format: .number.grouping(.never)) trips", comment: "Passport most-visited-place value for multiple trips.")))
        }
        if let temp = data.hottestTempC, let place = data.hottestPlace {
            rows.append((String(localized: "passport.field.hottest-stay", defaultValue: "Hottest stay", comment: "Passport record label for the hottest stay."), "\(UnitsFormatter.formatTemperatureCompact(temp)) · \(place)"))
        }
        if let temp = data.coldestTempC, let place = data.coldestPlace {
            rows.append((String(localized: "passport.field.coldest-stay", defaultValue: "Coldest stay", comment: "Passport record label for the coldest stay."), "\(UnitsFormatter.formatTemperatureCompact(temp)) · \(place)"))
        }
        return rows
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 0) {
            PassportSectionHeader(title: String(localized: "passport.section.records", defaultValue: "Records", comment: "Passport detail section title for travel records."))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recordRows.enumerated()), id: \.offset) { index, row in
                    recordRow(row.label, row.value, separated: index > 0)
                }
                // Apple Weather attribution: only when a temperature row is present.
                if data.hottestTempC != nil || data.coldestTempC != nil {
                    WeatherAttributionFootnote()
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 16)
            .passportPanel()
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(AppTheme.stat(.title3))
                .foregroundStyle(AppTheme.onField)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.footnote)
                .foregroundStyle(AppTheme.onFieldSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func recordRow(_ label: String, _ value: String, separated: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(AppTheme.onFieldSecondary)
            Spacer(minLength: 0)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(AppTheme.onField)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if separated {
                Rectangle()
                    .fill(PassportPalette.separator)
                    .frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Machine-readable zone

    /// The two lines that close the book, as on a passport's data page:
    /// decoration in foil monospace, hidden from VoiceOver.
    private func machineReadable(_ stats: [CountryStat], rememberedOnly: [String]) -> some View {
        let width = 44
        let first = "P<TRAVELLOG<<\(data.countries)<COUNTRIES<<\(continents)<CONTINENTS"
        var second = ""
        for code in stats.map(\.code) + rememberedOnly {
            let alpha3 = PassportStamp.alpha3(for: code)
            let next = second.isEmpty ? alpha3 : second + "<" + alpha3
            guard next.count <= width else { break }
            second = next
        }
        func padded(_ line: String) -> String {
            String((line + String(repeating: "<", count: width)).prefix(width))
        }
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(AppTheme.foil.opacity(0.26))
                .frame(height: 0.5)
            VStack(alignment: .leading, spacing: 4.5) {
                Text(verbatim: padded(first))
                Text(verbatim: padded(second))
            }
            .font(.system(size: 11.5, design: .monospaced))
            .tracking(0.23)
            .foregroundStyle(AppTheme.foil.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.top, 9)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }
}

// MARK: - Field and palette

/// The expanded Passport's own surfaces, on top of the shared field tokens.
private enum PassportPalette {
    /// The scrolled passport's field, top to bottom.
    static let deepTop = Color(UIColor(hex: 0x0D1960))
    static let deepMid = Color(UIColor(hex: 0x0A1450))
    /// The year picker's popover.
    static let picker = Color(UIColor(hex: 0x101C68, alpha: 0.86))
    /// The pinned switcher's glass tint.
    static let pinnedTint = Color(UIColor(hex: 0x0E1A64, alpha: 0.72))
    /// The surface a first-visit badge sits on, for its ring.
    static let badgeRing = Color(UIColor(hex: 0x18298B))
    static let separator = Color.white.opacity(0.13)
    static let pageDots = AppTheme.foil.opacity(0.08)
}

/// The scroll position the backdrop, the top fade, the title and the
/// pinned switcher follow. Kept out of the page's own state, so a scroll
/// re-evaluates only those small views.
@MainActor @Observable
private final class PassportScroll {
    /// How far the content has scrolled under the navigation bar.
    var y: CGFloat = 0
}

private nonisolated struct PageSpan: Equatable {
    let top: CGFloat
    let bottom: CGFloat
}

private enum PickerSource {
    case page, pinned
}

/// The field behind the passport, fixed to the screen: the cover's cobalt
/// (lifted in the top trailing corner, down to the night field) gives way
/// to the deeper field as the cover scrolls off.
private struct PassportBackdrop: View {
    let scroll: PassportScroll

    var body: some View {
        let coverOpacity = 1 - min(1, max(0, scroll.y / 520))
        ZStack {
            LinearGradient(
                stops: [.init(color: PassportPalette.deepTop, location: 0),
                        .init(color: PassportPalette.deepMid, location: 0.45),
                        .init(color: AppTheme.fieldNight, location: 1)],
                startPoint: .top, endPoint: .bottom)
            PassportCoverField()
                .opacity(coverOpacity)
        }
        .accessibilityHidden(true)
    }
}

/// The cover's field: the design's 170 degree gradient from cobalt to the
/// night field, and a cobalt lift spreading from the top trailing corner.
private struct PassportCoverField: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let radiusX = width * 0.95
            let radiusY = height * 0.52
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    stops: [.init(color: AppTheme.field, location: 0),
                            .init(color: AppTheme.fieldMid, location: 0.334),
                            .init(color: AppTheme.fieldDeep, location: 0.69),
                            .init(color: AppTheme.fieldNight, location: 0.94)],
                    startPoint: UnitPoint(x: 0.3, y: -0.025),
                    endPoint: UnitPoint(x: 0.7, y: 1.025))
                RadialGradient(
                    colors: [AppTheme.cobaltFill.opacity(0.85), AppTheme.cobaltFill.opacity(0)],
                    center: .center, startRadius: 0, endRadius: radiusX * 0.7)
                    .frame(width: radiusX * 2, height: radiusX * 2)
                    .scaleEffect(x: 1, y: radiusY / radiusX)
                    .position(x: width, y: 0)
            }
        }
    }
}

/// The field again over the top of the content once it scrolls under the
/// bar: solid behind the bar, fading out below it; reaching below the
/// pinned switcher while it shows.
private struct PassportTopFade: View {
    let scroll: PassportScroll
    let inset: CGFloat
    let span: PageSpan?

    var body: some View {
        let opacity = min(1, max(0, (scroll.y - 6) / 56))
        let pinned = span.map { PassportPinnedSwitcher<EmptyView>.placement(scroll: scroll.y, span: $0).shown } ?? false
        let height = inset + (pinned ? 78 : 20)
        PassportBackdrop(scroll: scroll)
            .mask(alignment: .top) {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.62),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .animation(.easeOut(duration: 0.2), value: pinned)
            }
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct PassportBarTitle: View {
    let scroll: PassportScroll

    var body: some View {
        let shown = scroll.y > 70
        Text(String(localized: "passport.title", defaultValue: "Passport", comment: "Title of the expanded Passport page, which shows the stamp book and every country visited."))
            .font(.headline)
            .foregroundStyle(AppTheme.onField)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: shown)
            .accessibilityHidden(!shown)
    }
}

/// The fine foil rule under the cover's title, fading out before the
/// trailing edge.
private struct FoilRule: View {
    var body: some View {
        LinearGradient(
            stops: [.init(color: AppTheme.foil.opacity(0.8), location: 0),
                    .init(color: AppTheme.foil.opacity(0.3), location: 0.6),
                    .init(color: AppTheme.foil.opacity(0), location: 1)],
            startPoint: .leading, endPoint: .trailing)
            .frame(height: 0.75)
            .padding(.trailing, 60)
            .accessibilityHidden(true)
    }
}

/// The cover's four figures in the design's columns: the first a little
/// wider (1.05 to 1), so the leading figure has room.
private struct CoverFigureRow: Layout {
    var spacing: CGFloat

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let shares = (0..<count).map { $0 == 0 ? 1.05 : 1 }
        let unit = max(0, total - spacing * CGFloat(count - 1)) / shares.reduce(0, +)
        return shares.map { $0 * unit }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 350
        let columns = widths(width, count: subviews.count)
        let height = zip(subviews, columns).map { subview, column in
            subview.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, column) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: column, height: nil))
            x += column + spacing
        }
    }
}

/// A section's header on the cobalt: the title, and a count on the right.
private struct PassportSectionHeader: View {
    let title: String
    var trailing: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.onField)
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.onFieldSecondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

private extension View {
    /// A panel on the cobalt: a faint white fill and hairline, 4 points
    /// wider than the text column on each side.
    func passportPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5) }
            .padding(.horizontal, -4)
    }
}

// MARK: - Stamp pages

/// One page of the stamp book: a year's stamps (the expanded Passport
/// keeps a whole year on one page).
struct StampPage: Identifiable, Equatable {
    static let perPage = 9

    let year: Int
    /// The page within its year, from 0.
    let part: Int
    let stamps: [StatsAggregator.StampEntry]
    /// The year's stamps and first-ever countries, across its pages.
    let yearStampCount: Int
    let firstEver: Set<String>

    var id: String { "\(year)-\(part)" }

    /// Pages in year order, `perPage` stamps to a page; nil keeps each year
    /// on one page. First-ever: the stay that first recorded the country
    /// (Wrapped's rule, as This Year counts it) is filed on this page
    /// (`StatsAggregator.firstEverStampYears`), and the country is not a
    /// remembered pre-TravelLog country.
    static func pages(_ years: [StatsAggregator.StampYear], firstRecorded: [Int: Set<String>],
                      remembered: Set<String>, perPage: Int? = StampPage.perPage) -> [StampPage] {
        years.flatMap { year -> [StampPage] in
            let firstEver = (firstRecorded[year.year] ?? []).subtracting(remembered)
                .intersection(year.stamps.map(\.code))
            let size = max(1, perPage ?? year.stamps.count)
            return stride(from: 0, to: year.stamps.count, by: size).map { start in
                StampPage(year: year.year, part: start / size,
                          stamps: Array(year.stamps[start..<min(start + size, year.stamps.count)]),
                          yearStampCount: year.stamps.count, firstEver: firstEver)
            }
        }
    }
}

/// A year's page on the cobalt: the switcher (arrows, the year, its stamp
/// and first-ever counts), a foil rule, then the year's stamps three to a
/// row over a faint dot grid. The page grows a row per three stamps. A
/// horizontal swipe steps a year.
private struct PassportYearPage<Switcher: View>: View {
    let page: StampPage
    let stepsForward: Bool
    let canStepBack: Bool
    let canStepForward: Bool
    let step: (Int) -> Void
    @ViewBuilder let switcher: Switcher

    /// How far the stamps follow a horizontal swipe in progress.
    @State private var drag: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            switcher
                .padding(.horizontal, 14)
                .padding(.top, 14)
            Rectangle()
                .fill(LinearGradient(
                    stops: [.init(color: AppTheme.foil.opacity(0), location: 0),
                            .init(color: AppTheme.foil.opacity(0.5), location: 0.5),
                            .init(color: AppTheme.foil.opacity(0), location: 1)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .accessibilityHidden(true)
            ZStack(alignment: .top) {
                PassportStampField(page: page)
                    .id(page.year)
                    .transition(.push(from: stepsForward ? .trailing : .leading))
            }
            .offset(x: drag)
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                LinearGradient(colors: [.white.opacity(0.085), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                StampDotGrid(color: PassportPalette.pageDots)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .overlay(alignment: .top) {
            // The inner highlight along the top edge.
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: .white.opacity(0.12), location: 0),
                                       .init(color: .white.opacity(0), location: 0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, -4)
        .contentShape(.rect)
        .gesture(HorizontalSwipe(changed: follow, ended: finish))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
    }

    /// A horizontal swipe steps a year: leftwards to the newer, rightwards
    /// to the older. The stamps follow the finger a little meanwhile.
    private func follow(_ dx: CGFloat) {
        let allowed = dx < 0 ? canStepForward : canStepBack
        drag = dx * (allowed ? 0.35 : 0.12)
    }

    private func finish(_ dx: CGFloat, velocity: CGFloat) {
        withAnimation(.snappy(duration: 0.25)) { drag = 0 }
        guard abs(dx) > 60 || (abs(dx) > 24 && abs(velocity) > 500) else { return }
        step(dx < 0 ? 1 : -1)
    }
}

/// A pan that begins only when the finger moves sideways, so the page's
/// vertical scrolling is never held up by it (a SwiftUI drag on scroll
/// content would hold the scroll view's pan).
private struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            changed(dx)
        case .ended:
            ended(dx, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            ended(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}

/// The year switcher: 44 pt arrows either side of the year, which opens
/// the decade picker. `compact` is the glass capsule pinned under the bar.
private struct PassportYearSwitcher: View {
    let page: StampPage
    let compact: Bool
    let canStepBack: Bool
    let canStepForward: Bool
    let step: (Int) -> Void
    @Binding var showsPicker: Bool
    let picker: PassportYearPicker

    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", enabled: canStepBack,
                  label: String(localized: "passport.year.previous", defaultValue: "Previous year", comment: "VoiceOver label of the expanded Passport's button that shows the previous year's stamp page.")) {
                step(-1)
            }
            Spacer(minLength: 4)
            Button {
                showsPicker = true
            } label: {
                VStack(spacing: compact ? 0 : 2) {
                    HStack(spacing: compact ? 5 : 6) {
                        Text(verbatim: String(page.year))
                            .font(.system(size: compact ? 20 : 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.onField)
                        Image(systemName: "chevron.down")
                            .font(.system(size: compact ? 10 : 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    PassportYearSubline(page: page)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "passport.year.choose", defaultValue: "\(String(page.year)), choose a year", comment: "VoiceOver label of the expanded Passport's year title, which opens a picker of every year with stamps; the placeholder is the year shown, such as 2026."))
            .accessibilityValue(PassportYearSubline.text(page))
            .popover(isPresented: $showsPicker, arrowEdge: .top) {
                picker
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(PassportPalette.picker)
                    .environment(\.colorScheme, .dark)
            }
            Spacer(minLength: 4)
            arrow("chevron.right", enabled: canStepForward,
                  label: String(localized: "passport.year.next", defaultValue: "Next year", comment: "VoiceOver label of the expanded Passport's button that shows the next year's stamp page.")) {
                step(1)
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, label: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(enabled ? 0.12 : 0.05), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// "9 stamps · 1 first-ever", the first-ever count in saffron.
private struct PassportYearSubline: View {
    let page: StampPage

    static func text(_ page: StampPage) -> String {
        var parts = [PassportText.stamps(page.yearStampCount)]
        if !page.firstEver.isEmpty { parts.append(PassportText.firstEver(page.firstEver.count)) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(PassportText.stamps(page.yearStampCount))
            if !page.firstEver.isEmpty {
                Text(verbatim: "·")
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                    Text(PassportText.firstEver(page.firstEver.count))
                }
                .foregroundStyle(PassportStamp.Ink.onFieldSaffron)
                .fontWeight(.semibold)
            }
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.onFieldSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The year's stamps, three to a row at the design's 74 points (78 for the
/// active trip's), each nudged off the grid and tilted as if stamped by
/// hand, in the cobalt inks with no ink repeated among neighbours.
private struct PassportStampField: View {
    let page: StampPage

    static let pitch: CGFloat = 93
    /// The widest the field spreads; wider pages (the iPhone Duo's inner
    /// screen) centre it so the stamps stay a cluster, not three far columns.
    private static let maxWidth: CGFloat = 430
    /// The column centres in the design's 330 point field.
    private static let columns: [CGFloat] = [55, 165, 275]
    private static let jitter: [CGSize] = [
        CGSize(width: -4, height: 4), CGSize(width: 6, height: -5), CGSize(width: -2, height: 6),
        CGSize(width: 8, height: -3), CGSize(width: -5, height: 2), CGSize(width: 4, height: -7),
        CGSize(width: -7, height: 5), CGSize(width: 5, height: -2), CGSize(width: -1, height: 4),
    ]
    private static let tilts: [Double] = [-5, 4, 6, -3, -6, 3, -2, -6, 5]

    var body: some View {
        let stamps = page.stamps
        let inks = PassportStamp.fieldInks(codes: stamps.map(\.code),
                                           ongoing: stamps.map { $0.isOngoing == true })
        let rows = (stamps.count + 2) / 3
        GeometryReader { proxy in
            let width = min(proxy.size.width, Self.maxWidth)
            let inset = (proxy.size.width - width) / 2
            let scale = width / 330
            ForEach(Array(stamps.enumerated()), id: \.element.code) { index, stamp in
                let slot = index % 9
                let ongoing = stamp.isOngoing == true
                let nudge = Self.jitter[slot]
                PassportStamp(
                    iso: stamp.code,
                    date: Self.displayDate(stamp.day),
                    size: ongoing ? 78 : 74,
                    ink: inks[index]?.onField ?? PassportStamp.Ink.onFieldSaffron,
                    highlighted: page.firstEver.contains(stamp.code),
                    rotation: Self.tilts[slot],
                    style: .book,
                    badgeRing: PassportPalette.badgeRing)
                .position(x: inset + Self.columns[index % 3] * scale + nudge.width * 0.925,
                          y: 46 + CGFloat(index / 3) * Self.pitch + nudge.height * 0.925)
            }
        }
        .frame(height: CGFloat(rows) * Self.pitch + 16)
    }

    /// Noon on the label's civil date in the device zone, so the stamp
    /// prints the day the label names wherever the device is.
    private static func displayDate(_ label: Date) -> Date {
        let parts = TravelDays.labelCalendar.dateComponents([.year, .month, .day], from: label)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        return local.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? label
    }
}

/// The page's faint foil dot grid: one dot every 14 points.
private struct StampDotGrid: View {
    var color: Color = AppTheme.stampGrid

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y: CGFloat = 7
            while y < size.height {
                var x: CGFloat = 7
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += 14
                }
                y += 14
            }
            context.fill(dots, with: .color(color))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The switcher pinned under the bar as a glass capsule while a tall year
/// page scrolls; the page's end pushes it away.
private struct PassportPinnedSwitcher<Switcher: View>: View {
    let scroll: PassportScroll
    let span: PageSpan
    @ViewBuilder let switcher: Switcher

    /// In content coordinates the capsule sits 10 points under the bar; it
    /// pins once the page's own switcher reaches it, and the page's end
    /// pushes it up and away.
    static func placement(scroll: CGFloat, span: PageSpan) -> (shown: Bool, push: CGFloat) {
        let top = scroll + 10
        let push = min(0, (span.bottom - 12) - (top + 56))
        return (span.top + 14 <= top && push > -56, push)
    }

    var body: some View {
        let (shown, push) = Self.placement(scroll: scroll.y, span: span)
        ZStack {
            if shown {
                switcher
                    .padding(.horizontal, 6)
                    .frame(height: 56)
                    .glassEffect(.regular.tint(PassportPalette.pinnedTint), in: .capsule)
                    .shadow(color: Color(UIColor(hex: 0x020624, alpha: 0.4)), radius: 15, y: 10)
                    .offset(y: push)
                    .opacity(1 + push / 32)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

/// "Jump to a year": every year with stamps, by decade, newest first, five
/// to a row in their place in the decade (first year bottom left, last top
/// right), the year on the page in cobalt.
private struct PassportYearPicker: View {
    let years: [(year: Int, stamps: Int)]
    let selected: Int
    let pick: (Int) -> Void

    private static let cellHeight: CGFloat = 54
    private static let gap: CGFloat = 6

    var body: some View {
        let rows = decadeRows
        let height = 16 + 22 + 4 + CGFloat(rows.count) * 34
            + rows.reduce(0) { $0 + CGFloat($1.rows.count) * (Self.cellHeight + Self.gap) - Self.gap } + 14
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "passport.year-picker.title", defaultValue: "Jump to a year", comment: "Title of the expanded Passport's year picker, which lists every year with stamps."))
                        .font(.headline)
                        .foregroundStyle(AppTheme.onField)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(years.count == 1
                         ? String(localized: "passport.year-picker.years.one", defaultValue: "\(years.count, format: .number) year", comment: "Expanded Passport year picker: how many years have stamps, for one.")
                         : String(localized: "passport.year-picker.years.other", defaultValue: "\(years.count, format: .number) years", comment: "Expanded Passport year picker: how many years have stamps, for several."))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                ForEach(rows, id: \.decade) { decade in
                    Text(String(localized: "passport.year-picker.decade", defaultValue: "\(String(decade.decade))s", comment: "Expanded Passport year picker: a decade's heading, such as 2020s."))
                        .font(.footnote.weight(.semibold))
                        .tracking(0.78)
                        .foregroundStyle(AppTheme.foil)
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: Self.gap) {
                        ForEach(decade.rows, id: \.self) { row in
                            HStack(spacing: Self.gap) {
                                ForEach(row, id: \.self) { year in cell(year) }
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14))
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 350, height: min(height, 560))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Each decade's rows of five years (a year with no stamps is an empty
    /// slot; a row with none is left out), newest decade first, its later
    /// half on top so the decade reads from bottom left to top right.
    private var decadeRows: [Decade] {
        guard let first = years.map(\.year).min(), let last = years.map(\.year).max() else { return [] }
        let stamped = Set(years.map(\.year))
        return stride(from: last / 10 * 10, through: first / 10 * 10, by: -10).compactMap { decade -> Decade? in
            let rows = [5, 0].compactMap { offset -> [Int]? in
                let row = Array(decade + offset..<decade + offset + 5)
                guard row.contains(where: stamped.contains) else { return nil }
                return row
            }
            return rows.isEmpty ? nil : Decade(decade: decade, rows: rows)
        }
    }

    private struct Decade {
        let decade: Int
        let rows: [[Int]]
    }

    @ViewBuilder
    private func cell(_ year: Int) -> some View {
        if let entry = years.first(where: { $0.year == year }) {
            let isSelected = year == selected
            Button {
                pick(year)
            } label: {
                VStack(spacing: 2) {
                    Text(verbatim: String(year))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.onField)
                    Text(PassportText.stamps(entry.stamps))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.86 : 0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.cellHeight)
                .background(isSelected ? AppTheme.cobaltFill : Color.white.opacity(0.07),
                            in: .rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    }
                }
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.cellHeight)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Country rows

/// One tracked country: flag, name, trips and first year, days. A country
/// with trips opens the Trips tab filtered to it.
private struct PassportCountryRow: View {
    let stat: CountryStat
    let showsSeparator: Bool

    var body: some View {
        let name = StatsView.countryDisplayName(stat)
        if stat.tripCount > 0 {
            Button {
                TripsTabRouter.shared.requestCountryFilter(stat.code)
            } label: {
                content(name: name, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Trips tab filtered to \(name)")
        } else {
            content(name: name, chevron: false)
        }
    }

    private func content(name: String, chevron: Bool) -> some View {
        PassportCountryRowLayout(code: stat.code, name: name, caption: caption,
                                 days: stat.days ?? 0, chevron: chevron, showsSeparator: showsSeparator)
    }

    /// "2 trips · first in 2023"; home and temporary home rows say so.
    private var caption: String {
        var parts: [String] = []
        if stat.tripCount > 0 {
            parts.append(StatsText.trips(stat.tripCount))
        } else if stat.isHome {
            parts.append(String(localized: "home"))
        } else if stat.isTemporaryHome == true {
            parts.append(String(localized: "stats.country.temporary-home", defaultValue: "temporary home", comment: "Country row caption for the country of a temporary home, such as a semester abroad, with no trips there."))
        } else {
            parts.append(String(localized: "time near home"))
        }
        if let year = stat.firstYear {
            parts.append(PassportText.firstIn(year))
        }
        return parts.joined(separator: " · ")
    }
}

/// A country remembered from before TravelLog: no trips, no days.
private struct PassportRememberedRow: View {
    let code: String
    let showsSeparator: Bool

    var body: some View {
        PassportCountryRowLayout(code: code, name: StatsText.regionName(code),
                                 caption: String(localized: "before TravelLog"),
                                 days: 0, chevron: false, showsSeparator: showsSeparator)
    }
}

private struct PassportCountryRowLayout: View {
    let code: String
    let name: String
    let caption: String
    let days: Int
    let chevron: Bool
    let showsSeparator: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            FlagView(iso: code, size: .large)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(AppTheme.onField)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.onFieldSecondary)
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: 8)
            if days > 0 {
                Text(StatsText.emphasizing(StatsText.plain(days), in: StatsText.days(days),
                                           font: AppTheme.stat(.body)))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.onFieldSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(PassportPalette.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 64)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview("15 years, 23 stamps in 2025") {
    NavigationStack {
        PassportDetailView(data: PassportPreviewData.data, canShare: true, continents: 4,
                           book: PassportPreviewData.book(years: 15))
    }
}

#Preview("One year") {
    NavigationStack {
        PassportDetailView(data: PassportPreviewData.data, canShare: true, continents: 1,
                           book: PassportPreviewData.book(years: 1))
    }
}

/// Synthetic passports for the previews: up to 15 years (2012 to 2026),
/// 12 stamps in 2024 and 23 in 2025, an active trip in 2026.
enum PassportPreviewData {
    static let data: PassportData = {
        var data = PassportData()
        data.countries = 27
        data.cities = 96
        data.trips = 58
        data.daysAbroad = 395
        data.hexes = 1284
        data.flights = 87
        data.sinceYear = 2012
        data.totalStays = 412
        data.totalPings = 48920
        data.longestTripName = "Kyoto & Osaka"
        data.longestTripDays = 13
        data.furthestKm = 9370
        data.furthestPlace = "Tokyo"
        data.mostVisitedPlace = "Lisbon"
        data.mostVisitedTripCount = 5
        return data
    }()

    private static let counts = [2012: 3, 2013: 4, 2014: 2, 2015: 5, 2016: 4, 2017: 6, 2018: 5, 2019: 7,
                                 2020: 3, 2021: 6, 2022: 8, 2023: 9, 2024: 12, 2025: 23, 2026: 9]
    private static let pool = ["AT", "CZ", "HU", "IT", "FR", "ES", "PT", "CA", "GB", "IE", "NL", "BE",
                               "DE", "DK", "SE", "NO", "IS", "FI", "EE", "PL", "HR", "SI", "CH", "JP", "US", "GR"]

    static func book(years: Int) -> PassportBook {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let chosen = counts.keys.sorted().suffix(years)
        var stampYears: [StatsAggregator.StampYear] = []
        var firsts: [Int: Set<String>] = [:]
        var seen: Set<String> = []
        for year in chosen {
            let count = counts[year] ?? 0
            let offset = (year * 7) % pool.count
            let codes = (0..<count).map { pool[(offset + $0) % pool.count] }
            let stamps = codes.enumerated().map { index, code in
                StatsAggregator.StampEntry(
                    code: code,
                    day: calendar.date(from: DateComponents(year: year, month: 1 + index * 11 / max(count, 1), day: 3 + index % 25))!,
                    isOngoing: year == 2026 && index == count - 1)
            }
            stampYears.append(.init(year: year, stamps: stamps))
            // The pool repeats, so mark a few first-ever countries by hand.
            firsts[year] = seen.isEmpty
                ? Set(codes)
                : Set(codes.enumerated().filter { ($0.offset * 5 + year) % 7 == 0 }.map(\.element))
            seen.formUnion(codes)
        }
        let stats = seen.sorted().enumerated().map { index, code in
            CountryStat(code: code, name: code, tripCount: 1 + index % 5, isHome: false,
                        days: 40 - index, firstYear: chosen.first)
        }
        return PassportBook(stampYears: stampYears, firstRecordedByYear: firsts,
                            countryStats: stats, trackedCodes: seen)
    }
}
