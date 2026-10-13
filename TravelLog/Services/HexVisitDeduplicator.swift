//
//  HexVisitDeduplicator.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 5/5/26.
//

import Foundation
import SwiftData
import os.log

/// Merges duplicate HexVisit records that arise from multi-device CloudKit sync.
///
/// When two devices visit the same H3 hex independently, each creates its own
/// HexVisit record. After CloudKit sync, both records coexist in the store.
/// This service finds duplicates (same h3Index) and merges them into one.
///
/// Deletions sync, so every replica must keep the same row or the cell can
/// converge to zero. A group is merged only when its survivor carries a
/// minted, table-unique id (`HexVisit.mintID()`), which every replica holds
/// with the same value. Plain ids (the V12 migration default, a record
/// hydrated without `CD_id`, the retired random repair) can differ between
/// replicas, so an all-plain group is left in place: a duplicate is
/// recoverable, a lost cell is not. Row identity is never rewritten here.
/// `nonisolated` so the full-table dedup fetches really run off the main actor.
nonisolated enum HexVisitDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "HexVisitDeduplicator"
    )

    /// Single-flight per container, as `YearWrappedDeduplicator` keys it: the app
    /// has one container, and tests on separate containers never collide.
    private static let runningContainers = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let containerID = ObjectIdentifier(modelContainer)
        let alreadyRunning = runningContainers.withLock { running in
            !running.insert(containerID).inserted
        }
        guard !alreadyRunning else {
            logger.debug("Deduplication already in progress, skipping.")
            return false
        }
        defer { _ = runningContainers.withLock { $0.remove(containerID) } }

        let context = ModelContext(modelContainer)

        let descriptor = FetchDescriptor<HexVisit>(
            sortBy: [SortDescriptor(\.h3Index), SortDescriptor(\.firstVisited)]
        )

        do {
            let allHexes = try context.fetch(descriptor)
            guard allHexes.count > 1 else { return true }

            // Table-wide, not per group: a migration default can be shared by
            // rows in different cells, and such a value names no single row.
            var idCounts: [UUID: Int] = [:]
            for hex in allHexes { idCounts[hex.id, default: 0] += 1 }

            var mergedCount = 0
            var skippedAmbiguous = 0
            var i = 0

            // The fetch is sorted by (h3Index, firstVisited), so rows sharing an
            // h3Index are contiguous and the first row of each group has the
            // minimum firstVisited.
            while i < allHexes.count {
                let groupStart = i
                let h3 = allHexes[groupStart].h3Index
                var groupEnd = groupStart + 1
                while groupEnd < allHexes.count && allHexes[groupEnd].h3Index == h3 {
                    groupEnd += 1
                }

                // Singleton hex → nothing to merge.
                guard groupEnd - groupStart > 1 else { i = groupEnd; continue }

                let group = allHexes[groupStart..<groupEnd]

                // Deterministic survivor across devices: the row with the
                // smallest `id`, keyed on the id ALONE. `firstVisited` is a
                // plain var that several one-device paths REWRITE before
                // propagating (`PingRecorder.upsertHexVisitForImport`,
                // `TripDataImporter`, `PhotoImportService`'s import and its
                // discard repair), so sorting on it lets two devices delete
                // each other's row. The earliest `firstVisited` is absorbed below.
                let survivor = group.min { a, b in
                    a.id.uuidString < b.id.uuidString
                }!

                // Minted ids sort before plain ones, so a plain minimum means
                // the whole group is plain: no row has an id every replica is
                // known to share, and two replicas could keep opposite rows.
                // A minted id shared by another row would name no single row
                // either. Skip both and keep the duplicates.
                // Otherwise every replica that sees the smallest minted row
                // keeps it, and a replica that has not seen it cannot delete it.
                if !HexVisit.isMintedID(survivor.id) || idCounts[survivor.id, default: 0] > 1 {
                    skippedAmbiguous += 1
                    i = groupEnd
                    continue
                }

                // Deterministic DONOR order too: min/max field
                // merges are order-independent, but the nil-fill fields
                // (locality/country) take the FIRST donor carrying a value —
                // under raw fetch order two devices could absorb different
                // labels onto the same survivor and ping-pong via CloudKit.
                // Same immutable-id key as the survivor pick, and for the same
                // reason: a mutable sort key lets two devices absorb donors in
                // different orders and ping-pong the nil-fill fields forever.
                let donors = group
                    .filter { $0.id != survivor.id }
                    .sorted { a, b in a.id.uuidString < b.id.uuidString }
                for duplicate in donors {
                    survivor.firstVisited = min(survivor.firstVisited, duplicate.firstVisited)
                    survivor.lastVisited = max(survivor.lastVisited, duplicate.lastVisited)
                    // Idempotent merge: use `max`, NOT
                    // `+=`. CloudKit can deliver the survivor's count update and
                    // the duplicate's deletion in separate pushes / out of order,
                    // so dedup re-runs (on `didReceiveRemoteNotification`) while
                    // both rows are still visible and would re-add the loser's
                    // count, inflating the survivor on every partial sync. `max`
                    // is idempotent (`max(max(a,b), b) == max(a,b)`) → converges.
                    // (Trade-off: a hex visited on two devices reports the larger
                    // per-device count, not their sum — but the sum was never a
                    // reliable cross-device total anyway, being corrupted by this
                    // same race.)
                    survivor.visitCount = max(survivor.visitCount, duplicate.visitCount)
                    if survivor.locality == nil { survivor.locality = duplicate.locality }
                    // (country, isoCountryCode) is a PAIR that must stay
                    // internally consistent — never "Norway" + "SE" — but a
                    // half-filled survivor must still be completable: a legacy
                    // row with a country name but no ISO takes the donor's ISO
                    // when the countries match, or the delete below destroys
                    // the only copy and the cell drops out of per-country
                    // Exploration counts.
                    if survivor.country == nil, survivor.isoCountryCode == nil {
                        // Empty pair → adopt the donor's pair wholesale.
                        survivor.country = duplicate.country
                        survivor.isoCountryCode = duplicate.isoCountryCode
                    } else if survivor.isoCountryCode == nil,
                              duplicate.country == nil || duplicate.country == survivor.country {
                        // Same place (or an unlabelled donor) → safe to complete.
                        survivor.isoCountryCode = duplicate.isoCountryCode
                    } else if survivor.country == nil,
                              duplicate.isoCountryCode == nil || duplicate.isoCountryCode == survivor.isoCountryCode {
                        survivor.country = duplicate.country
                    }
                    context.delete(duplicate)
                    mergedCount += 1
                }

                i = groupEnd
            }

            if mergedCount > 0 {
                try context.save()
                logger.info("Merged \(mergedCount) duplicate HexVisit record(s).")
            }
            if skippedAmbiguous > 0 {
                logger.info("Skipped \(skippedAmbiguous) HexVisit group(s) without a minted, unique survivor id; left in place to avoid cross-device convergence-to-zero.")
            }
            return true
        } catch {
            logger.error("HexVisit deduplication failed: \(error.localizedDescription)")
            return false
        }
    }
}
