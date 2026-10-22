//
//  TripShareCardMap.swift
//  TravelLog
//
//  The share card's map: the trip's territory as the exploration map paints
//  it (a cobalt hex wash with only the outer outline, `HexPalette` and the
//  map's own outline builder) under the trip page's route line and plain
//  stations, over a dark basemap. The hex resolution follows the trip's
//  span, so an island and a region both read as cells. The basemap is a
//  MapKit snapshot of the framed trip; offline, or when the snapshot fails,
//  the bundled country outlines stand in, so the card always draws a map.
//  Everything but the snapshot is vector, drawn when the card renders. The
//  route breaks between two places wherever the export removed evidence or
//  the drawn curve would pass a protected place (`TripShareExclusions`).
//

import MapKit
import Network
import SwiftH3
import SwiftUI
import UIKit
import os

/// The card's map, in its own points (`TripShareMapGeometry.size`).
struct TripShareCardMap {
    let layout: TripShareMapGeometry.Layout
    /// The veiled MapKit snapshot; nil when it could not be drawn.
    var basemap: UIImage?
    /// Country outlines standing in for the snapshot; even-odd rings.
    var land: [[CGPoint]] = []
}

nonisolated enum TripShareMapGeometry {
    static let size = CGSize(width: 360, height: 232)
    /// The MapKit snapshot covers the map's top this far, so its Apple Maps
    /// logo stays readable above the flags; its last `snapshotFeather`
    /// points, below the logo, feather into the water.
    static let snapshotHeight: CGFloat = 200
    static let snapshotFeather: CGFloat = 14
    /// Where the stations sit: clear of the map's sides and of the fade
    /// under the title.
    static let routeBox = CGRect(x: 36, y: 28, width: 288, height: 140)
    /// The hex size the resolution aims for, in points across.
    static let targetCellPoints = 10.0
    static let maximumCells = 4_000
    /// Fixes less precise than this draw no cell.
    static let maximumAccuracyMeters = 1_000.0
    /// Average H3 edge length per resolution, in km.
    static let edgeKilometers: [Double] = [
        1107.71, 418.68, 158.24, 59.81, 22.61, 8.54, 3.23, 1.22, 0.461, 0.174, 0.0659,
    ]
    static let resolutions: ClosedRange<Int32> = 2...10

    /// A place on the route, its longitude unwrapped around the first one.
    struct Station: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        /// A night or more there: the big ring.
        let isBase: Bool
        let start: Date
        let end: Date
    }

    struct Cell: Sendable {
        let points: [CGPoint]
        let fill: HexRGBA
    }

    struct Run: Sendable {
        let points: [CGPoint]
        let closed: Bool
    }

    struct Mark: Sendable {
        let point: CGPoint
        let isBase: Bool
    }

    /// The framed map: a map rect in unwrapped map points (it may run past
    /// the antimeridian) and the longitude everything unwraps around.
    struct Frame: Sendable {
        let rect: MKMapRect
        let referenceLongitude: Double

        func mapPoint(latitude: Double, longitude: Double) -> MKMapPoint {
            let unwrapped = referenceLongitude + GeoMath.wrappedLongitudeDelta(longitude, referenceLongitude)
            return TripShareMapGeometry.project(latitude: latitude, unwrappedLongitude: unwrapped)
        }

        func point(_ mapPoint: MKMapPoint, size: CGSize = TripShareMapGeometry.size) -> CGPoint {
            CGPoint(x: (mapPoint.x - rect.minX) / max(rect.width, 1) * size.width,
                    y: (mapPoint.y - rect.minY) / max(rect.height, 1) * size.height)
        }

        func point(latitude: Double, longitude: Double, size: CGSize = TripShareMapGeometry.size) -> CGPoint {
            point(mapPoint(latitude: latitude, longitude: longitude), size: size)
        }

        /// The same rect shifted into the world's x range, for MapKit.
        var normalizedRect: MKMapRect {
            let world = MKMapSize.world.width
            var shifted = rect
            while shifted.minX < 0 { shifted = shifted.offsetBy(dx: world, dy: 0) }
            while shifted.minX >= world { shifted = shifted.offsetBy(dx: -world, dy: 0) }
            return shifted
        }
    }

    /// Everything vector the card's map draws, in card points.
    struct Layout: Sendable {
        let frame: Frame
        let resolution: Int32
        let cells: [Cell]
        let outline: [Run]
        let outlineWidth: Double
        /// Runs of the route; no line joins two runs.
        let route: [[CGPoint]]
        let stations: [Mark]
    }

    // MARK: Stations and framing

    /// The trip's places in visit order, as the trip page's map shows them:
    /// destinations with nights on the big ring, visits on the small one.
    /// A trip with no destination shows its transit stops as visits.
    static func stations(of trip: SharedTrip) -> [Station] {
        let destinations = trip.destinations
        let stays = destinations.isEmpty
            ? trip.stays.sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
            : destinations
        guard let first = stays.first else { return [] }
        let reference = GeoMath.normalizedLongitude(first.longitude)
        return stays.map { stay in
            let nights = TripDisplayText.nights(
                from: stay.startTime, to: stay.endTime, timeZone: StayTimeZone.resolve(stay.timeZoneIdentifier))
            return Station(
                latitude: stay.latitude,
                longitude: reference + GeoMath.wrappedLongitudeDelta(stay.longitude, reference),
                isBase: stay.categoryRaw == StayCategory.destination.rawValue && nights > 0,
                start: stay.startTime, end: stay.endTime)
        }
    }

    /// Frames the stations inside `routeBox`, never closer than a town's
    /// width for one place or a few kilometres for several.
    static func frame(for stations: [Station], size: CGSize = size) -> Frame? {
        guard let first = stations.first else { return nil }
        let points = stations.map { project(latitude: $0.latitude, unwrappedLongitude: $0.longitude) }
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let floor: CLLocationDistance = stations.count == 1 ? 12_000 : 5_000
        let minimum = MKMapPointsPerMeterAtLatitude(first.latitude) * floor
        let width = max(maxX - minX, minimum), height = max(maxY - minY, minimum)
        let box = routeBox
        var scale = max(width / box.width, height / box.height)
        // Never taller than the world.
        scale = min(scale, MKMapSize.world.height / size.height)
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        var origin = MKMapPoint(x: midX - box.midX * scale, y: midY - box.midY * scale)
        let rectHeight = size.height * scale
        origin.y = min(max(origin.y, 0), MKMapSize.world.height - rectHeight)
        let rect = MKMapRect(origin: origin, size: MKMapSize(width: size.width * scale, height: rectHeight))
        return Frame(rect: rect, referenceLongitude: GeoMath.normalizedLongitude(first.longitude))
    }

    /// The resolution whose cells come closest to `targetCellPoints` across
    /// at this framing: fine for an island, coarse for a region.
    static func resolution(for frame: Frame, size: CGSize = size) -> Int32 {
        let center = MKMapPoint(x: frame.rect.midX, y: frame.rect.midY).coordinate
        let metersAcross = frame.rect.width / MKMapPointsPerMeterAtLatitude(center.latitude)
        let pointsPerKm = size.width / max(metersAcross / 1000, 0.001)
        var best = resolutions.lowerBound
        var bestError = Double.infinity
        for resolution in resolutions {
            let across = 2 * edgeKilometers[Int(resolution)] * pointsPerKm
            let error = abs(log(across / targetCellPoints))
            if error < bestError { best = resolution; bestError = error }
        }
        return best
    }

    // MARK: Territory

    /// The cells the trip's destinations touched at `resolution`: each fix
    /// of a destination and each destination's centre, counted in days, so
    /// a base reads denser than a road passed once.
    static func cells(of trip: SharedTrip, resolution: Int32, frame: Frame) -> [HexOverlayData] {
        let pings = Dictionary(trip.pings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var days: [String: Set<Date>] = [:]
        var order: [String] = []
        func add(_ latitude: Double, _ longitude: Double, day: Date) {
            let index = H3Index(coordinate: H3Coordinate(lat: latitude, lon: longitude), resolution: resolution)
            guard index.isValid else { return }
            let key = index.description
            if days[key] == nil { order.append(key) }
            days[key, default: []].insert(day)
        }
        let stays = trip.destinations.isEmpty ? trip.stays : trip.destinations
        for stay in stays {
            let zone = StayTimeZone.resolve(stay.timeZoneIdentifier)
            // The civil date in the stay's zone: a local midnight divided by
            // 86,400 s would merge two days around a daylight-saving change.
            func civilDay(_ date: Date) -> Date {
                TravelDays.label(for: date, zone: zone) ?? date
            }
            add(stay.latitude, stay.longitude, day: civilDay(stay.startTime))
            for id in stay.pingIDs {
                guard let ping = pings[id], ping.horizontalAccuracy >= 0,
                      ping.horizontalAccuracy <= maximumAccuracyMeters else { continue }
                add(ping.latitude, ping.longitude, day: civilDay(ping.timestamp))
            }
        }
        return order.prefix(maximumCells).compactMap { key in
            guard let center = H3Service.centerCoordinate(for: key),
                  let boundary = H3Service.cellBoundary(for: key) else { return nil }
            let unwrapped = frame.referenceLongitude + GeoMath.wrappedLongitudeDelta(center.longitude, frame.referenceLongitude)
            return HexOverlayData(
                id: key,
                boundary: boundary.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                visitCount: days[key]?.count ?? 1,
                centerLatitude: center.latitude,
                centerLongitude: unwrapped)
        }
    }

    /// The whole vector map for `trip`; nil when it has no place to show.
    static func layout(for trip: SharedTrip, exclusions: TripShareExclusions, size: CGSize = size) -> Layout? {
        let stations = stations(of: trip)
        guard let frame = frame(for: stations, size: size) else { return nil }
        var resolution = resolution(for: frame, size: size)
        var overlays = cells(of: trip, resolution: resolution, frame: frame)
        // A trip that would draw too many cells steps coarser.
        while overlays.count >= maximumCells, resolution > resolutions.lowerBound {
            resolution -= 1
            overlays = cells(of: trip, resolution: resolution, frame: frame)
        }

        let geometry = HexGeometryBuilder.build(overlays)
        let scaleX = size.width / max(frame.rect.width, 1)
        let diameter = geometry.map(\.diameter).max().map { $0 * scaleX } ?? targetCellPoints
        let blend = HexPalette.compactBlend(diameterPoints: diameter)
        let cells = zip(geometry, overlays).map { cell, overlay in
            let regular = HexPalette.fill(visits: overlay.visitCount, in: HexPalette.darkRamp)
            let compact = HexPalette.fill(visits: overlay.visitCount, in: HexPalette.darkCompactRamp)
            return Cell(points: cell.ring.map { frame.point($0, size: size) }, fill: mix(regular, compact, blend))
        }
        let edges = (try? HexMapDataLoader.outlineEdges(of: overlays)) ?? []
        let outline = HexGeometryBuilder.buildOutline(edges, overlays: overlays, position: Array(overlays.indices))
            .paths.map { Run(points: $0.points.map { frame.point($0, size: size) }, closed: $0.closed) }

        let marks = stations.map {
            Mark(point: frame.point(project(latitude: $0.latitude, unwrappedLongitude: $0.longitude), size: size),
                 isBase: $0.isBase)
        }
        return Layout(
            frame: frame, resolution: resolution, cells: cells, outline: outline,
            outlineWidth: HexPalette.outlineWidth(blend: blend),
            route: routeRuns(stations, trip: trip.shareID, exclusions: exclusions, frame: frame, size: size),
            stations: marks)
    }

    // MARK: Route

    /// Samples per curve when checking where it is drawn.
    static let curveSamples = 32

    /// The route through `stations` in runs, as `TripShareCardMapView`
    /// draws it. A leg is left out where the export removed evidence or the
    /// straight line passes a protected place; then each run's smoothed
    /// curve is read back as map positions, and a leg whose curve passes
    /// one is left out too, until every drawn curve is clear.
    static func routeRuns(
        _ stations: [Station], trip: UUID, exclusions: TripShareExclusions, frame: Frame, size: CGSize = size
    ) -> [[CGPoint]] {
        guard stations.count >= 2 else { return [] }
        let points = stations.map {
            frame.point(project(latitude: $0.latitude, unwrappedLongitude: $0.longitude), size: size)
        }
        func position(_ station: Station) -> TripShareExclusions.Point {
            .init(latitude: station.latitude, longitude: GeoMath.normalizedLongitude(station.longitude),
                  date: station.end)
        }
        // `joined[i]`: whether a line runs from station i - 1 to station i.
        var joined = [false] + stations.indices.dropFirst().map { index in
            let to = stations[index]
            return exclusions.joins(
                trip: trip, position(stations[index - 1]),
                .init(latitude: to.latitude, longitude: GeoMath.normalizedLongitude(to.longitude), date: to.start))
        }
        while true {
            // Runs of station indices; one drawn on the one before it is skipped.
            var runs: [[Int]] = []
            for index in stations.indices {
                if joined[index], var run = runs.popLast() {
                    let last = points[run[run.count - 1]]
                    if hypot(last.x - points[index].x, last.y - points[index].y) >= 0.5 { run.append(index) }
                    runs.append(run)
                } else {
                    runs.append([index])
                }
            }
            var blocked: Int?
            search: for run in runs where run.count >= 2 {
                let legs = curves(run.map { points[$0] })
                for (offset, curve) in legs.enumerated() {
                    let from = stations[run[offset]], to = stations[run[offset + 1]]
                    let span = TripShareExport.span(from.end, to.start)
                    let samples = (0...curveSamples).map {
                        coordinate(curve.point(at: Double($0) / Double(curveSamples)), frame: frame, size: size)
                    }
                    for (a, b) in zip(samples, samples.dropFirst())
                    where TripShareExport.lineCrossesHome(from: a, to: b, during: span, rings: exclusions.rings) {
                        blocked = run[offset + 1]
                        break search
                    }
                }
            }
            guard let blocked else {
                return runs.filter { $0.count >= 2 }.map { $0.map { points[$0] } }
            }
            joined[blocked] = false
        }
    }

    /// One leg of the route as drawn: a cubic from `start` to `end`.
    struct Curve: Sendable {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint

        func point(at t: Double) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                           y: a * start.y + b * control1.y + c * control2.y + d * end.y)
        }
    }

    /// The legs through `points` as one smooth line (Catmull-Rom as cubic
    /// curves), so legs bend gently through each place; two points join
    /// straight.
    static func curves(_ points: [CGPoint]) -> [Curve] {
        guard points.count >= 2 else { return [] }
        guard points.count > 2 else {
            let (a, b) = (points[0], points[1])
            return [Curve(start: a, control1: a, control2: b, end: b)]
        }
        return (0..<(points.count - 1)).map { index in
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            return Curve(start: p1,
                         control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                         control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                         end: p2)
        }
    }

    /// A card point back on the map.
    static func coordinate(_ point: CGPoint, frame: Frame, size: CGSize = size) -> (latitude: Double, longitude: Double) {
        let x = frame.rect.minX + point.x / size.width * frame.rect.width
        let y = frame.rect.minY + point.y / size.height * frame.rect.height
        let latitude = MKMapPoint(x: MKMapSize.world.width / 2, y: y).coordinate.latitude
        return (latitude, GeoMath.normalizedLongitude(x / MKMapSize.world.width * 360 - 180))
    }

    // MARK: Helpers

    /// Web Mercator map points for an unwrapped longitude, as
    /// `HexGeometryBuilder` projects cell rings.
    static func project(latitude: Double, unwrappedLongitude: Double) -> MKMapPoint {
        MKMapPoint(
            x: (unwrappedLongitude + 180) / 360 * MKMapSize.world.width,
            y: MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 0)).y)
    }

    static func mix(_ a: HexRGBA, _ b: HexRGBA, _ t: Double) -> HexRGBA {
        HexRGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t,
                b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }
}

