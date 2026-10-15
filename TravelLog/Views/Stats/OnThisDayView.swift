//
//  OnThisDayView.swift
//  TravelLog
//

import Photos
import SwiftData
import SwiftUI

// MARK: - Banner (Stats page entry point)

/// Compact "On This Day" teaser card shown at the top of the Stats page —
/// only when at least one past-year memory exists for today's date. Tapping
/// pushes the full `OnThisDayView`. Content-layer card (flat semantic
/// background, no glass) per the Liquid Glass adoption guidance.
struct OnThisDayBanner: View {
    let groups: [OnThisDayYearGroup]

    private var headline: String {
        guard let newest = groups.first else { return "" }
        if let place = newest.trips.first?.places.first {
            return newest.yearsAgo == 1
                ? String(localized: "on-this-day.headline.place.one", defaultValue: "\(place), \(newest.yearsAgo, format: .number.grouping(.never)) year ago", comment: "On This Day banner headline naming a place visited one year ago.")
                : String(localized: "on-this-day.headline.place.other", defaultValue: "\(place), \(newest.yearsAgo, format: .number.grouping(.never)) years ago", comment: "On This Day banner headline naming a place visited multiple years ago.")
        }
        return newest.yearsAgo == 1
            ? String(localized: "on-this-day.headline.trip.one", defaultValue: "A trip, \(newest.yearsAgo, format: .number.grouping(.never)) year ago", comment: "On This Day banner headline for an unnamed trip from one year ago.")
            : String(localized: "on-this-day.headline.trip.other", defaultValue: "A trip, \(newest.yearsAgo, format: .number.grouping(.never)) years ago", comment: "On This Day banner headline for an unnamed trip from multiple years ago.")
    }

    private var extraCount: Int {
        max(0, groups.reduce(0) { $0 + $1.trips.count } - 1)
    }

