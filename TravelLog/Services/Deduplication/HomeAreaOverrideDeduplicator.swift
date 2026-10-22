//
//  HomeAreaOverrideDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// Collapses duplicate `HomeAreaOverride` rows from CloudKit sync — the same
/// correction tapped on two devices, or one device's tap arriving after the
/// other already synced. The SEVENTH deduplicator, mirroring
/// `PlannedTripDeduplicator`: `OSAllocatedUnfairLock` reentrancy guard, its
/// own `ModelContext`, deterministic convergence.
///
/// **Identity** = `(kindRaw, homeID, centre rounded to ~11 m)` — immutable
/// fields only (the PhotoImportState lesson: keying on a mutable field is a
/// delete-war). Two corrections at the same spot for the same home mean the
/// same decision; radius differences fold to the survivor's.
///
/// **Survivor** = oldest by `(createdAt, id.uuidString)` — strict total
/// order over synced fields, so every device picks the same row. Nothing to
/// absorb: an override carries no lifecycle state, and `sourceTripName` is
/// display-only provenance where the first writer's value is as good as any.
nonisolated enum HomeAreaOverrideDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "HomeAreaOverrideDeduplicator"
    )

    private static let isRunning = OSAllocatedUnfairLock(initialState: false)

    /// ~11 m at the equator — far below any radius an override can carry
    /// (floor 1 km), and coarse enough that floating-point noise in a synced
    /// coordinate cannot split a group.
    nonisolated static func identityKey(
        kindRaw: String, homeID: UUID?, latitude: Double, longitude: Double
    ) -> String {
        String(format: "%@|%@|%.4f|%.4f",
               kindRaw, homeID?.uuidString ?? "-", latitude, longitude)
    }

    /// One taught place across Home eras: the identity key without the Home.
    /// A nearby Home edit copies a correction to its successor era, so the
    /// copies share this key while their `identityKey`s differ.
    nonisolated static func placeKey(
        kindRaw: String, latitude: Double, longitude: Double
    ) -> String {
        String(format: "%@|%.4f|%.4f", kindRaw, latitude, longitude)
    }

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else {
            logger.debug("HomeAreaOverride dedup already in progress, skipping.")
            return false
        }
        defer { isRunning.withLock { $0 = false } }

        let context = ModelContext(modelContainer)

        guard let all = try? context.fetch(FetchDescriptor<HomeAreaOverride>()) else { return false }
        guard all.count > 1 else { return true }

        var groups: [String: [HomeAreaOverride]] = [:]
        for row in all {
            groups[identityKey(kindRaw: row.kindRaw, homeID: row.homeID,
                               latitude: row.centerLatitude,
                               longitude: row.centerLongitude),
                   default: []].append(row)
        }

        var deleted = 0
        for rows in groups.values where rows.count > 1 {
            let sorted = rows.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                // No uniquely-determined survivor → skip the row (the
                // PlacesDeduplicator shared-id rule). Two devices importing
                // the same v6 backup mint rows with IDENTICAL (id,
                // createdAt); the sort order is then the store's fetch
                // order, which differs per device — each device deleting
                // "the other" row would destroy the correction on BOTH after
                // sync. Identical twins are
                // harmless to keep: same geometry, same membership.
                guard loser.createdAt != survivor.createdAt
                        || loser.id != survivor.id else { continue }
                context.delete(loser)
                deleted += 1
            }
        }

        guard deleted > 0 else { return true }
        do {
            try context.save()
            logger.info("HomeAreaOverride dedup removed \(deleted, privacy: .public) duplicate row(s).")
            return true
        } catch {
            logger.error("HomeAreaOverride dedup save failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
