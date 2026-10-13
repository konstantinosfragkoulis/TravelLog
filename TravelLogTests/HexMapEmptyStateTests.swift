import Testing
@testable import TravelLog

/// The Map tab's empty-state copy claims "nothing explored", so it must only
/// appear after a read actually succeeded with zero overlays. A pending or
/// failed first read is not absence.
struct HexMapEmptyStateTests {
    @Test func hiddenBeforeFirstSuccessfulLoad() {
        #expect(!HexMapView.showsEmptyState(hasLoaded: false, overlayCount: 0))
    }

    @Test func shownForLoadedEmptyHistory() {
        #expect(HexMapView.showsEmptyState(hasLoaded: true, overlayCount: 0))
    }

    @Test func hiddenWhenOverlaysExist() {
        #expect(!HexMapView.showsEmptyState(hasLoaded: true, overlayCount: 5))
    }
}
