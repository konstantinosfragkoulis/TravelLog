//
//  PassportCard.swift
//  TravelLog
//

import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Data

/// The lifetime ledger shown on the Passport card. Pure value type — the
/// Stats view assembles it from data it already queries; the share render
/// and tests consume it without touching models. Codable because it rides
/// in the persisted `StatsSnapshotStore` snapshot.
nonisolated struct PassportData: Equatable, Sendable, Codable {
    var countries = 0
    var cities = 0
    var trips = 0
    /// Travel days, plus the days lived at temporary homes when one exists.
    var daysAbroad = 0
    /// Days lived at temporary homes that no trip covers; nil when there are
    /// none. Optional so older cached payloads remain decodable.
    var daysAtTemporaryHomes: Int?
    /// Mean completed-trip duration, independent of unioned travel dates.
    /// Optional so older cached payloads remain decodable.
    var averageTripDays: Double?
    var hexes = 0
    var flights = 0
    var furthestKm: Double?
    var furthestPlace: String?
    var sinceYear: Int?

    // Detail-sheet extras — the card shows the core six; the expandable
    // detail (`PassportDetailView`) shows whichever of these exist.
    var totalStays = 0
    var totalPings = 0
    var tripsThisYear = 0
    var newHexesThisYear = 0
    var longestTripName: String?
    var longestTripDays = 0
    var mostVisitedPlace: String?
    var mostVisitedTripCount = 0
    var hottestTempC: Double?
    var hottestPlace: String?
    var coldestTempC: Double?
    var coldestPlace: String?

    /// H3 res-6 cells average ~36.13 km² — turns the abstract hex count
    /// into a tangible "area of the world you've stood in".
    var exploredAreaKm2: Double { Double(hexes) * 36.13 }

    /// The six tiles shown on the card, in display order. Flights only
    /// earn a slot when transit inference has actually detected some;
    /// otherwise the explored area takes the sixth tile.
    var tiles: [(label: String, value: String)] {
        var result: [(String, String)] = [
            (String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries."), StatsText.grouped(countries)),
            (String(localized: "passport.tile.cities", defaultValue: "Cities", comment: "Passport statistic tile label for cities."), StatsText.grouped(cities)),
            (String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), StatsText.grouped(trips)),
            (String(localized: "passport.tile.days-away", defaultValue: "Days Away", comment: "Passport statistic tile label for days away."), StatsText.grouped(daysAbroad)),
            (String(localized: "passport.tile.hexes", defaultValue: "Hexes", comment: "Passport statistic tile label for explored hexes."), StatsText.grouped(hexes))
        ]
        if flights > 0 {
            result.append((String(localized: "passport.tile.flights", defaultValue: "Flights", comment: "Passport statistic tile label for flights."), StatsText.grouped(flights)))
        } else {
            result.append((String(localized: "passport.tile.explored", defaultValue: "Explored", comment: "Passport statistic tile label for explored area."), areaText))
        }
        return result
    }

    var areaText: String {
        // Stored and estimated in km²; imperial locales read square miles.
        if UnitsFormatter.isImperial {
            let area = exploredAreaKm2 * 0.386102
            if area >= 10_000 {
                let thousands = Int((area / 1000).rounded())
                return String(localized: "passport.area.thousands.square-miles", defaultValue: "\(thousands, format: .number)k mi²", comment: "Passport explored area in thousands of square miles.")
            }
            let rounded = Int(area.rounded())
            return String(localized: "passport.area.square-miles", defaultValue: "\(rounded, format: .number) mi²", comment: "Passport explored area in square miles.")
        }
        let area = exploredAreaKm2
        if area >= 10_000 {
            let thousands = Int((area / 1000).rounded())
            return String(localized: "passport.area.thousands", defaultValue: "\(thousands, format: .number)k km²", comment: "Passport explored area in thousands of square kilometres.")
        }
        let rounded = Int(area.rounded())
        return String(localized: "passport.area", defaultValue: "\(rounded, format: .number) km²", comment: "Passport explored area in square kilometres.")
    }

    /// Only a complete aggregate for the current deletion generation can be
    /// shared. A cold page, a degraded read or revoked content keeps the
    /// share button hidden, even when remembered countries alone make the
    /// card nonzero.
    func isShareable(aggregatesComplete: Bool) -> Bool {
        aggregatesComplete && self != PassportData()
    }
}

