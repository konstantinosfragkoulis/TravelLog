//
//  TripRouteMap.swift
//  TravelLog
//
//  The trip page's route map: plain stations on the cobalt line, no names
//  at rest. A tapped station names itself in a glass callout with a
//  pointer; stations that touch at the map's fixed camera share one double
//  ring, whose tap opens a short chooser list. One place at most is ever
//  selected: a group is never selected as a whole.
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

/// One place on the trip map, in route order.
struct TripMapStation: Identifiable, Equatable {
    let id: PersistentIdentifier
    let name: String
    /// "3 to 5 Jun · 2 nights", "5 Jun · 3h 35m".
    let caption: String
    let latitude: Double
    let longitude: Double
    /// A night or more there: the big ring. Visits ride the small one.
    let isBase: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What the trip map shows over its stations. At most one place is selected.
enum TripMapFocus: Equatable {
    /// One place selected, its callout open (at its group's ring when it shares one).
    case place(PersistentIdentifier)
    /// A double ring's chooser open; nothing selected. Any member's id.
    case group(PersistentIdentifier)
    /// Chosen from the Stops list: the place selected, its callout open, or
    /// its group's chooser open on its row.
    case listed(PersistentIdentifier)

    var selectedPlace: PersistentIdentifier? {
        switch self {
        case .place(let id), .listed(let id): id
        case .group: nil
        }
    }

    var focusedID: PersistentIdentifier {
        switch self {
        case .place(let id), .group(let id), .listed(let id): id
        }
    }
}

/// The page's tints for the map's callouts and the Stops rows.
enum TripPageTint {
    /// The callout's glass: a near-opaque system background over a blur.
    static let calloutFill = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.88)
            : UIColor(white: 1, alpha: 0.88)
    })
    static let calloutEdge = Color(UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.1)
    })
    static let calloutShadow = Color(UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.45) : UIColor(white: 0, alpha: 0.14)
    })
    static let scrollIndicator = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.4)
            : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.35)
    })
    /// A chosen row in the chooser, and a stop row's flash.
    static let flash = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(hex: 0x6E8BFF, alpha: 0.16)
            : UIColor(hex: 0x2F4BE0, alpha: 0.1)
    })
    /// A stop row under the finger.
    static let pressed = Color(UIColor {
        UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255,
                alpha: $0.userInterfaceStyle == .dark ? 0.24 : 0.16)
    })
}

// MARK: - Projection and grouping

/// Where the map draws a coordinate: the visible map rect stretched over the map's frame.
nonisolated struct TripMapProjection: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
    var size: CGSize

    init(rect: MKMapRect, size: CGSize) {
        minX = rect.origin.x
        minY = rect.origin.y
        width = max(rect.size.width, 1)
        height = max(rect.size.height, 1)
        self.size = size
    }

    /// The map repeats every world width, and the visible rect may sit on
    /// any copy of it (a camera over the 180th meridian runs past the
    /// world's edge).
    static let worldWidth = MKMapSize.world.width

    /// The copy of `x` nearest `reference`.
    static func unwrap(_ x: Double, near reference: Double) -> Double {
        x + ((reference - x) / worldWidth).rounded() * worldWidth
    }

    /// A coordinate on the world copy nearest the view's centre, so a
    /// station across the dateline draws beside its neighbours.
    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        let mapPoint = MKMapPoint(coordinate)
        let x = Self.unwrap(mapPoint.x, near: minX + width / 2)
        return CGPoint(x: (x - minX) / width * size.width,
                       y: (mapPoint.y - minY) / height * size.height)
    }

    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D {
        MKMapPoint(x: minX + point.x / max(size.width, 1) * width,
                   y: minY + point.y / max(size.height, 1) * height).coordinate
    }
}

/// A drawn marker: one station, or several that touch on one double ring.
struct TripMapMarker: Identifiable {
    let members: [TripMapStation]
    let point: CGPoint
    let coordinate: CLLocationCoordinate2D
    let isBase: Bool

    var id: PersistentIdentifier { members[0].id }
    var isGroup: Bool { members.count > 1 }
    /// The plain station's ring: 8 pt for a base, 5.5 for a visit (to the stroke's middle).
    var ringRadius: CGFloat { isBase ? 8 : 5.5 }

    func contains(_ id: PersistentIdentifier?) -> Bool {
        guard let id else { return false }
        return members.contains { $0.id == id }
    }

