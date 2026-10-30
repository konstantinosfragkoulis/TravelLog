//
//  TripClassifier+TitleGeneration.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Stage 5: Trip Titles

    /// Calendar deletion revokes every title an older build may have derived
    /// from event text: each trip's generated title is derived again from its
    /// stays (its default title, `TripTitlePolicy.defaultTitle`), every
    /// localized variant goes, and copied Wrapped names are scrubbed, in one
    /// transaction. The wipe waits until no pass runs and holds the classifier
    /// latch across that transaction, so no rebuild can restore a title it
    /// snapshotted before. The revocation marker finishes right after it commits.
    nonisolated struct CalendarTitleWipeResult: Sendable, Equatable {
        let cleared: Bool
        let revocationFinished: Bool
        let generated: Int
    }

    @discardableResult
    func clearThenRegenerateAllTitlesForCalendarWipe(
        gate: PipelineGate = .shared,
        finishRevocationAfterClear: @Sendable () -> Bool = { true }
    ) async -> CalendarTitleWipeResult {
        let admitted = await takeLatchQueued(waiting: {
            #if DEBUG
            calendarWipeWaitingForLatchForTesting = true
            #endif
            logger.debug("Pipeline running; calendar title wipe queued.")
        })
        #if DEBUG
        calendarWipeWaitingForLatchForTesting = false
        #endif
        guard admitted else {
            return CalendarTitleWipeResult(cleared: false, revocationFinished: false, generated: 0)
        }
        let generated: Int?
        do {
            defer { isRunning = false }
            generated = await gate.runReturning(touching: [.trip, .yearWrapped]) {
                await self.rederiveAllCanonicalTitlesForCalendarWipe()
            }
        }
        guard let generated else {
            return CalendarTitleWipeResult(cleared: false, revocationFinished: false, generated: 0)
        }
        // Nothing Calendar-derived remains, so the durable marker can finish
        // now; if it cannot, the next launch retries the whole revocation.
        let revocationFinished = finishRevocationAfterClear()
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        return CalendarTitleWipeResult(
            cleared: true, revocationFinished: revocationFinished, generated: generated)
    }

    /// The wipe's transaction. Returns how many trips hold a generated title
    /// after it, or nil when it rolled back.
    func rederiveAllCanonicalTitlesForCalendarWipe() -> Int? {
        do {
            let trips = try modelContext.fetch(FetchDescriptor<Trip>()).filter { !$0.isDeleted }
            var replacements: [String: Set<String>] = [:]
            var namesByStart: [Date: Set<String>] = [:]
            let customNames = Set(trips.compactMap(\.customName).filter { !$0.isEmpty })
            var titled = 0
            for trip in trips {
                // Retain aliases before deleting variants, including a title
                // copied into a recap before the user assigned a custom name.
                var previousNames = [trip.displayName]
                previousNames += [trip.aiGeneratedTitle].compactMap { $0 }
                previousNames += (trip.localizedTitles ?? []).filter { !$0.isDeleted }.map(\.title)
                // An unreadable home-place set derives nothing: the title is
                // cleared, and Stage 5 derives it once the set reads.
                let title = (try? TripTitleStore.generatedTitleAlternatives(
                    for: trip, in: modelContext))?.first
                _ = TripTitleStore.replaceCanonicalTitle(
                    title,
                    for: trip,
                    in: modelContext,
                    invalidateVariantsEvenIfUnchanged: true)
                if title != nil { titled += 1 }
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
            return titled
        } catch {
            modelContext.rollback()
            logger.error("Calendar title wipe save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Runs in the wipe's title transaction, with no await or nested gate.
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

    /// The detail screen's lane for a trip that has no generated title yet
    /// (a legacy or newly imported one, or one whose home places were
    /// unreadable when it changed), so a trip opened directly from Spotlight
    /// or an App Intent does not wait for a pipeline pass. Returns the title,
    /// or nil for a custom-named trip or one with no title to give.
    func ensureCanonicalTitle(
        for tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        gate: PipelineGate = .shared
    ) async -> String? {
        if let trip = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier),
           trip.customName?.isEmpty != false,
           let title = TripTitleStore.normalized(trip.aiGeneratedTitle) {
            return title
        }
        let title = await gate.runReturning(touching: [.trip]) {
            await self.fillUntitledTrip(tripID: tripID, tripIdentifier: tripIdentifier)
        }
        if title != nil {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return title
    }

    /// One unit of `ensureCanonicalTitle`: the trip's default title, written
    /// only into an empty title of a trip with no custom name.
    private func fillUntitledTrip(tripID: UUID, tripIdentifier: PersistentIdentifier?) -> String? {
        guard !Task.isCancelled,
              let trip = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier),
              trip.customName?.isEmpty != false else { return nil }
        if let existing = TripTitleStore.normalized(trip.aiGeneratedTitle) { return existing }
        guard let title = try? TripTitleStore.generatedTitleAlternatives(
            for: trip, in: modelContext).first else { return nil }
        TripTitleStore.replaceCanonicalTitle(title, for: trip, in: modelContext)
        do {
            try modelContext.save()
            return title
        } catch {
            modelContext.rollback()
            logger.error("Trip title save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Share the production predicate with StageFivePredicateShapeTests because SwiftData translates nil-coalescing comparisons at runtime.
    nonisolated static func untitledTripsPredicate() -> Predicate<Trip> {
        #Predicate<Trip> {
            ($0.customName ?? "") == "" && ($0.aiGeneratedTitle ?? "") == ""
        }
    }

    /// The trips per Stage 5 write unit: each is a short, bounded transaction.
    static let titleUnitSize = 25

    /// Stage 5: gives every untitled trip without a custom name its default
    /// title (`TripTitlePolicy.defaultTitle`), newest first, in short gated
    /// units that each re-read their rows and write only into a title that
    /// is still empty. Titles change everywhere else in the transaction that
    /// changes their inputs (`TripTitleStore.invalidateGeneratedTitles`);
    /// this pass fills the trips that never had one (new trips, legacy and
    /// imported rows, an unreadable home-place set). A finite limit bounds
    /// the titles written; a trip with no title to give is passed over.
    /// Returns how many titles it wrote.
    @discardableResult
    func generateTitlesStage(
        maxTripsPerCall: Int?,
        applyGate: PipelineGate = .shared
    ) async -> Int {
        let descriptor = FetchDescriptor<Trip>(
            predicate: Self.untitledTripsPredicate(),
            sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        guard let fetched = try? modelContext.fetch(descriptor) else { return 0 }
        // Rows, not models: a classification unit may delete and save a
        // candidate between these units. Each unit fetches its rows again.
        var rows = fetched.compactMap { trip -> (id: UUID, identifier: PersistentIdentifier)? in
            guard !trip.isDeleted, !trip.orderedStays.isEmpty else { return nil }
            return (trip.id, trip.persistentModelID)
        }[...]
        var written = 0
        while !rows.isEmpty, !Task.isCancelled {
            let remaining = maxTripsPerCall.map { max(0, $0 - written) }
            if remaining == 0 { break }
            let unit = Array(rows.prefix(Self.titleUnitSize))
            rows = rows.dropFirst(unit.count)
            written += await applyGate.runReturning(touching: [.trip]) {
                await self.fillUntitledTrips(unit, limit: remaining)
            }
        }
        if written > 0 {
            logger.info("Stage 5: titled \(written) trip(s).")
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return written
    }

    /// One Stage 5 unit. Returns how many titles it wrote; a failed save writes none.
    private func fillUntitledTrips(
        _ rows: [(id: UUID, identifier: PersistentIdentifier)],
        limit: Int?
    ) -> Int {
        var written = 0
        for row in rows {
            if let limit, written >= limit { break }
            guard !Task.isCancelled else { break }
            guard let trip = fetchTrip(tripID: row.id, tripIdentifier: row.identifier),
                  trip.customName?.isEmpty != false,
                  TripTitleStore.normalized(trip.aiGeneratedTitle) == nil,
                  let title = try? TripTitleStore.generatedTitleAlternatives(
                    for: trip, in: modelContext).first else { continue }
            TripTitleStore.replaceCanonicalTitle(title, for: trip, in: modelContext)
            written += 1
        }
        guard written > 0 else { return 0 }
        do {
            try modelContext.save()
            return written
        } catch {
            modelContext.rollback()
            logger.error("Stage 5 save failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Resolve the exact SwiftData row when a caller already has one. The
    /// UUID-only fallback is retained for older orchestration APIs, while
    /// batch and detail title lanes carry the physical identifier so two
    /// CloudKit rows sharing an app UUID cannot receive each other's title.
    /// Always a fetch, never `model(for:)`: that hands back a registered
    /// model or a fresh fault for any identifier, including a row a
    /// classification unit deleted and saved while inference awaited, and
    /// reading such a model's properties traps. A fetch returns live rows only.
    func fetchTrip(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier?
    ) -> Trip? {
        if let tripIdentifier {
            let row = tripIdentifier
            let trip = try? modelContext.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate<Trip> { $0.persistentModelID == row })).first
            guard let trip, !trip.isDeleted, trip.id == tripID else { return nil }
            return trip
        }
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        return try? modelContext.fetch(
            FetchDescriptor<Trip>(predicate: predicate)).first
    }
}
