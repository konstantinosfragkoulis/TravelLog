//
//  HomeAreaHealing.swift
//  TravelLog
//
//  Retroactive healing runs
//  exactly when the home-area fingerprint moves — an override was added,
//  removed, or synced in (and when the derived orbit set
//  changes). Event-driven glue over the tested classifier seams
//  (`homeAreaFingerprint` / `healHomeAreaCorrections`); no timer, no BG
//  task. The fingerprint lives in UserDefaults, DEVICE-LOCAL on purpose:
//  healing is idempotent, so two devices converging independently is safe,
//  and a restored device simply heals once against its restored store.
//
//  Ordering contract: the fingerprint is stamped only AFTER the healing
//  unit ran, so a crash mid-heal re-arms rather than silently skipping.
//

import Foundation
import SwiftData
import WidgetKit

@MainActor
enum HomeAreaHealing {

    static let fingerprintKey = "homeAreaHealingFingerprint_v1"
    /// The previous pass's learned/taught coverage geometry (JSON-encoded
    /// `[CoverageDisc]`). This is the shrink arm's memory: derived discs
    /// are deliberately not persisted anywhere else, so when one
    /// de-qualifies, this snapshot is the only record of where it used to
    /// claim.
    static let coverageKey = "homeAreaCoverageSnapshot_v1"
    /// When `coverageKey` was last stamped. Diagnostics only (the Debug
    /// Diagnostics screen shows the snapshot's age); nothing in the healing
    /// logic reads it.
    static let coverageStampedAtKey = "homeAreaCoverageSnapshotAt_v1"
    /// Set when a heal starts for a moved fingerprint and cleared only by the
    /// stamp. The fingerprint can move back before a pass stamps (a same-id
    /// cohort healing deferred converges during the finalizing pass), and
    /// then the old stamp equals the input again: this debt keeps the heal
    /// owed until a pass stamps it.
    static let owedKey = "homeAreaHealingOwed_v1"

    /// The compare-and-heal collaborators. Production uses `.live`; focused
    /// tests substitute the post-heal stages so they can pin orchestration
    /// without touching the app singleton store or WidgetKit.
    struct Stages {
        var rescue: @MainActor @Sendable () async -> Void
        var fingerprint: @MainActor @Sendable () async -> String?
        var heal: @MainActor @Sendable (
            [TripClassifier.CoverageDisc]
        ) async -> TripClassifier.HomeAreaHealingOutcome
        var drainParked: @MainActor @Sendable () async -> [DissolvedTripRecord]
        /// True only when the finalizing pass committed; the stamps wait for it.
        var classify: @MainActor @Sendable () async -> Bool
        var generateTitles: @MainActor @Sendable () async -> Void
        var coverage: @MainActor @Sendable () async throws
            -> [TripClassifier.CoverageDisc]
        var bumpChanges: @MainActor @Sendable () -> Void
        var reloadWidgets: @MainActor @Sendable () -> Void

