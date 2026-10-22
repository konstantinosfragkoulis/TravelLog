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

    @Test("Cells under two points show as discs; tiers step the blend in sixteenths")
    func levelOfDetail() {
        #expect(HexOverlayStyle.showsDiscs(diameterPoints: 1.99))
        #expect(!HexOverlayStyle.showsDiscs(diameterPoints: 2))
        #expect(HexOverlayStyle.tier(diameterPoints: 26, zoomScale: 0.01) == HexZoomTier(blendStep: 0, lod: .hexes))
        #expect(HexOverlayStyle.tier(diameterPoints: 7, zoomScale: 0.01) == HexZoomTier(blendStep: 8, lod: .hexes))
        let far = HexOverlayStyle.tier(diameterPoints: 1, zoomScale: 0.0001)
        #expect(far.blendStep == 16)
        // log2(0.0001) * 4 = -53.15: quarter-octave step -54.
        #expect(far.lod == .discs(step: -54))
    }

    @Test("A disc step's dots stay near three points across its quarter octave")
    func discStepScale() {
        for step in [-60, -54, -40] {
            let built = HexOverlayStyle.zoomScale(forDiscStep: step)
            for zoomScale in [pow(2, (Double(step) + 0.001) / 4), pow(2, (Double(step) + 0.999) / 4)] {
                #expect(HexOverlayStyle.tier(diameterPoints: 1, zoomScale: zoomScale).lod == .discs(step: step))
                let diameter = 2 * HexOverlayStyle.discRadius / built * zoomScale
                #expect(diameter > 2.7 && diameter < 3.3)
            }
        }
    }

    // MARK: Unions

    private static func cells(_ ids: [String]) throws -> [HexCellGeometry] {
        HexGeometryBuilder.build(try ids.map { id in
            let boundary = try #require(H3Service.cellBoundary(for: id))
            let center = try #require(H3Service.centerCoordinate(for: id))
            return HexOverlayData(
                id: id, boundary: boundary.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                visitCount: 1, centerLatitude: center.latitude, centerLongitude: center.longitude
            )
        })
    }

    /// A mid-Atlantic cell and its six neighbours.
    private static func flower() throws -> [String] {
        let center = try #require(H3Service.cellIndex(latitude: 10.5, longitude: -35.5))
        let c = try #require(H3Service.centerCoordinate(for: center))
        var ids = [center]
        for step in 0..<72 {
            let angle = Double(step) * 5 * .pi / 180
            let id = try #require(H3Service.cellIndex(
                latitude: c.latitude + 5.6 / 111.2 * sin(angle),
                longitude: c.longitude + 5.6 / (111.2 * cos(c.latitude * .pi / 180)) * cos(angle)
            ))
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private func union(_ cells: [HexCellGeometry], _ members: [Int]) -> [MKPolygon] {
        var union = HexGeometryBuilder.UnionEdges()
        for index in members { union.add(cells[index].ring) }
        return union.polygons(orientation: HexGeometryBuilder.signedArea(cells[0].ring))
    }

    @Test("Shared edges cancel: a flower is one hexagon-of-hexagons, a ring keeps its hole")
    func unionsCancelSharedEdges() throws {
        let cells = try Self.cells(Self.flower())
        #expect(cells.count == 7)

        let full = union(cells, Array(0..<7))
        #expect(full.count == 1)
        #expect(full[0].pointCount == 18)
        #expect(full[0].interiorPolygons?.isEmpty ?? true)

        let ring = union(cells, Array(1..<7))
        #expect(ring.count == 1)
        #expect(ring[0].pointCount == 18)
        #expect(ring[0].interiorPolygons?.count == 1)
        #expect(ring[0].interiorPolygons?.first?.pointCount == 6)

        let pair = union(cells, [0, 1])
        #expect(pair.count == 1 && pair[0].pointCount == 10)

        // Two cells apart: two polygons.
        let apart = union(cells, [1, 4])
        #expect(apart.count == 2 && apart.allSatisfy { $0.pointCount == 6 })
    }

    @Test("Layers stack the wash from the lowest level, outline above, highlights on top; the selection is left out")
    func layerOrder() throws {
        let cells = try Self.cells(Self.flower())
        let ramp = HexPalette.darkRamp, compact = HexPalette.darkCompactRamp
        func paint(_ visits: Int) -> HexCellPaint {
            HexCellPaint(
                fill: HexPalette.fill(visits: visits, in: ramp), compactFill: HexPalette.fill(visits: visits, in: compact),
                stroke: HexPalette.outline(dark: true), emphasized: false
            )
        }
        // Paint order: three 1-visit cells, then three at 4, then one at 9.
        let paints = [paint(1), paint(1), paint(1), paint(4), paint(4), paint(4), paint(9)]
        let order = [1, 2, 3, 4, 5, 6, 0]
        let ordered = order.map { cells[$0] }
        let outline = HexOutline(paths: [HexOutlinePath(
            points: ordered[0].ring, closed: true, owners: Array(repeating: 0, count: ordered[0].ring.count)
        )])
        let layers = HexOverlayStyle.layers(
            cells: ordered, paints: paints, outline: outline, selected: nil, lod: .hexes, dark: true
        )
        #expect(layers.count == 4)
        guard layers.count == 4,
              case .stack(let lower0, let paint0, let base) = layers[0],
              case .stack(let lower1, let paint1, _) = layers[1],
              case .stack(let lower2, let paint2, let top) = layers[2],
              case .outlineLoops = layers[3] else {
            Issue.record("unexpected layer kinds")
            return
        }
        #expect(lower0 == nil && paint0 == paint(1))
        #expect(lower1 == paint(1) && paint1 == paint(4))
        #expect(lower2 == paint(4) && paint2 == paint(9))
        // The lowest layer is the whole flower; the top one the busiest cell.
        #expect(base.count == 1 && base[0].pointCount == 18)
        #expect(top.count == 1 && top[0].pointCount == 6)

        // Highlight the busiest cell and select a 1-visit one.
        var highlighted = paints.map(HexPalette.dimmed)
        highlighted[6] = HexPalette.highlightPaint(dark: true)
        let marked = HexOverlayStyle.layers(
            cells: ordered, paints: highlighted, outline: outline, selected: 0, lod: .hexes, dark: true
        )
        guard case .fill(let fillPaint, let fill) = marked.last(where: {
            if case .fill = $0 { return true } else { return false }
        }) else {
            Issue.record("no highlight layer")
            return
        }
        #expect(fillPaint.emphasized && fill.count == 1)
        guard case .stack(_, _, let dimmedBase) = marked[0] else {
            Issue.record("no wash")
            return
        }
        // Without the selected cell and the highlighted centre, the wash's
        // lowest layer is a ring broken open at the selected cell.
        #expect(dimmedBase.count == 1)
        #expect(dimmedBase[0].interiorPolygons?.isEmpty ?? true)
    }

    @Test("Disc layers draw opaque dots for every cell but the selected one")
    func discLayers() throws {
        let cells = try Self.cells(Self.flower())
        let paint = HexCellPaint(
            fill: HexPalette.darkRamp[0], compactFill: HexPalette.darkCompactRamp[0],
            stroke: HexPalette.outline(dark: true), emphasized: false
        )
        let layers = HexOverlayStyle.layers(
            cells: cells, paints: Array(repeating: paint, count: cells.count), outline: .empty,
            selected: 3, lod: .discs(step: -50), dark: true
        )
        #expect(layers.count == 1)
        guard case .discs(let color, let polygons) = layers.first else {
            Issue.record("no discs")
            return
        }
        #expect(color.a == 1)
        #expect(polygons.count == cells.count - 1)
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