    var body: some View {
        NavigationLink {
            OnThisDayView(groups: groups)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("On This Day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(extraCount > 0
                         ? (extraCount == 1
                            ? String(localized: "on-this-day.headline.more.one", defaultValue: "\(headline) · +\(extraCount, format: .number.grouping(.never)) more", comment: "On This Day banner headline followed by one additional memory count.")
                            : String(localized: "on-this-day.headline.more.other", defaultValue: "\(headline) · +\(extraCount, format: .number.grouping(.never)) more", comment: "On This Day banner headline followed by multiple additional memories."))
                         : headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("On this day: \(headline)")
        .accessibilityHint("Shows your trips from this date in past years")
    }
}

// MARK: - Detail page

/// Everything that happened on today's calendar date across past years,
/// grouped by year (newest first). Multiple trips per year are expected
/// and each gets its own row; rows deep-link to the trip when it still
/// exists. Each row leads with a cover photo from the trip (a pinned photo
/// first), falling back to a flag tile, and reads as title / places /
/// dates, with the weather as a trailing chip.
struct OnThisDayView: View {
    let groups: [OnThisDayYearGroup]

    @Query private var trips: [Trip]

    /// `uniquingKeysWith`, NOT `uniqueKeysWithValues`:
    /// Trip.id carries no uniqueness constraint (CloudKit), so two rows
    /// sharing an id — two-device JSON imports of the same export
    /// converging via sync — would trap this page. Same rule as
    /// `TripEntityFetcher.entities(for:container:)`. Static + pure so the
    /// duplicate-collapse rule stays independently testable.
    static func tripLookup(_ trips: [Trip]) -> [UUID: Trip] {
        Dictionary(trips.compactMap { trip in
            guard !trip.isDeleted else { return nil }
            return (trip.id, trip)
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        // Built ONCE per body evaluation and passed down: as a computed
        // property referenced inside `row(for:)`, SwiftUI would re-derive
        // the full dictionary on every row access.
        let tripsByID = Self.tripLookup(trips)
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.trips) { tripGroup in
                        row(for: tripGroup, trip: tripGroup.tripID.flatMap { tripsByID[$0] })
                    }
                } header: {
                    yearHeader(group)
                }
            }
            // Apple Weather attribution: once per screen, only when a row
            // shows weather.
            if groups.contains(where: { group in
                group.trips.contains { $0.weatherConditionRaw != nil }
            }) {
                Section {
                    WeatherAttributionFootnote()
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("On This Day")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "2023" large, "3 years ago" beside it — the year is the thing the
    /// eye scans for.
    private func yearHeader(_ group: OnThisDayYearGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.year, format: .number.grouping(.never))
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(group.yearsAgo == 1
                 ? String(localized: "on-this-day.years-ago.one", defaultValue: "\(group.yearsAgo, format: .number.grouping(.never)) year ago", comment: "On This Day year header suffix for one year ago.")
                 : String(localized: "on-this-day.years-ago.other", defaultValue: "\(group.yearsAgo, format: .number.grouping(.never)) years ago", comment: "On This Day year header suffix for multiple years ago."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(for tripGroup: OnThisDayTripGroup, trip: Trip?) -> some View {
        if let trip {
            NavigationLink {
                TripDetailView(trip: trip)
            } label: {
                OnThisDayRow(tripGroup: tripGroup, trip: trip)
            }
        } else {
            // The stay's trip was deleted (or never assembled) — still a
            // memory worth showing, just not navigable.
            OnThisDayRow(tripGroup: tripGroup, trip: nil)
        }
    }
}

// MARK: - Row

private struct OnThisDayRow: View {
    let tripGroup: OnThisDayTripGroup
    let trip: Trip?

    /// The trip only while it is still live: the lookup already drops
    /// deleted rows, but a deletion can land between that lookup and this
    /// row's own render, and `isDeleted` is the one safe read on such a model.
    private var liveTrip: Trip? {
        if let trip, !trip.isDeleted { trip } else { nil }
    }

    private var placesLine: String {
        tripGroup.places.joined(separator: " · ")
    }

    /// Trip name when the trip still exists and has one; otherwise the
    /// places, and only then the generic fallback.
    private var title: String {
        if let trip = liveTrip, trip.hasUsableDisplayName { return trip.displayName }
        if !placesLine.isEmpty { return placesLine }
        return String(localized: "on-this-day.place.unknown", defaultValue: "Unknown place", comment: "Fallback place name for an On This Day memory.")
    }

    private var subtitle: String? {
        guard let trip = liveTrip, trip.hasUsableDisplayName, !placesLine.isEmpty else { return nil }
        return placesLine
    }

    private var dateRange: String? {
        guard let start = tripGroup.startTime, let end = tripGroup.endTime else { return nil }
        // The year is already the section header; day + month is enough.
        // A same-day span renders as a single date.
        let style = Date.IntervalFormatStyle().month(.abbreviated).day()
        return (start..<max(start, end)).formatted(style)
    }

    private var flags: String {
        let codes = tripGroup.isoCountryCodes ?? []
        let fromStays = codes.compactMap(flagEmoji(for:)).joined()
        if !fromStays.isEmpty { return fromStays }
        return liveTrip?.countryFlags ?? ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            OnThisDayCover(trip: liveTrip, flags: flags)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let dateRange {
                        Text(dateRange)
                    }
                    if tripGroup.places.count > 1 {
                        if dateRange != nil { Text(verbatim: "·") }
                        Text(String(localized: "collections.places.count.other", defaultValue: "\(tripGroup.places.count, format: .number.grouping(.never)) places", comment: "Places collection header for multiple places."))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let raw = tripGroup.weatherConditionRaw,
               let condition = StayWeather.Condition(rawValue: raw),
               condition != .unknown, condition != .unavailable {
                VStack(spacing: 2) {
                    Image(systemName: condition.systemImage)
                        .symbolRenderingMode(.multicolor)
                        .font(.title3)
                    if let temp = tripGroup.avgTemperatureC {
                        Text(UnitsFormatter.formatTemperatureCompact(temp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 36)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cover

/// The trip's cover: its first pinned photo, else its first photo, else a
/// flag tile. Photo lookup goes through `PhotoService`'s per-trip cache, so
/// scrolling back over a row costs nothing.
private struct OnThisDayCover: View {
    let trip: Trip?
    let flags: String

    private struct CoverTaskKey: Hashable {
        let tripID: UUID?
        let changeToken: UUID
    }

    @State private var asset: PHAsset?

    private static let side: CGFloat = 60

    var body: some View {
        let liveTrip: Trip? = if let trip, PhotoService.isLive(trip) { trip } else { nil }
        ZStack {
            if let asset {
                PhotoThumbnailView(asset: asset, targetSize: CGSize(width: Self.side * 3, height: Self.side * 3))
                    .id(asset.localIdentifier)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.tint.opacity(0.12))
                if flags.isEmpty {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(.tint)
                } else {
                    Text(flags)
                        .font(flags.count > 2 ? .body : .title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
        // The change token re-runs the lookup after hides, pins and library
        // changes, and retries a load that could not read the hidden list.
        .task(id: CoverTaskKey(tripID: liveTrip?.id, changeToken: PhotoService.shared.changeToken)) {
            guard let trip = liveTrip, PhotoService.isLive(trip) else { asset = nil; return }
            let tripID = trip.id
            // `.unavailable` keeps the current cover rather than risk a hidden photo.
            guard let groups = await PhotoService.shared.photosForTrip(trip).groups,
                  !Task.isCancelled else { return }
            let all = groups.flatMap(\.assets)
            let pinned = PhotoService.shared.pinnedIdentifiers(for: tripID)
            asset = all.first { pinned.contains($0.localIdentifier) } ?? all.first
        }
    }
}
