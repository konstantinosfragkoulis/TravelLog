import SwiftUI
import SwiftData
import Photos

/// The tapped hex, as one flat sheet surface: a header with the cell's mark
/// (its map colour inside the saffron selection ring), place, flag and
/// country, and Close; one facts row split by hairlines; the trips with a
/// stay in the cell as plain rows; and a few of those stays' photos.
///
/// Trips, days and photos come from the cell's stays (`HexCellTripsLoader`),
/// read off-main per cell and store change; photos reuse `PhotoService`'s
/// per-trip groups, so hidden photos stay hidden.
struct HexDetailSheet: View {
    let hex: HexVisitSnapshot
    /// The cell's paint on the map.
    let markFill: Color
    let onClose: () -> Void
    let onOpenTrip: (Trip) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var detail: CellDetail?

    private struct CellDetail {
        let h3Index: String
        let days: Int
        let trips: [Trip]
        var photos: [CellPhoto] = []
    }

    private struct CellPhoto: Identifiable {
        let asset: PHAsset
        let trip: Trip
        var id: String { asset.localIdentifier }
    }

    private struct LoadKey: Equatable {
        let h3Index: String
        let storeToken: Int
        let photoToken: UUID
    }

    /// At most this many photos, from at most `photoTripLimit` trips.
    private static let photoLimit = 4
    private static let photoTripLimit = 3
    private static let photoRadius: CGFloat = 10

