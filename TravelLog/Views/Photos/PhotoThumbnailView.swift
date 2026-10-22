import SwiftUI
import Photos

struct PhotoThumbnailView: View {

    /// The design system's two thumbnail radii; galleries tile square.
    enum Corners {
        case square
        /// 80 pt and up.
        case large
        /// Under 60 pt.
        case small

        var radius: CGFloat {
            switch self {
            case .square: 0
            case .large: AppTheme.thumbLarge
            case .small: AppTheme.thumbSmall
            }
        }
    }

    let asset: PHAsset
    let targetSize: CGSize
    var corners: Corners = .square

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isDegraded = false
    @State private var loadGeneration = 0
    @State private var isVisible = false

    /// Request again on reappear while only the degraded bitmap arrived: the
    /// disappear cancel stops the final delivery, which otherwise never comes.
    nonisolated static func shouldRequest(hasImage: Bool, isDegraded: Bool) -> Bool {
        !hasImage || isDegraded
    }

    /// What the cell's pixels show: the photo and its last edit. A gallery
    /// refetch after an edit in Photos (a crop, a rotation) keeps the cell's
    /// identity but hands it a newer revision, so the cell loads again.
    nonisolated struct ContentRevision: Equatable {
        let localIdentifier: String
        let modificationDate: Date?
    }

    /// A visible cell whose photo changed reloads; an unchanged revision, or
    /// a cell off screen (it loads on its next appearance), does not.
    nonisolated static func shouldReload(from old: ContentRevision, to new: ContentRevision, isVisible: Bool) -> Bool {
        isVisible && old != new
    }

    private var revision: ContentRevision {
        ContentRevision(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: corners.radius))
            .onAppear {
                isVisible = true
                guard Self.shouldRequest(hasImage: image != nil, isDegraded: isDegraded) else { return }
                load()
            }
            .onChange(of: revision) { old, new in
                guard Self.shouldReload(from: old, to: new, isVisible: isVisible) else { return }
                // The old pixels go at once: an edit may have cropped
                // something out, so they must not linger while the new load
                // is in flight. The new generation fences off the old request.
                image = nil
                isDegraded = false
                load()
            }
            .onDisappear {
                // Cancel the in-flight thumbnail request when the cell scrolls
                // offscreen so fast scrolling doesn't pile up PhotoKit requests.
                isVisible = false
                loadGeneration += 1
                if let requestID {
                    PhotoService.shared.cancelImageRequest(requestID)
                    self.requestID = nil
                }
                image = nil
                isDegraded = false
            }
    }

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        if let requestID { PhotoService.shared.cancelImageRequest(requestID) }
        requestID = PhotoService.shared.loadThumbnail(for: asset, targetSize: targetSize) { loaded, degraded in
            Task { @MainActor in
                guard generation == self.loadGeneration else { return }
                // Never let a nil result erase an image we already have.
                // The request uses `.opportunistic` delivery, so the
                // handler fires more than once: a fast degraded bitmap
                // first, then the final one — and that final call
                // delivers nil when the request was cancelled or the
                // iCloud fetch failed. Assigning it would blank a
                // thumbnail the user can already see, leaving a grey
                // tile until the cell is recycled.
                guard let loaded else { return }
                // A late degraded bitmap must not replace a final one.
                if degraded, self.image != nil, !self.isDegraded { return }
                self.image = loaded
                self.isDegraded = degraded
            }
        }
    }
}

