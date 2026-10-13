//
//  TripDetailView+Timeline.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import TipKit
import Photos
import UIKit

extension TripDetailView {

    // MARK: - Timeline Section

    @ViewBuilder
    func timelineSection(_ orderedStays: [Stay]) -> some View {
        let photosByStay = photoPresentation.assetsByStay
        // Lazy: an imported trip can carry 100+ stays, and each row owns a
        // context menu, a tip anchor and a thumbnail strip. Rows are realized
        // as they scroll into view; the enclosing ScrollView drives it even
        // through the outer eager VStack.
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .padding(.bottom, 12)

            // `!splitHintDismissed` is the cross-scene safeguard: a "Got It"
            // or split in another scene hides an already-visible card here on
            // the next render, not just on the next arming pass.
            if showSplitHint && !isEditing && !splitHintDismissed {
                splitHintCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ForEach(Array(orderedStays.enumerated()), id: \.element.id) { index, stay in
                TimelineStayRow(
                    stay: stay,
                    stayPhotos: photosByStay[stay.id] ?? [],
                    isFirst: index == 0,
                    isLast: index == orderedStays.count - 1,
                    isEditing: isEditing,
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
                .popoverTip(index == 1 && !isEditing && !showSplitHint && !splitHintDismissed
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
            }
        }
        .padding(.bottom, 16)

        if orderedStays.contains(where: { $0.weatherConditionRaw != nil }) {
            WeatherAttributionFootnote()
                .padding(.bottom, 32)
        }
    }

    private var splitHintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "scissors")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text("One trip, or several?")
                        .font(.subheadline.weight(.semibold))
                    Text("This trip was rebuilt from imported history, and long gaps make its boundaries uncertain. Touch and hold a stop below and choose “Split Trip Here”. You can also merge trips by touching and holding one in your trips list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    splitHintDismissed = true
                    withAnimation { showSplitHint = false }
                } label: {
                    Text("Got It")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TimelineStayRow: View {

    let stay: Stay
    let stayPhotos: [PHAsset]
    let isFirst: Bool
    let isLast: Bool
    let isEditing: Bool
    let onCategoryChange: (StayCategory) -> Void
    /// Hands a stay the user set back to automatic classification.
    let onAutomaticCategory: () -> Void
    /// Called when the user taps a photo thumbnail in this stay's row.
    /// The caller is expected to scope a full-screen viewer to this
    /// stay's photos starting at the tapped asset.
    let onPhotoTap: (PHAsset) -> Void


    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? .clear : .secondary.opacity(0.3))
                    .frame(width: 2, height: 12)

                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)

                Rectangle()
                    .fill(isLast ? .clear : .secondary.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 20)

            stayContent
                .padding(.vertical, 4)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stayContent: some View {
        let isDestination = stay.category == .destination

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !isDestination {
                    // The leg's mode says what kind of stop this was — an
                    // airplane, a car, a walk — where a "Transit" capsule
                    // only repeated the row's greyed styling.
                    Image(systemName: stay.transitMode?.systemImage ?? "arrow.triangle.swap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(stay.transitMode?.displayName ?? stay.category.displayName)
                }

                Text(stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."))
                    .font(isDestination ? .subheadline.bold() : .caption)
                    .foregroundStyle(isDestination ? .primary : .secondary)

                if let country = localizedCountryName(
                    iso: stay.isoCountryCode,
                    fallback: stay.country
                ), isDestination {
                    Text(verbatim: "· \(country)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !isDestination {
                    Text(verbatim: "· \(stay.formattedDuration)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Viewing: the dot, weight and colour already say which
                // rows are destinations. Editing: the category menu.
                if isEditing {
                    editCategoryButton
                }
            }

            if isDestination {
                HStack(spacing: 12) {
                    Label(stay.formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(formattedTimeRange)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if let condition = stay.weatherCondition,
                       condition != .unavailable && condition != .unknown,
                       let temp = stay.avgTemperatureC {
                        Label(
                            UnitsFormatter.formatTemperatureCompact(temp),
                            systemImage: condition.systemImage
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !stayPhotos.isEmpty {
                    // Show the first 6 thumbnails; tapping any opens the
                    // full-screen viewer scoped to this stay's complete
                    // photo set (not just the visible prefix). Each
                    // PhotoThumbnailView wraps in a Button so the system
                    // gives us the standard tap hit-target + scaling.
                    // `.plain` button style preserves the photo
                    // visuals (no system bezel / tint).
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 3) {
                            ForEach(Array(stayPhotos.prefix(6)), id: \.localIdentifier) { asset in
                                Button {
                                    onPhotoTap(asset)
                                } label: {
                                    PhotoThumbnailView(
                                        asset: asset,
                                        targetSize: CGSize(width: 100, height: 100)
                                    )
                                    .frame(width: 50, height: 50)
                                    .clipShape(.rect(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 50)
                }
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
                    .font(.caption2.bold())
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(categoryColor, in: .capsule)
        }
    }

    // MARK: - Styling

    private var dotColor: Color {
        switch stay.category {
        case .destination: .red
        case .transit: .orange
        default: .gray
        }
    }

    private var dotSize: CGFloat {
        stay.category == .destination ? 12 : 8
    }

    private var categoryColor: Color {
        switch stay.category {
        case .destination: .green
        case .transit: .orange
        default: .gray
        }
    }

    /// Day, month and time only: the header already carries the year, and
    /// the full form wrapped every row onto a second line.
    private var formattedTimeRange: String {
        (stay.startTime..<stay.endTime).formatted(
            Date.IntervalFormatStyle().month(.abbreviated).day().hour().minute()
        )
    }
}
