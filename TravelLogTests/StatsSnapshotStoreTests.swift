//
//  StatsSnapshotStoreTests.swift
//  TravelLogTests
//
//  The persisted Stats snapshot supports cold-launch hydration.
//  A fully populated `StatsAggregator.Aggregates`, including
//  every nested Collections/passport type, must survive the disk round
//  trip. Date-sensitive on-this-day groups stay in the live input, and the store must
//  degrade to nil (never trap, never partial) on garbage input. Pure value
//  types + a real file in a unique temporary directory per test.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

// Each test binds its own snapshot file and wipe generation, including actor/gate calls.
@Suite(.serialized)
struct StatsSnapshotStoreTests {

    private func withIsolatedStorage(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Void
    ) async throws {
        let suiteName = "StatsSnapshotStoreTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suiteName
        )) {
            #expect(StatsSnapshotStore.clearGeneration == 0)
            try await body()
        }
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// An `Aggregates` with every branch populated — nil-heavy defaults
    /// would round-trip trivially and prove nothing.
    private func populatedAggregates() -> StatsAggregator.Aggregates {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.totalPings = 48_211
        aggregates.totalStays = 913
        aggregates.totalHexes = 402
        aggregates.totalTrips = 31
        aggregates.trackingSince = utc(2019, 1, 26)
        aggregates.newHexesThisYear = 57
        aggregates.topHexCountries = [
            .init(code: "GR", name: "Greece", count: 210),
            .init(code: "NL", name: nil, count: 44),
        ]
        aggregates.flightCount = 12
        aggregates.onThisDayGroups = [
            OnThisDayYearGroup(year: 2023, yearsAgo: 3, trips: [
                OnThisDayTripGroup(id: "2023-abc", tripID: UUID(),
                                   places: ["Kyoto", "Osaka"], stayCount: 4,
                                   weatherConditionRaw: "clear", avgTemperatureC: 21.5),
            ]),
        ]
        aggregates.uniqueCountries = ["GR", "NL", "JP"]
        aggregates.countryStats = [
            CountryStat(code: "GR", name: "Greece", tripCount: 9, isHome: true),
            CountryStat(code: "JP", name: "Japan", tripCount: 1, isHome: false),
        ]
        aggregates.lastTrip = StatsAggregator.LastTrip(name: "Cephalonia Hop", date: utc(2026, 5, 5))

        var passport = PassportData()
        passport.countries = 14
        passport.furthestKm = 9_412.5
        passport.furthestPlace = "Kyoto"
        passport.sinceYear = 2019
        passport.longestTripName = "Japan"
        passport.longestTripDays = 16
        passport.hottestTempC = 38.2
        passport.hottestPlace = "Athens"
        passport.coldestTempC = -4.1
        passport.coldestPlace = "Vienna"
        aggregates.passportData = passport

        var collections = CollectionsAggregator.Collections()
        collections.airports = [
            .init(code: "ATH", name: "Athens International", city: "Athens",
                  isoCountryCode: "GR", hasScheduledService: true,
                  stayCount: 7, firstVisit: utc(2021, 3, 27),
                  lastVisit: utc(2026, 5, 5), flownThrough: true),
        ]
        let leg = CollectionsAggregator.FlightRecord(
            id: UUID(), departureCode: "ATH", arrivalCode: "AMS",
            departurePlace: "Athens", arrivalPlace: "Amsterdam",
            departureISO: "GR", arrivalISO: "NL",
            date: utc(2026, 4, 2), distanceKm: 2_205,
            estimatedHours: 3.33, isInternational: true,
            timeZonesCrossed: 1, isOvernight: false,
            departureWindowStart: utc(2026, 4, 1)
        )
        collections.flights = [leg]
        collections.flightStats.totalFlights = 12
        collections.flightStats.totalKm = 30_100
        collections.flightStats.mostFlownRouteLabel = "AMS ↔ ATH"
        collections.flightStats.mostFlownRouteCount = 4
        collections.possibleFlights = [
            .init(record: leg, evidenceRaw: CollectionsAggregator.CandidateEvidence.acrossWater.rawValue,
                  gapHours: 33.5),
        ]
        collections.places = [
            .init(id: "Athens|GR", name: "Athens", isoCountryCode: "GR",
                  country: "Greece", kind: .metro, tripCount: 9, stayCount: 40,
                  dayCount: 120, firstVisit: utc(2019, 1, 26),
                  lastVisit: utc(2026, 5, 27), localities: ["Gérakas", "Agios Dimitrios"]),
        ]
        aggregates.collections = collections
        return aggregates
    }

    @Test("A pre-wipe file left on disk cannot hydrate after its generation is cleared")
    func retainedOldFileCannotHydrate() async throws {
        try await withIsolatedStorage {
            StatsSnapshotStore.save(populatedAggregates(), generation: StatsSnapshotStore.clearGeneration)
            let url = try #require(StatsSnapshotStore.fileURL)
            let oldFile = try Data(contentsOf: url)
            StatsSnapshotStore.clear()
            // Model an unsuccessful unlink (or an external stale replacement):
            // the bytes still exist, but the persistent wipe generation advanced.
            try oldFile.write(to: url, options: .atomic)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @Test("A delayed older accepted snapshot cannot replace a newer result")
    func acceptedWritersPublishInOrder() async throws {
        try await withIsolatedStorage {
            let generation = StatsSnapshotStore.clearGeneration
            let older = try #require(StatsSnapshotStore.reserveSave(generation: generation))
            let newer = try #require(StatsSnapshotStore.reserveSave(generation: generation))
            var a = populatedAggregates()
            a.totalPings = 100
            var b = a
            b.totalPings = 200
            StatsSnapshotStore.save(b, request: newer)
            StatsSnapshotStore.save(a, request: older)
            #expect(StatsSnapshotStore.load()?.totalPings == 200)
            StatsSnapshotStore.clear()
            StatsSnapshotStore.save(b, request: newer)
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @Test("an unrelated task's clear cannot invalidate this test's snapshot or generation")
    func unrelatedClearPreservesSnapshot() async throws {
        try await withIsolatedStorage {
            let generation = StatsSnapshotStore.clearGeneration
            StatsSnapshotStore.save(populatedAggregates(), generation: generation, languageTag: "en")
            #expect(StatsSnapshotStore.load(languageTag: "en") != nil)

            // A detached task drops this scope, but must still use temporary storage.
            let otherSuite = "StatsSnapshotStoreTests.detached.\(UUID().uuidString)"
            let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(otherSuite)
            let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
            defer {
                try? FileManager.default.removeItem(at: otherDirectory)
                otherDefaults.removePersistentDomain(forName: otherSuite)
            }
            let generations = await Task.detached {
                StatsSnapshotStore.$storageForTesting.withValue(.init(
                    directory: otherDirectory, defaultsSuiteName: otherSuite
                )) {
                    let before = StatsSnapshotStore.clearGeneration
                    StatsSnapshotStore.clear()
                    return (before, StatsSnapshotStore.clearGeneration)
                }
            }.value
            #expect(generations.0 == 0)
            #expect(generations.1 > generations.0)

            #expect(StatsSnapshotStore.clearGeneration == generation)
            let loaded = try #require(StatsSnapshotStore.load(languageTag: "en"))
            #expect(loaded.totalPings == populatedAggregates().totalPings)
            StatsSnapshotStore.save(populatedAggregates(), generation: generation, languageTag: "en")
            #expect(StatsSnapshotStore.load(languageTag: "en") != nil)
        }
    }

    @MainActor
    @Test("calendar deletion removes the snapshot and rejects a pre-deletion queued save")
    func calendarDeletionInvalidatesSnapshot() async throws {
        try await withIsolatedStorage {
            let container = try TestSupport.makeInMemoryContainer()
            let enricher = CalendarEnricher(modelContainer: container)
            let generation = StatsSnapshotStore.clearGeneration
            StatsSnapshotStore.save(populatedAggregates(), generation: generation)
            #expect(StatsSnapshotStore.load() != nil)
            let result = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
                await enricher.deleteAllCalendarData()
            }
            #expect(result.succeeded)
            #expect(StatsSnapshotStore.load() == nil)
            #expect(StatsSnapshotStore.clearGeneration > generation)
            StatsSnapshotStore.save(populatedAggregates(), generation: generation)
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @MainActor
    @Test("photo discard removes the snapshot and rejects a pre-discard queued save")
    func photoDiscardInvalidatesSnapshot() async throws {
        try await withIsolatedStorage {
            let container = try TestSupport.makeInMemoryContainer()
            let service = PhotoImportService(modelContainer: container)
            let generation = StatsSnapshotStore.clearGeneration
            StatsSnapshotStore.save(populatedAggregates(), generation: generation)
            #expect(StatsSnapshotStore.load() != nil)
            try await service.performDiscardTeardownForTesting()
            #expect(StatsSnapshotStore.load() == nil)
            #expect(StatsSnapshotStore.clearGeneration > generation)
            StatsSnapshotStore.save(populatedAggregates(), generation: generation)
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @Test("the disk round trip preserves aggregates without copying live memories")
    func roundTripThroughDisk() async throws {
        try await withIsolatedStorage {
            let original = populatedAggregates()
            StatsSnapshotStore.save(original, generation: StatsSnapshotStore.clearGeneration)

            let loaded = try #require(StatsSnapshotStore.load())
            #expect(loaded.totalPings == original.totalPings)
            #expect(loaded.trackingSince == original.trackingSince)
            #expect(loaded.topHexCountries == original.topHexCountries)
            #expect(loaded.uniqueCountries == original.uniqueCountries)
            #expect(loaded.countryStats == original.countryStats)
            #expect(loaded.lastTrip == original.lastTrip)
            #expect(loaded.passportData == original.passportData)
            #expect(loaded.collections == original.collections)
            #expect(loaded.onThisDayGroups.isEmpty)
            #expect(original.onThisDayGroups.count == 1)
            #expect(original.onThisDayGroups.first?.trips.first?.places == ["Kyoto", "Osaka"])
        }
    }

    @Test("clear removes the snapshot; the next load is nil")
    func clearRemovesSnapshot() async throws {
        try await withIsolatedStorage {
            StatsSnapshotStore.save(populatedAggregates(), generation: StatsSnapshotStore.clearGeneration)
            StatsSnapshotStore.clear()
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @MainActor
    @Test("cached UUID twins preserve separate display identities without physical write authority")
    func cachedTwinDisplayIdentityHasNoWriteAuthority() async throws {
        try await withIsolatedStorage {
            var aggregates = populatedAggregates()
            var first = try #require(aggregates.collections.flights.first)
            let row = Stay(startTime: first.date, endTime: first.date.addingTimeInterval(3600),
                           centroidLatitude: 52, centroidLongitude: 4,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            first.arrivalIdentifier = row.persistentModelID
            first.actionGuard = .init(target: row.persistentModelID, id: first.id, start: row.startTime,
                                      end: row.endTime, modeRaw: nil, predecessor: nil,
                                      predecessorID: nil, predecessorEnd: nil, memberIDs: [])
            first.presentationToken = first.id.uuidString + ":0"
            first.logicalIdentityIsAmbiguous = true
            var second = first
            second.presentationToken = first.id.uuidString + ":1"
            aggregates.collections.flights = [first, second]
            StatsSnapshotStore.save(aggregates, generation: StatsSnapshotStore.clearGeneration)
            let loaded = try #require(StatsSnapshotStore.load())
            let records = loaded.collections.flights
            #expect(records.count == 2)
            #expect(Set(records.map(\.presentationID)).count == 2)
            #expect(records.first?.presentationID == .cached(first.id.uuidString + ":0"))
            #expect(records.last?.presentationID == .cached(first.id.uuidString + ":1"))
            #expect(records.allSatisfy { $0.presentationID != .physical(row.persistentModelID) })
            #expect(records.allSatisfy { $0.arrivalIdentifier == nil && $0.actionGuard == nil })
            #expect(records.allSatisfy { !$0.canUsePortablePreferences && $0.annotationSnapshot == nil })
            #expect(records.allSatisfy { FlightLogAuthority.Target(record: $0) == nil })
            let file = try String(contentsOf: #require(StatsSnapshotStore.fileURL), encoding: .utf8)
            #expect(!file.contains("arrivalIdentifier"))
            #expect(!file.contains("actionGuard"))
            #expect(!file.contains("annotationSnapshot"))
        }
    }

    /// Red/green pin: Delete All Data calls
    /// `clear()` synchronously, but every Stats compute persists through a
    /// fire-and-forget background task. A compute that read PRE-wipe state and
    /// lands AFTER the wipe must not recreate the file — otherwise the next
    /// cold launch hydrates the deleted totals into a wiped app.
    @Test("a save whose compute predates a wipe cannot resurrect the snapshot")
    func staleSaveCannotOutliveAWipe() async throws {
        try await withIsolatedStorage {
            // The generation the in-flight compute captured before the wipe.
            let generationBeforeWipe = StatsSnapshotStore.clearGeneration

            StatsSnapshotStore.clear()

            // The background save finally lands, carrying pre-wipe aggregates.
            StatsSnapshotStore.save(populatedAggregates(), generation: generationBeforeWipe)

            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @Test("a save taken after the wipe persists normally")
    func freshSaveAfterAWipeStillPersists() async throws {
        try await withIsolatedStorage {
            StatsSnapshotStore.clear()

            // A compute STARTED after the wipe captures the new generation.
            StatsSnapshotStore.save(populatedAggregates(), generation: StatsSnapshotStore.clearGeneration)

            let loaded = try #require(StatsSnapshotStore.load())
            #expect(loaded.totalPings == populatedAggregates().totalPings)
        }
    }

    @Test("a corrupt snapshot file reads as nil, never traps or half-decodes")
    func corruptFileDegradesToNil() async throws {
        try await withIsolatedStorage {
            let url = try #require(StatsSnapshotStore.fileURL)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("not json at all {{{".utf8).write(to: url, options: .atomic)
            #expect(StatsSnapshotStore.load() == nil)
        }
    }

    @Test("a snapshot from another app language is never hydrated")
    func languageMismatchDegradesToNil() async throws {
        try await withIsolatedStorage {
            StatsSnapshotStore.save(
                populatedAggregates(),
                generation: StatsSnapshotStore.clearGeneration,
                languageTag: "el"
            )

            #expect(StatsSnapshotStore.load(languageTag: "en") == nil)
            let matching = try #require(StatsSnapshotStore.load(languageTag: "el"))
            #expect(matching.lastTrip?.name == "Cephalonia Hop")
        }
    }

    @Test("clear removes both legacy language and old day-policy caches")
    func clearRemovesLegacySnapshot() async throws {
        try await withIsolatedStorage {
            let currentURL = try #require(StatsSnapshotStore.fileURL)
            let legacyURLs = ["stats-aggregates-snapshot-v1.json", "stats-aggregates-snapshot-v2.json", "stats-aggregates-snapshot-v3.json", "stats-aggregates-snapshot-v4.json", "stats-aggregates-snapshot-v5.json", "stats-aggregates-snapshot-v6.json", "stats-aggregates-snapshot-v7.json"].map {
                currentURL.deletingLastPathComponent().appendingPathComponent($0)
            }
            try FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for url in legacyURLs { try Data("legacy cache".utf8).write(to: url, options: .atomic) }
            #expect(currentURL.lastPathComponent == "stats-aggregates-snapshot-v8.json")
            StatsSnapshotStore.clear()
            #expect(legacyURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    @Test("a degraded compute is never persisted, so hydration only sees complete aggregates")
    func degradedSnapshotIsRefused() async throws {
        try await withIsolatedStorage {
            var degraded = populatedAggregates()
            degraded.computeDegraded = true
            StatsSnapshotStore.save(degraded, generation: StatsSnapshotStore.clearGeneration)
            #expect(StatsSnapshotStore.load() == nil)
            let url = try #require(StatsSnapshotStore.fileURL)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("a degraded payload already on disk does not hydrate; an absent flag stays healthy")
    func degradedPayloadOnDiskDoesNotHydrate() async throws {
        try await withIsolatedStorage {
            StatsSnapshotStore.save(
                populatedAggregates(), generation: StatsSnapshotStore.clearGeneration, languageTag: "en")
            let url = try #require(StatsSnapshotStore.fileURL)
            let healthy = try #require(StatsSnapshotStore.load(languageTag: "en"))
            #expect(healthy.computeDegraded == nil)

            func rewrite(computeDegraded: Bool) throws {
                var object = try #require(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                var aggregates = try #require(object["aggregates"] as? [String: Any])
                aggregates["computeDegraded"] = computeDegraded
                object["aggregates"] = aggregates
                try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
            }
            // The rewrite path itself decodes: an explicit false still loads.
            try rewrite(computeDegraded: false)
            #expect(StatsSnapshotStore.load(languageTag: "en") != nil)
            try rewrite(computeDegraded: true)
            #expect(StatsSnapshotStore.load(languageTag: "en") == nil)
        }
    }
}
