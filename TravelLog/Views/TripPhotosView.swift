import SwiftUI
import SwiftData
import Photos
import UIKit

struct TripPhotosView: View {

    let trip: Trip

    @State private var tripPhotos: [StayPhotos]

    /// True once the first `refetchPhotos()` has published — gates the
    /// empty state below so it can't flash during the deferred initial load.
    @State private var hasLoadedOnce = false
    /// True when no photo is visible but this device can show hidden ones;
    /// the empty state then points to Hidden Photos instead of the library.
    @State private var hasRestorableHiddenPhotos = false
    /// Drives the empty state's push to Hidden Photos. A link inside that
    /// empty state would pop the pushed screen (and its viewer) as soon as
    /// the first restore republishes a non-empty gallery underneath it.
    @State private var showsHiddenPhotos = false
    @State private var pinnedAssets: [PHAsset] = []
    @State private var pinnedIDs: Set<String> = []
    @State private var pendingPinMutations = 0
    @State private var photoViewerAssetID: String?
    @State private var assetPendingDelete: PHAsset?
    /// Monotonic guard so only the NEWEST in-flight refetch publishes.
    @State private var refetchGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var allAssets: [PHAsset] {
        tripPhotos.flatMap(\.assets)
    }

    init(trip: Trip) {
        self.trip = trip
        // Photos load in `.task` after appearance rather than synchronously in
        // init — a PhotoKit + SwiftData fetch here blocks the navigation push,
        // so the grid would stutter in on a large trip. `pinnedAssets` /
        // `pinnedIDs` already default to empty at their declarations.
        _tripPhotos = State(initialValue: [])
    }

    var body: some View {
        // Deleted-model guard, as in TripDetailView.body: `isDeleted` is the
        // one safe read of a row deleted out from under this view. Render a
        // placeholder; the parent's next recompute drops the destination.
        if trip.isDeleted {
            ContentUnavailableView(
                "Trip Unavailable",
                systemImage: "suitcase",
                description: Text("This trip was removed or rebuilt.")
            )
        } else {
            galleryContent
        }
    }

