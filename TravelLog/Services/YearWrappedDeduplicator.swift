//
//  YearWrappedDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// `nonisolated` so the full-table dedup fetches really run off the main actor.
nonisolated enum YearWrappedDeduplicator {

    private static let logger = Logger(subsystem: "com.travellog.app", category: "YearWrappedDedup")
    private static let runningContainers = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let containerID = ObjectIdentifier(modelContainer)
        let alreadyRunning = runningContainers.withLock { running in
            !running.insert(containerID).inserted
        }
        guard !alreadyRunning else { return false }
        defer { _ = runningContainers.withLock { $0.remove(containerID) } }

        let context = ModelContext(modelContainer)

        do {
            let all = try context.fetch(FetchDescriptor<YearWrapped>(
                sortBy: [SortDescriptor(\.year, order: .forward)]
            ))

            guard all.count > 1 else { return true }

            var kept: [Int: YearWrapped] = [:]
            var toDelete: [YearWrapped] = []

            // Survivor rule: keep the row with the largest IMMUTABLE
            // `id.uuidString` per year. Any mutable key lets two devices order
            // the pair differently and each delete the row the other kept;
            // both deletions sync, erasing that year's recap. A regenerated
            // recap is kept by ABSORBING its content onto the survivor below,
            // not by choosing its row.
            for wrapped in all {
                if let incumbent = kept[wrapped.year] {
                    let challengerWins = wrapped.id.uuidString > incumbent.id.uuidString
                    if challengerWins {
                        kept[wrapped.year] = wrapped
                        toDelete.append(incumbent)
                    } else {
                        toDelete.append(wrapped)
                    }
                } else {
                    kept[wrapped.year] = wrapped
                }
            }

            guard !toDelete.isEmpty else { return true }

            for item in toDelete {
                // Preserve the earliest `viewedAt` onto the survivor so a
                // regenerated recap (`viewedAt == nil`) isn't re-flagged as
                // "New" / doesn't re-fire the ready banner for a year the
                // user already opened.
                if let survivor = kept[item.year], let viewed = item.viewedAt,
                   survivor.viewedAt == nil || viewed < survivor.viewedAt! {
                    survivor.viewedAt = viewed
                }
                // Absorb the NEWEST content as a field copy rather than a row
                // choice, so row IDENTITY stays keyed on the immutable id
                // (which is what makes two devices converge) while the
                // surviving row still carries the freshest narrative AND
                // stats. Copying only the narrative would leave corrected
                // stats behind.
                //
                // The whole generation-time content set moves together:
                // narrative, its source, stats, both coverage fractions and
                // generatedAt. Legacy stats (no `weatherExtremesSafe`) gate
                // the weather card on `weatherCoverage`, so leaving the
                // survivor's own coverage behind would gate the donor's
                // extremes with another generation's number.
                if let survivor = kept[item.year],
                   survivor.id != item.id,
                   (item.generatedAt, item.id.uuidString) > (survivor.generatedAt, survivor.id.uuidString) {
                    survivor.yearNarrative = item.yearNarrative
                    survivor.yearNarrativeSourceRaw = item.yearNarrativeSourceRaw
                    survivor.statsData = item.statsData
                    survivor.weatherCoverage = item.weatherCoverage
                    survivor.transitCoverage = item.transitCoverage
                    survivor.generatedAt = item.generatedAt
                }
                context.delete(item)
            }
            try context.save()

            logger.info("Deduplicated \(toDelete.count) YearWrapped row(s), kept \(kept.count) unique year(s).")
            return true
        } catch {
            logger.error("YearWrapped dedup failed: \(error.localizedDescription)")
            return false
        }
    }
}
