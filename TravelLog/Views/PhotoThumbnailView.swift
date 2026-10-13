import SwiftUI
import Photos

struct PhotoThumbnailView: View {

    let asset: PHAsset
    let targetSize: CGSize

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isDegraded = false

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
            .onAppear {
                guard Self.shouldRequest(hasImage: image != nil, isDegraded: isDegraded) else { return }
                if let requestID { PhotoService.shared.cancelImageRequest(requestID) }
                requestID = PhotoService.shared.loadThumbnail(for: asset, targetSize: targetSize) { loaded, degraded in
                    Task { @MainActor in
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
                if let requestID {
                    PhotoService.shared.cancelImageRequest(requestID)
                    self.requestID = nil
                }
            }
    }
}

