import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

/// Uses the same generated ModelActor context as the pipeline workers. Only
/// scalar observations cross the actor boundary; persistence is checked again
/// from an independent context in the hosted test.
@ModelActor
private actor PipelineDirtySaveProbe {
    /// This deliberately retains the pre-rollback references and never fetches
    /// in the owning context afterward. A fresh context verifies what a clean
    /// save actually committed, independently of cached-model rollback state.
    func rollbackThenCleanSave() throws -> [Bool] {
        let trip = Trip(startDate: Date(timeIntervalSince1970: 1_687_904_000))
        trip.customName = "Persisted name"
        let stay = Stay(
            startTime: trip.startDate, endTime: trip.startDate.addingTimeInterval(3600),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "probe", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        modelContext.insert(trip)
        modelContext.insert(stay)
        stay.trip = trip
        try modelContext.save()
        trip.customName = "Rolled back"
        var checks = [modelContext.hasChanges]
        modelContext.rollback()
        checks.append(!modelContext.hasChanges)
        // A stale retained reference must not turn this clean save into an
        // unreported write. Keep the original graph alive through the save.
        try withExtendedLifetime((trip, stay)) { try modelContext.save() }
        checks.append(!modelContext.hasChanges)
        let verification = ModelContext(modelContainer)
        let stored = try #require(try verification.fetch(FetchDescriptor<Trip>()).first)
        checks.append(stored.customName == "Persisted name")
        return checks
    }

    func exercise() throws -> [Bool] {
        var checks = [!modelContext.autosaveEnabled, !modelContext.hasChanges]
        let trip = Trip(startDate: Date(timeIntervalSince1970: 1_687_904_000))
        modelContext.insert(trip)
        checks.append(modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)

        trip.customName = "Persisted name"
        checks.append(modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)

        let stay = Stay(
            startTime: trip.startDate, endTime: trip.startDate.addingTimeInterval(3600),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "probe", pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        modelContext.insert(stay)
        try modelContext.save()
        stay.trip = trip
        checks.append(modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)

        trip.aiGeneratedTitle = "Athens"
        modelContext.insert(TripTitleVariant(
            languageTag: "de", title: "Athen", sourceTitle: "Athens", trip: trip))
        try modelContext.save()
        TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
        checks.append(modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)

        modelContext.delete(stay)
        checks.append(modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)
        try modelContext.save()
        checks.append(!modelContext.hasChanges)
        return checks
    }
}

@MainActor
@Suite("Pipeline publication outcomes")
struct PipelinePublicationOutcomeTests {
    @Test("a clean ModelActor save after rollback cannot commit retained stale values on disk")
    func rollbackCleanSaveDoesNotCommitHiddenChanges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let probe = PipelineDirtySaveProbe(modelContainer: container)
        let checks = try await probe.rollbackThenCleanSave()
        #expect(checks.count == 4)
        for (index, passed) in checks.enumerated() {
            #expect(passed, "disk-backed rollback clean-save checkpoint \(index)")
        }
    }

    @Test("ModelActor dirty state covers updates, relationships, title invalidation and deletes")
    func modelActorHasChangesTracksPipelineMutations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let probe = PipelineDirtySaveProbe(modelContainer: container)
        let checks = try await probe.exercise()
        #expect(checks.count == 13)
        for (index, passed) in checks.enumerated() {
            #expect(passed, "dirty-state checkpoint \(index) failed")
        }
        let verification = ModelContext(container)
        let trip = try #require(try verification.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.customName == "Persisted name")
        #expect(trip.aiGeneratedTitle == nil)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    private var base: Date { Date(timeIntervalSince1970: 1_687_904_000) }

    private func ping(at date: Date) -> LocationPing {
        LocationPing(
            timestamp: date, latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 10, h3IndexRes6: "publication", source: .liveSLC)
    }

    private func stay(at date: Date) -> Stay {
        Stay(
            startTime: date, endTime: date.addingTimeInterval(3600),
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: "publication", pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: [])
    }

    private func homeFixture() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(
            label: "Home", latitude: 37.9838, longitude: 23.7275,
            radiusKm: 25, startedAt: base.addingTimeInterval(-86400)))
        context.insert(stay(at: base))
        try context.save()
        return container
    }

    @Test("all three workers report an empty pass without publication")
    func emptyWorkersDoNotRequestPublication() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let clustering = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges()
        let transit = await TransitInferer(modelContainer: container)
            .inferTransitForRecentStaysReportingChanges()
        let classification = await TripClassifier(modelContainer: container)
            .classifyAndAssembleTripsReportingChangesWithGates()
        #expect(clustering.created == 0 && !clustering.needsPublication)
        #expect(transit.fetched == 0 && !transit.needsPublication)
        #expect(classification.created == 0 && !classification.needsPublication)
    }

    @Test("extending a stay publishes with zero new stays, then settles")
    func stayExtensionPublishesWithoutCreation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let existing = stay(at: base)
        context.insert(existing)
        context.insert(ping(at: base.addingTimeInterval(7200)))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let outcome = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(outcome.created == 0)
        #expect(outcome.needsPublication)
        let verification = ModelContext(container)
        let saved = try #require(try verification.fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.endTime == base.addingTimeInterval(7200))
        #expect(try verification.fetch(FetchDescriptor<LocationPing>()).allSatisfy(\.isProcessed))
        let settled = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(settled.created == 0 && !settled.needsPublication)
    }

    @Test("Visit-only reconciliation publishes and a processed Visit settles")
    func visitOnlyReconciliationPublishes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(7200),
            latitude: 37.9838, longitude: 23.7275, horizontalAccuracy: 5,
            receivedAt: base.addingTimeInterval(7200)))
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        let outcome = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(outcome.created == 1 && outcome.needsPublication)
        let savedVisit = try #require(try ModelContext(container).fetch(FetchDescriptor<Visit>()).first)
        #expect(savedVisit.isProcessed && savedVisit.stayID != nil)
        let settled = await clusterer.clusterUnprocessedPingsReportingChanges()
        #expect(settled.created == 0 && !settled.needsPublication)
    }

    #if DEBUG
    @Test("a committed ping batch still publishes after Visit save rollback")
    func earlierClusterCommitSurvivesLaterRollback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(ping(at: base))
        context.insert(Visit(
            arrivalDate: base.addingTimeInterval(2 * 86400),
            departureDate: base.addingTimeInterval(2 * 86400 + 7200),
            latitude: 39.6628, longitude: 20.8612, horizontalAccuracy: 5,
            receivedAt: base.addingTimeInterval(2 * 86400 + 7200)))
        try context.save()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges(beforeSave: {
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 2 { throw CocoaError(.fileWriteUnknown) }
            })
        #expect(calls.withLock { $0 } == 2)
        #expect(outcome.created == 1 && outcome.needsPublication)
        // The pending Visits make the pass incomplete for an import finalizing on it.
        #expect(outcome.failed)
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 1)
        #expect(try verification.fetch(FetchDescriptor<LocationPing>()).allSatisfy(\.isProcessed))
        #expect(try verification.fetch(FetchDescriptor<Visit>()).allSatisfy { !$0.isProcessed })
    }

    @Test("a dirty failed cluster save retains fail-open publication after rollback")
    func failedClusterSaveStillRequestsPublication() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(ping(at: base))
        try context.save()
        let outcome = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPingsReportingChanges(beforeSave: {
                throw CocoaError(.fileWriteUnknown)
            })
        #expect(outcome.created == 0 && outcome.needsPublication)
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try verification.fetch(FetchDescriptor<LocationPing>()).allSatisfy { !$0.isProcessed })
    }

    #endif

    @Test("transit-only changes publish; an exhausted inference pass does not")
    func transitChangesPublishThenSettle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(stay(at: base))
        try context.save()
        let inferer = TransitInferer(modelContainer: container)
        let outcome = await inferer.inferTransitForRecentStaysReportingChanges()
        #expect(outcome.fetched == 1 && outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.transitFromPreviousRaw == TransitMode.unknown.rawValue)
        let settled = await inferer.inferTransitForRecentStaysReportingChanges()
        #expect(settled.fetched == 0 && !settled.needsPublication)
    }

    #if DEBUG
    @Test("a dirty failed transit save requests conservative publication")
    func failedTransitSaveStillRequestsPublication() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(stay(at: base))
        try context.save()
        let outcome = await TransitInferer(modelContainer: container)
            .inferTransitForRecentStaysReportingChanges(beforeSave: {
                throw CocoaError(.fileWriteUnknown)
            })
        #expect(outcome.fetched == 1 && outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.transitFromPreviousRaw == nil)
    }

    #endif

    @Test("cancelled inference can fetch a stay without changing or publishing it")
    func cancelledTransitFetchDoesNotPublish() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(stay(at: base))
        try context.save()
        let inferer = TransitInferer(modelContainer: container)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await inferer.inferTransitForRecentStaysReportingChanges()
        }
        let outcome = await task.value
        #expect(outcome.fetched == 1 && !outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.transitFromPreviousRaw == nil)
    }

    @Test("classification publishes a category-only change with no new trip, then settles")
    func categoryOnlyClassificationPublishesThenSettles() async throws {
        let container = try homeFixture()
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.classifyAndAssembleTripsReportingChangesWithGates()
        #expect(outcome.created == 0 && outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.category == .home)
        let settled = await classifier.classifyAndAssembleTripsReportingChangesWithGates()
        #expect(settled.created == 0 && !settled.needsPublication)
    }

    #if DEBUG
    @Test("classifier publication survives its final save failing, which re-arms the baseline")
    func earlierClassifierCommitSurvivesLaterSaveFailure() async throws {
        let container = try homeFixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier
            .classifyAndAssembleTripsReportingChangesWithGates(beforeSave: {
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 2 { throw CocoaError(.fileWriteUnknown) }
            })
        // One checked final save: its failure rolls the unit back instead of
        // retrying blindly and leaving repairs for another unit to decide.
        #expect(calls.withLock { $0 } == 2)
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(outcome.created == 0 && outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.category == .home)
    }

    @Test("failed classifier saves publish conservatively and retained edits publish on retry")
    func failedClassifierSaveAndRetryBothRequestPublication() async throws {
        let container = try homeFixture()
        let classifier = TripClassifier(modelContainer: container)
        let failed = await classifier.classifyAndAssembleTripsReportingChangesWithGates(beforeSave: {
            throw CocoaError(.fileWriteUnknown)
        })
        #expect(failed.created == 0 && failed.needsPublication)
        let beforeRetry = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(beforeRetry.category == .unclassified)
        let retried = await classifier.classifyAndAssembleTripsReportingChangesWithGates()
        #expect(retried.created == 0 && retried.needsPublication)
        let afterRetry = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(afterRetry.category == .home)
    }

    #endif

    @Test("cancellation retains the classifier's saved pre-filter changes")
    func cancelledClassifierPublishesSavedPreFilter() async throws {
        let container = try homeFixture()
        let classifier = TripClassifier(modelContainer: container)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.classifyAndAssembleTripsReportingChangesWithGates()
        }
        let outcome = await task.value
        #expect(outcome.created == 0 && outcome.needsPublication)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.category == .home)
    }

    @Test("cancellation of an empty gated classifier pass publishes nothing")
    func cancelledEmptyClassifierDoesNotPublish() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await classifier.classifyAndAssembleTripsReportingChangesWithGates()
        }.value
        #expect(result.created == 0 && !result.needsPublication)
    }

}
