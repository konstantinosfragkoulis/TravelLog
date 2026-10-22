//
//  GeocoderSnapshotDumpTests.swift
//  TravelLogTests
//
//  Opt-in tool for comparing two Geocoder.sqlite builds through the real
//  resolver (island area cap, town fallback, neighbourhood ranking), which a
//  SQL-level comparison cannot reproduce. Bundle one database, run this with
//  a coordinate list, swap the bundled file, run it again, and diff the two
//  outputs (see scripts/REBUILD_GEOCODER.md §6.6a).
//
//  Environment (pass through xcodebuild with the TEST_RUNNER_ prefix):
//    TRAVELLOG_GEOCODER_DUMP=1
//    GEOCODER_DUMP_INPUT=/path/in.tsv     label <TAB> latitude <TAB> longitude
//    GEOCODER_DUMP_OUTPUT=/path/out.tsv
//

import Foundation
import Testing
@testable import TravelLog

struct GeocoderSnapshotDumpTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TRAVELLOG_GEOCODER_DUMP"] == "1"
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(30)))
    func dumpResolverResults() async throws {
        let environment = ProcessInfo.processInfo.environment
        let inputPath = try #require(environment["GEOCODER_DUMP_INPUT"])
        let outputPath = try #require(environment["GEOCODER_DUMP_OUTPUT"])
        let input = try String(contentsOfFile: inputPath, encoding: .utf8)

        var lines: [String] = []
        lines.reserveCapacity(input.utf8.count / 24)
        for row in input.split(separator: "\n") {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3,
                  let latitude = Double(columns[1]),
                  let longitude = Double(columns[2]) else { continue }
            let result = await GeocodeResolver.shared.resolve(
                latitude: latitude, longitude: longitude)
            let fields = [
                result?.isoCountryCode, result?.country, result?.administrativeArea,
                result?.metroName, result?.localityName, result?.subLocalityName,
                result?.islandName,
            ].map { $0 ?? "" }
            lines.append(([String(columns[0]), String(columns[1]), String(columns[2])] + fields)
                .joined(separator: "\t"))
        }

        #expect(!lines.isEmpty, "no parseable rows in \(inputPath)")
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
