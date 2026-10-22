//
//  TripShareCard.swift
//  TravelLog
//
//  The overview image a share carries, the approved "Route map" card: a
//  dark 360 x 450 pt card with the trip's territory and route on a map
//  (`TripShareCardMap`), its flags, title and dates, then its days,
//  countries, places and distance, and the Travel Log mark. Up to four
//  trips share one card each; five or more share one summary card listing
//  each trip by flag, title and dates over the totals, with one card per
//  trip a switch away. Cards are built from the same home-filtered trips
//  the file carries, so an image shows no home area either, and render
//  with `ImageRenderer` at 3x.
//

import MapKit
import SwiftUI
import UIKit

/// Whether several trips share one image each or one summary.
nonisolated enum TripShareImages: Hashable, Sendable {
    case perTrip
    case summary

    /// Five trips or more default to one summary image.
    static let summaryThreshold = 5

    static func defaultChoice(tripCount: Int) -> TripShareImages {
        tripCount >= summaryThreshold ? .summary : .perTrip
    }

    /// The share sheet offers the switch only where a summary is the default.
    static func offersChoice(tripCount: Int) -> Bool {
        tripCount >= summaryThreshold
    }
}

/// The numbers a card counts, before any formatting.
nonisolated struct TripShareFigures: Equatable, Sendable {
    var days: Int
    var countries: Int
    var places: Int
    var kilometers: Double

    init(days: Int, countries: Int, places: Int, kilometers: Double) {
        self.days = days
        self.countries = countries
        self.places = places
        self.kilometers = kilometers
    }

    /// One trip: its days (so far, for one still going on), its countries,
    /// its destinations (the trip page's places) and its own legs.
    init(_ trip: SharedTrip, now: Date) {
        self.init(days: Self.days(trip, now: now),
                  countries: Set(trip.countryCodes.map { $0.uppercased() }).count,
                  places: trip.destinations.count,
                  kilometers: Self.distanceKm(trip))
    }

    /// Several trips: their days, places and distance added up, and every
    /// country they reached once.
    init(_ trips: [SharedTrip], now: Date) {
        let each = trips.map { TripShareFigures($0, now: now) }
        self.init(days: each.reduce(0) { $0 + $1.days },
                  countries: Set(trips.flatMap { $0.countryCodes.map { $0.uppercased() } }).count,
                  places: each.reduce(0) { $0 + $1.places },
                  kilometers: each.reduce(0) { $0 + $1.kilometers })
    }

    static func days(_ trip: SharedTrip, now: Date) -> Int {
        if let days = SharedTripText.dayCount(trip) { return days }
        let first = trip.stays.min { $0.startTime < $1.startTime }
        return Trip.inclusiveDays(
            from: trip.startDate, in: StayTimeZone.resolve(first?.timeZoneIdentifier),
            to: max(now, trip.startDate), in: .current)
    }

    /// The trip's own legs: each stay's great-circle distance from the stay
    /// before it, in trip order. The first stay's leg starts at the
    /// sender's home and never counts; a stay with no leg adds nothing.
    static func distanceKm(_ trip: SharedTrip) -> Double {
        let ordered = trip.stays.sorted {
            ($0.orderInTrip ?? 0, $0.startTime, $0.id.uuidString)
                < ($1.orderInTrip ?? 0, $1.startTime, $1.id.uuidString)
        }
        return ordered.dropFirst().reduce(0) { total, stay in
            guard let km = stay.distanceFromPreviousKm, km.isFinite, km > 0 else { return total }
            return total + km
        }
    }
}

/// The flags a trip card shows: all of up to `limit`, else one fewer and
/// a count of the rest, so the row never runs past the card.
nonisolated struct TripShareFlags: Equatable, Sendable {
    static let limit = 6

    let shown: [String]
    let extra: Int

    init(codes: [String]) {
        if codes.count <= Self.limit {
            shown = codes
            extra = 0
        } else {
            shown = Array(codes.prefix(Self.limit - 1))
            extra = codes.count - shown.count
        }
    }
}

/// The summary card's list: every trip up to `limit`, else one row fewer
/// and a line counting the rest.
nonisolated enum TripShareSummaryRows {
    static let limit = 12

    static func shownCount(of total: Int) -> Int {
        total <= limit ? total : limit - 1
    }
}

