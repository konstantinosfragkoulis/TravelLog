//
//  HomeOrbitReplayTests.swift
//  TravelLogTests
//
//  Parity between the Swift expansion engine (HomeOrbit) and the
//  Python oracle (scripts/home-orbit-replica.py) on a supplied replay fixture.
//  The acceptance checks cover insufficient returns, the corridor dwell
//  floor, and baseline gate parity (HomeShapeReplayTests owns that).
//
//  The fixture is external and read-only. It uses the same environment
//  gating as HomeShapeReplayTests:
//
//      TEST_RUNNER_TRAVELLOG_REAL_FIXTURE=/path/to/TravelLog.store \
//      xcodebuild test -only-testing:TravelLogTests/HomeOrbitReplayTests \
//        -parallel-testing-enabled NO
//
//  BOTH flags are load-bearing: without the fixture flags the tests report
//  as skipped, and the "HOME-ORBIT REPLAY" block prints only when the
//  replay actually ran.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Home-orbit replay", .serialized)
struct HomeOrbitReplayTests {

    nonisolated private static var fixtureURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TRAVELLOG_REAL_FIXTURE"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private struct FixtureExpectations: Decodable {
        let homeOrbitMaxReturns: Int
        let homeOrbitReturnsWithoutD: Int
        let homeOrbitCorridorLatitude: Double
        let homeOrbitCorridorLongitude: Double
    }

    private func fixtureExpectations() throws -> FixtureExpectations? {
        guard let path = ProcessInfo.processInfo.environment["TRAVELLOG_REAL_FIXTURE_EXPECTATIONS"],
              !path.isEmpty else { return nil }
        return try JSONDecoder().decode(FixtureExpectations.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func openFixture(label: String) throws -> (ModelContainer, URL) {
        let fixture = try #require(Self.fixtureURL, "TRAVELLOG_REAL_FIXTURE unset")
        let schema = Schema(versionedSchema: TravelLogSchemaV14.self)
        let configuration = ModelConfiguration(
            "\(label)-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        try TestSupport.copyStoreFamily(from: fixture, to: configuration.url)
        let container = try ModelContainer(for: schema,
                                           migrationPlan: TravelLogMigrationPlan.self,
                                           configurations: [configuration])
        return (container, configuration.url)
    }

    private func observations(from stays: [Stay]) -> [HomeOrbit.StayObservation] {
        stays.map {
            HomeOrbit.StayObservation(
                id: $0.id, start: $0.startTime, end: $0.endTime,
                latitude: $0.centroidLatitude, longitude: $0.centroidLongitude,
                isTransitNode: $0.isAirport,
                isLive: $0.sourceRaw == DataSource.liveSLC.rawValue
                     || $0.sourceRaw == DataSource.merged.rawValue)
        }
    }

    // Corridor anchor used for the replay dwell-floor comparison.
    private static let corridorAnchor = (lat: 38.9437, lon: 22.8653)

    @Test("replay: the orbit admits no discs and the corridor tests clause (d)", .enabled(
        if: HomeOrbitReplayTests.fixtureURL != nil,
        "Point TRAVELLOG_REAL_FIXTURE at a replay fixture to run the replay"
    ))
    func orbitParityOnReplayFixture() async throws {
        let (container, storeURL) = try openFixture(label: "HomeOrbitReplay")
        defer { TestSupport.removeStoreFamily(at: storeURL) }
        let context = ModelContext(container)
        let expectations = try fixtureExpectations()
        let corridorAnchor = expectations.map {
            (lat: $0.homeOrbitCorridorLatitude, lon: $0.homeOrbitCorridorLongitude)
        } ?? Self.corridorAnchor

        let homes = try context.fetch(FetchDescriptor<Home>())
        let stays = try context.fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime)]))
        let home = try #require(homes.min(by: { $0.startedAt < $1.startedAt }))

        let seed = await HomeShapeProvider.shared.shape(
            latitude: home.latitude, longitude: home.longitude)
        guard case .urbanCentre = seed.seed else {
            Issue.record("fixture home did not resolve to an urban centre")
            return
        }

        let obs = observations(from: stays)
        let audits = HomeOrbit.deriveDiscs(observations: obs, seed: seed)

        // Pin 1: the replay fixture admits no discs.
        let admitted = audits.compactMap(\.disc)
        #expect(admitted.isEmpty,
                "expansion admitted \(admitted.count) discs on the replay fixture")

        // Pin 2: the strongest cluster must match the independent oracle.
        let maxReturns = audits.map(\.qualifyingReturnTimes.count).max() ?? 0
        if let expectations {
            #expect(maxReturns == expectations.homeOrbitMaxReturns,
                    "maximum qualifying returns differ from the oracle: \(maxReturns)")
        }

        // Pin 3: compare corridor returns with and without the dwell floor.
        let corridor = try #require(audits.min(by: {
            HomeOrbit.greatCircleKm($0.centerLatitude, $0.centerLongitude,
                                    corridorAnchor.lat, corridorAnchor.lon)
            < HomeOrbit.greatCircleKm($1.centerLatitude, $1.centerLongitude,
                                      corridorAnchor.lat, corridorAnchor.lon)
        }))
        #expect(HomeOrbit.greatCircleKm(corridor.centerLatitude, corridor.centerLongitude,
                                        corridorAnchor.lat, corridorAnchor.lon) < 2.0,
                "no cluster found near the corridor anchor")
        #expect(corridor.qualifyingReturnTimes.isEmpty,
                "clause (d) must refuse the corridor")

        let excursions = TripConfidence.excursions(
            from: obs.map(\.confidenceInput), shapes: [seed])
        let byID = Dictionary(uniqueKeysWithValues: obs.map { ($0.id, $0) })
        let withoutD = HomeOrbit.qualifyingReturnTimes(
            clusterLatitude: corridor.centerLatitude,
            clusterLongitude: corridor.centerLongitude,
            clusterRadiusKm: corridor.radiusKm,
            seedExcursions: excursions, observationsByID: byID,
            dwellFloor: 0)
        #expect(!withoutD.isEmpty, "disabling the dwell floor must allow corridor returns")
        if let expectations {
            #expect(withoutD.count == expectations.homeOrbitReturnsWithoutD,
                    "corridor returns without (d) differ from the oracle: \(withoutD.count)")
        }

        print("""

        ================ HOME-ORBIT REPLAY ================
        stays \(obs.count) (live \(obs.filter(\.isLive).count)), candidate clusters \(audits.count)
        admitted discs: \(admitted.count)   max returns: \(maxReturns)
        corridor: \(withoutD.count) returns without (d) → \(corridor.qualifyingReturnTimes.count) with (d)
        ===================================================

        """)
    }
}
