import MapKit
import CoreGraphics
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

/// Background tile draws read one immutable snapshot from the map's only overlay.
nonisolated final class CountryOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var frame = CountryOverlayFrame.empty

    func publish(_ frame: CountryOverlayFrame) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func currentFrame() -> CountryOverlayFrame {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

nonisolated final class CountryOverlayRenderer: MKOverlayRenderer {
    /// A projected bounding box under half a point in both dimensions is invisible.
    static func shouldDraw(bounds: MKMapRect, zoomScale: Double) -> Bool {
        bounds.width * zoomScale >= 0.5 || bounds.height * zoomScale >= 0.5
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let frame = (overlay as! CountryOverlay).currentFrame()
        guard zoomScale.isFinite, zoomScale > 0 else { return }
        let pad = 1 / Double(zoomScale) + 1
        let query = mapRect.insetBy(dx: -pad, dy: -pad)

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        context.setFillColor(
            red: CGFloat(frame.fill.r), green: CGFloat(frame.fill.g),
            blue: CGFloat(frame.fill.b), alpha: CGFloat(frame.fill.a)
        )
        context.setStrokeColor(
            red: CGFloat(frame.stroke.r), green: CGFloat(frame.stroke.g),
            blue: CGFloat(frame.stroke.b), alpha: CGFloat(frame.stroke.a)
        )
        context.setLineWidth(1 / zoomScale)

        // Natural Earth polygons are split at the antimeridian; the decoder's
        // absolute map points need no unwrapping or additional world copies.
        for country in frame.polygons {
            let polygon = country.polygon
            let bounds = polygon.boundingMapRect
            guard bounds.intersects(query),
                  Self.shouldDraw(bounds: bounds, zoomScale: Double(zoomScale)) else { continue }
            context.beginPath()
            addRing(polygon, to: context)
            for interior in polygon.interiorPolygons ?? [] {
                addRing(interior, to: context)
            }
            context.drawPath(using: .eoFillStroke)
        }
    }

    private func addRing(_ polygon: MKPolygon, to context: CGContext) {
        guard polygon.pointCount >= 3 else { return }
        let points = polygon.points()
        context.move(to: point(for: points[0]))
        for index in 1..<polygon.pointCount {
            context.addLine(to: point(for: points[index]))
        }
        context.closePath()
    }
}
