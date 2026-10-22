//
//  GeocodeResolverIslandFallbackTests.swift
//  TravelLogTests
//
//  `GeocodeResolver.resolve` names an island in two steps: the centroid's
//  own polygon, else the island the nearest GeoNames town sits on. Port
//  stays motivate the second step: a harbour centroid can drift seaward of
//  any island polygon, and the stay would then read as a second
//  destination beside its own island. Real coordinates against the
//  shipped bundle; mainland ports beside islands are the controls.
//

import Testing
import Foundation
@testable import TravelLog

struct GeocodeResolverIslandFallbackTests {

    @Test("a centroid offshore of Patitírion is still an Alonissos stay")
    func offshoreHarbourAdoptsTheTownsIsland() async throws {
        // An offshore centroid misses the island polygon directly.
        // The nearest GeoNames town supplies its island.
        let result = try #require(await GeocodeResolver.shared.resolve(
            latitude: 39.1426, longitude: 23.8271))
        #expect(result.islandName == "Alonissos")
        #expect(result.localityName == "Patitirion")
        #expect(result.metroName == nil)
    }

    @Test("Mykonos old port resolves to Mykonos")
    func mykonosPortIsMykonos() async throws {
        let result = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.4443, longitude: 25.3151))
        #expect(result.islandName == "Mykonos")
    }

    @Test("mainland ports beside islands stay mainland")
    func mainlandPortsDoNotAdoptNeighbouringIslands() async throws {
        // Perama: Salamina is 2 km across the strait. Galatas: Poros lies
        // across the water. Agia Kyriakií Spáton: a coastal point in east
        // Attica, inside the Athens metro.
        let perama = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.9640, longitude: 23.5720))
        #expect(perama.islandName == nil)
        let galatas = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.4902, longitude: 23.4528))
        #expect(galatas.islandName == nil)
        let agiaKyriaki = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.9982, longitude: 23.9810))
        #expect(agiaKyriaki.islandName == nil)
        #expect(agiaKyriaki.metroName == "Athens")
    }

    @Test("an island town across the water from the mainland keeps its island")
    func islandTownAcrossFromMainlandKeepsIsland() async throws {
        let poros = try #require(await GeocodeResolver.shared.resolve(
            latitude: 37.4990, longitude: 23.4560))
        #expect(poros.islandName == "Poros")
    }
}
