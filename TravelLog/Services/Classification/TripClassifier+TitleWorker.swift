//
//  TripClassifier+TitleWorker.swift
//  TravelLog
//
//  The title worker: every title write outside Stage 5 (the detail
//  screen's ensure, the per-trip refresh, Settings' regenerate all, and the
//  calendar wipe's refill) runs here instead of under the classifier latch,
//  so a title's inference never holds classification. Each trip's
//  generation is a job keyed by its row, its exact input shape and its
//  mode; a request matching a job in flight joins it. Every job lands
//  through the same compare-and-swap units as before, which discard a title
//  whose trip, source or shape changed meanwhile.
//

import Foundation
import SwiftData
import FoundationModels
import WidgetKit

extension TripClassifier {

    /// How a job generates its title and lands it.
    nonisolated enum TitleJobMode: Hashable, Sendable {
        /// The detail screen's ensure: greedy, inside the retry budget, and
        /// only into an empty title.
        case ensure
        /// The per-trip refresh: sampled, replacing the title only on success.
        case regenerate
        /// Settings' regenerate all: greedy, replacing the title only on
        /// success and never under a custom name.
        case replace
        /// The calendar wipe's refill: greedy, writing the fallback (or nil)
        /// when generation fails.
        case calendarRefill
    }

    struct TitleJobKey: Hashable, Sendable {
        let tripIdentifier: PersistentIdentifier
        /// `titleFailureKey(for:)` of the job's input: the trip and its exact shape.
        let shape: String
        let mode: TitleJobMode
    }

    struct TitleJobResult: Sendable {
        var changed = false
        /// The title the job wrote; nil when it wrote none or cleared one.
        var title: String?
        /// The trip was deleted while the job ran.
        var tripGone = false
    }

    struct TitleJob {
        let task: Task<TitleJobResult, Never>
        var waiters: Int
    }

    /// Admits one title operation: waits while the calendar wipe owns the
    /// title namespace, then counts the operation in, so the wipe's clear
    /// waits for it in turn. False on cancellation. The caller counts it
    /// out with `titleOperations -= 1`.
    func admitTitleOperation() async -> Bool {
        while isCalendarTitleWipeRunning || isCalendarTitleWipeQueued {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled else { return false }
        titleOperations += 1
        return true
    }

    /// Runs `input`'s job for `mode`, or joins the one in flight for the
    /// same row, shape and mode. A cancelled caller stops waiting for the
    /// job's value only once it lands; the job itself is cancelled when its
    /// last waiter is.
    func runTitleJob(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier,
        input: PreparedCanonicalTitleInput,
        mode: TitleJobMode,
        gate: PipelineGate
    ) async -> TitleJobResult {
        let key = TitleJobKey(
            tripIdentifier: tripIdentifier, shape: titleFailureKey(for: input.shape), mode: mode)
        let task: Task<TitleJobResult, Never>
        if let job = titleJobs[key] {
            task = job.task
            titleJobs[key]?.waiters += 1
        } else {
            task = Task {
                await self.performTitleJob(
                    tripID: tripID, tripIdentifier: tripIdentifier, input: input,
                    failureKey: key.shape, mode: mode, gate: gate)
            }
            titleJobs[key] = TitleJob(task: task, waiters: 1)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leaveTitleJob(key, task: task) }
        }
        if titleJobs[key]?.task == task { titleJobs[key] = nil }
        return result
    }

    private func leaveTitleJob(_ key: TitleJobKey, task: Task<TitleJobResult, Never>) {
        guard var job = titleJobs[key], job.task == task else { return }
        job.waiters -= 1
        if job.waiters > 0 {
            titleJobs[key] = job
        } else {
            titleJobs[key] = nil
            task.cancel()
        }
    }

    private func performTitleJob(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier,
        input: PreparedCanonicalTitleInput,
        failureKey: String,
        mode: TitleJobMode,
        gate: PipelineGate
    ) async -> TitleJobResult {
        guard let current = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier) else {
            return TitleJobResult(tripGone: true)
        }
        // An ensure whose shape spent its retry budget lands the fallback without inferring again.
        let outcome = mode == .ensure && persistentTitleFailures.contains(failureKey)
            ? CanonicalTitleGenerationOutcome.failed
            : await generateTitle(for: current, mode: mode, input: input)
        guard !Task.isCancelled else { return TitleJobResult() }
        // Fetched again: a classification unit may have deleted and saved
        // the row while the model ran, and the held model must not be read.
        guard let trip = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier) else {
            return TitleJobResult(tripGone: true)
        }

        switch mode {
        case .ensure:
            let title: String?
            switch outcome {
            case .success(let generated): title = generated
            case .failed: title = nil
            case .unavailable, .cancelled, .discarded: return TitleJobResult()
            }
            let changed = await gate.runReturning(touching: [.trip]) {
                await self.applyTitleGeneration(
                    title,
                    tripID: tripID,
                    tripIdentifier: tripIdentifier,
                    expectedShape: input.shape,
                    expectedSourceState: input.sourceState,
                    failureKey: failureKey)
            }
            if changed > 0 {
                await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
            }
            return TitleJobResult(changed: changed > 0, title: title)
        case .regenerate:
            guard case .success(let title) = outcome else { return TitleJobResult() }
            let applied = await gate.runReturning(touching: [.trip]) {
                await self.applyRegeneratedTitle(
                    title,
                    tripID: tripID,
                    tripIdentifier: tripIdentifier,
                    expectedShape: input.shape,
                    expectedSourceState: input.sourceState)
            }
            return TitleJobResult(changed: applied, title: applied ? title : nil)
        case .replace, .calendarRefill:
            let replacement: String?
            switch outcome {
            case .success(let title):
                replacement = title
            case .failed where mode == .calendarRefill:
                // The apply unit's shape check pins this same home-place set.
                replacement = computeFallbackTitle(for: trip, homePlaceNames: input.homePlaceNames)
            case .failed, .unavailable, .cancelled, .discarded:
                return TitleJobResult()
            }
            let refill = mode == .calendarRefill
            let changed = await gate.runReturning(touching: [.trip]) {
                await self.applyForcedCanonicalTitle(
                    replacement,
                    tripID: tripID,
                    tripIdentifier: tripIdentifier,
                    expectedShape: input.shape,
                    expectedSourceState: input.sourceState,
                    allowCustomName: refill,
                    invalidateVariantsEvenIfUnchanged: refill)
            }
            return TitleJobResult(changed: changed, title: replacement)
        }
    }

    /// `generateOneTitle`; an ensure takes the test override when one is installed.
    private func generateTitle(
        for trip: Trip,
        mode: TitleJobMode,
        input: PreparedCanonicalTitleInput
    ) async -> CanonicalTitleGenerationOutcome {
        #if DEBUG
        if mode == .ensure, let titleGenerationOverrideForTesting {
            let tripID = trip.id
            guard let title = await titleGenerationOverrideForTesting(tripID) else { return .failed }
            return .success(title)
        }
        #endif
        let sampling: GenerationOptions.SamplingMode = mode == .regenerate
            ? .random(probabilityThreshold: 0.85) : .greedy
        return await generateOneTitle(for: trip, sampling: sampling, input: input)
    }
}