// MARK: - Basemap

@MainActor
enum TripShareCardMapBuilder {

    /// The card's map for `trip`: the vector layers, then the snapshot or,
    /// without one, the country outlines. Nil when the trip has no place.
    static func map(for trip: SharedTrip, exclusions: TripShareExclusions,
                    scale: CGFloat = TripShareCardContent.scale) async -> TripShareCardMap? {
        guard let layout = await Task.detached(priority: .userInitiated, operation: {
            TripShareMapGeometry.layout(for: trip, exclusions: exclusions)
        }).value else { return nil }
        var map = TripShareCardMap(layout: layout)
        if await !isOffline() {
            map.basemap = await snapshot(layout.frame, scale: scale)
        }
        if map.basemap == nil {
            map.land = await land(layout.frame)
        }
        return map
    }

    /// The framed map as MapKit draws it in dark, muted and without points
    /// of interest, under the trip page's night veil. Nil when it fails or
    /// takes longer than a share should wait.
    static func snapshot(_ frame: TripShareMapGeometry.Frame, scale: CGFloat) async -> UIImage? {
        let size = CGSize(width: TripShareMapGeometry.size.width, height: TripShareMapGeometry.snapshotHeight)
        var rect = frame.normalizedRect
        rect.size.height *= size.height / TripShareMapGeometry.size.height
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = scale
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let snapshotter = MKMapSnapshotter(options: options)
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            snapshotter.cancel()
        }
        defer { timeout.cancel() }
        guard let snapshot = try? await snapshotter.start() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            // MapKit's dark muted style still paints land in greens; the
            // design's map is near black so the cobalt carries it.
            cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            let feather = TripShareMapGeometry.snapshotFeather
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor] as CFArray,
                locations: [0, 1]) else { return }
            cg.setBlendMode(.destinationOut)
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height - feather),
                                  end: CGPoint(x: 0, y: size.height), options: [.drawsAfterEndLocation])
        }
    }

    /// The bundled country outlines inside the frame, in card points.
    static func land(_ frame: TripShareMapGeometry.Frame) async -> [[CGPoint]] {
        let codes = Set(FlagAssetCodes.shipped.map { $0.uppercased() })
        let polygons = await CountryPolygonProvider.polygons(for: codes)
        let world = MKMapSize.world.width
        let visible = frame.rect.insetBy(dx: -frame.rect.width * 0.1, dy: -frame.rect.height * 0.1)
        var rings: [[CGPoint]] = []
        for country in polygons {
            let polygon = country.polygon
            let bounds = polygon.boundingMapRect
            for shift in [0, -world, world] where bounds.offsetBy(dx: shift, dy: 0).intersects(visible) {
                let points = polygon.points()
                var ring: [CGPoint] = []
                ring.reserveCapacity(polygon.pointCount)
                for index in 0..<polygon.pointCount {
                    let mapPoint = MKMapPoint(x: points[index].x + shift, y: points[index].y)
                    let point = frame.point(mapPoint)
                    if let last = ring.last, abs(last.x - point.x) + abs(last.y - point.y) < 0.4 { continue }
                    ring.append(point)
                }
                if ring.count >= 3 { rings.append(ring) }
            }
        }
        return rings
    }

    /// Whether the device has no network path: the snapshot would only
    /// draw empty tiles. Unknown after a second counts as online.
    static func isOffline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Bool) -> Void = { offline in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: offline)
            }
            monitor.pathUpdateHandler = { path in answer(path.status != .satisfied) }
            monitor.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { answer(false) }
        }
    }
}

