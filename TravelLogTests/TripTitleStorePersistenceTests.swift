//
//  TripTitleStorePersistenceTests.swift
//  TravelLogTests
//
//  Persistence-policy coverage for localized trip-title variants. These tests
//  pin the rules that must converge identically after out-of-order CloudKit
//  delivery: canonical language tags, source isolation, generation priority,
//  timestamp priority, and the immutable-UUID final tiebreak.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Localized trip-title persistence", .serialized)
struct TripTitleStorePersistenceTests {

    @Test("same-ID content ties resolve by normalized title, independent of input order")
    func valueComparatorHasFinalContentTiebreak() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let winner = TripTitleStore.ContentValue(
            id: id, title: "Alpha", generationVersion: 2, updatedAt: date)
        let loser = TripTitleStore.ContentValue(
            id: id, title: "Zulu", generationVersion: 2, updatedAt: date)

        #expect(TripTitleStore.hasPreferredContent(winner, over: loser))
        #expect(!TripTitleStore.hasPreferredContent(loser, over: winner))
    }

    private func makeTrip(
        in context: ModelContext,
        canonicalTitle: String = "Cycladic Summer"
    ) throws -> Trip {
        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 807_862_400))
        trip.aiGeneratedTitle = canonicalTitle
        context.insert(trip)
        try context.save()
        return trip
    }

    private func variants(in context: ModelContext) throws -> [TripTitleVariant] {
        try context.fetch(FetchDescriptor<TripTitleVariant>())
    }

    @Test("upsert and lookup normalize supported regional language tags")
    func canonicalTagNormalization() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let legacy = TripTitleVariant(
            languageTag: "PT_br",
            title: "Verão antigo",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: Date(timeIntervalSinceReferenceDate: 800),
            trip: trip)
        context.insert(legacy)
        try context.save()
        let writtenAt = Date(timeIntervalSinceReferenceDate: 900)

        #expect(TripTitleStore.preferredVariant(
            for: trip, languageTag: "pt-BR")?.id == legacy.id)

        #expect(TripTitleStore.upsertVariant(
            languageTag: "PT_br",
            title: "Verão nas Cíclades",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion + 1,
            updatedAt: writtenAt,
            for: trip,
            in: context))
        try context.save()

        let all = try variants(in: context)
        #expect(all.count == 1)
        let row = try #require(all.first)
        #expect(row.id == legacy.id)
        #expect(row.languageTag == "pt-BR")
        #expect(TripTitleStore.preferredVariant(
            for: trip, languageTag: "pt_br", minimumGenerationVersion: TripTitleStore.currentGenerationVersion + 1)?.id == row.id)
        #expect(TripTitleStore.localizedTitle(
            for: trip, languageTag: "pt-BR", minimumGenerationVersion: TripTitleStore.currentGenerationVersion + 1)
            == "Verão nas Cíclades")
    }

    @Test("dedup folds canonical-equivalent tags and persists the canonical tag")
    func dedupCanonicalizesEquivalentTags() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000)
        let expected = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            languageTag: "DE_de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: timestamp,
            trip: trip)
        let duplicate = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            languageTag: "de",
            title: "Sommer auf den Kykladen",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: timestamp,
            trip: trip)
        context.insert(duplicate)
        context.insert(expected)
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try variants(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == expected.id)
        #expect(remaining.first?.languageTag == "de")
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "de-DE")
                == "Kykladischer Sommer")
    }

    @Test("dedup retains source-mismatched rows while cleaning current-source duplicates")
    func staleSourceRetention() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let stale = TripTitleVariant(
            languageTag: "fr",
            title: "Ancien été",
            sourceTitle: "Old Canonical Title",
            generationVersion: 99,
            updatedAt: .now,
            trip: trip)
        let currentA = TripTitleVariant(
            languageTag: "fr",
            title: "Été A",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            trip: trip)
        let currentB = TripTitleVariant(
            languageTag: "fr",
            title: "Été B",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            trip: trip)
        for row in [stale, currentA, currentB] { context.insert(row) }
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try variants(in: context)
        let survivorID = [currentA.id, currentB.id]
            .min(by: { $0.uuidString < $1.uuidString })
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.id == stale.id })
        #expect(remaining.contains { $0.id == survivorID })
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "fr") == "Été B")
    }

    @Test("a delayed old revision cannot resurrect when canonical text is reused")
    func staleSameTextRevisionNeverResurrects() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)

        #expect(TripTitleStore.upsertVariant(
            languageTag: "de",
            title: "Alter kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            for: trip,
            in: context))
        try context.save()
        let oldRevision = try #require(trip.titleSourceRevision)
        let oldRow = try #require(try variants(in: context).first)
        let oldRowID = oldRow.id

        // The trip changes, then the canonical generator happens to choose the
        // exact same English words for the new semantic incarnation.
        TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
        try context.save()
        #expect(TripTitleStore.replaceCanonicalTitle(
            "Cycladic Summer", for: trip, in: context))
        try context.save()
        let currentRevision = try #require(trip.titleSourceRevision)
        #expect(currentRevision != oldRevision)

        // CloudKit now delivers the pre-invalidation derivative out of order.
        context.insert(TripTitleVariant(
            id: oldRowID,
            languageTag: "de",
            title: "Alter kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: oldRevision,
            trip: trip))
        try context.save()

        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "de") == nil)
        #expect(trip.displayName(languageTag: "de") == "Cycladic Summer")

        #expect(TripTitleStore.upsertVariant(
            languageTag: "de",
            title: "Neuer kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            for: trip,
            in: context))
        try context.save()
        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try variants(in: context)
        #expect(remaining.count == 2, "stale CloudKit rows stay retained but invisible")
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "de")
                == "Neuer kykladischer Sommer")
        #expect(remaining.contains { $0.sourceRevision == oldRevision })
        #expect(remaining.contains { $0.sourceRevision == currentRevision })
    }

    @Test("an older generation cannot downgrade a newer stored variant")
    func higherGenerationIsNotDowngraded() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let sourceRevision = UUID()
        trip.titleSourceRevision = sourceRevision
        let originalDate = Date(timeIntervalSinceReferenceDate: 100)
        let row = TripTitleVariant(
            languageTag: "it",
            title: "Estate nelle Cicladi",
            sourceTitle: "Cycladic Summer",
            sourceRevision: sourceRevision,
            generationVersion: 4,
            updatedAt: originalDate,
            trip: trip)
        context.insert(row)
        try context.save()

        #expect(!TripTitleStore.upsertVariant(
            languageTag: "it-IT",
            title: "Titolo regressivo",
            sourceTitle: "Cycladic Summer",
            generationVersion: 3,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            for: trip,
            in: context))

        #expect(row.title == "Estate nelle Cicladi")
        #expect(row.generationVersion == 4)
        #expect(row.updatedAt == originalDate)
        #expect(try variants(in: context).count == 1)
    }

    @Test("within one generation only a newer timestamp replaces content")
    func sameGenerationUsesNewerTimestamp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let oldDate = Date(timeIntervalSinceReferenceDate: 100)
        let newDate = Date(timeIntervalSinceReferenceDate: 200)
        let row = TripTitleVariant(
            languageTag: "nl",
            title: "Oude titel",
            sourceTitle: "Cycladic Summer",
            generationVersion: 2,
            updatedAt: oldDate,
            trip: trip)
        context.insert(row)
        try context.save()

        #expect(TripTitleStore.upsertVariant(
            languageTag: "nl-NL",
            title: "Cycladische zomer",
            sourceTitle: "Cycladic Summer",
            generationVersion: 2,
            updatedAt: newDate,
            for: trip,
            in: context))
        #expect(row.title == "Cycladische zomer")
        #expect(row.updatedAt == newDate)

        #expect(!TripTitleStore.upsertVariant(
            languageTag: "nl",
            title: "Te laat bezorgd, maar ouder",
            sourceTitle: "Cycladic Summer",
            generationVersion: 2,
            updatedAt: oldDate,
            for: trip,
            in: context))
        #expect(row.title == "Cycladische zomer")
        #expect(row.updatedAt == newDate)
    }

    @Test("a malformed higher-generation row cannot block a usable translation")
    func malformedFutureRowCannotWin() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let malformed = TripTitleVariant(
            languageTag: "fr",
            title: "   ",
            sourceTitle: "Cycladic Summer",
            generationVersion: 99,
            updatedAt: .now,
            trip: trip)
        context.insert(malformed)
        try context.save()

        #expect(TripTitleStore.upsertVariant(
            languageTag: "fr",
            title: "Été cycladique",
            sourceTitle: "Cycladic Summer",
            generationVersion: TripTitleStore.currentGenerationVersion,
            for: trip,
            in: context))
        try context.save()

        let rows = try variants(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Été cycladique")
        #expect(trip.displayName(languageTag: "fr") == "Été cycladique")
    }

    @Test("dedup keeps immutable survivor identity and absorbs newest content")
    func deterministicDuplicateCleanup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let new = Date(timeIntervalSinceReferenceDate: 200)
        let rows = [
            TripTitleVariant(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                languageTag: "el", title: "Μεγάλο UUID",
                sourceTitle: "Cycladic Summer", generationVersion: 2,
                updatedAt: new, trip: trip),
            TripTitleVariant(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                languageTag: "el", title: "Χαμηλή γενιά",
                sourceTitle: "Cycladic Summer", generationVersion: 1,
                updatedAt: new, trip: trip),
            TripTitleVariant(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                languageTag: "el", title: "Παλιότερη εγγραφή",
                sourceTitle: "Cycladic Summer", generationVersion: 2,
                updatedAt: old, trip: trip),
            TripTitleVariant(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                languageTag: "el", title: "Νικητής",
                sourceTitle: "Cycladic Summer", generationVersion: 2,
                updatedAt: new, trip: trip),
        ]
        for row in rows { context.insert(row) }
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)
        var remaining = try variants(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == rows[1].id)
        #expect(remaining.first?.title == "Νικητής")

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)
        remaining = try variants(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == rows[1].id)
    }

    /// An incomplete list ("Αθήνα και") has no display authority. Dedup used
    /// to rank it like any other row, copy it onto the survivor, and delete
    /// the valid distinct-UUID translation.
    @Test("dedup takes content only from usable rows, whatever wins on metadata or order",
          arguments: [(true, false), (false, true), (true, true), (false, false)])
    func malformedRowCannotWinDedupContent(
        malformedHasHigherGeneration: Bool, insertMalformedFirst: Bool
    ) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let survivorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let validID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let malformed = TripTitleVariant(
            id: survivorID, languageTag: "el", title: "Αθήνα και",
            sourceTitle: "Cycladic Summer",
            generationVersion: malformedHasHigherGeneration ? TripTitleStore.currentGenerationVersion + 1 : TripTitleStore.currentGenerationVersion,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200), trip: trip)
        let valid = TripTitleVariant(
            id: validID, languageTag: "el", title: "Αθήνα και Κρήτη",
            sourceTitle: "Cycladic Summer", generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip)
        for row in insertMalformedFirst ? [malformed, valid] : [valid, malformed] {
            context.insert(row)
        }
        try context.save()

        #expect(await TripTitleVariantDeduplicator.deduplicateAll(
            modelContainer: container))

        let remaining = try ModelContext(container).fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(remaining.count == 1)
        let row = try #require(remaining.first)
        #expect(row.id == survivorID, "survivor identity is immutable")
        #expect(row.title == "Αθήνα και Κρήτη")
        #expect(row.generationVersion == TripTitleStore.currentGenerationVersion)
        let fresh = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(fresh.displayName(languageTag: "el") == "Αθήνα και Κρήτη")
    }

    @Test("dedup leaves a group with no usable row untouched")
    func allMalformedGroupIsLeftUntouched() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let first = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            languageTag: "fr", title: "Paris &",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip)
        let second = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            languageTag: "fr", title: "et Alès",
            sourceTitle: "Cycladic Summer", generationVersion: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200), trip: trip)
        context.insert(first)
        context.insert(second)
        try context.save()

        #expect(await TripTitleVariantDeduplicator.deduplicateAll(
            modelContainer: container))

        let remaining = try ModelContext(container).fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(remaining.count == 2)
        #expect(remaining.first { $0.id == first.id }?.title == "Paris &")
        #expect(remaining.first { $0.id == second.id }?.title == "et Alès")
    }

    @Test("dedup copies usable content onto every malformed survivor twin")
    func malformedSurvivorTwinsAbsorbUsableContent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for title in ["Αθήνα και", "και Κρήτη"] {
            context.insert(TripTitleVariant(
                id: sharedID, languageTag: "el", title: title,
                sourceTitle: "Cycladic Summer", generationVersion: 3,
                updatedAt: Date(timeIntervalSinceReferenceDate: 300), trip: trip))
        }
        context.insert(TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            languageTag: "el", title: "Αθήνα και Κρήτη",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip))
        try context.save()

        #expect(await TripTitleVariantDeduplicator.deduplicateAll(
            modelContainer: container))

        let remaining = try ModelContext(container).fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.id == sharedID })
        #expect(remaining.allSatisfy { $0.title == "Αθήνα και Κρήτη" })
    }

    @Test("dedup converges every trip across one-trip gate batches")
    func dedupConvergesAcrossBoundedBatches() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for index in 0..<3 {
            let trip = Trip(startDate: Date(
                timeIntervalSinceReferenceDate: Double(index)))
            trip.aiGeneratedTitle = "Trip \(index)"
            context.insert(trip)
            context.insert(TripTitleVariant(
                id: UUID(), languageTag: "de-DE", title: "Alt \(index)",
                sourceTitle: "Trip \(index)", generationVersion: 1, trip: trip))
            context.insert(TripTitleVariant(
                id: UUID(), languageTag: "de", title: "Neu \(index)",
                sourceTitle: "Trip \(index)", generationVersion: 2,
                trip: trip))
        }
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(
            modelContainer: container,
            gate: PipelineGate(forTesting: ()),
            batchSize: 1)

        let remaining = try variants(in: context)
        #expect(remaining.count == 3)
        #expect(remaining.allSatisfy { $0.languageTag == "de" })
        #expect(remaining.allSatisfy { $0.generationVersion == 2 })
    }

    @Test("dedup retains indistinguishable same-ID twins")
    func identicalIDTwinsAreRetained() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let old = TripTitleVariant(
            id: sharedID,
            languageTag: "fr",
            title: "Ancien titre",
            sourceTitle: "Cycladic Summer",
            generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            trip: trip)
        let new = TripTitleVariant(
            id: sharedID,
            languageTag: "fr",
            title: "Été cycladique",
            sourceTitle: "Cycladic Summer",
            generationVersion: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            trip: trip)
        context.insert(old)
        context.insert(new)
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try variants(in: context)
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.id == sharedID })
        #expect(remaining.allSatisfy { $0.title == "Été cycladique" })
        #expect(remaining.allSatisfy { $0.generationVersion == 2 })

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)
        #expect(try variants(in: context).count == 2)
    }

    @Test("dedup never merges variants across physical trips sharing an app UUID")
    func physicalTripTwinsRemainIndependent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let sharedTripID = UUID()
        let sharedRevision = UUID()
        let firstTrip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 100))
        let secondTrip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 200))
        for trip in [firstTrip, secondTrip] {
            trip.id = sharedTripID
            trip.aiGeneratedTitle = "Cycladic Summer"
            trip.titleSourceRevision = sharedRevision
            context.insert(trip)
        }
        let firstVariant = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer A",
            sourceTitle: "Cycladic Summer",
            sourceRevision: sharedRevision,
            trip: firstTrip)
        let secondVariant = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer B",
            sourceTitle: "Cycladic Summer",
            sourceRevision: sharedRevision,
            trip: secondTrip)
        context.insert(firstVariant)
        context.insert(secondVariant)
        try context.save()

        await TripTitleVariantDeduplicator.deduplicateAll(modelContainer: container)

        let remaining = try variants(in: context)
        #expect(remaining.count == 2)
        #expect((firstTrip.localizedTitles ?? []).map(\.id) == [firstVariant.id])
        #expect((secondTrip.localizedTitles ?? []).map(\.id) == [secondVariant.id])
        #expect(firstTrip.displayName(languageTag: "de") == "Kykladischer Sommer A")
        #expect(secondTrip.displayName(languageTag: "de") == "Kykladischer Sommer B")
    }

    @Test("upsert keeps immutable survivor while absorbing preferred content")
    func upsertUsesImmutableSurvivor() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let survivorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let old = TripTitleVariant(
            id: survivorID, languageTag: "de", title: "Alter Titel",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip)
        let newest = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            languageTag: "de", title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer", generationVersion: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200), trip: trip)
        context.insert(old)
        context.insert(newest)
        try context.save()

        #expect(TripTitleStore.upsertVariant(
            languageTag: "de",
            title: "Zu spät geliefert",
            sourceTitle: "Cycladic Summer",
            generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 50),
            for: trip,
            in: context))
        try context.save()

        let remaining = try variants(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == survivorID)
        #expect(remaining.first?.title == "Kykladischer Sommer")
        #expect(remaining.first?.generationVersion == 2)
    }

    @Test("upsert retains same-ID twins and synchronizes their content")
    func upsertRetainsSameIDTwins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = TripTitleVariant(
            id: sharedID, languageTag: "it", title: "Vecchio",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip)
        let second = TripTitleVariant(
            id: sharedID, languageTag: "it", title: "Ancora vecchio",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), trip: trip)
        context.insert(first)
        context.insert(second)
        try context.save()

        #expect(TripTitleStore.upsertVariant(
            languageTag: "it",
            title: "Estate nelle Cicladi",
            sourceTitle: "Cycladic Summer",
            generationVersion: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            for: trip,
            in: context))
        try context.save()

        let remaining = try variants(in: context)
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.id == sharedID })
        #expect(remaining.allSatisfy { $0.title == "Estate nelle Cicladi" })
        #expect(remaining.allSatisfy { $0.generationVersion == 2 })
    }

    @Test("active-home fingerprint seeds safely, then invalidates only a proven change")
    func activeHomeFingerprintReconciliation() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            trip: trip))
        let home = Home(
            label: "Home",
            latitude: 37.9838,
            longitude: 23.7275,
            radiusKm: 3)
        home.locality = "Athens"
        home.country = "Greece"
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()

        let suite = "TripTitleStorePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-baseline", forKey: "activeHomeTitleFingerprint_v1")

        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")
        #expect((trip.localizedTitles ?? []).count == 1)
        #expect(defaults.string(forKey: TripTitleStore.activeHomeTitleFingerprintKey)
                == TripTitleStore.activeHomeTitleFingerprint(
                    for: try TripTitleStore.fetchActiveHomeTitleInputs(in: context)))

        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")

        home.label = "Renamed Home"
        try context.save()
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")
        #expect((trip.localizedTitles ?? []).count == 1)

        home.locality = "Ioánnina"
        try context.save()
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 1)
        #expect(trip.aiGeneratedTitle == nil)
        #expect((trip.localizedTitles ?? []).isEmpty)
    }

    @Test("active-home fingerprint ignores physical ids and same-content twins")
    func activeHomeFingerprintIgnoresSameContentTwins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            trip: trip))
        let home = Home(
            label: "Home",
            latitude: 37.9838,
            longitude: 23.7275,
            radiusKm: 3)
        home.locality = "Athens"
        home.country = "Greece"
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()

        let suite = "TripTitleStorePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-baseline", forKey: "activeHomeTitleFingerprint_v2")

        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")

        // A twin about 4.4 km away is never collapsed by the deduplicator.
        let twin = Home(
            label: "Second Device",
            latitude: 37.9731,
            longitude: 23.6797,
            radiusKm: 3)
        twin.locality = "Athens"
        twin.country = "Greece"
        twin.isoCountryCode = "GR"
        context.insert(twin)
        try context.save()
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")
        #expect((trip.localizedTitles ?? []).count == 1)

        home.endedAt = Date(timeIntervalSinceReferenceDate: 7_867_400)
        try context.save()
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 0)
        #expect(trip.aiGeneratedTitle == "Cycladic Summer")
        #expect((trip.localizedTitles ?? []).count == 1)

        twin.locality = "Ioánnina"
        try context.save()
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(
            in: context,
            defaults: defaults) == 1)
        #expect(trip.aiGeneratedTitle == nil)
        #expect((trip.localizedTitles ?? []).isEmpty)
    }
}
