//
//  ForegroundClassificationDrain.swift
//  TravelLog
//
//  Keeps classifying in the foreground after an import, and on activation
//  and cold launch, until the backlog is empty: one bounded bite at a time,
//  after the stays' inbound legs (flight or not) are classified.
//  Each bite is an ordinary pipeline pass with its own gate units and the
//  classifier latch only while it runs, assembly included, so live saves
//  and queued explicit actions run between bites. The drain stops when the
//  app leaves the foreground, under serious thermal pressure or Low Power
//  Mode, on a failed bite or an unreadable backlog, after two bites without
//  progress, on cancellation, and for Delete All Data; the next request
//  resumes it. Committed work stands, so a resumed drain starts from the
//  stored categories. It never listens for store changes: its own bites
//  publish them.
//

import Foundation
import SwiftData
import UIKit
import os

@MainActor
final class ForegroundClassificationDrain {

    /// Stays a bite plans at most.
    nonisolated static let biteSize = 200

    nonisolated enum StopReason: Sendable, Equatable {
        case drained
        case noProgress
        case failed
        case cancelled
        /// The app left the foreground, thermal or power policy stopped it,
        /// or Delete All Data suspended it.
        case paused
        /// The backlog drained, but the inbound-leg pass reached its round
        /// cap with legs left; a trailing run continues them.
        case transitPending
    }

    /// How the inbound-leg pass ended. Only `exhausted` lets a run report
    /// `.drained`: Stats counts flights from those legs.
    nonisolated enum TransitOutcome: Sendable, Equatable {
        /// No inbound leg is left unclassified.
        case exhausted
        /// A batch failed (a read or save), or rounds made no progress.
        case failed
        /// Stopped with legs left: the unit policy, cancellation, or the
        /// round cap after progress.
        case incomplete
    }

    /// What one bite reported.
    nonisolated struct BiteOutcome: Sendable, Equatable {
        /// Every unit of the pass committed.
        var completed: Bool
        /// Stays the pass classified and committed.
        var classified: Int
    }

    nonisolated struct Environment: Sendable {
        /// `unitPolicy` is checked as each of the bite's units begins.
        var bite: @Sendable (_ maxStays: Int, _ unitPolicy: @escaping @Sendable () -> Bool) async -> BiteOutcome
        /// The unclassified, non-overridden count on a fresh context; nil when unreadable.
        var backlog: @MainActor @Sendable () -> Int?
        /// Whether a trip still waits for its generated title, on a fresh
        /// context. A run that finds nothing to classify refills them then:
        /// `titlesOwed` does not outlive the process, so a run cut short
        /// before its refill (a kill, a crash) would otherwise leave them
        /// to the Trips list's few titles per launch.
        var titlesPending: @MainActor @Sendable () -> Bool = { false }
        var titles: @Sendable () async -> Void
        /// Classifies the stays' inbound legs (flight or not) until none is
        /// left, in its own short gate units, each checking `unitPolicy`.
        var transit: @Sendable (_ unitPolicy: @escaping @Sendable () -> Bool) async -> TransitOutcome = { _ in .exhausted }
        /// Whether the app is active and `systemAllowsWork`.
        var mayRun: @MainActor @Sendable () -> Bool
        /// Neither serious thermal pressure nor Low Power Mode holds work
        /// back; read off the main actor too, as each unit begins.
        var systemAllowsWork: @Sendable () -> Bool
    }

    static let shared = ForegroundClassificationDrain(environment: .live)

    private let environment: Environment
    private let logger = Logger(subsystem: "com.travellog.app", category: "ForegroundDrain")

    private var task: Task<StopReason, Never>?
    private var requested = false
    private var suspended = false
    /// The backlog a run stopped at without progress: stays that never
    /// classify. A request finding exactly that count again starts no bite;
    /// any other count (new stays, a settled one) drains again, in bites
    /// that reach past it.
    private var stuckBacklog: Int?
    /// A run classified stays and stopped before refilling titles; the
    /// next run refills them even when it finds nothing to classify.
    private var titlesOwed = false
    private(set) var lastStop: StopReason?

    init(environment: Environment) {
        self.environment = environment
    }

    var isDraining: Bool { task != nil }