        static var live: Stages {
            Stages(
                rescue: { await HomeAreaHealing.rescueIfNeeded() },
                fingerprint: {
                    await AppDelegate.tripClassifier.homeAreaFingerprint()
                },
                heal: { staleCoverage in
                    await PipelineGate.shared.runReturning(
                        touching: [.stay, .trip]
                    ) {
                        let pinned = await MainActor.run {
                            PinnedTripsStorage.shared.pinnedIDs
                        }
                        return await AppDelegate.tripClassifier.healHomeAreaCorrections(
                            pinnedTripIDs: pinned,
                            staleCoverage: staleCoverage)
                    }
                },
                drainParked: {
                    await AppDelegate.tripClassifier.drainParkedDissolvedTrips()
                },
                classify: {
                    // Queue behind an in-flight pass instead of being dropped.
                    await AppDelegate.tripClassifier.classifyAndAssembleTripsQueuedWithGates(
                        maxStaysPerCall: nil)
                },
                generateTitles: {
                    _ = await AppDelegate.tripClassifier.generateTitlesStage(
                        maxTripsPerCall: nil)
                    _ = await AppDelegate.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                },
                coverage: {
                    try await AppDelegate.tripClassifier.homeAreaCoverage()
                },
                bumpChanges: {
                    StoreChangeTracker.shared.bump([.stay, .trip])
                },
                reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }
            )
        }
    }

    /// Compare-and-heal. Unchanged input costs one projected stay scan + digest
    /// compare, plus home/override reads; when the fingerprint moved, dissolve newly-claimed trips,
    /// free stays the OLD coverage stranded, and re-run the pipeline so the
    /// freed stays re-judge. False when the fingerprint was unreadable, so a heal may be owed,
    /// or the heal unit or coverage read failed, so it is. True means this maintenance
    /// unit finished: the stamps are then written only if the finalizing classification
    /// also completed and the input did not move meanwhile; otherwise both stay stale and
    /// the next trigger heals again. Classification keeps its own triggers and does not
    /// withhold the post-import token.
    @discardableResult
    static func healIfNeeded(
        defaults: UserDefaults = .standard,
        stages: Stages = .live
    ) async -> Bool {
        // The dissolve queue's auto-rescue runs BEFORE the fingerprint
        // guard: a late-arriving pin changes no fingerprint, but it must
        // still bring the parked trip back (the KVS-dissolve race). Cheap
        // when the queue is empty.
        await stages.rescue()

        // An unreadable fingerprint is not an unchanged one: heal and stamp nothing.
        guard let current = await stages.fingerprint() else { return false }
        guard defaults.string(forKey: fingerprintKey) != current
                || defaults.bool(forKey: owedKey) else { return true }
        // Owed from here until a stamp: whatever the input reads as after
        // this run, a heal that did not stamp runs again.
        defaults.set(true, forKey: owedKey)

        let staleCoverage = (defaults.data(forKey: coverageKey))
            .flatMap { try? JSONDecoder().decode(
                [TripClassifier.CoverageDisc].self, from: $0) } ?? []
        // Pins are snapshotted INSIDE the unit: this unit can queue
        // behind a long import, and a favorite made during that wait
        // must protect its trip.
        let outcome = await stages.heal(staleCoverage)
        // A failure with no committed work needs no finalization. When an
        // earlier shrink disc already saved, however, reclassify and publish
        // that durable work while still leaving BOTH stamps untouched so the
        // fingerprint mismatch re-arms this heal on the next trigger.
        guard !outcome.failed || outcome.moved > 0 else { return false }
        // The classifier's pre-save sink already made every parked record
        // durable: a dissolve whose record it could not persist never saves.
        // Drained only to release them. Appending again here, outside the
        // gate, could restore records a Delete All Data or a Forget in
        // between had removed. Only the DEBUG heal log reads the count.
        #if DEBUG
        let parked = await stages.drainParked()
        #else
        _ = await stages.drainParked()
        #endif
        if outcome.moved > 0 {
            stages.bumpChanges()
        }
        // Re-run the pipeline on EVERY fingerprint change, not only when
        // something moved: a membership SHRINK (an excluded learned place,
        // a removed include) frees no trips here — healing never re-cuts —
        // but the gate must re-judge the suppressed residue against the new
        // membership, and freed `.unclassified` stays from a dissolve need
        // their `.home` re-stamp. Both happen in the normal pass.
        let classified = await stages.classify()
        await stages.generateTitles()
        // Stamp AFTER the pass, and reload widgets only once the freed
        // stays are re-judged: stamping (or reloading) between the dissolve
        // and the re-stamp would publish a store where healed stays are
        // `.unclassified` — widget counts visibly dip, and a kill in the
        // window leaves a fingerprint that says "done" over unfinished work.
        //
        // COVERAGE FIRST, fingerprint second: the
        // coverage call awaits a re-prime, and a kill between the two must
        // re-arm (mismatched fingerprint → harmless re-heal), never leave a
        // "done" fingerprint over a stale coverage snapshot — that snapshot
        // is the shrink arm's only memory, and a silently stale one strands
        // `.home` stays with no signal.
        //
        // A skipped, failed or cancelled classification is unfinished work
        // too: freed stays may still be `.unclassified`, so no stamp may say
        // "done". Nor may one describe inputs that moved while the pass was
        // queued; the old snapshot then stays so the next heal can shrink.
        var maintained = false
        if !outcome.failed,
           let coverage = try? JSONEncoder().encode(
                try await stages.coverage()) {
            maintained = true
            if classified, await stages.fingerprint() == current {
                defaults.set(coverage, forKey: coverageKey)
                defaults.set(Date.now, forKey: coverageStampedAtKey)
                defaults.set(current, forKey: fingerprintKey)
                defaults.removeObject(forKey: owedKey)
                #if DEBUG
                DebugHealLog.record(DebugHealLog.Entry(
                    at: .now, kind: "heal", tripsDissolved: outcome.moved,
                    recordsParked: parked.count, tripsRestored: 0))
                #endif
            }
        }
        stages.bumpChanges()
        if outcome.moved > 0 {
            stages.reloadWidgets()
        }
        return maintained
    }

    /// Auto-restore parked dissolved trips a late-arriving guard now
    /// protects (pin synced from another device, hidden/pinned photo row
    /// delivered late). Called at every `healIfNeeded` entry AND directly
    /// from `PinnedTripsStorage`'s external-change observer, so a remote
    /// pin rescues its trip within seconds of landing — no fingerprint
    /// change required. Cheap no-op while the queue is empty.
    static func rescueIfNeeded() async {
        // File read off-main: this runs on every activation heal.
        // A split archive comes back only through Keep as One Trip.
        let records = await Task.detached(priority: .utility) {
            DissolvedTripQueue.load().filter { !$0.isSplitRecord }
        }.value
        guard !records.isEmpty else { return }

        // Cheap guarded-precheck BEFORE taking the gate: pins are free on
        // the MainActor, and the annotation lookup is an ungated read-only
        // fetch bounded by the record ids. A queue full of unguarded
        // records must not cost a gate unit on every heal entry (the
        // gate's prime directive).
        let recordIDs = Set(records.map(\.id))
        let pinnedHit = !PinnedTripsStorage.shared.pinnedIDs.isDisjoint(with: recordIDs)
        var annotationHit = false
        if !pinnedHit {
            let ids = Array(recordIDs)
            let context = ModelContext(AppDelegate.modelContainer)
            let hidden = (try? context.fetchCount(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { ids.contains($0.tripID) }))) ?? 0
            let pinnedPhotos = (try? context.fetchCount(FetchDescriptor<PinnedPhoto>(
                predicate: #Predicate { ids.contains($0.tripID) }))) ?? 0
            annotationHit = hidden > 0 || pinnedPhotos > 0
        }
        guard pinnedHit || annotationHit else { return }

        let outcome = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .hiddenPhoto, .pinnedPhoto]) {
            let pinned = await MainActor.run { PinnedTripsStorage.shared.pinnedIDs }
            return await AppDelegate.tripClassifier.rescueDissolvedTrips(
                records, pinnedTripIDs: pinned)
        }
        #if DEBUG
        DebugHealLog.record(DebugHealLog.Entry(
            at: .now, kind: "rescue", tripsDissolved: 0, recordsParked: 0,
            tripsRestored: outcome.restored.count))
        #endif
        // Prune the permanently-dead guarded records alongside the restored
        // ones — a record whose trip is already back (or whose stays belong
        // to a newer trip) would otherwise sit in the review list forever
        // and retry on every heal. A trip already back got the record's
        // photo rows committed first, so drop its stale photo cache.
        // An id whose other archive stays queued keeps both until it settles.
        let done = Set(outcome.restored).union(outcome.prunable).subtracting(outcome.unsettled)
        guard !done.isEmpty || !outcome.restored.isEmpty else { return }
        if !done.isEmpty { try? DissolvedTripQueue.remove(ids: done) }
        for record in records
        where outcome.prunable.contains(record.id) && record.carriesPhotoAnnotations {
            PhotoService.shared.invalidateCache(for: record.id)
        }
        if !outcome.restored.isEmpty {
            StoreChangeTracker.shared.bump([.stay, .trip, .hiddenPhoto, .pinnedPhoto])
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Keep as One Trip for the views (Removed Trips, a temporary home's split
    /// trips): the gated unit, which works from the queued archive and, once
    /// it committed, pins the trip's favourite again and records the commit;
    /// then the change published, the record removed and the pass that
    /// regroups the other stays of the pieces it replaced. A record whose
    /// removal fails is only removed by the next Keep: what the user did since
    /// stays. The pass queues behind one in flight instead of being dropped;
    /// if it fails, the stays it would have regrouped are classified and
    /// tripless, so the next pass's assembly check sees them and regroups them.
    /// `removedTemporaryHomeIDs` marks a removal's own Keep (`keepSplitTrips`).
    static func keepSplitTrip(
        _ record: DissolvedTripRecord,
        classifier: TripClassifier = AppDelegate.tripClassifier,
        gate: PipelineGate = .shared,
        pins: PinnedTripsStorage = .shared,
        queueDirectory: URL? = nil,
        removedTemporaryHomeIDs: Set<UUID>? = nil
    ) async -> TripClassifier.KeepSplitOutcome {
        let outcome = await classifier.keepSplitTripWhole(
            record, pinnedTripIDs: { pins.pinnedIDs }, gate: gate, queueDirectory: queueDirectory,
            removedTemporaryHomeIDs: removedTemporaryHomeIDs, pin: { pins.pin($0) })
        guard outcome == .kept else { return outcome }
        StoreChangeTracker.shared.bump([.temporaryHome, .stay, .trip, .hiddenPhoto, .pinnedPhoto])
        WidgetCenter.shared.reloadAllTimelines()
        // Outside the gate: a split that ran since may have archived the kept
        // trip again under its id, and only the spent record goes.
        try? DissolvedTripQueue.removeKeptRecord(id: record.id, in: queueDirectory)
        _ = await classifier.classifyAndAssembleTripsQueuedWithGates(maxStaysPerCall: nil, gate: gate)
        _ = await classifier.generateTitlesStage(maxTripsPerCall: nil, applyGate: gate)
        return .kept
    }

    /// A removal's Keep as One Trip: `keepSplitTrip` on each committed split
    /// archive of these removed temporary homes whose Keep has not committed,
    /// one at a time, each checked again inside its gate. A blocked or missing
    /// one stays in Removed Trips. Call outside any gate.
    /// - Returns: the removed ids whose putting back could not finish (the
    ///   queue unreadable, or a Keep that failed), for the next drain to retry.
    @discardableResult
    static func keepSplitTrips(
        splitBy removedIDs: Set<UUID>,
        classifier: TripClassifier = AppDelegate.tripClassifier,
        gate: PipelineGate = .shared,
        pins: PinnedTripsStorage = .shared,
        queueDirectory: URL? = nil
    ) async -> Set<UUID> {
        let records: [DissolvedTripRecord]
        do {
            records = try DissolvedTripQueue.loadThrowing(from: queueDirectory).filter { record in
                record.splitByTemporaryHomeID.map { removedIDs.contains($0) } == true
                    && record.splitCommitted == true && record.keepCommitted != true
            }
        } catch {
            return removedIDs
        }
        var unfinished: Set<UUID> = []
        for record in records {
            let outcome = await keepSplitTrip(
                record, classifier: classifier, gate: gate, pins: pins, queueDirectory: queueDirectory,
                removedTemporaryHomeIDs: removedIDs)
            if outcome == .saveFailed, let id = record.splitByTemporaryHomeID { unfinished.insert(id) }
        }
        return unfinished
    }
}
