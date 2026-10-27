//
//  CollectionsMap.swift
//  TravelLog
//
//  The flat vector map the Collections pages draw: the bundled country
//  outlines (`CountryPolygonProvider`) projected once per frame off the
//  main actor, then great-circle routes and plain station circles in a
//  Canvas. A tapped station names itself in a glass callout; there are no
//  labels at rest. Equal Earth for the world of routes, Mercator for a
//  region of airports.
//

import MapKit
import SwiftUI

// MARK: - Projection

/// Latitude and longitude to the map's points: a projection's unit plane
/// (y down), scaled and offset so the fitted places sit inside the insets.
nonisolated struct OutlineProjection: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case equalEarth, mercator }

    let kind: Kind
    let size: CGSize
    let scale: Double
    let offset: CGPoint

    func point(latitude: Double, longitude: Double) -> CGPoint {
        place(Self.unit(kind, latitude: latitude, longitude: longitude))
    }

    func place(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * scale + offset.x, y: unit.y * scale + offset.y)
    }

    /// The projection fitting `coordinates` inside `size` less `insets`,
    /// never closer than `minimumSpanDegrees` across, so one airport or a
    /// short hop still shows its coast. Without coordinates, the world.
    static func fitting(_ coordinates: [(latitude: Double, longitude: Double)], kind: Kind,
                        size: CGSize, insets: EdgeInsets, minimumSpanDegrees: Double) -> OutlineProjection {
        let units = coordinates.map { unit(kind, latitude: $0.latitude, longitude: $0.longitude) }
        var box: CGRect
        if let first = units.first {
            box = units.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        } else {
            let corner = unit(kind, latitude: 70, longitude: -180)
            let opposite = unit(kind, latitude: -56, longitude: 180)
            box = CGRect(x: corner.x, y: corner.y, width: opposite.x - corner.x, height: opposite.y - corner.y)
        }
        let span = minimumSpanDegrees * .pi / 180
        if box.width < span { box = box.insetBy(dx: -(span - box.width) / 2, dy: 0) }
        if box.height < span * 0.6 { box = box.insetBy(dx: 0, dy: -(span * 0.6 - box.height) / 2) }
        let available = CGRect(x: insets.leading, y: insets.top,
                               width: max(size.width - insets.leading - insets.trailing, 1),
                               height: max(size.height - insets.top - insets.bottom, 1))
        let scale = min(available.width / box.width, available.height / box.height)
        let offset = CGPoint(x: available.midX - box.midX * scale, y: available.midY - box.midY * scale)
        return OutlineProjection(kind: kind, size: size, scale: scale, offset: offset)
    }

    /// The unit plane: Equal Earth (Šavrič, Patterson and Jenny, 2018), or
    /// spherical Mercator in radians.
    static func unit(_ kind: Kind, latitude: Double, longitude: Double) -> CGPoint {
        let lat = min(max(latitude, -85), 85) * .pi / 180
        let lon = longitude * .pi / 180
        switch kind {
        case .mercator:
            return CGPoint(x: lon, y: -log(tan(.pi / 4 + lat / 2)))
        case .equalEarth:
            let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796
            let m = 3.0.squareRoot() / 2
            let theta = asin(m * sin(lat))
            let t2 = theta * theta, t6 = t2 * t2 * t2
            let x = lon * cos(theta) / (m * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)))
            let y = theta * (a1 + a2 * t2 + t6 * (a3 + a4 * t2))
            return CGPoint(x: x, y: -y)
        }
    }

    /// A MapKit map point on the unit plane (Mercator straight from it).
    static func unit(_ kind: Kind, mapPoint: MKMapPoint) -> CGPoint {
        switch kind {
        case .mercator:
            let world = MKMapSize.world.width
            return CGPoint(x: mapPoint.x / world * 2 * .pi - .pi, y: mapPoint.y / world * 2 * .pi - .pi)
        case .equalEarth:
            let coordinate = mapPoint.coordinate
            return unit(kind, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// The great circle from `a` to `b` in `segments` steps, as latitude
    /// and longitude.
    static func greatCircle(from a: (latitude: Double, longitude: Double),
                            to b: (latitude: Double, longitude: Double),
                            segments: Int) -> [(latitude: Double, longitude: Double)] {
        let rad = Double.pi / 180
        let lat1 = a.latitude * rad, lon1 = a.longitude * rad
        let lat2 = b.latitude * rad, lon2 = b.longitude * rad
        let d = 2 * asin(min(1, sqrt(pow(sin((lat2 - lat1) / 2), 2)
            + cos(lat1) * cos(lat2) * pow(sin((lon2 - lon1) / 2), 2))))
        guard d > 1e-9, segments > 0 else { return [a, b] }
        return (0...segments).map { step in
            let f = Double(step) / Double(segments)
            let s1 = sin((1 - f) * d) / sin(d), s2 = sin(f * d) / sin(d)
            let x = s1 * cos(lat1) * cos(lon1) + s2 * cos(lat2) * cos(lon2)
            let y = s1 * cos(lat1) * sin(lon1) + s2 * cos(lat2) * sin(lon2)
            let z = s1 * sin(lat1) + s2 * sin(lat2)
            return (atan2(z, (x * x + y * y).squareRoot()) / rad, atan2(y, x) / rad)
        }
    }
}

// MARK: - Land

enum OutlineLand {
    /// The bundled country outlines as `projection` draws them: every ring
    /// that reaches the frame, thinned to half a point.
    static func path(for projection: OutlineProjection) async -> Path {
        let codes = Set(FlagAssetCodes.shipped.map { $0.uppercased() })
        let polygons = await CountryPolygonProvider.polygons(for: codes)
        guard !Task.isCancelled else { return Path() }
        return await Task.detached(priority: .userInitiated) {
            build(polygons, projection)
        }.value
    }

    private nonisolated static func build(_ polygons: [CountryPolygonProvider.CountryPolygon],
                                          _ projection: OutlineProjection) -> Path {
        let frame = CGRect(origin: .zero, size: projection.size).insetBy(dx: -24, dy: -24)
        var path = Path()
        for country in polygons {
            if Task.isCancelled { return Path() }
            let polygon = country.polygon
            let points = polygon.points()
            var ring: [CGPoint] = []
            ring.reserveCapacity(polygon.pointCount)
            var bounds = CGRect.null
            for index in 0..<polygon.pointCount {
                let point = projection.place(OutlineProjection.unit(projection.kind, mapPoint: points[index]))
                if let last = ring.last, abs(last.x - point.x) + abs(last.y - point.y) < 0.5 { continue }
                ring.append(point)
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
            guard ring.count >= 3, bounds.intersects(frame) else { continue }
            path.addLines(ring)
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Map

/// The map's colours: near-black water and land in dark, the trip map's
/// route cobalt for lines and flown stations.
enum OutlineMapTint {
    static let water = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x0E141B) : UIColor(hex: 0xC9D7E3) })
    static let land = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1F24) : UIColor(hex: 0xEEF0F2) })
    /// A station's hollow centre.
    static let station = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1C1E) : .white })
}