/// Everything a card shows, already localized.
struct TripShareCardContent {
    /// The canvas, in points; rendered at `scale` (1080 x 1350 px).
    static let size = CGSize(width: 360, height: 450)
    static let scale: CGFloat = 3

    struct Count: Equatable {
        let value: String
        let label: String
    }

    struct Row: Equatable {
        let countryCode: String?
        let title: String
        let dates: String
    }

    enum Body {
        case trip(flags: TripShareFlags, map: TripShareCardMap?)
        case summary(rows: [Row], more: String?)
    }

    var title: String
    var dates: String
    var counts: [Count]
    var body: Body
}

extension TripShareCardContent {

    /// One trip's card around its map.
    static func trip(_ trip: SharedTrip, map: TripShareCardMap?, now: Date = .now,
                     locale: Locale = AppLanguagePreference.currentLocale()) -> TripShareCardContent {
        TripShareCardContent(
            title: title(trip),
            dates: dates(trip, includeYear: true, locale: locale),
            counts: counts(TripShareFigures(trip, now: now), locale: locale),
            body: .trip(flags: TripShareFlags(codes: trip.countryCodes), map: map))
    }

    /// One card for several trips: "12 trips", their whole span, one row
    /// per trip in trip order and the totals.
    static func summary(_ trips: [SharedTrip], now: Date = .now,
                        locale: Locale = AppLanguagePreference.currentLocale()) -> TripShareCardContent {
        let ordered = trips.sorted { ($0.startDate, $0.shareID.uuidString) < ($1.startDate, $1.shareID.uuidString) }
        let start = ordered.first?.startDate ?? now
        let end = ordered.map { $0.endDate ?? max(now, $0.startDate) }.max() ?? start
        // Rows carry the year only when the trips span more than one.
        let calendar = Calendar.current
        let oneYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let shown = TripShareSummaryRows.shownCount(of: ordered.count)
        let rows = ordered.prefix(shown).map { trip in
            Row(countryCode: trip.countryCodes.first, title: title(trip),
                dates: dates(trip, includeYear: !oneYear, locale: locale))
        }
        let rest = ordered.count - shown
        let count = ordered.count
        return TripShareCardContent(
            title: String(localized: "trip-share.card.summary.title",
                          defaultValue: "\(count, format: .number.grouping(.never)) trips",
                          comment: "Title of the share image summing up several trips (always 5 or more); the placeholder is how many."),
            dates: DateRangeText.format(start..<max(start, end), intervalStyle(includeYear: true, locale: locale)),
            counts: counts(TripShareFigures(ordered, now: now), locale: locale),
            body: .summary(rows: Array(rows), more: rest > 0
                ? String(localized: "trip-share.card.summary.more",
                         defaultValue: "\(rest, format: .number.grouping(.never)) more trips",
                         comment: "Last line of the share image summing up several trips, counting the trips it has no room to list (always 2 or more).")
                : nil))
    }

    /// The trip's name; without one, its countries, then "Trip".
    static func title(_ trip: SharedTrip) -> String {
        trip.displayTitle()
            ?? TripDisplayText.countryNames(trip.countryCodes)
            ?? String(localized: "trip.display-name.fallback", defaultValue: "Trip",
                      comment: "Fallback display name for a trip with no usable title or destination.")
    }

    /// "5 to 11 Aug 2031"; "Since 14 Oct" for a trip still going on. Each
    /// end's day where it happened, as the card's day count reads it.
    static func dates(_ trip: SharedTrip, includeYear: Bool, locale: Locale) -> String {
        let zones = SharedTripText.boundaryZones(trip)
        guard let end = trip.endDate else { return TripDisplayText.since(trip.startDate, in: zones.start) }
        let first = TravelDays.label(for: trip.startDate, zone: zones.start) ?? trip.startDate
        let last = TravelDays.label(for: end, zone: zones.end) ?? end
        var style = intervalStyle(includeYear: includeYear, locale: locale)
        style.timeZone = TravelDays.labelCalendar.timeZone
        return DateRangeText.format(first..<max(first, last), style)
    }

