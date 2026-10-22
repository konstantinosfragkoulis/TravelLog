//
//  TripDetailView+Timeline.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import TipKit
import Photos
import SwiftData
import UIKit

extension TripDetailView {

    // MARK: - Timeline Section

    @ViewBuilder
    func timelineSection(_ orderedStays: [Stay], onShowOnMap: @escaping (PersistentIdentifier) -> Void) -> some View {
        let photosByStay = photoPresentation.assetsByStay
        let showsCountry = trip.countryCodeList.count > 1
        // The rows whose place is a station on the map; one at most selected.
        let stationIDs = Set(Self.mapStations(orderedStays).map(\.id))
        let selectedPlace = mapFocus?.selectedPlace
        // The gaps on the line, each drawn above its later stay: a question
        // to answer, or a quiet note once answered "No, one trip". None while editing.
        let gaps = isEditing ? [] : stopGaps
        let gapAbove = Dictionary(gaps.map { ($0.question.laterStayID, $0) }, uniquingKeysWith: { first, _ in first })
        let dashedBelow = Set(gaps.map(\.question.earlierStayID))
        let asksQuestions = gaps.contains { !$0.answered }
        // One view, so the caller's padding wraps the header, card and footnote together.
        VStack(alignment: .leading, spacing: 0) {
            TripsListView.sectionHeader(Text(String(
                localized: "trip-detail.stops.header",
                defaultValue: "Stops",
                comment: "Header of the trip page's line of stops, from the first place to the last.")), inList: false)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Lazy: an imported trip can carry 100+ stays, and each row owns a
            // context menu, a tip anchor and a thumbnail strip. Rows are realized
            // as they scroll into view; the enclosing ScrollView drives it even
            // through the outer eager VStack.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(orderedStays.enumerated()), id: \.element.persistentModelID) { index, stay in
                    let rowID = stay.persistentModelID
                    let isStation = stationIDs.contains(rowID)
                    let gap = gapAbove[stay.id]
                    VStack(spacing: 0) {
                        if let gap {
                            TripGapLineRow(
                                question: gap.question,
                                answered: gap.answered,
                                isBusy: isAnsweringGap,
                                onWentHome: { answerGapQuestionWentHome(gap.question) },
                                onOneTrip: { answerGapQuestionOneTrip(gap.question) })
                                .transition(.opacity)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    stopScroll.gapHeights[stay.id] = height
                                }
                        }
                        TimelineStayRow(
                            stay: stay,
                            stayPhotos: photosByStay[stay.id] ?? [],
                            isFirst: index == 0,
                            isLast: index == orderedStays.count - 1,
                            dashedAbove: gap != nil,
                            dashedBelow: dashedBelow.contains(stay.id),
                            showsCountry: showsCountry,
                            isEditing: isEditing,
                            isSelected: isStation && (selectedPlace == rowID || flashedStop == rowID),
                            highlight: flashedStop == rowID ? .flash : (pressedStop == rowID ? .pressed : nil),
                            onShowOnMap: isStation && !isEditing ? { onShowOnMap(rowID) } : nil,
                            onCategoryChange: { newCategory in
                                changeStayCategory(stay, to: newCategory)
                            },
                            onAutomaticCategory: {
                                resetStayToAutomatic(stay)
                            },
                            onPhotoTap: { asset in
                                // Scope viewer to JUST this stay's photos.
                                // Order matters: set scope BEFORE asset ID so the
                                // fullScreenCover body, which reads both, sees a
                                // consistent state on its first render.
                                photoViewerScopeStayID = stay.id
                                photoViewerAssetID = asset.localIdentifier
                            }
                        )
                        // A trip that asks "Did you go home?" already offers the split.
                        .popoverTip(index == 1 && !isEditing && !asksQuestions && !splitHintDismissed
                            ? SplitTripTip() : nil)
                        .contextMenu {
                            if index > 0 {
                                Button {
                                    stayToSplitAt = stay
                                } label: {
                                    Label("Split Trip Here", systemImage: "scissors")
                                }
                            }
                        }
                        // The map's callout scrolls the page to this row.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            stopScroll.heights[rowID] = height
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.pageSpace)).minY
            } action: { top in
                stopScroll.rowsTop = top
            }
            .padding(.horizontal, AppTheme.cardPadding)
            .padding(.vertical, 4)
            .appCard(padded: false)
            // A flashing first or last row keeps the card's corners.
            .clipShape(.rect(cornerRadius: AppTheme.cardRadius))

            if orderedStays.contains(where: { $0.weatherConditionRaw != nil }) {
                WeatherAttributionFootnote()
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    /// "Now its own trip": the later half the last "Yes" split off, as its
    /// Trips list row, opening its page.
    func splitOffSection(_ splitOff: Trip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TripsListView.sectionHeader(Text(String(
                localized: "trip-gap.split-off.header",
                defaultValue: "Now its own trip",
                comment: "Header under a trip's stops after the user answered Yes to the did-you-go-home question: the later part is now a separate trip.")), inList: false)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            NavigationLink {
                TripDetailView(trip: splitOff)
            } label: {
                HStack(spacing: 8) {
                    TripRow(trip: splitOff)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(TripsListView.tripRowInsets)
                .background(TripRowBackground(wash: RowWash.section([splitOff.countryCodeList]).first))
                .clipShape(.rect(cornerRadius: AppTheme.listCardRadius))
                .contentShape(.rect(cornerRadius: AppTheme.listCardRadius))
            }
            .buttonStyle(.plain)
        }
    }
}