/// A station on the map.
struct OutlineMapMark: Identifiable, Equatable {
    enum Style: Equatable {
        /// A small hollow ring on the route lines.
        case routeStation
        /// A filled circle: an airport flown through.
        case filled
        /// A hollow ring: an airport only set foot in.
        case hollow
    }

    let id: String
    let latitude: Double
    let longitude: Double
    var style: Style
    /// Drawn a size up: the busiest.
    var emphasized = false
}

/// A route between two stations, as wide and bright as it is flown.
struct OutlineMapArc: Equatable {
    let from: (latitude: Double, longitude: Double)
    let to: (latitude: Double, longitude: Double)
    let flights: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to && lhs.flights == rhs.flights
    }
}

/// The map: water, land, arcs, then the stations, the selected one saffron
/// and named in a callout. A tap selects the nearest station within 22 pt;
/// a tap elsewhere clears it.
struct OutlineMap: View {
    let projection: OutlineProjection
    let marks: [OutlineMapMark]
    var arcs: [OutlineMapArc] = []
    @Binding var selection: String?
    /// The selected station's callout: its name and one line under it.
    let callout: (String) -> (title: String, detail: String)?
    /// The callout keeps this far from the map's top.
    var calloutTop: CGFloat = 10
    var calloutWidth: CGFloat = 240

    @State private var land: Path?

