//
//  TripClassifier+TitleGeneration.swift
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

extension TripClassifier {

    // MARK: - Stage 5: AI Trip Title Generation

    /// Public entry: regenerate every trip's `aiGeneratedTitle` from scratch
    /// (greedy sampling). Used by the Settings "Regenerate Trip Titles"
    /// button. Preserves `customName` and `userEdited` flags on trips —
    /// only the AI-suggested title is touched. Returns the number of titles
    /// successfully (re)generated.
    @discardableResult
    func clearAndRegenerateAllTitles(
        locale: Locale = .current,
        gate: PipelineGate = .shared
    ) async -> Int {
        // Explicit regeneration queues behind the pipeline, as reclassifyAll does.
        while isRunning {
            guard !Task.isCancelled else { return 0 }
            logger.debug("Pipeline running; title regeneration queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return 0 }
        }
        isRunning = true
        defer { isRunning = false }

        return await forceRegenerateCanonicalTitles(
            replaceOnGenerationFailure: false,
            gate: gate
        )
    }

    /// Calendar deletion clears all locales, including legacy event-derived titles; only refill is language-gated.
    /// Hold the classifier latch across clear and refill so an in-flight title cannot repopulate the cleared namespace.
    /// The revocation marker finishes right after the clear commits, so a kill during the slow refill does not repeat the wipe.
    nonisolated struct CalendarTitleWipeResult: Sendable, Equatable {
        let cleared: Bool
        let revocationFinished: Bool
        let generated: Int
    }

    @discardableResult
    func clearThenRegenerateAllTitlesForCalendarWipe(
        locale: Locale = .current,
        gate: PipelineGate = .shared,
        finishRevocationAfterClear: @Sendable () -> Bool = { true }
    ) async -> CalendarTitleWipeResult {
        while isRunning || isGeneratingTitles || isCalendarTitleWipeRunning {
            guard !Task.isCancelled else {
                return CalendarTitleWipeResult(cleared: false, revocationFinished: false, generated: 0)
            }
            #if DEBUG
            calendarWipeWaitingForLatchForTesting = true
            #endif
            logger.debug("Pipeline running; calendar title wipe queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                #if DEBUG
                calendarWipeWaitingForLatchForTesting = false
                #endif
                return CalendarTitleWipeResult(cleared: false, revocationFinished: false, generated: 0)
            }
        }
        #if DEBUG
        calendarWipeWaitingForLatchForTesting = false
        #endif
        isRunning = true
        isCalendarTitleWipeRunning = true
        defer {
            isCalendarTitleWipeRunning = false
            isRunning = false
        }

        // Revocation is all-or-nothing: remove every potentially
        // calendar-derived live title and copied Wrapped name in one short
        // transaction before slow refill work. Recaps keep their counts and
        // use post-clear names even if regeneration is cancelled or fails.
        let cleared = await gate.runReturning(touching: [.trip, .yearWrapped]) {
            await self.clearAllCanonicalTitlesForCalendarWipe()
        }
        guard cleared else {
            return CalendarTitleWipeResult(cleared: false, revocationFinished: false, generated: 0)
        }
        // Nothing Calendar-derived remains, so the durable marker can finish
        // now; if it cannot, the next launch retries the whole revocation.
        let revocationFinished = finishRevocationAfterClear()

        #if DEBUG
        if let calendarWipeAfterClearOverrideForTesting {
            await calendarWipeAfterClearOverrideForTesting()
        }
        #endif

        let generated = await forceRegenerateCanonicalTitles(
            replaceOnGenerationFailure: true,
            gate: gate
        )
        return CalendarTitleWipeResult(
            cleared: true, revocationFinished: revocationFinished, generated: generated)
    }

    func clearAllCanonicalTitlesForCalendarWipe() -> Bool {
        do {
            let trips = try modelContext.fetch(FetchDescriptor<Trip>()).filter { !$0.isDeleted }
            var replacements: [String: Set<String>] = [:]
            var namesByStart: [Date: Set<String>] = [:]
            let customNames = Set(trips.compactMap(\.customName).filter { !$0.isEmpty })
            for trip in trips {
                // Retain aliases before deleting variants, including a title
                // copied into a recap before the user assigned a custom name.
                var previousNames = [trip.displayName]
                previousNames += [trip.aiGeneratedTitle].compactMap { $0 }
                previousNames += (trip.localizedTitles ?? []).filter { !$0.isDeleted }.map(\.title)
                _ = TripTitleStore.replaceCanonicalTitle(
                    nil,
                    for: trip,
                    in: modelContext,
                    invalidateVariantsEvenIfUnchanged: true)
                let name = trip.displayName
                for previous in previousNames + [name] {
                    replacements[previous, default: []].insert(name)
                }
                namesByStart[trip.startDate, default: []].insert(name)
            }
            try scrubWrappedNamesForCalendarWipe(
                replacements: replacements, namesByStart: namesByStart, customNames: customNames)
            #if DEBUG
            if failNextCalendarTitleWipeClearForTesting {
                failNextCalendarTitleWipeClearForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
            // Also reject computes begun after PlannedTrip deletion but
            // before this transaction removed the live calendar titles.
            StatsSnapshotStore.clear()
            return true
        } catch {
            modelContext.rollback()
            logger.error("Calendar title wipe save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Runs in the live-title clear transaction, with no await or nested gate.
    /// Old blobs contain names/dates, not trip IDs or title provenance. Keep
    /// verifiable custom names; ambiguous or missing trips use the neutral label.
    private func scrubWrappedNamesForCalendarWipe(
        replacements: [String: Set<String>],
        namesByStart: [Date: Set<String>],
        customNames: Set<String>
    ) throws {
        let fallback = String(localized: "trip.display-name.fallback", defaultValue: "Trip")
        func replacement(_ name: String, start: Date? = nil) -> String {
            if let start, let names = namesByStart[start], names.count == 1, let current = names.first {
                return current
            }
            if customNames.contains(name) { return name }
            if let names = replacements[name], names.count == 1, let current = names.first {
                return current
            }
            return fallback
        }
        for row in try modelContext.fetch(FetchDescriptor<YearWrapped>()) where !row.isDeleted {
            if let data = row.statsData {
                // A blob that stays unreadable after the card salvage renders on no
                // build, and its text cannot be inspected. Failing here would block
                // this privacy deletion on every retry and every launch resume, so
                // the recap goes with the data it may have copied.
                guard var stats = WrappedStats.decoded(from: data) else {
                    logger.error("Calendar title wipe: deleting the unreadable \(row.year) recap.")
                    modelContext.delete(row)
                    continue
                }
                stats.longestTripName = stats.longestTripName.map { replacement($0) }
                stats.rainiestTripName = stats.rainiestTripName.map { replacement($0) }
                if case let .shortestTrip(name, days) = stats.mysteryFact {
                    stats.mysteryFact = .shortestTrip(name: replacement(name), days: days)
                }
                stats.mysteryFactText = nil
                if let inputs = stats.narrativeInputs {
                    stats.narrativeInputs = NarrativeInputs(
                        year: inputs.year,
                        tripDisplayNames: inputs.tripDisplayNames.enumerated().map { index, name in
                            replacement(name, start: inputs.tripStartDates.indices.contains(index)
                                ? inputs.tripStartDates[index] : nil)
                        },
                        tripStartDates: inputs.tripStartDates,
                        longestTripName: inputs.longestTripName.map { replacement($0) },
                        longestTripDays: inputs.longestTripDays,
                        farthestPlaceName: inputs.farthestPlaceName,
                        farthestDistanceKm: inputs.farthestDistanceKm,
                        firstTimeCountryISOCodes: inputs.firstTimeCountryISOCodes)
                }
                row.statsData = try JSONEncoder().encode(stats)
            }
            // Structured inputs rerender in the viewer's language. Legacy
            // FM prose cannot be safely edited; nil uses the existing card/share fallback.
            row.yearNarrative = nil
            row.yearNarrativeSourceRaw = nil
        }
    }

    /// Standalone refill entry for callers whose titles are already cleared.
    @discardableResult
    func regenerateAllTitles(
        gate: PipelineGate = .shared
    ) async -> Int {
        while isRunning {
            guard !Task.isCancelled else { return 0 }
            logger.debug("Pipeline running; title regeneration queued.")
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return 0 }
        }
        isRunning = true
        defer { isRunning = false }

        return await generateTitlesStage(
            maxTripsPerCall: nil,
            sampling: .greedy,
            applyGate: gate
        )
    }

    /// Manual regeneration replaces existing titles only after successful inference, preserving them on failure.
    /// Calendar deletion clears first to revoke legacy event text, then permits deterministic fallbacks or nil for unnameable rows.
    private func forceRegenerateCanonicalTitles(
        replaceOnGenerationFailure: Bool,
        gate: PipelineGate
    ) async -> Int {
        sessionTitleAttemptCount.removeAll()
        clearAllPersistentTitleFailures()

        let model = SystemLanguageModel.default
        let canGenerate = FMLanguagePolicy.canonicalTitlesEligible(
            fmAvailable: model.availability == .available,
            supportsLocale: { model.supportsLocale($0) })
        if !canGenerate && !replaceOnGenerationFailure {
            logger.info("Title regeneration skipped: canonical English model unavailable.")
            return 0
        }

        let descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        guard let trips = try? modelContext.fetch(descriptor) else { return 0 }

        var changed = 0
        for trip in trips {
            if Task.isCancelled { break }
            if ProcessInfo.processInfo.thermalState == .critical { break }
            guard !trip.isDeleted else { continue }

            // A custom name remains verbatim and needs no hidden replacement.
            // Calendar deletion still clears its hidden generated title so
            // revoking calendar data is complete if the custom name is removed.
            let hasCustomName = trip.customName?.isEmpty == false
            if hasCustomName && !replaceOnGenerationFailure { continue }

            let generationOutcome: CanonicalTitleGenerationOutcome
            let expectedShape: CanonicalTitleShape
            let expectedSourceState: CanonicalTitleSourceState
            let expectedHomePlaceNames: Set<String>
            if canGenerate && !hasCustomName {
                guard let input = prepareCanonicalTitleInput(
                    for: trip,
                    ) else {
                    continue
                }
                expectedShape = input.shape
                expectedSourceState = input.sourceState
                expectedHomePlaceNames = input.homePlaceNames
                generationOutcome = await generateOneTitle(
                    for: trip,
                    sampling: .greedy,
                    input: input)
            } else {
                // Unreadable inputs never clear or replace a title.
                guard let activeHomes = try? fetchCanonicalActiveHomeInputs(),
                      let homeNames = try? homePlaceNames(for: trip) else {
                    continue
                }
                expectedShape = canonicalTitleShape(
                    for: trip,
                    activeHomes: activeHomes,
                    homePlaceNames: homeNames)
                expectedSourceState = canonicalTitleSourceState(for: trip)
                expectedHomePlaceNames = homeNames
                generationOutcome = .failed
            }
            guard !Task.isCancelled, !trip.isDeleted else { break }

            let replacement: String?
            switch generationOutcome {
            case .success(let newTitle):
                replacement = newTitle
            case .failed where replaceOnGenerationFailure && !hasCustomName:
                // The apply unit's shape check pins this same home-place set.
                replacement = computeFallbackTitle(
                    for: trip, homePlaceNames: expectedHomePlaceNames)
            case .failed where replaceOnGenerationFailure:
                replacement = nil
            case .failed, .unavailable, .cancelled, .discarded:
                continue
            }

            let tripID = trip.id
            let tripIdentifier = trip.persistentModelID
            let didChange = await gate.runReturning(touching: [.trip]) {
                await self.applyForcedCanonicalTitle(
                    replacement,
                    tripID: tripID,
                    tripIdentifier: tripIdentifier,
                    expectedShape: expectedShape,
                    expectedSourceState: expectedSourceState,
                    allowCustomName: replaceOnGenerationFailure,
                    invalidateVariantsEvenIfUnchanged: replaceOnGenerationFailure)
            }
            // The public result is the number of titles successfully
            // generated, not the number of rows mutated. Calendar-data
            // deletion may legitimately clear an unnameable hidden title;
            // that cleanup is durable but is not a regenerated title.
            if didChange, replacement != nil { changed += 1 }

            if ProcessInfo.processInfo.thermalState == .serious {
                try? await Task.sleep(for: .seconds(2))
            }
            await Task.yield()
        }
        return changed
    }

    func applyForcedCanonicalTitle(
        _ title: String?,
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        expectedShape: CanonicalTitleShape,
        expectedSourceState: CanonicalTitleSourceState,
        allowCustomName: Bool,
        invalidateVariantsEvenIfUnchanged: Bool
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier),
              shapeStillMatches(expectedShape, trip: trip),
              sourceStillMatches(expectedSourceState, trip: trip),
              allowCustomName || trip.customName?.isEmpty != false else {
            return false
        }
        let changed = TripTitleStore.replaceCanonicalTitle(
            title,
            for: trip,
            in: modelContext,
            invalidateVariantsEvenIfUnchanged: invalidateVariantsEvenIfUnchanged)
        guard changed else { return false }
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            logger.error("Forced title regeneration save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Detail-screen priority lane for a legacy or newly imported trip that
    /// has never received its canonical English title. Unlike explicit
    /// regeneration this is idempotent, greedy, and respects the ordinary
    /// retry budget. It exists so a trip opened directly from Spotlight or an
    /// App Intent does not depend on the Trips list having appeared first.
    func ensureCanonicalTitle(
        for tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        gate: PipelineGate = .shared
    ) async -> String? {
        func currentEligibleTrip() -> Trip? {
            guard let trip = fetchTrip(
                tripID: tripID, tripIdentifier: tripIdentifier),
                  trip.customName?.isEmpty != false else { return nil }
            return trip
        }

        if let existing = currentEligibleTrip(),
           let title = TripTitleStore.normalized(existing.aiGeneratedTitle) {
            return title
        }

        let model = SystemLanguageModel.default
        guard FMLanguagePolicy.canonicalTitlesEligible(
            fmAvailable: model.availability == .available,
            supportsLocale: { model.supportsLocale($0) }) else {
            return nil
        }

        while isRunning {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return nil }
            if let existing = currentEligibleTrip(),
               let title = TripTitleStore.normalized(existing.aiGeneratedTitle) {
                return title
            }
        }
        isRunning = true
        defer { isRunning = false }

        guard let trip = currentEligibleTrip(),
              let input = prepareCanonicalTitleInput(for: trip) else { return nil }
        let physicalIdentifier = trip.persistentModelID
        let failureKey = titleFailureKey(for: input.shape)
        let isExhausted = persistentTitleFailures.contains(failureKey)
        let generatedTitle = isExhausted
            ? CanonicalTitleGenerationOutcome.failed
            : await generateOneTitle(
                for: trip,
                sampling: .greedy,
                input: input)
        guard !Task.isCancelled, !trip.isDeleted else { return nil }
        let titleToApply: String?
        switch generatedTitle {
        case .success(let title): titleToApply = title
        case .failed: titleToApply = nil
        case .unavailable, .cancelled, .discarded: return nil
        }

        let changed = await gate.runReturning(touching: [.trip]) {
            await self.applyTitleGeneration(
                titleToApply,
                tripID: tripID,
                tripIdentifier: physicalIdentifier,
                expectedShape: input.shape,
                expectedSourceState: input.sourceState,
                failureKey: failureKey)
        }
        if changed > 0 {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }

        return currentEligibleTrip().flatMap {
            TripTitleStore.normalized($0.aiGeneratedTitle)
        }
    }

    /// Public entry: regenerate a single trip's title using a non-greedy
    /// sampler so the second attempt is different from the deterministic
    /// auto pass. Used by the per-trip refresh button in `TripDetailView`.
    /// Returns the new title, or nil if AI was unavailable / the result
    /// failed validation.
    func regenerateTitle(
        for tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        locale: Locale = .current,
        gate: PipelineGate = .shared
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard FMLanguagePolicy.canonicalTitlesEligible(
            fmAvailable: model.availability == .available,
            supportsLocale: { model.supportsLocale($0) }) else { return nil }
        guard !isRunning else {
            logger.debug("Pipeline already running, skipping per-trip title regen.")
            return nil
        }
        isRunning = true
        defer { isRunning = false }

        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier) else {
            return nil
        }
        let physicalIdentifier = trip.persistentModelID

        // Explicit per-trip refresh resets exhaustion so later automatic passes may retry too.
        clearSessionTitleFailures(tripID)
        clearPersistentTitleFailure(tripID)

        guard let input = prepareCanonicalTitleInput(for: trip) else { return nil }
        let generationOutcome = await generateOneTitle(
            for: trip,
            sampling: .random(probabilityThreshold: 0.85),
            input: input)
        guard !Task.isCancelled,
              case .success(let newTitle) = generationOutcome else { return nil }

        let applied = await gate.runReturning(touching: [.trip]) {
            await self.applyRegeneratedTitle(
                newTitle,
                tripID: tripID,
                tripIdentifier: physicalIdentifier,
                expectedShape: input.shape,
                expectedSourceState: input.sourceState)
        }
        return applied ? newTitle : nil
    }

    func applyRegeneratedTitle(
        _ title: String,
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        expectedShape: CanonicalTitleShape,
        expectedSourceState: CanonicalTitleSourceState
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier),
              shapeStillMatches(expectedShape, trip: trip),
              sourceStillMatches(expectedSourceState, trip: trip) else {
            return false
        }
        _ = TripTitleStore.replaceCanonicalTitle(title, for: trip, in: modelContext)
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            logger.error("Per-trip title regeneration save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Share the production predicate with StageFivePredicateShapeTests because SwiftData translates nil-coalescing comparisons at runtime.
    nonisolated static func untitledTripsPredicate() -> Predicate<Trip> {
        #Predicate<Trip> {
            ($0.customName ?? "") == "" && ($0.aiGeneratedTitle ?? "") == ""
        }
    }

    /// As in Stage 2, nil drains all and a finite limit bounds foreground inference attempts.
    @discardableResult
    func generateTitlesStage(
        maxTripsPerCall: Int?,
        sampling: GenerationOptions.SamplingMode = .greedy,
        applyGate: PipelineGate = .shared
    ) async -> Int {
        guard !isCalendarTitleWipeRunning else {
            logger.debug("Canonical title generation deferred during calendar-data wipe.")
            return 0
        }
        if isGeneratingTitles {
            mergePendingTitleGeneration(maxTripsPerCall)
            logger.debug("Canonical title generation already running; queued a follow-up pass.")
            return 0
        }
        isGeneratingTitles = true
        defer { isGeneratingTitles = false }
        pendingTitleGeneration = nil

        var totalGenerated = 0
        var nextLimit = maxTripsPerCall
        repeat {
            totalGenerated += await generateTitlesPass(
                maxTripsPerCall: nextLimit,
                sampling: sampling,
                applyGate: applyGate)
            guard !Task.isCancelled,
                  let pending = pendingTitleGeneration else { break }
            pendingTitleGeneration = nil
            switch pending {
            case .finite(let limit): nextLimit = limit
            case .drainAll: nextLimit = nil
            }
        } while !isCalendarTitleWipeRunning
        return totalGenerated
    }

    private func mergePendingTitleGeneration(_ limit: Int?) {
        let incoming: PendingTitleGeneration = limit.map {
            .finite(max(0, $0))
        } ?? .drainAll
        switch (pendingTitleGeneration, incoming) {
        case (.drainAll, _), (_, .drainAll):
            pendingTitleGeneration = .drainAll
        case (.finite(let existing), .finite(let new)):
            pendingTitleGeneration = .finite(max(existing, new))
        case (nil, .finite(let new)):
            pendingTitleGeneration = .finite(new)
        }
    }

    private func generateTitlesPass(
        maxTripsPerCall: Int?,
        sampling: GenerationOptions.SamplingMode,
        applyGate: PipelineGate
    ) async -> Int {

        // Bail early if Apple Intelligence is unavailable. The fallback is
        // simply "leave aiGeneratedTitle nil", which `Trip.displayName` then
        // resolves to `destinationSummary` — the legacy concatenation.
        let model = SystemLanguageModel.default
        let canGenerate: Bool
        #if DEBUG
        if titleGenerationOverrideForTesting != nil {
            canGenerate = true
        } else {
            canGenerate = FMLanguagePolicy.canonicalTitlesEligible(
                fmAvailable: model.availability == .available,
                supportsLocale: { model.supportsLocale($0) })
        }
        #else
        canGenerate = FMLanguagePolicy.canonicalTitlesEligible(
            fmAvailable: model.availability == .available,
            supportsLocale: { model.supportsLocale($0) })
        #endif
        guard canGenerate else {
            logger.info("Stage 5 skipped: Foundation Models unavailable.")
            return 0
        }

        // All-transit trips share detail-generation prompt and grounding fallbacks; title newest trips first.
        // Push name checks into the predicate to avoid materializing the titled library on steady-state passes.
        let descriptor = FetchDescriptor<Trip>(
            predicate: Self.untitledTripsPredicate(),
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard var candidates = try? modelContext.fetch(descriptor) else { return 0 }
        candidates = candidates.filter { trip in
            // Skip user-named trips entirely — their `customName` always
            // wins in `displayName`, so generating an AI title would just
            // burn tokens for an invisible field.
            if let custom = trip.customName, !custom.isEmpty { return false }
            if let existing = trip.aiGeneratedTitle, !existing.isEmpty { return false }
            if trip.orderedStays.isEmpty { return false }
            return true
        }
        guard !candidates.isEmpty else { return 0 }

        logger.info("Stage 5: titling \(candidates.count) trip(s) via Foundation Models.")
        var generated = 0
        var attempted = 0
        titleLoop: for trip in candidates {
            // Mirror Stage 2's pre-iter cooperative checks. Foundation
            // Models inference doesn't observe Task.isCancelled reliably
            // mid-call, so we check between calls.
            if Task.isCancelled {
                logger.info("Stage 5: cancelled after \(generated) of \(candidates.count) titles.")
                break
            }
            if ProcessInfo.processInfo.thermalState == .critical {
                logger.warning("Stage 5: thermal .critical after \(generated) of \(candidates.count) titles; stopping.")
                break
            }
            if let cap = maxTripsPerCall, attempted >= cap { break }
            // Re-check availability mid-run — Apple Intelligence can
            // disappear (reboot, settings toggle, system pressure).
            let stillAvailable: Bool
            #if DEBUG
            if titleGenerationOverrideForTesting != nil {
                stillAvailable = true
            } else {
                stillAvailable = FMLanguagePolicy.canonicalTitlesEligible(
                    fmAvailable: SystemLanguageModel.default.availability == .available,
                    supportsLocale: { SystemLanguageModel.default.supportsLocale($0) })
            }
            #else
            stillAvailable = FMLanguagePolicy.canonicalTitlesEligible(
                fmAvailable: SystemLanguageModel.default.availability == .available,
                supportsLocale: { SystemLanguageModel.default.supportsLocale($0) })
            #endif
            if !stillAvailable {
                logger.warning("Stage 5: Foundation Models became unavailable mid-run after \(generated) titles.")
                break
            }

            guard let input = prepareCanonicalTitleInput(for: trip) else { continue }
            let failureKey = titleFailureKey(for: input.shape)
            // Retry exhaustion belongs to exact semantic inputs, so membership, place, or home changes receive a fresh bounded budget.
            if persistentTitleFailures.contains(failureKey) { continue }
            attempted += 1
            let generationOutcome: CanonicalTitleGenerationOutcome
            #if DEBUG
            if let titleGenerationOverrideForTesting {
                if let title = await titleGenerationOverrideForTesting(trip.id) {
                    generationOutcome = .success(title)
                } else {
                    generationOutcome = .failed
                }
            } else {
                generationOutcome = await generateOneTitle(
                    for: trip,
                    sampling: sampling,
                    input: input)
            }
            #else
            generationOutcome = await generateOneTitle(
                for: trip,
                sampling: sampling,
                input: input)
            #endif

            // Cancellation must not consume the retry budget; a later trigger may retry.
            if Task.isCancelled {
                logger.info("Stage 5: cancelled after \(generated) of \(candidates.count) titles.")
                break
            }

            // Recheck liveness after inference because concurrent destructive units can invalidate the model;
            // never read a deleted trip's ID or spend its retry budget.
            guard !trip.isDeleted else { continue }

            let titleToApply: String?
            switch generationOutcome {
            case .success(let title):
                titleToApply = title
            case .failed:
                titleToApply = nil
            case .unavailable:
                logger.info("Stage 5: temporary model condition; retrying on a later trigger without spending title budget.")
                break titleLoop
            case .cancelled:
                break titleLoop
            case .discarded:
                continue
            }

            let tripID = trip.id
            let tripIdentifier = trip.persistentModelID
            let applied = await applyGate.runReturning(touching: [.trip]) {
                await self.applyTitleGeneration(
                    titleToApply,
                    tripID: tripID,
                    tripIdentifier: tripIdentifier,
                    expectedShape: input.shape,
                    expectedSourceState: input.sourceState,
                    failureKey: failureKey)
            }
            generated += applied

            // Cool the SoC if heat is building.
            if ProcessInfo.processInfo.thermalState == .serious {
                try? await Task.sleep(for: .seconds(2))
            }
            // Release the actor's executor so the UI can render.
            await Task.yield()
        }
        if generated > 0 {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return generated
    }

    /// Apply one completed Stage-5 attempt. The Settings regeneration path
    /// calls this inside a short `PipelineGate` unit after FM returns.
    /// Re-fetching by ID makes concurrent delete/rename/reclassification win
    /// over the stale pre-FM candidate snapshot.
    func applyTitleGeneration(
        _ newTitle: String?,
        tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        expectedShape: CanonicalTitleShape,
        expectedSourceState: CanonicalTitleSourceState,
        failureKey: String
    ) -> Int {
        guard !Task.isCancelled else { return 0 }
        // NO destination requirement here: all-transit trips are deliberate
        // Stage-5 candidates (`buildTitlePrompt` and `ungroundedTitleFailure`
        // both carry an all-transit fallback — "better some title than
        // nothing"), and `untitledTripsPredicate` admits them.
        guard let trip = fetchTrip(
            tripID: tripID, tripIdentifier: tripIdentifier),
              let validatedHomePlaceNames = matchingHomePlaceNames(expectedShape, trip: trip),
              sourceStillMatches(expectedSourceState, trip: trip),
              trip.customName?.isEmpty != false,
              trip.aiGeneratedTitle?.isEmpty != false else {
            return 0
        }

        var generated = 0
        var nextAttemptCount: Int?
        var shouldClearPersistentFailure = false
        var shouldMarkPersistentFailure = false
        if let newTitle {
            _ = TripTitleStore.replaceCanonicalTitle(
                newTitle, for: trip, in: modelContext)
            generated = 1
            shouldClearPersistentFailure = true
        } else {
            // Failure (AI error, validator rejection, oversized output,
            // empty output, ANE inference error). Track per-session attempts;
            // once at threshold, write the deterministic fallback so the trip
            // exits the candidate pool.
            let attempts = (sessionTitleAttemptCount[failureKey] ?? 0) + 1
            nextAttemptCount = attempts
            let alreadyExhausted = persistentTitleFailures.contains(failureKey)
            if attempts >= Self.titleAttemptThreshold || alreadyExhausted {
                if let fallback = installFallbackTitle(
                    for: trip, homePlaceNames: validatedHomePlaceNames) {
                    generated = 1
                    logger.info("Stage 5: wrote deterministic fallback title '\(fallback)' for trip \(trip.id) after \(attempts) attempt(s).")
                } else {
                    logger.info("Stage 5: AI failed for trip \(trip.id) after \(attempts) attempt(s); no fallback computable, leaving aiGeneratedTitle nil.")
                }
                shouldMarkPersistentFailure = true
            }
        }

        // Per-trip save → incremental @Query updates → list view animates in
        // titles one at a time instead of dumping the batch at the end.
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            logger.error("Stage 5 per-trip save failed: \(error.localizedDescription)")
            return 0
        }

        // Retry bookkeeping describes durable state. Update it only after the
        // title/fallback transaction commits so a transient store failure does
        // not suppress a title that was never actually persisted.
        if shouldClearPersistentFailure {
            clearSessionTitleFailures(trip.id)
            clearPersistentTitleFailure(trip.id)
        } else if let nextAttemptCount {
            sessionTitleAttemptCount[failureKey] = nextAttemptCount
            if shouldMarkPersistentFailure {
                markPersistentTitleFailure(failureKey)
            }
        }
        return generated
    }

    /// Writes the deterministic fallback as the canonical title of a trip
    /// whose input shape spent its retry budget. Returns it, or nil when none
    /// is computable and the title stays nil. The caller saves.
    func installFallbackTitle(
        for trip: Trip, homePlaceNames: Set<String>
    ) -> String? {
        guard let fallback = computeFallbackTitle(
            for: trip, homePlaceNames: homePlaceNames) else { return nil }
        _ = TripTitleStore.replaceCanonicalTitle(fallback, for: trip, in: modelContext)
        return fallback
    }

    /// Only quality failures spend retry budget; temporary unavailability does not.
    /// Give validation one same-session retry naming the violation because an identical greedy prompt reproduces the rejected output.
    private func generateOneTitle(
        for trip: Trip,
        sampling: GenerationOptions.SamplingMode,
        input: PreparedCanonicalTitleInput
    ) async -> CanonicalTitleGenerationOutcome {
        let tripID = trip.id
        guard !Task.isCancelled else { return .cancelled }
        guard !trip.isDeleted,
              shapeStillMatches(input.shape, trip: trip),
              sourceStillMatches(input.sourceState, trip: trip) else {
            return .discarded
        }
        let prompt = input.prompt
        let instructions = TripTitlePolicy.titleInstructions
        // The decode grammar is the candidate list itself (`TripTitleSchema`):
        // the model cannot return a name the prompt did not offer. A list
        // with a single admissible string has no choice in it, so the title
        // is that string without a model turn; an empty list has nothing to
        // choose from and is a failure the fallback handles.
        let choices = TripTitleSchema.choices(for: input.candidates)
        guard !choices.isEmpty else {
            logger.warning("No title candidates for trip \(tripID); nothing to ask the model.")
            return .failed
        }
        // Each validation below follows a passing shape check with no
        // suspension between, so the frozen stays are the trip's current ones.
        let stays = input.shape.trip.stays
        if choices.count == 1 {
            let only = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: [choices[0]], candidates: input.candidates, titleSpellings: input.titleSpellings))
            guard let failure = TripTitlePolicy.titleValidationFailure(
                only, stays: stays, homePlaceNames: input.homePlaceNames) else {
                return .success(only)
            }
            logger.warning("Single title candidate '\(only)' for trip \(tripID) rejected (\(String(describing: failure))).")
            return .failed
        }
        let options = GenerationOptions(samplingMode: sampling, maximumResponseTokens: 200)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let places = try await TripTitleSchema.respond(
                session: session, prompt: prompt,
                candidates: input.candidates, options: options)
            guard !Task.isCancelled else { return .cancelled }
            // The model chose places; the code joins them. Defensive
            // normalization still runs: a chosen name occasionally arrives
            // wrapped in quotes or markdown.
            let stripped = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: places, candidates: input.candidates, titleSpellings: input.titleSpellings))
            // The multi-second FM await is the widest deletion window in
            // this method: the shape check below reads the trip's stays.
            guard !trip.isDeleted,
                  shapeStillMatches(input.shape, trip: trip),
                  sourceStillMatches(input.sourceState, trip: trip) else {
                return .discarded
            }
            guard let failure = TripTitlePolicy.titleValidationFailure(
                stripped, stays: stays, homePlaceNames: input.homePlaceNames) else {
                #if DEBUG
                DebugFMStatus.recordSuccess(feature: "Trip title")
                #endif
                return .success(stripped)
            }

            // Retry once in the same session with the violation named so greedy decoding receives corrective context.
            logger.warning("AI title '\(stripped)' for trip \(tripID) rejected (\(String(describing: failure))); retrying with the violation named.")
            let retryPlaces = try await TripTitleSchema.respond(
                session: session,
                prompt: "Your previous choice was rejected because the title it made (\"\(stripped)\") \(failure.promptFragment). Choose again, using only the place names listed in the prompt above.",
                candidates: input.candidates, options: options)
            guard !Task.isCancelled else { return .cancelled }
            let retryStripped = TripTitlePolicy.normalizeAITitle(TripTitlePolicy.composeCanonicalTitle(
                places: retryPlaces, candidates: input.candidates, titleSpellings: input.titleSpellings))
            guard !trip.isDeleted,
                  shapeStillMatches(input.shape, trip: trip),
                  sourceStillMatches(input.sourceState, trip: trip) else {
                return .discarded
            }
            if TripTitlePolicy.titleValidationFailure(
                retryStripped, stays: stays, homePlaceNames: input.homePlaceNames) == nil {
                #if DEBUG
                DebugFMStatus.recordSuccess(feature: "Trip title", detail: "after one retry")
                #endif
                return .success(retryStripped)
            }
            logger.warning("AI title retry also rejected for trip \(tripID); giving up this attempt.")
            return .failed
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            logger.error("Title generation failed for trip \(tripID): \(error.localizedDescription)")
            #if DEBUG
            DebugFMStatus.recordFailure(
                feature: "Trip title",
                message: "\(error.localizedDescription) — \(String(describing: error))")
            #endif
            if let disposition = FMErrorClassifier.disposition(of: error) {
                switch disposition {
                case .permanent: return .failed
                case .transient: return .unavailable
                }
            }
            if case .available = SystemLanguageModel.default.availability {
                return .failed
            }
            return .unavailable
        }
    }

    /// Resolve the exact SwiftData row when a caller already has one. The
    /// UUID-only fallback is retained for older orchestration APIs, while
    /// batch and detail title lanes carry the physical identifier so two
    /// CloudKit rows sharing an app UUID cannot receive each other's title.
    func fetchTrip(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier?
    ) -> Trip? {
        if let tripIdentifier,
           let trip = modelContext.model(for: tripIdentifier) as? Trip,
           !trip.isDeleted,
           trip.id == tripID {
            return trip
        }
        guard tripIdentifier == nil else { return nil }
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        return try? modelContext.fetch(
            FetchDescriptor<Trip>(predicate: predicate)).first
    }
}
