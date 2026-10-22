//
//  ProcessingFailureReportingTests.swift
//  TravelLogTests
//
//  A required processing pass that did not complete is not success: the
//  classifier reports its completion, a Timeline/GPX import carries it into
//  its outcome and a duplicate-only re-import finalizes what an earlier run
//  recorded, a foreground photo finalization pauses instead of completing,
//  and a failed Visit evidence read fails the classification pass instead of
//  assembling trips without that evidence.
//
//  The widget fallback (redacted entries for a fallback or missing store)
//  lives in the widget extension, which this host does not compile or link,
//  so it is verified by building that target, not here.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import TravelLog

@MainActor
// `.serialized`: external imports toggle the process-global
// `ExternalHistoryImporter.isImportRunning` flag, and every stage here runs
// on the shared gate.
@Suite("Processing failure reporting", .serialized, IsolatedTitleDefaults())
struct ProcessingFailureReportingTests {

    static let base = Date(timeIntervalSince1970: 1_573_388_800)

    /// Two dwells about 50 km apart, five minutes between fixes.
    private var pings: [TimelinePing] {
        (0..<24).map { index in
            let atSecond = index >= 12
            return TimelinePing(
                timestamp: Self.base.addingTimeInterval(
                    Double(index) * 300 + (atSecond ? 3 * 3600 : 0)),
                latitude: atSecond ? 38.4 : 37.9838,
                longitude: 23.7275, horizontalAccuracy: 20)
        }
    }