    /// Asks for a drain. A request during a run arms one trailing check.
    func request() {
        requested = true
        startIfAllowed()
    }

    /// Leaving the foreground, or Delete All Data: stop at the next boundary
    /// and start nothing until `resume()`.
    func pause() {
        suspended = true
        admission.withLock { $0 = false }
        task?.cancel()
    }

    /// Activation, cold launch, or the end of Delete All Data: allow drains
    /// again and check the backlog.
    func resume() {
        suspended = false
        admission.withLock { $0 = true }
        request()
    }

    /// Explicit cancellation: stop and drop the pending request.
    func cancel() {
        requested = false
        task?.cancel()
    }

    /// Waits for the current run and any trailing one; returns the last stop.
    func waitUntilIdle() async -> StopReason? {
        while let task { _ = await task.value }
        return lastStop
    }

    /// Whether the drain is not suspended, for a bite's units to read off
    /// the main actor as they begin.
    private nonisolated let admission = OSAllocatedUnfairLock(initialState: true)

    /// The bite a run uses: `biteSize` past a remembered stuck remainder,
    /// since the stuck stays come first in every oldest-first batch.
    var biteSize: Int {
        Self.biteSize + (stuckBacklog ?? 0)
    }

    private func startIfAllowed() {
        guard task == nil, !suspended, requested, environment.mayRun() else { return }
        requested = false
        task = Task {
            let stop = await self.run()
            self.finished(stop)
            return stop
        }
    }

    private func finished(_ stop: StopReason) {
        task = nil
        lastStop = stop
        logger.info("Foreground drain stopped: \(String(describing: stop)).")
        // A cancelled or paused run never restarts itself; a later request
        // or activation does.
        guard stop != .cancelled, stop != .paused else { return }
        startIfAllowed()
    }

    private var titlesNeeded: Bool { titlesOwed || environment.titlesPending() }

    private func refillTitles() async {
        await environment.titles()
        if !Task.isCancelled { titlesOwed = false }
    }

    private var interrupted: StopReason { suspended ? .paused : .cancelled }

    private func run() async -> StopReason {
        // Inbound legs first: classification reads them as evidence, and
        // Stats counts its flights from them. Without this an import's legs
        // were classified 50 per Trips-list pass, one pass per launch.
        let admission = admission
        let systemAllowsWork = environment.systemAllowsWork
        let transit = await environment.transit({ admission.withLock { $0 } && systemAllowsWork() })
        if Task.isCancelled { return interrupted }
        if transit == .incomplete {
            // The unit policy stopped the legs: a pause. Otherwise the round
            // cap did, after progress: a trailing run continues them.
            guard environment.mayRun() else { return .paused }
            requested = true
        }
        let stop = await classifyBacklog()
        // Classification may have drained, but legs left pending or failed
        // keep the drain from reporting it.
        guard stop == .drained else { return stop }
        switch transit {
        case .exhausted: return .drained
        case .failed: return .failed
        case .incomplete: return .transitPending
        }
    }

    /// The bites after the inbound-leg pass, and the title refill.
    private func classifyBacklog() async -> StopReason {
        let admission = admission
        let systemAllowsWork = environment.systemAllowsWork
        guard let initial = environment.backlog() else { return .failed }
        guard initial > 0 else {
            stuckBacklog = nil
            if titlesNeeded { await refillTitles() }
            return .drained
        }
        guard initial != stuckBacklog else { return .noProgress }
        let size = biteSize
        stuckBacklog = nil
        var progress = ClassificationBacklogProgress(remaining: initial, patience: 2)
        while true {
            if Task.isCancelled { return interrupted }
            guard environment.mayRun() else { return .paused }
            let outcome = await environment.bite(size, {
                admission.withLock { $0 } && systemAllowsWork()
            })
            if Task.isCancelled { return interrupted }
            // A unit that found the app backgrounded, hot or in Low Power
            // Mode stops its bite; that is a pause, not a failure.
            guard outcome.completed else { return environment.mayRun() ? .failed : .paused }
            // An unreadable count is a failure, never an empty backlog.
            guard let now = environment.backlog() else { return .failed }
            let decision = progress.record(remaining: now, classified: outcome.classified)
            if progress.progressed { titlesOwed = true }
            switch decision {
            case .continueDrain:
                await Task.yield()
            case .complete:
                if Task.isCancelled { return interrupted }
                guard environment.mayRun() else { return .paused }
                await refillTitles()
                return .drained
            case .stalled:
                // What is left never classifies; what did is settled, so
                // its trips still get their titles.
                stuckBacklog = now
                if titlesNeeded, !Task.isCancelled, environment.mayRun() {
                    await refillTitles()
                }
                return .noProgress
            }
        }
    }
}

