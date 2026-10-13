//
//  TripDetailView+Photos.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import Photos
import UIKit

/// Rebuilt on accepted photo or pin publications, so unrelated body updates
/// do not flatten the gallery, sort pinned assets or rebuild timeline buckets.
struct TripPhotoPresentation {
    let groups: [StayPhotos]
    let pinnedIdentifiers: Set<String>
    let count: Int
    let preview: [PHAsset]
    let pinned: [PHAsset]
    let assetsByStay: [UUID: [PHAsset]]

    init(groups: [StayPhotos], pinnedIdentifiers: Set<String>) {
        self.groups = groups
        self.pinnedIdentifiers = pinnedIdentifiers
        count = groups.reduce(0) { $0 + $1.assets.count }
        preview = Array(groups.lazy.flatMap(\.assets).prefix(20))
        pinned = PhotoService.pinnedAssets(in: groups, pinnedIdentifiers: pinnedIdentifiers)
        assetsByStay = Dictionary(groups.map { ($0.stayID, $0.assets) },
                                  uniquingKeysWith: { first, _ in first })
    }
}

extension TripDetailView {

    // MARK: - Photos Section

    @ViewBuilder
    var photosSection: some View {
        let photoCount = photoPresentation.count
        let pinned = photoPresentation.pinned

        if photoAccessIsOff {
            VStack(alignment: .leading, spacing: 8) {
                Text("Photos")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(photoAccessOffHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if PhotoService.shared.authorizationStatus == .denied {
                        Button("Open Settings") {
                            openPhotoSettings()
                        }
                        .font(.subheadline)
                    }
                }
                Divider()
            }
        } else if photoCount > 0 || hasRestorableHiddenPhotos {
            // One header subtree for both modes: hiding the last visible photo
            // relabels the link instead of removing it, so the only route to
            // Hidden Photos survives and an open gallery keeps its link.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Photos")
                        .font(.headline)

                    if photoCount > 0 {
                        Text("\(photoCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    NavigationLink {
                        TripPhotosView(trip: trip)
                    } label: {
                        if photoCount == 0 {
                            Text("Hidden Photos")
                                .font(.subheadline)
                        } else {
                            Text("See All")
                                .font(.subheadline)
                        }
                    }
                }

                if !pinned.isEmpty {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 4) {
                            ForEach(pinned, id: \.localIdentifier) { asset in
                                photoButton(for: asset)
                            }
                        }
                    }
                    .frame(height: 80)
                }

