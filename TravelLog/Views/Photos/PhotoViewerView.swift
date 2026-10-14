import SwiftUI
import UIKit
import Photos

struct PhotoViewerView: View {

    let tripID: UUID
    /// When `true`, the hide (`eye.slash`) button is swapped for a restore
    /// (`eye`) button, and the pin button is hidden entirely (pinning a hidden
    /// photo would create state for an asset that isn't in the gallery). Used
    /// when the viewer is opened from `TripHiddenPhotosView`. Defaults to
    /// `false` so every other call site (`TripDetailView`, `TripPhotosView`)
    /// keeps the pin + hide pair.
    let isShowingHidden: Bool
    let onAssetsChanged: ([PHAsset]) -> Void

    @State private var assets: [PHAsset]
    /// Selection is the asset's `PHAsset.localIdentifier`, not an `Int` index.
    /// Identity-based navigation means a mutation that shifts indices (hide /
    /// unhide / library change) cannot drift the visible page to a different
    /// asset — the viewer continues to show whichever asset was on screen, by
    /// identity, until we explicitly choose its successor.
    @State private var currentID: String
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var showShareError = false
    /// Retained so dismissal cancels an in-flight share decode: unowned, the
    /// task would survive the viewer and mutate obsolete view state after an
    /// iCloud-backed multi-second 3072² load.
    @State private var shareTask: Task<Void, Never>?
    @State private var showHideConfirmation = false
    /// The photo the open Hide confirmation is about.
    @State private var hideConfirmationID: String?
    @State private var pinnedIDs: Set<String> = []
    @State private var pendingPinMutations = 0
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @Environment(\.dismiss) private var dismiss