extension ForegroundClassificationDrain {
    /// Runs inbound-leg batches until none is left. A failed batch rolled
    /// back and would refetch the same rows, so it ends the pass; a short
    /// batch that classified every leg it fetched ends it exhausted (a leg
    /// another writer moved meanwhile is fetched again). The round cap is a
    /// runaway backstop: reached after progress the pass is incomplete and
    /// continues in a trailing run, reached without any it failed.
    nonisolated static func drainTransit(
        maxRounds: Int = 400,
        unitPolicy: () -> Bool,
        batch: () async -> TransitInferer.DrainOutcome
    ) async -> TransitOutcome {
        var classified = 0
        for _ in 0..<maxRounds {
            guard !Task.isCancelled, unitPolicy() else { return .incomplete }
            let outcome = await batch()
            if outcome.failed { return .failed }
            classified += outcome.classified
            if outcome.fetched < TransitInferer.inferenceBatchSize, outcome.classified == outcome.fetched {
                return .exhausted
            }
        }
        return classified > 0 ? .incomplete : .failed
    }
}

/// The stop rule of a backlog drain, shared by the foreground drain and the
/// background refresh: done at zero, stalled after `patience` bites in a row
/// that neither classified a stay nor shrank the backlog. Concurrent
/// arrivals can replace classified rows without moving the count, so
/// committed classifications count as progress too.
nonisolated struct ClassificationBacklogProgress: Sendable {
    enum Decision: Equatable, Sendable {
        case continueDrain
        case complete
        case stalled
    }

    private(set) var remaining: Int?
    let patience: Int
    private var withoutProgress = 0
    /// Whether the last recorded bite made progress.
    private(set) var progressed = false

    init(remaining: Int? = nil, patience: Int) {
        self.remaining = remaining
        self.patience = max(1, patience)
    }

    mutating func record(remaining now: Int, classified: Int) -> Decision {
        progressed = classified > 0 || remaining.map { now < $0 } ?? true
        withoutProgress = progressed ? 0 : withoutProgress + 1
        remaining = now
        if now == 0 { return .complete }
        return withoutProgress >= patience ? .stalled : .continueDrain
    }
}

extension ForegroundClassificationDrain.Environment {
    static var live: Self {
        let systemAllowsWork: @Sendable () -> Bool = {
            let thermal = ProcessInfo.processInfo.thermalState
            return thermal != .serious && thermal != .critical
                && !ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return Self(
            bite: { maxStays, unitPolicy in
                await AppDelegate.tripClassifier.runBacklogBite(
                    maxStaysPerCall: maxStays, unitPolicy: unitPolicy)
            },
            backlog: { AppDelegate.unclassifiedStayBacklogCount() },
            titlesPending: {
                let context = ModelContext(AppDelegate.modelContainer)
                var descriptor = FetchDescriptor<Trip>(
                    predicate: TripClassifier.untitledTripsPredicate())
                descriptor.fetchLimit = 1
                // Unreadable is not "none": the refill's own pass reads again.
                return ((try? context.fetchCount(descriptor)) ?? 1) > 0
            },
            titles: {
                _ = await AppDelegate.tripClassifier.generateTitlesStage(maxTripsPerCall: nil)
                guard !Task.isCancelled else { return }
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
            },
            transit: { unitPolicy in
                // Bounded batches whose calendar evidence is gathered outside
                // the gate and applied in short gated units, so live saves
                // and deletion never wait on an EventKit query.
                await ForegroundClassificationDrain.drainTransit(unitPolicy: unitPolicy) {
                    await AppDelegate.transitInferer.inferTransitBatchOutsideGate(publishing: true)
                }
            },
            mayRun: {
                UIApplication.shared.applicationState == .active && systemAllowsWork()
            },
            systemAllowsWork: systemAllowsWork)
    }
}