/// How a stop reads on the line: a place left the same day it was reached
/// is a visit, on a smaller station.
enum TimelineStop {
    static func nights(_ stay: Stay) -> Int {
        TripDisplayText.nights(
            from: stay.startTime, to: stay.endTime,
            timeZone: StayTimeZone.resolve(stay.timeZoneIdentifier))
    }

    static func isDayTrip(_ stay: Stay) -> Bool {
        nights(stay) == 0
    }

    /// A stop row's height at the reader's text size, for scrolling a row
    /// that may not be laid out yet under the navigation buttons.
    static func estimatedRowHeight(_ stay: Stay, hasPhotos: Bool) -> CGFloat {
        let footnote = UIFont.preferredFont(forTextStyle: .footnote).lineHeight
        guard stay.category == .destination else {
            return 9 + UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 2 + footnote + 11
        }
        var height = 9 + UIFont.preferredFont(forTextStyle: .headline).lineHeight + 2 + footnote + 11
        if stay.transitMode == .flight { height += 4 + footnote }
        if hasPhotos { height += 8 + 50 }
        return height
    }
}

/// A stop row's tint: the flash after the map's callout scrolled to it, or
/// the press that sends it to the map.
enum TimelineRowHighlight {
    case flash, pressed
}

/// One stop on the metro-style line: the rail and its station on the left,
/// the place, its dates and nights, and the weather on the right.
private struct TimelineStayRow: View {

    let stay: Stay
    let stayPhotos: [PHAsset]
    let isFirst: Bool
    let isLast: Bool
    /// A gap with nothing recorded meets this stop from above or below: the
    /// rail runs dashed there.
    var dashedAbove = false
    var dashedBelow = false
    /// A trip through several countries names each destination's country.
    let showsCountry: Bool
    let isEditing: Bool
    /// The map's selected place: the rail's station turns solid cobalt.
    let isSelected: Bool
    let highlight: TimelineRowHighlight?
    /// Shows this stop on the map; nil for a stop that is no station there, and while editing.
    let onShowOnMap: (() -> Void)?
    let onCategoryChange: (StayCategory) -> Void
    /// Hands a stay the user set back to automatic classification.
    let onAutomaticCategory: () -> Void
    /// Called when the user taps a photo thumbnail in this stay's row.
    /// The caller is expected to scope a full-screen viewer to this
    /// stay's photos starting at the tapped asset.
    let onPhotoTap: (PHAsset) -> Void

    private enum StationKind {
        case base, visit, transit
    }

