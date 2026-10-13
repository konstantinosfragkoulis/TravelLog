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
            (String(localized: "passport.tile.countries", defaultValue: "Countries", comment: "Passport statistic tile label for countries."), countries.formatted(.number.grouping(.never))),
            (String(localized: "passport.tile.cities", defaultValue: "Cities", comment: "Passport statistic tile label for cities."), cities.formatted(.number.grouping(.never))),
            (String(localized: "passport.tile.trips", defaultValue: "Trips", comment: "Passport statistic tile label for trips."), trips.formatted(.number.grouping(.never))),
            (String(localized: "passport.tile.days-away", defaultValue: "Days Away", comment: "Passport statistic tile label for days away."), daysAbroad.formatted(.number.grouping(.never))),
            (String(localized: "passport.tile.hexes", defaultValue: "Hexes", comment: "Passport statistic tile label for explored hexes."), hexes.formatted(.number.grouping(.never)))
        ]
        if flights > 0 {
            result.append((String(localized: "passport.tile.flights", defaultValue: "Flights", comment: "Passport statistic tile label for flights."), flights.formatted(.number.grouping(.never))))
        } else {
            result.append((String(localized: "passport.tile.explored", defaultValue: "Explored", comment: "Passport statistic tile label for explored area."), areaText))
        }
        return result
    }

    var areaText: String {
        let area = exploredAreaKm2
        if area >= 10_000 {
            let thousands = Int((area / 1000).rounded())
            return String(localized: "passport.area.thousands", defaultValue: "\(thousands, format: .number.grouping(.never))k km²", comment: "Passport explored area in thousands of square kilometres.")
        }
        let rounded = Int(area.rounded())
        return String(localized: "passport.area", defaultValue: "\(rounded, format: .number.grouping(.never)) km²", comment: "Passport explored area in square kilometres.")
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

/// The "Passport" — a travel-document-styled lifetime stats card, the hero
/// of the Stats page. Content layer: rich gradient, no glass (per the
/// Liquid Glass guidance, glass is for chrome, not content). Shareable as
/// a square image via the same render pipeline Wrapped uses.
struct PassportCardView: View {

    let data: PassportData
    /// Whether `data` comes from complete aggregates (see `isShareable`).
    let canShare: Bool

    @State private var showDetail = false

    private static let gold = Color(red: 0.85, green: 0.72, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tileGrid
            footer
        }
        .padding(20)
        .background(passportBackground, in: .rect(cornerRadius: 20))
        // Tap anywhere on the card (the inner ShareLink wins its own taps)
        // to open the full passport. `contentShape` covers the gradient.
        .contentShape(.rect(cornerRadius: 20))
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            PassportDetailView(data: data, canShare: canShare)
        }
        .accessibilityHint("Opens your full passport with detailed lifetime statistics")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PASSPORT")
                    .font(.caption.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(Self.gold)
                Text("A lifetime of travel")
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.title2)
                    .foregroundStyle(Self.gold.opacity(0.9))

                if data.isShareable(aggregatesComplete: canShare) {
                    ShareLink(
                        item: PassportShare(data: data),
                        preview: SharePreview(String(localized: "passport.share-preview", defaultValue: "TravelLog Passport", comment: "Share preview title for the TravelLog Passport image; keep TravelLog verbatim."))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("Share your passport")
                }
            }
        }
    }

    private var tileGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 14) {
            ForEach(data.tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.value)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(tile.label.uppercased(with: AppLanguagePreference.currentLocale()))
                        .font(.caption2.weight(.medium))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if let year = data.sinceYear {
                Text("MEMBER SINCE \(String(year))")
            }
            if let km = data.furthestKm, km > 0, let place = data.furthestPlace {
                if data.sinceYear != nil { Text(verbatim: "·") }
                Text("FARTHEST: \(place.uppercased(with: AppLanguagePreference.currentLocale())) \(UnitsFormatter.formatDistance(kilometers: km))")
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Self.gold.opacity(0.6))
        }
        .font(.caption2.weight(.medium))
        .tracking(1)
        .foregroundStyle(Self.gold.opacity(0.8))
    }

    private var passportBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.15, blue: 0.34),
                Color(red: 0.04, green: 0.07, blue: 0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Share render (1080×1080)

/// Fixed-size export layout — rendered by `WrappedRenderer` (forced dark,
/// opaque), so it must not depend on the live environment or use glass.
private struct ShareablePassportCard: View {

    let data: PassportData

    private static let gold = Color(red: 0.85, green: 0.72, blue: 0.42)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.15, blue: 0.34),
                    Color(red: 0.04, green: 0.07, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 48) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PASSPORT")
                            .font(.system(size: 40, weight: .semibold))
                            .tracking(16)
                            .foregroundStyle(Self.gold)
                        Text("A lifetime of travel")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "globe.europe.africa.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Self.gold.opacity(0.9))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 56) {
                    ForEach(data.tiles, id: \.label) { tile in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tile.value)
                                .font(.system(size: 88, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(tile.label.uppercased(with: AppLanguagePreference.currentLocale()))
                                .font(.system(size: 26, weight: .medium))
                                .tracking(4)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                Spacer()

                HStack {
                    if let year = data.sinceYear {
                        Text("MEMBER SINCE \(String(year))")
                            .font(.system(size: 26, weight: .medium))
                            .tracking(4)
                            .foregroundStyle(Self.gold.opacity(0.85))
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "airplane")
                        Text("TravelLog")
                    }
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(80)
        }
    }
}


// MARK: - Detail Sheet

/// The expanded passport — a bottom sheet in the same travel-document
/// language as the card, organized like a passport's data pages: TOTALS
/// (tile grid), RECORDS (field rows), and THIS YEAR. Sections render only
/// when their data exists.
struct PassportDetailView: View {

    let data: PassportData
    /// Forwarded from the card; an open sheet follows revocation too.
    let canShare: Bool

    private static let gold = Color(red: 0.85, green: 0.72, blue: 0.42)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                    .padding(.top, 24)

                section(String(localized: "passport.section.totals", defaultValue: "Totals", comment: "Passport detail section title for totals.")) {
                    // Top-aligned, so a row's numbers share a line when one label wraps.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3), spacing: 18) {
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
                    Text("MEMBER SINCE \(String(year))")
                        .font(.caption.weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(Self.gold.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.15, blue: 0.34),
                    Color(red: 0.04, green: 0.07, blue: 0.18)
                ],
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
                    .font(.title3.weight(.semibold))
                    .tracking(6)
                    .foregroundStyle(Self.gold)
                Text("A lifetime of travel")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 12)
            Spacer()
            HStack(spacing: 16) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.title)
                    .foregroundStyle(Self.gold.opacity(0.9))
                if data.isShareable(aggregatesComplete: canShare) {
                    ShareLink(
                        item: PassportShare(data: data),
                        preview: SharePreview(String(localized: "passport.share-preview", defaultValue: "TravelLog Passport", comment: "Share preview title for the TravelLog Passport image; keep TravelLog verbatim."))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("Share your passport")
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased(with: AppLanguagePreference.currentLocale()))
                .font(.caption.weight(.semibold))
                .tracking(3)
                .foregroundStyle(Self.gold)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label.uppercased(with: AppLanguagePreference.currentLocale()))
                .font(.caption2.weight(.medium))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased(with: AppLanguagePreference.currentLocale()))
                    .font(.caption2.weight(.medium))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 10)
            Divider().overlay(.white.opacity(0.1))
        }
    }
}