    init(
        assets: [PHAsset],
        initialAssetID: String,
        tripID: UUID,
        isShowingHidden: Bool = false,
        onAssetsChanged: @escaping ([PHAsset]) -> Void = { _ in }
    ) {
        self.tripID = tripID
        self.isShowingHidden = isShowingHidden
        self.onAssetsChanged = onAssetsChanged
        _assets = State(initialValue: assets)
        _currentID = State(initialValue: initialAssetID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1.0 - min(dragOffset / 300, 0.5))
                .onDisappear { shareTask?.cancel() }

            ZStack {
                TabView(selection: $currentID) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        FullSizePhotoPage(asset: asset)
                            .tag(asset.localIdentifier)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .allowsHitTesting(!isDismissing)

                VStack {
                    GlassEffectContainer {
                        HStack(spacing: 12) {
                            // Close button. Tap routes through the same
                            // slide-down animation as the swipe-down gesture
                            // (via isDismissing), so the .interactive() press
                            // feedback has time to render — a plain dismiss()
                            // tears the view down instantly.
                            Button {
                                isDismissing = true
                            } label: {
                                GlassCircleIcon(symbol: "xmark")
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Close")

                            Spacer()

                            if !isShowingHidden {
                                Button {
                                    togglePinForCurrentPhoto()
                                } label: {
                                    GlassCircleIcon(symbol: currentPhotoIsPinned ? "pin.fill" : "pin")
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel(currentPhotoIsPinned ? "Unpin photo" : "Pin photo")
                            }

                            // Same control slot, different verb depending on
                            // context: hide (with confirmation) for normal
                            // browsing, restore (instant) when viewing
                            // hidden-photos. The hide alert below is bound to
                            // `showHideConfirmation`, which is only set true
                            // by the hide branch — so it can stay attached
                            // and harmlessly never fire in the restore mode.
                            if isShowingHidden {
                                Button {
                                    unhideCurrentPhoto()
                                } label: {
                                    GlassCircleIcon(symbol: "eye")
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Restore photo to trip")
                            } else {
                                Button {
                                    hideConfirmationID = currentID
                                    showHideConfirmation = true
                                } label: {
                                    GlassCircleIcon(symbol: "eye.slash")
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Hide photo from trip")
                            }

                            Button {
                                shareCurrentPhoto()
                            } label: {
                                GlassCircleIcon(symbol: "square.and.arrow.up")
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Share photo")
                        }
                    }
                    .padding()
                    .opacity(dragOffset > 0 ? max(0, 1 - dragOffset / 100) : 1)

                    Spacer()

                    photoMetadataOverlay
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .opacity(dragOffset > 0 ? max(0, 1 - dragOffset / 100) : 1)
                }
            }
            .offset(y: dragOffset)
        }
        .gesture(
            DismissDragGesture(
                dragOffset: $dragOffset,
                isDismissing: $isDismissing
            )
        )
        .onChange(of: isDismissing) { _, dismissing in
            guard dismissing else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                dragOffset = 1000
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dismiss()
                }
            }
        }
        .onAppear {
            guard pendingPinMutations == 0 else { return }
            pinnedIDs = PhotoService.shared.pinnedIdentifiers(for: tripID)
        }
        // Real-time PhotoKit reactivity: if the user (or a cross-device
        // sync) deletes an asset that's in our local `assets` array while
        // the viewer is open, reconcile so we never present a dead
        // `PHAsset`. The reconciliation engine animates the same way as
        // the hide/unhide flow.
        .onChange(of: PhotoService.shared.changeToken) { _, _ in
            Task { await reconcileAssetsWithLibrary() }
        }
        .alert("Hide Photo?", isPresented: $showHideConfirmation) {
            Button("Hide") {
                // A library change may have moved the selection meanwhile:
                // never hide a photo the user did not confirm.
                if hideConfirmationID == currentID { hideCurrentPhoto() }
                hideConfirmationID = nil
            }
            Button("Cancel", role: .cancel) { hideConfirmationID = nil }
        } message: {
            Text("This photo won't appear in this trip anymore. You can restore it later from Hidden Photos.")
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            // Release the share decode as soon as the sheet closes. `shareImage`
            // is otherwise retained for the rest of the session — a ghost
            // allocation (a multi-MB bitmap) that never gets reclaimed.
            shareImage = nil
        }) {
            if let shareImage {
                PhotoShareSheet(image: shareImage)
            }
        }
        .alert("Couldn't Load Photo", isPresented: $showShareError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This photo isn't available right now. It may still be downloading from iCloud.")
        }
    }

    // MARK: - Derived state

    /// The index of the currently-displayed asset within `assets`, or `nil`
    /// if the selection no longer matches anything (mid-animation transient).
    private var currentIndex: Int? {
        assets.firstIndex(where: { $0.localIdentifier == currentID })
    }

    private var currentAsset: PHAsset? {
        currentIndex.map { assets[$0] }
    }

    private var currentPhotoIsPinned: Bool {
        pinnedIDs.contains(currentID)
    }

    // MARK: - Actions

    private func shareCurrentPhoto() {
        guard let asset = currentAsset else { return }
        shareTask?.cancel()
        shareTask = Task {
            // `loadFullSizeImage` can return nil — the asset's underlying
            // resource may be mid-iCloud-download, deleted concurrently, or
            // simply unavailable offline. Presenting the share sheet with a
            // nil image renders an empty modal that the user has to dismiss
            // manually with no explanation. Guard the presentation and surface
            // an alert instead.
            // Bound the share decode. `PHImageManagerMaximumSize` decodes the
            // native resolution — ~190 MB ARGB for a 48 MP photo — which the
            // in-app share sheet has never needed. 3072² (paired with the
            // `.aspectFit` share loader so aspect is preserved) caps it to
            // ~16-37 MB. A true full-resolution export would be a separate,
            // explicit affordance.
            let image = await PhotoService.shared.loadFullSizeImage(
                for: asset,
                targetSize: CGSize(width: 3072, height: 3072)
            )
            // Dismissal (or a newer share tap) cancelled us — the result
            // belongs to a viewer that no longer exists.
            guard !Task.isCancelled else { return }
            if let image {
                shareImage = image
                showShareSheet = true
            } else {
                showShareError = true
            }
        }
    }

    private func togglePinForCurrentPhoto() {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        pendingPinMutations += 1
        let mutation: Task<Bool, Never>
        if pinnedIDs.contains(id) {
            mutation = PhotoService.shared.unpinPhoto(localIdentifier: id, tripID: tripID)
            pinnedIDs.remove(id)
        } else {
            mutation = PhotoService.shared.pinPhoto(localIdentifier: id, tripID: tripID)
            pinnedIDs.insert(id)
        }
        Task {
            _ = await mutation.value
            pendingPinMutations -= 1
            // Keep later optimistic taps until every submitted write settles.
            guard pendingPinMutations == 0 else { return }
            pinnedIDs = PhotoService.shared.pinnedIdentifiers(for: tripID)
        }
    }

    private func hideCurrentPhoto() {
        advancePastCurrentAsset { id in
            PhotoService.shared.hidePhoto(localIdentifier: id, tripID: tripID)
        }
    }

    /// Inverse of `hideCurrentPhoto()`. Same advance-or-dismiss flow but
    /// calls `PhotoService.unhidePhoto` and skips the confirmation alert
    /// (un-hide is non-destructive — the photo just rejoins the trip's
    /// gallery). Only reachable when the viewer was opened with
    /// `isShowingHidden: true`.
    private func unhideCurrentPhoto() {
        advancePastCurrentAsset { id in
            PhotoService.shared.unhidePhoto(localIdentifier: id, tripID: tripID)
        }
    }

    /// When the system Photo library changes (asset deleted in Photos.app,
    /// limited-library reselect, etc.), our local `assets` array may hold
    /// `PHAsset` references for identifiers that no longer resolve on this
    /// device. Intersect with PhotoKit's current state, advance the
    /// selection to the closest surviving neighbour, and signal the parent
    /// via `onAssetsChanged`. Dismiss if nothing survived.
    private func reconcileAssetsWithLibrary() async {
        let ids = assets.map(\.localIdentifier)
        guard !ids.isEmpty else { return }

        // Off-main: the viewer is seeded with the whole trip's asset set,
        // uncapped, and this re-runs on every `changeToken` bump, so on the
        // main actor it would be a visible hitch while the user swipes
        // photos on a large trip. Only the PhotoKit query moves; all
        // decisions below stay on the main actor.
        let existing: Set<String> = await Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var found = Set<String>()
            result.enumerateObjects { asset, _, _ in
                found.insert(asset.localIdentifier)
            }
            return found
        }.value

        let survivors = assets.filter { existing.contains($0.localIdentifier) }
        // Fast path: nothing was deleted; preserve current state untouched
        // so we don't accidentally animate a no-op (and so we don't bother
        // the parent with a redundant `onAssetsChanged`).
        guard survivors.count != assets.count else { return }

        if survivors.isEmpty {
            onAssetsChanged([])
            isDismissing = true
            return
        }

        let originalIndex = assets.firstIndex(where: { $0.localIdentifier == currentID })
        let nextID: String
        if survivors.contains(where: { $0.localIdentifier == currentID }) {
            // Current asset survives — trim the array, keep the selection.
            nextID = currentID
        } else if let originalIndex {
            // Current asset gone; land on the closest neighbour in the
            // shorter survivor array. `min(originalIndex, count - 1)` falls
            // back to the previous if we were past the new end.
            let nearest = min(originalIndex, survivors.count - 1)
            nextID = survivors[nearest].localIdentifier
        } else {
            // `currentID` wasn't even in `assets` (transient state) — pick
            // the first survivor as a safe default.
            nextID = survivors[0].localIdentifier
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            assets = survivors
            currentID = nextID
        }
        onAssetsChanged(survivors)
    }