    var body: some View {
        let isDestination = stay.category == .destination
        let nights = TimelineStop.nights(stay)
        let kind: StationKind = !isDestination ? .transit : (nights == 0 ? .visit : .base)
        HStack(alignment: .top, spacing: 14) {
            rail(kind)

            HStack(alignment: .top, spacing: 8) {
                stayContent(isDestination: isDestination)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Viewing: the weather. Editing: the category menu.
                if isEditing {
                    editCategoryButton
                        .padding(.top, 1)
                } else if isDestination {
                    weather
                        .padding(.top, 10)
                }
            }
            .padding(.top, 9)
            .padding(.bottom, 11)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 0.5)
                }
            }
        }
        // The flash and the press tint the row to the card's edges.
        .background {
            if let highlight {
                Rectangle()
                    .fill(highlight == .flash ? TripPageTint.flash : TripPageTint.pressed)
                    .padding(.horizontal, -AppTheme.cardPadding)
                    .transition(.opacity)
            }
        }
        .modifier(ShowOnMapAction(action: onShowOnMap))
    }

    /// The line through this stop: 4 pt cobalt, clear above the first
    /// station and below the last; the station sits on it: 18 pt for a
    /// base, 12 for a visit, 10 for a transit stop, and a solid cobalt disc
    /// while the map has the place selected.
    private func rail(_ kind: StationKind) -> some View {
        VStack(spacing: 0) {
            TripGapRail(clear: isFirst, dashed: dashedAbove)
                .frame(width: 4, height: 16)

            // A 14 pt slot, so a selected station's larger disc never moves the row.
            ZStack {
                if isSelected {
                    let size: CGFloat = kind == .base ? 22 : 17
                    Circle()
                        .fill(AppTheme.routeLine)
                        .frame(width: size, height: size)
                        .shadow(color: AppTheme.accentGlow, radius: 5)
                } else {
                    let size: CGFloat = kind == .base ? 18 : (kind == .visit ? 12 : 10)
                    let stroke: CGFloat = kind == .base ? 4 : (kind == .visit ? 3 : 2.5)
                    Circle()
                        .fill(AppTheme.card)
                        .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: stroke))
                        .frame(width: size, height: size)
                        .shadow(color: kind == .transit ? .clear : AppTheme.accentGlow, radius: 5)
                }
            }
            .frame(width: 18, height: 14)
            .zIndex(1)

            TripGapRail(clear: isLast, dashed: dashedBelow)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stayContent(isDestination: Bool) -> some View {
        // The inbound leg, not the stop: its own caption below, so the
        // airplane never sits beside the stop's dwell time.
        let arrivedByFlight = stay.transitMode == .flight

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !isDestination && !arrivedByFlight {
                    // The leg's mode says what kind of stop this was — a
                    // car, a walk — where a "Transit" capsule only repeated
                    // the row's greyed styling.
                    Image(systemName: stay.transitMode?.systemImage ?? "arrow.triangle.swap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(stay.transitMode?.displayName ?? stay.category.displayName)
                }

                Text(stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."))
                    .font(isDestination ? .headline : .subheadline)
                    .foregroundStyle(isDestination ? .primary : .secondary)

                if showsCountry, isDestination, let country = localizedCountryName(
                    iso: stay.isoCountryCode,
                    fallback: stay.country
                ) {
                    Text(verbatim: "· \(country)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // "12 to 16 Sep · 4 nights", a visit's "14 Sep · 3h 35m", or a
            // transit stop's dwell: "14 Sep · 1h 40m", "40 min".
            Text(verbatim: TripDisplayText.stopCaption(stay))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            if arrivedByFlight {
                Label {
                    Text(String(localized: "trip-detail.arrived-by-flight", defaultValue: "Arrived by flight", comment: "Trip timeline caption on a stop the user reached by plane."))
                } icon: {
                    Image(systemName: "airplane")
                        .foregroundStyle(AppTheme.accent)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            if isDestination && !stayPhotos.isEmpty {
                // Show the first 6 thumbnails; tapping any opens the
                // full-screen viewer scoped to this stay's complete
                // photo set (not just the visible prefix). Each
                // PhotoThumbnailView wraps in a Button so the system
                // gives us the standard tap hit-target + scaling.
                // `.plain` button style preserves the photo
                // visuals (no system bezel / tint).
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(Array(stayPhotos.prefix(6)), id: \.localIdentifier) { asset in
                            Button {
                                onPhotoTap(asset)
                            } label: {
                                PhotoThumbnailView(
                                    asset: asset,
                                    targetSize: CGSize(width: 100, height: 100),
                                    corners: .small
                                )
                                .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 50)
                .padding(.top, 8)
            }
        }
    }

    /// The stop's weather: the condition's own colours, the temperature in
    /// the statistic face.
    @ViewBuilder
    private var weather: some View {
        if let condition = stay.weatherCondition,
           condition != .unavailable && condition != .unknown,
           let temp = stay.avgTemperatureC {
            HStack(spacing: 5) {
                Image(systemName: condition.systemImage)
                    .weatherGlyph()
                    .font(.system(size: 17))
                Text(UnitsFormatter.formatTemperatureCompact(temp))
                    .font(AppTheme.stat(.body, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private var editCategoryButton: some View {
        Menu {
            ForEach([StayCategory.destination, .transit], id: \.self) { category in
                Button {
                    onCategoryChange(category)
                } label: {
                    HStack {
                        Text(category.displayName)
                        if stay.category == category {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if TripDetailView.offersAutomaticCategory(userOverridden: stay.userOverridden) {
                Button(TripDetailView.automaticCategoryTitle) {
                    onAutomaticCategory()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(stay.category.displayName)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isDestinationMarker ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isDestinationMarker ? AnyShapeStyle(AppTheme.cobaltFill) : AnyShapeStyle(AppTheme.inset),
                in: .capsule)
        }
    }

    private var isDestinationMarker: Bool {
        stay.category == .destination
    }
}

/// A stop row's tap outside its thumbnails, and the same as a VoiceOver
/// action: shows the stop on the map. Rows that are no station there take neither.
private struct ShowOnMapAction: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAction(named: Text(String(
                    localized: "trip-detail.stop.show-on-map",
                    defaultValue: "Show on Map",
                    comment: "VoiceOver action on a trip page stop row: scrolls up to the route map and selects that place."))) {
                    action()
                }
        } else {
            content
        }
    }
}
