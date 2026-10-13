//
//  ExternalHistoryImporter.swift
//  TravelLog
//
//  Shared spine of the external-history imports (Google Timeline + GPX):
//  record chronologically-sorted fixes as
//  import-sourced pings in bounded gate units (a background SLC save can
//  never starve behind a whole file), then run the photo-import
//  post-pipeline — per-batch summary/provenance reconciliation → cluster → classify →
//  widget reload.
//
//  The sequence is a testable contract, not view plumbing. The
//  cluster/classify/widget stages are injectable for tests; the
//  `recomputeAffectedTripSummaries` step is the spine's own invariant
//  (PhotoImportService.finalizeSuccessfulImport Step-3 parity) and is
//  deliberately NOT injectable: pings that pre-attach into an existing
//  completed trip flip its stays to `.merged` and stale-date its summary,
//  and without the recompute the trip would keep a summary contradicting
//  its own dates forever.
//

import Foundation
import WidgetKit

enum ExternalHistoryImporter {

    nonisolated struct Outcome: Sendable, Equatable {
        let inserted: Int
        let saveFailed: Bool
        /// Clustering or classification did not complete: the fixes are
        /// recorded but trips may be missing until a later pass or re-import.
        let processingFailed: Bool
    }

    /// Gate-unit size: the next unit's dedup-window fetch must see this
    /// unit's saved rows, and a crash mid-import keeps everything already
    /// recorded.
    static let batchSize = 500

    /// True while a Timeline/GPX import is mid-flight on this device.
    /// `PhotoImportPingDeduplicator` checks it before either phase (the same reason it
    /// checks the photo loop): stay reconciliation must not interleave
    /// with this spine's pre-attach `pingIDs` mutations between gate units.
    private(set) static var isImportRunning = false

    /// The post-record pipeline stages. Production uses `.live`
    /// (AppDelegate singletons); tests stub these to drive the spine
    /// against an in-memory container without FM/clustering machinery.
    /// `cluster` and `classify` return whether their pass completed.
    struct Stages {
        var cluster: @MainActor @Sendable () async -> Bool
        var classify: @MainActor @Sendable () async -> Bool
        var generateTitles: @MainActor @Sendable () async -> Void
        var reloadWidgets: @MainActor @Sendable () -> Void

        static var live: Stages {
            Stages(
                cluster: {
                    let clustering = await PipelineGate.shared.runReturning(touching: [.stay, .locationPing, .trip, .visit]) {
                        await AppDelegate.stayClusterer.clusterUnprocessedPingsReportingChanges()
                    }
                    await AppDelegate.stayClusterer.enrichPendingLocalities(clustering.pendingLocalities)
                    return !clustering.failed
                },
                classify: {
                    // Waits behind a pass already in flight: that pass may
                    // have read the store before these fixes were clustered.
                    await AppDelegate.tripClassifier.classifyAndAssembleTripsReportingChangesWithGates(
                        reclassifyRecentStays: false, waitingForInFlight: true
                    ).completed
                },
                generateTitles: {
                    _ = await AppDelegate.tripClassifier.generateTitlesStage(
                        maxTripsPerCall: nil)
                    _ = await AppDelegate.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                },
                reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }
            )
        }
    }

    /// Records parsed fixes as `source` pings and runs the post-pipeline.
    /// Returns the durable inserted count, whether a later batch failed, and
    /// whether clustering or classification did not complete.
    @discardableResult
    static func record(
        _ pings: [TimelinePing],
        source: DataSource,
        recorder: PingRecorder,
        stages: Stages = .live
    ) async -> Outcome {
        isImportRunning = true
        defer { isImportRunning = false }

        // Stale IDs left by a previous import operation must not leak into
        // this run's summary recompute (photo-import start does the same —
        // PhotoImportService.runImport) — otherwise the recompute below
        // would nil summaries of trips this import never touched.
        await recorder.clearAffectedTripIDs()

        var inserted = 0
        var saveFailed = false
        var processingFailed = false
        var index = 0
        while index < pings.count {
            // Converted per unit: no second whole-file copy of the fixes.
            let batch = pings[index..<min(index + batchSize, pings.count)].map {
                ImportedPingCandidate(
                    timestamp: $0.timestamp,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    horizontalAccuracy: $0.horizontalAccuracy
                )
            }
            index += batch.count
            let durableCount: Int? = await PipelineGate.shared.runReturning(
                touching: [.locationPing, .hexVisit, .stay, .trip]
            ) {
                // One atomic save includes the pings/stays AND any title
                // invalidation their pre-attach requires. A failed unit is
                // not counted or followed by later batches from this run.
                do {
                    let accepted = try await recorder.recordImportedPings(batch, source: source)
                    try await recorder.saveImportBatch()
                    return accepted
                } catch {
                    return nil
                }
            }
            guard let durableCount else {
                saveFailed = true
                break
            }
            inserted += durableCount
        }

        // A run that saved nothing and failed skips this; every other run,
        // including a re-import whose fixes all dedup, finalizes, so fixes a
        // failed earlier run recorded but did not process are retried. The
        // stages are the pipeline's own idempotent passes (unprocessed pings,
        // unclassified stays) and the summary recompute below has nothing
        // affected after the clear above.
        if inserted > 0 || !saveFailed {
            // Post-pipeline, mirroring PhotoImportService.finalizeSuccessfulImport:
            // cluster the durable pings into stays, then classify/assemble
            // uncapped (a historical import can mint many trips at once).
            // This also runs after a later batch fails: already-committed
            // pings must not be left indefinitely unclustered/unpublished.
            // The live stage owns its write gate and awaits post-gate locality enrichment.
            let clustered = await stages.cluster()
            // Catch-all for older/pending actor state. Normal batches consume
            // their affected IDs above, so this is usually a cheap no-op.
            await PipelineGate.shared.run(touching: [.trip]) {
                await recorder.recomputeAffectedTripSummaries()
            }
            // The classifier owns its bounded write gates; inference runs
            // outside the gate so location persistence remains responsive.
            let classified = await stages.classify()
            processingFailed = !clustered || !classified
            await stages.generateTitles()
            stages.reloadWidgets()
        }
        return Outcome(inserted: inserted, saveFailed: saveFailed, processingFailed: processingFailed)
    }
}