    var body: some View {
        ZStack(alignment: .topLeading) {
            OutlineLandLayer(land: land)
            Canvas { context, _ in
                draw(in: &context)
            }
            if let selection, let mark = marks.first(where: { $0.id == selection }),
               let text = callout(selection) {
                let anchor = projection.point(latitude: mark.latitude, longitude: mark.longitude)
                CalloutPlacement(anchor: anchor, clearance: 13, top: calloutTop) {
                    OutlineMapCallout(title: text.title, detail: text.detail)
                        .frame(maxWidth: calloutWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(width: projection.size.width, height: projection.size.height)
        .contentShape(.rect)
        .onTapGesture { location in
            withAnimation(.easeOut(duration: 0.15)) {
                selection = nearest(to: location)
            }
        }
        .task(id: projection) {
            let path = await OutlineLand.path(for: projection)
            guard !Task.isCancelled else { return }
            land = path
        }
    }

    private func nearest(to location: CGPoint) -> String? {
        var best: (id: String, distance: CGFloat)?
        for mark in marks {
            let point = projection.point(latitude: mark.latitude, longitude: mark.longitude)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= 22, distance < best?.distance ?? .infinity { best = (mark.id, distance) }
        }
        return best?.id
    }

    private func draw(in context: inout GraphicsContext) {
        let line = AppTheme.routeLine
        let casing = AppTheme.routeCasing
        for arc in arcs {
            let points = OutlineProjection.greatCircle(from: arc.from, to: arc.to, segments: 40)
            var path = Path()
            var previous: (latitude: Double, longitude: Double)?
            for coordinate in points {
                let point = projection.point(latitude: coordinate.latitude, longitude: coordinate.longitude)
                // Across the antimeridian the line leaves one edge and
                // comes back at the other.
                if let previous, abs(previous.longitude - coordinate.longitude) < 180 {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                }
                previous = coordinate
            }
            let flights = Double(arc.flights)
            context.stroke(path, with: .color(line.opacity(min(0.95, 0.38 + 0.06 * flights))),
                           style: StrokeStyle(lineWidth: min(3.2, 1.1 + 0.2 * flights), lineCap: .round))
        }

        for mark in marks where mark.id != selection {
            let point = projection.point(latitude: mark.latitude, longitude: mark.longitude)
            switch mark.style {
            case .routeStation:
                let radius: CGFloat = mark.emphasized ? 4.2 : 2.4
                let circle = Self.circle(point, radius)
                context.fill(circle, with: .color(OutlineMapTint.station))
                context.stroke(circle, with: .color(line), lineWidth: mark.emphasized ? 2.2 : 1.5)
            case .filled:
                let circle = Self.circle(point, mark.emphasized ? 6.4 : 4.6)
                context.fill(circle, with: .color(line))
                context.stroke(circle, with: .color(casing), lineWidth: mark.emphasized ? 2 : 1.5)
            case .hollow:
                let circle = Self.circle(point, 4.1)
                context.fill(circle, with: .color(OutlineMapTint.station))
                context.stroke(circle, with: .color(.secondary), lineWidth: 1.6)
            }
        }

        if let selection, let mark = marks.first(where: { $0.id == selection }) {
            let point = projection.point(latitude: mark.latitude, longitude: mark.longitude)
            let large = mark.style != .routeStation
            context.fill(Self.circle(point, large ? 13 : 9), with: .color(AppTheme.saffronSoft))
            let dot = Self.circle(point, large ? 6.4 : 4.6)
            context.fill(dot, with: .color(AppTheme.saffron))
            context.stroke(dot, with: .color(casing), lineWidth: large ? 2 : 1.5)
        }
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Water and land on their own layer, redrawn only when the outlines change.
private struct OutlineLandLayer: View, Equatable {
    let land: Path?

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(OutlineMapTint.water))
            if let land {
                context.fill(land, with: .color(OutlineMapTint.land))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A station's name and one line under it, in the trip map's glass.
struct OutlineMapCallout: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
            Text(verbatim: detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(TripPageTint.calloutFill, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(TripPageTint.calloutEdge, lineWidth: 0.5))
        .shadow(color: TripPageTint.calloutShadow, radius: 14, y: 6)
    }
}

/// Places its one subview above `anchor`, clear of the station and inside
/// the map's sides; below it when there is no room under `top`.
private struct CalloutPlacement: Layout {
    let anchor: CGPoint
    let clearance: CGFloat
    let top: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let callout = subviews.first else { return }
        let margin: CGFloat = 10
        let size = callout.sizeThatFits(ProposedViewSize(width: bounds.width - margin * 2, height: nil))
        let x = min(max(anchor.x - size.width / 2, margin), bounds.width - margin - size.width)
        var y = anchor.y - clearance - 6 - size.height
        if y < top { y = anchor.y + clearance + 6 }
        callout.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      proposal: ProposedViewSize(size))
    }
}