    static func intervalStyle(includeYear: Bool, locale: Locale) -> Date.IntervalFormatStyle {
        let style = Date.IntervalFormatStyle(locale: locale).day().month(.abbreviated)
        return includeYear ? style.year() : style
    }

    /// Days, then countries, places and distance where there are any: a
    /// trip with one stop travelled no leg, and an ungeocoded one has no
    /// country to count.
    static func counts(_ figures: TripShareFigures, locale: Locale) -> [Count] {
        let units = WrappedUnits(locale: locale)
        var counts = [Count(value: units.number(figures.days), label: units.days(figures.days))]
        if figures.countries > 0 {
            counts.append(Count(value: units.number(figures.countries), label: units.countries(figures.countries)))
        }
        if figures.places > 0 {
            counts.append(Count(value: units.number(figures.places), label: places(figures.places, locale: locale)))
        }
        let travelled = UnitsFormatter.isImperial ? figures.kilometers / 1.609_344 : figures.kilometers
        if travelled.rounded() >= 1 {
            let distance = WrappedUnits.distance(figures.kilometers, locale: locale)
            counts.append(Count(value: distance.value, label: distance.unit))
        }
        return counts
    }

    static func places(_ count: Int, locale: Locale) -> String {
        count == 1
            ? String(localized: "trip-share.card.unit.places.one", defaultValue: "place", locale: locale,
                     comment: "Share image unit under the number of a trip's places; the number is shown separately. One place.")
            : String(localized: "trip-share.card.unit.places.other", defaultValue: "places", locale: locale,
                     comment: "Share image unit under the number of a trip's places; the number is shown separately. Several places.")
    }
}

extension WrappedUnits {
    /// Unit words for a surface that is not a recap: today's wording.
    init(locale: Locale) {
        self.locale = locale
        usesTripSpanDays = true
    }
}

// MARK: - Views

/// The card at its canvas size: one trip over its map, or the summary.
struct TripShareCardView: View {
    let content: TripShareCardContent

    static let background = Color(UIColor(hex: 0x0B0C10))
    static let secondary = Color(UIColor(hex: 0xEBEBF5, alpha: 0.66))

    var body: some View {
        ZStack(alignment: .topLeading) {
            Self.background
            switch content.body {
            case .trip(let flags, let map):
                TripShareCardMapView(map: map)
                LinearGradient(colors: [Self.background.opacity(0), Self.background],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: TripShareCardContent.size.width, height: 62)
                    .offset(y: 172)
                VStack(alignment: .leading, spacing: 0) {
                    if !flags.shown.isEmpty {
                        flagRow(flags)
                            .padding(.bottom, 9)
                    }
                    header
                    Spacer(minLength: 0)
                    footer
                }
                .padding(EdgeInsets(top: 214, leading: 20, bottom: 16, trailing: 20))
            case .summary(let rows, let more):
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            summaryRow(row)
                        }
                        if let more {
                            Text(more)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Self.secondary)
                                .lineLimit(1)
                                .padding(.leading, FlagView.Size.small.dimensions.width + 9)
                                .frame(height: 21)
                        }
                    }
                    .padding(.top, 12)
                    Spacer(minLength: 0)
                    footer
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
            }
        }
        .frame(width: TripShareCardContent.size.width, height: TripShareCardContent.size.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.title)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.39)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(content.dates)
                .font(.system(size: 15))
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func flagRow(_ flags: TripShareFlags) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(flags.shown.enumerated()), id: \.offset) { _, code in
                FlagView(iso: code, size: .regular)
            }
            if flags.extra > 0 {
                Text(verbatim: "+" + flags.extra.formatted(.number.grouping(.never)))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(TripShareCardMapView.line)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(minWidth: 22, minHeight: 16, maxHeight: 16)
                    .background(Color(UIColor(hex: 0x2C2C2E)), in: .capsule)
            }
        }
        .frame(height: FlagView.Size.regular.dimensions.height)
    }

    private func summaryRow(_ row: TripShareCardContent.Row) -> some View {
        HStack(spacing: 9) {
            FlagView(iso: row.countryCode, size: .small)
            Text(row.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.dates)
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 21)
    }

    /// The counts over a hairline, then the mark.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 0.5)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(content.counts.enumerated()), id: \.offset) { index, count in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(count.value)
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(height: 26)
                        Text(count.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Self.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: 16)
                    }
                    .padding(.leading, index == 0 ? 0 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 0.5)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(.top, 12)
            HStack(spacing: 5) {
                Circle()
                    .stroke(TripShareCardMapView.line, lineWidth: 2)
                    .frame(width: 8, height: 8)
                    .frame(width: 12, height: 12)
                Text(verbatim: "Travel Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(UIColor(hex: 0xEBEBF5, alpha: 0.62)))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 12)
        }
    }
}

