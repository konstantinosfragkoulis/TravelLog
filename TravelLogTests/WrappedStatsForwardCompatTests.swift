//
//  WrappedStatsForwardCompatTests.swift
//  TravelLogTests
//
//  Guards the WrappedStats forward-compatibility rule: every field added
//  after first ship MUST be Optional. Synthesized Codable does NOT use a
//  property's default value for a missing key, so a non-optional addition
//  (even a defaulted `var x: Int = 0`) would make every pre-existing
//  `YearWrapped.statsData` blob fail to decode — silently wiping the
//  user's Wrapped stats on upgrade.
//

import Foundation
import Testing
@testable import TravelLog

struct WrappedStatsForwardCompatTests {

    /// The exact non-optional key set `WrappedStats` wrote as of 2026-06
    /// (optional keys deliberately absent — old blobs may omit them too).
    /// Do NOT update this fixture when adding fields: its whole purpose is
    /// to stand in for blobs already written to users' stores. If
    /// `frozenPreUpgradeBlobStillDecodes` fails, a non-optional field was
    /// added — make it Optional instead.
    private static let frozenV1Blob = Data("""
    {
      "countriesVisited": 7,
      "citiesVisited": 21,
      "totalDaysAbroad": 40,
      "totalHexesVisited": 130,
      "longestTripDays": 12,
      "farthestDistanceKm": 9000.5,
      "flightKm": 18000,
      "driveKm": 1200,
      "walkKm": 80,
      "totalGreatCircleKm": 19500,
      "newCountryCodes": ["JP", "KR"],
      "mostVisitedCountryTripCount": 3,
      "daysAbroad": 40,
      "daysAtHome": 325,
      "tripsCompleted": 9
    }
    """.utf8)

    @Test func frozenPreUpgradeBlobStillDecodes() {
        let stats = WrappedStats.decoded(from: Self.frozenV1Blob)
        #expect(stats != nil)
        #expect(stats?.countriesVisited == 7)
        #expect(stats?.newCountryCodes == ["JP", "KR"])
        // Optional keys absent from the blob decode to nil, not failure.
        #expect(stats?.hottestTempC == nil)
        #expect(stats?.longestTripName == nil)
        #expect(stats?.longestTripStartDate == nil)
        #expect(stats?.mysteryFactText == nil)
        #expect(stats?.mysteryFact == nil)
        #expect(stats?.narrativeInputs == nil)
    }

    @Test func missingNonOptionalKeyFailsToDecode() {
        // Documents the sharp edge the rule exists for: synthesized Codable
        // throws on a missing NON-optional key despite the property default.
        // (If this ever starts decoding, Swift changed Codable semantics and
        // the rule in YearWrapped.swift's doc comment should be revisited.)
        #expect(WrappedStats.decoded(from: Data("{}".utf8)) == nil)
    }

    // This file's job is the FROZEN blob + the missing-key sharp edge, which
    // self round-trips can't cover; every-field round trips live in
    // WrappedStatsCodableTests.
}
