import Testing
@testable import TravelLog

struct PhotoThumbnailViewTests {

    @Test func requestsWhenEmptyOrDegradedOnly() {
        #expect(PhotoThumbnailView.shouldRequest(hasImage: false, isDegraded: false))
        #expect(PhotoThumbnailView.shouldRequest(hasImage: true, isDegraded: true))
        #expect(!PhotoThumbnailView.shouldRequest(hasImage: true, isDegraded: false))
    }
}
