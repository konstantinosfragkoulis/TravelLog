//
//  FlightGeographicIdentity.swift
//  TravelLog
//
//  Display names nominate possible matches; bounded observed geography
//  decides whether those matches can represent one schematic place.
//  These derived keys are never persisted or used as write authority.
//

import Foundation

nonisolated enum FlightGeographicIdentity {
    nonisolated struct Endpoint: Sendable {
        let place: String?
        let iso: String?
        let administrativeArea: String?
        let granularity: String?
        let latitude: Double?
        let longitude: Double?
        /// Only a nearby observed airport, never a likely serving airport.
        let observedAirportCode: String?
    }

    /// Returns one identity per input, in input order. Sorting unique points
    /// before complete-link clustering makes permutation and duplicate visits
    /// immaterial. Unlike a nearest-neighbour chain, no cluster can acquire
    /// an arbitrarily distant endpoint through intermediate observations.
    static func resolve(_ endpoints: [Endpoint]) -> [String?] {
        var results = [String?](repeating: nil, count: endpoints.count)
        var groups: [String: [LocatedEndpoint]] = [:]
        var administrativeAreas: [String: Set<String>] = [:]
        for endpoint in endpoints where endpoint.granularity == "locality" {
            guard let base = baseKey(endpoint), let admin = normalized(endpoint.administrativeArea) else { continue }
            administrativeAreas[base, default: []].insert(admin)
        }
        for (index, endpoint) in endpoints.enumerated() {
            guard let point = Point(latitude: endpoint.latitude, longitude: endpoint.longitude) else {
                // A label alone cannot distinguish homonyms or country-wide
                // fallbacks. Retain only an actually observed airport alias.
                results[index] = airportKey(endpoint.observedAirportCode)
                continue
            }
            guard var base = baseKey(endpoint) else {
                // With no place information, match only identical geography
                // or a genuinely observed airport. Avoid inventing a town.
                results[index] = airportKey(endpoint.observedAirportCode) ?? "point:" + point.key
                continue
            }
            if endpoint.granularity == "locality", (administrativeAreas[base]?.count ?? 0) > 1 {
                // A named metro may span administrative boundaries. A known
                // locality collision, however, must retain its qualifier.
                base += encoded([normalized(endpoint.administrativeArea) ?? "?"])
            }
            groups[base, default: []].append(LocatedEndpoint(index: index, point: point,
                                                          maximumDiameterKm: diameter(for: endpoint.granularity)))
        }
        for (base, members) in groups {
            // Duplicate observations do not affect the cluster's geometry or
            // its identifier. Keep the stricter radius for conflicting tags.
            var radiusByPoint: [Point: Double] = [:]
            for member in members {
                radiusByPoint[member.point] = min(radiusByPoint[member.point] ?? .infinity, member.maximumDiameterKm)
            }
            let locations = radiusByPoint.map { Location(point: $0.key, maximumDiameterKm: $0.value) }
                .sorted { $0.point < $1.point }
            var clusters: [[Location]] = []
            var identityByPoint: [Point: String] = [:]
            for location in locations {
                let matching = clusters.firstIndex { cluster in
                    cluster.allSatisfy {
                        location.point.distanceKm(to: $0.point) <= min(location.maximumDiameterKm, $0.maximumDiameterKm)
                    }
                }
                let clusterIndex: Int
                if let matching {
                    clusterIndex = matching
                    clusters[matching].append(location)
                } else {
                    clusterIndex = clusters.count
                    clusters.append([location])
                }
                identityByPoint[location.point] = "place:" + encoded([base, clusters[clusterIndex][0].point.key])
            }
            for member in members { results[member.index] = identityByPoint[member.point] }
        }
        return results
    }

    private nonisolated struct LocatedEndpoint {
        let index: Int
        let point: Point
        let maximumDiameterKm: Double
    }

    private nonisolated struct Location {
        let point: Point
        let maximumDiameterKm: Double
    }

    private nonisolated struct Point: Hashable, Comparable {
        let latitude: Double
        let longitude: Double

        init?(latitude: Double?, longitude: Double?) {
            guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            self.latitude = latitude == 0 ? 0 : latitude
            self.longitude = longitude == 180 ? -180 : longitude == 0 ? 0 : longitude
        }

        var key: String { encoded([String(latitude), String(longitude)]) }

        static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.latitude == rhs.latitude ? lhs.longitude < rhs.longitude : lhs.latitude < rhs.latitude
        }

        func distanceKm(to other: Point) -> Double {
            let radians = Double.pi / 180
            let dLatitude = (other.latitude - latitude) * radians
            let dLongitude = (other.longitude - longitude) * radians
            let value = pow(sin(dLatitude / 2), 2)
                + cos(latitude * radians) * cos(other.latitude * radians) * pow(sin(dLongitude / 2), 2)
            let bounded = max(0, min(value, 1))
            return 6_371 * 2 * atan2(sqrt(bounded), sqrt(1 - bounded))
        }
    }

    private static func baseKey(_ endpoint: Endpoint) -> String? {
        guard let place = normalized(endpoint.place) else { return nil }
        return encoded([place, normalized(endpoint.iso) ?? "?"])
    }

    private static func airportKey(_ code: String?) -> String? {
        normalized(code).map { "airport:" + $0.uppercased(with: Locale(identifier: "en_US_POSIX")) }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func diameter(for granularity: String?) -> Double {
        switch granularity {
        case "metro": 100  // One named urban region may contain several airports.
        case "locality": 25
        case "country", "administrativeArea", "island": 10
        default: 25       // Legacy metadata never establishes a broad metro.
        }
    }

    private static func encoded<S: Sequence>(_ parts: S) -> String where S.Element == String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