    private var galleryContent: some View {
        ScrollView {
            // Post-load empty state: when every photo of an OPEN gallery
            // disappears (library deletion, limited-access deselect), the
            // refetch publishes an empty snapshot, which would otherwise
            // render as a blank scroll view indistinguishable from loading.
            // Gated on `hasLoadedOnce` so the deferred initial load still
            // shows nothing rather than flashing "no photos" before the first
            // fetch lands.
            if hasLoadedOnce && tripPhotos.isEmpty && pinnedAssets.isEmpty {
                Group {
                    if photoAccessIsOff {
                        VStack(spacing: 12) {
                            Text(photoAccessOffHint)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if PhotoService.shared.authorizationStatus == .denied {
                                Button("Open Settings") {
                                    openPhotoSettings()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if hasRestorableHiddenPhotos {
                        ContentUnavailableView {
                            Label("No Photos Available", systemImage: "eye.slash")
                        } description: {
                            Text(String(
                                localized: "trip-photos.all-hidden.description",
                                defaultValue: "All of this trip's photos are hidden. You can restore them from Hidden Photos.",
                                comment: "Trip gallery empty state when every photo of the trip on this device is hidden."
                            ))
                        } actions: {
                            Button("Hidden Photos") {
                                showsHiddenPhotos = true
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "No Photos Available",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("No photos from this trip are in your library right now.")
                        )
                    }
                }
                .padding(.top, 80)
            }
            LazyVStack(alignment: .leading, spacing: 16) {
                if !pinnedAssets.isEmpty {
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(pinnedAssets, id: \.localIdentifier) { asset in
                                photoCell(for: asset)
                            }
                        }
                    } header: {
                        pinnedHeader
                    }
                }

                ForEach(tripPhotos) { stayGroup in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(stayGroup.assets, id: \.localIdentifier) { asset in
                                photoCell(for: asset)
                            }
                        }
                    } header: {
                        stayHeader(for: stayGroup)
                    }
                }
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TripHiddenPhotosView(trip: trip, onChange: { Task { await refetchPhotos() } })
                } label: {
                    Label("Hidden", systemImage: "eye.slash")
                }
            }
        }
        // Owned by the always-present gallery, not the empty state, so
        // restoring photos keeps Hidden Photos on screen.
        .navigationDestination(isPresented: $showsHiddenPhotos) {
            TripHiddenPhotosView(trip: trip, onChange: { Task { await refetchPhotos() } })
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { photoViewerAssetID != nil },
                set: { if !$0 { photoViewerAssetID = nil } }
            ),
            onDismiss: { Task { await refetchPhotos() } }
        ) {
            if let id = photoViewerAssetID {
                PhotoViewerView(
                    assets: allAssets,
                    initialAssetID: id,
                    tripID: trip.id,
                    onAssetsChanged: { _ in Task { await refetchPhotos() } }
                )
            }
        }
        .alert("Hide Photo?", isPresented: Binding(
            get: { assetPendingDelete != nil },
            set: { if !$0 { assetPendingDelete = nil } }
        )) {
            Button("Hide") {
                // Stale-render tap guard, as in togglePin.
                if let asset = assetPendingDelete, !trip.isDeleted {
                    let mutation = PhotoService.shared.hidePhoto(localIdentifier: asset.localIdentifier, tripID: trip.id)
                    Task {
                        _ = await mutation.value
                        await refetchPhotos()
                    }
                }
                assetPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { assetPendingDelete = nil }
        } message: {
            Text("This photo won't appear in this trip anymore. You can restore it later from Hidden Photos.")
        }
        // Photos can be hidden / pinned / deleted while we're backgrounded.
        // Three arrival paths: (1) system-library changes — delivered to the
        // registered change observer on resume → `handleSystemPhotoLibraryChange`
        // invalidates + bumps `changeToken`; (2) CloudKit silent push →
        // AppDelegate's handler invalidates + bumps; (3) CloudKit rows whose
        // push was throttled — mirroring imports them on foreground with NO
        // hook firing. Path 3 is why the cold invalidation below is kept for
        // iCloud-sync users (guaranteed per-foreground consistency).
        // Local-only installs have no path 3, so they skip the full cold
        // PhotoKit re-match, which hitches on large libraries. TripDetailView
        // follows the same rule. Auth revocation isn't a stale-cache risk:
        // iOS terminates the process when Photos permission changes.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // Deleted-model guard: this handler fires in exactly the window a
            // background pass can delete the trip, and `trip.id` then traps.
            guard !trip.isDeleted else { return }
            PhotoService.shared.refreshAuthorizationStatus()
            if UserDefaults.standard.bool(forKey: AppDelegate.iCloudSyncEnabledKey) {
                PhotoService.shared.invalidateCache(for: trip.id)
            }
            Task { await refetchPhotos() }
        }
        // Real-time library-change reactivity: when `PhotoService` observes a
        // PhotoKit event while we're foregrounded (deletion, import, limited-
        // library reselect), it bumps `changeToken` after invalidating its
        // own caches. We just need to repaint our local snapshot.
        .onChange(of: PhotoService.shared.changeToken) { _, _ in
            Task { await refetchPhotos() }
        }
        // Initial load, deferred off the navigation-push critical path so the
        // push animation stays smooth.
        .task { await refetchPhotos() }
    }

    // MARK: - Subviews

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
    private func photoCell(for asset: PHAsset) -> some View {
        Button {
            photoViewerAssetID = asset.localIdentifier
        } label: {
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 400, height: 400)
            )
            .aspectRatio(1, contentMode: .fill)
            .clipped()
        }
        .buttonStyle(.plain)
        .contextMenu {
            photoContextMenu(for: asset)
        }
    }

    @ViewBuilder
    private func photoContextMenu(for asset: PHAsset) -> some View {
        let isPinned = pinnedIDs.contains(asset.localIdentifier)
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

    @ViewBuilder
    private var pinnedHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Pinned", systemImage: "pin.fill")
                .font(.subheadline.bold())

            Text(pinnedAssets.count == 1
                 ? String(localized: "trip-photos.pinned-count.one", defaultValue: "\(pinnedAssets.count, format: .number.grouping(.never)) photo", comment: "Pinned photos section count for one photo.")
                 : String(localized: "trip-photos.pinned-count.other", defaultValue: "\(pinnedAssets.count, format: .number.grouping(.never)) photos", comment: "Pinned photos section count for multiple photos."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stayHeader(for group: StayPhotos) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.stayLocality ?? String(localized: "trip-photos.place.unknown", defaultValue: "Unknown", comment: "Fallback place name for a group of trip photos."))
                .font(.subheadline.bold())

            Text(group.assets.count == 1
                 ? String(localized: "trip-photos.stay-header.one", defaultValue: "\(group.stayStartTime.formatted(date: .abbreviated, time: .omitted)) · \(group.assets.count, format: .number.grouping(.never)) photo", comment: "Trip photo group header with its date and one photo.")
                 : String(localized: "trip-photos.stay-header.other", defaultValue: "\(group.stayStartTime.formatted(date: .abbreviated, time: .omitted)) · \(group.assets.count, format: .number.grouping(.never)) photos", comment: "Trip photo group header with its date and multiple photos."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func togglePin(_ asset: PHAsset) {
        // A tap can land on a stale render after a background delete — the
        // body guard only swaps content on the NEXT render.
        guard !trip.isDeleted else { return }
        let id = asset.localIdentifier
        pendingPinMutations += 1
        let mutation: Task<Bool, Never>
        if pinnedIDs.contains(id) {
            mutation = PhotoService.shared.unpinPhoto(localIdentifier: id, tripID: trip.id)
            pinnedIDs.remove(id)
        } else {
            mutation = PhotoService.shared.pinPhoto(localIdentifier: id, tripID: trip.id)
            pinnedIDs.insert(id)
        }
        pinnedAssets = PhotoService.pinnedAssets(in: tripPhotos, pinnedIdentifiers: pinnedIDs)
        let tripID = trip.id
        Task {
            _ = await mutation.value
            pendingPinMutations -= 1
            // Keep later optimistic taps until every submitted write settles.
            guard pendingPinMutations == 0 else { return }
            pinnedIDs = PhotoService.shared.pinnedIdentifiers(for: tripID)
            pinnedAssets = PhotoService.pinnedAssets(in: tripPhotos, pinnedIdentifiers: pinnedIDs)
        }
    }

    private func refetchPhotos() async {
        // Deleted-model guards: this method is
        // spawned from unstructured Tasks (viewer dismiss, hide, scenePhase,
        // library change) that can fire after a background pipeline pass
        // deleted the row. A saved deletion clears isDeleted but detaches the
        // row, so both checks run before and after every suspension, and only
        // the UUID captured up front is used after one.
        guard PhotoService.isLive(trip) else { return }

        // Generation guard: only the newest refetch publishes (see
        // `TripDetailView.loadPhotos`).
        refetchGeneration += 1
        let generation = refetchGeneration
        let tripID = trip.id

        // After a hide, PhotoService surgically removed the asset from its
        // per-trip cache (no cold re-match), so this read returns the
        // updated list with the hidden photo gone. `.unavailable` (unreadable
        // hidden list, dead row) keeps the loading or previous state.
        guard let photos = await PhotoService.shared.photosForTrip(trip).groups,
              generation == refetchGeneration, !Task.isCancelled,
              PhotoService.isLive(trip) else { return }
        // Resolve the all-hidden case before publishing so the empty state
        // never claims the library is empty while hidden photos exist.
        var hiddenRoute = false
        if photos.isEmpty {
            hiddenRoute = await PhotoService.shared.hasRestorableHiddenPhotos(for: trip)
            guard generation == refetchGeneration, !Task.isCancelled,
                  PhotoService.isLive(trip) else { return }
        }
        tripPhotos = photos
        hasRestorableHiddenPhotos = hiddenRoute
        hasLoadedOnce = true
        // One pinned-set fetch, not two: the pure overload takes the set we
        // already have, while the `tripID:` overload re-runs a synchronous
        // main-actor SwiftData fetch.
        if pendingPinMutations == 0 {
            pinnedIDs = PhotoService.shared.pinnedIdentifiers(for: tripID)
        }
        pinnedAssets = PhotoService.pinnedAssets(in: tripPhotos, pinnedIdentifiers: pinnedIDs)

        // Identity-based viewer selection means we never need to clamp an
        // index here — if the selected asset is gone, the viewer's `TabView`
        // simply has no matching tag and the next `onAssetsChanged` callback
        // will dismiss or advance us.
    }
}
