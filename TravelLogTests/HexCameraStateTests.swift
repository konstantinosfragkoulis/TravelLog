import Testing
import MapKit
@testable import TravelLog

nonisolated struct HexCameraStateTests {
    @Test("My Location supersedes a gesture before cells arrive")
    func followAfterGestureBeforeCells() {
        var state = HexCameraState()
        state.userInteracted = true
        state.apply(.followUser(animated: true))
        let emptyFit = state.fitContentIfNeeded(hasCells: false, hasLocation: false)
        #expect(!emptyFit)
        let contentFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(contentFit)
        let restoredFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(restoredFollow)
    }

    @Test("My Location with existing cells fits once and restores a later fix")
    func followAfterGestureWithCells() {
        var state = HexCameraState()
        let initialFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(initialFit)
        let initialFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(initialFollow)
        state.userInteracted = true
        state.apply(.followUser(animated: true))
        let requestedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(requestedFit)
        let repeatedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(!repeatedFit)
        let requestedFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(requestedFollow)
        let repeatedFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(!repeatedFollow)
    }

    @Test("Explicit framing suppresses fallback until a newer My Location request")
    func followAfterExplicitFraming() {
        var state = HexCameraState()
        state.apply(.region(MKCoordinateRegion(), animated: false))
        let framedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(!framedFit)
        let framedFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(!framedFollow)
        state.apply(.followUser(animated: true))
        let requestedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(requestedFit)
        let requestedFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(requestedFollow)
    }

    @Test("A newer gesture still wins over pending content and location")
    func gestureAfterFollow() {
        var state = HexCameraState()
        state.apply(.followUser(animated: true))
        state.userInteracted = true
        let gestureFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(!gestureFit)
        let gestureFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(!gestureFollow)
    }

    @Test("Initial fallback waits for content, fits once and restores follow once")
    func initialFallback() {
        var state = HexCameraState()
        let emptyFit = state.fitContentIfNeeded(hasCells: false, hasLocation: false)
        #expect(!emptyFit)
        let locatedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: true)
        #expect(!locatedFit)
        let contentFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(contentFit)
        let repeatedFit = state.fitContentIfNeeded(hasCells: true, hasLocation: false)
        #expect(!repeatedFit)
        let missingLocationFollow = state.restoreFollowIfNeeded(hasLocation: false, trackingIsNone: true)
        #expect(!missingLocationFollow)
        let alreadyFollowing = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: false)
        #expect(!alreadyFollowing)
        let restoredFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(restoredFollow)
        let repeatedFollow = state.restoreFollowIfNeeded(hasLocation: true, trackingIsNone: true)
        #expect(!repeatedFollow)
    }
}
