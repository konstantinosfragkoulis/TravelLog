//
//  TripsListView+Rows.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import TipKit
import UIKit
import SwiftData
import WidgetKit
import os.log

// MARK: - Active Trip Row

/// A prominent row for an ongoing trip: the flag deck, title and countries,
/// then the saffron "Active" pill with its day count and start. The trip has
/// no known end, so the row counts days since its start only.
struct ActiveTripRow: View {
    let trip: Trip
    var caption: TripsListView.MatchCaption?
    /// The temporary-home question, from the list's cache (never computed here).
    var suggestion: TemporaryHomeSuggestion.Candidate?
    var onSetUp: (TemporaryHomeSuggestion.Candidate) -> Void = { _ in }
    var onNotNow: (TemporaryHomeSuggestion.Candidate) -> Void = { _ in }

    var body: some View {
        let codes = trip.countryCodeList
        TripLeadRow(codes: codes) {
            Text(trip.hasUsableDisplayName ? trip.displayName : String(localized: "trips.active-name.fallback", defaultValue: "Trip in Progress", comment: "Fallback title for an ongoing trip without a usable name."))
                .font(.headline)
                .lineLimit(2)

            if let names = TripRowText.countryLine(codes) {
                Text(names)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)
            }

            HStack(spacing: 6) {
                ActiveStatePill()

                // Count calendar-date boundaries rather than elapsed 24-hour intervals.
                // Same civil-day rule as the Current Trip widget: inclusive
                // Gregorian days between the departure stay's zone and the
                // latest stay's zone, so the list and the widget agree.
                // Minute ticks land on every zone's midnight, so the day flips with no store write.
                // A tick can land after a background delete and before the parent
                // filters the row; `isDeleted` is the one safe read on an invalidated model.
                TimelineView(.everyMinute) { context in
                    if !trip.isDeleted, trip.modelContext != nil {
                        Text(Self.dayText(TripsListView.ongoingDisplayDay(for: trip, now: context.date)))
                    }
                }

                Text(verbatim: "·").accessibilityHidden(true)

                // Its first day where it began, the day its count starts from.
                Text(TripDisplayText.since(trip.startDate, in: TripDisplayText.boundaryZones(of: trip).start))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 8)

            matchCaptionLine(caption)
                .padding(.top, caption == nil ? 0 : 6)

            if let suggestion {
                TemporaryHomeSuggestionLine(
                    candidate: suggestion,
                    onSetUp: { onSetUp(suggestion) },
                    onNotNow: { onNotNow(suggestion) })
                .padding(.top, 10)
            }
        }
        .wholePointHeight()
    }

    /// "Day 3", shared by the row and the trip page.
    static func dayText(_ displayDay: Int) -> String {
        displayDay == 1
            ? String(localized: "trips.active-day.one", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for its first day.")
            : String(localized: "trips.active-day.other", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for a later day.")
    }
}

// MARK: - Temporary Home Suggestion

/// Reruns the trips list's suggestions on stay changes while `isActive`.
/// The token read lives here, so a stay change redraws this empty view, not the list.
struct TemporaryHomeSuggestionStayObserver: View {
    let isActive: Bool
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .task(id: TripsListView.suggestionStayToken(followsStays: isActive)) {
                guard isActive else { return }
                onChange()
            }
    }
}