                if photoCount > 0 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 4) {
                            ForEach(photoPresentation.preview, id: \.localIdentifier) { asset in
                                photoButton(for: asset)
                            }
                        }
                    }
                    .frame(height: 80)
                }

                Divider()
            }
        }
    }

    private var photoAccessIsOff: Bool {
        PhotoService.shared.authorizationStatus == .denied
            || PhotoService.shared.authorizationStatus == .restricted
    }

    private var photoAccessOffHint: String {
        if PhotoService.shared.authorizationStatus == .restricted {
            return String(localized: "This device doesn't allow photo access.")
        }
        return String(
            localized: "photos.access-off.hint",
            defaultValue: "Photo access is off. Enable it in Settings to see trip photos",
            comment: "Guidance shown on trip photo surfaces when Photos access is denied or restricted."
        )
    }

    private func openPhotoSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private func photoButton(for asset: PHAsset) -> some View {
        Button {
            photoViewerAssetID = asset.localIdentifier
        } label: {
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 160, height: 160)
            )
            .frame(width: 80, height: 80)
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            photoContextMenu(for: asset)
        }
    }

    @ViewBuilder
    private func photoContextMenu(for asset: PHAsset) -> some View {
        let isPinned = photoPresentation.pinnedIdentifiers.contains(asset.localIdentifier)
        Button {
            togglePin(asset)
        } label: {
            Label(isPinned ? "Unpin" : "Pin to Top",
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
        Button {
            assetPendingDelete = asset
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
    }

    private func togglePin(_ asset: PHAsset) {
        guard !trip.isDeleted else { return }
        let id = asset.localIdentifier
        pendingPinMutations += 1
        let mutation: Task<Bool, Never>
        var pinnedIDs = photoPresentation.pinnedIdentifiers
        if pinnedIDs.contains(id) {
            mutation = PhotoService.shared.unpinPhoto(localIdentifier: id, tripID: trip.id)
            pinnedIDs.remove(id)
        } else {
            mutation = PhotoService.shared.pinPhoto(localIdentifier: id, tripID: trip.id)
            pinnedIDs.insert(id)
        }
        photoPresentation = TripPhotoPresentation(groups: photoPresentation.groups, pinnedIdentifiers: pinnedIDs)
        let tripID = trip.id
        Task {
            _ = await mutation.value
            pendingPinMutations -= 1
            // Keep later optimistic taps until every submitted write settles.
            guard pendingPinMutations == 0 else { return }
            photoPresentation = TripPhotoPresentation(
                groups: photoPresentation.groups,
                pinnedIdentifiers: PhotoService.shared.pinnedIdentifiers(for: tripID))
        }
    }

    func loadPhotos() async {
        guard PhotoService.isLive(trip) else { return }
        guard PhotoService.shared.authorizationStatus == .authorized
            || PhotoService.shared.authorizationStatus == .limited else {
            return
        }
        // Monotonic generation guard. Six sites trigger this — the view
        // `.task`, a stay reclassify, the photo picker's `onAssetsChanged`,
        // hide/unhide, the library-change observer and pull-to-refresh —
        // several of which fire in bursts, and `photosForTrip` runs off-main
        // for a variable time (cache hit vs a full PhotoKit fetch + grouping).
        // An older fetch finishing last would republish stale groups over a
        // newer result (hidden photos reappearing, a just-added photo
        // vanishing) until the next trigger, so only the newest publishes.
        photoLoadGeneration &+= 1
        let generation = photoLoadGeneration
        // Capture the Sendable id BEFORE the await — the row can be deleted
        // while photosForTrip is off snapshotting/grouping.
        let tripID = trip.id
        guard let publication = await Self.resolvePhotoLoad(
            for: trip,
            showingPhotos: !photoPresentation.groups.isEmpty,
            service: .shared,
            isCurrent: { generation == photoLoadGeneration }
        ) else { return }
        hasRestorableHiddenPhotos = publication.hiddenRoute
        guard let loaded = publication.photos else { return }
        photoPresentation = TripPhotoPresentation(
            groups: loaded,
            pinnedIdentifiers: pendingPinMutations == 0
                ? PhotoService.shared.pinnedIdentifiers(for: tripID)
                : photoPresentation.pinnedIdentifiers)
    }

    /// What one detail photo load publishes. `photos == nil` keeps the groups
    /// already shown; `hiddenRoute` keeps the header link to Hidden Photos
    /// when nothing is visible.
    struct PhotoLoadPublication {
        let photos: [StayPhotos]?
        let hiddenRoute: Bool
    }

    /// Resolves one `loadPhotos()` pass, fencing generation (`isCurrent`),
    /// cancellation and the row's lifetime after every await; nil publishes
    /// nothing. `.unavailable` for a live row means the hidden list could not
    /// be read: shown photos stay, and with none shown the route helper
    /// decides, whose unknown answer keeps the route. Otherwise a cold first
    /// failure would leave an all-hidden trip with no way to restore.
    static func resolvePhotoLoad(
        for trip: Trip,
        showingPhotos: Bool,
        service: PhotoService,
        isCurrent: @MainActor () -> Bool
    ) async -> PhotoLoadPublication? {
        guard PhotoService.isLive(trip) else { return nil }
        let loaded = await service.photosForTrip(trip).groups
        guard isCurrent(), !Task.isCancelled, PhotoService.isLive(trip) else { return nil }
        if loaded == nil && showingPhotos { return nil }
        // With nothing visible, check for restorable hidden photos before
        // publishing so no render drops the header link in between.
        var hiddenRoute = false
        if loaded?.isEmpty ?? true {
            hiddenRoute = await service.hasRestorableHiddenPhotos(for: trip)
            guard isCurrent(), !Task.isCancelled, PhotoService.isLive(trip) else { return nil }
        }
        return PhotoLoadPublication(photos: loaded, hiddenRoute: hiddenRoute)
    }

    /// The detail's initial load. Captures the UUID before the first
    /// suspension and re-checks cancellation and the row's lifetime after
    /// each one: a detail torn down or deleted while its photos load spends
    /// no gate unit or network on weather, and no model is read after death.
    static func runInitialLoad(
        for trip: Trip,
        loadPhotos: @MainActor () async -> Void,
        enrich: @MainActor (UUID) async -> Void
    ) async {
        guard PhotoService.isLive(trip) else { return }
        let tripID = trip.id
        await loadPhotos()
        guard !Task.isCancelled, PhotoService.isLive(trip) else { return }
        await enrich(tripID)
    }

    /// Assets to pass to the full-screen photo viewer. When the tap came
    /// from a timeline-row thumbnail (`photoViewerScopeStayID` is
    /// non-nil), the viewer is limited to JUST that stay's photos so
    /// swipes walk through THAT stay's gallery only. When the tap came
    /// from the trip's top photo section, scope is the whole trip.
    func viewerAssets() -> [PHAsset] {
        if let stayID = photoViewerScopeStayID {
            return photoPresentation.assetsByStay[stayID] ?? []
        }
        return photoPresentation.groups.flatMap(\.assets)
    }
}
