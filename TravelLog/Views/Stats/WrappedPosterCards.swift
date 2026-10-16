//
//  WrappedPosterCards.swift
//  TravelLog
//
//  The Wrapped cards: one idea per card, drawn from the data at poster
//  scale. One colour (cobalt) with paper and ink, compressed black numerals
//  from the system font, no icons. The cards follow the system appearance;
//  the shared image (`WrappedShareRenderer`) is always the cobalt poster.
//

import SwiftUI
import UIKit

// MARK: - Palette

/// Contrast (WCAG, against the surface it sits on): ink and secondary text
/// clear 4.5:1 on paper and on the colour field; chart marks, including the
/// non-peak month columns, clear 3:1 in both appearances.
struct WrappedPosterPalette {
    let paper: Color
    let ink: Color
    let secondary: Color
    /// Full-bleed colour field behind the title, farthest, first-visit and
    /// home-and-away cards.
    let field: Color
    /// Chart marks on paper: hexes, laps, peak column, tally.
    let mark: Color
    /// Non-peak month columns.
    let markMuted: Color
    let track: Color
    /// The closing card's ink field.
    let closing: Color
    let onField = Color.white
    let onFieldSecondary = Color.white.opacity(0.8)

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            paper = Color(red: 0.05, green: 0.05, blue: 0.06)
            ink = Color(red: 0.96, green: 0.96, blue: 0.94)
            secondary = Color(red: 0.96, green: 0.96, blue: 0.94).opacity(0.6)
            field = Color(red: 0.18, green: 0.28, blue: 0.86)
            mark = Color(red: 0.36, green: 0.48, blue: 1.0)
            markMuted = Color(red: 0.33, green: 0.40, blue: 0.70)
            track = .white.opacity(0.16)
            closing = Color(red: 0.13, green: 0.13, blue: 0.15)
        } else {
            paper = Color(red: 0.97, green: 0.97, blue: 0.955)
            ink = Color(red: 0.05, green: 0.05, blue: 0.07)
            secondary = Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.6)
            field = Color(red: 0.12, green: 0.25, blue: 0.88)
            mark = Color(red: 0.12, green: 0.25, blue: 0.88)
            markMuted = Color(red: 0.443, green: 0.524, blue: 0.908)
            track = .black.opacity(0.08)
            closing = Color(red: 0.05, green: 0.05, blue: 0.07)
        }
    }
}

// MARK: - Units and wording shared with the share image

/// Localized unit words and number formatting. Plural forms follow the
/// catalog's split-key pattern (`.one` / `.other`).
struct WrappedUnits {
    let locale: Locale
    /// Snapshots from before trip-span days count days abroad; they keep
    /// that wording so a saved recap keeps its historical meaning.
    let usesTripSpanDays: Bool

    init(locale: Locale, stats: WrappedStats) {
        self.locale = locale
        usesTripSpanDays = stats.usesTripSpanDays == true
    }

    func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }

    func trips(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.trips.one", defaultValue: "trip", locale: locale, comment: "Wrapped unit beside a large number of trips; the number is shown separately. One trip.")
            : String(localized: "wrapped.unit.trips.other", defaultValue: "trips", locale: locale, comment: "Wrapped unit beside a large number of trips; the number is shown separately. Several trips.")
    }

    func countries(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.countries.one", defaultValue: "country", locale: locale, comment: "Wrapped unit beside a large number of countries visited; the number is shown separately. One country.")
            : String(localized: "wrapped.unit.countries.other", defaultValue: "countries", locale: locale, comment: "Wrapped unit beside a large number of countries visited; the number is shown separately. Several countries.")
    }

    func cities(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.cities.one", defaultValue: "city", locale: locale, comment: "Wrapped unit beside a large number of cities visited; the number is shown separately. One city.")
            : String(localized: "wrapped.unit.cities.other", defaultValue: "cities", locale: locale, comment: "Wrapped unit beside a large number of cities visited; the number is shown separately. Several cities.")
    }

    func daysAway(_ n: Int) -> String {
        if usesTripSpanDays {
            return n == 1
                ? String(localized: "wrapped.unit.days-away.one", defaultValue: "day away", locale: locale, comment: "Wrapped unit beside a large number of days spent away from home on trips; the number is shown separately. One day.")
                : String(localized: "wrapped.unit.days-away.other", defaultValue: "days away", locale: locale, comment: "Wrapped unit beside a large number of days spent away from home on trips; the number is shown separately. Several days.")
        }
        return n == 1
            ? String(localized: "wrapped.unit.days-abroad.one", defaultValue: "day abroad", locale: locale, comment: "Wrapped unit beside a large number of days spent abroad, used for recaps saved before domestic trips counted; the number is shown separately. One day.")
            : String(localized: "wrapped.unit.days-abroad.other", defaultValue: "days abroad", locale: locale, comment: "Wrapped unit beside a large number of days spent abroad, used for recaps saved before domestic trips counted; the number is shown separately. Several days.")
    }

    func daysAtHome(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.days-at-home.one", defaultValue: "day at home", locale: locale, comment: "Wrapped unit beside a large number of days spent at home; the number is shown separately. One day.")
            : String(localized: "wrapped.unit.days-at-home.other", defaultValue: "days at home", locale: locale, comment: "Wrapped unit beside a large number of days spent at home; the number is shown separately. Several days.")
    }

    func days(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.days.one", defaultValue: "day", locale: locale, comment: "Wrapped unit beside the large length of the longest trip; the number is shown separately. One day.")
            : String(localized: "wrapped.unit.days.other", defaultValue: "days", locale: locale, comment: "Wrapped unit beside the large length of the longest trip; the number is shown separately. Several days.")
    }

    func newHexes(_ n: Int) -> String {
        n == 1
            ? String(localized: "wrapped.unit.new-hexes.one", defaultValue: "new hex on your map", locale: locale, comment: "Wrapped unit beside a large count of map hexes (small map cells) visited for the first time that year; the number is shown separately. One hex.")
            : String(localized: "wrapped.unit.new-hexes.other", defaultValue: "new hexes on your map", locale: locale, comment: "Wrapped unit beside a large count of map hexes (small map cells) visited for the first time that year; the number is shown separately. Several hexes.")
    }

    /// Number and unit apart, so the number can be the hero. Miles where
    /// the locale prefers imperial distances, like `UnitsFormatter`.
    static func distance(_ km: Double, locale: Locale) -> (value: String, unit: String, longUnit: String) {
        let unit: UnitLength = UnitsFormatter.isImperial ? .miles : .kilometers
        let value = UnitsFormatter.isImperial ? km / 1.609_344 : km
        let short = MeasurementFormatter()
        short.locale = locale
        short.unitStyle = .short
        let long = MeasurementFormatter()
        long.locale = locale
        long.unitStyle = .long
        return (Int(value.rounded()).formatted(.number.locale(locale)),
                short.string(from: unit), long.string(from: unit))
    }

    /// The year split for the two-line poster numeral ("20" / "26").
    static func yearLines(_ year: Int) -> [String] {
        let text = String(year)
        guard text.count == 4 else { return [text] }
        return [String(text.prefix(2)), String(text.suffix(2))]
    }
}

