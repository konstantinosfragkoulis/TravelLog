import MapKit
import UIKit
import Foundation

nonisolated struct HexRGBA: Sendable, Hashable {
    let r, g, b, a: Double

    /// The same colour with its alpha scaled by `opacity`.
    func withOpacity(_ opacity: Double) -> HexRGBA {
        HexRGBA(r: r, g: g, b: b, a: a * opacity)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

extension HexRGBA {
    /// An sRGB colour from a 0xRRGGBB literal.
    nonisolated init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255, a: alpha
        )
    }
}

/// The ramp and outline strengths, in one place so the balance between the
/// wash and the territory outline is a one-line switch. Dark values; light
/// follows them (`HexPalette`).
nonisolated struct HexTuning: Sendable, Equatable {
    /// Fill alpha at one visit and at `HexPalette.maxVisits` and beyond.
    let lowAlpha: Double
    let highAlpha: Double
    /// Outline width at close scale, in points.
    let outlineWidth: Double
    let outlineAlpha: Double

    /// The shipped balance: a wide ramp under a fine outline.
    static let wide = HexTuning(lowAlpha: 0.20, highAlpha: 0.48, outlineWidth: 1, outlineAlpha: 0.62)
    /// A compressed ramp under a firmer outline.
    static let compressed = HexTuning(lowAlpha: 0.28, highAlpha: 0.44, outlineWidth: 1.5, outlineAlpha: 0.80)
    /// A near-flat ramp: the outline carries the territory.
    static let flat = HexTuning(lowAlpha: 0.34, highAlpha: 0.42, outlineWidth: 1.5, outlineAlpha: 0.85)
}

