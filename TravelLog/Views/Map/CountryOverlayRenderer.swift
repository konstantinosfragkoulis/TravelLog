import MapKit
import Foundation

nonisolated struct CountryOverlayFrame: Sendable {
    let generation: Int
    let polygons: [CountryPolygonProvider.CountryPolygon]
    let fill: HexRGBA
    let stroke: HexRGBA

    static let empty = CountryOverlayFrame(
        generation: 0, polygons: [],
        fill: HexRGBA(r: 0, g: 0, b: 0, a: 0),
        stroke: HexRGBA(r: 0, g: 0, b: 0, a: 0)
    )
}

/// The visited countries as one MapKit vector overlay, so fills and borders
/// stay sharp at every zoom. A colour change restyles the renderer; only a
/// change of countries replaces the overlay.
final class CountryOverlayLayer {
    /// The border width, in points.
    nonisolated static let lineWidth: CGFloat = 1.5

    private(set) var overlay: MKMultiPolygon?
    private var renderer: MKMultiPolygonRenderer?
    private var countryIDs: [String] = []

    /// One shape for every country polygon (holes included); nil when there
    /// are none. Natural Earth polygons are split at the antimeridian, so
    /// their absolute map points need no unwrapping.
    nonisolated static func shape(for polygons: [CountryPolygonProvider.CountryPolygon]) -> MKMultiPolygon? {
        polygons.isEmpty ? nil : MKMultiPolygon(polygons.map(\.polygon))
    }

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        overlay === self.overlay ? renderer : nil
    }

    func publish(_ frame: CountryOverlayFrame, on map: MKMapView) {
        let ids = frame.polygons.map(\.id)
        if ids != countryIDs {
            countryIDs = ids
            let previous = overlay
            overlay = Self.shape(for: frame.polygons)
            renderer = overlay.map { MKMultiPolygonRenderer(multiPolygon: $0) }
            style(frame)
            // The new shape goes in before the old leaves, so nothing blinks.
            if let overlay { map.addOverlay(overlay, level: .aboveRoads) }
            if let previous { map.removeOverlay(previous) }
        } else {
            style(frame)
            renderer?.setNeedsDisplay()
        }
    }

    private func style(_ frame: CountryOverlayFrame) {
        guard let renderer else { return }
        renderer.shouldRasterize = false
        renderer.fillColor = frame.fill.uiColor
        renderer.strokeColor = frame.stroke.uiColor
        renderer.lineWidth = Self.lineWidth
        renderer.lineJoin = .round
    }
}