// MARK: - Content

/// Everything the cards show, derived from the saved `WrappedStats` in the
/// app language. Pure value; rebuilt with `WrappedView`.
struct WrappedPosterContent {

    struct Country: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    let year: Int
    let units: WrappedUnits
    let countries: Int
    let cities: Int
    let trips: Int
    let newHexes: Int
    let daysAway: Int
    let daysHome: Int
    let longestTripName: String?
    let longestTripDays: Int
    let longestTripStart: Date?
    let farthestKm: Double
    let farthestPlace: String?
    let modes: [(label: String, km: Double)]
    let totalKm: Double
    let newCountries: [Country]
    let mostVisitedName: String?
    let monthTrips: [Int]
    let hottest: (value: String, place: String)?
    let coldest: (value: String, place: String)?
    let wettest: (value: String, trip: String)?
    let footnote: String?

    #if DEBUG
    /// Render-test seam: invented country names for invented codes.
    @TaskLocal static var countryNameOverrideForTesting: (@Sendable (String) -> String)?
    #endif

    init(year: Int, stats: WrappedStats, weatherCoverage: Double, locale: Locale) {
        func name(_ code: String) -> String {
            #if DEBUG
            if let override = Self.countryNameOverrideForTesting { return override(code) }
            #endif
            return localizedCountryName(iso: code, fallback: code, locale: locale) ?? code
        }
        self.year = year
        units = WrappedUnits(locale: locale, stats: stats)
        countries = stats.countriesVisited
        cities = stats.citiesVisited
        trips = stats.tripsCompleted
        newHexes = stats.totalHexesVisited
        daysAway = stats.daysAbroad
        daysHome = stats.daysAtHome
        longestTripName = stats.longestTripName
        longestTripDays = stats.longestTripDays
        longestTripStart = stats.longestTripStartDate
        farthestKm = stats.farthestDistanceKm
        farthestPlace = stats.farthestPlaceName
        totalKm = stats.totalGreatCircleKm
        var modes: [(String, Double)] = []
        if stats.flightKm >= WrappedView.transitCardMinimumKm {
            modes.append((String(localized: "wrapped.transport.flown", defaultValue: "Flown", comment: "Wrapped transport label for distance flown."), stats.flightKm))
        }
        if stats.driveKm >= WrappedView.transitCardMinimumKm {
            modes.append((String(localized: "wrapped.transport.driven", defaultValue: "Driven", comment: "Wrapped transport label for distance driven."), stats.driveKm))
        }
        if stats.walkKm >= WrappedView.transitCardMinimumKm {
            modes.append((String(localized: "wrapped.transport.walked", defaultValue: "Walked", comment: "Wrapped transport label for distance walked."), stats.walkKm))
        }
        self.modes = modes
        newCountries = stats.newCountryCodes.map { Country(code: $0, name: name($0)) }
        mostVisitedName = stats.mostVisitedCountryCode.map(name)
        monthTrips = WrappedView.tripsPerMonth(stats: stats) ?? Array(repeating: 0, count: 12)
        if (stats.weatherExtremesSafe ?? (weatherCoverage >= 0.7)),
           WrappedView.weatherCardHasContent(stats: stats) {
            hottest = stats.hottestTempC.flatMap { t in
                stats.hottestLocality.map { (value: UnitsFormatter.formatTemperature(t), place: $0) }
            }
            coldest = stats.coldestTempC.flatMap { t in
                stats.coldestLocality.map { (value: UnitsFormatter.formatTemperature(t), place: $0) }
            }
            wettest = stats.rainiestPrecipitationMm.flatMap { mm in
                guard mm > 0, let trip = stats.rainiestTripName else { return nil }
                return (value: String(localized: "wrapped.weather.precipitation", defaultValue: "\(Int(mm), format: .number.grouping(.never)) mm", comment: "Wrapped precipitation value in millimetres."),
                        trip: trip)
            }
        } else {
            hottest = nil
            coldest = nil
            wettest = nil
        }
        footnote = WrappedDisplayResolver.resolvedMysteryFact(stats: stats, locale: locale)
    }

