import Testing
import MapKit
import Foundation
@testable import TravelLog

nonisolated struct HexOverlayGeometryTests {
    @Test("Geometry preserves loader order/count and projects a mid-longitude centre")
    func orderAndCenter() throws {
        let center = CLLocationCoordinate2D(latitude: 37.9838, longitude: 23.7275)
        let boundary = [
            CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
            CLLocationCoordinate2D(latitude: 37.99, longitude: 23.72),
            CLLocationCoordinate2D(latitude: 37.99, longitude: 23.74),
            CLLocationCoordinate2D(latitude: 37.98, longitude: 23.74)
        ]
        let overlays = ["second", "first"].map { id in
            HexOverlayData(
                id: id, boundary: boundary, visitCount: 2,
                centerLatitude: center.latitude, centerLongitude: center.longitude
            )
        }
        let cells = HexGeometryBuilder.build(overlays)
        #expect(cells.count == overlays.count)
        #expect(cells.map(\.id) == ["second", "first"])
        let cell = try #require(cells.first)
        let expected = MKMapPoint(center)
        #expect(abs(cell.center.x - expected.x) < 1e-6)
        #expect(abs(cell.center.y - expected.y) < 1e-6)
        #expect(cell.ring.count == boundary.count)
        #expect(cell.bounds.minX >= 0 && cell.bounds.maxX <= MKMapSize.world.width)
        #expect(HexGeometryBuilder.build([]).isEmpty)
    }

    @Test("Dateline rings unwrap to a small seam-crossing box", arguments: [179.95, -179.95])
    func dateline(centerLongitude: Double) throws {
        let overlay = HexOverlayData(
            id: "seam",
            boundary: [
                CLLocationCoordinate2D(latitude: 10, longitude: 179.9),
                CLLocationCoordinate2D(latitude: 10.02, longitude: 179.9),
                CLLocationCoordinate2D(latitude: 10.02, longitude: -179.9),
                CLLocationCoordinate2D(latitude: 10, longitude: -179.9)
            ],
            visitCount: 1, centerLatitude: 10.01, centerLongitude: centerLongitude
        )
        let cell = try #require(HexGeometryBuilder.build([overlay]).first)
        let worldWidth = MKMapSize.world.width
        #expect(cell.bounds.width < worldWidth * 0.001)
        #expect(abs(cell.bounds.width - 0.2 / 360 * worldWidth) < 1e-6)
        if centerLongitude > 0 {
            #expect(cell.bounds.maxX > worldWidth)
        } else {
            #expect(cell.bounds.minX < 0)
        }
    }

    @Test("Initial content fit shares a narrow longitude interval across the dateline")
    func datelineContentFit() {
        let overlays = [179.5, -179.5].map { longitude in
            HexOverlayData(
                id: String(longitude),
                boundary: [
                    CLLocationCoordinate2D(latitude: 10, longitude: longitude - 0.1),
                    CLLocationCoordinate2D(latitude: 10.2, longitude: longitude - 0.1),
                    CLLocationCoordinate2D(latitude: 10.2, longitude: longitude + 0.1),
                    CLLocationCoordinate2D(latitude: 10, longitude: longitude + 0.1)
                ],
                visitCount: 1, centerLatitude: 10.1, centerLongitude: longitude
            )
        }
        let rect = HexNativeMap.fitRect(for: HexGeometryBuilder.build(overlays))
        #expect(!rect.isNull)
        #expect(rect.width > 0 && rect.height > 0)
        #expect(rect.width < MKMapSize.world.width * 0.1)
        #expect(abs(rect.width - 1.2 / 360 * MKMapSize.world.width * 1.4) < 1e-6)
        #expect(rect.maxX > MKMapSize.world.width)
    }

    @Test("LOD switches from discs to outlined cells at two screen points")
    func levelOfDetail() {
        #expect(HexOverlayRenderer.lod(diameterPoints: 1.99) == .disc)
        #expect(HexOverlayRenderer.lod(diameterPoints: 2) == .fillAndStroke)
        #expect(HexOverlayRenderer.lod(diameterPoints: 5.99) == .fillAndStroke)
        #expect(HexOverlayRenderer.lod(diameterPoints: 6) == .fillAndStroke)
    }

    @Test("Disc footprints wrap interior polygons at both world edges", arguments: [false, true])
    func discFootprintWraps(eastEdge: Bool) {
        let worldWidth = MKMapSize.world.width
        let cell = footprintCell(centerX: eastEdge ? worldWidth - 12 : 12)
        let zoomScale = 0.05
        #expect(cell.bounds.minX > 0 && cell.bounds.maxX < worldWidth)
        #expect(HexOverlayRenderer.lod(diameterPoints: cell.diameter * zoomScale) == .disc)

        let footprint = HexOverlayRenderer.footprint(for: cell, zoomScale: zoomScale)
        #expect(footprint.minX < 0 || footprint.maxX > worldWidth)
        let shifted = MKMapRect(
            x: footprint.minX + (eastEdge ? -worldWidth : worldWidth),
            y: footprint.minY, width: footprint.width, height: footprint.height
        )
        let oppositeTile = MKMapRect(
            x: eastEdge ? 0 : worldWidth - 16, y: cell.center.y - 4,
            width: 16, height: 8
        )
        #expect(shifted.intersects(oppositeTile))
        #expect(abs(footprint.width * zoomScale - 3) < 1e-10)
        #expect(abs(footprint.height * zoomScale - 3) < 1e-10)
    }

    @Test("Interior disc footprints need no seam copy")
    func interiorDiscFootprint() {
        let worldWidth = MKMapSize.world.width
        let cell = footprintCell(centerX: worldWidth / 2)
        let footprint = HexOverlayRenderer.footprint(for: cell, zoomScale: 0.05)
        #expect(footprint.minX >= 0 && footprint.maxX <= worldWidth)
        #expect(!footprint.intersects(MKMapRect(x: 0, y: cell.center.y - 4, width: 16, height: 8)))
        #expect(!footprint.intersects(MKMapRect(
            x: worldWidth - 16, y: cell.center.y - 4, width: 16, height: 8
        )))
    }

    @Test("Disc footprints reach tiles beyond polygon bounds", arguments: [0.000001, 0.01, 0.05, 0.07])
    func discFootprintReachesTile(zoomScale: Double) {
        let cell = footprintCell(centerX: MKMapSize.world.width / 2)
        #expect(HexOverlayRenderer.lod(diameterPoints: cell.diameter * zoomScale) == .disc)
        let radius = 1.5 / zoomScale
        let tile = MKMapRect(
            x: cell.center.x + radius - 1, y: cell.center.y - 1, width: 2, height: 2
        )
        #expect(!cell.bounds.intersects(tile))
        #expect(cell.bounds.intersects(tile.insetBy(dx: -(radius + 1), dy: -(radius + 1))))
        #expect(HexOverlayRenderer.footprint(for: cell, zoomScale: zoomScale).intersects(tile))
    }

    @Test("Outlined cell footprints retain polygon bounds at and above the LOD threshold",
          arguments: [2.0, 6.0])
    func polygonFootprint(diameterPoints: Double) {
        let cell = footprintCell(centerX: 12)
        let footprint = HexOverlayRenderer.footprint(
            for: cell, zoomScale: diameterPoints / cell.diameter
        )
        #expect(footprint.minX == cell.bounds.minX)
        #expect(footprint.minY == cell.bounds.minY)
        #expect(footprint.width == cell.bounds.width)
        #expect(footprint.height == cell.bounds.height)
        #expect(footprint.minX > 0)
    }

    private func footprintCell(centerX: Double) -> HexCellGeometry {
        let center = MKMapPoint(x: centerX, y: MKMapSize.world.height / 2)
        let bounds = MKMapRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        return HexCellGeometry(
            id: "footprint", ring: [
                MKMapPoint(x: bounds.minX, y: bounds.minY),
                MKMapPoint(x: bounds.maxX, y: bounds.minY),
                MKMapPoint(x: bounds.maxX, y: bounds.maxY),
                MKMapPoint(x: bounds.minX, y: bounds.maxY)
            ],
            center: center, bounds: bounds, diameter: hypot(20, 20)
        )
    }

    @Test("A regular projected hexagon has diameter twice its circumradius")
    func regularHexagonDiameter() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 38, longitude: 24)
        let center = MKMapPoint(coordinate)
        let radius = 1_024.0
        // Hand-built regular ring in map points, converted to loader coordinates.
        let boundary = (0..<6).map { index in
            let angle = Double(index) * .pi / 3
            return MKMapPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            ).coordinate
        }
        let overlay = HexOverlayData(
            id: "regular", boundary: boundary, visitCount: 1,
            centerLatitude: coordinate.latitude, centerLongitude: coordinate.longitude
        )
        let cell = try #require(HexGeometryBuilder.build([overlay]).first)
        #expect(abs(cell.diameter - 2 * radius) < 1e-6)
    }
}