    /// Shared "remove the current asset and advance to its neighbour" engine.
    /// Computes the successor's identifier *before* mutating `assets` so the
    /// TabView's selection-by-identifier transitions cleanly with the
    /// animation. If the removed asset was the last one in the gallery,
    /// dismisses the viewer instead.
    private func advancePastCurrentAsset(_ persist: @escaping (String) -> Task<Bool, Never>) {
        guard let index = currentIndex else { return }
        let removedID = assets[index].localIdentifier
        let mutation = persist(removedID)
        Task {
            guard await mutation.value,
                  let index = assets.firstIndex(where: { $0.localIdentifier == removedID }) else { return }

            var newAssets = assets
            newAssets.remove(at: index)

            if newAssets.isEmpty {
                onAssetsChanged([])
                isDismissing = true
                return
            }

            // Land on the next photo, or the previous if we removed the last one.
            let nextIndex = min(index, newAssets.count - 1)
            let nextID = newAssets.contains(where: { $0.localIdentifier == currentID })
                ? currentID : newAssets[nextIndex].localIdentifier

            withAnimation(.easeInOut(duration: 0.2)) {
                assets = newAssets
                currentID = nextID
            }
            onAssetsChanged(newAssets)
        }
    }

    @ViewBuilder
    private var photoMetadataOverlay: some View {
        // Resolve the selection ONCE — `currentAsset` re-runs the
        // `currentIndex` scan (computed properties don't memoize), and this
        // overlay re-renders on every drag tick.
        if let index = currentIndex {
            let asset = assets[index]
            VStack(alignment: .leading, spacing: 4) {
                if let date = asset.creationDate {
                    Text(date.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.white)
                }

                Text(index == 0
                     ? String(localized: "photo-viewer.position.one", defaultValue: "\(index + 1, format: .number.grouping(.never)) of \(assets.count, format: .number.grouping(.never))", comment: "Photo viewer position when showing the first photo.")
                     : String(localized: "photo-viewer.position.other", defaultValue: "\(index + 1, format: .number.grouping(.never)) of \(assets.count, format: .number.grouping(.never))", comment: "Photo viewer position when showing a later photo."))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
    }
}

// MARK: - Glass Circle Icon
//
// One helper, one set of constants, every glass button in the viewer renders
// identically. 17pt `.semibold` matches the SF Symbol weight used by the
// system nav-bar back chevron in iOS 26. The 28pt outer frame produces a
// glass circle close to Apple's standard 44pt tap target after `.glass`
// chrome — visually consistent with iOS Photos.app's full-screen viewer.

private struct GlassCircleIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
    }
}

