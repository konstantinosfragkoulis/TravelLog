//
//  TripIntentSearchTests.swift
//  TravelLogTests
//
//  Local-pass behavior of the Siri search intent's orchestration. The FM
//  fallback path is deliberately NOT exercised — `TripSearchAI` would do a
//  real Foundation Models call on Apple Intelligence-enabled hardware,
//  which is slow and nondeterministic in a unit suite. The strong-hit
//  short-circuit below proves `run()` never reaches it when the resolver
//  matches strongly.
//

import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

@MainActor
struct TripIntentSearchTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func seedParisTrip(in context: ModelContext) throws -> Trip {
        let trip = Trip(startDate: date(2025, 6, 10))
        trip.endDate = date(2025, 6, 14)
        trip.isComplete = true
        trip.customName = "Paris Weekend"
        trip.countryCodes = "FR"
        trip.destinationSummary = "Paris"
        context.insert(trip)
        try context.save()
        return trip
    }

    private func addStay(
        to trip: Trip,
        in context: ModelContext,
        category: StayCategory,
        locality: String,
        iso: String
    ) {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate.addingTimeInterval(86_400),
                        centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                        pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.locality = locality
        stay.isoCountryCode = iso
        stay.orderInTrip = trip.stays?.count ?? 0
        stay.trip = trip
    }

    @Test func localMatchFindsTripByName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)

        let matches = try TripIntentSearch.localMatches(query: "paris", container: container)
        #expect(matches.map(\.id) == [trip.id])
    }

    @Test func parisFixtureSearchIsIdenticalWithColdAndWarmMemo() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try seedParisTrip(in: context)
        for language in ["en", "el", "fr"] {
            for query in ["paris", "france", "paris france", "parsi", "2025", "june", "missing", ""] {
                TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
                let cold = try TripIntentSearch.localMatches(query: query, container: container, languageTag: language)
                let warm = try TripIntentSearch.localMatches(query: query, container: container, languageTag: language)
                #expect(cold.map(\.id) == warm.map(\.id))
            }
        }
    }

    @Test func localMatchFindsTripByCountryName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)

        // "france" only exists via the ISO-code expansion in the country field.
        let matches = try TripIntentSearch.localMatches(query: "france", container: container)
        #expect(matches.map(\.id) == [trip.id])
    }

    @Test func emptyAndWhitespaceQueriesReturnNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try seedParisTrip(in: context)

        #expect(try TripIntentSearch.localMatches(query: "", container: container).isEmpty)
        #expect(try TripIntentSearch.localMatches(query: "   ", container: container).isEmpty)
        #expect(try await TripIntentSearch.localMatchesOffMain(query: " \t", container: container).isEmpty)
        let viaRun = try await TripIntentSearch.run(query: "  \n", container: container)
        #expect(viaRun.isEmpty)
    }

    @Test func runReturnsStrongHitsWithoutTouchingAIFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)

        let results = try await TripIntentSearch.run(query: "Paris", container: container)
        #expect(results.map(\.id) == [trip.id])
        #expect(results.first?.title == "Paris Weekend")
    }

    /// Delete All Data moves the snapshot-clear generation. A search that
    /// read its trips before the wipe must not answer with them after it.
    @Test func runRefusesAnswerRevokedByADeletionMidSearch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)
        let suiteName = "TripIntentSearchTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suiteName
        )) {
            let wipeDuringRead: @Sendable (IntentRead) throws -> Void = { read in
                if read == .searchTrips { StatsSnapshotStore.clear() }
            }
            await #expect(throws: IntentDataError.self) {
                try await IntentRead.$failureForTesting.withValue(wipeDuringRead) {
                    try await TripIntentSearch.run(query: "Paris", container: container)
                }
            }
            // A search begun after the clear answers normally.
            let after = try await TripIntentSearch.run(query: "Paris", container: container)
            #expect(after.map(\.id) == [trip.id])
        }
    }

    /// The Shortcuts parameter search reads through the same local worker,
    /// so a wipe that overtakes it revokes its answer too.
    @Test func entityQueryRefusesAnswerRevokedByADeletionMidSearch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)
        let query = TripEntityQuery(container: container, isPersistentStore: true)
        let suiteName = "TripIntentSearchTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await StatsSnapshotStore.$storageForTesting.withValue(.init(
            directory: directory, defaultsSuiteName: suiteName
        )) {
            let wipeDuringRead: @Sendable (IntentRead) throws -> Void = { read in
                if read == .searchTrips { StatsSnapshotStore.clear() }
            }
            await #expect(throws: IntentDataError.self) {
                try await IntentRead.$failureForTesting.withValue(wipeDuringRead) {
                    try await query.entities(matching: "Paris")
                }
            }
            // A search begun after the clear answers normally.
            let after = try await query.entities(matching: "Paris")
            #expect(after.map(\.id) == [trip.id])
        }
    }

    @Test func runUsesCorpusAwarePlaceInterpretationBeforeAIFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2025, 7, 10))
        trip.endDate = date(2025, 7, 14)
        trip.isComplete = true
        trip.destinationSummary = "Winter Park"
        context.insert(trip)
        try context.save()

        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
        let cold = try TripIntentSearch.localMatches(query: "Winter Park", container: container)
        let warm = try TripIntentSearch.localMatches(query: "Winter Park", container: container)
        #expect(cold.map(\.id) == warm.map(\.id))

        // The old chain's raw fuzzy pass rejected the filler words, then its
        // parser consumed "winter" as Dec/Jan/Feb and filtered this July trip
        // out. A local hit also proves `run` never needs nondeterministic FM.
        let results = try await TripIntentSearch.run(
            query: "trips to Winter Park",
            container: container
        )
        #expect(results.map(\.id) == [trip.id])
    }

    @Test func strongMatchesComeBeforeSimilarOnes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Newest first in index order: the layover trip precedes the stay.
        let layover = Trip(startDate: date(2025, 5, 1))
        layover.endDate = date(2025, 5, 6)
        layover.isComplete = true
        layover.customName = "Porto Spring"
        context.insert(layover)
        addStay(to: layover, in: context, category: .transit, locality: "Frankfurt", iso: "DE")
        addStay(to: layover, in: context, category: .destination, locality: "Porto", iso: "PT")
        let visit = Trip(startDate: date(2023, 3, 1))
        visit.endDate = date(2023, 3, 4)
        visit.isComplete = true
        visit.customName = "Book Fair"
        context.insert(visit)
        addStay(to: visit, in: context, category: .destination, locality: "Frankfurt", iso: "DE")
        try context.save()

        let ranked = try TripIntentSearch.rankedLocalMatches(query: "frankfurt", container: container, languageTag: "en")
        #expect(ranked.map(\.entity.id) == [visit.id, layover.id])
        #expect(ranked.map(\.strength) == [.strong, .similar])
        #expect(try TripIntentSearch.localMatches(query: "frankfurt", container: container, languageTag: "en")
            .map(\.id) == [visit.id, layover.id])
    }

    @Test func duplicateTripIDsCollapseToOneEntity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try seedParisTrip(in: context)
        let twin = Trip(startDate: trip.startDate)
        twin.id = trip.id
        twin.endDate = trip.endDate
        twin.isComplete = true
        twin.customName = "Paris Weekend"
        context.insert(twin)
        try context.save()

        #expect(try TripIntentSearch.localMatches(query: "paris", container: container).map(\.id) == [trip.id])
    }

    /// Local matches equal the shared resolver over documents of the same
    /// rows: strong, then similar, then partial, index order within each,
    /// Trip.id collapsed.
    @Test func localMatchesAgreeWithTheResolver() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try seedParisTrip(in: context)
        let tokyo = Trip(startDate: date(2024, 4, 2))
        tokyo.endDate = date(2024, 4, 12)
        tokyo.isComplete = true
        tokyo.aiGeneratedTitle = "Tokyo Spring"
        tokyo.titleSourceRevision = UUID()
        tokyo.countryCodes = "JP"
        tokyo.destinationSummary = "Tokyo, Kyoto"
        context.insert(tokyo)
        addStay(to: tokyo, in: context, category: .destination, locality: "Tokyo", iso: "JP")
        addStay(to: tokyo, in: context, category: .destination, locality: "Kyoto", iso: "JP")
        let lisbon = Trip(startDate: date(2024, 10, 5))
        lisbon.endDate = date(2024, 10, 6)
        lisbon.isComplete = true
        lisbon.destinationSummary = "Lisbon"
        lisbon.countryCodes = "PT"
        context.insert(lisbon)
        let lastYear = Calendar.current.component(.year, from: .now) - 1
        let rome = Trip(startDate: date(lastYear, 3, 3))
        rome.endDate = date(lastYear, 3, 8)
        rome.isComplete = true
        rome.destinationSummary = "Rome"
        rome.countryCodes = "IT"
        context.insert(rome)
        try context.save()

        let fetch = ModelContext(container)
        let trips = try fetch.fetch(FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\Trip.startDate, order: .reverse)]))
        let index = TripSearchIndex(documents: trips.map { TripSearchDocument.make(from: $0, languageTag: "en") })

        let queries = [
            "paris", "my tokyo trip", "trips to paris", "weekend trips", "last year",
            "tokyo 2024", "kyoto april", "japan", "parsi", "paris tokyo", "missing", "2024",
        ]
        for query in queries {
            let resolved = TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: false, languageTag: "en")
            var seen = Set<UUID>()
            let strengths: [TripSearchStrength] = [.strong, .similar, .partial]
            let expected = strengths.flatMap { strength in
                resolved.filter { $0.strength == strength }.map { trips[$0.documentIndex].id }
            }.filter { seen.insert($0).inserted }
            let local = try TripIntentSearch.localMatches(query: query, container: container, languageTag: "en")
            #expect(local.map(\.id) == expected, "\(query)")
        }
        #expect(try !TripIntentSearch.localMatches(query: "my tokyo trip", container: container, languageTag: "en").isEmpty)
        #expect(try !TripIntentSearch.localMatches(query: "trips to paris", container: container, languageTag: "en").isEmpty)
    }
}
