//
//  TripSearchIndexStoreTests.swift
//  TravelLogTests
//
//  The Trips list's search cache: stale-while-revalidate across store token
//  changes, fingerprint rebuilds, twins, deletes, wipe revocation, the memo
//  and the main-thread budget. Every test owns a `TripSearchIndexStore
//  (forTesting:)` over an isolated `StoreChangeTracker(forTesting:)`, so the
//  shared tracker is never bumped. Serialized: the store clears the global
//  normalization memo on `invalidateAll()`.
//

import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

/// Holds an injected build until the test releases it.
private actor BuildGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

@MainActor
@Suite(.serialized)
struct TripSearchIndexStoreTests {

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    private func makeStore(builder: TripSearchIndexStore.Builder? = nil) -> (TripSearchIndexStore, StoreChangeTracker) {
        let tracker = StoreChangeTracker(forTesting: ())
        return (TripSearchIndexStore(forTesting: tracker, builder: builder), tracker)
    }

    @discardableResult
    private func makeTrip(
        in context: ModelContext,
        start: Date,
        summary: String,
        locality: String? = nil
    ) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(3 * 86_400)
        trip.isComplete = true
        trip.destinationSummary = summary
        context.insert(trip)
        if let locality {
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(86_400),
                            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            context.insert(stay)
            stay.category = .destination
            stay.locality = locality
            stay.orderInTrip = 0
            stay.trip = trip
        }
        return trip
    }

    private func ids(_ results: [(trip: Trip, match: TripSearchMatch)]?) -> [PersistentIdentifier]? {
        results?.map(\.trip.persistentModelID)
    }

    @Test func emptyQueryBypassesTheStore() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trips = [makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")]
        try context.save()
        let (store, _) = makeStore()

        for query in ["", "   ", "\n"] {
            let results = store.search(trips, query: query, allowsTrailingPartial: true, languageTag: "en")
            #expect(results?.isEmpty == true)
        }
        #expect(store.cachedDocumentCount == 0)
        #expect(store.synchronousBuildCount == 0)
        #expect(!store.hasPendingBuild)
    }

    @Test func coldCacheWithinBudgetBuildsOnMainAndFinds() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lisbon = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        let rome = makeTrip(in: context, start: day(2023, 5, 1), summary: "Rome")
        try context.save()
        let (store, _) = makeStore()

        let results = store.search([lisbon, rome], query: "lisbon", allowsTrailingPartial: false, languageTag: "en")
        #expect(ids(results) == [lisbon.persistentModelID])
        #expect(results?.first?.match.strength == .strong)
        #expect(store.synchronousBuildCount == 2)
        #expect(!store.hasPendingBuild)
        #expect(store.indexedTrips([lisbon, rome], languageTag: "en")?.index.documents.count == 2)
    }

    @Test func keyChangeKeepsStaleDocumentsAndSchedulesOneRebuild() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon", locality: "Belem")
        try context.save()
        let trips = [trip]
        let (store, tracker) = makeStore()

        #expect(ids(store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        let mainBuilds = store.synchronousBuildCount
        let generation = store.generation

        // A stay-only edit: the fingerprint is unchanged, so main keeps the
        // stale document and the store revalidates off-main.
        let stay = try #require(trip.stays?.first)
        stay.locality = "Porto"
        try context.save()
        tracker.applyNowForTesting(.stay)

        #expect(ids(store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        #expect(store.synchronousBuildCount == mainBuilds)
        #expect(store.hasPendingBuild)
        // A second stale read while the build runs does not queue another.
        _ = store.search(trips, query: "porto", allowsTrailingPartial: false, languageTag: "en")
        #expect(store.hasPendingBuild)

        await store.waitForBuildForTesting()
        #expect(!store.hasPendingBuild)
        #expect(store.generation == generation + 1)
        #expect(ids(store.search(trips, query: "porto", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        #expect(store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en")?.isEmpty == true)
        #expect(store.synchronousBuildCount == mainBuilds)
        #expect(!store.hasPendingBuild)
    }

    @Test func renameIsFoundImmediatelyThroughTheFingerprint() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        let other = makeTrip(in: context, start: day(2023, 5, 1), summary: "Rome")
        try context.save()
        let trips = [trip, other]
        let (store, _) = makeStore()

        #expect(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en")?.isEmpty == true)
        let mainBuilds = store.synchronousBuildCount

        // No save and no tracker bump: the scalar fingerprint alone notices.
        trip.customName = "Kyoto Nights"
        #expect(ids(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        #expect(store.synchronousBuildCount == mainBuilds + 1)
        #expect(!store.hasPendingBuild)

        trip.destinationSummary = "Osaka"
        #expect(ids(store.search(trips, query: "osaka", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
    }

    @Test func deletedTripsAreDropped() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let kept = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        let deleted = makeTrip(in: context, start: day(2023, 5, 1), summary: "Lisbon")
        try context.save()
        let trips = [kept, deleted]
        let (store, _) = makeStore()

        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")?.count == 2)
        context.delete(deleted)
        #expect(deleted.isDeleted)
        #expect(ids(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en"))
            == [kept.persistentModelID])
        #expect(store.indexedTrips(trips, languageTag: "en")?.trips.count == 1)
    }

    @Test func uuidTwinsAreBothIndexed() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let original = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        let twin = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        twin.id = original.id
        try context.save()
        let trips = [original, twin]
        let (store, _) = makeStore()

        let results = store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")
        #expect(ids(results) == [original.persistentModelID, twin.persistentModelID])
        #expect(store.cachedDocumentCount == 2)
        #expect(store.indexedTrips(trips, languageTag: "en")?.index.documents.map(\.tripID)
            == [original.id, original.id])
    }

    @Test func buildFinishingAfterInvalidateAllDoesNotPublish() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        try context.save()
        let trips = [trip]
        let gate = BuildGate()
        // Builds eagerly, before any revocation, then waits: only the wipe
        // revision can stop these documents from publishing.
        let (store, tracker) = makeStore { container, languageTag, calendar in
            let built = TripSearchIndexBuilder.buildDocuments(
                container: container, languageTag: languageTag, calendar: calendar)
            await gate.markStarted()
            await gate.waitForRelease()
            return built
        }

        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")?.count == 1)
        tracker.applyNowForTesting(.trip)
        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")?.count == 1)
        #expect(store.hasPendingBuild)
        await gate.waitUntilStarted()

        store.invalidateAll()
        let generation = store.generation
        #expect(store.cachedDocumentCount == 0)
        #expect(!store.hasPendingBuild)
        await gate.release()
        await store.waitForBuildForTesting()

        #expect(store.cachedDocumentCount == 0)
        #expect(store.generation == generation)
        #expect(!store.hasPendingBuild)
        // The next search starts over from the live rows.
        #expect(ids(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
    }

    @Test func memoAnswersMatchColdAndTheResolver() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lisbon = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon", locality: "Lisbon")
        let rome = makeTrip(in: context, start: day(2023, 9, 1), summary: "Rome")
        rome.countryCodes = "IT"
        try context.save()
        let trips = [lisbon, rome]
        let index = TripSearchIndex(documents: trips.map { TripSearchDocument.make(from: $0, languageTag: "en") })

        for query in ["lisbon", "lisbn", "italy", "2024", "lisbon 2024", "rome lisbon", "missing"] {
            for allowsTrailingPartial in [false, true] {
                TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
                let (store, _) = makeStore()
                let cold = try #require(store.search(
                    trips, query: query, allowsTrailingPartial: allowsTrailingPartial, languageTag: "en"))
                let warm = try #require(store.search(
                    trips, query: query, allowsTrailingPartial: allowsTrailingPartial, languageTag: "en"))
                let expected = TripQueryParser.searchTrips(
                    index: index, query: query, allowsTrailingPartial: allowsTrailingPartial, languageTag: "en")
                #expect(cold.map(\.match) == expected, "\(query)")
                #expect(warm.map(\.match) == expected, "\(query)")
                #expect(cold.map(\.trip.persistentModelID) == expected.map { trips[$0.documentIndex].persistentModelID })
                #expect(warm.map(\.trip.persistentModelID) == cold.map(\.trip.persistentModelID))
            }
        }
    }

    @Test func coldCachePastTheBudgetAsksForPreparation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let count = TripSearchIndexStore.mainThreadBudget + 8
        let trips = (0..<count).map { offset in
            makeTrip(in: context, start: day(2024, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        try context.save()
        let (store, _) = makeStore()

        #expect(store.needsPreparation(trips, languageTag: "en"))
        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en") == nil)
        #expect(store.indexedTrips(trips, languageTag: "en") == nil)
        #expect(store.synchronousBuildCount == 0)
        #expect(store.hasPendingBuild)

        await store.prepare(trips, container: container, languageTag: "en")
        #expect(!store.needsPreparation(trips, languageTag: "en"))
        let results = try #require(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en"))
        #expect(results.map(\.trip.persistentModelID) == trips.map(\.persistentModelID))
        #expect(store.synchronousBuildCount == 0)
    }

    @Test func prepareBuildsRowsTheBackgroundContextCannotSee() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let count = TripSearchIndexStore.mainThreadBudget + 3
        let trips = (0..<count).map { offset in
            makeTrip(in: context, start: day(2024, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        let (store, _) = makeStore()

        #expect(store.needsPreparation(trips, languageTag: "en"))
        await store.prepare(trips, container: container, languageTag: "en")
        let results = try #require(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en"))
        #expect(results.count == count)
    }

    @Test func changedFingerprintsPastTheBudgetAskForPreparation() async throws {
        // A cold row costs about 2.3 ms on main; a bulk rename must go off-main.
        #expect(TripSearchIndexStore.mainThreadBudget <= 8)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let count = TripSearchIndexStore.mainThreadBudget + 3
        let trips = (0..<count).map { offset in
            makeTrip(in: context, start: day(2024, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        try context.save()
        let (store, _) = makeStore()
        await store.prepare(trips, container: container, languageTag: "en")
        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")?.count == count)

        // Within the budget a rename still lands on main at once.
        trips[0].customName = "Kyoto Nights"
        #expect(!store.needsPreparation(trips, languageTag: "en"))
        #expect(ids(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en"))
            == [trips[0].persistentModelID])
        #expect(store.synchronousBuildCount == 1)

        // Past it (a saved bulk retitle, before the token bump) the list
        // waits for the off-main build instead of building on main.
        let renamed = Array(trips.prefix(TripSearchIndexStore.mainThreadBudget + 1))
        for trip in renamed { trip.customName = "Osaka Days" }
        try context.save()
        #expect(store.needsPreparation(trips, languageTag: "en"))
        #expect(store.search(trips, query: "osaka", allowsTrailingPartial: false, languageTag: "en") == nil)
        #expect(store.synchronousBuildCount == 1)

        await store.prepare(trips, container: container, languageTag: "en")
        #expect(!store.needsPreparation(trips, languageTag: "en"))
        #expect(ids(store.search(trips, query: "osaka", allowsTrailingPartial: false, languageTag: "en"))
            == renamed.map(\.persistentModelID))
        #expect(store.synchronousBuildCount == 1)
    }

    @Test func prepareAwaitsTheQueuedFollowUpBuild() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let count = TripSearchIndexStore.mainThreadBudget + 3
        let first = (0..<count).map { offset in
            makeTrip(in: context, start: day(2024, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        try context.save()
        let gate = BuildGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // The first build fetches, then waits: rows saved meanwhile are
        // only seen by the follow-up it queues. Both build off-main, so the
        // follow-up is still running when the first build publishes.
        let (store, tracker) = makeStore { container, languageTag, calendar in
            let call = calls.withLock { value in
                value += 1
                return value
            }
            let built = await TripSearchIndexBuilder.build(
                container: container, languageTag: languageTag, calendar: calendar)
            if call == 1 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
            return built
        }

        let preparingFirst = Task { await store.prepare(first, container: container, languageTag: "en") }
        await gate.waitUntilStarted()

        let added = (0..<3).map { offset in
            makeTrip(in: context, start: day(2023, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        try context.save()
        tracker.applyNowForTesting(.trip)
        let all = first + added
        let preparingAll = Task { await store.prepare(all, container: container, languageTag: "en") }
        // Let the second prepare join the in-flight build before it finishes.
        await Task.yield()
        await gate.release()
        await preparingAll.value
        await preparingFirst.value

        #expect(calls.withLock { $0 } == 2)
        #expect(store.synchronousBuildCount == 0)
        #expect(!store.hasPendingBuild)
        #expect(store.search(all, query: "lisbon", allowsTrailingPartial: false, languageTag: "en")?.count == all.count)
        #expect(store.synchronousBuildCount == 0)
    }

    @Test func prepareRebuildsRowsSavedAfterTheInFlightBuildFetchedOffMain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let count = TripSearchIndexStore.mainThreadBudget + 3
        let trips = (0..<count).map { offset in
            makeTrip(in: context, start: day(2024, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Lisbon")
        }
        try context.save()
        let gate = BuildGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // The first build fetches, then waits; the follow-up builds at once.
        let (store, _) = makeStore { container, languageTag, calendar in
            let call = calls.withLock { value in
                value += 1
                return value
            }
            let built = await TripSearchIndexBuilder.build(
                container: container, languageTag: languageTag, calendar: calendar)
            if call == 1 {
                await gate.markStarted()
                await gate.waitForRelease()
            }
            return built
        }

        #expect(store.search(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en") == nil)
        await gate.waitUntilStarted()

        // A remote merge saves a bulk retitle before its tracker bump: the
        // key is unchanged, so the in-flight build queues no follow-up.
        let renamed = Array(trips.prefix(TripSearchIndexStore.mainThreadBudget + 1))
        for trip in renamed { trip.customName = "Kyoto Nights" }
        try context.save()

        // Released only once prepare has joined the in-flight build.
        Task { await gate.release() }
        await store.prepare(trips, container: container, languageTag: "en")

        #expect(calls.withLock { $0 } == 2)
        #expect(store.synchronousBuildCount == 0)
        #expect(!store.hasPendingBuild)
        #expect(ids(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en"))
            == renamed.map(\.persistentModelID))
        #expect(store.synchronousBuildCount == 0)
    }

    @Test func onlyInvalidateAllAdvancesTheWipeRevision() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon", locality: "Belem")
        let count = TripSearchIndexStore.mainThreadBudget + 3
        let trips = [trip] + (0..<count).map { offset in
            makeTrip(in: context, start: day(2023, 1, 1).addingTimeInterval(Double(offset) * 86_400), summary: "Rome")
        }
        try context.save()
        let (store, tracker) = makeStore()
        #expect(store.wipeRevision == 0)

        // An off-main build publishes.
        await store.prepare(trips, container: container, languageTag: "en")
        #expect(store.generation == 1)
        #expect(store.wipeRevision == 0)

        // A main-thread rebuild and a changing off-main publish.
        trip.customName = "Kyoto Nights"
        #expect(ids(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        let stay = try #require(trip.stays?.first)
        stay.locality = "Porto"
        try context.save()
        tracker.applyNowForTesting(.stay)
        _ = store.search(trips, query: "porto", allowsTrailingPartial: false, languageTag: "en")
        await store.waitForBuildForTesting()
        #expect(store.generation == 2)
        #expect(store.wipeRevision == 0)

        store.invalidateAll()
        #expect(store.wipeRevision == 1)
        #expect(store.generation == 3)

        // Rebuilding after the wipe publishes without advancing it again.
        await store.prepare(trips, container: container, languageTag: "en")
        #expect(store.generation == 4)
        #expect(store.wipeRevision == 1)
        store.invalidateAll()
        #expect(store.wipeRevision == 2)
    }

    @Test func prepareBuildsSmallLibrariesOffMain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trips = [
            makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon"),
            makeTrip(in: context, start: day(2023, 5, 1), summary: "Rome"),
        ]
        try context.save()
        let (store, _) = makeStore()

        #expect(!store.needsPreparation(trips, languageTag: "en"))
        await store.prepare(trips, container: container, languageTag: "en")
        #expect(store.cachedDocumentCount == 2)
        #expect(store.synchronousBuildCount == 0)
        #expect(ids(store.search(trips, query: "rome", allowsTrailingPartial: false, languageTag: "en"))
            == [trips[1].persistentModelID])
        #expect(store.synchronousBuildCount == 0)
    }

    @Test func rebuildThatChangesNothingKeepsTheGeneration() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon", locality: "Belem")
        try context.save()
        let trips = [trip]
        let (store, tracker) = makeStore()

        #expect(ids(store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        let generation = store.generation
        let indexGeneration = try #require(store.indexedTrips(trips, languageTag: "en")).index.generation

        // A token change with no search-relevant edit.
        tracker.applyNowForTesting(.trip)
        _ = store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en")
        #expect(store.hasPendingBuild)
        await store.waitForBuildForTesting()

        #expect(store.generation == generation)
        #expect(store.indexedTrips(trips, languageTag: "en")?.index.generation == indexGeneration)
        // The entries now carry the current key: no further rebuild.
        #expect(ids(store.search(trips, query: "belem", allowsTrailingPartial: false, languageTag: "en"))
            == [trip.persistentModelID])
        #expect(!store.hasPendingBuild)
        #expect(store.synchronousBuildCount == 1)
    }

    @Test func memoDayTurnsOverAtLocalMidnight() throws {
        var athens = Calendar(identifier: .gregorian)
        athens.timeZone = try #require(TimeZone(identifier: "Europe/Athens"))
        func at(_ year: Int, _ month: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
            athens.date(from: DateComponents(year: year, month: month, day: d, hour: hour, minute: minute))!
        }

        // 23:58 on 31 Dec and 00:30 on 1 Jan share a UTC day; "this year" differs.
        #expect(TripSearchIndexStore.memoDay(at(2026, 12, 31, 23, 58), calendar: athens)
            != TripSearchIndexStore.memoDay(at(2027, 1, 1, 0, 30), calendar: athens))
        // 00:30 (still the previous UTC day) and 23:30 are one local day.
        #expect(TripSearchIndexStore.memoDay(at(2027, 1, 1, 0, 30), calendar: athens)
            == TripSearchIndexStore.memoDay(at(2027, 1, 1, 23, 30), calendar: athens))
    }

    @Test func relativeDatesTurnOverAtLocalMidnightWithoutAStoreEvent() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // The production calendar: documents and the resolver both read it.
        let calendar = TripFilters.yearCalendar
        func at(_ year: Int, _ month: Int, _ d: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour, minute: minute))!
        }
        let lisbon = makeTrip(in: context, start: at(2026, 6, 10, 12, 0), summary: "Lisbon")
        let kyoto = makeTrip(in: context, start: at(2027, 3, 10, 12, 0), summary: "Kyoto")
        try context.save()
        let trips = [lisbon, kyoto]
        let (store, _) = makeStore()

        let lastEvening = try #require(store.search(
            trips, query: "this year", allowsTrailingPartial: false, languageTag: "en", now: at(2026, 12, 31, 23, 58)))
        #expect(ids(lastEvening) == [lisbon.persistentModelID])
        let builds = store.synchronousBuildCount

        // Same trips, same index, no token change: only the clock moved.
        let newYear = try #require(store.search(
            trips, query: "this year", allowsTrailingPartial: false, languageTag: "en", now: at(2027, 1, 1, 0, 30)))
        #expect(ids(newYear) == [kyoto.persistentModelID])
        let laterThatDay = try #require(store.search(
            trips, query: "this year", allowsTrailingPartial: false, languageTag: "en", now: at(2027, 1, 1, 23, 30)))
        #expect(ids(laterThatDay) == [kyoto.persistentModelID])
        #expect(store.synchronousBuildCount == builds)
    }

    @Test func searchResultReturnsTheIndexItSearched() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lisbon = makeTrip(in: context, start: day(2024, 5, 1), summary: "Lisbon")
        let rome = makeTrip(in: context, start: day(2023, 5, 1), summary: "Rome")
        try context.save()
        let trips = [lisbon, rome]
        let (store, _) = makeStore()

        let empty = try #require(store.searchResult(trips, query: "  ", allowsTrailingPartial: false, languageTag: "en"))
        #expect(empty.matches.isEmpty)
        #expect(empty.index.documents.isEmpty)
        #expect(store.synchronousBuildCount == 0)

        let first = try #require(store.searchResult(trips, query: "lisbon", allowsTrailingPartial: false, languageTag: "en"))
        #expect(first.matches.map(\.trip.persistentModelID) == [lisbon.persistentModelID])
        #expect(first.index.generation == store.indexedTrips(trips, languageTag: "en")?.index.generation)
        #expect(first.index.documents.count == 2)

        // A rename rebuilds the index during the call; the result carries the new one.
        rome.customName = "Kyoto Nights"
        let second = try #require(store.searchResult(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en"))
        #expect(second.matches.map(\.trip.persistentModelID) == [rome.persistentModelID])
        #expect(second.index.generation != first.index.generation)
        #expect(second.index.generation == store.indexedTrips(trips, languageTag: "en")?.index.generation)
        #expect(second.index.containsWord("kyoto"))
        #expect(store.search(trips, query: "kyoto", allowsTrailingPartial: false, languageTag: "en")
            .map { $0.map(\.trip.persistentModelID) } == [rome.persistentModelID])

        let emptyAfter = try #require(store.searchResult(trips, query: "", allowsTrailingPartial: false, languageTag: "en"))
        #expect(emptyAfter.index.generation == second.index.generation)
    }
}
