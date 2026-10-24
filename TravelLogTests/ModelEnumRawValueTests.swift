//
//  ModelEnumRawValueTests.swift
//  TravelLogTests
//
//  PERSISTED-TOKEN tables + decode-fallback contracts for every String-backed
//  model enum: DataSource, StayCategory, TransitMode, SummarySource,
//  ImportStatus, StayWeather.Condition. These strings live in the SwiftData
//  store (and some are hard-coded into #Predicate string matching — e.g.
//  "photoImport" in the dedup predicate, the widget category predicates), so
//  the load-bearing invariant is that each case's rawValue equals its FROZEN
//  persisted token. A rename breaks these tables loudly.
//
//  (Do not replace these literal tables with self-derived
//  `Enum(rawValue: c.rawValue) == c` round trips: renaming a token changes
//  both sides, so a round trip can never catch the one defect this file
//  exists for.)
//
//  The decode fallbacks are real custom logic and stay: DataSource → .liveSLC,
//  TransitMode → .unknown, SummarySource → .deterministic (NOT its first case).
//  All enums are pure Sendable values — no @MainActor, no SwiftData container.
//

import Testing
import Foundation
@testable import TravelLog

struct ModelEnumRawValueTests {

    /// Asserts an exhaustive `(case, frozen persisted token)` table: every
    /// case appears exactly once and carries exactly its frozen string. The
    /// table length check means ADDING a case also fails here until its token
    /// is frozen deliberately.
    private func expectTokens<E: RawRepresentable & CaseIterable & Equatable>(
        _ type: E.Type, _ frozen: [(E, String)]
    ) where E.RawValue == String {
        #expect(frozen.count == E.allCases.count,
                "token table out of date: \(E.allCases.count) cases, \(frozen.count) frozen")
        for (c, token) in frozen {
            #expect(c.rawValue == token, "\(c) persisted token drifted")
        }
    }

    // MARK: - Persisted-token tables

    @Test("DataSource persisted tokens are frozen")
    func dataSourceTokens() {
        expectTokens(DataSource.self, [
            (.liveSLC, "liveSLC"),
            (.foregroundStream, "foregroundStream"),
            (.photoImport, "photoImport"),   // hard-coded in the dedup #Predicate
            (.merged, "merged"),
            (.jsonImport, "jsonImport"),
            (.timelineImport, "timelineImport"),
            (.gpxImport, "gpxImport"),
            (.sharedImport, "sharedImport"),
        ])
    }

    @Test("StayCategory persisted tokens are frozen (widget predicates + store)")
    func stayCategoryTokens() {
        expectTokens(StayCategory.self, [
            (.home, "home"),
            (.routine, "routine"),
            (.destination, "destination"),
            (.transit, "transit"),
            (.unclassified, "unclassified"),
        ])
        for c in StayCategory.allCases {
            #expect(c.id == c.rawValue)
        }
    }

    @Test("TransitMode persisted tokens are frozen")
    func transitModeTokens() {
        expectTokens(TransitMode.self, [
            (.stationary, "stationary"),
            (.walking, "walking"),
            (.running, "running"),
            (.cycling, "cycling"),
            (.automotive, "automotive"),
            (.flight, "flight"),
            (.mixed, "mixed"),
            (.unknown, "unknown"),
            (.notFlight, "notFlight"),
        ])
    }

    @Test("SummarySource persisted tokens are frozen")
    func summarySourceTokens() {
        expectTokens(SummarySource.self, [
            (.foundationModels, "foundationModels"),
            (.deterministic, "deterministic"),
        ])
    }

    @Test("ImportStatus persisted tokens are frozen")
    func importStatusTokens() {
        expectTokens(ImportStatus.self, [
            (.idle, "idle"),
            (.running, "running"),
            (.paused, "paused"),
            (.completed, "completed"),
            (.failed, "failed"),
            (.cancelled, "cancelled"),
        ])
    }

    @Test("StayWeather.Condition persisted tokens are frozen")
    func stayWeatherConditionTokens() {
        expectTokens(StayWeather.Condition.self, [
            (.clear, "clear"), (.partlyCloudy, "partlyCloudy"),
            (.cloudy, "cloudy"), (.rain, "rain"), (.heavyRain, "heavyRain"),
            (.drizzle, "drizzle"), (.snow, "snow"), (.sleet, "sleet"),
            (.thunderstorms, "thunderstorms"), (.fog, "fog"), (.haze, "haze"),
            (.windy, "windy"), (.hot, "hot"), (.cold, "cold"),
            (.unknown, "unknown"), (.unavailable, "unavailable"),
        ])
    }

    // MARK: - Decode fallbacks (custom logic, each deliberately distinct)

    @Test("DataSource.decode unknown/empty → .liveSLC; known → itself")
    func dataSourceDecodeUnknownFallsBackToLiveSLC() {
        #expect(DataSource.decode("nonsense") == .liveSLC)
        #expect(DataSource.decode("") == .liveSLC)
        #expect(DataSource.decode("photoImport") == .photoImport)
    }

    @Test("DataSource identifies raw live observations and normalizes derived provenance")
    func dataSourceLiveObservationAndDerivedRollup() {
        for source in DataSource.allCases {
            #expect(source.isLiveObservation
                    == (source == .liveSLC || source == .foregroundStream))
            #expect(source.derivedRecordSource
                    == (source == .foregroundStream ? .liveSLC : source))
        }
    }

    @Test("TransitMode.decode unknown → .unknown; known → itself")
    func transitModeDecodeUnknownFallsBackToUnknown() {
        #expect(TransitMode.decode("teleport") == .unknown)
        #expect(TransitMode.decode("flight") == .flight)
    }

    @Test("SummarySource.decode unknown → .deterministic (NOT its first case)")
    func summarySourceDecodeUnknownFallsBackToDeterministic() {
        #expect(SummarySource.decode("future") == .deterministic)
        #expect(SummarySource.decode("foundationModels") == .foundationModels)
    }

    // MARK: - Display metadata (switch totality)

    @Test("StayCategory.displayName is the expected human label",
          arguments: zip(StayCategory.allCases,
                         ["Home", "Routine", "Destination", "Transit", "Unclassified"]))
    func stayCategoryDisplayNameMatchesExpectedLabel(c: StayCategory, expected: String) {
        #expect(c.displayName == expected)
    }

    @Test("TransitMode displayName + systemImage non-empty for every case",
          arguments: TransitMode.allCases)
    func transitModeDisplayAndSystemImageTotal(c: TransitMode) {
        #expect(!c.displayName.isEmpty)
        #expect(!c.systemImage.isEmpty)
    }

    @Test("TransitMode.automotive maps to Driving / car.fill (representative arm)")
    func transitModeAutomotiveMapping() {
        #expect(TransitMode.automotive.displayName == "Driving")
        #expect(TransitMode.automotive.systemImage == "car.fill")
    }

    @Test("StayWeather.Condition systemImage non-empty for every case",
          arguments: StayWeather.Condition.allCases)
    func stayWeatherConditionSystemImageTotal(c: StayWeather.Condition) {
        #expect(!c.systemImage.isEmpty)
    }

    @Test("StayWeather.Condition terminal cases map to representative glyphs")
    func stayWeatherConditionTerminalGlyphs() {
        #expect(StayWeather.Condition.unavailable.systemImage == "xmark.circle")
        #expect(StayWeather.Condition.unknown.systemImage == "questionmark.circle")
    }
}
