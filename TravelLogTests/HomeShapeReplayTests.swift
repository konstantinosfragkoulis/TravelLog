//
//  HomeShapeReplayTests.swift
//  TravelLogTests
//
//  Compares home membership with and without shapes using an external fixture.
//  The replay reports which stays change membership.
//
//  This replays the DECISION POINT, not the whole pipeline: for every stay it
//  asks `TripClassifier.matchesHome` twice, once with the legacy circle and
//  once with the measured shape, and reports the diff. That isolates the one
//  variable being changed. Running the full pipeline would also drag in
//  Foundation Models, live geocoding and the pipeline gate, none of which the
//  flag touches, and any difference they introduced would be noise.
//
//  Because `.home` is what brackets an excursion, a stay flipping home↔away is
//  exactly what re-cuts a trip boundary. So the counts printed here are the
//  blast radius of the cutover.
//
//  **The external fixture is never committed and never mutated.**
//  Point `TRAVELLOG_REAL_FIXTURE` at a store to run; without
//  it every test here skips, so the suite stays green for anyone without the
//  data. The store family is copied — including `-wal`/`-shm`, whose loss would
//  silently drop the most recent travel — and only the copy is opened.
//
//      TEST_RUNNER_TRAVELLOG_REAL_FIXTURE=/path/to/TravelLog.store \
//      xcodebuild test -only-testing:TravelLogTests/HomeShapeReplayTests \
//        -parallel-testing-enabled NO
//
//  Both flags are required: without the
//  TEST_RUNNER_ prefix the variable never reaches the test process, and with
//  parallel testing on (cloned simulators) it ALSO never arrives. Either way
//  the `.enabled(if:)` trait reports the tests as skipped. Tests reported
//  as passing have executed the replay.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Home-shape replay", .serialized)
struct HomeShapeReplayTests {

    nonisolated private static var fixtureURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TRAVELLOG_REAL_FIXTURE"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    // MARK: - The replay

    @Test("replay: what the shape changes in an external fixture", .enabled(
        if: HomeShapeReplayTests.fixtureURL != nil,
        "Point TRAVELLOG_REAL_FIXTURE at an external fixture to run the replay"
    ))
    func replay() async throws {
        let (container, storeURL) = try openFixture(label: "HomeShapeReplay")
        defer { TestSupport.removeStoreFamily(at: storeURL) }
        let context = ModelContext(container)

        let homes = try context.fetch(FetchDescriptor<Home>())
        let stays = try context.fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime)]))
        let trips = try context.fetch(FetchDescriptor<Trip>())
        try #require(!homes.isEmpty, "fixture has no Home row")

        // Two ring sets over the SAME homes: legacy circle, and shape-attached.
        let circles = homes.map {
            TripClassifier.HomeRing(latitude: $0.latitude, longitude: $0.longitude,
                                    radiusKm: $0.radiusKm, startedAt: $0.startedAt,
                                    endedAt: $0.endedAt)
        }
        var shaped: [TripClassifier.HomeRing] = []
        for ring in circles {
            let shape = await HomeShapeProvider.shared.shape(
                latitude: ring.latitude, longitude: ring.longitude)
            shaped.append(ring.withShape(shape))
        }

        var becameAway: [Stay] = []      // was home, now away  -> may CREATE trips
        var becameHome: [Stay] = []      // was away, now home  -> may DELETE trips
        for stay in stays {
            let old = TripClassifier.matchesHome(
                stayStart: stay.startTime, latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude, homes: circles)
            let new = TripClassifier.matchesHome(
                stayStart: stay.startTime, latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude, homes: shaped)
            if old && !new { becameAway.append(stay) }
            if !old && new { becameHome.append(stay) }
        }

        func summarise(_ rows: [Stay]) -> String {
            let byPlace = Dictionary(grouping: rows) {
                $0.islandName ?? $0.locality ?? "(un-geocoded)"
            }
            return byPlace.sorted { $0.value.count > $1.value.count }
                .prefix(12)
                .map { "      \($0.value.count)x \($0.key)" }
                .joined(separator: "\n")
        }

        let seedNames = shaped.map { ring -> String in
            switch ring.shape?.seed {
            case .urbanCentre(_, let name): return name ?? "(unnamed UC)"
            case .fallbackDisc: return "1 km fallback disc"
            case nil: return "NO SHAPE"
            }
        }

        print("""

        ================ HOME-SHAPE REPLAY ================
        store        : \(stays.count) stays, \(trips.count) trips, \(homes.count) home row(s)
        seeds        : \(seedNames.joined(separator: ", "))
        D* per home  : \(shaped.map { String(format: "%.2f km", $0.shape?.areaEquivalentRadiusKm ?? -1) }.joined(separator: ", "))

        stays flipping HOME -> AWAY : \(becameAway.count)   (these can create new trips)
        \(summarise(becameAway))

        stays flipping AWAY -> HOME : \(becameHome.count)   (these can dissolve trips)
        \(summarise(becameHome))

        unchanged                   : \(stays.count - becameAway.count - becameHome.count)
        ===================================================
        """)

        // Invariants the cutover must satisfy, whatever the counts are.
        #expect(shaped.allSatisfy { $0.shape != nil }, "every home resolved a shape")
        // A stay at a declared home's own coordinate must stay home under both.
        for home in homes {
            let stillHome = TripClassifier.matchesHome(
                stayStart: home.startedAt, latitude: home.latitude,
                longitude: home.longitude, homes: shaped)
            #expect(stillHome, "the declared home itself stopped being home")
        }
    }

    @Test("replay: the fixture is never mutated", .enabled(
        if: HomeShapeReplayTests.fixtureURL != nil,
        "Point TRAVELLOG_REAL_FIXTURE at an external fixture to run the replay"
    ))
    func fixtureIsPristine() throws {
        let fixture = try #require(Self.fixtureURL)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.path)
        let (container, storeURL) = try openFixture(label: "HomeShapePristine")
        defer { TestSupport.removeStoreFamily(at: storeURL) }
        let context = ModelContext(container)
        _ = try context.fetchCount(FetchDescriptor<Stay>())
        let after = try FileManager.default.attributesOfItem(atPath: fixture.path)
        #expect(before[.size] as? Int == after[.size] as? Int)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        // Read-only protection makes an accidental write to the source fail.
        let perms = (after[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o200 == 0, "fixture lost its read-only protection")
    }
}