/// Deferred PNG payload. The square card is rendered only when the share
/// sheet requests its representation; a failed render throws so a later
/// share attempt retries.
struct PassportShare: Transferable {
    let data: PassportData

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            let rendered = await MainActor.run {
                WrappedRenderer.renderImage(
                    content: { ShareablePassportCard(data: payload.data) },
                    size: CGSize(width: 1080, height: 1080),
                    scale: 1.0
                )
            }
            guard let data = rendered?.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        .suggestedFileName { _ in "TravelLog-Passport.png" }
    }
}

// MARK: - Card

/// Passport wording shared by the card, the expanded passport and the share
/// image. Labels stay in sentence case; only the "PASSPORT" eyebrow, which
/// every language writes in capitals, wears the expanded small capitals.
enum PassportText {
    static func memberSince(_ year: Int) -> String {
        String(localized: "passport.member-since", defaultValue: "Member since \(String(year))", comment: "Passport footer: the year the user started recording travel, such as Member since 2019. Sentence case.")
    }

    static func farthest(place: String, km: Double) -> String {
        String(localized: "passport.farthest", defaultValue: "Farthest: \(place), \(UnitsFormatter.formatDistance(kilometers: km))", comment: "Passport footer: the place farthest from home and its distance, such as Farthest: Lisbon, 2,900 km. Sentence case.")
    }

    /// "27 countries", for the expanded Passport's summary line.
    static func countries(_ count: Int) -> String {
        count == 1
            ? String(localized: "passport.summary.countries.one", defaultValue: "\(count, format: .number) country", comment: "Expanded Passport summary: the number of countries visited, for one.")
            : String(localized: "passport.summary.countries.other", defaultValue: "\(count, format: .number) countries", comment: "Expanded Passport summary: the number of countries visited, for zero or several.")
    }

    /// "4 continents", for the expanded Passport's summary line.
    static func continents(_ count: Int) -> String {
        count == 1
            ? String(localized: "passport.summary.continents.one", defaultValue: "\(count, format: .number) continent", comment: "Expanded Passport summary: the number of continents visited, for one.")
            : String(localized: "passport.summary.continents.other", defaultValue: "\(count, format: .number) continents", comment: "Expanded Passport summary: the number of continents visited, for zero or several.")
    }

    /// "9 stamps" under a stamp page's year.
    static func stamps(_ count: Int) -> String {
        count == 1
            ? String(localized: "passport.page.stamps.one", defaultValue: "\(count, format: .number) stamp", comment: "Passport stamp page caption: the year's number of stamps (countries entered that year), for one.")
            : String(localized: "passport.page.stamps.other", defaultValue: "\(count, format: .number) stamps", comment: "Passport stamp page caption: the year's number of stamps (countries entered that year), for zero or several.")
    }

    /// "2 first-ever" beside a stamp page's stamp count.
    static func firstEver(_ count: Int) -> String {
        String(localized: "passport.page.first-ever", defaultValue: "\(count, format: .number) first-ever", comment: "Passport stamp page caption: how many of the year's countries were recorded for the first time that year, such as 2 first-ever.")
    }

    /// "first in 2019" in an expanded Passport country row.
    static func firstIn(_ year: Int) -> String {
        String(localized: "passport.country.first-in", defaultValue: "first in \(String(year))", comment: "Expanded Passport country row caption: the year the country was first recorded, such as first in 2019. Lowercase; follows a trip count and a middle dot.")
    }