/// The exploration map's paint, as plain values the map overlays and the
/// detail sheet share. Cells are a soft cobalt wash over the basemap, by
/// absolute visits: level t = ln(min(visits, 15)) / ln(15), so 1 visit is 0
/// and 15+ visits are 1 (the log spreads the many 1 to 3 visit cells), moves
/// both the colour and the alpha. Only the visited set's outline is stroked:
/// an edge with no visited cell across it (holes included), 1 pt at close
/// scale, thinning to 0.5 pt at country scale; an edge between two visited
/// cells is never stroked, whatever their levels. Small cells step up to a
/// compact ramp, so a 1-visit cell still reads at country scale. The tapped
/// cell keeps its fill inside a saffron ring with a soft saffron glow, over
/// a dark (light appearance: white) halo.
nonisolated enum HexPalette {
    static let maxVisits = 15

    /// The active balance (`HexTuning`).
    static let tuning = HexTuning.wide

    /// Light runs 0.04 lighter in fill and 0.02 in outline than dark; the
    /// compact ramps are denser by 0.16 / 0.14 (light 0.14 / 0.12).
    private static let lightFillOffset = -0.04
    private static let lightOutlineOffset = -0.02

    /// Indexed by `visits - 1`; built once, so a frame resolves no colours.
    /// Dark: rgb(110,139,255) at 0.20 to rgb(150,172,255) at 0.48.
    static let darkRamp = ramp(
        from: HexRGBA(hex: 0x6E8BFF, alpha: tuning.lowAlpha), to: HexRGBA(hex: 0x96ACFF, alpha: tuning.highAlpha)
    )
    /// Light: rgb(61,92,240) at 0.16 to rgb(31,56,196) at 0.44.
    static let lightRamp = ramp(
        from: HexRGBA(hex: 0x3D5CF0, alpha: tuning.lowAlpha + lightFillOffset),
        to: HexRGBA(hex: 0x1F38C4, alpha: tuning.highAlpha + lightFillOffset)
    )
    /// The same colours, denser, for small cells: dark 0.36 to 0.62.
    static let darkCompactRamp = ramp(
        from: HexRGBA(hex: 0x6E8BFF, alpha: tuning.lowAlpha + 0.16),
        to: HexRGBA(hex: 0x96ACFF, alpha: tuning.highAlpha + 0.14)
    )
    /// Light 0.30 to 0.56.
    static let lightCompactRamp = ramp(
        from: HexRGBA(hex: 0x3D5CF0, alpha: tuning.lowAlpha + lightFillOffset + 0.14),
        to: HexRGBA(hex: 0x1F38C4, alpha: tuning.highAlpha + lightFillOffset + 0.12)
    )

    static func ramp(dark: Bool) -> [HexRGBA] { dark ? darkRamp : lightRamp }

    static func compactRamp(dark: Bool) -> [HexRGBA] { dark ? darkCompactRamp : lightCompactRamp }

    static func fill(visits: Int, in ramp: [HexRGBA]) -> HexRGBA {
        ramp[min(max(visits, 1), maxVisits) - 1]
    }

    /// 0 at one visit, 1 at `maxVisits` and beyond, logarithmic between.
    static func level(visits: Int) -> Double {
        log(Double(min(max(visits, 1), maxVisits))) / log(Double(maxVisits))
    }

    /// The outline colour, the same at every level.
    static func outline(dark: Bool) -> HexRGBA {
        dark
            ? HexRGBA(hex: 0xA0B4FF, alpha: tuning.outlineAlpha)
            : HexRGBA(hex: 0x2842D6, alpha: tuning.outlineAlpha + lightOutlineOffset)
    }

    /// The outline width, in screen points: 1 pt at close scale, 0.5 pt at
    /// country scale, following the compact blend.
    static func outlineWidth(diameterPoints: Double) -> Double {
        outlineWidth(blend: compactBlend(diameterPoints: diameterPoints))
    }

    static func outlineWidth(blend: Double) -> Double {
        tuning.outlineWidth * (1 - 0.5 * blend)
    }

    /// How far a cell `diameterPoints` across has moved from the regular
    /// paint (0, at 10 pt and up) to the compact one (1, at 4 pt and
    /// below): the fill blends toward the compact ramp and the outline
    /// thins. Stepped in sixteenths, so the map restyles only when a step
    /// changes.
    static func compactBlend(diameterPoints: Double) -> Double {
        let blend = min(max((10 - diameterPoints) / 6, 0), 1)
        return (blend * 16).rounded() / 16
    }

    // MARK: Selection

    static func ring(dark: Bool) -> HexRGBA {
        HexRGBA(hex: dark ? 0xFFBE3D : 0xEE9D0B)
    }

    static func halo(dark: Bool) -> HexRGBA {
        dark ? HexRGBA(r: 0, g: 0, b: 0, a: 0.6) : HexRGBA(r: 1, g: 1, b: 1, a: 0.9)
    }

    /// The ring's soft glow: the design blurs (2.6 pt sigma) a 4 pt ring
    /// stroke at this opacity.
    static func glow(dark: Bool) -> HexRGBA {
        ring(dark: dark).withOpacity(dark ? 0.75 : 0.35)
    }

    /// The glow as three wide, faint strokes under the ring (vector overlays
    /// cannot blur), stepping down the blur's falloff: in dark about 0.31
    /// within 3 pt of the edge, 0.16 to 5 pt and 0.05 to 7 pt. Widest first.
    static func glowStrokes(_ glow: HexRGBA) -> [(width: Double, color: HexRGBA)] {
        [(14, glow.withOpacity(0.067)), (10, glow.withOpacity(0.155)), (6.5, glow.withOpacity(0.24))]
    }

    /// The sheet's hex mark: the cell's colour at this alpha.
    static func markAlpha(dark: Bool) -> Double {
        dark ? 0.85 : 0.8
    }

    // MARK: Highlight

    /// `AppTheme.saffron`, for Stats-routed highlights.
    static func saffron(dark: Bool) -> HexRGBA {
        HexRGBA(hex: dark ? 0xFFBE3D : 0xF2A516)
    }

    /// A highlighted cell: translucent saffron, denser than the busiest
    /// cobalt, its share of the outline saffron.
    static func highlightPaint(dark: Bool) -> HexCellPaint {
        let color = saffron(dark: dark)
        return HexCellPaint(
            fill: color.withOpacity(dark ? 0.5 : 0.45), compactFill: color.withOpacity(dark ? 0.75 : 0.7),
            stroke: color.withOpacity(dark ? 0.6 : 0.7), emphasized: true
        )
    }

    /// Cells outside a highlight keep their own colour, dimmed but legible;
    /// their outline recedes further.
    static func dimmed(_ paint: HexCellPaint) -> HexCellPaint {
        HexCellPaint(
            fill: paint.fill.withOpacity(0.55), compactFill: paint.compactFill.withOpacity(0.55),
            stroke: paint.stroke.withOpacity(0.35), emphasized: false
        )
    }

    /// RGB rounds to whole channels and alpha to two places, as the design
    /// specifies them.
    private static func ramp(from low: HexRGBA, to high: HexRGBA) -> [HexRGBA] {
        (1...maxVisits).map { visits in
            let t = level(visits: visits)
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            func channel(_ a: Double, _ b: Double) -> Double { (mix(a, b) * 255).rounded() / 255 }
            return HexRGBA(
                r: channel(low.r, high.r), g: channel(low.g, high.g), b: channel(low.b, high.b),
                a: (mix(low.a, high.a) * 100).rounded() / 100
            )
        }
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

nonisolated struct HexCellPaint: Sendable, Hashable {
    let fill: HexRGBA
    /// The fill small cells blend toward (`HexPalette.compactBlend`); a
    /// disc-sized cell's dot is this colour, denser.
    let compactFill: HexRGBA
    /// The cell's share of the outline.
    let stroke: HexRGBA
    /// Drawn after the others, so a highlighted cell's outline stays whole.
    let emphasized: Bool
}

/// The tapped cell, drawn last: its own fill inside a saffron ring with a
/// soft glow, over a wider halo.
nonisolated struct HexSelectionPaint: Sendable, Equatable {
    /// Into the frame's `cells`.
    let index: Int
    let ring: HexRGBA
    let halo: HexRGBA
    let glow: HexRGBA
}

/// One run of the visited set's outline, in map points: the loader's edges
/// joined end to end, so a loop strokes as one line with no doubled joint.
nonisolated struct HexOutlinePath: Sendable {
    /// A closed path does not repeat its first point.
    let points: [MKMapPoint]
    let closed: Bool
    /// Into the frame's `cells` (paint order): `owners[i]` owns the segment
    /// from `points[i]` to the next point (for a closed path, the last one
    /// back to the first), so its paint strokes that stretch.
    let owners: [Int]
}

nonisolated struct HexOutline: Sendable {
    let paths: [HexOutlinePath]

    static let empty = HexOutline(paths: [])
}

nonisolated struct HexOverlayFrame: Sendable {
    let generation: Int
    /// Changes whenever `cells` or `outline` do.
    var geometryID: Int = 0
    let cells: [HexCellGeometry]
    /// Same count and order as `cells`, which come in paint order.
    let paints: [HexCellPaint]
    var outline: HexOutline = .empty
    var selection: HexSelectionPaint?
    /// The appearance the paints were resolved for.
    var dark = true

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

    /// Projects the loader's outline edges, unwrapping each around its
    /// owner's centre longitude as `build` unwraps that cell's ring, and
    /// joins them end to end into loops. `position` maps a loader index to
    /// the paint-order index.
    static func buildOutline(
        _ edges: [HexOutlineEdgeData], overlays: [HexOverlayData], position: [Int]
    ) -> HexOutline {
        var projected: [(owner: Int, points: [MKMapPoint])] = []
        projected.reserveCapacity(edges.count)
        for edge in edges where edge.cell < overlays.count && edge.cell < position.count && edge.vertices.count >= 2 {
            let centerLongitude = overlays[edge.cell].centerLongitude
            projected.append((position[edge.cell], edge.vertices.map { vertex in
                project(
                    latitude: vertex.latitude,
                    longitude: centerLongitude + GeoMath.wrappedLongitudeDelta(vertex.longitude, centerLongitude)
                )
            }))
        }
        return HexOutline(paths: chain(projected))
    }

    /// A vertex, to a 64th of a map point (a few millimetres): absorbs the
    /// rounding between neighbours' copies of a shared vertex.
    struct VertexKey: Hashable {
        let x: Int64, y: Int64

        init(_ point: MKMapPoint) {
            x = Int64((point.x * 64).rounded())
            y = Int64((point.y * 64).rounded())
        }
    }

    /// Joins edges that share an end point. A vertex of the hex grid meets
    /// three cells, so at most two outline edges meet there and every
    /// chain is a simple path: a loop around the visited set or a hole, or
    /// an open run where projection unwrapping parts two ends.
    static func chain(_ edges: [(owner: Int, points: [MKMapPoint])]) -> [HexOutlinePath] {
        typealias Key = VertexKey
        var ends: [Key: [Int]] = [:]
        ends.reserveCapacity(edges.count * 2)
        for (index, edge) in edges.enumerated() {
            ends[Key(edge.points[0]), default: []].append(index)
            ends[Key(edge.points[edge.points.count - 1]), default: []].append(index)
        }
        var used = [Bool](repeating: false, count: edges.count)
        func take(at key: Key) -> Int? {
            guard let next = ends[key]?.first(where: { !used[$0] }) else { return nil }
            used[next] = true
            return next
        }

        var paths: [HexOutlinePath] = []
        for start in edges.indices where !used[start] {
            used[start] = true
            var points = edges[start].points
            var owners = [Int](repeating: edges[start].owner, count: points.count - 1)
            func isClosed() -> Bool { points.count > 2 && Key(points[0]) == Key(points[points.count - 1]) }
            // Forward from the end, then backward from the start.
            while !isClosed(), let next = take(at: Key(points[points.count - 1])) {
                var more = edges[next].points
                if Key(more[0]) != Key(points[points.count - 1]) { more.reverse() }
                points.append(contentsOf: more.dropFirst())
                owners.append(contentsOf: repeatElement(edges[next].owner, count: more.count - 1))
            }
            while !isClosed(), let previous = take(at: Key(points[0])) {
                var more = edges[previous].points
                if Key(more[more.count - 1]) != Key(points[0]) { more.reverse() }
                points.insert(contentsOf: more.dropLast(), at: 0)
                owners.insert(contentsOf: repeatElement(edges[previous].owner, count: more.count - 1), at: 0)
            }
            let closed = isClosed()
            if closed { points.removeLast() }
            paths.append(HexOutlinePath(points: points, closed: closed, owners: owners))
        }
        return paths
    }

    /// The boundary edges of a set of cells, kept open so cells can be
    /// added one at a time: an edge two added cells share cancels, so what
    /// stays is the union's outline, each edge running the way the cells'
    /// rings run.
    struct UnionEdges {
        private struct Edge: Hashable {
            let from: VertexKey, to: VertexKey
        }

        private var open: [Edge: MKMapPoint] = [:]

        mutating func add(_ ring: [MKMapPoint]) {
            guard ring.count >= 3 else { return }
            for index in ring.indices {
                let start = ring[index], end = ring[(index + 1) % ring.count]
                let edge = Edge(from: VertexKey(start), to: VertexKey(end))
                guard edge.from != edge.to else { continue }
                if open.removeValue(forKey: Edge(from: edge.to, to: edge.from)) == nil {
                    open[edge] = start
                }
            }
        }

        /// The union as polygons with their holes. Outer loops turn the
        /// way the cells do; a loop turning the other way is a hole, given
        /// to the smallest outer loop around it.
        func polygons(orientation: Double) -> [MKPolygon] {
            var next: [VertexKey: (to: VertexKey, point: MKMapPoint)] = [:]
            next.reserveCapacity(open.count)
            for (edge, point) in open { next[edge.from] = (edge.to, point) }
            var outers: [(points: [MKMapPoint], area: Double, bounds: MKMapRect)] = []
            var holes: [[MKMapPoint]] = []
            for start in next.keys where next[start] != nil {
                var loop: [MKMapPoint] = []
                var key = start
                while let step = next.removeValue(forKey: key) {
                    loop.append(step.point)
                    key = step.to
                }
                guard loop.count >= 3 else { continue }
                let area = HexGeometryBuilder.signedArea(loop)
                if (area > 0) == (orientation > 0) {
                    outers.append((loop, abs(area), HexGeometryBuilder.bounds(loop)))
                } else {
                    holes.append(loop)
                }
            }
            var interiors = [[MKPolygon]](repeating: [], count: outers.count)
            for hole in holes {
                let probe = hole[0]
                var best: Int?
                for (index, outer) in outers.enumerated()
                where outer.bounds.contains(probe) && HexGeometryBuilder.contains(probe, in: outer.points) {
                    if best.map({ outers[$0].area > outer.area }) ?? true { best = index }
                }
                if let best { interiors[best].append(MKPolygon(points: hole, count: hole.count)) }
            }
            return outers.indices.map { index in
                MKPolygon(points: outers[index].points, count: outers[index].points.count,
                          interiorPolygons: interiors[index].isEmpty ? nil : interiors[index])
            }
        }
    }

    /// Twice the signed area of a ring, in map points.
    static func signedArea(_ ring: [MKMapPoint]) -> Double {
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    static func bounds(_ ring: [MKMapPoint]) -> MKMapRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for point in ring {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd ray test.
    static func contains(_ point: MKMapPoint, in ring: [MKMapPoint]) -> Bool {
        var inside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// A disc of `sides` vertices standing in for a cell too small to show
    /// its shape.
    static func disc(center: MKMapPoint, radius: Double, sides: Int = 12) -> MKPolygon {
        let points = (0..<sides).map { index in
            let angle = Double(index) / Double(sides) * 2 * .pi
            return MKMapPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        return MKPolygon(points: points, count: points.count)
    }

    private static func project(latitude: Double, longitude: Double) -> MKMapPoint {
        MKMapPoint(
            x: (longitude + 180) / 360 * MKMapSize.world.width,
            y: MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 0)).y
        )
    }
}

// MARK: - Zoom tiers

/// What the map shows of a cell: its hexagon, or, once cells are under
/// 2 pt and the shape is gone, a fixed-size disc built for one
/// quarter-octave zoom step.
nonisolated enum HexLOD: Sendable, Hashable {
    case hexes
    case discs(step: Int)
}

/// The zoom-dependent style, in steps, so the overlays restyle only when a
/// step changes and never per frame.
nonisolated struct HexZoomTier: Sendable, Equatable {
    /// `HexPalette.compactBlend` in sixteenths.
    var blendStep: Int
    var lod: HexLOD

    var blend: Double { Double(blendStep) / 16 }

    static let close = HexZoomTier(blendStep: 0, lod: .hexes)
}

/// One overlay of the scene, before it reaches the map. Fills are unions:
/// cells of one paint join into polygons with no edge between them.
nonisolated enum HexLayerSpec {
    /// One level of the cobalt wash, laid over the levels below it: the
    /// union of every cell at this paint or a later one, coloured so the
    /// layers composite to each cell's own paint (`stackColor`). Stacking
    /// leaves no seam where levels meet.
    case stack(lower: HexCellPaint?, paint: HexCellPaint, polygons: [MKPolygon])
    /// Highlighted cells, over the wash.
    case fill(paint: HexCellPaint, polygons: [MKPolygon])
    /// Disc-sized cells: opaque dots, so overlapping dots read as one.
    case discs(color: HexRGBA, polygons: [MKPolygon])
    case outlineLoops(stroke: HexRGBA, polygons: [MKPolygon])
    case outlineRuns(stroke: HexRGBA, polylines: [MKPolyline])
}

/// Specs built off the main actor. MapKit shapes are not `Sendable`; these
/// are never mutated after they are built.
nonisolated struct HexSceneSpecs: @unchecked Sendable {
    let layers: [HexLayerSpec]
}

/// Pure style and geometry decisions for the hex overlays.
nonisolated enum HexOverlayStyle {
    /// A disc-sized cell's dot radius, in points.
    static let discRadius = 1.5
    /// Selection widths, in points.
    static let haloWidth = 6.0
    static let ringWidth = 2.6
    /// A disc-sized selected cell is marked by a dot this large instead of a ring.
    static let selectionDiscRadius = 6.0

    /// Cells draw as hexagons while the shape is still discernible (the
    /// outline thins between 10 and 4 pt, `HexPalette.compactBlend`).
    /// Below 2 pt the shape is gone and a disc marks the location instead.
    static func showsDiscs(diameterPoints: Double) -> Bool {
        diameterPoints < 2
    }

    /// The tier for a typical cell `diameterPoints` across at `zoomScale`.
    static func tier(diameterPoints: Double, zoomScale: Double) -> HexZoomTier {
        let blendStep = Int((HexPalette.compactBlend(diameterPoints: diameterPoints) * 16).rounded())
        guard showsDiscs(diameterPoints: diameterPoints) else {
            return HexZoomTier(blendStep: blendStep, lod: .hexes)
        }
        return HexZoomTier(blendStep: blendStep, lod: .discs(step: Int((log2(zoomScale) * 4).rounded(.down))))
    }

    /// The zoom scale a disc step's discs are built for: the middle of its
    /// quarter octave, so a 3 pt dot stays between 2.75 and 3.27 pt.
    static func zoomScale(forDiscStep step: Int) -> Double {
        pow(2, (Double(step) + 0.5) / 4)
    }

    /// A typical cell's diameter in metres: the median over a sample, as
    /// the map's projected diameter follows latitude.
    static func referenceDiameterMeters(_ cells: [HexCellGeometry]) -> Double {
        guard !cells.isEmpty else { return 0 }
        let stride = max(1, cells.count / 256)
        var sample: [Double] = []
        for index in Swift.stride(from: 0, to: cells.count, by: stride) {
            let cell = cells[index]
            sample.append(cell.diameter * MKMetersPerMapPointAtLatitude(cell.center.coordinate.latitude))
        }
        sample.sort()
        return sample[sample.count / 2]
    }

    /// The fill of a cell `diameterPoints` across: its level's colour,
    /// blended toward the compact one as the cell shrinks.
    static func fill(of paint: HexCellPaint, diameterPoints: Double) -> HexRGBA {
        fill(of: paint, blend: HexPalette.compactBlend(diameterPoints: diameterPoints))
    }

    static func fill(of paint: HexCellPaint, blend: Double) -> HexRGBA {
        if blend == 0 { return paint.fill }
        if blend == 1 { return paint.compactFill }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * blend }
        return HexRGBA(
            r: mix(paint.fill.r, paint.compactFill.r), g: mix(paint.fill.g, paint.compactFill.g),
            b: mix(paint.fill.b, paint.compactFill.b), a: mix(paint.fill.a, paint.compactFill.a)
        )
    }

    /// The colour that, laid over `lower`, composites to `upper` over any
    /// background: alpha from (1 - a) = (1 - upper.a) / (1 - lower.a),
    /// colour from what is left once `lower` shows through. A step too
    /// small to express is drawn clear.
    static func stackColor(lower: HexRGBA?, upper: HexRGBA) -> HexRGBA {
        guard let lower, lower.a < 1 else { return upper }
        let alpha = 1 - (1 - upper.a) / (1 - lower.a)
        guard alpha > 0.004 else { return HexRGBA(r: upper.r, g: upper.g, b: upper.b, a: 0) }
        func channel(_ u: Double, _ l: Double) -> Double {
            min(max((u * upper.a - l * lower.a * (1 - alpha)) / alpha, 0), 1)
        }
        return HexRGBA(
            r: channel(upper.r, lower.r), g: channel(upper.g, lower.g), b: channel(upper.b, lower.b), a: alpha
        )
    }

    /// A disc-sized cell's dot: the compact fill at twice its alpha (capped
    /// at opaque). A dot this small in the translucent fill would vanish
    /// into the basemap; doubling keeps both the level and a dimming.
    static func disc(of paint: HexCellPaint) -> HexRGBA {
        let fill = paint.compactFill
        return HexRGBA(r: fill.r, g: fill.g, b: fill.b, a: min(1, fill.a * 2))
    }

    /// The dot made opaque over the basemap's typical colour under the
    /// cells, so dots that overlap do not double their alpha.
    static func opaqueDisc(of paint: HexCellPaint, dark: Bool) -> HexRGBA {
        let dot = disc(of: paint)
        let base = dark ? HexRGBA(hex: 0x12242C) : HexRGBA(hex: 0xE6EEDC)
        func over(_ c: Double, _ b: Double) -> Double { c * dot.a + b * (1 - dot.a) }
        return HexRGBA(r: over(dot.r, base.r), g: over(dot.g, base.g), b: over(dot.b, base.b), a: 1)
    }

    /// Cells sharing a paint, in paint order; emphasized paints after all
    /// others, so highlighted cells draw on top.
    static func buckets(_ paints: [HexCellPaint]) -> [(paint: HexCellPaint, members: [Int])] {
        var order: [HexCellPaint] = []
        var members: [HexCellPaint: [Int]] = [:]
        for (index, paint) in paints.enumerated() {
            if members[paint] == nil { order.append(paint) }
            members[paint, default: []].append(index)
        }
        let sorted = order.filter { !$0.emphasized } + order.filter(\.emphasized)
        return sorted.map { ($0, members[$0] ?? []) }
    }

    /// The outline cut into runs of one stroke: a path whose owners share
    /// a paint stays whole (a loop stays closed); one that changes paint
    /// splits where it does. Strokes with no alpha are dropped.
    static func outlineRuns(
        _ outline: HexOutline, paints: [HexCellPaint]
    ) -> [(stroke: HexRGBA, emphasized: Bool, points: [MKMapPoint], closed: Bool)] {
        var runs: [(stroke: HexRGBA, emphasized: Bool, points: [MKMapPoint], closed: Bool)] = []
        func same(_ a: HexCellPaint, _ b: HexCellPaint) -> Bool {
            a.stroke == b.stroke && a.emphasized == b.emphasized
        }
        for path in outline.paths where !path.owners.isEmpty {
            guard path.owners.allSatisfy({ $0 < paints.count }) else { continue }
            var segments = path.owners.map { paints[$0] }
            var points = path.points
            if segments.allSatisfy({ same($0, segments[0]) }) {
                if segments[0].stroke.a > 0 {
                    runs.append((segments[0].stroke, segments[0].emphasized, points, path.closed))
                }
                continue
            }
            if path.closed {
                // Start at a change of paint and close the loop explicitly.
                let count = segments.count
                let shift = segments.indices.first { !same(segments[$0], segments[($0 + count - 1) % count]) } ?? 0
                points = Array(points[shift...] + points[..<shift])
                segments = Array(segments[shift...] + segments[..<shift])
                points.append(points[0])
            }
            var start = 0
            while start < segments.count {
                var end = start
                while end + 1 < segments.count, same(segments[end + 1], segments[start]) { end += 1 }
                if segments[start].stroke.a > 0 {
                    runs.append((segments[start].stroke, segments[start].emphasized, Array(points[start...(end + 1)]), false))
                }
                start = end + 1
            }
        }
        return runs
    }

    /// Every overlay but the selection's, in drawing order: the wash as
    /// stacked unions (or dots), its outline, then highlighted cells and
    /// theirs. The selected cell is left out; the selection draws it.
    static func layers(
        cells: [HexCellGeometry], paints: [HexCellPaint], outline: HexOutline,
        selected: Int?, lod: HexLOD, dark: Bool
    ) -> [HexLayerSpec] {
        guard cells.count == paints.count, !cells.isEmpty else { return [] }
        let buckets = buckets(paints)
        var layers: [HexLayerSpec] = []

        if case .discs(let step) = lod {
            let radius = discRadius / zoomScale(forDiscStep: step)
            for bucket in buckets {
                let polygons = bucket.members.compactMap { index in
                    index == selected ? nil : HexGeometryBuilder.disc(center: cells[index].center, radius: radius)
                }
                if !polygons.isEmpty {
                    layers.append(.discs(color: opaqueDisc(of: bucket.paint, dark: dark), polygons: polygons))
                }
            }
            return layers
        }

        let orientation = cells.first { $0.ring.count >= 3 }.map { HexGeometryBuilder.signedArea($0.ring) } ?? 1
        let runs = outlineRuns(outline, paints: paints)
        func outlineLayers(emphasized: Bool) -> [HexLayerSpec] {
            var strokes: [HexRGBA] = []
            let mine = runs.filter { $0.emphasized == emphasized }
            for run in mine where !strokes.contains(run.stroke) { strokes.append(run.stroke) }
            return strokes.flatMap { stroke -> [HexLayerSpec] in
                let these = mine.filter { $0.stroke == stroke }
                let loops = these.filter(\.closed).map { MKPolygon(points: $0.points, count: $0.points.count) }
                let lines = these.filter { !$0.closed }.map { MKPolyline(points: $0.points, count: $0.points.count) }
                return (loops.isEmpty ? [] : [.outlineLoops(stroke: stroke, polygons: loops)])
                    + (lines.isEmpty ? [] : [.outlineRuns(stroke: stroke, polylines: lines)])
            }
        }

        // The wash: union of everything from each level up, built from the
        // top level down so each step adds one level's cells.
        let wash = buckets.filter { !$0.paint.emphasized }
        var union = HexGeometryBuilder.UnionEdges()
        var stack: [HexLayerSpec] = []
        for (position, bucket) in wash.enumerated().reversed() {
            for index in bucket.members where index != selected { union.add(cells[index].ring) }
            let polygons = union.polygons(orientation: orientation)
            guard !polygons.isEmpty else { continue }
            let lower = position > 0 ? wash[position - 1].paint : nil
            stack.append(.stack(lower: lower, paint: bucket.paint, polygons: polygons))
        }
        layers += stack.reversed()
        layers += outlineLayers(emphasized: false)

        for bucket in buckets where bucket.paint.emphasized {
            var cellsOfPaint = HexGeometryBuilder.UnionEdges()
            for index in bucket.members where index != selected { cellsOfPaint.add(cells[index].ring) }
            let polygons = cellsOfPaint.polygons(orientation: orientation)
            if !polygons.isEmpty { layers.append(.fill(paint: bucket.paint, polygons: polygons)) }
        }
        layers += outlineLayers(emphasized: true)
        return layers
    }
}

// MARK: - Scene

/// The hex map's overlays, drawn by MapKit's vector path renderers so
/// fills, the outline and the selection stay sharp at every zoom: the wash
/// as a few stacked unions, the outline as joined loops (stroke only), and
/// a few small layers for the tapped cell. Geometry is built off the main
/// actor whenever the cells, paints, selection or level of detail change;
/// zoom restyles the existing renderers when the tier (`HexZoomTier`)
/// steps, and only the disc level of detail, far out, rebuilds geometry,
/// once the camera settles.
final class HexOverlayScene {
    private enum Role {
        case stack(lower: HexCellPaint?, paint: HexCellPaint)
        case fill(paint: HexCellPaint)
        case solid(HexRGBA)
        case outline(stroke: HexRGBA)
        case stroke(width: Double, color: HexRGBA)
    }

    private struct Layer {
        let overlay: any MKOverlay
        let renderer: MKOverlayPathRenderer
        let role: Role
    }

    private weak var map: MKMapView?
    private var frame = HexOverlayFrame.empty
    private var tier = HexZoomTier.close
    /// The level of detail the current layers were built for.
    private var builtLOD = HexLOD.hexes
    /// The level of detail an unfinished build is making, if any.
    private var pendingLOD: HexLOD?
    private var referenceMeters = 0.0
    private var layers: [Layer] = []
    private var renderers: [ObjectIdentifier: MKOverlayRenderer] = [:]
    private var buildTask: Task<Void, Never>?
    private var buildSequence = 0

    func attach(_ map: MKMapView) {
        self.map = map
    }

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        renderers[ObjectIdentifier(overlay)]
    }

    func publish(_ next: HexOverlayFrame) {
        let geometryChanged = frame.geometryID != next.geometryID
        frame = next
        if geometryChanged {
            referenceMeters = HexOverlayStyle.referenceDiameterMeters(next.cells)
            if let map, let current = currentTier(in: map) { tier = current }
        }
        rebuild()
    }

    /// While the camera moves: restyle when the blend step changes.
    func cameraMoved(_ map: MKMapView) {
        guard let next = currentTier(in: map), next.blendStep != tier.blendStep else { return }
        tier.blendStep = next.blendStep
        restyle()
    }

    /// Once the camera settles: switch between hexagons and discs, or to
    /// discs for a new zoom step.
    func cameraSettled(_ map: MKMapView) {
        guard let next = currentTier(in: map) else { return }
        let blendChanged = next.blendStep != tier.blendStep
        tier = next
        // Compare with the build in flight too: zooming back before it lands
        // must replace it, not let it install the wrong level of detail.
        if next.lod != (pendingLOD ?? builtLOD) {
            rebuild()
        } else if blendChanged {
            restyle()
        }
    }

    private func currentTier(in map: MKMapView) -> HexZoomTier? {
        let width = map.visibleMapRect.size.width
        guard referenceMeters > 0, width > 0, map.bounds.width > 0 else { return nil }
        let zoomScale = Double(map.bounds.width) / width
        let metersPerPoint = MKMetersPerMapPointAtLatitude(map.centerCoordinate.latitude)
        guard zoomScale.isFinite, zoomScale > 0, metersPerPoint > 0 else { return nil }
        return HexOverlayStyle.tier(diameterPoints: referenceMeters / metersPerPoint * zoomScale, zoomScale: zoomScale)
    }

    // MARK: Layers

    /// Builds every layer off the main actor, then swaps them in at once;
    /// a newer build supersedes an unfinished one.
    private func rebuild() {
        buildTask?.cancel()
        buildSequence += 1
        let sequence = buildSequence
        let frame = frame
        let lod = tier.lod
        pendingLOD = lod
        buildTask = Task { [weak self] in
            let specs = await Task.detached(priority: .userInitiated) {
                HexSceneSpecs(layers: HexOverlayStyle.layers(
                    cells: frame.cells, paints: frame.paints, outline: frame.outline,
                    selected: frame.selection?.index, lod: lod, dark: frame.dark
                ))
            }.value
            guard let self, !Task.isCancelled, sequence == self.buildSequence else { return }
            self.pendingLOD = nil
            self.builtLOD = lod
            self.apply(specs, for: frame, lod: lod)
        }
    }

    private func apply(_ specs: HexSceneSpecs, for frame: HexOverlayFrame, lod: HexLOD) {
        guard let map else { return }
        var next: [Layer] = specs.layers.map { spec in
            switch spec {
            case .stack(let lower, let paint, let polygons):
                let overlay = MKMultiPolygon(polygons)
                return layer(overlay, MKMultiPolygonRenderer(multiPolygon: overlay), .stack(lower: lower, paint: paint))
            case .fill(let paint, let polygons):
                let overlay = MKMultiPolygon(polygons)
                return layer(overlay, MKMultiPolygonRenderer(multiPolygon: overlay), .fill(paint: paint))
            case .discs(let color, let polygons):
                let overlay = MKMultiPolygon(polygons)
                return layer(overlay, MKMultiPolygonRenderer(multiPolygon: overlay), .solid(color))
            case .outlineLoops(let stroke, let polygons):
                let overlay = MKMultiPolygon(polygons)
                return layer(overlay, MKMultiPolygonRenderer(multiPolygon: overlay), .outline(stroke: stroke))
            case .outlineRuns(let stroke, let polylines):
                let overlay = MKMultiPolyline(polylines)
                return layer(overlay, MKMultiPolylineRenderer(multiPolyline: overlay), .outline(stroke: stroke))
            }
        }
        next += selectionLayers(for: frame, lod: lod)

        // New layers go in before the old ones leave, so nothing blinks.
        for layer in next {
            renderers[ObjectIdentifier(layer.overlay)] = layer.renderer
        }
        map.addOverlays(next.map(\.overlay), level: .aboveRoads)
        if !layers.isEmpty {
            map.removeOverlays(layers.map(\.overlay))
            for layer in layers {
                renderers[ObjectIdentifier(layer.overlay)] = nil
            }
        }
        layers = next
    }

    /// Halo, the glow's strokes, the cell's own fill and the ring; for a
    /// disc-sized cell a dot of halo, ring colour and its own colour.
    private func selectionLayers(for frame: HexOverlayFrame, lod: HexLOD) -> [Layer] {
        guard let selection = frame.selection, selection.index < frame.cells.count,
              selection.index < frame.paints.count, !frame.cells[selection.index].ring.isEmpty else { return [] }
        let cell = frame.cells[selection.index]
        let paint = frame.paints[selection.index]
        if case .discs(let step) = lod {
            let radius = HexOverlayStyle.selectionDiscRadius / HexOverlayStyle.zoomScale(forDiscStep: step)
            let own = paint.compactFill
            return [
                (radius, selection.halo), (radius * 0.6, selection.ring),
                (radius * 0.24, HexRGBA(r: own.r, g: own.g, b: own.b, a: 1))
            ].map { radius, color in
                let overlay = HexGeometryBuilder.disc(center: cell.center, radius: radius, sides: 24)
                return layer(overlay, MKPolygonRenderer(polygon: overlay), .solid(color))
            }
        }
        func ring() -> MKPolygon { MKPolygon(points: cell.ring, count: cell.ring.count) }
        let strokes = [(HexOverlayStyle.haloWidth, selection.halo)] + HexPalette.glowStrokes(selection.glow)
        var layers = strokes.map { width, color in
            let overlay = ring()
            return layer(overlay, MKPolygonRenderer(polygon: overlay), .stroke(width: width, color: color))
        }
        let fill = ring()
        layers.append(layer(fill, MKPolygonRenderer(polygon: fill), .fill(paint: paint)))
        let edge = ring()
        layers.append(layer(edge, MKPolygonRenderer(polygon: edge), .stroke(width: HexOverlayStyle.ringWidth, color: selection.ring)))
        return layers
    }

    private func layer(_ overlay: any MKOverlay, _ renderer: MKOverlayPathRenderer, _ role: Role) -> Layer {
        renderer.shouldRasterize = false
        renderer.lineJoin = .round
        renderer.lineCap = .round
        let layer = Layer(overlay: overlay, renderer: renderer, role: role)
        style(layer)
        return layer
    }

    private func style(_ layer: Layer) {
        let renderer = layer.renderer
        let blend = tier.blend
        switch layer.role {
        case .stack(let lower, let paint):
            let color = HexOverlayStyle.stackColor(
                lower: lower.map { HexOverlayStyle.fill(of: $0, blend: blend) },
                upper: HexOverlayStyle.fill(of: paint, blend: blend)
            )
            renderer.fillColor = color.uiColor
            renderer.strokeColor = nil
        case .fill(let paint):
            renderer.fillColor = HexOverlayStyle.fill(of: paint, blend: blend).uiColor
            renderer.strokeColor = nil
        case .solid(let color):
            renderer.fillColor = color.uiColor
            renderer.strokeColor = nil
        case .outline(let stroke):
            renderer.fillColor = nil
            renderer.strokeColor = stroke.uiColor
            renderer.lineWidth = HexPalette.outlineWidth(blend: blend)
        case .stroke(let width, let color):
            renderer.fillColor = nil
            renderer.strokeColor = color.uiColor
            renderer.lineWidth = width
        }
    }

    /// The blend step changed: new fill colours and outline widths on the
    /// existing renderers.
    private func restyle() {
        for layer in layers {
            switch layer.role {
            case .stack, .fill, .outline:
                style(layer)
                layer.renderer.setNeedsDisplay()
            case .solid, .stroke:
                break
            }
        }
    }
}
