//
//  FlightRouteMap.swift
//  TravelLog
//
//  An offline schematic using the country outlines already bundled with
//  TravelLog. Country decoding and route preparation run once per input,
//  outside body; filtering does not re-read GeoJSON or request map tiles.
//

import MapKit
import SwiftUI

struct FlightRouteMap: View {
    let records: [CollectionsAggregator.FlightRecord]
    var isCandidate = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var drawing: FlightRouteGeometry.Drawing?
    @State private var land: [[FlightRouteGeometry.Point]] = []

    private var routes: [FlightRouteGeometry.Route] {
        let identities = FlightLogProjection.geographicIdentities(for: records)
        return zip(records, identities).map { record, identity in
            let departure = Self.waypoint(
                code: record.departureAirportResolution == .observedNearby ? record.departureCode : nil,
                geographicIdentity: identity.departure,
                place: record.departurePlace, iso: record.departureISO,
                latitude: record.flightLogDepartureLatitude, longitude: record.flightLogDepartureLongitude)
            let arrival = Self.waypoint(
                code: record.arrivalAirportResolution == .observedNearby ? record.arrivalCode : nil,
                geographicIdentity: identity.arrival,
                place: record.arrivalPlace, iso: record.arrivalISO,
                latitude: record.flightLogArrivalLatitude, longitude: record.flightLogArrivalLongitude)
            let stops = (record.stops ?? []).map { stop -> FlightRouteGeometry.Waypoint? in
                Self.waypoint(code: stop.code, geographicIdentity: nil, place: nil, iso: stop.isoCountryCode,
                              latitude: stop.latitude, longitude: stop.longitude)
            }
            return FlightRouteGeometry.Route(
                identity: FlightLogProjection.stableRouteIdentity(record, geographicIdentity: identity) ?? record.id.uuidString,
                points: [departure] + stops + [arrival])
        }
    }