    var locale: Locale { units.locale }

    var busiestMonth: (index: Int, trips: Int)? {
        guard let peak = monthTrips.max(), peak > 0,
              let index = monthTrips.firstIndex(of: peak) else { return nil }
        return (index, peak)
    }

    var activeMonths: Int { monthTrips.count { $0 > 0 } }

    var monthNames: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.standaloneMonthSymbols
    }

    var monthInitials: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.veryShortStandaloneMonthSymbols
    }

    var awayFraction: Double {
        let total = daysAway + daysHome
        return total > 0 ? Double(daysAway) / Double(total) : 0
    }

    var timesAroundEarth: Double { totalKm / 40_075 }

    /// Cells in the honeycomb: one per hex up to 220, else one per 10, 100...
    var hexesPerCell: Int {
        var scale = 1
        while newHexes / scale > 220 { scale *= 10 }
        return scale
    }
}

// MARK: - Metrics

/// Giant numerals are fixed poster sizes that shrink, rather than grow, as
/// text gets larger, so the words around them have room.
private enum PosterMetrics {
    static func numeralScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large, .xLarge: 1
        case .xxLarge: 0.94
        case .xxxLarge: 0.88
        case .accessibility1: 0.78
        case .accessibility2: 0.7
        case .accessibility3: 0.64
        default: 0.58
        }
    }

    /// 1.3 times the body text's title3 size: compressed black digits at
    /// that size match the visual weight of the words.
    static func numeralFloor(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traits).pointSize * 1.3
    }

    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.compressed)
    }
}

// MARK: - Card

struct WrappedPosterCard: View {
    let kind: WrappedCardKind
    let content: WrappedPosterContent
    /// The closing card's share payload; nil on every other card.
    let share: WrappedShare?
    let index: Int
    let total: Int
    let revealed: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var palette: WrappedPosterPalette { WrappedPosterPalette(scheme) }
    private var units: WrappedUnits { content.units }

    private enum Surface { case paper, field, closing }

    private var surface: Surface {
        switch kind {
        case .title, .farthest, .firstVisits: .field
        case .closing: .closing
        default: .paper
        }
    }

    private var background: Color {
        switch surface {
        case .paper: palette.paper
        case .field: palette.field
        case .closing: palette.closing
        }
    }

    private var fg: Color { surface == .paper ? palette.ink : palette.onField }
    private var fg2: Color { surface == .paper ? palette.secondary : palette.onFieldSecondary }
    /// Mark colour: cobalt on paper, white on a colour field.
    private var mark: Color { surface == .paper ? palette.mark : palette.onField }

