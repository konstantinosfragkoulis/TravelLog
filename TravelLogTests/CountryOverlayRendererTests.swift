import Testing
import MapKit
@testable import TravelLog

nonisolated struct CountryOverlayRendererTests {
    @Test("Country polygons draw when either projected dimension reaches half a point")
    func subpixelPolygons() {
        let zoomScale = 0.01
        #expect(!CountryOverlayRenderer.shouldDraw(
            bounds: MKMapRect(x: 0, y: 0, width: 30, height: 30), zoomScale: zoomScale
        ))
        #expect(CountryOverlayRenderer.shouldDraw(
            bounds: MKMapRect(x: 0, y: 0, width: 60, height: 30), zoomScale: zoomScale
        ))
        #expect(CountryOverlayRenderer.shouldDraw(
            bounds: MKMapRect(x: 0, y: 0, width: 10_000, height: 10_000), zoomScale: zoomScale
        ))
    }
}