    /// Stations in route order join the first group whose seed is under
    /// 20 pt away; markers that still touch then merge. Display data at the
    /// current camera (`points` are the stations on screen), never stored:
    /// zooming in separates them.
    static func group(_ stations: [TripMapStation], points: [CGPoint]) -> [TripMapMarker] {
        guard points.count == stations.count else { return [] }
        var clusters: [[Int]] = []
        for index in stations.indices {
            if let match = clusters.firstIndex(where: { distance(points[$0[0]], points[index]) < 20 }) {
                clusters[match].append(index)
            } else {
                clusters.append([index])
            }
        }
        struct Draft {
            var members: [Int]
            var point: CGPoint
            var isBase: Bool
            var radius: CGFloat { (isBase ? 9.75 : 7.25) + (members.count > 1 ? 4 : 0) }
        }
        func draft(_ members: [Int]) -> Draft {
            let sorted = members.sorted()
            let x = sorted.reduce(0) { $0 + points[$1].x } / CGFloat(sorted.count)
            let y = sorted.reduce(0) { $0 + points[$1].y } / CGFloat(sorted.count)
            return Draft(members: sorted, point: CGPoint(x: x, y: y),
                         isBase: sorted.contains { stations[$0].isBase })
        }
        var drafts = clusters.map(draft)
        var merged = true
        while merged {
            merged = false
            search: for a in drafts.indices {
                for b in drafts.indices where b > a {
                    if distance(drafts[a].point, drafts[b].point) < drafts[a].radius + drafts[b].radius + 2 {
                        drafts[a] = draft(drafts[a].members + drafts[b].members)
                        drafts.remove(at: b)
                        merged = true
                        break search
                    }
                }
            }
        }
        return drafts.map { draft in
            // A group's spot on the map: its members' mean, which stays put
            // while the camera pans or zooms.
            return TripMapMarker(
                members: draft.members.map { stations[$0] },
                point: draft.point,
                coordinate: draft.members.count == 1
                    ? stations[draft.members[0]].coordinate
                    : mean(draft.members.map { stations[$0].coordinate }),
                isBase: draft.isBase)
        }
    }

