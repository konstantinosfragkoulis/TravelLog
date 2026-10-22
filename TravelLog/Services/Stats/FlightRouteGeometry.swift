//
//  FlightRouteGeometry.swift
//  TravelLog
//
//  Pure, offline geometry for the flight journal's schematic maps. Repeated
//  hops share one stroke; samples follow the great circle, never the long
//  way around the antimeridian. A missing point breaks the route rather
//  than manufacturing a direct connection across it.
//

import Foundation

nonisolated enum FlightRouteGeometry {
    struct Point: Sendable, Equatable {
        let latitude: Double
        let longitude: Double

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }
    }

    struct Waypoint: Sendable, Equatable {
        /// Observed airport code or a bounded geographic cluster key.
        /// Display labels never supply geographic identity on their own.
        let identity: String
        let label: String
        let point: Point
    }

    struct Route: Sendable, Equatable {
        /// Stable full-journey identity, shared by outbound/return routes.
        let identity: String
        let points: [Waypoint?]
    }

    struct Node: Sendable, Equatable {
        let identity: String
        let label: String
        let point: Point
        let visits: Int
    }

    struct Edge: Sendable, Equatable {
        let identity: String
        let count: Int
        let samples: [Point]

        /// Repeated routes read more strongly without overwhelming the map.
        var lineWidth: Double { min(3.6, 1.1 + log2(Double(max(1, count))) * 0.55) }
    }

    struct Drawing: Sendable, Equatable {
        let nodes: [Node]
        let edges: [Edge]
        let routeCount: Int
        let frame: Frame

        static let empty = Drawing(nodes: [], edges: [], routeCount: 0,
                                   frame: Frame(centerLongitude: 0, centerLatitude: 0,
                                                longitudeSpan: 360, latitudeSpan: 160))
    }

    /// Longitude is centered on the smallest circular extent of the route.
    /// Local equirectangular scaling preserves useful city/country context;
    /// it is a schematic, not an interactive navigation map.
    struct Frame: Sendable, Equatable {
        let centerLongitude: Double
        let centerLatitude: Double
        let longitudeSpan: Double
        let latitudeSpan: Double

        var longitudeScale: Double { max(0.2, cos(centerLatitude * .pi / 180)) }

        func point(_ point: Point, width: Double, height: Double, inset: Double = 22) -> (x: Double, y: Double) {
            self.point(latitude: point.latitude,
                       unwrappedLongitude: centerLongitude + Self.delta(point.longitude - centerLongitude),
                       width: width, height: height, inset: inset)
        }

        /// Already-unwrapped country rings use this overload so a seam does
        /// not close a polygon across the full map.
        func point(latitude: Double, unwrappedLongitude: Double,
                   width: Double, height: Double, inset: Double = 22) -> (x: Double, y: Double) {
            let scale = min(max(1, width - inset * 2) / (longitudeSpan * longitudeScale),
                            max(1, height - inset * 2) / latitudeSpan)
            return (width / 2 + (unwrappedLongitude - centerLongitude) * longitudeScale * scale,
                    height / 2 - (latitude - centerLatitude) * scale)
        }

        static func delta(_ longitude: Double) -> Double {
            let wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
            return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
        }
    }

    static func prepare(_ routes: [Route]) -> Drawing {
        struct Bucket {
            var labels: [String] = []
            var points: [Point] = []
        }
        var buckets: [String: Bucket] = [:]
        for route in routes {
            for case let waypoint? in route.points where waypoint.point.isValid {
                buckets[waypoint.identity, default: Bucket()].labels.append(waypoint.label)
                buckets[waypoint.identity, default: Bucket()].points.append(waypoint.point)
            }
        }
        guard !buckets.isEmpty else { return .empty }

        // Sorting before summation makes refresh/filter order immaterial,
        // including for repeated endpoints on either side of the dateline.
        let nodes = buckets.map { identity, bucket -> Node in
            let ordered = bucket.points.sorted {
                $0.latitude == $1.latitude ? $0.longitude < $1.longitude : $0.latitude < $1.latitude
            }
            let anchor = ordered[0].longitude
            let latitude = ordered.reduce(0) { $0 + $1.latitude } / Double(ordered.count)
            let longitude = ordered.reduce(0) { $0 + anchor + Frame.delta($1.longitude - anchor) } / Double(ordered.count)
            let label = bucket.labels.sorted { left, right in
                left.count == right.count ? left < right : left.count < right.count
            }.first ?? ""
            return Node(identity: identity, label: label,
                        point: Point(latitude: latitude, longitude: Frame.delta(longitude)),
                        visits: ordered.count)
        }.sorted { $0.identity < $1.identity }
        let points = Dictionary(uniqueKeysWithValues: nodes.map { ($0.identity, $0.point) })
        var counts: [String: (from: String, to: String, count: Int)] = [:]
        var drawnRoutes: Set<String> = []
        for route in routes {
            var hasEdge = false
            for (from, to) in zip(route.points, route.points.dropFirst()) {
                guard let from, let to, from.point.isValid, to.point.isValid,
                      from.identity != to.identity,
                      let fromPoint = points[from.identity], let toPoint = points[to.identity],
                      angularDistance(fromPoint, toPoint) > 0.000_001 else { continue }
                let ends = [from.identity, to.identity].sorted()
                // A length prefix keeps identities containing separators safe.
                let key = "\(ends[0].utf8.count):\(ends[0])\(ends[1])"
                let previous = counts[key]?.count ?? 0
                counts[key] = (ends[0], ends[1], previous + 1)
                hasEdge = true
            }
            if hasEdge { drawnRoutes.insert(route.identity) }
        }
        let edges = counts.keys.sorted().compactMap { key -> Edge? in
            guard let edge = counts[key], let from = points[edge.from], let to = points[edge.to] else { return nil }
            return Edge(identity: key, count: edge.count, samples: greatCircle(from: from, to: to))
        }
        let allPoints = edges.flatMap(\.samples) + nodes.map(\.point)
        return Drawing(nodes: nodes, edges: edges, routeCount: drawnRoutes.count, frame: frame(allPoints))
    }

    static func frame(_ points: [Point]) -> Frame {
        let valid = points.filter(\.isValid)
        guard !valid.isEmpty else { return Drawing.empty.frame }
        let longitudes = valid.map { $0.longitude < 0 ? $0.longitude + 360 : $0.longitude }.sorted()
        var largestGap = -Double.infinity
        var start = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            let gap = next - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                start = next
            }
        }
        let extent = max(0, 360 - largestGap)
        let south = valid.map(\.latitude).min() ?? -80
        let north = valid.map(\.latitude).max() ?? 80
        return Frame(centerLongitude: Frame.delta(start + extent / 2),
                     centerLatitude: (south + north) / 2,
                     longitudeSpan: min(360, max(12, extent * 1.18)),
                     latitudeSpan: min(180, max(8, (north - south) * 1.25)))
    }

    /// Returns unwrapped runs, ready to project. A great-circle route that
    /// reaches the map's seam starts a new run instead of drawing a line
    /// through the wrong hemisphere.
    static func runs(_ samples: [Point], frame: Frame) -> [[Point]] {
        var result: [[Point]] = []
        var run: [Point] = []
        for point in samples where point.isValid {
            if let last = run.last,
               abs(Frame.delta(point.longitude - frame.centerLongitude)
                   - Frame.delta(last.longitude - frame.centerLongitude)) > 180 {
                if run.count > 1 { result.append(run) }
                run = []
            }
            run.append(point)
        }
        if run.count > 1 { result.append(run) }
        return result
    }

    static func greatCircle(from: Point, to: Point) -> [Point] {
        guard from.isValid, to.isValid else { return [] }
        let angle = angularDistance(from, to)
        guard angle > 0.000_001 else { return [from, to] }
        let segments = max(8, min(64, Int(ceil(angle * 180 / .pi / 3))))
        let denominator = sin(angle)
        let fromLatitude = from.latitude * .pi / 180
        let fromLongitude = from.longitude * .pi / 180
        let toLatitude = to.latitude * .pi / 180
        let toLongitude = to.longitude * .pi / 180
        return (0...segments).map { index in
            if index == 0 { return from }
            if index == segments { return to }
            let fraction = Double(index) / Double(segments)
            // Exactly opposite endpoints have no unique shortest arc.
            // A deterministic shortest-longitude interpolation is an honest
            // schematic fallback; it also avoids division by nearly zero.
            if abs(denominator) < 0.000_001 {
                return Point(latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                             longitude: Frame.delta(from.longitude + Frame.delta(to.longitude - from.longitude) * fraction))
            }
            let a = sin((1 - fraction) * angle) / denominator
            let b = sin(fraction * angle) / denominator
            let x = a * cos(fromLatitude) * cos(fromLongitude) + b * cos(toLatitude) * cos(toLongitude)
            let y = a * cos(fromLatitude) * sin(fromLongitude) + b * cos(toLatitude) * sin(toLongitude)
            let z = a * sin(fromLatitude) + b * sin(toLatitude)
            return Point(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                         longitude: atan2(y, x) * 180 / .pi)
        }
    }

    private static func angularDistance(_ from: Point, _ to: Point) -> Double {
        let latitude1 = from.latitude * .pi / 180
        let latitude2 = to.latitude * .pi / 180
        let dLatitude = latitude2 - latitude1
        let dLongitude = Frame.delta(to.longitude - from.longitude) * .pi / 180
        let a = pow(sin(dLatitude / 2), 2) + cos(latitude1) * cos(latitude2) * pow(sin(dLongitude / 2), 2)
        return 2 * atan2(sqrt(max(0, min(1, a))), sqrt(max(0, 1 - a)))
    }
}
