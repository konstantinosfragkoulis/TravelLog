//
//  TripTitleVariantDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// Converges duplicate localized-title rows produced by two devices before
/// CloudKit has delivered either device's write to the other.
///
/// Source-mismatched and temporarily orphaned rows are retained. CloudKit may
/// deliver a variant before its corresponding Trip field or relationship, so
/// deleting those rows immediately would make record ordering destructive.
/// They are never displayed unless the relationship exists and both source
/// text and source revision match the canonical title.
nonisolated enum TripTitleVariantDeduplicator {

    private struct LogicalKey: Hashable {
        let tripIdentifier: PersistentIdentifier
        let languageTag: String
        let sourceTitle: String
        let sourceRevision: UUID?
    }

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "TripTitleVariantDedup")
    private static let isRunning = OSAllocatedUnfairLock(initialState: false)
    static let tripBatchSize = 50

    private struct BatchOutcome: Sendable {
        let normalizedTagCount: Int
        let absorbedContentCount: Int
        let deletedCount: Int
        let succeeded: Bool

        static let failed = BatchOutcome(
            normalizedTagCount: 0,
            absorbedContentCount: 0,
            deletedCount: 0,
            succeeded: false)
    }

    /// Snapshots lightweight Trip ids, then gives each bounded Trip batch its
    /// own gate unit. Trips sharing an application UUID stay in the same batch;
    /// grouping still uses physical SwiftData identity inside that unit.
    /// False when the pass did not reach its end (single-flight, snapshot,
    /// failed batch, or cancellation with batches left).
    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        gate: PipelineGate = .shared,
        batchSize: Int = tripBatchSize
    ) async -> Bool {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return false }
        defer { isRunning.withLock { $0 = false } }

        let tripIDs: [UUID]
        do {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<Trip>()
            descriptor.propertiesToFetch = [\.id]
            tripIDs = Array(Set(try context.fetch(descriptor).map(\.id)))
                .sorted { $0.uuidString < $1.uuidString }
        } catch {
            logger.error(
                "Localized title deduplication trip snapshot failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
        guard !tripIDs.isEmpty else { return true }

        var normalizedTagCount = 0
        var absorbedContentCount = 0
        var deletedCount = 0
        let boundedBatchSize = max(1, batchSize)

        var index = 0
        while index < tripIDs.count {
            guard !Task.isCancelled else { break }
            let end = min(index + boundedBatchSize, tripIDs.count)
            let batch = Array(tripIDs[index ..< end])
            index = end
            let outcome = await gate.runReturning(touching: [.trip]) {
                deduplicateTripBatch(batch, modelContainer: modelContainer)
            }
            guard outcome.succeeded else { return false }
            normalizedTagCount += outcome.normalizedTagCount
            absorbedContentCount += outcome.absorbedContentCount
            deletedCount += outcome.deletedCount
        }

        let finished = index >= tripIDs.count
        guard normalizedTagCount > 0 || absorbedContentCount > 0
                || deletedCount > 0 else { return finished }
        logger.info(
            "Normalized \(normalizedTagCount, privacy: .public) language tag(s), absorbed \(absorbedContentCount, privacy: .public) field(s), and deduplicated \(deletedCount, privacy: .public) localized trip title row(s).")
        return finished
    }

    private static func deduplicateTripBatch(
        _ tripIDs: [UUID],
        modelContainer: ModelContainer
    ) -> BatchOutcome {
        let context = ModelContext(modelContainer)
        do {
            let predicate = #Predicate<Trip> { tripIDs.contains($0.id) }
            let trips = try context.fetch(FetchDescriptor<Trip>(
                predicate: predicate))
            let variants = trips.flatMap { $0.localizedTitles ?? [] }

            var groups: [LogicalKey: [TripTitleVariant]] = [:]
            var normalizedTagCount = 0

            for variant in variants {
                guard let trip = variant.trip,
                      let languageTag = AppLanguagePreference.normalizedSupportedTag(
                        variant.languageTag),
                      languageTag != "en",
                      TripTitleStore.normalized(variant.title) != nil,
                      TripTitleStore.normalized(variant.sourceTitle) != nil else {
                    // A nil relationship can be a CloudKit ordering window.
                    // Malformed related rows are invisible and tiny; leave
                    // them for a later pass rather than conflating the cases.
                    continue
                }
                if variant.languageTag != languageTag {
                    variant.languageTag = languageTag
                    normalizedTagCount += 1
                }
                let key = LogicalKey(
                    tripIdentifier: trip.persistentModelID,
                    languageTag: languageTag,
                    sourceTitle: variant.sourceTitle,
                    sourceRevision: variant.sourceRevision)
                groups[key, default: []].append(variant)
            }

            var losers: [TripTitleVariant] = []
            var absorbedContentCount = 0
            for (key, rows) in groups where rows.count > 1 {
                guard let survivor = rows.min(by: {
                    TripTitleStore.hasPreferredSurvivorIdentity($0, over: $1)
                }) else { continue }
                // Identity comes from every row, content only from usable
                // ones: an incomplete list ("Αθήνα και") is invisible, so it
                // must not overwrite a valid translation and then delete it.
                // A group with no usable row is left untouched for later.
                guard let contentWinner = rows.reduce(
                    nil as TripTitleVariant?,
                    { current, candidate in
                        guard TripTitleStore.isUsableVariantTitle(
                            candidate.title, languageTag: key.languageTag) else {
                            return current
                        }
                        guard let current else { return candidate }
                        return TripTitleStore.hasPreferredContent(candidate, over: current)
                            ? candidate : current
                    }) else { continue }

                // Preserve all physical twins that share the survivor UUID:
                // another device cannot distinguish which CloudKit record is
                // which. Absorb identical best content onto every twin instead.
                for row in rows where row.id == survivor.id {
                    if row.title != contentWinner.title {
                        row.title = contentWinner.title
                        absorbedContentCount += 1
                    }
                    if row.generationVersion != contentWinner.generationVersion {
                        row.generationVersion = contentWinner.generationVersion
                        absorbedContentCount += 1
                    }
                    if row.updatedAt != contentWinner.updatedAt {
                        row.updatedAt = contentWinner.updatedAt
                        absorbedContentCount += 1
                    }
                }
                losers.append(contentsOf: rows.filter { $0.id != survivor.id })
            }

            guard !losers.isEmpty || normalizedTagCount > 0
                    || absorbedContentCount > 0 else {
                return BatchOutcome(
                    normalizedTagCount: 0,
                    absorbedContentCount: 0,
                    deletedCount: 0,
                    succeeded: true)
            }
            for loser in losers { context.delete(loser) }
            try context.save()
            return BatchOutcome(
                normalizedTagCount: normalizedTagCount,
                absorbedContentCount: absorbedContentCount,
                deletedCount: losers.count,
                succeeded: true)
        } catch {
            context.rollback()
            logger.error(
                "Localized title deduplication batch failed: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }
}