    /// The members' mean on the map, taken on one world copy: members
    /// either side of the dateline average beside it, not at Greenwich.
    static func mean(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard let first = coordinates.first else { return CLLocationCoordinate2D() }
        let world = TripMapProjection.worldWidth
        let anchor = MKMapPoint(first).x
        let points = coordinates.map(MKMapPoint.init)
        let x = points.reduce(0) { $0 + TripMapProjection.unwrap($1.x, near: anchor) } / Double(points.count)
        let y = points.reduce(0) { $0 + $1.y } / Double(points.count)
        let wrapped = x - (x / world).rounded(.down) * world
        return MKMapPoint(x: wrapped, y: y).coordinate
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - Map

/// The map's markers where the camera now draws them. Rewritten on every
/// camera frame and read only by the overlay, so a pan or a pinch redraws
/// the overlay, never the map's content.
@Observable
final class TripMapLiveLayout {
    var markers: [TripMapMarker] = []
    /// The route through the markers, in route order.
    var route: [CGPoint] = []
    /// The markers' spots, changed only when the grouping does: the map's
    /// label guards follow these, not every frame.
    var guards: [LabelGuard] = []
    @ObservationIgnored var lastRect: MKMapRect?
    /// Until then the camera is moving on the page's behalf (revealing a
    /// stop chosen in the list), so its frames keep the selection.
    @ObservationIgnored var programmaticMoveUntil = Date.distantPast

    struct LabelGuard: Identifiable, Equatable {
        let id: PersistentIdentifier
        let name: String
        let latitude: Double
        let longitude: Double
        let isGroup: Bool
    }

    func update(_ stations: [TripMapStation], points: [CGPoint]) {
        let markers = TripMapMarker.group(stations, points: points)
        var markerOf: [PersistentIdentifier: Int] = [:]
        for (index, marker) in markers.enumerated() {
            for member in marker.members { markerOf[member.id] = index }
        }
        var route: [CGPoint] = []
        var last: Int?
        for station in stations {
            guard let index = markerOf[station.id] else { continue }
            if index != last { route.append(markers[index].point) }
            last = index
        }
        self.markers = markers
        self.route = route
        let guards = markers.map {
            LabelGuard(id: $0.id, name: $0.members[0].name, latitude: $0.coordinate.latitude,
                       longitude: $0.coordinate.longitude, isGroup: $0.isGroup)
        }
        if guards != self.guards { self.guards = guards }
    }
}

struct TripRouteMap: View {
    let stations: [TripMapStation]
    @Binding var focus: TripMapFocus?
    /// The callout's tap: the page shows that stop in its list.
    let onOpenStop: (PersistentIdentifier) -> Void

    @State private var cameraPosition: MapCameraPosition
    /// The map's measured size and the sides it runs under system chrome
    /// (the iPhone Duo's status column and tab rail), kept clear of the route.
    @State private var layout = MapLayout(size: TripRouteMap.assumedSize, covered: EdgeInsets())
    @State private var live: TripMapLiveLayout

    nonisolated struct MapLayout: Equatable, Sendable {
        var size: CGSize
        var covered: EdgeInsets
    }

    @Environment(\.self) private var environment

    init(stations: [TripMapStation], focus: Binding<TripMapFocus?>, onOpenStop: @escaping (PersistentIdentifier) -> Void) {
        self.stations = stations
        _focus = focus
        self.onOpenStop = onOpenStop
        let framing = Self.framing(for: stations, size: Self.assumedSize, covered: EdgeInsets())
        _cameraPosition = State(initialValue: framing.map { .rect($0.rect) } ?? .automatic)
        _live = State(initialValue: TripMapLiveLayout())
    }

    var body: some View {
        Group {
            // Pan and zoom as before; the map stays north up and flat, so its
            // visible rect is the projection the overlay draws with.
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                // A night veil over the basemap, under its labels and the route:
                // MapKit's muted dark style still paints land in greens, and the
                // design's map is near black so the cobalt route carries it.
                if environment.colorScheme == .dark {
                    ForEach(Self.veil.indices, id: \.self) { index in
                        MapPolygon(coordinates: Self.veil[index])
                            .foregroundStyle(Color.black.opacity(0.45))
                            .mapOverlayLevel(level: .aboveRoads)
                    }
                }
                // Clear stand-ins for the drawn stations: MapKit keeps its own
                // place labels off them, as it did off the stations it drew.
                ForEach(live.guards) { spot in
                    Annotation(spot.name, coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude), anchor: .center) {
                        Color.clear
                            .frame(width: spot.isGroup ? 28 : 20, height: spot.isGroup ? 28 : 20)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .accessibilityHidden(true)
            // Frame the route below the navigation buttons and clear of the edges.
            // The camera frames the route itself (`framing(for:)`); the map
            // keeps no safe area, or MapKit would shift that frame again.
            .ignoresSafeArea()
            .onGeometryChange(for: MapLayout.self) { geometry in
                MapLayout(size: geometry.size, covered: EdgeInsets(
                    top: 0, leading: geometry.safeAreaInsets.leading, bottom: 0, trailing: geometry.safeAreaInsets.trailing))
            } action: { newLayout in
                guard newLayout.size.width > 0, newLayout.size.height > 0, newLayout != layout else { return }
                layout = newLayout
                if let framing = Self.framing(for: stations, size: newLayout.size, covered: newLayout.covered) {
                    cameraPosition = .rect(framing.rect)
                    relayout(rect: framing.rect)
                }
            }
            // Every camera frame (a pan, a pinch, a double-tap zoom) moves the
            // stations and regroups them; moving the map closes a callout.
            .onMapCameraChange(frequency: .continuous) { context in
                if let last = live.lastRect, focus != nil, Date.now > live.programmaticMoveUntil,
                   Self.moved(from: last, to: context.rect) {
                    focus = nil
                }
                live.lastRect = context.rect
                relayout(rect: context.rect)
            }
            .onChange(of: stations) { _, _ in
                relayout(rect: live.lastRect)
            }
            .onChange(of: focus) { _, new in
                if case .listed(let id) = new { reveal(id) }
            }
            .onTapGesture { location in
                tap(location)
            }
            // Clipped like the map under it: a station panned past the
            // map's edge must not draw over the page below.
            .overlay {
                TripMapOverlay(
                    live: live,
                    safe: safeArea,
                    focus: $focus,
                    onOpenStop: onOpenStop)
                    .clipped()
            }
            .onAppear {
                if live.markers.isEmpty, let framing = Self.framing(for: stations, size: layout.size, covered: layout.covered) {
                    relayout(rect: framing.rect)
                }
            }
        }
    }

    /// A stop chosen in the list whose station the user panned or zoomed
    /// out of view: the camera eases back to the trip's framing, keeping
    /// the selection through the move.
    private func reveal(_ id: PersistentIdentifier) {
        guard let marker = live.markers.first(where: { $0.contains(id) }) else { return }
        let size = layout.size
        let visible = CGRect(
            x: layout.covered.leading + 8, y: 100,
            width: max(1, size.width - layout.covered.leading - layout.covered.trailing - 16),
            height: max(1, size.height - 108))
        guard !visible.contains(marker.point),
              let framing = Self.framing(for: stations, size: size, covered: layout.covered) else { return }
        live.programmaticMoveUntil = .now.addingTimeInterval(1.5)
        withAnimation(.smooth(duration: 0.6)) {
            cameraPosition = .rect(framing.rect)
        }
    }

    /// The stations on screen: the visible map rect stretched over the
    /// map's frame (the requested frame's until the map reports its own).
    private func relayout(rect: MKMapRect?) {
        guard let rect else { return }
        let projection = TripMapProjection(rect: rect, size: layout.size)
        live.update(stations, points: stations.map { projection.point($0.coordinate) })
    }

    /// Whether the camera moved more than a rounding error.
    private static func moved(from a: MKMapRect, to b: MKMapRect) -> Bool {
        let tolerance = max(a.width, 1) * 0.002
        return abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    /// A tap on the map: the nearest marker within 22 pt (a 44 pt hit area)
    /// opens; empty map closes the callout. The corner with MapKit's logo
    /// and Legal link stays MapKit's.
    private func tap(_ location: CGPoint) {
        if location.x < layout.covered.leading + 110, location.y > layout.size.height - 30 { return }
        let nearest = live.markers
            .map { ($0, hypot($0.point.x - location.x, $0.point.y - location.y)) }
            .filter { $0.1 <= 22 }
            .min { $0.1 < $1.1 }?.0
        if let nearest {
            if let opened = TripMapOverlay.focus(opening: nearest, current: focus) { focus = opened }
        } else {
            focus = nil
        }
    }

    /// Callouts stay inside the map, 12 pt from its sides and foot and
    /// some 8 pt below the navigation buttons.
    private var safeArea: CGRect {
        let size = layout.size
        let minX = layout.covered.leading + 12
        let maxX = size.width - layout.covered.trailing - 12
        let top: CGFloat = 114
        return CGRect(x: minX, y: top, width: max(1, maxX - minX), height: max(1, size.height - 12 - top))
    }
}

extension TripRouteMap {
    /// The first frame's guess, until the map has measured itself.
    static let assumedSize = CGSize(width: 400, height: 300)

    /// The whole world in four quarters (each under 180 degrees wide, so
    /// MapKit never takes the short way round), so no edge ever shows.
    static let veil: [[CLLocationCoordinate2D]] = stride(from: -180.0, to: 180, by: 90).map { west in
        let east = west + 90
        return [
            CLLocationCoordinate2D(latitude: -85, longitude: west),
            CLLocationCoordinate2D(latitude: 85, longitude: west),
            CLLocationCoordinate2D(latitude: 85, longitude: east),
            CLLocationCoordinate2D(latitude: -85, longitude: east),
        ]
    }

    /// Frames the stations, not the veil: `.automatic` would fit every
    /// piece of map content, the world-sized veil included.
    /// `size` is the map's place on the page; `covered` how far it runs
    /// past that under system chrome, where the route must not go.
    /// Returns the map rect and the size it is drawn over.
    static func framing(for stations: [TripMapStation], size: CGSize, covered: EdgeInsets) -> (rect: MKMapRect, size: CGSize)? {
        framing(for: stations.map(\.coordinate), size: size, covered: covered)
    }

    static func framing(for coordinates: [CLLocationCoordinate2D], size: CGSize, covered: EdgeInsets) -> (rect: MKMapRect, size: CGSize)? {
        guard let first = coordinates.first else { return nil }
        let xs = routeXs(coordinates)
        let points = zip(xs, coordinates).map { MKMapPoint(x: $0, y: MKMapPoint($1).y) }
        let rect = points.dropFirst().reduce(MKMapRect(origin: points[0], size: MKMapSize())) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize()))
        }
        // A floor for stops a street apart, so the frame stays readable;
        // a single stop shows its town.
        let floor: CLLocationDistance = coordinates.count == 1 ? 8_000 : 4_000
        let minimum = MKMapPointsPerMeterAtLatitude(first.latitude) * floor
        let width = max(rect.width, minimum), height = max(rect.height, minimum)
        // The route's box on the drawn map: clear of the glass buttons
        // above, and some 104 pt in from the page's sides. The camera then
        // shows the whole map around it.
        let map = CGSize(width: size.width + covered.leading + covered.trailing, height: size.height)
        let box = CGRect(x: covered.leading + 104, y: 112,
                         width: max(1, size.width - 208), height: max(1, size.height - 144))
        let scale = max(width / box.width, height / box.height)
        let origin = MKMapPoint(x: rect.midX - box.midX * scale, y: rect.midY - box.midY * scale)
        return (MKMapRect(origin: origin, size: MKMapSize(width: map.width * scale, height: map.height * scale)), map)
    }

    /// The stations' map x on one stretch of world copies: the narrowest
    /// that holds them all, which starts after the widest empty stretch of
    /// longitude between them. A trip either side of the dateline frames
    /// across it, not round the world through Greenwich; a route whose
    /// widest gap already spans the dateline (every ordinary one) keeps
    /// its plain x. A route wider than half the world frames the same way,
    /// on the side of the globe it covers.
    static func routeXs(_ coordinates: [CLLocationCoordinate2D]) -> [Double] {
        let world = TripMapProjection.worldWidth
        let xs = coordinates.map { MKMapPoint($0).x }
        let sorted = xs.sorted()
        guard let lowest = sorted.first, let highest = sorted.last else { return xs }
        // The gap across the dateline first, so a tie keeps the plain frame.
        var gap = lowest + world - highest
        var west = lowest
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > gap {
            gap = b - a
            west = b
        }
        return xs.map { $0 < west ? $0 + world : $0 }
    }
}

// MARK: - Markers

/// A station on the map: the plain ring (16 pt for a base, 11 pt for a
/// visit), a double ring for touching places, or the selected cobalt disc
/// with its casing and soft glow.
private struct TripMapMarkerView: View {
    let isBase: Bool
    let isGroup: Bool
    let isSelected: Bool
    let line: Color
    let casing: Color
    let glow: Color