// MARK: - Drawing

/// The map as the card draws it: the basemap or the country outlines, the
/// hex wash and its outline, then the route on its casing and bloom, and
/// the plain stations, bases on top.
struct TripShareCardMapView: View {
    let map: TripShareCardMap?

    static let water = Color(UIColor(hex: 0x0E141B))
    static let land = Color(UIColor(hex: 0x1C1F24))
    /// The route's colours in dark, whatever the surface around the card.
    static let line = Color(UIColor(hex: 0x6E8BFF))
    static let casing = Color(UIColor(hex: 0x05060A))
    static let glow = Color(UIColor(hex: 0x6E8BFF, alpha: 0.42))

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.water))
            guard let map else { return }
            if let basemap = map.basemap {
                context.draw(Image(uiImage: basemap), in: CGRect(
                    x: 0, y: 0, width: size.width, height: TripShareMapGeometry.snapshotHeight))
            } else {
                var land = Path()
                for ring in map.land { land.addLines(ring); land.closeSubpath() }
                context.fill(land, with: .color(Self.land), style: FillStyle(eoFill: true))
            }

            let layout = map.layout
            for cell in layout.cells where cell.points.count >= 3 {
                var path = Path()
                path.addLines(cell.points)
                path.closeSubpath()
                context.fill(path, with: .color(Self.color(cell.fill)))
            }
            var outline = Path()
            for run in layout.outline where run.points.count >= 2 {
                outline.addLines(run.points)
                if run.closed { outline.closeSubpath() }
            }
            context.stroke(outline, with: .color(Self.color(HexPalette.outline(dark: true))),
                           style: StrokeStyle(lineWidth: layout.outlineWidth, lineCap: .round, lineJoin: .round))

            if !layout.route.isEmpty {
                var route = Path()
                for run in layout.route { route.addPath(Self.smoothed(run)) }
                let round = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
                var bloom = context
                bloom.addFilter(.blur(radius: 3))
                bloom.stroke(route, with: .color(Self.glow), style: round(6.4))
                context.stroke(route, with: .color(Self.casing), style: round(5.6))
                context.stroke(route, with: .color(Self.line), style: round(2.88))
            }

            let ordered = layout.stations.filter { !$0.isBase } + layout.stations.filter(\.isBase)
            for station in ordered {
                let casing: CGFloat = station.isBase ? 7.65 : 5.44
                let ring: CGFloat = station.isBase ? 5.27 : 3.4
                let stroke: CGFloat = station.isBase ? 2.04 : 1.7
                context.fill(Self.circle(station.point, casing), with: .color(Self.casing))
                context.fill(Self.circle(station.point, ring), with: .color(Self.casing))
                context.stroke(Self.circle(station.point, ring), with: .color(Self.line), lineWidth: stroke)
            }
        }
        .frame(width: TripShareMapGeometry.size.width, height: TripShareMapGeometry.size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    static func color(_ rgba: HexRGBA) -> Color {
        Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// The route through one run, as `TripShareMapGeometry.curves` shapes it.
    static func smoothed(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for curve in TripShareMapGeometry.curves(points) {
            path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        }
        return path
    }
}
