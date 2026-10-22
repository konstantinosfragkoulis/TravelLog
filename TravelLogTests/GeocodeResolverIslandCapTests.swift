//
//  GeocodeResolverIslandCapTests.swift
//  TravelLogTests
//
//  The island size cap (`GeocodeResolver.islandAreaCapKm2`):
//  a landmass is not a place. Real coordinates against the shipped bundle:
//  rural stays on Great Britain, Honshu, Ireland, Iceland, Java and
//  Hispaniola resolve with no island and report the landmass as
//  `demotedIslandName`; Sicily, Cyprus, Crete, Paxos and Skye keep
//  their island, Skye even though Great Britain's bounding box contains it.
//

import Testing
import Foundation
@testable import TravelLog

struct GeocodeResolverIslandCapTests {

    private struct Point { let name: String; let lat: Double; let lon: Double }

    /// Inland points well clear of any coastline, one per landmass.
    private static let demoted: [(point: Point, landmass: String)] = [
        (Point(name: "Snowdonia", lat: 52.90, lon: -3.90), "Great Britain"),
        (Point(name: "Matsumoto", lat: 36.24, lon: 137.97), "Honshu"),
        (Point(name: "Athlone", lat: 53.42, lon: -7.94), "Ireland"),
        (Point(name: "Landmannalaugar", lat: 63.98, lon: -19.06), "Iceland"),
        (Point(name: "Yogyakarta", lat: -7.80, lon: 110.36), "Java"),
        (Point(name: "Punta Cana", lat: 18.58, lon: -68.37), "Hispaniola"),
        (Point(name: "Hobart", lat: -42.88, lon: 147.33), "Tasmania"),
    ]

    private static let kept: [(point: Point, island: String)] = [
        (Point(name: "Enna", lat: 37.57, lon: 14.28), "Sicily"),
        (Point(name: "Paphos", lat: 34.77, lon: 32.42), "Cyprus"),
        (Point(name: "Elounda", lat: 35.26, lon: 25.72), "Crete"),
        (Point(name: "Gáïos", lat: 39.19722, lon: 20.18556), "Paxos"),
        (Point(name: "Portree", lat: 57.41, lon: -6.19), "Skye"),
        (Point(name: "San Sebastián de la Gomera", lat: 28.09163, lon: -17.11331), "La Gomera"),
    ]

    @Test("a rural stay on a landmass resolves with no island and names the landmass as demoted")
    func landmassesAreDemoted() async throws {
        for (point, landmass) in Self.demoted {
            let result = try #require(
                await GeocodeResolver.shared.resolve(latitude: point.lat, longitude: point.lon),
                "\(point.name) resolved to nothing")
            #expect(result.islandName == nil, "\(point.name) kept island \(result.islandName ?? "nil")")
            #expect(result.demotedIslandName == landmass, "\(point.name) demoted \(result.demotedIslandName ?? "nil")")
        }
    }

    @Test("islands under the cap keep their name and report nothing demoted")
    func islandsUnderCapAreKept() async throws {
        for (point, island) in Self.kept {
            let result = try #require(
                await GeocodeResolver.shared.resolve(latitude: point.lat, longitude: point.lon),
                "\(point.name) resolved to nothing")
            #expect(result.islandName == island, "\(point.name) resolved island \(result.islandName ?? "nil")")
            #expect(result.demotedIslandName == nil)
        }
    }

    @Test("the mainland is neither an island nor a demoted landmass")
    func mainlandReportsNothing() async throws {
        // Athens (Attica) and Munich: continental Europe.
        let athens = try #require(await GeocodeResolver.shared.resolve(latitude: 37.98, longitude: 23.73))
        #expect(athens.islandName == nil)
        #expect(athens.demotedIslandName == nil)
        let munich = try #require(await GeocodeResolver.shared.resolve(latitude: 48.14, longitude: 11.58))
        #expect(munich.islandName == nil)
        #expect(munich.demotedIslandName == nil)
    }

    @Test("a centroid on a demoted landmass does not adopt a small island across the water")
    func landmassCentroidDoesNotBorrowNeighbouringIsland() async throws {
        // Near Kyle of Lochalsh, on the Great Britain side; Kyleakin on Skye
        // is the town across the strait. The town fallback exists for
        // centroids in NO polygon, never for centroids on a landmass.
        let result = try #require(await GeocodeResolver.shared.resolve(latitude: 57.2802, longitude: -5.7688))
        #expect(result.islandName == nil)
        #expect(result.demotedIslandName == "Great Britain")
    }

    @Test("the shipped polygons measure close to their published areas")
    func shippedAreasAreCredible() async {
        // Published (km²): Sicily 25,711; Crete 8,336; Cyprus 9,251;
        // Great Britain 209,331; Ireland 84,421. Spherical measure of the
        // OSM coastline should land within a few percent.
        let expectations: [(lat: Double, lon: Double, name: String, km2: Double)] = [
            (37.57, 14.28, "Sicily", 25_711),
            (35.26, 25.72, "Crete", 8_336),
            (34.77, 32.42, "Cyprus", 9_251),
            (52.90, -3.90, "Great Britain", 209_331),
            (53.42, -7.94, "Ireland", 84_421),
        ]
        for expectation in expectations {
            let hits = await GeocodeResolver.shared.islandHits(latitude: expectation.lat, longitude: expectation.lon)
            let hit = hits.first { $0.name == expectation.name }
            #expect(hit != nil, "no \(expectation.name) polygon at the probe")
            if let hit {
                let error = abs(hit.areaKm2 - expectation.km2) / expectation.km2
                #expect(error < 0.05, "\(expectation.name) measured \(Int(hit.areaKm2)) km²")
            }
        }
    }

    @Test("the cap sits between Sicily and the demoted landmasses with margin")
    func capHasMargin() async {
        let sicily = await GeocodeResolver.shared.islandHits(latitude: 37.57, longitude: 14.28)
            .first { $0.name == "Sicily" }
        let hokkaido = await GeocodeResolver.shared.islandHits(latitude: 43.06, longitude: 141.35)
            .first { $0.name == "Hokkaido" }
        #expect(sicily.map { $0.areaKm2 < GeocodeResolver.islandAreaCapKm2 * 0.9 } == true)
        #expect(hokkaido.map { $0.areaKm2 > GeocodeResolver.islandAreaCapKm2 * 2 } == true)
    }
}