    static var continentsLabel: String {
        String(localized: "passport.tile.continents", defaultValue: "Continents", comment: "Passport statistic label for the number of continents visited.")
    }

    /// The cover's four figures: countries, continents, days away, then
    /// flights, or trips while no flight has been detected.
    static func coverFigures(_ data: PassportData, continents: Int) -> [(label: String, value: String)] {
        let last: (String, String) = data.flights > 0
            ? (String(localized: "passport.tile.flights", defaultValue: "Flights", comment: "Passport statistic tile label for flights."), StatsText.grouped(data.flights))
            : (String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), StatsText.grouped(data.trips))
        return [
            (String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries."), StatsText.grouped(data.countries)),
            (continentsLabel, StatsText.grouped(continents)),
            (String(localized: "passport.tile.days-away", defaultValue: "Days Away", comment: "Passport statistic tile label for days away."), StatsText.grouped(data.daysAbroad)),
            last,
        ]
    }
}

/// Continents for the Passport: the UN M49 continents, with the Americas
/// split into North (Northern and Central America, the Caribbean) and South,
/// Antarctica on its own, and Cyprus in Europe as its stamp shows it.
nonisolated enum PassportContinents {
    static func continent(of iso: String) -> String? {
        let code = iso.uppercased()
        guard code.utf8.count == 2 else { return nil }
        if code == "AQ" { return "AQ" }
        if code == "CY" { return "150" }
        let region = Locale.Region(code)
        guard let continent = region.continent?.identifier else { return nil }
        if continent == "019" {
            return region.subcontinent?.identifier == "005" ? "SA" : "NA"
        }
        return continent
    }

    static func count(_ codes: Set<String>) -> Int {
        Set(codes.compactMap(continent(of:))).count
    }
}

/// Everything the expanded Passport needs beyond the lifetime ledger, as
/// values the Stats page already holds.
struct PassportBook: Equatable {
    var stampYears: [StatsAggregator.StampYear] = []
    var firstRecordedByYear: [Int: Set<String>] = [:]
    var countryStats: [CountryStat] = []
    /// Tracked country codes (`uniqueCountries`).
    var trackedCodes: Set<String> = []
}

/// The "Passport": the lifetime stats card, the hero of the Stats page.
/// Content layer: the cobalt field with a cobalt lift in the top trailing
/// corner, no glass, and fine foil details: the crest, the eyebrow, a rule
/// and a faint hex lattice. Four figures and the member-since footer; a tap
/// opens the expanded Passport. Shareable as a square image via the same
/// render pipeline Wrapped uses.
struct PassportCardView: View {

    let data: PassportData
    /// Whether `data` comes from complete aggregates (see `isShareable`).
    let canShare: Bool
    let continents: Int
    let book: PassportBook

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDetail = false
    /// The card is the zoom transition's source: the passport opens out of it.
    @Namespace private var zoom

