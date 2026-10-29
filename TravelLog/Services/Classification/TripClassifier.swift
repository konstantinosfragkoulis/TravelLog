//
//  TripClassifier.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WidgetKit
import os.log

/// Classifies stays and assembles trips after clustering.
/// Trip boundaries are deterministic: a home stay separates journeys and closes the preceding trip.
@ModelActor
actor TripClassifier {
    #if DEBUG
    // Task-local scope keeps fault injection per invocation across actor awaits.
    nonisolated enum SaveTestHook {
        @TaskLocal static var beforeSave: (@Sendable () throws -> Void)?
        @TaskLocal static var beforeRebuildSave: (@Sendable () throws -> Void)?
        @TaskLocal static var beforeRebuildResetSave: (@Sendable () throws -> Void)?
        /// Runs after a pass's classification unit lets go of the gate,
        /// before its assembly unit, so a test can write in between.
        @TaskLocal static var betweenPassUnits: (@Sendable () async -> Void)?
    }

    /// Signals that a queued explicit pass observed the latch held and is waiting.
    nonisolated enum QueueTestHook {
        @TaskLocal static var waiting: (@Sendable () -> Void)?
    }

    /// Runs when a temporary-home unit's gate has let go, before its wrapper's
    /// follow-up work, so a test can put another gated unit there.
    nonisolated enum TemporaryHomeTestHook {
        @TaskLocal static var afterUnit: (@Sendable () async -> Void)?
    }

    func classifyAndAssembleTripsReportingChangesWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = 60,
        gate: PipelineGate = .shared,
        beforeSave: @escaping @Sendable () throws -> Void
    ) async -> (created: Int, needsPublication: Bool, completed: Bool) {
        await SaveTestHook.$beforeSave.withValue(beforeSave) {
            await classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: reclassifyRecentStays,
                maxStaysPerCall: maxStaysPerCall, gate: gate)
        }
    }

    @discardableResult
    func reclassifyAll(gate: PipelineGate,
        beforeReplacementSave: @escaping @Sendable () throws -> Void) async -> RebuildOutcome {
        await SaveTestHook.$beforeRebuildSave.withValue(beforeReplacementSave) {
            await reclassifyAll(gate: gate)
        }
    }

    @discardableResult
    func reclassifyAll(gate: PipelineGate,
        beforeResetSave: @escaping @Sendable () throws -> Void) async -> RebuildOutcome {
        await SaveTestHook.$beforeRebuildResetSave.withValue(beforeResetSave) {
            await reclassifyAll(gate: gate)
        }
    }

    /// The queued healing entry with a save fault scoped to this invocation.
    func classifyAndAssembleTripsQueuedWithGates(
        maxStaysPerCall: Int? = nil,
        gate: PipelineGate = .shared,
        beforeSave: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        await SaveTestHook.$beforeSave.withValue(beforeSave) {
            await classifyAndAssembleTripsQueuedWithGates(
                maxStaysPerCall: maxStaysPerCall, gate: gate)
        }
    }

    #endif

    let logger = Logger(subsystem: "com.travellog.app", category: "TripClassifier")

    /// The stays this pass classified, whose user-edited owners' summaries
    /// are healed with them (`healUserEditedOpenTripSummaries`).
    var classifiedStayIDs: Set<UUID> = []
    var visitBackedStayIDs: Set<UUID> = []
    /// The home and routine stays the pre-filter's latest call stamped: new
    /// anchors whose journey tails Stage 1.5 hands back.
    var stampedAnchors: [Stay] = []

    /// Whether any stage of the current pipeline pass changed data —
    /// gates the widget-timeline reload in the
    /// `classifyAndAssembleTrips*WithGates` entry points.
    var lastPipelineMadeChanges = false

    /// Whether the back half (sanity-check → assemble → close) has completed a
    /// full, non-cancelled pass since this process launched. The first pass
    /// each launch always runs the back half (baseline heal); after that it is
    /// dirty-gated. See the gate in `runPipelineStagesWithGates`.
    var hasRunBackHalfSinceLaunch = false

    /// The rows an uncapped pass's Stage 2 settles per gate unit, as a
    /// backlog drain's bite does (`runPipelineStagesWithGates`).
    var uncappedStage2UnitSize = ForegroundClassificationDrain.biteSize

    /// Set when a back-half summary recompute could not read the home-place
    /// index; the back half then throws into its unit's rollback.
    var summaryHomePlacesUnreadable = false


    /// Whether the last temporary-home unit found a temporary home in the store,
    /// live or removed. A debt whose row never saved finds none, and its wrapper
    /// then starts no follow-up work.
    var temporaryHomeUnitFoundOne = false

    /// The ids of the trips the last committed temporary-home unit split and
    /// archived. Its wrapper unpins them and drops their photo caches.
    var temporaryHomeUnitRetiredTripIDs = Set<UUID>()

    /// What the last committed unit of a live temporary home processed and
    /// left (`temporaryHomeDigests` over its own rows as it saved them), and
    /// whether it deferred a newer copy's stamps. Its wrapper acknowledges it.
    var temporaryHomeUnitAcknowledgement: (id: UUID, digest: String, deferred: Bool)?

    /// The hidden-photo lineages the current unit's regrouping retired
    /// (`PhotoLineageStore`): recorded just before the unit's save and put
    /// back if it fails, dropped with a rolled-back unit.
    var pendingHiddenLineages: [PhotoLineageStore.Lineage] = []
    /// The splits that kept an original id in the current unit, logged the
    /// same way (`PhotoLineageStore.SplitProvenance`).
    var pendingHiddenSplits: [PhotoLineageStore.SplitProvenance] = []
    /// The detached-member log as the current unit's assembly leaves it
    /// (`PhotoLineageStore.detachedMembers`), written with the lineage logs;
    /// nil when the unit did not change it.
    var pendingDetachedMembers: [UUID: Set<UUID>]?
    /// The spared-trip log as the current unit's release leaves it
    /// (`sparedTripsKey`), written with the lineage logs; nil when unchanged.
    var pendingSparedTrips: [UUID: Set<UUID>]?

    #if DEBUG
    /// A test's own suite for the lineage log of every classifier it runs.
    @TaskLocal nonisolated static var hiddenLineageSuiteNameForTesting: String?
    #endif

    /// Where the hidden-photo lineage log lives; tests inject their own.
    var hiddenLineageDefaults: UserDefaults {
        get {
            if let injectedHiddenLineageDefaults { return injectedHiddenLineageDefaults }
            #if DEBUG
            if let suite = Self.hiddenLineageSuiteNameForTesting { return UserDefaults(suiteName: suite)! }
            #endif
            return .standard
        }
        set { injectedHiddenLineageDefaults = newValue }
    }
    private var injectedHiddenLineageDefaults: UserDefaults?

    /// True until the first complete back-half pass of this launch. The
    /// Trips list reads it to decide whether an upcoming run is visible work.
    func baselinePassPending() -> Bool { !hasRunBackHalfSinceLaunch }

    /// Prevents concurrent pipeline runs from overlapping views (TripsListView,
    /// StatusDashboardView, StaysListView all trigger the pipeline on appear).
    var isRunning = false
    /// Explicit actions waiting in `takeLatchQueued`.
    var latchWaiters = 0
    #if DEBUG
    var homeAreaHealingFetchCallCountForTesting = 0
    var failingHomeAreaHealingFetchCallForTesting: Int?
    var shouldFailNextUnHomeStaysSaveForTesting = false
    // Instance-scoped faults keep parallel tests from affecting other classifiers.
    nonisolated(unsafe) var failAssemblyStayFetchForTesting = false
    nonisolated(unsafe) var assemblyFetchFailureCallForTesting = 2
    var assemblyFetchCallForTesting = 0
    nonisolated(unsafe) var failIdentityRestorationFetchForTesting = false
    nonisolated(unsafe) var failRebuildResetTripFetchForTesting = false
    nonisolated(unsafe) var failRebuildResetStayFetchForTesting = false
    nonisolated(unsafe) var failRebuildDetachFetchForTesting = false
    nonisolated(unsafe) var failStage2BatchFetchForTesting = false
    nonisolated(unsafe) var failStage2CohortFetchForTesting = false
    nonisolated(unsafe) var failPreFilterStayFetchForTesting = false
    nonisolated(unsafe) var failInvariantOverrideFetchForTesting = false
    nonisolated(unsafe) var failSanityFetchForTesting = false
    nonisolated(unsafe) var failStaleClosureFetchForTesting = false
    nonisolated(unsafe) var failUnHomeStaysFetchForTesting = false
    nonisolated(unsafe) var failHomeReadForTesting = false
    nonisolated(unsafe) var failTemporaryHomeReadForTesting = false
    nonisolated(unsafe) var failDemotionTripReadForTesting = false
    nonisolated(unsafe) var failDemotionOverrideReadForTesting = false
    nonisolated(unsafe) var failRoutineReadForTesting = false
    nonisolated(unsafe) var failOrbitEvidenceReadForTesting = false
    nonisolated(unsafe) var failVisitBackedReadForTesting = false
    nonisolated(unsafe) var failReclassificationHomeReadForTesting = false

    func readFailureContextHasChangesForTesting() -> Bool { modelContext.hasChanges }

    func failHomeAreaHealingFetchCallForTesting(_ call: Int) {
        homeAreaHealingFetchCallCountForTesting = 0
        failingHomeAreaHealingFetchCallForTesting = call
    }

    func failNextUnHomeStaysSaveForTesting() {
        shouldFailNextUnHomeStaysSaveForTesting = true
    }

    var shouldFailNextLogAsTripSaveForTesting = false

    func failNextLogAsTripSaveForTesting() {
        shouldFailNextLogAsTripSaveForTesting = true
    }

    var shouldFailNextReconciliationSaveForTesting = false
    nonisolated(unsafe) var failReconciliationStayReadForTesting = false

    func failNextReconciliationSaveForTesting() {
        shouldFailNextReconciliationSaveForTesting = true
    }
    #endif

    #if DEBUG
    var calendarWipeWaitingForLatchForTesting = false

    /// Test seam for holding the pipeline latch while a calendar wipe queues.
    func setRunningLatchForTesting(_ running: Bool) {
        isRunning = running
    }

    func setUncappedStage2UnitSizeForTesting(_ size: Int) {
        uncappedStage2UnitSize = size
    }

    func setAITitleForTesting(_ title: String?, tripID: UUID) {
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trip = try? modelContext.fetch(
            FetchDescriptor<Trip>(predicate: predicate)
        ).first else { return }
        _ = TripTitleStore.replaceCanonicalTitle(
            title, for: trip, in: modelContext)
        try? modelContext.save()
    }

    func calendarWipeIsWaitingForLatchForTesting() -> Bool {
        calendarWipeWaitingForLatchForTesting
    }

    func healUserEditedOpenTripTitlesForTesting(
        changedStayIDs: Set<UUID>
    ) {
        classifiedStayIDs = changedStayIDs
        try? healUserEditedOpenTripSummaries()
    }
    #endif

    /// Last homecoming confirmation request, process-local because only this device accompanies the user.
    var lastHomecomingConfirmationRequest: Date?

    /// Waits until neither a pass nor `whileBusy` holds the classifier back,
    /// then takes `isRunning`. False on cancellation, leaving the latch
    /// alone. No await separates the last check from taking the latch.
    func takeLatchQueued(
        whileBusy busy: () -> Bool = { false },
        waiting: () -> Void = {}
    ) async -> Bool {
        latchWaiters += 1
        defer { latchWaiters -= 1 }
        while isRunning || busy() {
            guard !Task.isCancelled else { return false }
            waiting()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return false }
        }
        isRunning = true
        return true
    }

    // MARK: - Main Entry Point

    /// What an explicit rebuild committed. UI success follows `.completed` only.
    nonisolated enum RebuildOutcome: Sendable, Equatable {
        /// The reset, every classification unit and the replacement committed.
        case completed
        /// A required read or save failed or a unit rolled back. Units committed before the failure
        /// stand (identities and annotations are retained); retry is safe.
        case failed
        /// The caller was cancelled before or during the rebuild.
        case cancelled
    }

    /// Reclassify while preserving user-overridden categories, user-edited trips, and surviving trip identities.
    @discardableResult
    func reclassifyAll(gate: PipelineGate = .shared) async -> RebuildOutcome {
        // Explicit reclassification must queue behind an in-flight run.
        // No await may separate the loop exit from acquiring the actor-isolated latch.
        guard !Task.isCancelled else { return .cancelled }
        guard await takeLatchQueued(waiting: {
            logger.debug("Pipeline running; reclassification queued.")
            #if DEBUG
            QueueTestHook.waiting?()
            #endif
        }) else { return .cancelled }
        defer { isRunning = false }

        let rebuild = await gate.runReturning(touching: [.stay, .trip]) {
            await self.reclassifyAllCore()
        }
        guard let rebuild else { return Task.isCancelled ? .cancelled : .failed }
        let pass = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate, rebuild: rebuild)
        guard pass.completed else { return Task.isCancelled ? .cancelled : .failed }
        // Titles follow a committed rebuild only; they do not decide the outcome.
        _ = await generateTitlesStage(maxTripsPerCall: nil, applyGate: gate)
        return .completed
    }

    /// Memoized shapes let synchronous classification and reconciliation cores read home geometry.
    var resolvedHomeShapes: [String: HomeShape] = [:]

    /// Learned orbit discs per home, reused only when a fresh projected scan
    /// produces the same SHA-256 digest of all derivation inputs.
    /// Pass units derive these immediately before their first read; readers outside a pass prime
    /// themselves, and healing reads its own fingerprint's prime.
    var resolvedHomeOrbits: [String: [HomeOrbit.OrbitDisc]] = [:]
    var resolvedHomeOrbitInputDigests: [String: SHA256.Digest] = [:]
    /// The merged stays' own live support, as the last orbit prime resolved
    /// it (`MergedLiveSupport`). Nil before one resolved it against history.
    var mergedLiveSupport: MergedLiveSupport?

    #if DEBUG
    var orbitDerivationCountForTesting = 0
    /// Assemblies that walked the completed trips for retroactive home boundaries.
    var historicalScanCountForTesting = 0
    /// Ping queries the orbit prime made to resolve merged stays' live support.
    var mergedSupportPingQueryCountForTesting = 0

    func primedOrbitsForTesting(seedsOnly: Bool = false) async -> [String: [HomeOrbit.OrbitDisc]] {
        await primeHomeShapes(seedsOnly: seedsOnly)
        return resolvedHomeOrbits
    }
    #endif

    /// Memoize suppressed destinations so assemblyInvariantViolated accepts their tripless steady state.
    /// Re-arm when decision inputs change, except pure endTime growth before accretionClearsAt:
    /// the score is monotone in duration, and its crossing time is known.
    /// Shrinks, start-time changes, geometry drift past tolerance, and airport changes still re-arm.
    /// The first back-half pass always runs and repopulates this launch-local memo.
    var gateSuppressedStayFingerprints: [UUID: SuppressedStayFingerprint] = [:]

    /// A suppressed verdict also rests on inputs no fingerprint holds: where the
    /// tripless stays sit relative to each home area (real or temporary) decides where
    /// a run closes, a tripless transit row's length is part of its run, and a
    /// temporary home's dates decide which runs it may score. This digest of them,
    /// written with the memo, must still match before the memo excuses anything.
    /// Nil when the pass suppressed nothing.
    var gateSuppressionInputDigest: SHA256.Digest?

    /// What the last committed assembly's completed-trip scan stood on
    /// (`HistoricalBoundaryScan`). While it holds, an assembly skips the scan,
    /// and a home stay that arrives, or comes to qualify, without this device
    /// classifying it (sync, a Visit) re-arms the back half
    /// (`assemblyInvariantViolated`). Nil before an assembly read it, or when
    /// no trip-class stay existed.
    var acknowledgedHistoricalScan: HistoricalBoundaryScan?
    /// What this unit's assembly read, acknowledged once the unit commits.
    var pendingHistoricalScan: PendingHistoricalScan = .none

    /// The favourites assembly leaves whole against a late home boundary.
    /// They live on the main actor; a pass reads them before its assembly.
    var pinnedTripIDsSource: @MainActor @Sendable () -> Set<UUID> = { PinnedTripsStorage.shared.pinnedIDs }

    /// Run classification and assembly; returns the number of new trips.
    /// reclassifyRecentStays revisits the latest five journey stays with fresh context; imports disable it.
    /// maxStaysPerCall bounds Stage 2 work for UI callers; nil drains the backlog.
    /// Call outside PipelineGate: this owns its gate units.
    @discardableResult
    func classifyAndAssembleTripsWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = 60,
        gate: PipelineGate = .shared
    ) async -> Int {
        await classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: reclassifyRecentStays,
            maxStaysPerCall: maxStaysPerCall, gate: gate).created
    }

    /// `completed` means what the queued entry reports: the whole pass
    /// committed. Zero new trips
    /// is not a failure. A pass skipped behind one already in flight is not
    /// completed; `waitingForInFlight` instead waits for that pass, as the
    /// queued entry does, and then runs (an import's stays must be classified
    /// by a pass that read them). Cancellation while waiting is not completed.
    func classifyAndAssembleTripsReportingChangesWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = 60,
        gate: PipelineGate = .shared,
        waitingForInFlight: Bool = false
    ) async -> (created: Int, needsPublication: Bool, completed: Bool) {
        if waitingForInFlight {
            guard await takeLatchQueued(waiting: {
                logger.debug("Pipeline running; reporting classification waits.")
                #if DEBUG
                QueueTestHook.waiting?()
                #endif
            }) else { return (0, false, false) }
        } else {
            guard !isRunning else { return (0, false, false) }
            isRunning = true
        }
        defer { isRunning = false }
        let result = await runPipelineStagesWithGates(reclassifyRecentStays: reclassifyRecentStays,
            maxStaysPerCall: maxStaysPerCall, gate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return (result.created, result.needsPublication, result.completed)
    }

    /// Event-driven finalization (home-area healing) that must not be
    /// dropped behind an in-flight pass: queue outside any gate, as the other
    /// explicit actions do, and report whether the whole pass committed.
    /// False on cancellation or a failed required read or save, so the
    /// caller keeps its completion stamp and retries on the next trigger.
    func classifyAndAssembleTripsQueuedWithGates(
        maxStaysPerCall: Int? = nil,
        gate: PipelineGate = .shared
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await takeLatchQueued(waiting: {
            logger.debug("Pipeline running; queued classification waits.")
            #if DEBUG
            QueueTestHook.waiting?()
            #endif
        }) else { return false }
        defer { isRunning = false }
        let result = await runPipelineStagesWithGates(maxStaysPerCall: maxStaysPerCall, gate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return result.completed
    }

    /// One bite of a backlog drain (the foreground drain, the background
    /// refresh): an ordinary pass over at most `maxStaysPerCall` stays. It
    /// waits behind a pass in flight and, unlike the other entries, behind
    /// every explicit action waiting for the latch, so back-to-back bites
    /// never starve one. `unitPolicy` is checked as each unit begins; a unit
    /// it refuses stops the bite there, uncompleted.
    func runBacklogBite(
        maxStaysPerCall: Int,
        reclassifyRecentStays: Bool = false,
        unitPolicy: (@Sendable () -> Bool)? = nil,
        gate: PipelineGate = .shared
    ) async -> ForegroundClassificationDrain.BiteOutcome {
        let stopped = ForegroundClassificationDrain.BiteOutcome(completed: false, classified: 0)
        // No await may separate the loop exit from acquiring the actor-isolated latch.
        guard !Task.isCancelled else { return stopped }
        while isRunning || latchWaiters > 0 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return stopped }
        }
        isRunning = true
        defer { isRunning = false }
        let result = await runPipelineStagesWithGates(reclassifyRecentStays: reclassifyRecentStays,
            maxStaysPerCall: maxStaysPerCall, gate: gate, unitPolicy: unitPolicy)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return ForegroundClassificationDrain.BiteOutcome(
            completed: result.completed, classified: result.classified)
    }

    /// Set while a temporary-home unit's assembly runs: assembly records its
    /// constituents and outputs here and restores no identity itself.
    var deferredAssemblyIdentities: DeferredAssemblyIdentities?

    #if DEBUG
    /// The stay rows the last discovery read fetched.
    var discoveryStayReadCountForTesting = 0
    #endif

    var lastDemotion: DemotionUndo?

    // MARK: - Dissolve soft-delete queue

    /// Records for the trips the CURRENT healing pass dissolved, already
    /// persisted into `DissolvedTripQueue` by `dissolvedRecordSink`. Drained
    /// (released, not appended again) by `HomeAreaHealing.healIfNeeded` right
    /// after the heal unit returns; tests read them directly.
    var parkedDissolvedTrips: [DissolvedTripRecord] = []

    /// Persist recovery records BEFORE the deleting save so termination cannot lose the restore path.
    /// Production wires DissolvedTripQueue.append at launch.
    /// DEBUG tests may omit the sink and inspect drained records.
    var dissolvedRecordSink:
        (@Sendable ([DissolvedTripRecord]) throws -> Void)?

    #if DEBUG
    var failNextDissolvedRestoreSaveForTesting = false
    var dissolvedRestoreFetchCallCountForTesting = 0
    var failingDissolvedRestoreFetchCallForTesting: Int?
    var generatedTitleRevocationPendingOverrideForTesting: Bool?

    func failNextDissolvedRestoreSave() {
        failNextDissolvedRestoreSaveForTesting = true
    }

    func failDissolvedRestoreFetchCallForTesting(_ call: Int) {
        dissolvedRestoreFetchCallCountForTesting = 0
        failingDissolvedRestoreFetchCallForTesting = call
    }

    func setGeneratedTitleRevocationPendingForTesting(_ pending: Bool?) {
        generatedTitleRevocationPendingOverrideForTesting = pending
    }
    #endif

    #if DEBUG
    var failNextCalendarTitleWipeClearForTesting = false

    func failNextCalendarTitleWipeClear() {
        failNextCalendarTitleWipeClearForTesting = true
    }

    func clearCalendarTitlesForTesting() -> Bool {
        rederiveAllCanonicalTitlesForCalendarWipe() != nil
    }
    #endif

}
