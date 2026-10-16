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
private struct PassportShare: Transferable {
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

/// Passport wording shared by the card, the detail sheet and the share
/// image. Labels stay in sentence case; only the "PASSPORT" eyebrow, which
/// every language writes in capitals, wears the expanded small capitals.
enum PassportText {
    static func memberSince(_ year: Int) -> String {
        String(localized: "passport.member-since", defaultValue: "Member since \(String(year))", comment: "Passport footer: the year the user started recording travel, such as Member since 2019. Sentence case.")
    }

    static func farthest(place: String, km: Double) -> String {
        String(localized: "passport.farthest", defaultValue: "Farthest: \(place), \(UnitsFormatter.formatDistance(kilometers: km))", comment: "Passport footer: the place farthest from home and its distance, such as Farthest: Lisbon, 2,900 km. Sentence case.")
    }

    /// "Member since 2019 · Farthest: Lisbon, 2,900 km", either part alone,
    /// or nil without both.
    static func footer(_ data: PassportData) -> String? {
        var parts: [String] = []
        if let year = data.sinceYear { parts.append(memberSince(year)) }
        if let km = data.furthestKm, km > 0, let place = data.furthestPlace {
            parts.append(farthest(place: place, km: km))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The "Passport": the lifetime stats card, the hero of the Stats page.
/// Content layer: the cobalt field shared with Wrapped, no glass (per the
/// Liquid Glass guidance, glass is for chrome, not content). Shareable as
/// a square image via the same render pipeline Wrapped uses.
struct PassportCardView: View {

    let data: PassportData
    /// Whether `data` comes from complete aggregates (see `isShareable`).
    let canShare: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDetail = false

    var body: some View {
        // A real Button, so VoiceOver finds the full passport: the whole card
        // is its label. The ShareLink cannot nest inside a button, so it sits
        // on top, exactly over the slot the header keeps free for it.
        Button {
            showDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                header
                tileGrid
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(passportBackground, in: .rect(cornerRadius: AppTheme.cardRadius))
            .contentShape(.rect(cornerRadius: AppTheme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your full passport with detailed lifetime statistics")
        .overlay(alignment: .topTrailing) {
            if isShareable {
                shareSlot(live: true)
                    .padding(20)
            }
        }
        .sheet(isPresented: $showDetail) {
            PassportDetailView(data: data, canShare: canShare)
        }
    }

    private var isShareable: Bool { data.isShareable(aggregatesComplete: canShare) }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PASSPORT")
                    .font(AppTheme.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.onFieldSecondary)
                Text("A lifetime of travel")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.onField)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

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

    private var tileGrid: some View {
        // Two columns at accessibility sizes, so the figures keep their size.
        let count = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: count),
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(data.tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.value)
                        .font(AppTheme.stat(.title))
                        .foregroundStyle(AppTheme.onField)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(tile.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.onFieldSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let text = PassportText.footer(data) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.onFieldSecondary)
    }

    private var passportBackground: some ShapeStyle {
        LinearGradient(
            colors: [AppTheme.field, AppTheme.fieldDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// The share glyph on its translucent disc, on the cobalt field.
private struct PassportShareIcon: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36

    var body: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.body.weight(.semibold))
            .foregroundStyle(AppTheme.onField)
            .frame(width: side, height: side)
            .background(.white.opacity(0.16), in: Circle())
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
            LinearGradient(
                colors: [AppTheme.field, AppTheme.fieldDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 56) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("PASSPORT")
                        .font(.system(size: 32, weight: .semibold).width(.expanded))
                        .tracking(4)
                        .foregroundStyle(AppTheme.onFieldSecondary)
                    Text("A lifetime of travel")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(AppTheme.onField)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .leading), count: 2), spacing: 48) {
                    ForEach(data.tiles, id: \.label) { tile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.value)
                                .font(.system(size: 88, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.onField)
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

// MARK: - Detail Sheet

/// The expanded passport: a bottom sheet on the card's cobalt field,
/// organized like a passport's data pages: Totals (tile grid), Records
/// (field rows), and This Year. Sections render only when their data exists.
struct PassportDetailView: View {

    let data: PassportData
    /// Forwarded from the card; an open sheet follows revocation too.
    let canShare: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                    .padding(.top, 24)

                section(String(localized: "passport.section.totals", defaultValue: "Totals", comment: "Passport detail section title for totals.")) {
                    // Top-aligned, so a row's numbers share a line when one label wraps.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 18) {
                        tile(String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries."), data.countries.formatted())
                        tile(String(localized: "passport.tile.cities", defaultValue: "Cities", comment: "Passport statistic tile label for cities."), data.cities.formatted())
                        tile(String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), data.trips.formatted())
                        tile(String(localized: "passport.tile.days-away", defaultValue: "Days Away", comment: "Passport statistic tile label for days away."), data.daysAbroad.formatted())
                        tile(String(localized: "passport.tile.stays", defaultValue: "Stays", comment: "Passport statistic tile label for stays."), data.totalStays.formatted())
                        tile(String(localized: "passport.tile.pings", defaultValue: "Pings", comment: "Passport statistic tile label for location pings."), data.totalPings.formatted())
                        tile(String(localized: "passport.tile.hexes", defaultValue: "Hexes", comment: "Passport statistic tile label for explored hexes."), data.hexes.formatted())
                        tile(String(localized: "passport.tile.explored", defaultValue: "Explored", comment: "Passport statistic tile label for explored area."), data.areaText)
                        if data.flights > 0 {
                            tile(String(localized: "passport.tile.flights", defaultValue: "Flights", comment: "Passport statistic tile label for flights."), data.flights.formatted())
                        }
                        if let days = data.daysAtTemporaryHomes, days > 0 {
                            tile(String(localized: "passport.tile.days-at-temporary-homes", defaultValue: "Days at Temporary Homes", comment: "Passport statistic tile label for days lived at temporary homes, such as a semester abroad, outside of trips."), days.formatted())
                        }
                    }
                }

                if hasRecords {
                    section(String(localized: "passport.section.records", defaultValue: "Records", comment: "Passport detail section title for travel records.")) {
                        VStack(spacing: 0) {
                            if let name = data.longestTripName, data.longestTripDays > 0 {
                                fieldRow(String(localized: "passport.field.longest-trip", defaultValue: "Longest trip", comment: "Passport record label for the longest trip."), data.longestTripDays == 1
                                         ? String(localized: "passport.record.longest-trip.one", defaultValue: "\(name) · \(data.longestTripDays, format: .number.grouping(.never)) day", comment: "Passport longest-trip value lasting one day.")
                                         : String(localized: "passport.record.longest-trip.other", defaultValue: "\(name) · \(data.longestTripDays, format: .number.grouping(.never)) days", comment: "Passport longest-trip value lasting multiple days."))
                            }
                            if let km = data.furthestKm, km > 0, let place = data.furthestPlace {
                                fieldRow(String(localized: "passport.field.farthest-from-home", defaultValue: "Farthest from home", comment: "Passport record label for the farthest place from home."), "\(place) · \(UnitsFormatter.formatDistance(kilometers: km))")
                            }
                            if let place = data.mostVisitedPlace, data.mostVisitedTripCount > 0 {
                                fieldRow(String(localized: "passport.field.most-visited", defaultValue: "Most visited", comment: "Passport record label for the most visited place."), data.mostVisitedTripCount == 1
                                         ? String(localized: "passport.record.most-visited.one", defaultValue: "\(place) · \(data.mostVisitedTripCount, format: .number.grouping(.never)) trip", comment: "Passport most-visited-place value for one trip.")
                                         : String(localized: "passport.record.most-visited.other", defaultValue: "\(place) · \(data.mostVisitedTripCount, format: .number.grouping(.never)) trips", comment: "Passport most-visited-place value for multiple trips."))
                            }
                            if let temp = data.hottestTempC, let place = data.hottestPlace {
                                fieldRow(String(localized: "passport.field.hottest-stay", defaultValue: "Hottest stay", comment: "Passport record label for the hottest stay."), "\(UnitsFormatter.formatTemperatureCompact(temp)) · \(place)")
                            }
                            if let temp = data.coldestTempC, let place = data.coldestPlace {
                                fieldRow(String(localized: "passport.field.coldest-stay", defaultValue: "Coldest stay", comment: "Passport record label for the coldest stay."), "\(UnitsFormatter.formatTemperatureCompact(temp)) · \(place)")
                            }
                            // Apple Weather attribution: only when a
                            // temperature row is present.
                            if data.hottestTempC != nil || data.coldestTempC != nil {
                                WeatherAttributionFootnote()
                                    .padding(.top, 6)
                            }
                        }
                    }
                }

                if data.tripsThisYear > 0 || data.newHexesThisYear > 0 {
                    section(String(localized: "passport.section.this-year", defaultValue: "This Year", comment: "Passport detail section title for the current year.")) {
                        VStack(spacing: 0) {
                            if data.tripsThisYear > 0 {
                                fieldRow(String(localized: "passport.field.trips", defaultValue: "Trips", comment: "Passport current-year field label for trips."), data.tripsThisYear.formatted())
                            }
                            if data.newHexesThisYear > 0 {
                                fieldRow(String(localized: "passport.field.new-hexes", defaultValue: "New hexes", comment: "Passport current-year field label for newly explored hexes."), "+\(data.newHexesThisYear.formatted())")
                            }
                        }
                    }
                }

                if let year = data.sinceYear {
                    Text(PassportText.memberSince(year))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.onFieldSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [AppTheme.field, AppTheme.fieldDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var hasRecords: Bool {
        data.longestTripName != nil
            || (data.furthestKm ?? 0) > 0
            || data.mostVisitedPlace != nil
            || data.hottestTempC != nil
            || data.coldestTempC != nil
    }

    private var header: some View {
        HStack(alignment: .top) {
            // The title block rides slightly lower than the seal/share icons
            // so the text does not feel glued to the sheet top.
            VStack(alignment: .leading, spacing: 4) {
                Text("PASSPORT")
                    .font(AppTheme.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.onFieldSecondary)
                Text("A lifetime of travel")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.onField)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            Spacer()
            if data.isShareable(aggregatesComplete: canShare) {
                ShareLink(
                    item: PassportShare(data: data),
                    preview: SharePreview(String(localized: "passport.share-preview", defaultValue: "TravelLog Passport", comment: "Share preview title for the TravelLog Passport image; keep TravelLog verbatim."))
                ) {
                    PassportShareIcon()
                }
                .accessibilityLabel("Share your passport")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.onField)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.1), in: .rect(cornerRadius: AppTheme.cardRadius))
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AppTheme.stat(.title3))
                .foregroundStyle(AppTheme.onField)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.onFieldSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.onFieldSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.onField)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 10)
            Divider().overlay(.white.opacity(0.16))
        }
    }
}