// MARK: - Full Size Photo Page

private struct FullSizePhotoPage: View {

    let asset: PHAsset

    @State private var image: UIImage?
    @State private var isLoadingFullResolution = false
    @State private var didStartLoading = false

    // In-flight PhotoKit request tracking. Without
    // cancellation, fast swiping through a large gallery piles up network-
    // enabled full-res requests that delay the visible page's load and
    // accumulate 4096-box decodes. Mirrors `PhotoThumbnailView`'s pattern.
    // `loadGeneration` invalidates completions that race past a cancel:
    // a cancelled request may still deliver one final callback (Apple
    // documents both "handler may not be called at all" and a final call
    // with `PHImageCancelledKey` — handle both), and that callback must
    // not restart the preview→full-res chain on a disappeared page.
    @State private var previewRequestID: PHImageRequestID?
    @State private var fullResRequestID: PHImageRequestID?
    @State private var loadGeneration = 0

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }

            if isLoadingFullResolution {
                ProgressView()
                    .tint(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: .circle)
            }
        }
        .onAppear { loadImageIfNeeded() }
        .onDisappear { cancelInFlightLoads() }
    }

    private func loadImageIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        loadPreview()
    }

    /// Cancel whatever is still in flight when the page swipes offscreen,
    /// re-arm the load chain so a re-appearing page restarts the load, and
    /// RELEASE the decoded image.
    ///
    /// TabView (page style) keeps every visited page mounted, so without this
    /// each swiped-past page retained its full-res decode (~38-67 MB) for the
    /// life of the viewer — a 20-photo browse could hold a gigabyte. We now
    /// drop `image` on disappear; `loadImageIfNeeded` re-arms via
    /// `didStartLoading == false` and reloads on re-appear (a brief
    /// `ProgressView` flash on swipe-back, matching the existing
    /// cancel-on-disappear UX). This bounds resident page decodes to the set
    /// the user is actually looking at.
    private func cancelInFlightLoads() {
        loadGeneration += 1
        if let id = previewRequestID {
            PhotoService.shared.cancelImageRequest(id)
            previewRequestID = nil
        }
        if let id = fullResRequestID {
            PhotoService.shared.cancelImageRequest(id)
            fullResRequestID = nil
        }
        didStartLoading = false
        isLoadingFullResolution = false
        image = nil
    }

    private func loadPreview() {
        let generation = loadGeneration
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        // Bound the preview decode to ~600².
        options.resizeMode = .fast

        previewRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 600, height: 600),
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            Task { @MainActor in
                guard generation == self.loadGeneration else { return }
                self.previewRequestID = nil
                if let result {
                    self.image = result
                }
                self.isLoadingFullResolution = true
                self.loadFullResolution()
            }
        }
    }

    private func loadFullResolution() {
        let generation = loadGeneration
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        // `.exact`: this is an `.aspectFit` request with a precise bounding box,
        // so exact resizing honors the box without distortion (no square crop).
        // Without it, PhotoKit may decode well past the target.
        options.resizeMode = .exact

        // Cap the decode to a bounded box rather than PHImageManagerMaximumSize.
        // The latter decodes the asset at full native resolution — roughly
        // 190 MB in memory for a 48 MP photo — which can spike memory and get
        // the app jettisoned. A 3072-box `.aspectFit` keeps zoomed detail crisp
        // at typical viewing (and well past 1× across the screen at the 4× max
        // zoom) while bounding the decode to ≤ ~38 MB.
        fullResRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 3072, height: 3072),
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            Task { @MainActor in
                guard generation == self.loadGeneration else { return }
                self.fullResRequestID = nil
                if let result {
                    self.image = result
                }
                self.isLoadingFullResolution = false
            }
        }
    }
}

