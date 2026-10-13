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
import FoundationModels
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

    /// Exercise the production classification lifecycle without model hardware.
    /// Overrides are scoped to this invocation and inherited across actor hops.
    func classifyAndAssembleTripsReportingChangesWithGates(
        reclassifyRecentStays: Bool = true,
        maxStaysPerCall: Int? = 60,
        gate: PipelineGate = .shared,
        fmAvailable: Bool,
        response: @escaping @Sendable (String) async throws
            -> [StayClassificationInference.Classification]
    ) async -> (created: Int, needsPublication: Bool, completed: Bool) {
        await StayClassificationInference.TestHook.$availability.withValue(fmAvailable) {
            await StayClassificationInference.TestHook.$response.withValue(response) {
                await classifyAndAssembleTripsReportingChangesWithGates(
                    reclassifyRecentStays: reclassifyRecentStays,
                    maxStaysPerCall: maxStaysPerCall, gate: gate)
            }
        }
    }
    #endif

    let logger = Logger(subsystem: "com.travellog.app", category: "TripClassifier")

    /// Maximum stays to send to Foundation Models in one batch.
    /// With ~30 tokens per stay in the prompt and ~40 per classification in output,
    /// 20 stays uses ~1400 tokens - safely within the 4096 limit.
    let maxBatchSize = 20

    /// Number of chronological-neighbour stays rendered as settled context
    /// on each side of a batch's timeline span in the classification prompt.
    let promptContextSpan = 3

    /// Per-pass classification provenance is stamped from each trip's freshly classified stays;
    /// a trip with no stays classified this pass retains its existing AI flag.
    var fmClassifiedStayIDs: Set<UUID> = []
    var heuristicClassifiedStayIDs: Set<UUID> = []
    var visitBackedStayIDs: Set<UUID> = []

    /// Whether any stage of the current pipeline pass changed data —
    /// gates the widget-timeline reload in the
    /// `classifyAndAssembleTrips*WithGates` entry points.
    var lastPipelineMadeChanges = false

    /// Whether the back half (sanity-check → assemble → close) has completed a
    /// full, non-cancelled pass since this process launched. The first pass
    /// each launch always runs the back half (baseline heal); after that it is
    /// dirty-gated. See the gate in `runPipelineStagesWithGates`.
    var hasRunBackHalfSinceLaunch = false

    /// Set when a back-half summary recompute could not read the home-place
    /// index; the back half then throws into its unit's rollback.
    var summaryHomePlacesUnreadable = false

    /// Set by the last temporary-home unit that cleared a generated title for
    /// Stage 5; its wrapper then runs the title stage.
    var temporaryHomeUnitClearedTitle = false

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

    /// True until the first complete back-half pass of this launch. The
    /// Trips list reads it to decide whether an upcoming run is visible work.
    func baselinePassPending() -> Bool { !hasRunBackHalfSinceLaunch }

    /// Prevents concurrent pipeline runs from overlapping views (TripsListView,
    /// StatusDashboardView, StaysListView all trigger the pipeline on appear).
    var isRunning = false
    /// Canonical title inference is intentionally independent from the
    /// deterministic pipeline latch: it runs outside PipelineGate and lands
    /// through short CAS units. A small single-flight guard prevents two UI/
    /// background triggers from duplicating Foundation Models work.
    var isGeneratingTitles = false
    enum PendingTitleGeneration {
        case finite(Int)
        case drainAll
    }
    /// A trigger arriving during a pass is not equivalent to duplicate work:
    /// it may follow a semantic invalidation that was absent from the current
    /// candidate snapshot. The owner performs one merged follow-up pass.
    var pendingTitleGeneration: PendingTitleGeneration?
    /// Delete Calendar Data owns the canonical-title namespace from its
    /// atomic clear through its no-calendar refill. Ordinary Stage 5 must not
    /// reintroduce an EventKit-derived title inside that privacy boundary.
    var isCalendarTitleWipeRunning = false
    #if DEBUG
    var titleGenerationOverrideForTesting:
        (@Sendable (UUID) async -> String?)?
    var failCanonicalHomeInputFetchForTesting = false
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

    func readFailureContextHasChangesForTesting() -> Bool { modelContext.hasChanges }

    func setTitleGenerationOverrideForTesting(
        _ override: (@Sendable (UUID) async -> String?)?
    ) {
        titleGenerationOverrideForTesting = override
    }

    func setCanonicalHomeInputFetchFailureForTesting(_ shouldFail: Bool) {
        failCanonicalHomeInputFetchForTesting = shouldFail
    }

    func failHomeAreaHealingFetchCallForTesting(_ call: Int) {
        homeAreaHealingFetchCallCountForTesting = 0
        failingHomeAreaHealingFetchCallForTesting = call
    }

    func failNextUnHomeStaysSaveForTesting() {
        shouldFailNextUnHomeStaysSaveForTesting = true
    }

    var shouldFailNextReconciliationSaveForTesting = false
    nonisolated(unsafe) var failReconciliationStayReadForTesting = false

    func failNextReconciliationSaveForTesting() {
        shouldFailNextReconciliationSaveForTesting = true
    }
    #endif

    #if DEBUG
    var calendarWipeWaitingForLatchForTesting = false
    var calendarWipeAfterClearOverrideForTesting:
        (@Sendable () async -> Void)?

    /// Test seam for holding the pipeline latch while a calendar wipe queues.
    func setRunningLatchForTesting(_ running: Bool) {
        isRunning = running
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

    func setCalendarWipeAfterClearOverrideForTesting(
        _ override: (@Sendable () async -> Void)?
    ) {
        calendarWipeAfterClearOverrideForTesting = override
    }

    func titlePromptMaterialForTesting(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil
    ) -> TitlePromptMaterial? {
        guard let trip = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier) else { return nil }
        return titlePromptMaterial(for: trip)
    }

    func canonicalTitleShapeForTesting(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil
    ) -> CanonicalTitleShape? {
        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier),
              let activeHomes = try? fetchCanonicalActiveHomeInputs(),
              let homeNames = try? homePlaceNames(for: trip) else {
            return nil
        }
        return canonicalTitleShape(
            for: trip,
            activeHomes: activeHomes,
            homePlaceNames: homeNames)
    }

    func canonicalTitleFailureKeyForTesting(
        _ shape: CanonicalTitleShape
    ) -> String {
        titleFailureKey(for: shape)
    }

    func canonicalTitleSourceStateForTesting(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil
    ) -> CanonicalTitleSourceState? {
        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier) else { return nil }
        return canonicalTitleSourceState(for: trip)
    }

    func applyTitleGenerationForTesting(
        _ title: String?,
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        expectedShape: CanonicalTitleShape,
        expectedSourceState: CanonicalTitleSourceState
    ) -> Int {
        applyTitleGeneration(
            title,
            tripID: tripID,
            tripIdentifier: tripIdentifier,
            expectedShape: expectedShape,
            expectedSourceState: expectedSourceState,
            failureKey: titleFailureKey(for: expectedShape))
    }

    enum CanonicalApplyLaneForTesting: CaseIterable, Sendable {
        case forced
        case regenerated
    }

    func applyCanonicalTitleForTesting(
        _ title: String,
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        expectedShape: CanonicalTitleShape,
        expectedSourceState: CanonicalTitleSourceState,
        lane: CanonicalApplyLaneForTesting
    ) -> Bool {
        switch lane {
        case .forced:
            return applyForcedCanonicalTitle(
                title,
                tripID: tripID,
                tripIdentifier: tripIdentifier,
                expectedShape: expectedShape,
                expectedSourceState: expectedSourceState,
                allowCustomName: false,
                invalidateVariantsEvenIfUnchanged: false)
        case .regenerated:
            return applyRegeneratedTitle(
                title,
                tripID: tripID,
                tripIdentifier: tripIdentifier,
                expectedShape: expectedShape,
                expectedSourceState: expectedSourceState)
        }
    }

    func titleAttemptCountForTesting(
        _ shape: CanonicalTitleShape
    ) -> Int {
        sessionTitleAttemptCount[titleFailureKey(for: shape)] ?? 0
    }

    func markCanonicalTitleFailureForTesting(
        _ shape: CanonicalTitleShape
    ) {
        let key = titleFailureKey(for: shape)
        sessionTitleAttemptCount[key] = Self.titleAttemptThreshold
        markPersistentTitleFailure(key)
    }

    func hasCanonicalTitleFailureForTesting(
        _ shape: CanonicalTitleShape
    ) -> Bool {
        let key = titleFailureKey(for: shape)
        return sessionTitleAttemptCount[key] != nil
            || persistentTitleFailures.contains(key)
    }

    func healUserEditedOpenTripTitlesForTesting(
        changedStayIDs: Set<UUID>
    ) {
        fmClassifiedStayIDs = changedStayIDs
        heuristicClassifiedStayIDs = []
        try? healUserEditedOpenTripSummaries()
    }
    #endif

    /// Last homecoming confirmation request, process-local because only this device accompanies the user.
    var lastHomecomingConfirmationRequest: Date?

    /// Per-session failure counter, not persisted. Cleared on actor init
    /// (i.e., on app launch). A trip needs `titleAttemptThreshold`
    /// consecutive failures in the SAME session to be moved to the
    /// persistent failure set — survives transient ANE inference errors
    /// across launches.
    var sessionTitleAttemptCount: [String: Int] = [:]

    /// Loaded once from UserDefaults on first access via the
    /// `persistentTitleFailures` accessor. Mutations go through
    /// `markPersistentTitleFailure` / `clearPersistentTitleFailure` /
    /// `clearAllPersistentTitleFailures` which write back to UserDefaults.
    var _persistentTitleFailures: Set<String>?

    // MARK: - Main Entry Point

    /// What an explicit rebuild committed. UI success (dismissing the
    /// Enhance card) follows `.completed` only.
    nonisolated enum RebuildOutcome: Sendable, Equatable {
        /// The reset, every classification unit and the replacement committed.
        /// A batch discarded because its inputs changed (ordinary CAS work)
        /// does not withhold completion: its unattached planned stays stay
        /// unclassified for the next ordinary pass, as outside a rebuild.
        case completed
        /// A required read or save failed, a unit rolled back, or a thermal
        /// stop left the pass unfinished. Units committed before the failure
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
        while isRunning {
            logger.debug("Pipeline running; reclassification queued.")
            #if DEBUG
            QueueTestHook.waiting?()
            #endif
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return .cancelled }
        }
        isRunning = true
        defer { isRunning = false }

        let rebuild = await gate.runReturning(touching: [.stay, .trip]) {
            await self.reclassifyAllCore()
        }
        guard let rebuild else { return Task.isCancelled ? .cancelled : .failed }
        let pass = await runPipelineStagesWithGates(maxStaysPerCall: nil, gate: gate, rebuild: rebuild)
        // `plannedPending` alone is not a failure: the replacement committed,
        // and a live writer (clustering, locality enrichment) routinely
        // obsoletes a window during a long rebuild.
        guard pass.completed else { return Task.isCancelled ? .cancelled : .failed }
        // Titles follow a committed rebuild only; their own retry budgets
        // cover model failures, so they do not decide the outcome.
        _ = await generateTitlesStage(
            maxTripsPerCall: nil,
            sampling: .greedy,
            applyGate: gate)
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

    #if DEBUG
    var orbitDerivationCountForTesting = 0

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

    /// With temporary homes, a suppressed verdict also rests on inputs no fingerprint
    /// holds: a temporary home's dates decide which runs it may score, and where the
    /// tripless stays sit relative to its area decides where a run closes. This digest
    /// of them, written with the memo, must still match before the memo excuses
    /// anything. Nil when the pass had no temporary home (or suppressed nothing).
    var gateSuppressionInputDigest: SHA256.Digest?

    /// Run classification and assembly; returns the number of new trips.
    /// reclassifyRecentStays revisits the latest five journey stays with fresh context; imports disable it.
    /// maxStaysPerCall bounds Stage 2 work for UI callers; nil drains the backlog.
    /// Call outside PipelineGate: this owns its gate units, and inference, retries, and thermal waits must not hold the writer queue.
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
    /// committed and no planned stays were left unclassified. Zero new trips
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
        // No await may separate the loop exit from acquiring the actor-isolated latch.
        while waitingForInFlight, isRunning {
            logger.debug("Pipeline running; reporting classification waits.")
            #if DEBUG
            QueueTestHook.waiting?()
            #endif
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return (0, false, false) }
        }
        guard !isRunning else { return (0, false, false) }
        isRunning = true
        defer { isRunning = false }
        let result = await runPipelineStagesWithGates(reclassifyRecentStays: reclassifyRecentStays,
            maxStaysPerCall: maxStaysPerCall, gate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return (result.created, result.needsPublication, result.completed && !result.plannedPending)
    }

    /// Event-driven finalization (home-area healing) that must not be
    /// dropped behind an in-flight pass: queue outside any gate, as the other
    /// explicit actions do, and report whether the whole pass committed.
    /// False on cancellation, a failed required read or save, a thermal stop,
    /// a Stage 2 unit that could not apply, or planned stays a discarded
    /// unit left unclassified, so the caller keeps its completion stamp and
    /// retries on the next trigger.
    func classifyAndAssembleTripsQueuedWithGates(
        maxStaysPerCall: Int? = nil,
        gate: PipelineGate = .shared
    ) async -> Bool {
        // No await may separate the loop exit from acquiring the actor-isolated latch.
        guard !Task.isCancelled else { return false }
        while isRunning {
            logger.debug("Pipeline running; queued classification waits.")
            #if DEBUG
            QueueTestHook.waiting?()
            #endif
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return false }
        }
        isRunning = true
        defer { isRunning = false }
        let result = await runPipelineStagesWithGates(maxStaysPerCall: maxStaysPerCall, gate: gate)
        if lastPipelineMadeChanges {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return result.completed && !result.plannedPending
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
        clearAllCanonicalTitlesForCalendarWipe()
    }
    #endif

    /// Cap distinct groups after merging, not stays, so destinations with many observations cannot consume the prompt budget.
    let maxGroupsInTitlePrompt = 20

}