    var body: some View {
        let ring: CGFloat = isBase ? 8 : 5.5
        ZStack {
            if isGroup {
                let outer = ring + 4.5
                Circle()
                    .fill(casing)
                    .frame(width: (outer + 1.5) * 2, height: (outer + 1.5) * 2)
                Circle()
                    .stroke(line, lineWidth: 1.6)
                    .frame(width: outer * 2, height: outer * 2)
                if isSelected {
                    Circle()
                        .fill(line)
                        .frame(width: (ring + 1.75) * 2, height: (ring + 1.75) * 2)
                } else {
                    station(ring)
                }
            } else if isSelected {
                let radius: CGFloat = isBase ? 12 : 9.5
                Circle()
                    .fill(glow)
                    .frame(width: (radius + 3) * 2, height: (radius + 3) * 2)
                    .blur(radius: 3)
                Circle()
                    .fill(line)
                    .overlay(Circle().stroke(casing, lineWidth: 2.5))
                    .frame(width: radius * 2, height: radius * 2)
            } else {
                station(ring)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    /// The plain ring: a 3.5 pt line-coloured stroke on the casing.
    private func station(_ ring: CGFloat) -> some View {
        Circle()
            .fill(casing)
            .overlay(Circle().strokeBorder(line, lineWidth: 3.5))
            .frame(width: ring * 2 + 3.5, height: ring * 2 + 3.5)
    }
}

/// The small ring that leads a chooser row: the station's own kind.
private struct TripMapMiniRing: View {
    let isBase: Bool

    var body: some View {
        let radius: CGFloat = isBase ? 5 : 3.6
        Circle()
            .fill(AppTheme.routeCasing)
            .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: 2.4))
            .frame(width: radius * 2 + 2.4, height: radius * 2 + 2.4)
            .frame(width: 16, height: 16)
    }
}

// MARK: - Overlay: hit areas, callouts, the chooser

nonisolated private enum PointerSide {
    /// The callout sits above; its pointer points down at the station.
    case down
    case up
    /// The callout sits to the left; its pointer points right.
    case right
    case left
}

/// Placement of the callout and the chooser: above, below, then the side
/// with more room, then the other, each inside the safe area; the first
/// that covers no other station wins.
private enum CalloutPlacement {
    /// A station to keep clear: centre and radius.
    struct Obstacle {
        let center: CGPoint
        let radius: CGFloat
    }