    var body: some View {
        let inputs = routes
        Canvas(rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(AppTheme.inset.opacity(0.45)))
            guard let drawing else { return }
            drawLand(land, frame: drawing.frame, context: &context, size: size)
            drawRoutes(drawing, context: &context, size: size)
            drawLabels(drawing, context: &context, size: size)
        }
        .overlay {
            if let drawing, drawing.edges.isEmpty {
                Text(String(localized: "collections.flight-map.no-route",
                            defaultValue: "Not enough location detail to draw this route.",
                            comment: "Flight map placeholder when usable endpoint coordinates are missing."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.thumbLarge))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .task(id: MapInput(routes: inputs, isActive: scenePhase == .active)) {
            guard scenePhase == .active, !Task.isCancelled else { return }
            // Initial-active views need the same admission as RootView's
            // foreground hook; no onChange is emitted on a cold launch.
            FlightRouteLandCache.applicationDidBecomeActive()
            // A filter's old routes should not remain visible while the new
            // drawing is being prepared. Cancelling this view only discards
            // its result; completed thin outlines remain reusable. RootView
            // cancels a pending shared fill before releasing country polygons.
            drawing = nil
            async let outlines = FlightRouteLandCache.rings()
            let prepared = await Task.detached(priority: .utility) {
                FlightRouteGeometry.prepare(inputs)
            }.value
            let preparedLand = await outlines
            guard !Task.isCancelled else { return }
            land = preparedLand
            drawing = prepared
        }
    }

    private var accessibilitySummary: String {
        guard let drawing else {
            return String(localized: "collections.flight-map.accessibility.loading",
                          defaultValue: "Preparing schematic flight map.",
                          comment: "Accessibility description while the offline flight map is prepared.")
        }
        if drawing.edges.isEmpty {
            return String(localized: "collections.flight-map.no-route",
                          defaultValue: "Not enough location detail to draw this route.",
                          comment: "Flight map placeholder when usable endpoint coordinates are missing.")
        }
        if isCandidate {
            return String(localized: "collections.flight-map.accessibility.candidate",
                          defaultValue: "Schematic map of the possible route. The route is unconfirmed.",
                          comment: "Accessibility description of a possible flight's offline schematic map.")
        }
        return String(localized: "collections.flight-map.accessibility.routes",
                      defaultValue: "Recorded routes on a schematic map: \(drawing.routeCount). Repeated routes use stronger lines.",
                      comment: "Accessibility description of the offline flight map, with a unique route count.")
    }

    private struct MapInput: Equatable {
        let routes: [FlightRouteGeometry.Route]
        let isActive: Bool
    }

    private static func waypoint(code: String?, geographicIdentity: String?, place: String?, iso: String?,
                                 latitude: Double?, longitude: Double?) -> FlightRouteGeometry.Waypoint? {
        guard let latitude, let longitude else { return nil }
        let point = FlightRouteGeometry.Point(latitude: latitude, longitude: longitude)
        guard point.isValid else { return nil }
        let place = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = code ?? place.flatMap { $0.isEmpty ? nil : $0 }
            ?? iso.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? ""
        let identity = code.map { "airport:\($0.uppercased())" }
            ?? geographicIdentity
            // Unnamed positions should not collapse unrelated journeys to
            // one point. Round only for a stable fallback identity.
            ?? "point:\(Int((latitude * 10).rounded())):\(Int((longitude * 10).rounded()))"
        return FlightRouteGeometry.Waypoint(identity: identity, label: label, point: point)
    }

    private func drawLand(_ rings: [[FlightRouteGeometry.Point]], frame: FlightRouteGeometry.Frame,
                          context: inout GraphicsContext, size: CGSize) {
        var land = Path()
        for ring in rings where ring.count >= 3 {
            // Unwrap one whole country ring continuously, then repeat it
            // around the fitted center. Closing a dateline ring through
            // the map's middle would otherwise paint an entire continent.
            var unwrapped: [(latitude: Double, longitude: Double)] = []
            var lastLongitude = frame.centerLongitude
            for point in ring {
                let longitude = lastLongitude + FlightRouteGeometry.Frame.delta(point.longitude - lastLongitude)
                unwrapped.append((point.latitude, longitude))
                lastLongitude = longitude
            }
            guard let west = unwrapped.map(\.longitude).min(), let east = unwrapped.map(\.longitude).max() else { continue }
            for shift in [-360.0, 0, 360] where east + shift >= frame.centerLongitude - frame.longitudeSpan
                && west + shift <= frame.centerLongitude + frame.longitudeSpan {
                let points = unwrapped.map { coordinate in
                    let point = frame.point(latitude: coordinate.latitude, unwrappedLongitude: coordinate.longitude + shift,
                                            width: size.width, height: size.height)
                    return CGPoint(x: point.x, y: point.y)
                }
                land.addLines(points)
                land.closeSubpath()
            }
        }
        context.fill(land, with: .color(.secondary.opacity(0.12)), style: FillStyle(eoFill: true))
        context.stroke(land, with: .color(.secondary.opacity(0.13)), lineWidth: 0.5)
    }

    private func drawRoutes(_ drawing: FlightRouteGeometry.Drawing, context: inout GraphicsContext, size: CGSize) {
        for edge in drawing.edges {
            var path = Path()
            for run in FlightRouteGeometry.runs(edge.samples, frame: drawing.frame) {
                path.addLines(run.map { point($0, frame: drawing.frame, size: size) })
            }
            context.stroke(path, with: .color(AppTheme.bar.opacity(isCandidate ? 0.65 : 0.76)),
                           style: StrokeStyle(lineWidth: isCandidate ? 1.6 : edge.lineWidth,
                                              lineCap: .round, lineJoin: .round,
                                              dash: isCandidate ? [5, 4] : []))
        }
        for node in drawing.nodes {
            let position = point(node.point, frame: drawing.frame, size: size)
            let radius = node.visits > 2 ? 3.6 : 2.7
            let circle = Path(ellipseIn: CGRect(x: position.x - radius, y: position.y - radius,
                                              width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(AppTheme.card))
            context.stroke(circle, with: .color(AppTheme.bar), lineWidth: 1.6)
        }
    }

    private func drawLabels(_ drawing: FlightRouteGeometry.Drawing, context: inout GraphicsContext, size: CGSize) {
        let nodes = drawing.nodes.sorted {
            $0.visits == $1.visits ? $0.identity < $1.identity : $0.visits > $1.visits
        }
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5)
        var occupied: [CGRect] = []
        // Most routes are intentionally unlabelled: dots/line weights carry
        // the whole history while at most six labels give it an anchor.
        for node in nodes where occupied.count < 6 && !node.label.isEmpty {
            let origin = point(node.point, frame: drawing.frame, size: size)
            let label = node.label.count > 26 ? String(node.label.prefix(24)) + "…" : node.label
            let text = Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
            let resolved = context.resolve(text)
            // Measure the same single-line extent that the pill will draw.
            // Constraining measurement but drawing at a point lets long
            // names or large Dynamic Type escape the collision-tested rect.
            let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
            let size = CGSize(width: measured.width + 8, height: measured.height + 4)
            let candidates = [
                CGRect(x: origin.x + 6, y: origin.y - size.height / 2, width: size.width, height: size.height),
                CGRect(x: origin.x - size.width - 6, y: origin.y - size.height / 2, width: size.width, height: size.height),
                CGRect(x: origin.x - size.width / 2, y: origin.y + 7, width: size.width, height: size.height)
            ]
            guard let rect = candidates.first(where: { candidate in
                visible.contains(candidate) && !occupied.contains(where: { $0.intersects(candidate.insetBy(dx: -4, dy: -3)) })
            }) else { continue }
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(AppTheme.card.opacity(0.9)))
            let textRect = rect.insetBy(dx: 4, dy: 2)
            var labelContext = context
            labelContext.clip(to: Path(textRect))
            labelContext.draw(resolved, in: textRect)
            occupied.append(rect)
        }
    }

