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

    /// Request again on reappear while only the degraded bitmap arrived: the
    /// disappear cancel stops the final delivery, which otherwise never comes.
    nonisolated static func shouldRequest(hasImage: Bool, isDegraded: Bool) -> Bool {
        !hasImage || isDegraded
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
                guard Self.shouldRequest(hasImage: image != nil, isDegraded: isDegraded) else { return }
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
            .onDisappear {
                // Cancel the in-flight thumbnail request when the cell scrolls
                // offscreen so fast scrolling doesn't pile up PhotoKit requests.
                loadGeneration += 1
                if let requestID {
                    PhotoService.shared.cancelImageRequest(requestID)
                    self.requestID = nil
                }
                image = nil
                isDegraded = false
            }
    }
}

