//
//  PlannedTripDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// Collapses duplicate `PlannedTrip` rows that accumulate from CloudKit sync
/// when two devices independently scan the same synced calendar (foreground
/// scan + daily BG refresh run on each device) and both insert a row for the
/// same event before the other's row arrives.
///
/// The sixth deduplicator, mirroring `PhotoImportStateDeduplicator`'s
/// pattern: `OSAllocatedUnfairLock` reentrancy guard, its own `ModelContext`,
/// deterministic convergence so every device independently picks the same
/// survivor.
///
/// **Identity** is the same composite key the scan upserts on:
/// `(eventExternalIdentifier ?? eventLocalIdentifier, startDate)` — see
/// `PlannedTripDetector.identityKey`. `calendarItemExternalIdentifier` tracks
/// the server-side UID for synced accounts, so both devices' rows for one
/// event share it. When it's nil the key falls back to the per-device
/// `eventIdentifier` and the rows deliberately do NOT merge — but a nil
/// external identifier in practice means a local-only "On My iPhone"
/// calendar, which doesn't sync and therefore can't produce cross-device
/// duplicates in the first place.
///
/// **Survivor** = oldest by `(createdAt, id.uuidString)` — first device to
/// see the event wins, same rationale as `PhotoImportStateDeduplicator`.
/// Before losers are deleted, the survivor absorbs the group's most-advanced
/// lifecycle state: `matched > dismissed > expired > upcoming` (a match or a
/// user dismissal on EITHER device must survive the merge), plus the newest
/// `lastSeenAt` (so the staleness sweep doesn't mistake the merged row for
/// stale). Both folds read only CloudKit-synced fields through strict total
/// orders, so two devices deduplicating concurrently converge on identical
/// rows.
nonisolated enum PlannedTripDeduplicator {

    private static let logger = Logger(
        subsystem: "com.travellog.app",
        category: "PlannedTripDeduplicator"
    )

    private static let isRunning = OSAllocatedUnfairLock(initialState: false)

    /// False when the pass did not run to its end (single-flight, fetch or save).
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else {
            logger.debug("PlannedTrip dedup already in progress, skipping.")
            return false
        }
        defer { isRunning.withLock { $0 = false } }

        let context = ModelContext(modelContainer)

        guard let all = try? context.fetch(FetchDescriptor<PlannedTrip>()) else { return false }
        guard all.count > 1 else { return true }

        var groups: [String: [PlannedTrip]] = [:]
        for row in all {
            let key = PlannedTripDetector.identityKey(
                externalIdentifier: row.eventExternalIdentifier,
                localIdentifier: row.eventLocalIdentifier,
                startDate: row.startDate,
                isAllDay: row.isAllDay
            )
            groups[key, default: []].append(row)
        }

        var deleted = 0
        for rows in groups.values where rows.count > 1 {
            // Survivor: oldest by (createdAt, id.uuidString) — a strict
            // total order over synced fields (UUID tiebreak because two
            // devices scanning within the same millisecond can't otherwise
            // agree).
            let sorted = rows.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
            let survivor = sorted[0]

            // Fold the most-advanced lifecycle state into the survivor.
            // Priority ties break on id.uuidString so the (matchedTripID,
            // statusRaw) pair is picked identically on every device.
            let lead = rows.min { a, b in
                let pa = statusPriority(a.status), pb = statusPriority(b.status)
                if pa != pb { return pa > pb }
                return a.id.uuidString < b.id.uuidString
            }
            if let lead, statusPriority(lead.status) > statusPriority(survivor.status) {
                survivor.statusRaw = lead.statusRaw
                survivor.matchedTripID = lead.matchedTripID
            }
            if let newestSeen = rows.map(\.lastSeenAt).max(), newestSeen > survivor.lastSeenAt {
                survivor.lastSeenAt = newestSeen
            }
            foldEnrichment(from: rows, into: survivor)

            for row in sorted.dropFirst() {
                context.delete(row)
                deleted += 1
            }
        }

        guard deleted > 0 else { return true }
        do {
            try context.save()
            logger.info("Removed \(deleted) duplicate PlannedTrip row(s); kept oldest per identity key.")
            return true
        } catch {
            logger.error("Failed to save PlannedTrip dedup: \(error.localizedDescription)")
            return false
        }
    }

    /// Fold the group's enrichment into the survivor before the losers are
    /// deleted.
    ///
    /// The survivor is chosen by AGE, which says nothing about how much work
    /// has been done on a row. Two-device onboarding routinely leaves one
    /// device's row forward-geocoded (`resolved*`, `distanceFromHomeKm`) and
    /// forecast-filled while the other's is bare — and if the bare one happens
    /// to be older, keeping it alone would throw all of that away. None of it is
    /// re-derived: the scan's resolution pass only visits rows that are still
    /// unresolved, and `distanceFromHomeKm` drives detection signal 4 (+3,
    /// far-from-home), so losing it can demote the row below the display
    /// cutoff and make the card vanish.
    ///
    /// Every choice below is a deterministic function of synced fields, with
    /// an `id.uuidString` tiebreak, so two devices fold to the same survivor
    /// state — the convergence requirement every deduplicator here carries.
    static func foldEnrichment(from rows: [PlannedTrip], into survivor: PlannedTrip) {
        // The whole RESOLUTION travels as one unit — coordinates, the place
        // names derived from them, the distance measured from them, and the
        // forecast fetched for them. `distanceFromHomeKm` and
        // `forecastWeatherData` are not independent facts: each is computed
        // FROM a particular `resolved*` coordinate. Folding them field-by-field
        // (each picking its own min-uuid donor) could pair row X's place name
        // with row Y's distance — signal 4 measured against a location the row
        // no longer claims — and Y's weather chip for a place it no longer
        // names. That is the same "name from one resolution at another's
        // coordinates" error one level up.
        // ONE code path, no branch asymmetry. Pick the winning resolution
        // first, then fill the values derived from it from any row that agrees
        // on the coordinate — always by min-uuid among the rows that actually
        // CARRY a value.
        if survivor.resolvedLatitude == nil || survivor.resolvedLongitude == nil {
            let donor = rows
                .filter { $0.resolvedLatitude != nil && $0.resolvedLongitude != nil }
                .min { $0.id.uuidString < $1.id.uuidString }
            if let donor {
                survivor.resolvedLatitude = donor.resolvedLatitude
                survivor.resolvedLongitude = donor.resolvedLongitude
                survivor.resolvedLocality = donor.resolvedLocality
                survivor.resolvedCountry = donor.resolvedCountry
                survivor.resolvedISOCountryCode = donor.resolvedISOCountryCode
            }
        }

        // Rows that agree with the survivor's (now settled) coordinate — the
        // only rows whose derived values describe the same place. Exact `Double`
        // equality is deliberate and conservative: two independent resolutions
        // that differ in the last bit simply don't donate to each other.
        if survivor.resolvedLatitude != nil, survivor.resolvedLongitude != nil {
            let sameResolution = rows.filter {
                $0.resolvedLatitude == survivor.resolvedLatitude
                    && $0.resolvedLongitude == survivor.resolvedLongitude
            }
            if survivor.distanceFromHomeKm == nil {
                survivor.distanceFromHomeKm = sameResolution
                    .filter { $0.distanceFromHomeKm != nil }
                    .min { $0.id.uuidString < $1.id.uuidString }?
                    .distanceFromHomeKm
            }
            if survivor.forecastWeatherData == nil {
                survivor.forecastWeatherData = sameResolution
                    .filter { $0.forecastWeatherData != nil }
                    .min { $0.id.uuidString < $1.id.uuidString }?
                    .forecastWeatherData
            }
        }

        // Highest confidence wins across the group. NOTE: confidence is not
        // monotonic — `CalendarEnricher.applyScan` re-stamps it from each
        // scan's detection and can lower it (an event edited to drop a booking
        // keyword, or a scan where the FM tie-breaker was unavailable). So this
        // is a deterministic merge rule, not a claim about truth, and the next
        // scan re-stamps whatever it observes.
        let best = rows.min { a, b in
            let pa = confidencePriority(a.confidence), pb = confidencePriority(b.confidence)
            if pa != pb { return pa > pb }
            return a.id.uuidString < b.id.uuidString
        }
        if let best, confidencePriority(best.confidence) > confidencePriority(survivor.confidence) {
            survivor.confidenceRaw = best.confidenceRaw
        }

        // Signals are evidence tags, so the union is the honest merge. Sorted
        // for a byte-identical `signalsRaw` on every device.
        let unionedSignals = Set(rows.flatMap(\.signals)).sorted()
        if unionedSignals != survivor.signals {
            survivor.signals = unionedSignals
        }
    }

    static func confidencePriority(_ confidence: PlannedTripConfidence) -> Int {
        switch confidence {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    /// `matched` (a real trip is linked) outranks `dismissed` (an explicit
    /// user decision) outranks `expired` outranks `upcoming`.
    static func statusPriority(_ status: PlannedTripStatus) -> Int {
        switch status {
        case .matched: 3
        case .dismissed: 2
        case .expired: 1
        case .upcoming: 0
        }
    }
}
