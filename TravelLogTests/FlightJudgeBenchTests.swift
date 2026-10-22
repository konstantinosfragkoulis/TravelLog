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
//  Optional `observedTimestamps` are the retained raw-fix timestamps (ISO
//  8601). Absent evidence remains unknown; stored stay ends are never
//  converted into measured fixes by this benchmark.
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
        let observedTimestamps: [String]?
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
        let rowIDs = try bench.stays.map { try #require(UUID(uuidString: $0.id)) }
        try #require(Set(rowIDs).count == rowIDs.count,
                     "this portable bench format requires unique stay UUIDs for unambiguous journey scoring")
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let kept: Set<String?> = [nil, TransitMode.unknown.rawValue, TransitMode.flight.rawValue,
                                  TransitMode.notFlight.rawValue]
        for (row, rowID) in zip(bench.stays, rowIDs) {
            let start = try #require(Self.date(row.start)), end = try #require(Self.date(row.end))
            let observedDates = try (row.observedTimestamps ?? []).map { text in
                let date = try #require(Self.date(text))
                try #require(date >= start && date <= end,
                             "authored raw observations must be inside their stay interval")
                return date
            }
            let pings = observedDates.map { date in
                let ping = LocationPing(timestamp: date, latitude: row.latitude,
                                        longitude: row.longitude, horizontalAccuracy: 20,
                                        h3IndexRes6: "")
                // Preserve persisted provenance, including future/unknown
                // tokens. DataSource.decode's compatibility fallback must
                // never turn a benchmark import into live evidence.
                ping.sourceRaw = row.sourceRaw
                ping.isProcessed = true
                context.insert(ping)
                return ping
            }
            let stay = Stay(startTime: start, endTime: end,
                            centroidLatitude: row.latitude, centroidLongitude: row.longitude,
                            h3IndexRes6: "", pingCount: row.pingCount, distanceFromHomeKm: 100,
                            pingIDs: pings.map(\.id))
            stay.sourceRaw = row.sourceRaw
            stay.id = rowID
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

        let scoringContext = ModelContext(container)
        let stays = try scoringContext.fetch(FetchDescriptor<Stay>())
        let observations = try FlightObservationBounds.fetch(stays: stays, in: scoringContext)
        let collections = CollectionsAggregator.aggregate(
            stays: stays, dismissedCandidates: [], observationEvidenceByIdentifier: observations)
        // The journeys, for scoring by their stays.
        let timeline = FlightJudge.Timeline(stays.map { stay in
            FlightJudge.Stay(id: stay.id, start: stay.startTime, end: stay.endTime,
                             latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                             isAirport: stay.isAirport, islandName: stay.islandName, pingCount: stay.pingCount,
                             isPhoto: DataSource.needsPhotoTimeCaution(rawValue: stay.sourceRaw)
                                || (observations[stay.persistentModelID]?.retainedSourceRaws
                                    .contains(where: { DataSource.needsPhotoTimeCaution(rawValue: $0) }) ?? false),
                             mode: FlightJudge.Mode(raw: stay.transitFromPreviousRaw),
                             lastObservedAt: observations[stay.persistentModelID]?.lastObservedAt)
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