    private func point(_ point: FlightRouteGeometry.Point, frame: FlightRouteGeometry.Frame, size: CGSize) -> CGPoint {
        let point = frame.point(point, width: size.width, height: size.height)
        return CGPoint(x: point.x, y: point.y)
    }
}

/// One lazily loaded outline cache shared by overview and detail maps.
/// Only completed thin coordinate rings survive backgrounding; a pending fill
/// is cancelled before RootView releases the provider's decoded polygons.
@MainActor
final class FlightRouteLandCache {
    typealias Rings = [[FlightRouteGeometry.Point]]
    private static let shared = FlightRouteLandCache(loader: loadRings)

    private let loader: @MainActor @Sendable () async -> Rings
    private var completed: Rings?
    private var task: Task<Rings, Never>?
    private var generation: UInt64 = 0
    private var suspended = false

    // Injectable loader keeps lifecycle verification independent of the
    // process-global provider and of real decoding or background timing.
    init(loader: @escaping @MainActor @Sendable () async -> Rings) {
        self.loader = loader
    }

    static func rings() async -> Rings { await shared.value() }
    static func applicationDidBecomeActive() { shared.resume() }
    static func applicationDidEnterBackground() { shared.suspend() }

    func resume() { suspended = false }

    func suspend() {
        suspended = true
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func value() async -> Rings {
        if let completed { return completed }
        guard !suspended, !Task.isCancelled else { return [] }
        let admittedGeneration = generation
        let pending: Task<Rings, Never>
        if let task {
            pending = task
        } else {
            let loader = loader
            pending = Task { await loader() }
            task = pending
        }
        let result = await pending.value
        // A cancelled fill may finish after a foreground replacement. It
        // must neither publish stale rings nor clear the replacement's task.
        guard admittedGeneration == generation, !suspended,
              !pending.isCancelled else { return [] }
        completed = result
        if task == pending { task = nil }
        return Task.isCancelled ? [] : result
    }

    private static func loadRings() async -> Rings {
        let codes = Set(FlagAssetCodes.shipped.map { $0.uppercased() })
        let countries = await CountryPolygonProvider.polygons(for: codes)
        guard !Task.isCancelled else { return [] }
        let thinning = Task.detached(priority: .utility) { thin(countries) }
        return await withTaskCancellationHandler {
            await thinning.value
        } onCancel: {
            // Unstructured detached work does not inherit later cancellation.
            thinning.cancel()
        }
    }

    private nonisolated static func thin(_ countries: [CountryPolygonProvider.CountryPolygon]) -> Rings {
        var rings: Rings = []
        for country in countries {
            guard !Task.isCancelled else { return [] }
            let polygon = country.polygon
            let points = polygon.points()
            let stride = max(1, Int(ceil(Double(polygon.pointCount) / 720)))
            var ring: [FlightRouteGeometry.Point] = []
            for index in Swift.stride(from: 0, to: polygon.pointCount, by: stride) {
                if Task.isCancelled { return [] }
                let coordinate = points[index].coordinate
                let point = FlightRouteGeometry.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
                guard point.isValid else { continue }
                if let last = ring.last,
                   abs(last.latitude - point.latitude) + abs(FlightRouteGeometry.Frame.delta(last.longitude - point.longitude)) < 0.15 { continue }
                ring.append(point)
            }
            // Very small offshore islands add a disproportionate number of
            // paths at journal-card scale.
            if ring.count >= 3 { rings.append(ring) }
        }
        return rings
    }
}