// MARK: - Rendering

@MainActor
enum TripShareCardRenderer {

    /// One trip's card content with its map.
    static func content(for trip: SharedTrip, exclusions: TripShareExclusions, now: Date = .now,
                        locale: Locale = AppLanguagePreference.currentLocale()) async -> TripShareCardContent {
        let map = await TripShareCardMapBuilder.map(for: trip, exclusions: exclusions)
        return .trip(trip, map: map, now: now, locale: locale)
    }

    static func image(_ content: TripShareCardContent,
                      locale: Locale = AppLanguagePreference.currentLocale()) -> UIImage? {
        let view = TripShareCardView(content: content)
            .environment(\.locale, locale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = TripShareCardContent.scale
        renderer.proposedSize = ProposedViewSize(TripShareCardContent.size)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// A padded region around the points, dateline-safe.
    static func region(covering points: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !points.isEmpty else { return nil }
        let lats = points.map(\.latitude)
        guard let bounds = GeoMath.boundingLongitude(of: points.map(\.longitude)),
              let minLat = lats.min(), let maxLat = lats.max() else { return nil }
        let latSpan = min(170, max(0.05, (maxLat - minLat) * 1.5))
        let lonSpan = min(355, max(0.05, bounds.span * 1.5))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: bounds.center),
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
    }
}

/// The date and count phrases a shared trip shows, in the app's grammar
/// ("12 to 20 Apr 2031", never an interval dash).
enum SharedTripText {
    /// Each end's day where it happened, as `dayCount` reads it.
    static func dates(_ trip: SharedTrip) -> String {
        let zones = boundaryZones(trip)
        guard let end = trip.endDate else { return TripDisplayText.since(trip.startDate, in: zones.start) }
        return TripDisplayText.range(from: trip.startDate, in: zones.start, to: end, in: zones.end, includeYear: true)
    }

    /// The zones a shared trip's first and last days are read in: its
    /// earliest stay's and its latest-ending stay's, else the device's.
    nonisolated static func boundaryZones(_ trip: SharedTrip) -> (start: TimeZone, end: TimeZone) {
        let first = trip.stays.min { $0.startTime < $1.startTime }
        let last = trip.stays.max { $0.endTime < $1.endTime }
        return (StayTimeZone.resolve(first?.timeZoneIdentifier), StayTimeZone.resolve(last?.timeZoneIdentifier))
    }

    nonisolated static func dayCount(_ trip: SharedTrip) -> Int? {
        guard let end = trip.endDate else { return nil }
        let zones = boundaryZones(trip)
        return Trip.inclusiveDays(
            from: trip.startDate, in: zones.start,
            to: max(end, trip.startDate), in: zones.end)
    }

    static func days(_ trip: SharedTrip) -> String? {
        guard let count = dayCount(trip) else { return nil }
        return count == 1
            ? String(localized: "trip-share.day-count.one", defaultValue: "\(count, format: .number.grouping(.never)) day", comment: "Length of a shared trip of one day, on its image and preview.")
            : String(localized: "trip-share.day-count.other", defaultValue: "\(count, format: .number.grouping(.never)) days", comment: "Length of a shared trip of several days, on its image and preview.")
    }

    static func stops(_ count: Int) -> String {
        count == 1
            ? String(localized: "trip-share.stop-count.one", defaultValue: "\(count, format: .number.grouping(.never)) stop", comment: "Count of a shared trip's stops (destinations and transit), for one.")
            : String(localized: "trip-share.stop-count.other", defaultValue: "\(count, format: .number.grouping(.never)) stops", comment: "Count of a shared trip's stops (destinations and transit), for several.")
    }
}