    /// The loaded detail, only while it still describes this cell.
    private var currentDetail: CellDetail? {
        detail?.h3Index == hex.h3Index ? detail : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                facts
                    .padding(.top, 14)

                if let detail = currentDetail {
                    let trips = detail.trips.filter(PhotoService.isLive)
                    if !trips.isEmpty {
                        tripsSection(trips)
                    }
                    let photos = detail.photos.filter { PhotoService.isLive($0.trip) }
                    if !photos.isEmpty {
                        photoRow(photos)
                            .padding(.top, 10)
                    }
                }
            }
            .padding(.horizontal, 20)
            // Clear of the system grabber.
            .padding(.top, 23)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: LoadKey(
            h3Index: hex.h3Index,
            storeToken: StoreChangeTracker.shared.token(for: [.stay, .trip]),
            photoToken: PhotoService.shared.changeToken
        )) {
            await load()
        }
    }

    // MARK: - Header

    private var countryName: String? {
        localizedCountryName(iso: hex.isoCountryCode, fallback: hex.country)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HexMark()
                .fill(markFill)
                .overlay {
                    HexMark().stroke(AppTheme.saffron, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if let locality = hex.locality {
                    Text(locality)
                        .font(.title2.bold())
                } else if let countryName {
                    Text(countryName)
                        .font(.title2.bold())
                } else {
                    Text("Unknown Location")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                }

                let iso = hex.isoCountryCode
                let subtitle = hex.locality == nil ? nil : countryName
                if iso != nil || subtitle != nil {
                    HStack(spacing: 6) {
                        if let iso {
                            FlagView(iso: iso, size: .small)
                        }
                        if let subtitle {
                            Text(subtitle)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .lineLimit(2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.inset, in: .circle)
                    // 44 pt hit target around the 32 pt control.
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -6)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Facts

    private struct Fact: Identifiable {
        let id: String
        let label: Text
        let value: Text
        var accent = false
        var placeholder = false
    }

    private var factItems: [Fact] {
        var items = [Fact(
            id: "entries", label: Text("Entries"),
            value: Text(hex.visitCount, format: .number), accent: true
        )]
        let daysLabel = Text(String(
            localized: "hex-map.detail.days", defaultValue: "Days",
            comment: "Map hex sheet fact label: distinct days with a recorded stay in the tapped hex."))
        if let detail = currentDetail {
            if detail.days > 0 {
                items.append(Fact(id: "days", label: daysLabel, value: Text(detail.days, format: .number)))
            }
        } else {
            items.append(Fact(id: "days", label: daysLabel, value: Text(verbatim: "00"), placeholder: true))
        }
        items.append(Fact(
            id: "first", label: Text("First visited"),
            value: Text(hex.firstVisited.formatted(date: .abbreviated, time: .omitted))))
        items.append(Fact(
            id: "last", label: Text("Last visited"),
            value: Text(hex.lastVisited.formatted(date: .abbreviated, time: .omitted))))
        return items
    }

    /// One row split by hairlines; stacked label and value rows when the
    /// text size needs the width. No tiles.
    private var facts: some View {
        let items = factItems
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(items) { fact in
                    if fact.id != items.first?.id {
                        Spacer(minLength: 10)
                        Divider()
                            .padding(.vertical, 4)
                        Spacer(minLength: 10)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        fact.label
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        factValue(fact)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(items) { fact in
                    if fact.id != items.first?.id {
                        Divider()
                    }
                    HStack(alignment: .firstTextBaseline) {
                        fact.label
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        factValue(fact)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func factValue(_ fact: Fact) -> some View {
        fact.value
            .font(AppTheme.stat(.callout, weight: .semibold))
            .foregroundStyle(fact.accent ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .redacted(reason: fact.placeholder ? .placeholder : [])
    }

    // MARK: - Trips Here

    private func tripsSection(_ trips: [Trip]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(
                localized: "hex-map.detail.trips-here", defaultValue: "Trips Here",
                comment: "Map hex sheet: header above the trips with a stay in the tapped hex."))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(trips, id: \.persistentModelID) { trip in
                if trip.persistentModelID != trips.first?.persistentModelID {
                    Divider()
                }
                Button {
                    onOpenTrip(trip)
                } label: {
                    HStack(spacing: 10) {
                        Text(trip.displayName)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(trip.startDate.formatted(.dateTime.month(.abbreviated).year()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 42)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - Photos

    /// Up to four equal slots; each opens the trip it came from.
    private func photoRow(_ photos: [CellPhoto]) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.photoLimit, id: \.self) { slot in
                if slot < photos.count {
                    let photo = photos[slot]
                    Button {
                        onOpenTrip(photo.trip)
                    } label: {
                        PhotoThumbnailView(
                            asset: photo.asset,
                            targetSize: CGSize(width: 240, height: 168)
                        )
                        // A slot whose photo changes loads the new one.
                        .id(photo.id)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .clipShape(.rect(cornerRadius: Self.photoRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(
                        localized: "hex-map.detail.photo.accessibility",
                        defaultValue: "Photo from \(photo.trip.displayName)",
                        comment: "Map hex sheet: VoiceOver label of a photo thumbnail; opens the named trip."))
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Loading

    /// Stays first (days and trips), then photos, each published as it lands.
    /// A failed read keeps what is shown; the next store change retries.
    private func load() async {
        let h3Index = hex.h3Index
        guard let snapshot = try? await HexCellTripsLoader.load(h3Index: h3Index, context: modelContext),
              !Task.isCancelled else { return }
        guard let trips = resolveTrips(snapshot.tripIDs, rows: snapshot.tripRows) else { return }
        let previousPhotos = detail?.h3Index == h3Index ? detail?.photos ?? [] : []
        detail = CellDetail(h3Index: h3Index, days: snapshot.days, trips: trips, photos: previousPhotos)

        var photos: [CellPhoto] = []
        for trip in trips.prefix(Self.photoTripLimit) where photos.count < Self.photoLimit {
            // `.unavailable` (an unreadable hidden list) skips the trip rather
            // than risk showing a hidden photo.
            // A cancelled load returns before an unavailable outcome is skipped,
            // so it cannot overwrite a newer load's photos.
            let outcome = await PhotoService.shared.photosForTrip(trip)
            guard !Task.isCancelled else { return }
            guard let groups = outcome.groups else { continue }
            for group in groups where snapshot.stayIDs.contains(group.stayID) {
                for asset in group.assets.prefix(Self.photoLimit - photos.count) {
                    photos.append(CellPhoto(asset: asset, trip: trip))
                }
            }
        }
        guard detail?.h3Index == h3Index else { return }
        detail?.photos = photos
    }

    /// Live trips for the loader's ids, in its order. Same-id twins resolve
    /// to the row the cell's stays point at, else the first fetched. Nil
    /// when the read fails.
    private func resolveTrips(_ ids: [UUID], rows: [UUID: PersistentIdentifier]) -> [Trip]? {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) })
        guard let fetched = try? modelContext.fetch(descriptor) else { return nil }
        var byID: [UUID: Trip] = [:]
        for trip in fetched where !trip.isDeleted {
            if byID[trip.id] == nil || rows[trip.id] == trip.persistentModelID {
                byID[trip.id] = trip
            }
        }
        return ids.compactMap { byID[$0] }
    }
}

/// The sheet's hex mark: a pointy-top hexagon in a 24 pt design grid,
/// 18.8 tall and 16.4 wide, scaled to the frame.
private nonisolated struct HexMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        let points: [(Double, Double)] = [(12, 2.6), (20.2, 7.3), (20.2, 16.7), (12, 21.4), (3.8, 16.7), (3.8, 7.3)]
        var path = Path()
        path.addLines(points.map { CGPoint(x: origin.x + $0.0 * scale, y: origin.y + $0.1 * scale) })
        path.closeSubpath()
        return path
    }
}
