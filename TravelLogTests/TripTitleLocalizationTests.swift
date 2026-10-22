//
//  TripTitleLocalizationTests.swift
//  TravelLogTests
//

import CryptoKit
import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import TravelLog

private actor LocalizedTitleTestProbe {
    private var calls: [UUID: Int] = [:]
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func recordCall(for tripID: UUID) {
        calls[tripID, default: 0] += 1
    }

    func callCount(for tripID: UUID) -> Int {
        calls[tripID, default: 0]
    }

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor LocalizedTitleVerificationProbe {
    private(set) var translationPrompts: [String] = []
    private(set) var checkerPrompts: [String] = []
    func translation(_ prompt: String) { translationPrompts.append(prompt) }
    func checker(_ prompt: String) { checkerPrompts.append(prompt) }
}

private actor LocalizedTitleOrderProbe {
    private(set) var order: [UUID] = []
    func record(_ tripID: UUID) { order.append(tripID) }
}

@MainActor
@Suite("Localized trip titles", .serialized, IsolatedTitleDefaults())
struct TripTitleLocalizationTests {

    @Test("Malformed incoming title cannot replace a valid variant with newer metadata")
    func malformedIncomingListPreservesValidVariant() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        trip.aiGeneratedTitle = "Athens"
        #expect(TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα", sourceTitle: "Athens",
                                           for: trip, in: context))
        try context.save()
        let original = try #require(TripTitleStore.preferredVariant(for: trip, languageTag: "el"))
        let identity = original.persistentModelID
        #expect(!TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα &", sourceTitle: "Athens",
                                            generationVersion: 99, updatedAt: .distantFuture,
                                            for: trip, in: context))
        try context.save()
        let winner = try #require(TripTitleStore.preferredVariant(for: trip, languageTag: "el"))
        #expect(winner.persistentModelID == identity)
        #expect(winner.title == "Αθήνα")
    }

    @Test("Malformed saved list titles cannot block a valid repair even with future metadata")
    func malformedSavedListCanBeRepaired() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        trip.aiGeneratedTitle = "Athens"
        let source = try #require(trip.aiGeneratedTitle)
        let bad = TripTitleVariant(languageTag: "el", title: "Αθήνα και", sourceTitle: source, trip: trip)
        bad.sourceRevision = trip.titleSourceRevision
        bad.updatedAt = .distantFuture
        context.insert(bad)
        try context.save()
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "el") == nil)
        #expect(TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα", sourceTitle: source,
                                           for: trip, in: context))
        try context.save()
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "el") == "Αθήνα")
    }

    @Test("detail localization task key follows canonical source and app language")
    func detailTaskKeyInvalidation() {
        let tripID = UUID()
        let revision = UUID()
        let baseline = TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false)

        #expect(baseline == TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Aegean Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: UUID(),
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "el",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: true))
    }

    private func makeTrip(
        in context: ModelContext,
        offset: TimeInterval = 0,
        title: String = "Cycladic Summer"
    ) throws -> Trip {
        let trip = Trip(startDate: Date(
            timeIntervalSinceReferenceDate: 810_886_400 + offset))
        trip.aiGeneratedTitle = title
        trip.destinationSummary = "Athens, Cephalonia"
        context.insert(trip)
        try context.save()
        return trip
    }

    @Test("current-language variant wins, then canonical English, while custom name remains verbatim")
    func resolutionPrecedence() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let german = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            trip: trip)
        context.insert(german)
        try context.save()

        #expect(trip.displayName(languageTag: "de") == "Kykladischer Sommer")
        #expect(trip.displayName(languageTag: "fr") == "Cycladic Summer")
        #expect(trip.displayName(languageTag: "en") == "Cycladic Summer")

        trip.customName = "Our Anniversary"
        #expect(trip.displayName(languageTag: "de") == "Our Anniversary")
    }

    @Test("stale-source variants are never displayed")
    func staleSourceIsIgnored() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "fr",
            title: "Ancien titre",
            sourceTitle: "Old English Title",
            trip: trip))
        try context.save()

        #expect(trip.displayName(languageTag: "fr") == "Cycladic Summer")
    }

    @Test("duplicate winner is generation, then update time, then stable UUID")
    func deterministicWinner() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let new = Date(timeIntervalSinceReferenceDate: 200)
        let lowVersion = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            languageTag: "de", title: "Version one",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: new, trip: trip)
        let highVersionOld = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            languageTag: "de", title: "Version two old",
            sourceTitle: "Cycladic Summer", generationVersion: 2,
            updatedAt: old, trip: trip)
        let highVersionNewLargeID = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            languageTag: "de", title: "Larger ID",
            sourceTitle: "Cycladic Summer", generationVersion: 2,
            updatedAt: new, trip: trip)
        let expected = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            languageTag: "de", title: "Expected",
            sourceTitle: "Cycladic Summer", generationVersion: 2,
            updatedAt: new, trip: trip)
        for row in [lowVersion, highVersionOld, highVersionNewLargeID, expected] {
            context.insert(row)
        }
        try context.save()

        #expect(TripTitleStore.preferredVariant(for: trip, languageTag: "de")?.id == expected.id)
        #expect(trip.displayName(languageTag: "de") == "Expected")
    }

    @Test("canonical mutation deletes every derivative, including equal-text invalidation")
    func invalidationIsSemantic() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer", trip: trip))
        try context.save()

        TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
        try context.save()

        #expect(trip.aiGeneratedTitle == nil)
        #expect(try context.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("upsert requires current source and collapses local duplicates")
    func guardedUpsert() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let a = TripTitleVariant(
            languageTag: "fr", title: "Été A",
            sourceTitle: "Cycladic Summer", trip: trip)
        let b = TripTitleVariant(
            languageTag: "fr", title: "Été B",
            sourceTitle: "Cycladic Summer", trip: trip)
        context.insert(a)
        context.insert(b)
        try context.save()

        #expect(!TripTitleStore.upsertVariant(
            languageTag: "de", title: "Falsch", sourceTitle: "Wrong Source",
            for: trip, in: context))
        #expect(TripTitleStore.upsertVariant(
            languageTag: "fr", title: "Été cycladique",
            sourceTitle: "Cycladic Summer", for: trip, in: context))
        try context.save()

        let french = try context.fetch(FetchDescriptor<TripTitleVariant>()).filter {
            $0.languageTag == "fr" && $0.sourceTitle == "Cycladic Summer"
        }
        #expect(french.count == 1)
        #expect(french.first?.title == "Été cycladique")
    }

    @Test("explicit fallback language selects that catalog's connector")
    func explicitFallbackLocalization() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        trip.destinationSummary = "Athens, Cephalonia"
        context.insert(trip)
        try context.save()

        #expect(trip.displayName(languageTag: "en") == "Athens & Cephalonia")
        #expect(trip.displayName(languageTag: "el") == "Athens και Cephalonia")
    }

    @Test("localized output normalization and structural validation are language-neutral")
    func outputValidation() {
        #expect(TripTitleLocalizationService.normalize("  “Kykladischer Sommer.”  ") == "Kykladischer Sommer")
        #expect(TripTitleLocalizationService.normalize("’s-Hertogenbosch") == "’s-Hertogenbosch")
        #expect(TripTitleLocalizationService.isValid("東京と京都"))
        #expect(!TripTitleLocalizationService.isValid("A"))
        #expect(!TripTitleLocalizationService.isValid("Line one\nLine two"))
        #expect(!TripTitleLocalizationService.isValid("<b>Berlin</b>"))
        #expect(!TripTitleLocalizationService.isValid(String(repeating: "旅", count: 61)))

        #expect(TripTitleLocalizationService.isValidLocalizedOutput(
            title: "Kykladischer Sommer",
            outputLanguageTag: "de-DE",
            preservesMeaning: true,
            preservesDestinationsAndProperNouns: true,
            targetLanguageTag: "de"))
        #expect(!TripTitleLocalizationService.isValidLocalizedOutput(
            title: "Cycladic Summer",
            outputLanguageTag: "en",
            preservesMeaning: true,
            preservesDestinationsAndProperNouns: true,
            targetLanguageTag: "de"))
        #expect(!TripTitleLocalizationService.isValidLocalizedOutput(
            title: "Berlin & Hamburg",
            outputLanguageTag: "de",
            preservesMeaning: true,
            preservesDestinationsAndProperNouns: false,
            targetLanguageTag: "de"))
    }

    @Test("explicit retry clears a persisted failure before availability is evaluated")
    func forceRetryClearsFailureLatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let service = TripTitleLocalizationService(modelContainer: container)

        await service.setPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "el",
            sourceTitle: "Cycladic Summer")
        #expect(await service.hasPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "el",
            sourceTitle: "Cycladic Summer"))

        _ = await service.localizedTitle(
            for: trip.id,
            languageTag: "el",
            force: true,
            gate: PipelineGate(forTesting: ()))

        #expect(!(await service.hasPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "el",
            sourceTitle: "Cycladic Summer")))
        await service.clearAllFailureState()
    }

    @Test("a cancelled localized apply cannot persist a variant")
    func cancelledLocalizedApplyIsInert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let service = TripTitleLocalizationService(modelContainer: container)

        let result = await Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.applyLocalizedTitleForTesting(
                "Kykladischer Sommer",
                tripID: trip.id,
                languageTag: "de")
        }.value

        #expect(result == nil)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("localized apply targets the physical trip when app UUIDs collide")
    func localizedApplyTargetsPhysicalTrip() async throws {
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
        try context.save()
        let secondIdentifier = secondTrip.persistentModelID
        let service = TripTitleLocalizationService(modelContainer: container)

        let result = await service.applyLocalizedTitleForTesting(
            "Kykladischer Sommer",
            tripID: sharedTripID,
            tripIdentifier: secondIdentifier,
            languageTag: "de")

        #expect(result == "Kykladischer Sommer")
        let verification = ModelContext(container)
        let rows = try verification.fetch(FetchDescriptor<TripTitleVariant>())
        #expect(rows.count == 1)
        #expect(rows.first?.trip?.persistentModelID == secondIdentifier)
        let reloadedTrips = try verification.fetch(FetchDescriptor<Trip>())
        let reloadedFirst = try #require(reloadedTrips.first {
            $0.persistentModelID == firstTrip.persistentModelID
        })
        let reloadedSecond = try #require(reloadedTrips.first {
            $0.persistentModelID == secondIdentifier
        })
        #expect((reloadedFirst.localizedTitles ?? []).isEmpty)
        #expect(reloadedSecond.displayName(languageTag: "de") == "Kykladischer Sommer")
    }

    @Test("localized failure latch is scoped to the current semantic input")
    func localizedFailureKeyTracksSemanticInput() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let start = trip.startDate
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(3 * 60 * 60),
            centroidLatitude: 37.9838,
            centroidLongitude: 23.7275,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 4,
            pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        try context.save()

        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "de",
            sourceTitle: "Cycladic Summer")
        #expect(await service.hasPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "de",
            sourceTitle: "Cycladic Summer"))

        stay.locality = "Lixoúri"
        try context.save()

        // A fresh actor proves this is a persisted-key property, not merely an
        // in-memory cache reset.
        let afterMutation = TripTitleLocalizationService(modelContainer: container)
        #expect(!(await afterMutation.hasPersistentFailureForTesting(
            tripID: trip.id,
            languageTag: "de",
            sourceTitle: "Cycladic Summer")))
        await afterMutation.clearAllFailureState()
    }

    @Test("a capped localization stage spends at most its invocation budget and resumes",
          .timeLimit(.minutes(1)))
    func cappedStageResumesAcrossInvocations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var tripIDs: [UUID] = []
        for index in 0..<5 {
            let trip = try makeTrip(
                in: context,
                offset: TimeInterval(index),
                title: "Canonical \(index)")
            tripIDs.append(trip.id)
        }
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            return "Lokalisierter Titel"
        }

        for invocation in 1...3 {
            let summary = await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 2,
                languageTag: "de",
                gate: PipelineGate(forTesting: ()))

            let totalWritten = min(invocation * 2, 5)
            #expect(summary.written == (invocation == 3 ? 1 : 2))
            #expect(summary.alreadyPresent == (invocation - 1) * 2)
            #expect(summary.failed == 0)
            #expect(!summary.skippedUnsupported)
            #expect(!summary.cancelled)
            #expect(summary.completed == (invocation == 3))
            for (index, tripID) in tripIDs.enumerated() {
                #expect(await probe.callCount(for: tripID) == (index >= 5 - totalWritten ? 1 : 0))
            }
            #expect(try ModelContext(container).fetchCount(
                FetchDescriptor<TripTitleVariant>()) == totalWritten)
        }
    }

    @Test("an unbounded localization stage drains all eligible titles")
    func unboundedStageDrainsEntireLibrary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var tripIDs: [UUID] = []
        for index in 0..<5 {
            let trip = try makeTrip(in: context, offset: Double(index), title: "Canonical \(index)")
            tripIDs.append(trip.id)
        }
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            return "Lokalisierter Titel"
        }

        let summary = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: nil, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(summary.written == 5)
        #expect(summary.completed)
        for tripID in tripIDs {
            #expect(await probe.callCount(for: tripID) == 1)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 5)
    }

    @Test("variants saved during a fetched unit do not consume its remaining budget")
    func alreadyPresentOutcomeDoesNotConsumeBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let oldest = try makeTrip(in: context, offset: 0)
        let middle = try makeTrip(in: context, offset: 1)
        let newest = try makeTrip(in: context, offset: 2)
        let newestID = newest.id
        let middleID = middle.id
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            if tripID == newestID {
                // The middle trip is already in this unit's candidate snapshot.
                // A separate writer fills it before localizeAndApply rereads it.
                await MainActor.run {
                    let writer = ModelContext(container)
                    let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.id == middleID })
                    do {
                        let trip = try #require(writer.fetch(descriptor).first)
                        #expect(TripTitleStore.upsertVariant(
                            languageTag: "de", title: "Kykladischer Sommer",
                            sourceTitle: "Cycladic Summer", for: trip, in: writer))
                        try writer.save()
                    } catch {
                        Issue.record(error)
                    }
                }
            }
            return "Kykladischer Sommer"
        }

        let summary = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 2, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(summary.written == 2)
        #expect(summary.alreadyPresent == 1)
        #expect(!summary.completed)
        #expect(await probe.callCount(for: newestID) == 1)
        #expect(await probe.callCount(for: middleID) == 0)
        #expect(await probe.callCount(for: oldest.id) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 3)
    }

    @Test("failed titles spend the invocation budget on each retry")
    func failedAttemptsConsumeBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let older = try makeTrip(in: context, offset: 0)
        let newest = try makeTrip(in: context, offset: 1)
        let newestID = newest.id
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            return tripID == newestID ? nil : "Kykladischer Sommer"
        }

        for invocation in 1...2 {
            let summary = await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
            #expect(summary.written == 0)
            #expect(summary.failed == 1)
            #expect(!summary.completed)
            #expect(await probe.callCount(for: newestID) == invocation)
            #expect(await probe.callCount(for: older.id) == 0)
        }
        let resumed = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(resumed.written == 1)
        #expect(resumed.failed == 1)
        #expect(!resumed.completed)
        #expect(await probe.callCount(for: newestID) == 2)
        #expect(await probe.callCount(for: older.id) == 1)
    }

    @Test("inconclusive titles consume budget even when no model response is needed")
    func deferredAttemptsConsumeBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeGroundedTrip(in: context, title: "Paris weekend", names: ["Paris"], offset: 1)
        _ = try makeGroundedTrip(in: context, title: "Berlin", names: ["Berlin"], offset: 0)
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Berlin", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Berlin"
        })

        let capped = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(capped.written == 0)
        #expect(capped.failed == 0)
        #expect(!capped.completed)
        #expect(await probe.translationPrompts.isEmpty)
        #expect(await probe.checkerPrompts.isEmpty)

        // A larger budget retries the deferred key once, then reaches Berlin.
        let resumed = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 3, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(resumed.written == 1)
        #expect(resumed.failed == 0)
        #expect(!resumed.completed)
        #expect(await probe.translationPrompts.count == 1)
        #expect(await probe.checkerPrompts.count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 1)
    }

    @Test("Inconclusive titles cannot starve older trips across capped drains")
    func inconclusiveTitlesDoNotStarveCappedDrains() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var inconclusive: [Trip] = []
        for (index, city) in ["Paris", "Rome", "Madrid", "Vienna", "Lisbon"].enumerated() {
            inconclusive.append(try makeGroundedTrip(
                in: context, title: "\(city) weekend", names: [city],
                offset: TimeInterval(10 + index)))
        }
        _ = try makeGroundedTrip(in: context, title: "Berlin", names: ["Berlin"], offset: 0)
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.clearAllFailureState()
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Berlin", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Berlin"
        })

        let first = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 5, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(first.written == 0)
        #expect(!first.completed)
        #expect(await probe.translationPrompts.isEmpty)

        // Known-inconclusive inputs yield the budget to fresh candidates.
        let second = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 5, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(second.written == 1)
        #expect(await probe.translationPrompts.count == 1)
        #expect(await probe.checkerPrompts.count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 1)

        let third = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 5, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(third.written == 0)
        #expect(third.alreadyPresent == 1)
        #expect(!third.completed)
        for trip in inconclusive {
            #expect(!(await service.hasPersistentFailureForTesting(
                tripID: trip.id, languageTag: "de",
                sourceTitle: trip.aiGeneratedTitle ?? "")))
        }
    }

    @Test("a discarded stale result consumes the invocation budget", .timeLimit(.minutes(1)))
    func discardedAttemptsConsumeBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let older = try makeTrip(in: context, offset: 0)
        let newest = try makeTrip(in: context, offset: 1)
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        let release = LocalizedTitleTestProbe()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            continuation.yield()
            await release.wait()
            return "Kykladischer Sommer"
        }

        let work = Task {
            await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        newest.customName = "Our holiday"
        try context.save()
        await release.release()
        let discarded = await work.value
        #expect(discarded.written == 0)
        #expect(discarded.failed == 0)
        #expect(!discarded.completed)
        #expect(await probe.callCount(for: newest.id) == 1)
        #expect(await probe.callCount(for: older.id) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)

        let resumed = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(resumed.written == 1)
        #expect(!resumed.completed)
        #expect(await probe.callCount(for: newest.id) == 1)
        #expect(await probe.callCount(for: older.id) == 1)
    }

    @Test("concurrent capped drains share in-flight work without prefix spinning",
          .timeLimit(.minutes(1)))
    func concurrentCappedDrainsDoNotDuplicateWork() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var tripIDs: [UUID] = []
        for index in 0..<3 {
            let trip = try makeTrip(
                in: context,
                offset: TimeInterval(index),
                title: "Canonical \(index)")
            tripIDs.append(trip.id)
        }
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        let release = LocalizedTitleTestProbe()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        await service.clearAllFailureState()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            startedContinuation.yield()
            await release.wait()
            return "Lokalisierter Titel"
        }

        let first = Task {
            await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 4,
                languageTag: "de",
                gate: PipelineGate(forTesting: ()))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task {
            await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 4,
                languageTag: "de",
                gate: PipelineGate(forTesting: ()))
        }
        await release.release()
        let firstSummary = await first.value
        let secondSummary = await second.value

        #expect(firstSummary.written + secondSummary.written == 3)
        #expect(firstSummary.completed)
        #expect(secondSummary.completed)
        for tripID in tripIDs {
            #expect(await probe.callCount(for: tripID) == 1)
        }
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 3)
        await service.setTranslationOverrideForTesting(nil)
        await service.clearAllFailureState()
    }

    @Test("cancellation stops a resumable localization drain",
          .timeLimit(.minutes(1)))
    func cancellationStopsDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for index in 0..<3 {
            _ = try makeTrip(
                in: context,
                offset: TimeInterval(index),
                title: "Canonical \(index)")
        }
        let service = TripTitleLocalizationService(modelContainer: container)
        let release = LocalizedTitleTestProbe()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        await service.clearAllFailureState()
        await service.setTranslationOverrideForTesting { _ in
            startedContinuation.yield()
            await release.wait()
            return "Lokalisierter Titel"
        }

        let drain = Task {
            await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 1,
                languageTag: "de",
                gate: PipelineGate(forTesting: ()))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        drain.cancel()
        await release.release()
        let summary = await drain.value

        #expect(summary.written == 0)
        #expect(summary.cancelled)
        #expect(!summary.completed)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
        await service.setTranslationOverrideForTesting(nil)
        await service.clearAllFailureState()
    }

    @Test("persistent failure becomes ineligible and does not block later units",
          .timeLimit(.minutes(1)))
    func persistentFailureDoesNotSpin() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let successfulTrip = try makeTrip(
            in: context, offset: 1, title: "Athens Evenings")
        let failingTrip = try makeTrip(
            in: context, offset: 2, title: "Cycladic Summer")
        let failingTripID = failingTrip.id
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.clearAllFailureState()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            return tripID == failingTripID ? nil : "Abende in Athen"
        }

        let summary = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 4,
            languageTag: "de",
            gate: PipelineGate(forTesting: ()))

        #expect(summary.written == 1)
        #expect(summary.failed == 1)
        #expect(summary.completed)
        #expect(await probe.callCount(for: failingTrip.id) == 2)
        #expect(await probe.callCount(for: successfulTrip.id) == 1)
        #expect(await service.hasPersistentFailureForTesting(
            tripID: failingTrip.id,
            languageTag: "de",
            sourceTitle: "Cycladic Summer"))
        await service.setTranslationOverrideForTesting(nil)
        await service.clearAllFailureState()
    }

    @Test("Variant save failures defer once per drain without exhausting quality retries",
          .timeLimit(.minutes(1)))
    func variantSaveFailuresDeferAndRecover() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let failingTrip = try makeGroundedTrip(in: context, offset: 2)
        let failingTripID = failingTrip.id
        let sourceRevision = failingTrip.titleSourceRevision
        let olderTrip = try makeGroundedTrip(
            in: context, title: "Paris", names: ["Paris"], offset: 1)
        let suiteName = "TripTitleLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        let gate = PipelineGate(forTesting: ())
        await service.setPersistenceOverridesForTesting(defaultsSuiteName: suiteName) { tripID in
            if tripID == failingTripID {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: prompt.contains("Paris") ? "Paris" : "Athen & Kreta",
                         outputLanguageTag: "de", preservesMeaning: true,
                         preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return prompt.contains("Paris") ? "Paris" : "Athens & Crete"
        })

        for drainNumber in 1...2 {
            let summary = await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 3, languageTag: "de", gate: gate)
            #expect(summary.written == (drainNumber == 1 ? 1 : 0))
            #expect(summary.failed == 0)
            #expect(!summary.completed)
            #expect(!summary.skippedUnsupported)
            let prompts = await probe.translationPrompts
            #expect(prompts.filter { $0.contains("Athens & Crete") }.count == drainNumber)
            #expect(prompts.filter { $0.contains("Paris") }.count == 1)
            #expect(await probe.checkerPrompts.count == drainNumber + 1)
            #expect(!(await service.hasPersistentFailureForTesting(
                tripID: failingTripID, languageTag: "de", sourceTitle: "Athens & Crete")))
            #expect((defaults.stringArray(forKey: "failedLocalizedTripTitleKeys_v2") ?? []).isEmpty)
            let readContext = ModelContext(container)
            let rows = try readContext.fetch(FetchDescriptor<TripTitleVariant>())
            #expect(rows.count == 1)
            #expect(rows.first?.trip?.id == olderTrip.id)
            let reloaded = try #require(readContext.fetch(FetchDescriptor<Trip>()).first {
                $0.id == failingTripID
            })
            #expect(reloaded.aiGeneratedTitle == "Athens & Crete")
            #expect(reloaded.titleSourceRevision == sourceRevision)
            #expect((reloaded.localizedTitles ?? []).isEmpty)
        }

        await service.setPersistenceOverridesForTesting(defaultsSuiteName: suiteName, beforeSave: nil)
        let recovered = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 3, languageTag: "de", gate: gate)
        #expect(recovered.written == 1)
        #expect(recovered.failed == 0)
        #expect(recovered.completed)
        #expect(!recovered.skippedUnsupported)
        let prompts = await probe.translationPrompts
        #expect(prompts.filter { $0.contains("Athens & Crete") }.count == 3)
        #expect(await probe.checkerPrompts.count == 4)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TripTitleVariant>())
        #expect(rows.count == 2)
        #expect(rows.first { $0.trip?.id == failingTripID }?.title == "Athen & Kreta")
        #expect((defaults.stringArray(forKey: "failedLocalizedTripTitleKeys_v2") ?? []).isEmpty)
    }

    @Test("generation summary distinguishes existing and unsupported outcomes")
    func generationSummaryDistinguishesOutcomes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let existingTrip = try makeTrip(
            in: context, offset: 1, title: "Cycladic Summer")
        _ = try makeTrip(
            in: context, offset: 2, title: "Athens Evenings")
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            trip: existingTrip))
        try context.save()
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.clearAllFailureState()
        await service.setTranslationOverrideForTesting { _ in "Abende in Athen" }

        let generated = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1,
            languageTag: "de",
            gate: PipelineGate(forTesting: ()))
        #expect(generated.written == 1)
        #expect(generated.alreadyPresent == 1)
        #expect(generated.failed == 0)
        #expect(!generated.completed)

        await service.setTranslationOverrideForTesting(nil)
        let unsupported = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1,
            languageTag: "xx",
            gate: PipelineGate(forTesting: ()))
        #expect(unsupported.skippedUnsupported)
        #expect(!unsupported.completed)
        await service.clearAllFailureState()
    }

    @Test("capped drains attempt missing titles newest first, past present, stale-source and other-language variants",
          .timeLimit(.minutes(1)))
    func cappedDrainAttemptOrderAndSummaries() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trips = try (0..<5).map {
            try makeTrip(in: context, offset: TimeInterval($0), title: "Canonical \($0)")
        }
        // German is present on trips 1 and 3 only: trip 2's row is for an old source, trip 4 has Greek only.
        for index in [1, 3] {
            context.insert(TripTitleVariant(
                languageTag: "de", title: "Lokalisierter Titel",
                sourceTitle: "Canonical \(index)", trip: trips[index]))
        }
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Lokalisierter Titel", sourceTitle: "Old Source", trip: trips[2]))
        context.insert(TripTitleVariant(
            languageTag: "el", title: "Τοπικός Τίτλος", sourceTitle: "Canonical 4", trip: trips[4]))
        try context.save()
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleOrderProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.record(tripID)
            return "Kykladischer Sommer"
        }

        let first = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 2, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(await probe.order == [trips[4].id, trips[2].id])
        #expect(first == TripTitleLocalizationService.GenerationSummary(
            written: 2, alreadyPresent: 2, failed: 0,
            skippedUnsupported: false, cancelled: false, completed: false))

        let second = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 2, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(await probe.order == [trips[4].id, trips[2].id, trips[0].id])
        #expect(second == TripTitleLocalizationService.GenerationSummary(
            written: 1, alreadyPresent: 4, failed: 0,
            skippedUnsupported: false, cancelled: false, completed: true))
        await service.setTranslationOverrideForTesting(nil)
    }

    @Test("detail lookup returns a usable variant without model work and still localizes stale or forced titles",
          .timeLimit(.minutes(1)))
    func detailLaneChecksExistingVariantFirst() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let present = try makeTrip(in: context, offset: 0, title: "Canonical Present")
        let stale = try makeTrip(in: context, offset: 1, title: "Canonical Stale")
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Lokalisierter Titel", sourceTitle: "Canonical Present", trip: present))
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Lokalisierter Titel", sourceTitle: "Old Source", trip: stale))
        try context.save()
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleTestProbe()
        await service.setTranslationOverrideForTesting { tripID in
            await probe.recordCall(for: tripID)
            return "Kykladischer Sommer"
        }
        let gate = PipelineGate(forTesting: ())

        #expect(await service.localizedTitle(for: present.id, languageTag: "de", gate: gate) == "Lokalisierter Titel")
        #expect(await probe.callCount(for: present.id) == 0)
        #expect(await service.localizedTitle(for: stale.id, languageTag: "de", gate: gate) == "Kykladischer Sommer")
        #expect(await probe.callCount(for: stale.id) == 1)
        #expect(await service.localizedTitle(
            for: present.id, languageTag: "de", force: true, gate: gate) == "Kykladischer Sommer")
        #expect(await probe.callCount(for: present.id) == 1)
        await service.setTranslationOverrideForTesting(nil)
        await service.clearAllFailureState()
    }

    private func makeGroundedTrip(
        in context: ModelContext, title: String = "Athens & Crete",
        names: [String] = ["Athens", "Crete"], offset: TimeInterval = 0
    ) throws -> Trip {
        let trip = try makeTrip(in: context, offset: offset, title: title)
        for (index, name) in names.enumerated() {
            let start = trip.startDate.addingTimeInterval(Double(index) * 86_400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3_600),
                            centroidLatitude: 38, centroidLongitude: 24,
                            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
                            distanceFromHomeKm: 100, pingIDs: [])
            stay.locality = name
            stay.category = .destination
            stay.orderInTrip = index
            context.insert(stay)
            stay.trip = trip
        }
        try context.save()
        return trip
    }

    @Test("Injected full-title backtranslations accept conventional exonyms across scripts")
    func verifiedExonymsAcrossScripts() async throws {
        // These exercise the production pipeline, not real model language quality.
        let cases = [("de", "Athen & Kreta"), ("el", "Αθήνα & Κρήτη"),
                     ("ja", "アテネとクレタ"), ("ko", "아테네와 크레타"),
                     ("zh-Hans", "雅典与克里特"), ("vi", "A-ten và Crê-ta")]
        for (tag, title) in cases {
            let container = try TestSupport.makeInMemoryContainer()
            let trip = try makeGroundedTrip(in: ModelContext(container))
            let service = TripTitleLocalizationService(modelContainer: container)
            let probe = LocalizedTitleVerificationProbe()
            await service.setVerificationOverridesForTesting(translator: { prompt, _ in
                await probe.translation(prompt)
                return .init(title: title, outputLanguageTag: tag,
                             preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { prompt in
                await probe.checker(prompt)
                return "Athens & Crete"
            })
            let result = await service.localizedTitle(for: trip.id, languageTag: tag,
                                                       gate: PipelineGate(forTesting: ()))
            #expect(result == title)
            let checkerPrompts = await probe.checkerPrompts
            #expect(checkerPrompts.count == 1)
            #expect(checkerPrompts.first?.contains("<LOCALIZED_TITLE>\(title)</LOCALIZED_TITLE>") == true)
            #expect(checkerPrompts.first?.contains("Athens & Crete") == false)
            #expect(checkerPrompts.first?.contains("SOURCE_TITLE") == false)
            let rows = try ModelContext(container).fetch(FetchDescriptor<TripTitleVariant>())
            #expect(rows.count == 1)
            #expect(rows.first?.generationVersion == 1)
        }
    }

    @Test("Raw-script island snapshots localize the actual canonical candidate spellings")
    func rawScriptSnapshotLocalizesCanonicalTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeGroundedTrip(in: context, title: "Syros & Kephalonia", names: ["Σύρος", "Κεφαλονιά"])
        for stay in trip.orderedStays {
            // Imported populated island layers need not be geocoded again.
            stay.islandName = stay.locality
            stay.locality = nil
            stay.country = "Greece"
            stay.isoCountryCode = "GR"
        }
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        let material = try #require(await classifier.titlePromptMaterialForTesting(
            tripID: trip.id, tripIdentifier: trip.persistentModelID))
        #expect(material.candidates == ["Syros", "Kephalonia"])
        #expect(TripTitlePolicy.composeTitle(places: material.candidates) == trip.aiGeneratedTitle)
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Σύρος & Κεφαλονιά", outputLanguageTag: "el",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Syros & Kephalonia"
        })
        #expect(await service.localizedTitle(for: trip.id, languageTag: "el",
            gate: PipelineGate(forTesting: ())) == "Σύρος & Κεφαλονιά")
        #expect(await probe.translationPrompts.count == 1)
        #expect(await probe.checkerPrompts.count == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TripTitleVariant>())
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Σύρος & Κεφαλονιά")
    }

    @Test("Recognized missing or added places get exactly one correction despite positive self-assertions")
    func verifiedMismatchGetsOneCorrection() async throws {
        for firstEnglish in ["Athens", "Athens & Crete & Rome"] {
            let container = try TestSupport.makeInMemoryContainer()
            let trip = try makeGroundedTrip(in: ModelContext(container), names: ["Athens", "Crete", "Rome"])
            let service = TripTitleLocalizationService(modelContainer: container)
            let probe = LocalizedTitleVerificationProbe()
            await service.setVerificationOverridesForTesting(translator: { prompt, attempt in
                await probe.translation(prompt)
                return .init(title: attempt == 0 ? "Erster Titel" : "Athen & Kreta", outputLanguageTag: "de",
                             preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { prompt in
                await probe.checker(prompt)
                return prompt.contains("Erster Titel") ? firstEnglish : "Athens & Crete"
            })
            #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
                gate: PipelineGate(forTesting: ())) == "Athen & Kreta")
            let prompts = await probe.translationPrompts
            #expect(prompts.count == 2)
            #expect(prompts.last?.contains("changed the named places") == true)
            #expect(prompts.last?.contains("Rome") == false)
            #expect(await probe.checkerPrompts.count == 2)
        }
    }

    @Test("Unknown source meaning skips generation and never acquires a quality failure latch")
    func ungroundedSourceIsUnavailable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = try makeGroundedTrip(in: ModelContext(container), title: "Paris & Atlantis", names: ["Paris"])
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Paris", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Paris"
        })
        for _ in 0..<3 {
            #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
                gate: PipelineGate(forTesting: ())) == nil)
        }
        #expect(await probe.translationPrompts.isEmpty)
        #expect(await probe.checkerPrompts.isEmpty)
        #expect(!(await service.hasPersistentFailureForTesting(
            tripID: trip.id, languageTag: "de", sourceTitle: "Paris & Atlantis")))
    }

    @Test("Unfamiliar English aliases and checker errors stay retryable without a correction or quality latch")
    func inconclusiveCheckerDoesNotLatch() async throws {
        for checkerThrows in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let trip = try makeGroundedTrip(in: ModelContext(container), title: "Firenze", names: ["Firenze"])
            let service = TripTitleLocalizationService(modelContainer: container)
            let probe = LocalizedTitleVerificationProbe()
            await service.setVerificationOverridesForTesting(translator: { prompt, _ in
                await probe.translation(prompt)
                return .init(title: "Florenz", outputLanguageTag: "de",
                             preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { prompt in
                await probe.checker(prompt)
                if checkerThrows { throw CocoaError(.fileReadCorruptFile) }
                return "Florence"
            })
            for _ in 0..<3 {
                #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
                    gate: PipelineGate(forTesting: ())) == nil)
            }
            #expect(await probe.translationPrompts.count == 3)
            #expect(await probe.checkerPrompts.count == 3)
            #expect(!(await service.hasPersistentFailureForTesting(
                tripID: trip.id, languageTag: "de", sourceTitle: "Firenze")))
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
        }
    }

    @Test("Repeated recognized mismatches stop after one correction and retain the existing attempt threshold")
    func confirmedMismatchLatches() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = try makeGroundedTrip(in: ModelContext(container))
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Athen", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Athens"
        })
        for _ in 0..<3 {
            #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
                gate: PipelineGate(forTesting: ())) == nil)
        }
        #expect(await probe.translationPrompts.count == 4)
        #expect(await probe.checkerPrompts.count == 4)
        #expect(await service.hasPersistentFailureForTesting(
            tripID: trip.id, languageTag: "de", sourceTitle: "Athens & Crete"))
        await service.resetFailures(tripID: trip.id, languageTag: "de")
    }

    @Test("A source change while independent checking waits discards the result", .timeLimit(.minutes(1)))
    func verifiedApplyStillChecksSource() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeGroundedTrip(in: context)
        let service = TripTitleLocalizationService(modelContainer: container)
        let release = LocalizedTitleTestProbe()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await service.setVerificationOverridesForTesting(translator: { _, _ in
            .init(title: "Athen & Kreta", outputLanguageTag: "de",
                  preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { _ in
            continuation.yield()
            await release.wait()
            return "Athens & Crete"
        })
        let work = Task {
            await service.localizedTitle(for: trip.id, languageTag: "de", gate: PipelineGate(forTesting: ()))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        trip.aiGeneratedTitle = "Athens"
        trip.titleSourceRevision = UUID()
        try context.save()
        await release.release()
        #expect(await work.value == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("Checker cancellation remains cancellation, without a quality latch")
    func checkerCancellation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = try makeGroundedTrip(in: ModelContext(container))
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setVerificationOverridesForTesting(translator: { _, _ in
            .init(title: "Athen & Kreta", outputLanguageTag: "de",
                  preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { _ in throw CancellationError() })
        let summary = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: nil, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(summary.cancelled)
        #expect(summary.written == 0)
        #expect(summary.failed == 0)
        #expect(!(await service.hasPersistentFailureForTesting(
            tripID: trip.id, languageTag: "de", sourceTitle: "Athens & Crete")))
    }

    @Test("Verification rechecks saved stay semantics and custom names", .timeLimit(.minutes(1)))
    func verifiedApplyRechecksOtherInputs() async throws {
        for changesCustomName in [false, true] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let trip = try makeGroundedTrip(in: context)
            let service = TripTitleLocalizationService(modelContainer: container)
            let release = LocalizedTitleTestProbe()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            await service.setVerificationOverridesForTesting(translator: { _, _ in
                .init(title: "Athen & Kreta", outputLanguageTag: "de",
                      preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { _ in
                continuation.yield()
                await release.wait()
                return "Athens & Crete"
            })
            let work = Task {
                await service.localizedTitle(for: trip.id, languageTag: "de", gate: PipelineGate(forTesting: ()))
            }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            if changesCustomName {
                trip.customName = "Our holiday"
            } else {
                let stays = try context.fetch(FetchDescriptor<Stay>())
                let stay = try #require(stays.first)
                stay.locality = "Rome"
            }
            try context.save()
            await release.release()
            #expect(await work.value == nil)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
        }
    }

    @Test("A failed verification for changed input does not spend its old failure budget", .timeLimit(.minutes(1)))
    func discardedFailureDoesNotSpendBudget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeGroundedTrip(in: context)
        let service = TripTitleLocalizationService(modelContainer: container)
        let release = LocalizedTitleTestProbe()
        let probe = LocalizedTitleVerificationProbe()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Athen", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { _ in
            continuation.yield()
            await release.wait()
            return "Athens"
        })
        let work = Task {
            await service.localizedTitle(for: trip.id, languageTag: "de", gate: PipelineGate(forTesting: ()))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        trip.customName = "Our holiday"
        try context.save()
        await release.release()
        #expect(await work.value == nil)
        trip.customName = nil
        try context.save()
        // Restoring the exact semantic input exposes any incorrectly spent
        // old-key attempt: only one genuine failure has happened after this call.
        #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
            gate: PipelineGate(forTesting: ())) == nil)
        #expect(!(await service.hasPersistentFailureForTesting(
            tripID: trip.id, languageTag: "de", sourceTitle: "Athens & Crete")))
        #expect(await service.localizedTitle(for: trip.id, languageTag: "de",
            gate: PipelineGate(forTesting: ())) == nil)
        #expect(await service.hasPersistentFailureForTesting(
            tripID: trip.id, languageTag: "de", sourceTitle: "Athens & Crete"))
        #expect(await probe.translationPrompts.count == 6)
        await service.resetFailures(tripID: trip.id, languageTag: "de")
    }


    @Test("Inconclusive newest titles cannot starve later units or spin on repeated drains", .timeLimit(.minutes(1)))
    func deferredTitlesDoNotBlockDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let descriptor = try makeGroundedTrip(in: context, title: "Paris weekend", names: ["Paris"], offset: 30)
        let alias = try makeGroundedTrip(in: context, title: "Firenze", names: ["Firenze"], offset: 20)
        let malformed = try makeGroundedTrip(in: context, title: "Milan", names: ["Milan"], offset: 10)
        let translations = ["Paris": "Paris", "Berlin": "Berlin", "Rome": "Rom", "Madrid": "Madrid", "Vienna": "Wien"]
        for (index, name) in translations.keys.sorted().enumerated() {
            _ = try makeGroundedTrip(in: context, title: name, names: [name], offset: Double(index))
        }
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.clearAllFailureState()
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            let title: String
            if prompt.contains("<SOURCE_TITLE>Firenze</SOURCE_TITLE>") { title = "Florenz" }
            else if prompt.contains("<SOURCE_TITLE>Milan</SOURCE_TITLE>") { title = "Mailand" }
            else {
                title = translations.first { prompt.contains("<SOURCE_TITLE>\($0.key)</SOURCE_TITLE>") }?.value ?? "Invalid"
            }
            return .init(title: title, outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            if prompt.contains("<LOCALIZED_TITLE>Florenz</LOCALIZED_TITLE>") { return "Florence" }
            if prompt.contains("<LOCALIZED_TITLE>Mailand</LOCALIZED_TITLE>") { throw CocoaError(.fileReadCorruptFile) }
            return translations.first { prompt.contains("<LOCALIZED_TITLE>\($0.value)</LOCALIZED_TITLE>") }?.key ?? "Invalid"
        })

        let first = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 9, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(first.written == 5)
        #expect(first.failed == 0)
        #expect(!first.skippedUnsupported)
        #expect(!first.completed)
        #expect(await probe.translationPrompts.count == 7)
        #expect(await probe.checkerPrompts.count == 7)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TripTitleVariant>()) == 5)

        let second = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 9, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(second.written == 0)
        #expect(second.alreadyPresent == 5)
        #expect(second.failed == 0)
        #expect(!second.skippedUnsupported)
        #expect(!second.completed)
        // Only the alias and malformed checker retry once; descriptors cost no FM calls.
        #expect(await probe.translationPrompts.count == 9)
        #expect(await probe.checkerPrompts.count == 9)
        for (tripID, title) in [(descriptor.id, "Paris weekend"), (alias.id, "Firenze"), (malformed.id, "Milan")] {
            #expect(!(await service.hasPersistentFailureForTesting(tripID: tripID, languageTag: "de", sourceTitle: title)))
        }

        // An unchanged formerly inconclusive input can succeed on a later trigger.
        await service.setVerificationOverridesForTesting(translator: { _, _ in
            .init(title: "Florenz", outputLanguageTag: "de",
                  preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { _ in "Firenze" })
        #expect(await service.localizedTitle(for: alias.id, languageTag: "de", gate: PipelineGate(forTesting: ())) == "Florenz")
        await service.clearAllFailureState()
    }

    @Test("Global checker rate limits stop the drain and remain retryable", .timeLimit(.minutes(1)))
    func checkerModelUnavailabilityStopsDrain() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeGroundedTrip(in: context, title: "Paris", names: ["Paris"], offset: 2)
        _ = try makeGroundedTrip(in: context, title: "Berlin", names: ["Berlin"], offset: 1)
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.clearAllFailureState()
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: prompt.contains("Paris") ? "Paris" : "Berlin", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "injected model-wide limit"))
        })
        let blocked = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(blocked.skippedUnsupported)
        #expect(!blocked.completed)
        #expect(blocked.failed == 0)
        #expect(blocked.written == 0)
        #expect(await probe.translationPrompts.count == 1)
        #expect(await probe.checkerPrompts.count == 1)

        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            .init(title: prompt.contains("Paris") ? "Paris" : "Berlin", outputLanguageTag: "de",
                  preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in prompt.contains("Paris") ? "Paris" : "Berlin" })
        let recovered = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: nil, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(recovered.written == 2)
        #expect(recovered.completed)
        #expect(!recovered.skippedUnsupported)
        await service.clearAllFailureState()
    }

    @Test("iOS 27 checker rate limits stop the drain and remain retryable", .timeLimit(.minutes(1)))
    func checkerModelUnavailabilityStopsDrainIOS27() async throws {
        if #available(iOS 27, *) {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            _ = try makeGroundedTrip(in: context, title: "Paris", names: ["Paris"], offset: 2)
            _ = try makeGroundedTrip(in: context, title: "Berlin", names: ["Berlin"], offset: 1)
            let service = TripTitleLocalizationService(modelContainer: container)
            await service.clearAllFailureState()
            let probe = LocalizedTitleVerificationProbe()
            await service.setVerificationOverridesForTesting(translator: { prompt, _ in
                await probe.translation(prompt)
                return .init(title: prompt.contains("Paris") ? "Paris" : "Berlin", outputLanguageTag: "de",
                             preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { prompt in
                await probe.checker(prompt)
                throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "injected"))
            })
            let blocked = await service.generateLocalizedTitlesStage(
                maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
            #expect(blocked.skippedUnsupported)
            #expect(!blocked.completed)
            #expect(blocked.failed == 0)
            #expect(blocked.written == 0)
            #expect(await probe.translationPrompts.count == 1)
            #expect(await probe.checkerPrompts.count == 1)

            await service.setVerificationOverridesForTesting(translator: { prompt, _ in
                .init(title: prompt.contains("Paris") ? "Paris" : "Berlin", outputLanguageTag: "de",
                      preservesMeaning: true, preservesDestinationsAndProperNouns: true)
            }, backtranslator: { prompt in prompt.contains("Paris") ? "Paris" : "Berlin" })
            let recovered = await service.generateLocalizedTitlesStage(
                maxTripsPerCall: nil, languageTag: "de", gate: PipelineGate(forTesting: ()))
            #expect(recovered.written == 2)
            #expect(recovered.completed)
            #expect(!recovered.skippedUnsupported)
            await service.clearAllFailureState()
        } else {
            // The original test exercises the iOS 26 error family.
            return
        }
    }

    @Test("Legacy policy-2 failure keys receive one bounded recovery budget")
    func existingPolicyTwoFailureCanRecover() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeGroundedTrip(in: context)
        let cleaner = TripTitleLocalizationService(modelContainer: container)
        await cleaner.clearAllFailureState()
        // Reconstruct the shipped v2 key independently of the service's
        // current-version test helper, so a policy bump cannot silently pass.
        let payload = [
            "policy=2", "generation=1", "source=Athens & Crete",
            "revision=\(trip.titleSourceRevision?.uuidString ?? "legacy")",
            "semantic=\(TripTitleStore.semanticDigest(for: TripTitleStore.semanticSnapshot(for: trip)))"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        let oldKey = "\(trip.id.uuidString)|de|v2|\(digest)"
        IsolatedTitleDefaults.current.set([oldKey], forKey: "failedLocalizedTripTitleKeys_v2")
        let service = TripTitleLocalizationService(modelContainer: container)
        let probe = LocalizedTitleVerificationProbe()
        await service.setVerificationOverridesForTesting(translator: { prompt, _ in
            await probe.translation(prompt)
            return .init(title: "Athen & Kreta", outputLanguageTag: "de",
                         preservesMeaning: true, preservesDestinationsAndProperNouns: true)
        }, backtranslator: { prompt in
            await probe.checker(prompt)
            return "Athens & Crete"
        })
        let result = await service.generateLocalizedTitlesStage(
            maxTripsPerCall: 1, languageTag: "de", gate: PipelineGate(forTesting: ()))
        #expect(result.failed == 0)
        #expect(result.written == 1)
        #expect(!result.completed)
        #expect(await probe.translationPrompts.count == 1)
        #expect(await probe.checkerPrompts.count == 1)
        // A fresh service reads the persisted variant instead of translating again.
        let fresh = TripTitleLocalizationService(modelContainer: container)
        #expect(await fresh.localizedTitle(for: trip.id, languageTag: "de",
            gate: PipelineGate(forTesting: ())) == "Athen & Kreta")
        await service.clearAllFailureState()
    }
}
