//
//  FlightJudgeBenchTests.swift
//  TravelLogTests
//
//  Runs the real flight pipeline over an external bench file: every stay
//  inserted unclassified (legacy ground modes kept), the `TransitInferer`
//  drain to exhaustion, then the Flight Log's aggregate. Writes what was
//  recorded and what the review queue offers, by journey, for scoring
//  outside the repository.
//
//  **The bench file is never committed.** Point `TRAVELLOG_FLIGHT_BENCH` at
//  one (and `TRAVELLOG_FLIGHT_BENCH_OUT` at where the results go); without
//  it the test skips.
//
//      TEST_RUNNER_TRAVELLOG_FLIGHT_BENCH=/path/to/bench.json \
//      TEST_RUNNER_TRAVELLOG_FLIGHT_BENCH_OUT=/path/to/results.json \
//      xcodebuild test -only-testing:TravelLogTests/FlightJudgeBenchTests \
//        -parallel-testing-enabled NO
//
//  The file is `{"stays": [...]}`, each stay with `id`, `start` and `end`
//  (ISO 8601), `latitude`, `longitude`, `isAirport`, `islandName`,
//  `isoCountryCode`, `category`, `sourceRaw`, `pingCount` and `transitRaw`.
//

import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Flight judge bench", .serialized)
struct FlightJudgeBenchTests {

    nonisolated private static var benchURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TRAVELLOG_FLIGHT_BENCH"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private struct BenchStay: Decodable {
        let id: String
        let start: String
        let end: String
        let latitude: Double
        let longitude: Double
        let isAirport: Bool
        let islandName: String?
        let isoCountryCode: String?
        let category: String
        let sourceRaw: String
        let pingCount: Int
        let transitRaw: String?
    }

    private struct Bench: Decodable {
        let stays: [BenchStay]
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    @Test("the drain and the Flight Log over the bench file", .enabled(if: benchURL != nil),
          .timeLimit(.minutes(20)))
    func bench() async throws {
        let url = try #require(Self.benchURL)
        let bench = try JSONDecoder().decode(Bench.self, from: Data(contentsOf: url))
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let kept: Set<String?> = [nil, TransitMode.unknown.rawValue, TransitMode.flight.rawValue,
                                  TransitMode.notFlight.rawValue]
        for row in bench.stays {
            let start = try #require(Self.date(row.start)), end = try #require(Self.date(row.end))
            let stay = Stay(startTime: start, endTime: end,
                            centroidLatitude: row.latitude, centroidLongitude: row.longitude,
                            h3IndexRes6: "", pingCount: row.pingCount, distanceFromHomeKm: 100, pingIDs: [],
                            source: DataSource(rawValue: row.sourceRaw) ?? .liveSLC)
            stay.id = try #require(UUID(uuidString: row.id))
            stay.isAirport = row.isAirport
            stay.islandName = row.islandName
            stay.isoCountryCode = row.isoCountryCode
            stay.category = StayCategory(rawValue: row.category) ?? .destination
            // Judged afresh: only a legacy ground mode stays as measured.
            stay.transitFromPreviousRaw = kept.contains(row.transitRaw) ? nil : row.transitRaw
            context.insert(stay)
        }
        try context.save()

        let inferer = TransitInferer(modelContainer: container)
        var rounds = 0
        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
            await TransitInferer.TestScope.$dismissedArrivals.withValue([]) {
                while rounds < 1_000 {
                    rounds += 1
                    let batch = await inferer.inferTransitForRecentStaysReportingChanges()
                    #expect(!batch.failed)
                    if batch.failed || batch.fetched < TransitInferer.inferenceBatchSize { break }
                }
            }
        }

        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let collections = CollectionsAggregator.aggregate(stays: stays, dismissedCandidates: [])
        // The journeys, for scoring by their stays.
        let timeline = FlightJudge.Timeline(stays.map { stay in
            FlightJudge.Stay(id: stay.id, start: stay.startTime, end: stay.endTime,
                             latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                             isAirport: stay.isAirport, islandName: stay.islandName, pingCount: stay.pingCount,
                             isPhoto: stay.sourceRaw == DataSource.photoImport.rawValue,
                             mode: FlightJudge.Mode(raw: stay.transitFromPreviousRaw))
        })
        func members(_ id: UUID) -> [String] {
            guard let index = timeline.stays.firstIndex(where: { $0.id == id }),
                  let journey = timeline.journey(containing: index) else { return [id.uuidString] }
            return journey.members.map { timeline.stays[$0].id.uuidString }
        }
        var results: [[String: Any]] = []
        for flight in collections.flights {
            results.append(["first": flight.id.uuidString, "kind": "auto", "reason": "recorded",
                            "members": members(flight.id), "km": flight.distanceKm,
                            "route": flight.routeLabel])
        }
        for candidate in collections.possibleFlights {
            results.append(["first": candidate.id.uuidString, "kind": "cand",
                            "reason": candidate.evidenceRaw, "members": members(candidate.id),
                            "km": candidate.record.distanceKm, "gapHours": candidate.gapHours,
                            "route": candidate.record.routeLabel])
        }
        let output = ProcessInfo.processInfo.environment["TRAVELLOG_FLIGHT_BENCH_OUT"].map(URL.init(fileURLWithPath:))
            ?? url.deletingPathExtension().appendingPathExtension("results.json")
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        #expect(collections.flights.count + collections.possibleFlights.count == results.count)
    }
}