    static func covers(_ box: CGRect, _ obstacles: [Obstacle]) -> Bool {
        obstacles.contains { o in
            box.minX - o.radius < o.center.x && o.center.x < box.maxX + o.radius
                && box.minY - o.radius < o.center.y && o.center.y < box.maxY + o.radius
        }
    }

    private static func fits(_ box: CGRect, _ safe: CGRect) -> Bool {
        box.minX >= safe.minX - 0.5 && box.maxX <= safe.maxX + 0.5
            && box.minY >= safe.minY - 0.5 && box.maxY <= safe.maxY + 0.5
    }

    private static func clampX(_ left: CGFloat, width: CGFloat, safe: CGRect) -> CGFloat {
        max(safe.minX, min(left, safe.maxX - width))
    }

    static func box(anchor p: CGPoint, radius r: CGFloat, size: CGSize, safe: CGRect,
                    obstacles: [Obstacle], gap: CGFloat = 11) -> (CGRect, PointerSide) {
        let w = size.width, h = size.height
        let cx = clampX(p.x - w / 2, width: w, safe: safe)
        var candidates: [(CGRect, PointerSide)] = [
            (CGRect(x: cx, y: p.y - r - gap - h, width: w, height: h), .down),
            (CGRect(x: cx, y: p.y + r + gap, width: w, height: h), .up),
        ]
        let top = max(safe.minY, min(p.y - h / 2, safe.maxY - h))
        var sides: [(CGRect, PointerSide)] = [
            (CGRect(x: p.x - r - gap - w, y: top, width: w, height: h), .right),
            (CGRect(x: p.x + r + gap, y: top, width: w, height: h), .left),
        ]
        if safe.maxX - p.x > p.x - safe.minX { sides.reverse() }
        candidates += sides
        let fitting = candidates.filter { fits($0.0, safe) }
        if let clear = fitting.first(where: { !covers($0.0, obstacles) }) { return clear }
        if let first = fitting.first { return first }
        return (CGRect(x: cx, y: max(safe.minY, p.y - r - gap - h), width: w, height: h), .down)
    }

