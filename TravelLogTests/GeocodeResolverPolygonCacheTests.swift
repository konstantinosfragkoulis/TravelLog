//
//  GeocodeResolverPolygonCacheTests.swift
//  TravelLogTests
//
//  `GeocodeResolver` caches parsed admin-1, FUA, island and urban-centre polygons under a
//  vertex budget. The cache must not change any answer: cold, warm and
//  cleared resolves agree, and the vertex count stays within the budget.
//  Real coordinates against the shipped bundle.
//

import Testing
import Foundation
@testable import TravelLog

@Suite(.serialized)
struct GeocodeResolverPolygonCacheTests {

    private static let fixed: [(lat: Double, lon: Double)] = [
        (51.5074, -0.1278),    // London
        (52.52, 13.405),       // Berlin
        (55.9877, -3.2592),    // Edinburgh
        (37.9838, 23.7275),    // Athens
        (38.1994, 20.4373),    // Cephalonia
        (40.7128, -74.006),    // New York
        (-18.1117, 178.4770),  // Suva
        (1.4518, 172.9717),    // Tarawa
        (61.2181, -149.9003),  // Anchorage
        (64.7337, 177.4968),   // Anadyr
    ]

    private func resolveAll(_ points: [(lat: Double, lon: Double)]) async -> [GeocodeResolver.Result?] {
        var results: [GeocodeResolver.Result?] = []
        for point in points {
            results.append(await GeocodeResolver.shared.resolve(latitude: point.lat, longitude: point.lon))
        }
        return results
    }

    @Test("cold, warm and cleared resolves return identical results")
    func cacheDoesNotChangeResults() async {
        await GeocodeResolver.shared.clearPolygonCacheForTesting()
        let cold = await resolveAll(Self.fixed)
        // Not vacuous: the bundle must answer and the cache must fill.
        #expect(cold.compactMap { $0?.isoCountryCode }.count == Self.fixed.count)
        #expect(await GeocodeResolver.shared.polygonCacheVertexCountForTesting() > 0)
        let warm = await resolveAll(Self.fixed)
        await GeocodeResolver.shared.clearPolygonCacheForTesting()
        let cleared = await resolveAll(Self.fixed)
        #expect(cold == warm)
        #expect(cold == cleared)
    }

    @Test("cold, warm and cleared urban-centre shapes return identical source attributes and rings")
    func urbanCentreCacheDoesNotChangeResults() async {
        func hits() async -> [GeocodeResolver.UrbanCentreHit?] {
            var results: [GeocodeResolver.UrbanCentreHit?] = []
            for point in Self.fixed {
                results.append(await GeocodeResolver.shared.urbanCentre(latitude: point.lat, longitude: point.lon))
            }
            return results
        }
        await GeocodeResolver.shared.clearPolygonCacheForTesting()
        let cold = await hits()
        #expect(cold.compactMap { $0 }.count > 0)
        #expect(await GeocodeResolver.shared.polygonCacheVertexCountForTesting() > 0)
        let warm = await hits()
        await GeocodeResolver.shared.clearPolygonCacheForTesting()
        let cleared = await hits()
        #expect(cold == warm)
        #expect(cold == cleared)
    }

    @Test("the cached vertex count never exceeds the budget")
    func vertexCountStaysWithinBudget() async {
        let budget = GeocodeResolver.polygonCacheVertexBudget
        // A 10 by 10 grid over inhabited latitudes, plus the fixed list.
        var points = Self.fixed
        for latStep in 0..<10 {
            for lonStep in 0..<10 {
                points.append((lat: -45.0 + Double(latStep) * 11.0,
                               lon: -175.0 + Double(lonStep) * 36.0))
            }
        }
        for point in points {
            _ = await GeocodeResolver.shared.resolve(latitude: point.lat, longitude: point.lon)
            _ = await GeocodeResolver.shared.urbanCentre(latitude: point.lat, longitude: point.lon)
            let vertices = await GeocodeResolver.shared.polygonCacheVertexCountForTesting()
            #expect(vertices <= budget, "\(vertices) vertices after (\(point.lat), \(point.lon))")
        }
    }
}