    var body: some View {
        Group {
            if kind == .homeAway, !typeSize.isAccessibilitySize {
                HomeAwayBandPage(content: content, palette: palette, index: index, total: total,
                                 revealed: revealed)
            } else {
                ViewThatFits(in: .vertical) {
                    page(compact: false)
                    page(compact: true)
                    page(compact: true, minimal: true)
                }
                .background(background)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// `minimal` is the last fallback at the largest text sizes: it keeps
    /// the figures and their words and drops captions, charts and detail.
    private func page(compact: Bool, minimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeading(text: heading, color: fg, clearsClose: true)
                .wrappedRise(revealed)
            Spacer(minLength: 12)
            cardBody(compact: compact, minimal: minimal)
                .wrappedRise(revealed, delay: WrappedMotion.stagger)
            Spacer(minLength: 12)
            PosterFooter(year: content.year, index: index, total: total, color: fg2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 62)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: String {
        switch kind {
        case .title: String(localized: "wrapped.heading.title", defaultValue: "Travel", comment: "Wrapped opening card heading above the year; shown in capitals.")
        case .places: String(localized: "wrapped.heading.places", defaultValue: "New ground", comment: "Wrapped places card heading (new map hexes, countries, cities); shown in capitals.")
        case .longestTrip: String(localized: "wrapped.heading.longest-trip", defaultValue: "Longest trip", comment: "Wrapped longest-trip card heading; shown in capitals.")
        case .farthest: String(localized: "wrapped.heading.farthest", defaultValue: "Farthest from home", comment: "Wrapped farthest-place card heading; shown in capitals.")
        case .months: String(localized: "wrapped.heading.months", defaultValue: "When you went", comment: "Wrapped card heading for trips per month; shown in capitals.")
        case .distance: String(localized: "wrapped.heading.distance", defaultValue: "Distance", comment: "Wrapped distance card heading; shown in capitals.")
        case .homeAway: String(localized: "wrapped.heading.home-away", defaultValue: "Home and away", comment: "Wrapped card heading comparing days away with days at home; shown in capitals.")
        case .firstVisits: String(localized: "wrapped.heading.first-visits", defaultValue: "First visits", comment: "Wrapped card heading for countries visited for the first time; shown in capitals.")
        case .weather: String(localized: "wrapped.heading.weather", defaultValue: "Weather", comment: "Wrapped weather card heading; shown in capitals.")
        case .closing: String(localized: "wrapped.heading.closing", defaultValue: "The year", comment: "Wrapped closing card heading above the year's totals; shown in capitals.")
        }
    }

    // MARK: Atoms

    private func numeralSize(_ base: CGFloat, compact: Bool) -> CGFloat {
        max(base * PosterMetrics.numeralScale(typeSize) * (compact ? 0.66 : 1),
            min(base, PosterMetrics.numeralFloor(typeSize)))
    }

    /// A compressed black numeral. `tight` trims the line box to the digits
    /// so stacked numerals sit close, as on a poster.
    private func numeral(_ value: String, _ base: CGFloat, compact: Bool, color: Color? = nil,
                         tight: Bool = false) -> some View {
        let size = numeralSize(base, compact: compact)
        return Text(verbatim: value)
            .font(PosterMetrics.numeral(size))
            .foregroundStyle(color ?? fg)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: tight ? size * 0.78 : nil)
    }

    private func line(_ text: String, compact: Bool, style: Font = .title3) -> some View {
        Text(text)
            .font(style.weight(.bold))
            .foregroundStyle(fg)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(compact ? 0.7 : 1)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(fg2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Big number with its unit word on the same baseline.
    private func figure(_ value: String, _ unit: String, base: CGFloat, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            numeral(value, base, compact: compact)
                .layoutPriority(1)
            Text(unit)
                .font(.title3.weight(.bold))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Bodies

    @ViewBuilder
    private func cardBody(compact: Bool, minimal: Bool) -> some View {
        switch kind {
        case .title: titleBody(compact)
        case .places: placesBody(compact, minimal: minimal)
        case .longestTrip: longestBody(compact, minimal: minimal)
        case .farthest: farthestBody(compact)
        case .months: monthsBody(compact, minimal: minimal)
        case .distance: distanceBody(compact, minimal: minimal)
        case .homeAway: homeAwayCompactBody(minimal: minimal)
        case .firstVisits: firstVisitsBody(compact, minimal: minimal)
        case .weather: weatherBody(compact, minimal: minimal)
        case .closing: closingBody(compact, minimal: minimal)
        }
    }

    /// Side by side normally; stacked at accessibility sizes so words do
    /// not break mid-word.
    private var pairLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 20))
    }

    private func titleBody(_ compact: Bool) -> some View {
        let lines = WrappedUnits.yearLines(content.year)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if compact {
                    numeral(String(content.year), 300, compact: true, tight: true)
                } else {
                    ForEach(lines.indices, id: \.self) { numeral(lines[$0], 400, compact: false, tight: true) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(content.year)))
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                if content.trips > 0 {
                    figure(units.number(content.trips), units.trips(content.trips), base: 44, compact: compact)
                }
                figure(units.number(content.countries), units.countries(content.countries), base: 44, compact: compact)
                if content.daysAway > 0 {
                    figure(units.number(content.daysAway), units.daysAway(content.daysAway), base: 44, compact: compact)
                }
            }
            .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func placesBody(_ compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if content.newHexes > 0 {
                figureBlock(units.number(content.newHexes), units.newHexes(content.newHexes), base: 120, compact: compact)
            } else {
                figureBlock(units.number(content.cities), units.cities(content.cities), base: 120, compact: compact)
            }
            pairLayout {
                figure(units.number(content.countries), units.countries(content.countries), base: 40, compact: compact)
                if content.newHexes > 0 {
                    figure(units.number(content.cities), units.cities(content.cities), base: 40, compact: compact)
                }
            }
            if content.newHexes > 0, !compact {
                let cells = Int((Double(content.newHexes) / Double(content.hexesPerCell)).rounded(.up))
                Honeycomb(count: cells, fill: mark)
                    .frame(height: 240)
                    .opacity(revealed ? 1 : 0)
                    .wrappedGrow(revealed, delay: WrappedMotion.stagger * 2)
                    .accessibilityElement()
                    .accessibilityLabel(honeycombLabel(cells: cells))
                caption(cellScaleText)
            }
            if let favorite = content.mostVisitedName, !minimal {
                caption(String(localized: "wrapped.places.most-visited", defaultValue: "Your most visited country: \(favorite).", comment: "Wrapped places card line naming the country with the most trips that year."))
            }
        }
    }

    private var cellScaleText: String {
        let scale = content.hexesPerCell
        return scale == 1
            ? String(localized: "wrapped.places.cell-scale.one", defaultValue: "One cell for each hex you saw for the first time.", comment: "Wrapped caption under a honeycomb chart where each cell is one new map hex.")
            : String(localized: "wrapped.places.cell-scale.other", defaultValue: "One cell for every \(units.number(scale)) hexes you saw for the first time.", comment: "Wrapped caption under a honeycomb chart where each cell stands for several new map hexes; the number is 10, 100 or more.")
    }

    private func honeycombLabel(cells: Int) -> String {
        content.hexesPerCell == 1
            ? String(localized: "wrapped.places.honeycomb.a11y.one", defaultValue: "Honeycomb chart of \(units.number(cells)) cells, one per new hex.", comment: "VoiceOver label for the Wrapped honeycomb chart when each cell is one new map hex.")
            : String(localized: "wrapped.places.honeycomb.a11y.other", defaultValue: "Honeycomb chart of \(units.number(cells)) cells, one per \(units.number(content.hexesPerCell)) new hexes.", comment: "VoiceOver label for the Wrapped honeycomb chart when each cell stands for several new map hexes.")
    }

    /// Hero numeral with the unit as a full line under it.
    private func figureBlock(_ value: String, _ unit: String, base: CGFloat, compact: Bool, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            numeral(value, base, compact: compact, color: color)
            line(unit, compact: compact)
        }
        .accessibilityElement(children: .combine)
    }

    private func longestBody(_ compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                numeral(units.number(content.longestTripDays), 300, compact: compact, color: mark, tight: !compact)
                Text(units.days(content.longestTripDays))
                    .font(.title.weight(.black).width(.compressed))
                    .foregroundStyle(fg)
            }
            .accessibilityElement(children: .combine)
            line(content.longestTripName ?? "", compact: compact, style: .title2)
            if let start = content.longestTripStart, !minimal {
                let date = start.formatted(Date.FormatStyle(locale: content.locale).day().month(.wide))
                caption(String(localized: "wrapped.longest-trip.started", defaultValue: "Started on \(date).", comment: "Wrapped longest-trip card: the day the trip began, as day and month."))
            }
            if !compact {
                // One stroke per day, up to two months.
                HStack(spacing: 0) {
                    ForEach(0..<min(content.longestTripDays, 60), id: \.self) { _ in
                        Rectangle().fill(mark).frame(width: 4, height: 54)
                            .scaleEffect(y: revealed ? 1 : 0, anchor: .bottom)
                            .frame(maxWidth: .infinity)
                    }
                }
                .wrappedGrow(revealed, delay: WrappedMotion.stagger * 2)
                .padding(.top, 18)
                .accessibilityHidden(true)
            }
        }
    }

    private func farthestBody(_ compact: Bool) -> some View {
        let distance = WrappedUnits.distance(content.farthestKm, locale: content.locale)
        let text = content.farthestPlace.map { place in
            String(localized: "wrapped.farthest.unit-place", defaultValue: "\(distance.unit) from home, in \(place).", comment: "Wrapped farthest card line under the large distance: the distance unit (km or mi), then the farthest place.")
        } ?? String(localized: "wrapped.farthest.unit", defaultValue: "\(distance.unit) from home.", comment: "Wrapped farthest card line under the large distance when the place has no name: the distance unit (km or mi).")
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                numeral(distance.value, 170, compact: compact)
                line(text, compact: compact, style: .title2)
            }
            .accessibilityElement(children: .combine)
            if !compact {
                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Circle().stroke(fg, lineWidth: 3).frame(width: 18, height: 18)
                        Rectangle().fill(fg).frame(height: 3)
                            .scaleEffect(x: revealed ? 1 : 0, anchor: .leading)
                            .wrappedGrow(revealed, delay: WrappedMotion.stagger * 2)
                        Circle().fill(fg).frame(width: 18, height: 18)
                    }
                    if !typeSize.isAccessibilitySize {
                    HStack {
                        PosterHeading(text: String(localized: "wrapped.farthest.home", defaultValue: "Home", comment: "Wrapped farthest card: label under the start of the line from home to the farthest place; shown in capitals."), color: fg2)
                        Spacer()
                        if let place = content.farthestPlace {
                            PosterHeading(text: place, color: fg2)
                        }
                    }
                    }
                }
                .padding(.top, 48)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func monthsBody(_ compact: Bool, minimal: Bool) -> some View {
        let busiest = content.busiestMonth
        VStack(alignment: .leading, spacing: 10) {
            if let busiest {
                VStack(alignment: .leading, spacing: 6) {
                    numeral(content.monthNames[busiest.index], 110, compact: compact)
                    line(busiest.trips == 1
                         ? String(localized: "wrapped.months.busiest.one", defaultValue: "Your busiest month, with \(units.number(busiest.trips)) trip.", comment: "Wrapped months card line under the large month name; one trip began that month.")
                         : String(localized: "wrapped.months.busiest.other", defaultValue: "Your busiest month, with \(units.number(busiest.trips)) trips.", comment: "Wrapped months card line under the large month name; several trips began that month."),
                         compact: compact)
                }
                .accessibilityElement(children: .combine)
            }
            if !minimal {
                caption(String(localized: "wrapped.months.active", defaultValue: "You traveled in \(units.number(content.activeMonths)) of 12 months.", comment: "Wrapped months card: how many of the year's 12 months had a trip begin."))
            }
            PosterMonthColumns(values: content.monthTrips, highlight: busiest?.index,
                               initials: content.monthInitials, base: palette.markMuted,
                               accent: palette.mark, label: fg2, valueInk: fg,
                               rule: palette.track, revealed: revealed)
                .frame(height: minimal ? 110 : compact ? 150 : 300)
                .padding(.top, 8)
                .accessibilityElement()
                .accessibilityLabel(monthsLabel)
            if !minimal {
                caption(String(localized: "wrapped.months.caption", defaultValue: "Trips by the month they began.", comment: "Wrapped months card caption under the month columns chart."))
            }
        }
    }

    private var monthsLabel: String {
        let entries = content.monthTrips.indices.compactMap { index -> String? in
            let trips = content.monthTrips[index]
            guard trips > 0 else { return nil }
            let month = content.monthNames[index]
            let count = units.number(trips)
            return String(localized: "wrapped.months.a11y.entry", defaultValue: "\(month): \(count)", comment: "VoiceOver part of the Wrapped month chart: a month name and the number of trips that began in it.")
        }
        let caption = String(localized: "wrapped.months.caption", defaultValue: "Trips by the month they began.", comment: "Wrapped months card caption under the month columns chart.")
        return ([caption] + entries).joined(separator: ", ")
    }

    private func distanceBody(_ compact: Bool, minimal: Bool) -> some View {
        let km = content.totalKm > 0 ? content.totalKm : content.modes.map(\.km).reduce(0, +)
        let distance = WrappedUnits.distance(km, locale: content.locale)
        let laps = km / 40_075
        var sentence = String(localized: "wrapped.distance.unit-total", defaultValue: "\(distance.unit) in total.", comment: "Wrapped distance card line under the large total: the distance unit (km or mi).")
        if laps >= 0.95 {
            let times = laps.formatted(.number.precision(.fractionLength(1)).locale(content.locale))
            sentence += " " + String(localized: "wrapped.distance.times-around-earth", defaultValue: "\(times) times around the Earth.", comment: "Wrapped distance card: the total compared with the Earth's equator, a decimal such as 1.2.")
        } else if laps >= 0.1 {
            let share = laps.formatted(.percent.precision(.fractionLength(0)).locale(content.locale))
            sentence += " " + String(localized: "wrapped.distance.share-of-earth", defaultValue: "\(share) of the way around the Earth.", comment: "Wrapped distance card: the total as a percentage of the Earth's equator.")
        }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                numeral(distance.value, 150, compact: compact)
                line(sentence, compact: compact)
            }
            .accessibilityElement(children: .combine)
            if !compact, laps >= 0.25 {
                EarthLaps(laps: laps, ring: palette.track, mark: palette.mark, label: fg2,
                          ink: fg, locale: content.locale, revealed: revealed)
                    .frame(width: 240, height: 240)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            ForEach(minimal ? [] : Array(content.modes.indices), id: \.self) { index in
                let mode = content.modes[index]
                HStack {
                    Text(mode.label).font(.subheadline.weight(.semibold)).foregroundStyle(fg2)
                    Spacer()
                    Text(UnitsFormatter.formatDistance(kilometers: mode.km))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(fg)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func homeAwayCompactBody(minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            figureBlock(units.number(content.daysAway), units.daysAway(content.daysAway), base: 110, compact: true, color: palette.mark)
            figureBlock(units.number(content.daysHome), units.daysAtHome(content.daysHome), base: 110, compact: true)
            PosterProportionBar(fraction: content.awayFraction, fill: palette.mark, rest: palette.track,
                                revealed: revealed)
                .frame(height: 14)
                .accessibilityHidden(true)
            if let ratio = HomeAwayBandPage.ratioText(content), !minimal {
                caption(ratio)
            }
        }
    }

    private func firstVisitsBody(_ compact: Bool, minimal: Bool) -> some View {
        let count = content.newCountries.count
        let shown = content.newCountries.prefix(minimal ? 3 : typeSize.isAccessibilitySize ? 4 : 6)
        // One column at accessibility sizes so country names stay whole.
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .leading)]
            : [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        return VStack(alignment: .leading, spacing: 14) {
            line(count == 1
                 ? String(localized: "wrapped.first-visits.count.one", defaultValue: "\(units.number(count)) country for the first time", comment: "Wrapped first-visits card headline; one country was visited for the first time that year.")
                 : String(localized: "wrapped.first-visits.count.other", defaultValue: "\(units.number(count)) countries for the first time", comment: "Wrapped first-visits card headline; several countries were visited for the first time that year."),
                 compact: compact, style: .title2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 10 : 18) {
                ForEach(Array(shown)) { country in
                    VStack(alignment: .leading, spacing: 2) {
                        numeral(country.code, 120, compact: compact, tight: true)
                            .accessibilityHidden(true)
                        PosterHeading(text: country.name, color: fg2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if count > shown.count {
                caption(String(localized: "wrapped.first-visits.more", defaultValue: "And \(units.number(count - shown.count)) more.", comment: "Wrapped first-visits card: how many more first-visit countries are not shown."))
            }
        }
    }

    private func weatherBody(_ compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let hot = content.hottest {
                weatherBlock(hot.value, String(localized: "wrapped.weather.hottest-place", defaultValue: "Hottest, \(hot.place)", comment: "Wrapped weather card label under the hottest temperature: the place it was measured; shown in capitals."), compact: compact, color: mark)
            }
            // Minimal keeps one figure so the attribution has its room.
            if let cold = content.coldest, !minimal || content.hottest == nil {
                weatherBlock(cold.value, String(localized: "wrapped.weather.coldest-place", defaultValue: "Coldest, \(cold.place)", comment: "Wrapped weather card label under the coldest temperature: the place it was measured; shown in capitals."), compact: compact)
            }
            if let wet = content.wettest, !minimal || (content.hottest == nil && content.coldest == nil) {
                weatherBlock(wet.value, String(localized: "wrapped.weather.wettest-trip", defaultValue: "Wettest trip, \(wet.trip)", comment: "Wrapped weather card label under the most rain on one trip: the trip's name; shown in capitals."), compact: compact)
            }
            // Apple Weather attribution, gated like TripDetailView's.
            WeatherAttributionFootnote()
                .foregroundStyle(fg2)
        }
    }

    private func weatherBlock(_ value: String, _ label: String, compact: Bool, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            numeral(value, 104, compact: compact, color: color)
            PosterHeading(text: label, color: fg2)
        }
        .accessibilityElement(children: .combine)
    }

    private func closingBody(_ compact: Bool, minimal: Bool) -> some View {
        let distance = WrappedUnits.distance(content.totalKm, locale: content.locale)
        var rows: [(String, String)] = []
        if content.trips > 0 { rows.append((units.number(content.trips), units.trips(content.trips))) }
        rows.append((units.number(content.countries), units.countries(content.countries)))
        if content.cities > 0 { rows.append((units.number(content.cities), units.cities(content.cities))) }
        if content.daysAway > 0 { rows.append((units.number(content.daysAway), units.daysAway(content.daysAway))) }
        if content.totalKm > 0 {
            rows.append((distance.value, typeSize.isAccessibilitySize ? distance.unit : distance.longUnit))
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                figure(rows[index].0, rows[index].1, base: 72, compact: compact)
            }
            if let footnote = content.footnote, !minimal {
                caption(footnote)
                    .padding(.top, 12)
            }
            if let share {
                ShareLink(
                    item: share,
                    preview: SharePreview(String(localized: "wrapped.share-preview", defaultValue: "TravelLog \(content.year, format: .number.grouping(.never)) Wrapped", comment: "Share preview title for a Wrapped year; keep TravelLog verbatim."))
                ) {
                    Label(String(localized: "wrapped.closing.share", defaultValue: "Share the poster", comment: "Wrapped closing card button that shares the year as a poster image."),
                          systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(palette.field, in: .capsule)
                }
                .padding(.top, 20)
            }
        }
    }
}

// MARK: - Pieces

/// Small expanded capitals: card headings and chart labels.
private struct PosterHeading: View {
    let text: String
    let color: Color
    /// Card headings keep clear of the Close button's corner.
    var clearsClose = false

    var body: some View {
        Text(text.uppercased(with: AppLanguagePreference.currentLocale()))
            .font(.footnote.weight(.semibold).width(.expanded))
            .tracking(1.2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, clearsClose ? 48 : 0)
            .accessibilityAddTraits(clearsClose ? .isHeader : [])
    }
}

private struct PosterFooter: View {
    let year: Int
    let index: Int
    let total: Int
    let color: Color

    var body: some View {
        HStack {
            Text(verbatim: "TravelLog \(year)")
            Spacer()
            Text(verbatim: "\(index + 1)/\(total)")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold).width(.expanded))
        .lineLimit(1)
        .foregroundStyle(color)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }
}

/// The home-and-away card at standard text sizes: the page is the chart.
/// The colour band takes the away share of the year's height (with a floor
/// so its text fits; the note claiming the share shows only when the floor
/// did not apply).
private struct HomeAwayBandPage: View {
    let content: WrappedPosterContent
    let palette: WrappedPosterPalette
    let index: Int
    let total: Int
    let revealed: Bool

    private static let minimumBand: CGFloat = 170

    static func ratioText(_ content: WrappedPosterContent) -> String? {
        guard content.daysAway > 0 else { return nil }
        let away = content.units.usesTripSpanDays
        let denominator = Int((Double(content.daysAway + content.daysHome) / Double(content.daysAway)).rounded())
        if denominator < 2 {
            return away
                ? String(localized: "wrapped.balance.ratio.most", defaultValue: "Most of the year was spent away.", comment: "Wrapped home-and-away card when at least half the year was spent away from home.")
                : String(localized: "wrapped.balance.ratio.most-abroad", defaultValue: "Most of the year was spent abroad.", comment: "Wrapped home-and-away card, recaps saved before domestic trips counted, when at least half the year was spent abroad.")
        }
        let spelled = NumberFormatter()
        spelled.numberStyle = .spellOut
        spelled.locale = content.locale
        let word = denominator <= 10 ? spelled.string(from: denominator as NSNumber) : nil
        let n = word ?? content.units.number(denominator)
        return away
            ? String(localized: "wrapped.balance.ratio", defaultValue: "About one day in \(n) was spent away.", comment: "Wrapped home-and-away card: the share of the year spent away as one day in N; N may be written as a word, such as five.")
            : String(localized: "wrapped.balance.ratio.abroad", defaultValue: "About one day in \(n) was spent abroad.", comment: "Wrapped home-and-away card, recaps saved before domestic trips counted: the share of the year spent abroad as one day in N; N may be written as a word.")
    }

    var body: some View {
        GeometryReader { geo in
            let exact = geo.size.height * content.awayFraction
            let band = max(exact, Self.minimumBand)
            ZStack(alignment: .top) {
                palette.paper
                palette.field
                    .frame(height: revealed ? band : 0)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .wrappedGrow(revealed)
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        PosterHeading(text: String(localized: "wrapped.heading.home-away", defaultValue: "Home and away", comment: "Wrapped card heading comparing days away with days at home; shown in capitals."),
                                      color: palette.onField, clearsClose: true)
                        Spacer(minLength: 0)
                        figure(content.units.number(content.daysAway), content.units.daysAway(content.daysAway),
                               color: palette.onField)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 62)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: band)
                    .wrappedRise(revealed, delay: WrappedMotion.stagger * 3)

                    VStack(alignment: .leading, spacing: 8) {
                        Spacer(minLength: 0)
                        figure(content.units.number(content.daysHome), content.units.daysAtHome(content.daysHome),
                               color: palette.ink)
                        if let ratio = Self.ratioText(content) {
                            Text(ratio + (exact >= Self.minimumBand ? " " + String(localized: "wrapped.balance.area-note", defaultValue: "The colored band is that share of the year.", comment: "Wrapped home-and-away card: explains that the colored top band's height is the share of the year spent away.") : ""))
                                .font(.subheadline)
                                .foregroundStyle(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 20)
                        }
                        PosterFooter(year: content.year, index: index, total: total, color: palette.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .wrappedRise(revealed, delay: WrappedMotion.stagger * 4)
                }
            }
        }
    }

    private func figure(_ value: String, _ unit: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: value)
                .font(PosterMetrics.numeral(88))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.title3.weight(.bold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charts

/// Twelve columns, one highlighted; only the highlight carries its value.
private struct PosterMonthColumns: View {
    let values: [Int]
    let highlight: Int?
    let initials: [String]
    let base: Color
    let accent: Color
    let label: Color
    let valueInk: Color
    let rule: Color
    let revealed: Bool

    var body: some View {
        let peak = max(values.max() ?? 1, 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(values.indices, id: \.self) { index in
                        let value = values[index]
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            if index == highlight {
                                Text(verbatim: value.formatted())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(valueInk)
                            }
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(index == highlight ? accent : base)
                                .frame(height: value == 0 ? 0 : max(4, (geo.size.height - 24) * Double(value) / Double(peak)))
                                .scaleEffect(y: revealed ? 1 : 0, anchor: .bottom)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .wrappedGrow(revealed, delay: WrappedMotion.stagger * 2)
            }
            Rectangle().fill(rule).frame(height: 1)
            HStack(spacing: 5) {
                ForEach(initials.indices, id: \.self) { month in
                    Text(initials[month]).frame(maxWidth: .infinity)
                }
            }
            .font(.caption2)
            .foregroundStyle(label)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }
}

/// Part of a whole as one bar, with a 2 pt gap between the parts.
private struct PosterProportionBar: View {
    let fraction: Double
    let fill: Color
    let rest: Color
    let revealed: Bool

    var body: some View {
        GeometryReader { geo in
            let filled = max(geo.size.height, (geo.size.width - 2) * fraction)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(rest)
                RoundedRectangle(cornerRadius: 4).fill(fill)
                    .frame(width: revealed ? filled : 0)
                    .wrappedGrow(revealed, delay: WrappedMotion.stagger * 2)
            }
        }
    }
}

/// One hexagon per unit, packed outward from the centre in rings.
struct Honeycomb: View {
    let count: Int
    let fill: Color

    static func cells(_ count: Int) -> [(q: Int, r: Int)] {
        guard count > 0 else { return [] }
        var all: [(q: Int, r: Int, d: Int, a: Double)] = []
        let radius = 12
        for q in -radius...radius {
            for r in -radius...radius {
                let s = -q - r
                guard abs(s) <= radius else { continue }
                let d = max(abs(q), abs(r), abs(s))
                let x = Double(q) + Double(r) / 2
                let y = Double(r) * 0.866
                all.append((q, r, d, atan2(y, x)))
            }
        }
        all.sort { $0.d != $1.d ? $0.d < $1.d : $0.a < $1.a }
        return all.prefix(count).map { ($0.q, $0.r) }
    }

    var body: some View {
        Canvas { context, size in
            let cells = Self.cells(count)
            guard !cells.isEmpty else { return }
            let rings = cells.map { max(abs($0.q), abs($0.r), abs(-$0.q - $0.r)) }.max() ?? 0
            let across = Double(2 * rings + 1)
            let s = min(size.width / (across * 1.732), size.height / (across * 1.5 + 0.5))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for cell in cells {
                let cx = center.x + s * 1.732 * (Double(cell.q) + Double(cell.r) / 2)
                let cy = center.y + s * 1.5 * Double(cell.r)
                var path = Path()
                let inner = s - 1.2 // a 2 pt gap between cells
                for k in 0..<6 {
                    let angle = Double(k) * .pi / 3 - .pi / 6
                    let p = CGPoint(x: cx + inner * cos(angle), y: cy + inner * sin(angle))
                    if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                context.fill(path, with: .color(fill))
            }
        }
    }
}

/// Distance as laps of the equator: one full ring per lap, the last one
/// partial, nested inward.
private struct EarthLaps: View {
    let laps: Double
    let ring: Color
    let mark: Color
    let label: Color
    let ink: Color
    let locale: Locale
    let revealed: Bool

    var body: some View {
        let full = Int(laps)
        let rest = laps - Double(full)
        let count = max(min(full + (rest > 0.01 ? 1 : 0), 5), 1)
        let text = laps.formatted(.number.precision(.fractionLength(1)).locale(locale))
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let inset = CGFloat(index) * 24
                let trim = index < full ? 1.0 : rest
                Circle().stroke(ring, lineWidth: 12).padding(inset)
                Circle()
                    .trim(from: 0, to: revealed ? trim : 0)
                    .stroke(mark, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
                    .wrappedGrow(revealed, delay: WrappedMotion.stagger * Double(2 + index * 4))
            }
            VStack(spacing: 2) {
                Text(verbatim: text)
                    .font(PosterMetrics.numeral(56))
                    .foregroundStyle(ink)
                Text(String(localized: "wrapped.distance.laps", defaultValue: "laps of the Earth", comment: "Wrapped distance card: caption inside the ring chart under a decimal number of laps of the equator."))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(label)
                    .multilineTextAlignment(.center)
            }
            .padding(Double(count) * 24 + 8)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "wrapped.distance.laps.a11y", defaultValue: "Ring chart: \(text) laps of the Earth.", comment: "VoiceOver label for the Wrapped ring chart of the total distance as laps of the Earth's equator."))
    }
}