    /// The live stages against fixture actors, without titles or widgets.
    /// `classify` waits behind a pass in flight, as the live stage does.
    private func stages(_ container: ModelContainer, classifier: TripClassifier)
        -> ExternalHistoryImporter.Stages {
        let clusterer = StayClusterer(modelContainer: container)
        return ExternalHistoryImporter.Stages(
            cluster: {
                let clustering = await PipelineGate.shared.runReturning(
                    touching: [.stay, .locationPing, .trip, .visit]) {
                    await clusterer.clusterUnprocessedPingsReportingChanges()
                }
                return !clustering.failed
            },
            classify: {
                await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                    reclassifyRecentStays: false, waitingForInFlight: true).completed
            },
            generateTitles: {}, reloadWidgets: {})
    }

    private func savedPings(_ container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
    }

    // MARK: - Classifier reporting

    @Test("a pass that creates no trips still reports completion")
    func zeroTripPassIsComplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        let result = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false)
        }
        #expect(result.created == 0)
        #expect(result.completed)
    }

    @Test("a failed required read reports an incomplete pass")
    func failedReadIsIncomplete() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failStage2BatchFetchForTesting = true
        let result = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false)
        }
        #expect(!result.completed)
    }

    // MARK: - Timeline/GPX

    @Test("a duplicate-only re-import finalizes fixes a failed clustering left unprocessed")
    func duplicateReimportFinalizesUnprocessedFixes() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let classifier = TripClassifier(modelContainer: container)
        let pings = self.pings

        let failed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await StayClusterer.SaveTestHook.$beforeSave.withValue({
                throw CocoaError(.fileWriteUnknown)
            }) {
                await ExternalHistoryImporter.record(
                    pings, source: .gpxImport, recorder: recorder,
                    stages: stages(container, classifier: classifier))
            }
        }
        #expect(failed.inserted == pings.count)
        #expect(!failed.saveFailed)
        #expect(failed.processingFailed)
        #expect(try savedPings(container).allSatisfy { !$0.isProcessed })

        let retry = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await ExternalHistoryImporter.record(
                pings, source: .gpxImport, recorder: recorder,
                stages: stages(container, classifier: classifier))
        }
        #expect(retry.inserted == 0)
        #expect(!retry.saveFailed)
        #expect(!retry.processingFailed)
        let saved = try savedPings(container)
        #expect(saved.count == pings.count)
        #expect(saved.allSatisfy { $0.isProcessed })
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) > 0)
    }

    @Test("a classification pass that does not complete is reported and retried by re-import")
    func classificationFailureIsReported() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let classifier = TripClassifier(modelContainer: container)
        let pings = self.pings

        classifier.failStage2BatchFetchForTesting = true
        let failed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await ExternalHistoryImporter.record(
                pings, source: .timelineImport, recorder: recorder,
                stages: stages(container, classifier: classifier))
        }
        #expect(failed.inserted == pings.count)
        #expect(!failed.saveFailed)
        #expect(failed.processingFailed)
        #expect(try unclassifiedStayCount(container) > 0)

        classifier.failStage2BatchFetchForTesting = false
        let retry = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await ExternalHistoryImporter.record(
                pings, source: .timelineImport, recorder: recorder,
                stages: stages(container, classifier: classifier))
        }
        #expect(retry.inserted == 0)
        #expect(!retry.processingFailed)
        #expect(try unclassifiedStayCount(container) == 0)
    }

    private func unclassifiedStayCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }))
    }

    @Test("an import that meets a pass in flight waits for it and finishes, not partial")
    func overlappingPassDoesNotFailExternalImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let classifier = TripClassifier(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)
        let pings = self.pings
        let importStages = stages(container, classifier: classifier)
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let running = Task {
            await TripClassifier.QueueTestHook.$waiting.withValue({ _ = signal.yield() }) {
                await StayClassificationInference.TestHook.$availability.withValue(false) {
                    await ExternalHistoryImporter.record(
                        pings, source: .gpxImport, recorder: recorder, stages: importStages)
                }
            }
        }
        var iterator = waiting.makeAsyncIterator()
        let queued = await iterator.next() != nil
        #expect(queued, "the import never waited for the pass in flight")
        #expect(ExternalHistoryImporter.isImportRunning)

        await classifier.setRunningLatchForTesting(false)
        let outcome = await running.value
        signal.finish()
        #expect(outcome.inserted == pings.count)
        #expect(!outcome.saveFailed)
        #expect(!outcome.processingFailed)
        #expect(try unclassifiedStayCount(container) == 0)
    }

    @Test("a run that saved nothing and failed still skips the post-pipeline")
    func failedEmptyRunSkipsPostPipeline() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.failImportBatchSaveCallForTesting(1)
        let ran = Counter()
        let outcome = await ExternalHistoryImporter.record(
            pings, source: .gpxImport, recorder: recorder,
            stages: ExternalHistoryImporter.Stages(
                cluster: { ran.count += 1; return true },
                classify: { ran.count += 1; return true },
                generateTitles: {}, reloadWidgets: {}))
        #expect(outcome.inserted == 0)
        #expect(outcome.saveFailed)
        #expect(!outcome.processingFailed)
        #expect(ran.count == 0)
    }

    @MainActor
    private final class Counter { var count = 0 }

    // MARK: - Visit evidence

    @Test("a failed Visit evidence read fails the pass without assembling trips")
    func visitReadFailureAbortsPass() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = Stay(startTime: Self.base, endTime: Self.base.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "visit-read-failure",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        stay.country = "Greece"
        context.insert(stay)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        classifier.failVisitBackedReadForTesting = true
        let failed = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false)
        }
        #expect(!failed.completed)
        #expect(failed.created == 0)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)

        classifier.failVisitBackedReadForTesting = false
        let retried = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false)
        }
        #expect(retried.completed)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 1)
    }

    // MARK: - Photos

    private static let library: [PhotoImportService.AssetForTesting] = (0..<30).map { index in
        let date = base.addingTimeInterval(Double(index) * 600)
        return PhotoImportService.AssetForTesting(
            creationDate: date,
            candidate: ImportedPingCandidate(
                timestamp: date, latitude: 37.90 + Double(index) * 0.01, longitude: 23.70,
                horizontalAccuracy: 10, altitude: nil, verticalAccuracy: nil))
    }

    private func runPhotoImport(
        _ service: PhotoImportService, in container: ModelContainer,
        foregroundClassifier: TripClassifier?,
        titleLocalizer: TripTitleLocalizationService? = nil
    ) async -> ImportStatus {
        var pipeline = PhotoImportService.PipelineForTesting(
            recorder: PingRecorder(modelContainer: container),
            clusterer: StayClusterer(modelContainer: container))
        pipeline.isForeground = foregroundClassifier != nil
        pipeline.classifier = foregroundClassifier
        pipeline.titleLocalizer = titleLocalizer
        return await StayClassificationInference.TestHook.$availability.withValue(false) {
            await PhotoImportService.$readAccessForTesting.withValue(true) {
                await PhotoImportService.$libraryForTesting.withValue(Self.library) {
                    await PhotoImportService.$pipelineForTesting.withValue(pipeline) {
                        await Task { await service.runImportSession(progress: nil) }.value
                    }
                }
            }
        }
    }

    @Test("an incomplete foreground classification pauses the photo import for resume")
    func foregroundClassificationFailurePausesPhotoImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let classifier = TripClassifier(modelContainer: container)
        classifier.failStage2BatchFetchForTesting = true

        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)
        #expect(await runPhotoImport(service, in: container,
                                     foregroundClassifier: classifier) == .paused)
        let paused = try #require(await service.currentState())
        #expect(paused.completedAt == nil)
        #expect(paused.lastError == "importError.finalizationSaveFailed")
        #expect(try savedPings(container).allSatisfy { $0.isProcessed },
                "clustering committed; only classification is retried")

        // Enumeration is complete, so the resumed foreground run finalizes
        // again and, with the fault gone, classifies what the first run left.
        classifier.failStage2BatchFetchForTesting = false
        await classifier.setTitleGenerationOverrideForTesting { _ in nil }
        let localizer = TripTitleLocalizationService(modelContainer: container)
        let relaunched = PhotoImportService(modelContainer: container)
        _ = try await relaunched.prepareResumedStateForTesting(originDeviceID: deviceID)
        #expect(await runPhotoImport(relaunched, in: container,
                                     foregroundClassifier: classifier,
                                     titleLocalizer: localizer) == .completed)
        #expect(try unclassifiedStayCount(container) == 0)
    }

    @Test("a foreground photo import waits behind a pass in flight and completes, not paused")
    func overlappingPassDoesNotPausePhotoImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let classifier = TripClassifier(modelContainer: container)
        // Fixture actors only: no title model and no app-store localizer.
        await classifier.setTitleGenerationOverrideForTesting { _ in nil }
        let localizer = TripTitleLocalizationService(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)

        let service = PhotoImportService(modelContainer: container)
        _ = try await service.prepareNewStateForTesting(originDeviceID: deviceID)
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let running = Task {
            await TripClassifier.QueueTestHook.$waiting.withValue({ _ = signal.yield() }) {
                await runPhotoImport(service, in: container, foregroundClassifier: classifier,
                                     titleLocalizer: localizer)
            }
        }
        var iterator = waiting.makeAsyncIterator()
        let queued = await iterator.next() != nil
        #expect(queued, "finalization never waited for the pass in flight")
        #expect(await service.currentState()?.status == .running)

        await classifier.setRunningLatchForTesting(false)
        #expect(await running.value == .completed)
        signal.finish()
        let completed = try #require(await service.currentState())
        #expect(completed.lastError == nil)
        #expect(try unclassifiedStayCount(container) == 0)
    }
}