/// "Living in Brussels for now?" with Set Up and Not Now, on an open trip's
/// row and at the top of a trip's detail. Pure display over the candidate.
struct TemporaryHomeSuggestionLine: View {
    let candidate: TemporaryHomeSuggestion.Candidate
    let onSetUp: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.text(placeName: candidate.placeName, isOngoing: candidate.isOngoing))
            } icon: {
                Image(systemName: "house.and.flag")
                    .foregroundStyle(.tint)
            }
            .font(.caption)

            // Borderless, so a row's link does not swallow the taps.
            HStack(spacing: 10) {
                Button {
                    onSetUp()
                } label: {
                    Text(String(
                        localized: "temporary-home.suggestion.set-up",
                        defaultValue: "Set Up",
                        comment: "Button on the temporary home suggestion that opens the form for a new temporary home, prefilled from the trip."
                    ))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(AppTheme.cobaltFill, in: .capsule)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.borderless)

                Button {
                    onNotNow()
                } label: {
                    Text(String(
                        localized: "temporary-home.suggestion.not-now",
                        defaultValue: "Not Now",
                        comment: "Button on the temporary home suggestion that hides it for this trip on this device."
                    ))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The question: ongoing "Living in Brussels for now?", completed "Lived
    /// in Brussels for a while?", then why. Without a city it asks about
    /// "here" (ongoing) or "there" (completed).
    static func text(placeName: String?, isOngoing: Bool) -> String {
        if let placeName, !placeName.isEmpty {
            return isOngoing
                ? String(localized: "temporary-home.suggestion.ongoing.place", defaultValue: "Living in \(placeName) for now? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on an ongoing trip that mostly stays in one city; the placeholder is the city. A temporary home makes trips from there separate trips.")
                : String(localized: "temporary-home.suggestion.completed.place", defaultValue: "Lived in \(placeName) for a while? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on a long completed trip that mostly stayed in one city; the placeholder is the city. A temporary home makes trips from there separate trips.")
        }
        return isOngoing
            ? String(localized: "temporary-home.suggestion.ongoing.here", defaultValue: "Living here for now? Set up a temporary home so your trips from here count on their own.", comment: "Suggestion on an ongoing trip that mostly stays in one place whose city is unknown. A temporary home makes trips from there separate trips.")
            : String(localized: "temporary-home.suggestion.completed.there", defaultValue: "Lived there for a while? Set up a temporary home so your trips from there count on their own.", comment: "Suggestion on a long completed trip that mostly stayed in one place whose city is unknown. A temporary home makes trips from there separate trips.")
    }
}

/// Why a search row matched, when the row does not already show it. The
/// text joins the row's combined accessibility label; the symbol is decorative.
@ViewBuilder
private func matchCaptionLine(_ caption: TripsListView.MatchCaption?) -> some View {
    if let caption {
        HStack(spacing: 4) {
            Image(systemName: caption.systemImage)
                .accessibilityHidden(true)
            Text(caption.text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Whole-Point Rows

/// Sizes a row to whole points. Text heights land on fractions of a point,
/// and the list then leaves a one-pixel seam between two cells, where the
/// page shows through like a separator running the card's full width.
private struct WholePointHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

extension View {
    func wholePointHeight() -> some View {
        WholePointHeight { self }
    }
}

// MARK: - Trip Row

/// A standard row for a completed trip: the flag deck; the title; the
/// countries by name; then dates and length, with its places beside them
/// (or under them when the line runs out of room).
struct TripRow: View {
    let trip: Trip
    var caption: TripsListView.MatchCaption?
    /// False inside a year section, whose header already says it.
    var showsYear = true
    /// The trip's unanswered "Did you go home?" questions, from the list's cache.
    var questions = 0

    var body: some View {
        TripRowContent(
            title: trip.displayName,
            codes: trip.countryCodeList,
            dates: formattedDateRange,
            days: trip.durationDays.map(TripRowText.days),
            places: trip.destinationCount,
            caption: caption,
            questions: questions)
    }

    /// Read in the trip's own zones, as its day count is.
    private var formattedDateRange: String {
        TripDisplayText.tripDates(trip, includeYear: showsYear)
    }
}

/// A completed trip row's layout over plain values (the row and previews).
struct TripRowContent: View {
    let title: String
    let codes: [String]
    let dates: String
    let days: String?
    var places = 0
    var caption: TripsListView.MatchCaption?
    var questions = 0

    var body: some View {
        TripLeadRow(codes: codes) {
            Text(title)
                .font(.headline)
                .lineLimit(2)

            if let names = TripRowText.countryLine(codes) {
                Text(names)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)
            }

            TripMetaLine(dates: dates, days: days, places: places)
                .padding(.top, 3)

            if questions > 0 {
                TripGapBadge(count: questions)
                    .padding(.top, 8)
            }

            matchCaptionLine(caption)
                .padding(.top, caption == nil ? 0 : 6)
        }
        .wholePointHeight()
    }
}

// MARK: - Flag Lead

/// The trips list's row grammar: the flag deck in a 48 pt lead column,
/// centred on the text column beside it. The separator starts at the text
/// column.
struct TripLeadRow<Content: View>: View {
    let codes: [String]
    @ViewBuilder var content: Content

    var body: some View {
        // The deck, as one group, centres on the text block: the row's
        // leading icon, not a flag pinned to its corner.
        HStack(alignment: .center, spacing: FlagDeck.gap) {
            FlagDeck(codes: codes)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in FlagDeck.width + FlagDeck.gap }
    }
}

/// A trip's flags as a fanned deck, the first country in front: one flag
/// alone; two offset 9, 8; three at 6 pt steps; four or more the first three
/// and a cobalt "+N". Decorative: the row's names line says the countries.
struct FlagDeck: View {
    let codes: [String]

    /// The lead column, and the gap from it to the text column.
    nonisolated static let width: CGFloat = 48
    nonisolated static let gap: CGFloat = 12

    var body: some View {
        // No country yet (an Upcoming leg not geocoded): one neutral flag
        // keeps the text column where every other row has it.
        let shown: [String?] = codes.isEmpty ? [nil] : codes.prefix(3).map { $0 }
        let offsets = Self.offsets(count: shown.count)
        let extra = codes.count - min(codes.count, 3)
        let height = FlagView.Size.large.dimensions.height + offsets[offsets.count - 1].y
        ZStack(alignment: .topLeading) {
            // Back to front, so the first country sits on top.
            ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { index, code in
                FlagView(iso: code, size: .large)
                    .shadow(color: index == 0 && shown.count > 1 ? .black.opacity(0.35) : .clear, radius: 1.5, y: 1)
                    .padding(.leading, offsets[index].x)
                    .padding(.top, offsets[index].y)
            }
            if extra > 0 {
                Text(verbatim: "+" + extra.formatted(.number.grouping(.never)))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(minWidth: 22, minHeight: 16, maxHeight: 16)
                    .background(Color(.tertiarySystemGroupedBackground), in: .capsule)
                    // A ring of the card round the pill lifts it off the flags.
                    .background(AppTheme.card, in: Capsule().inset(by: -1.5))
                    .padding(.leading, 28)
                    .padding(.top, height - 8)
            }
        }
        .frame(width: Self.width, height: height + (extra > 0 ? 8 : 0), alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// Each shown flag's offset, front first.
    static func offsets(count: Int) -> [CGPoint] {
        switch count {
        case ...1: [.zero]
        case 2: [.zero, CGPoint(x: 9, y: 8)]
        default: [.zero, CGPoint(x: 6, y: 6), CGPoint(x: 12, y: 12)]
        }
    }
}

/// One colour of a row's wash, with its dark-mode strength (light draws it
/// at `FlagWash.lightScale`).
nonisolated struct WashTone: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let clear = WashTone(red: 0, green: 0, blue: 0, alpha: 0)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// The even blend of two tones, weighted by strength, so a colour
    /// meeting nothing fades to half its strength rather than turning grey.
    /// The hue comes from a mix in linear light; saturation and brightness
    /// are the two tones' own, weighted the same way, so red meeting blue
    /// reads as a clear violet, never a muddy grey.
    func blended(with other: WashTone) -> WashTone {
        let total = alpha + other.alpha
        guard total > 0 else { return .clear }
        let w = alpha / total, v = other.alpha / total
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encoded(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let mix = (encoded(linear(red) * w + linear(other.red) * v),
                   encoded(linear(green) * w + linear(other.green) * v),
                   encoded(linear(blue) * w + linear(other.blue) * v))
        let hue = Self.hsv(mix).hue
        let saturation = hsv.saturation * w + other.hsv.saturation * v
        let value = hsv.value * w + other.hsv.value * v
        let rgb = Self.rgb(hue: hue, saturation: saturation, value: value)
        return WashTone(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: total / 2)
    }

    private var hsv: (hue: Double, saturation: Double, value: Double) { Self.hsv((red, green, blue)) }

    private static func hsv(_ c: (Double, Double, Double)) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(c.0, c.1, c.2), minC = min(c.0, c.1, c.2), delta = maxC - minC
        guard delta > 0 else { return (0, 0, maxC) }
        var hue: Double
        if maxC == c.0 {
            hue = (c.1 - c.2) / delta
        } else if maxC == c.1 {
            hue = (c.2 - c.0) / delta + 2
        } else {
            hue = (c.0 - c.1) / delta + 4
        }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return (hue, maxC > 0 ? delta / maxC : 0, maxC)
    }

    private static func rgb(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
        let h = hue * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f))
        switch sector {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    func color(strength scale: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha * scale)
    }
}

/// A row's wash from top to bottom: its three bands at a quarter, half and
/// three quarters of its height, each edge the blend with the neighbouring
/// row's, so the wash flows across a card's separators. The first and last
/// rows of a card keep their own colour at the card's edge.
/// Built with the section's rows in the list's cache, never in a row body.
nonisolated struct RowWash: Equatable, Sendable {
    var top: WashTone
    var upper: WashTone
    var middle: WashTone
    var lower: WashTone
    var bottom: WashTone

    /// One section's washes, in row order, from each row's country codes.
    static func section(_ codeLists: [[String]]) -> [RowWash] {
        let bands = codeLists.map(FlagWash.bands(for:))
        return bands.indices.map { index in
            let own = bands[index]
            let top = index > 0 ? bands[index - 1][2].blended(with: own[0]) : own[0]
            let bottom = index < bands.count - 1 ? own[2].blended(with: bands[index + 1][0]) : own[2]
            return RowWash(top: top, upper: own[0], middle: own[1], lower: own[2], bottom: bottom)
        }
    }

    /// Washes keyed by row, for one section of rows.
    static func section<Row, Key: Hashable>(
        _ rows: [Row], key: (Row) -> Key, codes: (Row) -> [String]
    ) -> [Key: RowWash] {
        let washes = section(rows.map(codes))
        var result: [Key: RowWash] = [:]
        result.reserveCapacity(rows.count)
        for (row, wash) in zip(rows, washes) { result[key(row)] = wash }
        return result
    }

    var isClear: Bool {
        top.alpha == 0 && upper.alpha == 0 && middle.alpha == 0 && lower.alpha == 0 && bottom.alpha == 0
    }
}

/// The wash of a trip's countries' colours from its row's leading edge:
/// full strength under the flags, easing out across `reach` so the text
/// column carries a tint without losing contrast. 0.17 in dark, 1.2 times that
/// in light; the darkest navies lifted, at most 0.24 before that. Vertically it runs
/// through the row's `RowWash`: a flag's three bands top to bottom
/// (Norway red, navy, red; Germany clear, red, gold), so it meets its
/// neighbours' without an edge. The colours are a table lookup
/// (`FlagColors`, generated offline from the flag art).
struct FlagWash: View {
    let wash: RowWash

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !wash.isClear {
            let scale = colorScheme == .dark ? 1.0 : Self.lightScale
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: wash.top.color(strength: scale), location: 0),
                        .init(color: wash.upper.color(strength: scale), location: 0.25),
                        .init(color: wash.middle.color(strength: scale), location: 0.5),
                        .init(color: wash.lower.color(strength: scale), location: 0.75),
                        .init(color: wash.bottom.color(strength: scale), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: Self.reach)
                .mask(LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.85), location: 0.35),
                        .init(color: .black.opacity(0.4), location: 0.7),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// How far the wash reaches into the row.
    static let reach: CGFloat = 176
    /// Dark-mode strength of a band, and the cap a lifted dark colour stays under.
    nonisolated static let strength = 0.17
    nonisolated static let maxStrength = 0.24
    /// Light mode draws the same wash at this share of its strength.
    static let lightScale = 1.2

    /// A row's three bands, top to bottom: one country's own bands; two
    /// countries' lead colours above and below, meeting in the middle; three
    /// or more, the first three's leads. A clear band (white, black or grey
    /// in the flag) keeps its row's nearest colour at no strength, so the
    /// gradient fades into it rather than through black.
    nonisolated static func bands(for codes: [String]) -> [WashTone] {
        let entries = codes.prefix(3).compactMap { FlagColors.wash[$0.uppercased()] }
        guard let first = entries.first else { return [.clear, .clear, .clear] }
        let hexes: [UInt32?]
        switch entries.count {
        case 1: hexes = [first.top, first.middle, first.bottom]
        case 2: hexes = [first.lead, nil, entries[1].lead]
        default: hexes = entries.map(\.lead)
        }
        var tones = hexes.map { $0.map { WashTone(hex: $0, alpha: alpha($0, base: strength)) } }
        if entries.count == 2, let upper = tones[0], let lower = tones[2] {
            tones[1] = upper.blended(with: lower)
        }
        return tones.indices.map { index in
            if let tone = tones[index] { return tone }
            let nearest = [index - 1, index + 1, index - 2, index + 2]
                .lazy.compactMap { tones.indices.contains($0) ? tones[$0] : nil }.first
            guard var faded = nearest else { return .clear }
            faded.alpha = 0
            return faded
        }
    }

    /// The design's alpha: dark colours (luma under 0.12) lifted by 1.375,
    /// at most `maxStrength`.
    nonisolated static func alpha(_ hex: UInt32, base: Double) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return min(maxStrength, base * (luma < 0.12 ? 1.375 : 1))
    }
}

/// A trip row's card: the card fill and its flag wash. An ongoing trip's
/// adds the saffron rim, in the exact shape the list clips its cards to, so
/// the rim keeps its width all the way round the corners.
struct TripRowBackground: View {
    let wash: RowWash?
    var isActive = false

    var body: some View {
        if isActive {
            let shape = RoundedRectangle(cornerRadius: AppTheme.listCardRadius, style: .circular)
            shape
                .fill(AppTheme.card)
                .overlay { wash.map { FlagWash(wash: $0).clipShape(shape) } }
                .overlay { shape.strokeBorder(AppTheme.saffronEdge, lineWidth: 1) }
        } else {
            AppTheme.card
                .overlay { wash.map { FlagWash(wash: $0) } }
        }
    }
}

/// "12 to 20 Sep · 9 days" as one unbreakable piece, then a cobalt pin and
/// "4 places" as another: on one line when both fit, the places on the next
/// line when not. Where even the dates and length overflow, they stack too.
/// Never a stray "·".
struct TripMetaLine: View {
    let dates: String
    let days: String?
    var places: Int = 0

    var body: some View {
        WrappingPair(spacing: 10, lineSpacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(dates)
                    if let days {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(days)
                    }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(dates)
                    if let days { Text(days) }
                }
            }
            if places > 0 {
                HStack(spacing: 3) {
                    MapPinGlyph()
                    Text(TripDisplayText.places(places))
                }
                .fixedSize()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The design's outlined map pin, in cobalt, sized with the text.
private struct MapPinGlyph: View {
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 13

    var body: some View {
        MapPinShape()
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2.2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A teardrop pin with a hole, drawn on a 24 pt grid.
nonisolated private struct MapPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(12, 21))
        path.addCurve(to: p(5.5, 9.8), control1: p(12, 21), control2: p(5.5, 14.8))
        path.addArc(center: p(12, 9.8), radius: 6.5 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: p(12, 21), control1: p(18.5, 14.8), control2: p(12, 21))
        path.closeSubpath()
        path.addEllipse(in: CGRect(origin: p(9.7, 7.5), size: CGSize(width: 4.6 * s, height: 4.6 * s)))
        return path
    }
}

/// Two pieces side by side, vertically centred, when they fit the width;
/// otherwise the second starts the next line.
private struct WrappingPair: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(width: proposal.width, subviews: subviews)
        guard sizes.count > 1 else { return sizes.first ?? .zero }
        if fitsOneLine(sizes, width: proposal.width) {
            return CGSize(width: sizes[0].width + spacing + sizes[1].width, height: max(sizes[0].height, sizes[1].height))
        }
        return CGSize(width: max(sizes[0].width, sizes[1].width), height: sizes[0].height + lineSpacing + sizes[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(width: bounds.width, subviews: subviews)
        guard sizes.count > 1 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        if fitsOneLine(sizes, width: bounds.width) {
            let line = max(sizes[0].height, sizes[1].height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (line - sizes[0].height) / 2),
                              proposal: ProposedViewSize(sizes[0]))
            subviews[1].place(at: CGPoint(x: bounds.minX + sizes[0].width + spacing, y: bounds.minY + (line - sizes[1].height) / 2),
                              proposal: ProposedViewSize(sizes[1]))
        } else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(sizes[0]))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes[0].height + lineSpacing),
                              proposal: ProposedViewSize(sizes[1]))
        }
    }

    private func measure(width: CGFloat?, subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    private func fitsOneLine(_ sizes: [CGSize], width: CGFloat?) -> Bool {
        sizes[0].width + spacing + sizes[1].width <= (width ?? .infinity) + 0.5
    }
}

