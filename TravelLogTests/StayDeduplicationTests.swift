//
//  StayDeduplicationTests.swift
//  TravelLogTests
//
//  Pure model logic, no SwiftData container needed. Covers
//  `Stay.deduplicatedCityCount(from:thresholdKm:)`, the union-find metro
//  counter that feeds the "cities visited" stat (Wrapped Card 1 + stats).
//  This function is purely coordinate-based and order-independent,
//  so the tests assert exactly those invariants.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (and their static members)
//  MainActor-isolated; running the tests on the main actor lets us touch them.
//

import Testing
import Foundation
import CoreLocation
@testable import TravelLog

@MainActor
struct StayDeduplicationTests {

    /// Athens city center.
    static let athens = (lat: 37.9838, lon: 23.7275)
    /// ~4 km from Athens center, within the 25 km default and beyond a 1 km threshold.
    static let athensNearby = (lat: 37.95, lon: 23.75)
    /// Ioánnina is about 311 km from Athens, far beyond any reasonable threshold.
    static let ioannina = (lat: 39.6628, lon: 20.8612)

    private func makeStay(lat: Double, lon: Double, hex: String) -> Stay {
        Stay(startTime: .now, endTime: .now,
             centroidLatitude: lat, centroidLongitude: lon,
             h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    @Test("empty input → 0 cities")
    func emptyIsZero() {
        #expect(Stay.deduplicatedCityCount(from: []) == 0)
    }

    @Test("stays sharing an H3 hex collapse to a single city regardless of count")
    func sameHexCollapses() {
        let stays = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: "hexAthens"),
            makeStay(lat: Self.athensNearby.lat, lon: Self.athensNearby.lon, hex: "hexAthens"),
            makeStay(lat: Self.ioannina.lat, lon: Self.ioannina.lon, hex: "hexAthens"),
        ]
        // All three share one hex key → grouped to one averaged centroid → 1 metro,
        // even though the coordinates themselves are hundreds of km apart.
        #expect(Stay.deduplicatedCityCount(from: stays) == 1)
    }