    /// The chooser's box: full size where `box` finds room clear of its own
    /// ring; otherwise each side shrinks to the room it has, never over the
    /// ring, and the largest of at least 160 x 100 wins.
    static func list(anchor p: CGPoint, radius r: CGFloat, size: CGSize, safe: CGRect,
                     obstacles: [Obstacle], gap: CGFloat = 11) -> (CGRect, PointerSide) {
        let full = box(anchor: p, radius: r, size: size, safe: safe, obstacles: obstacles, gap: gap)
        if fits(full.0, safe), !covers(full.0, [Obstacle(center: p, radius: r + gap - 1)]) {
            return full
        }
        let w = size.width, h = size.height
        let above = min(h, p.y - r - gap - safe.minY)
        let below = min(h, safe.maxY - (p.y + r + gap))
        let top = max(safe.minY, min(p.y - h / 2, safe.maxY - h))
        let leftWidth = min(w, p.x - r - gap - safe.minX)
        let rightWidth = min(w, safe.maxX - (p.x + r + gap))
        let cx = clampX(p.x - w / 2, width: w, safe: safe)
        let candidates: [(CGRect, PointerSide)] = [
            (CGRect(x: cx, y: p.y - r - gap - above, width: w, height: above), .down),
            (CGRect(x: cx, y: p.y + r + gap, width: w, height: below), .up),
            (CGRect(x: p.x - r - gap - leftWidth, y: top, width: leftWidth, height: h), .right),
            (CGRect(x: p.x + r + gap, y: top, width: rightWidth, height: h), .left),
        ]
        let usable = candidates
            .filter { $0.0.width >= 160 && $0.0.height >= 100 }
            .sorted { $0.0.width * $0.0.height > $1.0.width * $1.0.height }
        return usable.first ?? full
    }
}

/// The glass callout's outline: its rounded box and a 16 x 9.5 pt pointer,
/// tip 2 pt off the station, in one path so the hairline runs round both.
nonisolated private struct CalloutBubble: Shape {
    let box: CGRect
    let tip: CGPoint
    let side: PointerSide

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 14, half: CGFloat = 8
        let body = Path(roundedRect: box, cornerRadius: radius, style: .continuous)
        var pointer = Path()
        switch side {
        case .down, .up:
            let baseX = min(max(tip.x, box.minX + radius + half), box.maxX - radius - half)
            let baseY = side == .down ? box.maxY - 0.5 : box.minY + 0.5
            pointer.move(to: CGPoint(x: baseX - half, y: baseY))
            pointer.addLine(to: tip)
            pointer.addLine(to: CGPoint(x: baseX + half, y: baseY))
        case .right, .left:
            let baseY = min(max(tip.y, box.minY + radius + half), box.maxY - radius - half)
            let baseX = side == .right ? box.maxX - 0.5 : box.minX + 0.5
            pointer.move(to: CGPoint(x: baseX, y: baseY - half))
            pointer.addLine(to: tip)
            pointer.addLine(to: CGPoint(x: baseX, y: baseY + half))
        }
        pointer.closeSubpath()
        return body.union(pointer)
    }
}

/// The callout's and the chooser's type: the design's 15, 13, 12 and 11 pt
/// at the default size, following the reader's text size up to xxxLarge so
/// a callout still fits inside the map. Line heights keep the design's ratios.
private struct CalloutMetrics: Equatable {
    let nameSize: CGFloat
    let captionSize: CGFloat
    let rowCaptionSize: CGFloat
    let chevronSize: CGFloat

    init(_ dynamicTypeSize: DynamicTypeSize) {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(min(dynamicTypeSize, .xxxLarge)))
        func scaled(_ value: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
            UIFontMetrics(forTextStyle: style).scaledValue(for: value, compatibleWith: traits)
        }
        nameSize = scaled(15, .subheadline)
        captionSize = scaled(13, .footnote)
        rowCaptionSize = scaled(12, .caption1)
        chevronSize = scaled(12, .footnote)
    }

    var name: Font { .system(size: nameSize, weight: .semibold) }
    var caption: Font { .system(size: captionSize) }
    var rowCaption: Font { .system(size: rowCaptionSize) }

    /// The callout's name line (20 pt at the default size) and caption (17).
    var nameLine: CGFloat { ceil(nameSize * 20 / 15) }
    var captionLine: CGFloat { ceil(captionSize * 17 / 13) }
    /// The chooser's name line (19) and caption (16).
    var rowNameLine: CGFloat { ceil(nameSize * 19 / 15) }
    var rowCaptionLine: CGFloat { ceil(rowCaptionSize * 16 / 12) }
    var chevronWidth: CGFloat { ceil(chevronSize) }

    func nameWidth(_ text: String) -> CGFloat {
        width(text, UIFont.systemFont(ofSize: nameSize, weight: .semibold))
    }

    func captionWidth(_ text: String) -> CGFloat {
        width(text, UIFont.systemFont(ofSize: captionSize))
    }

    /// A chooser row: 46 pt with a one-line name, 64 with two, at the default size.
    func rowHeight(lines: Int) -> CGFloat {
        CGFloat(lines) * rowNameLine + rowCaptionLine + (lines == 1 ? 11 : 10)
    }

    private func width(_ text: String, _ font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The map's touch layer and what it opens: an invisible 44 pt hit area
/// round every marker (the nearest within 22 pt wins), the callout and the
/// chooser. Empty map dismisses.
private struct TripMapOverlay: View {
    /// The markers and route where the camera now draws them.
    let live: TripMapLiveLayout
    let safe: CGRect
    @Binding var focus: TripMapFocus?
    let onOpenStop: (PersistentIdentifier) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let listWidth: CGFloat = 214
    private static let listMaxHeight: CGFloat = 180

    private struct Callout {
        enum Content {
            case place(TripMapStation, CalloutMetrics)
            case chooser([TripMapStation], tinted: PersistentIdentifier?, rowHeights: [CGFloat], metrics: CalloutMetrics)
        }
        let content: Content
        let box: CGRect
        let tip: CGPoint
        let side: PointerSide
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The route and its stations, drawn over the basemap in the
            // map's own projection, so a group's members meet at its ring.
            routeLayer
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // VoiceOver's stations: the map itself is hidden from it.
            ForEach(live.markers) { marker in
                Color.clear
                    .frame(width: 44, height: 44)
                    .position(marker.point)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityLabel(for: marker))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open(marker) }
            }

            if let callout = currentCallout {
                calloutView(callout)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: focus)
    }

