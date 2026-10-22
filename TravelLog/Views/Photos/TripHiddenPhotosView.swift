//
//  TripHiddenPhotosView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 14/5/26.
//

import SwiftUI
import SwiftData
import Photos

/// Per-trip browser for photos the user has previously removed from this
/// trip. Reached from `TripPhotosView` via the toolbar's "Hidden" item, or
/// its empty state when every photo is hidden. The trip detail keeps its
/// Photos link while restorable hidden photos exist, so this stays reachable.
///
/// Three ways to restore a photo, all driven by the same
/// `PhotoService.unhidePhoto(...)`:
///
/// 1. **Tap the eye-slash badge** in the top-right of a cell — instant.
/// 2. **Tap the photo body** — opens `PhotoViewerView` with
///    `isShowingHidden: true`, which swaps its `eye.slash` (hide) button for
///    an `eye` (restore) button and hides the pin button entirely. Same
///    advance-or-dismiss flow as the hide path. The viewer's
///    `onAssetsChanged` is piped back into this view's `hiddenAssets` and
///    into the parent's `onChange` so the main `TripPhotosView` gallery
///    re-fetches.
/// 3. **Long press** for the context menu.
///
/// Tap-on-badge vs tap-on-cell hit testing: the badge is a sibling of the
/// photo in a `ZStack`, not a child. SwiftUI's gesture router dispatches
/// the tap to whichever sibling has a `contentShape` containing the touch —
/// the badge's `.circle` shape gets badge taps; everywhere else routes to
/// the photo's `.onTapGesture`. Long-press anywhere on the cell triggers
/// the `.contextMenu` (it has its own gesture independent of taps).
struct TripHiddenPhotosView: View {

    let trip: Trip
    let onChange: () -> Void

    @State private var hiddenAssets: [PHAsset] = []
    /// First fetch happens in `.task` (below), not in `init`: this view is
    /// constructed eagerly by `TripPhotosView`'s closure-based toolbar
    /// `NavigationLink` on every parent re-render, so an init-time fetch would
    /// run a synchronous SwiftData + PHAsset round-trip per gallery repaint
    /// and discard its result after the first (`State(initialValue:)`
    /// applies once per identity).
    /// `hasLoaded` gates the empty state so a one-frame "No Hidden Photos"
    /// flash doesn't precede a non-empty grid. Only a successful read sets
    /// it: an unreadable hidden list is not "no hidden photos".
    @State private var hasLoaded = false
    /// Generation guard: only the newest refresh publishes (see
    /// `TripDetailView.loadPhotos`).
    @State private var refreshGeneration = 0
    @State private var photoViewerAssetID: String?
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    init(trip: Trip, onChange: @escaping () -> Void = {}) {
        self.trip = trip
        self.onChange = onChange
    }

    var body: some View {
        // Deleted-model guard, as in TripDetailView.body: `trip.id` is read
        // below in the viewer cover and unhide actions.
        if trip.isDeleted {
            ContentUnavailableView(
                "Trip Unavailable",
                systemImage: "suitcase",
                description: Text("This trip was removed or rebuilt.")
            )
        } else {
            hiddenContent
        }
    }

