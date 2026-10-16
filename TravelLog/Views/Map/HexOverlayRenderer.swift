import MapKit
import CoreGraphics
import Foundation

nonisolated struct HexRGBA: Sendable, Equatable {
    let r, g, b, a: Double

    /// The same colour with its alpha scaled by `opacity`.
    func withOpacity(_ opacity: Double) -> HexRGBA {
        HexRGBA(r: r, g: g, b: b, a: a * opacity)
    }
}

nonisolated struct HexCellGeometry: Sendable {
    let id: String
    /// Vertices unwrapped around the cell's centre longitude.
    let ring: [MKMapPoint]
    let center: MKMapPoint
    let bounds: MKMapRect
    let diameter: Double
}

nonisolated struct HexCellPaint: Sendable, Equatable {
    let fill: HexRGBA
    let stroke: HexRGBA
    let emphasized: Bool
}

nonisolated struct HexOverlayFrame: Sendable {
    let generation: Int
    let cells: [HexCellGeometry]
    /// Same count and order as `cells`.
    let paints: [HexCellPaint]

    static let empty = HexOverlayFrame(generation: 0, cells: [], paints: [])
}

nonisolated enum HexGeometryBuilder {
    static func build(_ overlays: [HexOverlayData]) -> [HexCellGeometry] {
        return overlays.map { overlay in
            let centerLongitude = overlay.centerLongitude
            let center = project(latitude: overlay.centerLatitude, longitude: centerLongitude)
            let ring = overlay.boundary.map { vertex in
                project(
                    latitude: vertex.latitude,
                    longitude: centerLongitude + GeoMath.wrappedLongitudeDelta(vertex.longitude, centerLongitude)
                )
            }
            let first = ring.first ?? center
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            var diameter = 0.0
            for (index, vertex) in ring.enumerated() {
                minX = min(minX, vertex.x)
                maxX = max(maxX, vertex.x)
                minY = min(minY, vertex.y)
                maxY = max(maxY, vertex.y)
                for other in ring.dropFirst(index + 1) {
                    diameter = max(diameter, hypot(vertex.x - other.x, vertex.y - other.y))
                }
            }
            return HexCellGeometry(
                id: overlay.id,
                ring: ring,
                center: center,
                bounds: MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                diameter: diameter
            )
        }
    }

    private static func project(latitude: Double, longitude: Double) -> MKMapPoint {
        MKMapPoint(
            x: (longitude + 180) / 360 * MKMapSize.world.width,
            y: MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 0)).y
        )
    }
}

/// The map retains one overlay. Background tile draws read one immutable frame.
nonisolated final class HexOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var frame = HexOverlayFrame.empty

    func publish(_ frame: HexOverlayFrame) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func currentFrame() -> HexOverlayFrame {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

nonisolated final class HexOverlayRenderer: MKOverlayRenderer {
    nonisolated enum LOD: Sendable, Equatable {
        case disc, fillAndStroke
    }

    /// Cells keep their outline at every size the hexagon shape is still
    /// discernible (the old per-polygon map drew fill + 0.8 pt stroke at any
    /// zoom, and dropping the outline below 6 pt read as blur). Below 2 pt
    /// the shape is gone and a fixed-size disc marks the location instead.
    static func lod(diameterPoints: Double) -> LOD {
        if diameterPoints < 2 { return .disc }
        return .fillAndStroke
    }

    static func footprint(for cell: HexCellGeometry, zoomScale: MKZoomScale) -> MKMapRect {
        guard lod(diameterPoints: cell.diameter * Double(zoomScale)) == .disc else {
            return cell.bounds
        }
        let radius = 1.5 / Double(zoomScale)
        return MKMapRect(
            x: cell.center.x - radius, y: cell.center.y - radius,
            width: radius * 2, height: radius * 2
        )
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let frame = (overlay as! HexOverlay).currentFrame()
        guard zoomScale.isFinite, zoomScale > 0 else { return }
        // Keep a conservative margin for polygon strokes and tile-edge rounding.
        let pad = 1.5 / Double(zoomScale) + 1
        let query = mapRect.insetBy(dx: -pad, dy: -pad)
        let worldWidth = MKMapSize.world.width

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))

        // Stable loader order within each pass; marked cells stay on top.
        for emphasized in [false, true] {
            for (cell, paint) in zip(frame.cells, frame.paints) {
                guard paint.emphasized == emphasized, !cell.ring.isEmpty else { continue }
                let footprint = Self.footprint(for: cell, zoomScale: zoomScale)
                if footprint.intersects(query) {
                    draw(
                        cell, paint: paint, footprint: footprint, shiftX: 0,
                        zoomScale: zoomScale, in: context
                    )
                }
                if footprint.minX < 0 || footprint.maxX > worldWidth {
                    for shiftX in [-worldWidth, worldWidth] {
                        let shiftedBounds = MKMapRect(
                            x: footprint.minX + shiftX, y: footprint.minY,
                            width: footprint.width, height: footprint.height
                        )
                        if shiftedBounds.intersects(query) {
                            draw(
                                cell, paint: paint, footprint: shiftedBounds, shiftX: shiftX,
                                zoomScale: zoomScale, in: context
                            )
                        }
                    }
                }
            }
        }
    }

    private func draw(
        _ cell: HexCellGeometry, paint: HexCellPaint, footprint: MKMapRect, shiftX: Double,
        zoomScale: MKZoomScale, in context: CGContext
    ) {
        context.setFillColor(
            red: CGFloat(paint.fill.r), green: CGFloat(paint.fill.g),
            blue: CGFloat(paint.fill.b), alpha: CGFloat(paint.fill.a)
        )
        let detail = Self.lod(diameterPoints: cell.diameter * Double(zoomScale))
        if detail == .disc {
            context.fillEllipse(in: rect(for: footprint))
            return
        }

        context.beginPath()
        for (index, vertex) in cell.ring.enumerated() {
            let vertexPoint = point(for: MKMapPoint(x: vertex.x + shiftX, y: vertex.y))
            if index == 0 {
                context.move(to: vertexPoint)
            } else {
                context.addLine(to: vertexPoint)
            }
        }
        context.closePath()
        context.setStrokeColor(
            red: CGFloat(paint.stroke.r), green: CGFloat(paint.stroke.g),
            blue: CGFloat(paint.stroke.b), alpha: CGFloat(paint.stroke.a)
        )
        // Highlighted cells share the accent with the rest, so their
        // heavier outline is part of what sets them apart.
        context.setLineWidth((paint.emphasized ? 2 : 0.8) / zoomScale)
        context.drawPath(using: .fillStroke)
    }
}