    // MARK: Route

    /// The cobalt line on its dark casing and soft bloom, then the stations,
    /// the selected one on top.
    private var routeLayer: some View {
        let selected = focus?.selectedPlace
        let markers = live.markers
        let route = live.route
        let ordered = markers.sorted { !$0.contains(selected) && $1.contains(selected) }
        return ZStack(alignment: .topLeading) {
            if route.count >= 2 {
                Canvas { context, _ in
                    var path = Path()
                    path.addLines(route)
                    let round = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
                    var bloom = context
                    bloom.addFilter(.blur(radius: 4))
                    bloom.stroke(path, with: .color(AppTheme.accentGlow), style: round(10))
                    context.stroke(path, with: .color(AppTheme.routeCasing), style: round(8.5))
                    context.stroke(path, with: .color(AppTheme.routeLine), style: round(4.5))
                }
            }
            ForEach(ordered) { marker in
                TripMapMarkerView(
                    isBase: marker.isBase, isGroup: marker.isGroup,
                    isSelected: marker.contains(selected),
                    line: AppTheme.routeLine, casing: AppTheme.routeCasing, glow: AppTheme.accentGlow)
                    .position(marker.point)
            }
        }
    }

    // MARK: Opening

    /// A station selects itself; a double ring only opens its chooser.
    /// Nil leaves an open chooser as it is.
    static func focus(opening marker: TripMapMarker, current: TripMapFocus?) -> TripMapFocus? {
        if marker.isGroup {
            if case .group(let id) = current, marker.contains(id) { return nil }
            return .group(marker.id)
        }
        return .place(marker.id)
    }

    private func open(_ marker: TripMapMarker) {
        if let opened = Self.focus(opening: marker, current: focus) { focus = opened }
    }

    private func accessibilityLabel(for marker: TripMapMarker) -> String {
        if marker.isGroup {
            return marker.members.map(\.name)
                .formatted(.list(type: .and).locale(AppLanguagePreference.currentLocale()))
        }
        let station = marker.members[0]
        return "\(station.name), \(station.caption)"
    }

    // MARK: Layout

    private var currentCallout: Callout? {
        let markers = live.markers
        let metrics = CalloutMetrics(dynamicTypeSize)
        guard let focus,
              let marker = markers.first(where: { $0.contains(focus.focusedID) }) else { return nil }
        let obstacles = markers
            .filter { $0.id != marker.id }
            .map { CalloutPlacement.Obstacle(center: $0.point, radius: $0.isBase ? 10 : 8) }
        let groupRadius = marker.ringRadius + 6
        switch focus {
        case .group:
            return chooser(marker, tinted: nil, radius: groupRadius, obstacles: obstacles, metrics: metrics)
        case .listed(let id) where marker.isGroup:
            return chooser(marker, tinted: id, radius: groupRadius, obstacles: obstacles, metrics: metrics)
        case .place(let id), .listed(let id):
            guard let station = marker.members.first(where: { $0.id == id }) else { return nil }
            let radius = marker.isGroup ? groupRadius : (marker.isBase ? 12 : 9.5)
            let nameWidth = metrics.nameWidth(station.name)
            let captionWidth = metrics.captionWidth(station.caption)
            // 14 lead, 12 trail, the 10 pt gap and the chevron.
            let chrome = 36 + metrics.chevronWidth
            let width = min(max(nameWidth, captionWidth) + chrome, safe.width)
            let nameLines: CGFloat = nameWidth + chrome > width ? 2 : 1
            // 9 above, 2 between, 10 below: 58 pt at the default size.
            let height = 9 + nameLines * metrics.nameLine + 2 + metrics.captionLine + 10
            let (box, side) = CalloutPlacement.box(
                anchor: marker.point, radius: radius,
                size: CGSize(width: ceil(width), height: height), safe: safe, obstacles: obstacles)
            return Callout(content: .place(station, metrics), box: box,
                           tip: Self.tip(marker.point, radius: radius, side: side), side: side)
        }
    }

    private func chooser(_ marker: TripMapMarker, tinted: PersistentIdentifier?, radius: CGFloat,
                         obstacles: [CalloutPlacement.Obstacle], metrics: CalloutMetrics) -> Callout {
        func heights(_ width: CGFloat) -> [CGFloat] {
            // The text column: the width less 11 lead, the 16 pt ring, two
            // 9 pt gaps, the chevron and 12 trail.
            let column = width - 57 - (metrics.chevronWidth - 1)
            return marker.members.map { metrics.rowHeight(lines: metrics.nameWidth($0.name) <= column ? 1 : 2) }
        }
        let fullHeight = heights(Self.listWidth).reduce(8, +)
        let (placed, side) = CalloutPlacement.list(
            anchor: marker.point, radius: radius,
            size: CGSize(width: Self.listWidth, height: min(fullHeight, Self.listMaxHeight)),
            safe: safe, obstacles: obstacles)
        let rowHeights = heights(placed.width)
        var box = placed
        let height = min(rowHeights.reduce(8, +), placed.height)
        if side == .down { box.origin.y = placed.maxY - height }
        box.size.height = height
        return Callout(content: .chooser(marker.members, tinted: tinted, rowHeights: rowHeights, metrics: metrics),
                       box: box, tip: Self.tip(marker.point, radius: radius, side: side), side: side)
    }

