import Testing
@testable import TravelLog

/// The Map tab's empty-state copy claims "nothing explored", so it must only
/// appear after a read actually succeeded with zero overlays. A pending or
/// failed first read is not absence.
struct HexMapEmptyStateTests {
    // `HexMapView.showsEmptyState` is main-actor isolated (app default isolation).
    @Test @MainActor func hiddenBeforeFirstSuccessfulLoad() {
        #expect(!HexMapView.showsEmptyState(hasLoaded: false, overlayCount: 0))
    }

    @Test @MainActor func shownForLoadedEmptyHistory() {
        #expect(HexMapView.showsEmptyState(hasLoaded: true, overlayCount: 0))
    }

    @Test @MainActor func hiddenWhenOverlaysExist() {
        #expect(!HexMapView.showsEmptyState(hasLoaded: true, overlayCount: 5))
    }
}