    private var hiddenContent: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if hiddenAssets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Tap the icon to restore a photo, or tap to view full screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppTheme.gutter)
                            .padding(.top, 4)

                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(hiddenAssets, id: \.localIdentifier) { asset in
                                photoCell(for: asset)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden Photos")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(
            isPresented: Binding(
                get: { photoViewerAssetID != nil },
                set: { if !$0 { photoViewerAssetID = nil } }
            ),
            onDismiss: { Task { await refreshFromService() } }
        ) {
            if let id = photoViewerAssetID {
                PhotoViewerView(
                    assets: hiddenAssets,
                    initialAssetID: id,
                    tripID: trip.id,
                    isShowingHidden: true,
                    onAssetsChanged: { newAssets in
                        // The viewer mutates its local copy as the user restores
                        // photos. Mirror those changes into our grid's state so
                        // the next render shows the same set, and bubble up so
                        // `TripPhotosView` knows to re-fetch when we navigate back.
                        hiddenAssets = newAssets
                        onChange()
                    }
                )
            }
        }
        // Same foreground refresh as the gallery views — if the user
        // unhid a photo on another device or revoked Photos access while
        // we were backgrounded, the hidden grid should catch up.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            PhotoService.shared.refreshAuthorizationStatus()
            Task { await refreshFromService() }
        }
        // Real-time PhotoKit reactivity (foreground): bumped by
        // `PhotoService.handleSystemPhotoLibraryChange()`. The hidden grid
        // is derived from SwiftData rows × on-device asset existence, so a
        // deletion in Photos.app naturally removes the row's resolved asset
        // from `hiddenAssets(for:)`'s output.
        .onChange(of: PhotoService.shared.changeToken) { _, _ in
            Task { await refreshFromService() }
        }
        // Initial load, deferred off the navigation-push critical path —
        // same pattern as TripPhotosView's `.task`. Runs once per identity;
        // the refresh paths above keep the grid current afterwards.
        .task {
            guard !hasLoaded else { return }
            await refreshFromService()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No Hidden Photos",
            systemImage: "eye.slash",
            description: Text("Photos you remove from this trip will appear here so you can restore them later.")
        )
    }

    @ViewBuilder
    private func photoCell(for asset: PHAsset) -> some View {
        ZStack(alignment: .topTrailing) {
            // Photo body. Uses .onTapGesture rather than a Button so the
            // restore-badge Button (sibling, not child) is the topmost
            // hit-target inside its circle and the rest of the cell routes
            // here.
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 400, height: 400)
            )
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .contentShape(.rect)
            .onTapGesture {
                openViewer(for: asset)
            }
            .contextMenu {
                Button {
                    unhide(asset)
                } label: {
                    Label("Restore to Trip", systemImage: "eye")
                }
            }

            // Restore badge. Its own Button so hit-testing isolates the
            // tap to the circle; `.contentShape(.circle)` keeps the
            // active region tight against the visible glyph.
            Button {
                unhide(asset)
            } label: {
                Image(systemName: "eye.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: .circle)
            }
            .buttonStyle(.plain)
            .contentShape(.circle)
            .padding(4)
            .accessibilityLabel("Restore photo")
        }
    }

    // MARK: - Actions

    private func openViewer(for asset: PHAsset) {
        photoViewerAssetID = asset.localIdentifier
    }

    private func unhide(_ asset: PHAsset) {
        // A tap can land on a stale render after a background delete — the
        // body guard only swaps content on the NEXT render.
        guard !trip.isDeleted else { return }
        let mutation = PhotoService.shared.unhidePhoto(
            localIdentifier: asset.localIdentifier,
            tripID: trip.id
        )
        Task {
            _ = await mutation.value
            await refreshFromService()
            onChange()
        }
    }

    /// Re-fetch from the canonical source of truth. The viewer reopens by
    /// `localIdentifier`, so a now-missing asset simply has no matching tag
    /// and the next user action sorts it out. Used both as the `onDismiss`
    /// of the fullScreenCover and after a local unhide via the badge /
    /// context menu. The PHAsset resolution runs off-main inside
    /// `PhotoService.hiddenAssets(for:)`; the generation guard keeps
    /// overlapping refreshes from publishing stale grids.
    private func refreshFromService() async {
        // Deleted-model guard: spawned from
        // unstructured Tasks that can outlive the row. A saved deletion
        // detaches the row without setting isDeleted.
        guard PhotoService.isLive(trip) else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let assets = await Self.resolveHiddenAssets(
            for: trip,
            service: .shared,
            isCurrent: { generation == refreshGeneration }
        ) else { return }
        hiddenAssets = assets
        hasLoaded = true
    }

    /// One refresh's publishable grid, or nil to publish nothing. A failed
    /// read keeps the spinner or the previous grid until the next foreground,
    /// library change or restore retries. A cancelled refresh (the initial
    /// `.task` torn down mid-read) must not set `hasLoaded` either, or the
    /// retained identity skips its initial load on reappearance
    /// (cancelled reads consume no retry token).
    static func resolveHiddenAssets(
        for trip: Trip,
        service: PhotoService,
        isCurrent: @MainActor () -> Bool
    ) async -> [PHAsset]? {
        guard PhotoService.isLive(trip) else { return nil }
        guard let assets = await service.hiddenAssets(for: trip),
              isCurrent(), !Task.isCancelled, PhotoService.isLive(trip) else { return nil }
        return assets
    }
}