    var body: some View {
        // A real Button, so VoiceOver finds the full passport: the whole card
        // is its label. The ShareLink cannot nest inside a button, so it sits
        // on top, exactly over the slot the header keeps free for it.
        Button {
            showDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                header
                PassportRule()
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                figures
                footer
                    .padding(.top, 13)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { PassportCover() }
            .contentShape(.rect(cornerRadius: AppTheme.cardRadius))
            .matchedTransitionSource(id: PassportDetailView.zoomID, in: zoom) { source in
                source.clipShape(.rect(cornerRadius: AppTheme.cardRadius, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your full passport with detailed lifetime statistics")
        .overlay(alignment: .topTrailing) {
            if isShareable {
                shareSlot(live: true)
                    .padding(.top, 18)
                    .padding(.trailing, 20)
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            PassportDetailView(data: data, canShare: canShare, continents: continents, book: book)
                .navigationTransition(.zoom(sourceID: PassportDetailView.zoomID, in: zoom))
        }
    }

    private var isShareable: Bool { data.isShareable(aggregatesComplete: canShare) }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            PassportCrest(side: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("PASSPORT")
                    .font(.caption2.weight(.bold).width(.expanded))
                    .tracking(2.4)
                    .foregroundStyle(AppTheme.foil)
                Text("A lifetime of travel")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.onField)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            shareSlot(live: false)
        }
    }

    /// The share slot. Inside the button it is a hidden placeholder; the
    /// overlay draws the live ShareLink, so both land on the same spot.
    @ViewBuilder
    private func shareSlot(live: Bool) -> some View {
        if isShareable {
            if live {
                ShareLink(
                    item: PassportShare(data: data),
                    preview: SharePreview(String(localized: "passport.share-preview", defaultValue: "TravelLog Passport", comment: "Share preview title for the TravelLog Passport image; keep TravelLog verbatim."))
                ) {
                    PassportShareIcon()
                }
                .accessibilityLabel("Share your passport")
            } else {
                PassportShareIcon()
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        let figures = PassportText.coverFigures(data, continents: continents)
        if dynamicTypeSize.isAccessibilitySize {
            // Two columns, so the figures keep their size.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 6, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                ForEach(figures, id: \.label) { figure($0) }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                // Four equal columns, as on the design's cover.
                ForEach(figures, id: \.label) { entry in
                    figure(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func figure(_ entry: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.value)
                .font(AppTheme.stat(.title))
                .foregroundStyle(AppTheme.onField)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(entry.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.onFieldSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 6) {
            if let year = data.sinceYear {
                Text(PassportText.memberSince(year))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.onFieldSecondary)
    }
}

/// The Passport cover: the cobalt field (top leading to bottom trailing),
/// a cobalt lift in the top trailing corner, the foil lattice there, a
/// hairline highlight along the top edge and a soft cobalt shadow.
struct PassportCover: View {
    var cornerRadius: CGFloat = AppTheme.cardRadius
    var latticeScale: CGFloat = 1
    var shadowed = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                stops: [
                    .init(color: AppTheme.field, location: 0),
                    .init(color: AppTheme.fieldMid, location: 0.46),
                    .init(color: AppTheme.fieldDeep, location: 1),
                ],
                startPoint: UnitPoint(x: 0.31, y: 0),
                endPoint: UnitPoint(x: 0.69, y: 1)
            )
            EllipticalGradient(
                colors: [AppTheme.coverGlow.opacity(0.9), AppTheme.coverGlow.opacity(0)],
                center: .topTrailing,
                startRadiusFraction: 0,
                endRadiusFraction: 0.68
            )
            PassportLattice(scale: latticeScale)
                .frame(width: 220 * latticeScale, height: 190 * latticeScale)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0),
                                       .init(color: .white.opacity(0), location: 0.12)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5)
        }
        .shadow(color: shadowed ? AppTheme.coverShadow : .clear, radius: 17, y: 10)
        .accessibilityHidden(true)
    }
}

/// The share glyph on its translucent disc, on the cobalt field.
private struct PassportShareIcon: View {
    var body: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppTheme.onField)
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.14), in: Circle())
    }
}

// MARK: - Foil

/// A pointy-topped hexagon filling the rect's height.
nonisolated private struct PassportHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / sqrt(3), rect.height / 2)
        return PassportLattice.hexagon(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius)
    }
}

/// The Passport's crest: a foil hexagon around a smaller one and a dot, on
/// a 24-point grid scaled to `side`.
struct PassportCrest: View {
    let side: CGFloat