// MARK: - Zoomable Image View
//
// UIScrollView-backed pinch + pan + double-tap zoom for a single photo page.
// Wrapped in UIViewRepresentable rather than reimplemented in SwiftUI because
// UIScrollView already handles bounds clipping, momentum, rubber-banding, and
// gesture coordination with surrounding recognizers — and crucially,
// `DismissDragGesture.Coordinator.gestureRecognizer(_:shouldBeRequiredToFailBy:)`
// already returns true for any UIScrollView in the hierarchy, so a pan inside
// this view automatically prevents the viewer's swipe-down-to-dismiss from
// firing. TabView paging defers to the inner scroll view's pan only when there
// is horizontal slack (i.e. zoomed in), so paging stays live at zoom = 1.

private struct ZoomableImageView: UIViewRepresentable {

    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // Stay quiescent at zoom = 1 so DismissDragGesture and TabView paging
        // see no competition from the scroll view's pan recognizer.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        // Pin the image view to the scroll view's content layout guide on all
        // four edges, then constrain its width / height equal to the scroll
        // view's frame layout guide. At zoom = 1 the image view fills the
        // scroll view's bounds (letterboxed by .scaleAspectFit); at zoom > 1
        // the image view scales via UIScrollView's zoom transform.
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // Identity check, not pixel equality: PHImageManager hands us a fresh
        // UIImage when the full-resolution result arrives. Swapping it
        // preserves the user's current zoomScale and contentOffset so a mid-
        // pinch transition from preview to full-res doesn't jolt.
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > 1.001 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let targetScale: CGFloat = 2.5
                let location = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(
                    x: location.x - width / 2,
                    y: location.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - Share Sheet

private struct PhotoShareSheet: UIViewControllerRepresentable {

    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Dismiss Drag Gesture

private struct DismissDragGesture: UIGestureRecognizerRepresentable {

    @Binding var dragOffset: CGFloat
    @Binding var isDismissing: Bool

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        guard !isDismissing else { return }

        switch recognizer.state {
        case .changed:
            let translation = recognizer.translation(in: recognizer.view)
            if translation.y > 0 {
                dragOffset = translation.y
            }
        case .ended, .cancelled:
            if dragOffset > 120 {
                isDismissing = true
            } else {
                withAnimation(.spring) {
                    dragOffset = 0
                }
            }
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
