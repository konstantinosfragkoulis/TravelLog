import Testing
import MapKit
import Foundation
@testable import TravelLog

nonisolated struct HexPaletteTests {
    private func close(_ a: HexRGBA, _ b: HexRGBA) -> Bool {
        abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9 && abs(a.a - b.a) < 1e-9
    }

    private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> HexRGBA {
        HexRGBA(r: r / 255, g: g / 255, b: b / 255, a: a)
    }

    @Test("Ramps hit the design's ends and clamp visits to 1...15", arguments: [false, true])
    func rampEndsAndClamp(dark: Bool) {
        let ramp = HexPalette.ramp(dark: dark)
        #expect(ramp.count == 15)
        let first = dark ? rgba(110, 139, 255, 0.20) : rgba(61, 92, 240, 0.16)
        let last = dark ? rgba(150, 172, 255, 0.48) : rgba(31, 56, 196, 0.44)
        #expect(close(HexPalette.fill(visits: 1, in: ramp), first))
        #expect(close(HexPalette.fill(visits: 0, in: ramp), first))
        #expect(close(HexPalette.fill(visits: 15, in: ramp), last))
        #expect(close(HexPalette.fill(visits: 400, in: ramp), last))
        // The compact ramp: the same colours, denser.
        let compact = HexPalette.compactRamp(dark: dark)
        let compactFirst = dark ? rgba(110, 139, 255, 0.36) : rgba(61, 92, 240, 0.30)
        let compactLast = dark ? rgba(150, 172, 255, 0.62) : rgba(31, 56, 196, 0.56)
        #expect(close(HexPalette.fill(visits: 1, in: compact), compactFirst))
        #expect(close(HexPalette.fill(visits: 15, in: compact), compactLast))
    }

    @Test("Small cells blend to the compact fill and thin the outline between 10 and 4 pt")
    func compactBlendByCellSize() {
        #expect(HexPalette.compactBlend(diameterPoints: 26) == 0)
        #expect(HexPalette.compactBlend(diameterPoints: 10) == 0)
        #expect(HexPalette.compactBlend(diameterPoints: 7) == 0.5)
        #expect(HexPalette.compactBlend(diameterPoints: 4) == 1)
        #expect(HexPalette.compactBlend(diameterPoints: 2) == 1)
        let paint = HexCellPaint(
            fill: HexPalette.fill(visits: 1, in: HexPalette.darkRamp),
            compactFill: HexPalette.fill(visits: 1, in: HexPalette.darkCompactRamp),
            stroke: HexPalette.outline(dark: true), emphasized: false
        )
        #expect(HexOverlayStyle.fill(of: paint, diameterPoints: 12) == paint.fill)
        #expect(HexOverlayStyle.fill(of: paint, diameterPoints: 4) == paint.compactFill)
        #expect(abs(HexOverlayStyle.fill(of: paint, diameterPoints: 7).a - (0.20 + 0.36) / 2) < 1e-9)
        #expect(HexPalette.outlineWidth(diameterPoints: 26) == 1)
        #expect(HexPalette.outlineWidth(diameterPoints: 7) == 0.75)
        #expect(HexPalette.outlineWidth(diameterPoints: 4) == 0.5)
        #expect(HexPalette.outlineWidth(diameterPoints: 2) == 0.5)
    }

    @Test("Level is logarithmic and drives colour and alpha together")
    func levelIsLogarithmic() {
        #expect(HexPalette.level(visits: 1) == 0)
        #expect(abs(HexPalette.level(visits: 15) - 1) < 1e-12)
        #expect(HexPalette.level(visits: 99) == HexPalette.level(visits: 15))
        // ln 4 / ln 15 = 0.512: rgb(130,156,255) at 0.34 in dark.
        #expect(close(HexPalette.fill(visits: 4, in: HexPalette.darkRamp), rgba(130, 156, 255, 0.34)))
        let alphas = HexPalette.darkRamp.map(\.a)
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("The outline is one colour at every level", arguments: [false, true])
    func outlineIsConstant(dark: Bool) {
        let outline = HexPalette.outline(dark: dark)
        #expect(close(outline, dark ? rgba(160, 180, 255, 0.62) : rgba(40, 66, 214, 0.60)))
    }

    @Test("Highlights are translucent saffron on top; others dim but keep their colour")
    func highlightStaysLegible() {
        let highlighted = HexPalette.highlightPaint(dark: true)
        #expect(highlighted.emphasized)
        #expect(highlighted.fill.a > 0 && highlighted.fill.a < 1)
        #expect(highlighted.fill.a > HexPalette.darkRamp.last!.a)
        let own = HexCellPaint(
            fill: HexPalette.fill(visits: 1, in: HexPalette.darkRamp),
            compactFill: HexPalette.fill(visits: 1, in: HexPalette.darkCompactRamp),
            stroke: HexPalette.outline(dark: true), emphasized: false
        )
        let dimmed = HexPalette.dimmed(own)
        #expect(!dimmed.emphasized)
        #expect(dimmed.fill.r == own.fill.r && dimmed.fill.a < own.fill.a && dimmed.fill.a > 0.05)
        #expect(dimmed.compactFill.a < own.compactFill.a && dimmed.compactFill.a > 0.15)
        #expect(abs(dimmed.stroke.a - own.stroke.a * 0.35) < 1e-9)
    }

    @Test("Cells paint fewest visits first, ties in loader order")
    func paintOrderAscendingStable() {
        let overlays = [("a", 3), ("b", 1), ("c", 3), ("d", 2), ("e", 1)].map { id, visits in
            HexOverlayData(id: id, boundary: [], visitCount: visits, centerLatitude: 0, centerLongitude: 0)
        }
        #expect(HexMapView.paintOrder(overlays).map(\.id) == ["b", "e", "d", "a", "c"])
    }

    @Test("The shipped tuning is the wide ramp under a 1 pt outline")
    func shippedTuning() {
        #expect(HexPalette.tuning == .wide)
        #expect(HexTuning.compressed.lowAlpha > HexTuning.wide.lowAlpha)
        #expect(HexTuning.flat.highAlpha - HexTuning.flat.lowAlpha < HexTuning.compressed.highAlpha - HexTuning.compressed.lowAlpha)
    }

    @Test("The glow steps down from the ring like the design's blur", arguments: [false, true])
    func glowSteps(dark: Bool) {
        let glow = HexPalette.glow(dark: dark)
        #expect(abs(glow.a - (dark ? 0.75 : 0.35)) < 1e-12)
        let strokes = HexPalette.glowStrokes(glow)
        // Widest first, each wider than the 6 pt halo and the 2.6 pt ring.
        #expect(strokes.map(\.width) == strokes.map(\.width).sorted(by: >))
        #expect(strokes.allSatisfy { $0.width > HexOverlayStyle.ringWidth })
        // Summed near the ring: about 0.31 of a 0.75 glow, fading outward.
        let near = 1 - strokes.reduce(1) { $0 * (1 - $1.color.a) }
        #expect(abs(near - glow.a * 0.31 / 0.75) < 0.02)
        #expect(strokes.allSatisfy { $0.color.r == glow.r && $0.color.a < glow.a })
    }

    @Test("Stacked levels composite to each level's own paint over any background")
    func stackColorComposites() {
        let ramp = HexPalette.darkRamp
        for background in [HexRGBA(r: 0, g: 0, b: 0, a: 1), HexRGBA(r: 0.9, g: 0.8, b: 0.3, a: 1)] {
            func over(_ top: HexRGBA, _ bottom: HexRGBA) -> HexRGBA {
                func c(_ t: Double, _ b: Double) -> Double { t * top.a + b * (1 - top.a) }
                return HexRGBA(r: c(top.r, bottom.r), g: c(top.g, bottom.g), b: c(top.b, bottom.b), a: 1)
            }
            var composite = background
            var lower: HexRGBA?
            for level in [1, 2, 4, 9, 15] {
                let target = HexPalette.fill(visits: level, in: ramp)
                composite = over(HexOverlayStyle.stackColor(lower: lower, upper: target), composite)
                let expected = over(target, background)
                #expect(abs(composite.r - expected.r) < 1e-9 && abs(composite.g - expected.g) < 1e-9
                    && abs(composite.b - expected.b) < 1e-9)
                lower = target
            }
        }
        // The first level is its own paint; a step with no alpha change draws clear.
        let first = HexPalette.fill(visits: 1, in: ramp)
        #expect(HexOverlayStyle.stackColor(lower: nil, upper: first) == first)
        #expect(HexOverlayStyle.stackColor(lower: first, upper: first).a == 0)
    }

    // MARK: Territory outline

    /// A mid-Atlantic cell and its six neighbours, found by sampling points 1.73
    /// circumradii out (inside the ring for any res-6 cell).
    private static func flower() throws -> (center: String, ring: [String]) {
        let lat = 10.5, lon = -35.5
        let center = try #require(H3Service.cellIndex(latitude: lat, longitude: lon))
        let c = try #require(H3Service.centerCoordinate(for: center))
        var ring: [String] = []
        for step in 0..<72 {
            let angle = Double(step) * 5 * .pi / 180
            let km = 5.6
            let id = try #require(H3Service.cellIndex(
                latitude: c.latitude + km / 111.2 * sin(angle),
                longitude: c.longitude + km / (111.2 * cos(c.latitude * .pi / 180)) * cos(angle)
            ))
            if id != center, !ring.contains(id) { ring.append(id) }
        }
        return (center, ring)
    }

    private static func overlays(_ ids: [String]) throws -> [HexOverlayData] {
        try ids.map { id in
            let boundary = try #require(H3Service.cellBoundary(for: id))
            let center = try #require(H3Service.centerCoordinate(for: id))
            return HexOverlayData(
                id: id, boundary: boundary.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                visitCount: 1, centerLatitude: center.latitude, centerLongitude: center.longitude
            )
        }
    }

    @Test("The outline strokes only edges with no visited cell across them")
    func outlineSkipsSharedEdges() throws {
        let (center, ring) = try Self.flower()
        #expect(ring.count == 6)

        // A full flower: 18 outer edges, all owned by ring cells.
        let full = try Self.overlays([center] + ring)
        let fullOutline = try HexMapDataLoader.outlineEdges(of: full)
        #expect(fullOutline.count == 18)
        #expect(fullOutline.allSatisfy { $0.cell != 0 && $0.vertices.count == 2 })

        // The same ring around an unvisited centre: the hole is outlined too.
        let holed = try Self.overlays(ring)
        #expect(try HexMapDataLoader.outlineEdges(of: holed).count == 24)

        // Two neighbours: five edges each, never the shared one.
        let pair = try Self.overlays([center, ring[0]])
        let pairOutline = try HexMapDataLoader.outlineEdges(of: pair)
        #expect(pairOutline.count == 10)
        #expect(pairOutline.filter { $0.cell == 0 }.count == 5)

        // A cell alone is one closed loop of its own boundary.
        let single = try Self.overlays([center])
        let loop = try #require(try HexMapDataLoader.outlineEdges(of: single).first)
        #expect(loop.vertices.count == single[0].boundary.count + 1)
        #expect(loop.vertices.first?.latitude == loop.vertices.last?.latitude)
    }

    @Test("Outline edges join into one loop per boundary, owned in paint order")
    func outlineProjectsInPaintOrder() throws {
        let (center, ring) = try Self.flower()
        let loaded = try Self.overlays([center, ring[0]])
        let edges = try HexMapDataLoader.outlineEdges(of: loaded)
        // Loader index 0 paints second, 1 first.
        let outline = HexGeometryBuilder.buildOutline(edges, overlays: loaded, position: [1, 0])
        // Two neighbours: one closed loop of ten edges, five owned by each.
        let loop = try #require(outline.paths.first)
        #expect(outline.paths.count == 1)
        #expect(loop.closed)
        #expect(loop.points.count == 10 && loop.owners.count == 10)
        #expect(loop.owners.filter { $0 == 1 }.count == 5)
        let cells = HexGeometryBuilder.build(loaded)
        for (index, point) in loop.points.enumerated() {
            // Each segment starts and ends on its owner's ring.
            let owner = cells[loop.owners[index] == 1 ? 0 : 1]
            let end = loop.points[(index + 1) % loop.points.count]
            #expect(owner.ring.contains { hypot($0.x - point.x, $0.y - point.y) < 1 })
            #expect(owner.ring.contains { hypot($0.x - end.x, $0.y - end.y) < 1 })
        }

        // A ring around an unvisited centre: two loops, the rim and the hole.
        let holed = try Self.overlays(ring)
        let holedOutline = HexGeometryBuilder.buildOutline(
            try HexMapDataLoader.outlineEdges(of: holed), overlays: holed, position: Array(holed.indices)
        )
        #expect(holedOutline.paths.count == 2)
        #expect(holedOutline.paths.allSatisfy { $0.closed })
        #expect(holedOutline.paths.map(\.points.count).sorted() == [6, 18])
    }

    @Test("Outline runs split where the owners' stroke changes")
    func outlineRunsSplitByPaint() throws {
        let (center, ring) = try Self.flower()
        let loaded = try Self.overlays([center, ring[0]])
        let outline = HexGeometryBuilder.buildOutline(
            try HexMapDataLoader.outlineEdges(of: loaded), overlays: loaded, position: [0, 1]
        )
        let own = HexCellPaint(
            fill: HexPalette.darkRamp[0], compactFill: HexPalette.darkCompactRamp[0],
            stroke: HexPalette.outline(dark: true), emphasized: false
        )
        let same = HexOverlayStyle.outlineRuns(outline, paints: [own, own])
        #expect(same.count == 1 && same[0].closed && same[0].points.count == 10)

        // One cell highlighted: two open runs of five segments, one each.
        let mixed = HexOverlayStyle.outlineRuns(outline, paints: [HexPalette.highlightPaint(dark: true), HexPalette.dimmed(own)])
        #expect(mixed.count == 2)
        #expect(mixed.allSatisfy { !$0.closed && $0.points.count == 6 })
        #expect(mixed.filter(\.emphasized).count == 1)
    }
}