    private static let foil = LinearGradient(
        stops: [
            .init(color: Color(UIColor(hex: 0xFBE6B2)), location: 0),
            .init(color: Color(UIColor(hex: 0xD9A748)), location: 0.55),
            .init(color: Color(UIColor(hex: 0xF3D28A)), location: 1),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        let unit = side / 24
        ZStack {
            PassportHexagon()
                .stroke(Self.foil, style: StrokeStyle(lineWidth: 1.2 * unit, lineJoin: .round))
                .frame(width: 20.4 * unit, height: 20.4 * unit)
            PassportHexagon()
                .stroke(Self.foil, style: StrokeStyle(lineWidth: 0.8 * unit, lineJoin: .round))
                .frame(width: 12.8 * unit, height: 12.8 * unit)
            Circle()
                .fill(Self.foil)
                .frame(width: 4.2 * unit, height: 4.2 * unit)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The fine foil rule under the Passport's title, fading out before the
/// trailing edge. `scale` sizes it for the share image.
private struct PassportRule: View {
    var scale: CGFloat = 1

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: AppTheme.foil.opacity(0.8), location: 0),
                .init(color: AppTheme.foil.opacity(0.3), location: 0.6),
                .init(color: AppTheme.foil.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 0.75 * scale)
        .padding(.trailing, 60 * scale)
        .accessibilityHidden(true)
    }
}

/// A faint foil hex lattice anchored in the top trailing corner of its
/// frame (220 by 190 points at scale 1), fading away from that corner. One
/// Canvas pass of about seventy thin strokes. `extent` is the rows and
/// columns it may draw; a larger scale needs more to fade out on its own.
struct PassportLattice: View {
    var scale: CGFloat = 1
    var extent = 10
    /// The stroke; 0.7 points times the scale by default.
    var lineWidth: CGFloat?

    var body: some View {
        Canvas { context, size in
            let radius = 9 * scale
            let step = radius * sqrt(3)
            let width = size.width
            let height = size.height
            for row in 0..<extent {
                for column in 0..<extent {
                    let x = width - CGFloat(column) * step - (row.isMultiple(of: 2) ? 0 : step / 2)
                    let y = CGFloat(row) * 1.5 * radius
                    let fade = max(0, 1 - (width - x) / (200 * scale)) * max(0, 1 - y / height)
                    guard fade >= 0.05 else { continue }
                    context.stroke(
                        Self.hexagon(center: CGPoint(x: x, y: y), radius: radius),
                        with: .color(AppTheme.foil.opacity(0.26 * fade)),
                        lineWidth: lineWidth ?? 0.7 * scale)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A pointy-topped hexagon around `center`.
    nonisolated static func hexagon(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = Double(corner) * .pi / 3 - .pi / 2
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Share render (1080×1080)

/// Fixed-size export layout, rendered by `WrappedRenderer` (opaque), so it
/// must not depend on the live environment or use glass. It pins the light
/// cobalt so the image matches Wrapped's shared poster in every appearance.
private struct ShareablePassportCard: View {

    let data: PassportData

    var body: some View {
        ZStack {
            PassportCover(cornerRadius: 0, latticeScale: 3, shadowed: false)

            VStack(alignment: .leading, spacing: 56) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        PassportCrest(side: 54)
                        Text("PASSPORT")
                            .font(.system(size: 32, weight: .bold).width(.expanded))
                            .tracking(7)
                            .foregroundStyle(AppTheme.foil)
                    }
                    Text("A lifetime of travel")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(AppTheme.onField)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    PassportRule(scale: 3)
                        .padding(.top, 26)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .leading), count: 2), spacing: 48) {
                    ForEach(Array(data.tiles.enumerated()), id: \.element.label) { index, tile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.value)
                                .font(.system(size: 88, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(index == 0 ? AppTheme.foil : AppTheme.onField)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(tile.label)
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AppTheme.onFieldSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline) {
                    if let year = data.sinceYear {
                        Text(PassportText.memberSince(year))
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(AppTheme.onFieldSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer()
                    Text("TravelLog")
                        .font(.system(size: 28, weight: .semibold).width(.expanded))
                        .foregroundStyle(AppTheme.onFieldSecondary)
                }
            }
            .padding(80)
        }
        .environment(\.colorScheme, .light)
    }
}