// MARK: - Row Text

/// The trips list's row phrases, shared by the trip and Upcoming rows.
enum TripRowText {
    /// Every country by name in visit order as a localized list ("Belgium,
    /// Netherlands and Luxembourg"); beyond four, the first two and a count
    /// ("Slovenia, Croatia and 4 more"). Memoized per language and codes, so
    /// a row redraw never formats the list again.
    static func countryLine(_ codes: [String]) -> String? {
        guard !codes.isEmpty else { return nil }
        let key = AppLanguagePreference.currentTag() + "|" + Locale.current.identifier + "|" + codes.joined(separator: ",")
        if let cached = countryLineCache[key] { return cached }
        let line: String
        if codes.count > 4 {
            let locale = AppLanguagePreference.currentLocale()
            let first = localizedCountryName(iso: codes[0], fallback: codes[0], locale: locale) ?? codes[0]
            let second = localizedCountryName(iso: codes[1], fallback: codes[1], locale: locale) ?? codes[1]
            let more = codes.count - 2
            line = String(localized: "trips.row.countries-more.other", defaultValue: "\(first), \(second) and \(more, format: .number.grouping(.never)) more", comment: "Trips list row line naming a trip's first two countries and counting the rest (always 3 or more), e.g. Slovenia, Croatia and 4 more.")
        } else {
            line = TripDisplayText.countryNames(codes) ?? ""
        }
        if countryLineCache.count > 512 { countryLineCache.removeAll() }
        countryLineCache[key] = line
        return line
    }