    @Test("distant stays in different hexes count as separate cities")
    func distantStaysSeparate() {
        let stays = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: "hexA"),
            makeStay(lat: Self.ioannina.lat, lon: Self.ioannina.lon, hex: "hexB"),
        ]
        #expect(Stay.deduplicatedCityCount(from: stays) == 2)
    }

    @Test("nearby stays in different hexes union under the default 25 km threshold")
    func nearbyHexesUnion() {
        let stays = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: "hexA"),
            makeStay(lat: Self.athensNearby.lat, lon: Self.athensNearby.lon, hex: "hexB"),
        ]
        // Different hexes (not pre-grouped) but ~4 km apart < 25 km → union → 1 city.
        #expect(Stay.deduplicatedCityCount(from: stays) == 1)
    }

    @Test("a tighter threshold splits the same nearby pair into two cities")
    func thresholdParameterRespected() {
        let stays = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: "hexA"),
            makeStay(lat: Self.athensNearby.lat, lon: Self.athensNearby.lon, hex: "hexB"),
        ]
        // ~4 km apart > 1 km threshold → no union → 2 cities. Proves the param is wired.
        #expect(Stay.deduplicatedCityCount(from: stays, thresholdKm: 1) == 2)
    }

    @Test("result is independent of input order")
    func orderIndependent() {
        let a = makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: "hexA")
        let b = makeStay(lat: Self.athensNearby.lat, lon: Self.athensNearby.lon, hex: "hexB")
        let c = makeStay(lat: Self.ioannina.lat, lon: Self.ioannina.lon, hex: "hexC")
        let forward = Stay.deduplicatedCityCount(from: [a, b, c])
        let reversed = Stay.deduplicatedCityCount(from: [c, b, a])
        #expect(forward == reversed)
        #expect(forward == 2) // {Athens ∪ nearby} + {Ioánnina}
    }

    @Test("stays with no hex key (empty h3) still cluster by distance")
    func ungroupedStaysClusterByDistance() {
        let near = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: ""),
            makeStay(lat: Self.athensNearby.lat, lon: Self.athensNearby.lon, hex: ""),
        ]
        #expect(Stay.deduplicatedCityCount(from: near) == 1) // ~4 km apart → union

        let far = [
            makeStay(lat: Self.athens.lat, lon: Self.athens.lon, hex: ""),
            makeStay(lat: Self.ioannina.lat, lon: Self.ioannina.lon, hex: ""),
        ]
        #expect(Stay.deduplicatedCityCount(from: far) == 2)
    }

    // MARK: - All-pairs oracle

    private typealias Point = (lat: Double, lon: Double)

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Plain union-find over EVERY pair with the same exact `CLLocation`
    /// distance and strict `<`: no latitude cull, no same-component skip.
    private func allPairsCityCount(_ points: [Point], thresholdKm: Double) -> Int {
        let locations = points.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        var parent = Array(0..<points.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { x = parent[x] }
            return x
        }
        for i in locations.indices {
            for j in (i + 1)..<locations.count {
                guard locations[i].distance(from: locations[j]) < thresholdKm * 1000 else { continue }
                let ri = find(i), rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        return Set(locations.indices.map(find)).count
    }

    /// Feeds the points as single-member nodes (alternating empty and unique
    /// hex keys), so each node sits exactly at its input coordinate.
    private func accumulatorCityCount(_ points: [Point], thresholdKm: Double) -> Int {
        var accumulator = Stay.CityCountAccumulator()
        for (index, point) in points.enumerated() {
            accumulator.add(
                h3IndexRes6: index.isMultiple(of: 2) ? "" : "hex\(index)",
                latitude: point.lat, longitude: point.lon)
        }
        return accumulator.count(thresholdKm: thresholdKm)
    }

    /// `CLLocation.distance(from:)` is not a pure function: it keeps
    /// process-wide state, so earlier calls (from any thread) moved the same
    /// pair's result by up to 0.8% in scratch probes. Keeping every pair at
    /// least 2% away from each tested threshold makes the oracle comparison
    /// independent of call history.
    private static let thresholdClearance = 0.02

    /// The candidates in order, minus any that would sit inside the
    /// clearance band of a tested threshold from a point already kept.
    private func clearOfThresholds(_ candidates: [Point], thresholdsKm: [Double]) -> [Point] {
        var kept: [(point: Point, location: CLLocation)] = []
        for candidate in candidates {
            let location = CLLocation(latitude: candidate.lat, longitude: candidate.lon)
            let clear = kept.allSatisfy { other in
                let meters = location.distance(from: other.location)
                return thresholdsKm.allSatisfy {
                    abs(meters - $0 * 1000) >= Self.thresholdClearance * $0 * 1000
                }
            }
            if clear { kept.append((candidate, location)) }
        }
        return kept.map { $0.point }
    }

    /// Latitude offset due north of `start` whose geodesic distance is
    /// `meters` (to within the history noise above).
    private func northOffset(from start: Point, meters: Double) -> Double {
        let origin = CLLocation(latitude: start.lat, longitude: start.lon)
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let d = origin.distance(from: CLLocation(latitude: start.lat + mid, longitude: start.lon))
            if d < meters { low = mid } else { high = mid }
        }
        return low
    }

    /// A meridian chain whose consecutive links sit `factor` times the
    /// threshold-crossing offset apart.
    private func meridianChain(from start: Point, links: Int, factor: Double, thresholdKm: Double) -> [Point] {
        var chain = [start]
        for _ in 0..<links {
            let last = chain[chain.count - 1]
            let step = northOffset(from: last, meters: thresholdKm * 1000) * factor
            chain.append((last.lat + step, last.lon))
        }
        return chain
    }

    @Test("city count matches an all-pairs union over clustered, scattered, antimeridian, polar, twin and threshold-edge nodes")
    func cityCountMatchesAllPairsOracle() {
        var rng = SplitMix(state: 0x5EED_C17E)
        func jitter(_ span: Double) -> Double { Double.random(in: -span...span, using: &rng) }

        // Far-apart centres with ±0.15° jitter: every cluster contributes at
        // least one component and many links merge inside it.
        let centres: [Point] = [
            (37.98, 23.73), (48.86, 2.35), (40.71, -74.01),
            (35.68, 139.69), (-33.87, 151.21), (-17.71, 178.07),
        ]
        var clustered: [Point] = []
        for i in 0..<96 {
            let centre = centres[i % centres.count]
            clustered.append((centre.lat + jitter(0.15), centre.lon + jitter(0.15)))
        }
        clustered = clearOfThresholds(clustered, thresholdsKm: [1, 25])
        // Dense legacy shape: one metro of ungrouped-style nodes.
        var dense: [Point] = []
        for _ in 0..<96 {
            dense.append((37.98 + jitter(0.05), 23.73 + jitter(0.05)))
        }
        dense = clearOfThresholds(dense, thresholdsKm: [1, 25])
        var scattered: [Point] = []
        for _ in 0..<96 {
            scattered.append((Double.random(in: 30...45, using: &rng), Double.random(in: -10...30, using: &rng)))
        }
        scattered = clearOfThresholds(scattered, thresholdsKm: [25, 150])
        var antimeridian: [Point] = []
        for i in 0..<80 {
            let lat = i.isMultiple(of: 2) ? 10 + jitter(0.2) : 65 + jitter(0.2)
            antimeridian.append((lat, GeoMath.normalizedLongitude(180 + jitter(0.3))))
        }
        antimeridian = clearOfThresholds(antimeridian, thresholdsKm: [25])
        var polar: [Point] = []
        for _ in 0..<48 {
            polar.append((Double.random(in: 89.80...89.99, using: &rng), Double.random(in: -180..<180, using: &rng)))
        }
        polar = clearOfThresholds(polar, thresholdsKm: [25])
        // Identical coordinates, like physical UUID twins.
        var twins = [Point](repeating: (lat: 37.98, lon: 23.73), count: 40)
        twins += [Point](repeating: (lat: 40.64, lon: 22.94), count: 40)
        // Links just inside / just outside the threshold, by the clearance.
        let inside = meridianChain(from: (38.0, 24.0), links: 4, factor: 1 - Self.thresholdClearance, thresholdKm: 25)
        let outside = meridianChain(from: (38.0, 30.0), links: 4, factor: 1 + Self.thresholdClearance, thresholdKm: 25)
        let joined = meridianChain(from: (-45.0, 170.0), links: 1, factor: 1 - Self.thresholdClearance, thresholdKm: 25)
        let split = meridianChain(from: (-44.0, 170.0), links: 1, factor: 1 + Self.thresholdClearance, thresholdKm: 25)
        var edges: [Point] = inside + outside
        edges += joined + split

        let cases: [(name: String, points: [Point], thresholds: [Double])] = [
            ("empty", [], [25]),
            ("single", [(37.98, 23.73)], [25]),
            ("clustered", clustered, [1, 25]),
            ("dense", dense, [1, 25]),
            ("scattered", scattered, [25, 150]),
            ("antimeridian", antimeridian, [25]),
            ("polar", polar, [25]),
            ("twins", twins, [25]),
            ("threshold edges", edges, [25]),
        ]
        for testCase in cases {
            for thresholdKm in testCase.thresholds {
                #expect(accumulatorCityCount(testCase.points, thresholdKm: thresholdKm)
                        == allPairsCityCount(testCase.points, thresholdKm: thresholdKm),
                        "\(testCase.name) at \(thresholdKm) km")
            }
        }

        // Anchors that keep the oracle honest.
        let clusteredCount = allPairsCityCount(clustered, thresholdKm: 25)
        #expect(clusteredCount >= centres.count && clusteredCount < clustered.count)
        #expect(allPairsCityCount(twins, thresholdKm: 25) == 2)
        #expect(allPairsCityCount(inside, thresholdKm: 25) == 1)
        #expect(allPairsCityCount(outside, thresholdKm: 25) == outside.count)
        #expect(allPairsCityCount(joined + split, thresholdKm: 25) == 3)
        let dateline: [Point] = [(0, 179.9), (0, -179.9)]
        #expect(allPairsCityCount(dateline, thresholdKm: 25) == 1)
        #expect(accumulatorCityCount(dateline, thresholdKm: 25) == 1)
    }
}