    private static func tip(_ p: CGPoint, radius r: CGFloat, side: PointerSide) -> CGPoint {
        let gap = r + 2
        switch side {
        case .down: return CGPoint(x: p.x, y: p.y - gap)
        case .up: return CGPoint(x: p.x, y: p.y + gap)
        case .right: return CGPoint(x: p.x - gap, y: p.y)
        case .left: return CGPoint(x: p.x + gap, y: p.y)
        }
    }

    // MARK: Drawing

    private func calloutView(_ callout: Callout) -> some View {
        let bubble = CalloutBubble(box: callout.box, tip: callout.tip, side: callout.side)
        return ZStack(alignment: .topLeading) {
            ZStack {
                bubble
                    .fill(TripPageTint.calloutFill)
                    .shadow(color: TripPageTint.calloutShadow, radius: 12, y: 8)
                bubble.fill(.ultraThinMaterial)
                bubble.fill(TripPageTint.calloutFill)
                bubble.stroke(TripPageTint.calloutEdge, lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            calloutContent(callout)
        }
    }

    private func calloutContent(_ callout: Callout) -> some View {
        Group {
            switch callout.content {
            case .place(let station, let metrics):
                placeCallout(station, metrics: metrics)
            case .chooser(let members, let tinted, let rowHeights, let metrics):
                TripMapChooser(
                    members: members, tinted: tinted, rowHeights: rowHeights, metrics: metrics,
                    size: callout.box.size,
                    onChoose: { focus = .place($0) })
            }
        }
        .frame(width: callout.box.width, height: callout.box.height)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .position(x: callout.box.midX, y: callout.box.midY)
    }

    private func placeCallout(_ station: TripMapStation, metrics: CalloutMetrics) -> some View {
        Button {
            onOpenStop(station.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: station.name)
                        .font(metrics.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(minHeight: metrics.nameLine)
                    Text(verbatim: station.caption)
                        .font(metrics.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: metrics.captionLine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.chevronSize, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(width: metrics.chevronWidth)
            }
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(station.name), \(station.caption)"))
        .accessibilityHint(String(
            localized: "trip-detail.map.callout.hint",
            defaultValue: "Shows this stop in the list.",
            comment: "VoiceOver hint on the trip map's callout naming a tapped stop; activating it scrolls the page to that stop's row."))
    }
}

/// The chooser of a double ring: one row per place (its ring, its name on
/// up to two lines, its dates and time there, a chevron). Past 180 pt the
/// rows scroll inside, under 16 pt fades with a 3 pt indicator; the glass
/// edge stays crisp.
private struct TripMapChooser: View {
    let members: [TripMapStation]
    let tinted: PersistentIdentifier?
    let rowHeights: [CGFloat]
    let metrics: CalloutMetrics
    let size: CGSize
    let onChoose: (PersistentIdentifier) -> Void

    @State private var offset: CGFloat = 0

    var body: some View {
        let total = rowHeights.reduce(8, +)
        let scrolls = total > size.height + 0.5
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, station in
                        row(station, index: index)
                            .id(station.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollDisabled(!scrolls)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, new in
                offset = new
            }
            .onAppear {
                if scrolls, let tinted { reader.scrollTo(tinted, anchor: .center) }
            }
        }
        .mask {
            if scrolls {
                let range = max(1, total - size.height)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: offset > 0.5 ? 16 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: offset < range - 0.5 ? 16 : 0)
                }
            } else {
                Color.black
            }
        }
        .overlay(alignment: .topTrailing) {
            if scrolls {
                let track = size.height - 12
                let bar = max(24, track * size.height / total)
                let progress = min(max(offset / max(1, total - size.height), 0), 1)
                Capsule()
                    .fill(TripPageTint.scrollIndicator)
                    .frame(width: 3, height: bar)
                    .padding(.top, 6 + (track - bar) * progress)
                    .padding(.trailing, 2.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func row(_ station: TripMapStation, index: Int) -> some View {
        let isTinted = station.id == tinted
        let followsTinted = index > 0 && members[index - 1].id == tinted
        return Button {
            onChoose(station.id)
        } label: {
            HStack(spacing: 9) {
                TripMapMiniRing(isBase: station.isBase)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: station.name)
                        .font(metrics.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: station.caption)
                        .font(metrics.rowCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.chevronSize - 1, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(width: metrics.chevronWidth - 1)
            }
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .frame(height: rowHeights[index])
            .frame(maxWidth: .infinity)
            .background(isTinted ? TripPageTint.flash : .clear)
            .overlay(alignment: .top) {
                if index > 0, !isTinted, !followsTinted {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 0.5)
                        .padding(.leading, 36)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(station.name), \(station.caption)"))
        .accessibilityAddTraits(isTinted ? .isSelected : [])
    }
}