    private static var countryLineCache: [String: String] = [:]

    /// "9 days": a completed trip's length on its row.
    static func days(_ days: Int) -> String {
        days == 1
            ? String(localized: "trips.duration-days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Completed trip row duration of one day.")
            : String(localized: "trips.duration-days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Completed trip row duration of multiple days.")
    }
}

// MARK: - Preview

#Preview("Trip rows, 1 to 6 countries") {
    let rows: [(String, [String], String, Int, Int)] = [
        ("Vienna & Salzburg", ["AT"], "15 to 19 Jan", 5, 2),
        ("Lisbon & Seville", ["PT", "ES"], "12 to 20 Sep 2024", 9, 4),
        ("Benelux", ["BE", "NL", "LU"], "8 to 13 May 2024", 6, 4),
        ("Central Europe by Train", ["AT", "CZ", "SK", "HU"], "2 to 14 Sep", 13, 7),
        ("Balkans Road Trip: Ljubljana to Skopje", ["SI", "HR", "BA", "ME", "AL", "MK"], "8 to 21 Aug", 14, 11),
    ]
    NavigationStack {
        List {
            Section {
                let washes = RowWash.section(rows.map(\.1))
                ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                    NavigationLink {
                        Text(row.0)
                    } label: {
                        TripRowContent(title: row.0, codes: row.1, dates: row.2, days: TripRowText.days(row.3), places: row.4)
                    }
                    .listRowInsets(TripsListView.tripRowInsets)
                    .listRowBackground(TripRowBackground(wash: washes[index]))
                }
            } header: {
                TripsListView.yearHeader(2026, totals: .init(trips: 3, days: 32))
            }
        }
        .headerProminence(.increased)
        .navigationTitle("Trips")
    }
}

