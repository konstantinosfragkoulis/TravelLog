//
//  AppDelegate+DataRepairs.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import UIKit
import SwiftData
import BackgroundTasks
import UserNotifications
import WidgetKit
import CoreLocation
import CoreData
import os.log

extension AppDelegate {

    // MARK: - Airport Backfill (V9 origin; re-armed per dataset expansion)

    /// Write this legacy completion key on success for downgrade compatibility;
    /// only the dataset-versioned key gates the current pass.
    nonisolated static let airportBackfillCompletedKey = "airportBackfillCompleted_v1"

    /// Bump this gate when the bundled airport dataset changes.
    /// Re-stamping is idempotent because the flag is a pure function of centroid and dataset.
    nonisolated static let airportBackfillDatasetKey = "airportBackfillCompleted_v3"

    /// Set airport flags in BOTH directions from centroid proximity, once per dataset version.
    /// Yield between batches so foreground interactions remain responsive.
    nonisolated static func runAirportBackfillIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: airportBackfillDatasetKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "AirportBackfill")
        logger.info("Starting airport backfill (dataset v3).")

        let passStartedAt = Date.now
        let result = await backfillAirports(modelContainer: modelContainer)

        // Latch completion ONLY after the terminal save succeeds so failed writes retry.
        guard result.saved else {
            logger.error("Airport backfill read or save failed; gate NOT set, will retry next launch.")
            return
        }
        guard mayLatchOneShotBackfill(
            processedRows: backfillRowCount(Stay.self), passStartedAt: passStartedAt) else {
            logger.info("Airport backfill ran, but the store may still be hydrating; gate NOT set.")
            return
        }
        defaults.set(true, forKey: airportBackfillCompletedKey)
        defaults.set(true, forKey: airportBackfillDatasetKey)
        logger.info("Airport backfill complete. Flagged \(result.flagged) stays as airport-adjacent.")
    }

    /// Internal worker test seam for AirportBackfillTests using an in-memory container.
    /// `datasetLoaded` is injectable so tests can simulate an airports.json read failure.
    nonisolated static func backfillAirports(
        modelContainer: ModelContainer,
        datasetLoaded: Bool = AirportDetector.shared.airportCount > 0
    ) async -> (flagged: Int, saved: Bool) {
        // An unloaded dataset is a failed read, not "no airports": restamping from it
        // would clear every true flag (and sync that). Not complete, so the pass retries.
        guard datasetLoaded else { return (0, false) }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Stay>()
        // Fetch failed → couldn't read the data → NOT complete (saved:false),
        // so the caller leaves the gate unset and the pass retries next launch.
        guard let stays = try? context.fetch(descriptor) else { return (0, false) }
        let titleSnapshots = TripTitleStore.parentSemanticSnapshots(for: stays)

        var flagged = 0
        for (i, stay) in stays.enumerated() {
            let coord = CLLocationCoordinate2D(
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude
            )
            // Set the flag in BOTH directions from the current centroid; seed-ping stamps can be stale.
            let near = AirportDetector.shared.isNearAirport(coord)
            if stay.isAirport != near {
                stay.isAirport = near
                flagged += 1
            }
            // Yield every 200 stays so a foreground user-interaction can
            // squeeze in. Single-actor backpressure is the only mechanism
            // here; the loop itself never blocks on I/O.
            if i % 200 == 199 {
                await Task.yield()
            }
        }

        do {
            // An unreadable home-place index must not latch this one-shot.
            try TripTitleStore.invalidateChangedParentTitles(
                from: titleSnapshots, in: context)
            try context.save()
        } catch {
            context.rollback()
            Logger(subsystem: "com.travellog.app", category: "AirportBackfill")
                .error("Save failed during airport backfill: \(error.localizedDescription)")
            return (0, false)
        }
        return (flagged, true)
    }

    // MARK: - Trip countryCodes recompute (transit-stripped)

    /// Completion key for destination-only trip country-code recomputation.
    nonisolated static let tripCountryCodesRecomputeCompletedKey = "tripCountryCodesRecomputeCompleted_v1"

    /// Recompute destination-only country codes idempotently; summaries and provenance are also derived.
    /// One save bounds CloudKit replay to the affected trips.
    nonisolated static func runTripCountryCodesRecomputeIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: tripCountryCodesRecomputeCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "TripCountryRecompute")
        logger.info("Starting one-time Trip.countryCodes recompute (transit-stripped).")

        let passStartedAt = Date.now
        let result = await recomputeAllTripCountryCodes(modelContainer: modelContainer)

        // Gate on save success.
        guard result.saved else {
            logger.error("Trip.countryCodes recompute save failed; gate NOT set, will retry next launch.")
            return
        }
        guard mayLatchOneShotBackfill(
            processedRows: backfillRowCount(Trip.self), passStartedAt: passStartedAt) else {
            logger.info("Trip.countryCodes recompute ran, but the store may still be hydrating; gate NOT set.")
            return
        }
        defaults.set(true, forKey: tripCountryCodesRecomputeCompletedKey)
        logger.info("Trip.countryCodes recompute complete. Updated \(result.touched) trip(s).")
    }

    nonisolated private static func recomputeAllTripCountryCodes(modelContainer: ModelContainer) async -> (touched: Int, saved: Bool) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Trip>()
        guard let trips = try? context.fetch(descriptor) else { return (0, false) }

        for trip in trips {
            // The one-shot latches on this pass: a summary built without its
            // home-place filter is a required-read failure, so save nothing.
            guard trip.recomputeSummary() else {
                context.rollback()
                Logger(subsystem: "com.travellog.app", category: "TripCountryRecompute")
                    .error("Home places unreadable during Trip.countryCodes recompute; nothing saved.")
                return (0, false)
            }
        }

        var saved = true
        do {
            try context.save()
        } catch {
            saved = false
            Logger(subsystem: "com.travellog.app", category: "TripCountryRecompute")
                .error("Save failed during Trip.countryCodes recompute: \(error.localizedDescription)")
        }
        return (trips.count, saved)
    }

    // MARK: - Trip summary metro refresh (post-V10, May-2026)

    /// Completion key for summary refresh and stored-title validation under the current title policy.
    /// v6: titles normalize like their place names, and titles in the old prompt transform's
    /// letter-deleting spelling ("Troms" for Tromsø) are respelled in stored spelling.
    nonisolated static let tripSummaryMetroRefreshCompletedKey = "tripSummaryMetroRefreshCompleted_v6"

    /// Recompute summaries and validate stored titles AFTER offline geocoding populates metro/island fields.
    /// The idempotent summary pass also derives country codes and provenance;
    /// a single save bounds CloudKit replay by trip count.
    nonisolated static func runTripSummaryMetroRefreshIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: tripSummaryMetroRefreshCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "TripSummaryMetroRefresh")
        logger.info("Starting one-time Trip.destinationSummary metro refresh.")

        let passStartedAt = Date.now
        let result = await recomputeAllTripSummariesForMetroRefresh(modelContainer: modelContainer)

        // Gate on save success.
        guard result.saved else {
            logger.error("Trip.destinationSummary metro refresh save failed; gate NOT set, will retry next launch.")
            return
        }
        guard mayLatchOneShotBackfill(
            processedRows: backfillRowCount(Trip.self), passStartedAt: passStartedAt) else {
            logger.info("Trip.destinationSummary metro refresh ran, but the store may still be hydrating; gate NOT set.")
            return
        }
        defaults.set(true, forKey: tripSummaryMetroRefreshCompletedKey)
        logger.info("Trip.destinationSummary metro refresh complete. Updated \(result.touched) trip(s).")
    }

    nonisolated static func recomputeAllTripSummariesForMetroRefresh(modelContainer: ModelContainer) async -> (touched: Int, saved: Bool) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Trip>()
        guard let trips = try? context.fetch(descriptor) else { return (0, false) }

        var invalidated = 0
        for trip in trips {
            // This pass latches once: an unreadable home-place index would
            // persist home-named summaries and keep titles that name the
            // home, so save nothing and retry next launch.
            let homePlaces: Set<String>
            do {
                guard trip.recomputeSummary() else { throw TripTitleStore.HomePlaceNamesUnreadable() }
                homePlaces = try TripClassifier.homePlaceNames(for: trip, in: context)
            } catch {
                context.rollback()
                Logger(subsystem: "com.travellog.app", category: "TripSummaryMetroRefresh")
                    .error("Home places unreadable during Trip.destinationSummary metro refresh; nothing saved.")
                return (0, false)
            }
            // Respell stored titles in the retired prompt spelling and invalidate
            // titles the current policy rejects; Stage 5 regenerates those.
            guard trip.customName?.isEmpty != false,
                  let title = trip.aiGeneratedTitle, !title.isEmpty else { continue }
            if applyStoredTitlePolicy(title, to: trip, homePlaces: homePlaces, in: context) {
                invalidated += 1
            }
        }
        if invalidated > 0 {
            Logger(subsystem: "com.travellog.app", category: "TripSummaryMetroRefresh")
                .info("Respelled or invalidated \(invalidated) stored title(s) under the current title policy.")
        }

        var saved = true
        do {
            try context.save()
        } catch {
            saved = false
            Logger(subsystem: "com.travellog.app", category: "TripSummaryMetroRefresh")
                .error("Save failed during Trip.destinationSummary metro refresh: \(error.localizedDescription)")
        }
        return (trips.count, saved)
    }

    /// The current title policy for one stored generated title. A title in
    /// the retired prompt spelling ("Troms" for Tromsø) is respelled first:
    /// grounding alone can accept it when a region owns the shortened word.
    /// A title the policy rejects is cleared for Stage 5. Returns whether the
    /// trip's title changed.
    nonisolated private static func applyStoredTitlePolicy(
        _ title: String, to trip: Trip, homePlaces: Set<String>, in context: ModelContext
    ) -> Bool {
        let respelled = TripClassifier.legacyTitleSpellingRepair(title, for: trip)
        if tripClassifier.titleValidationFailure(
            respelled ?? title, for: trip, homePlaceNames: homePlaces) != nil {
            TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
            return true
        }
        guard let respelled else { return false }
        return TripTitleStore.replaceCanonicalTitle(respelled, for: trip, in: context)
    }

    /// Titles in the retired prompt spelling keep arriving after the latched
    /// launch pass: from an older device through CloudKit and from backup
    /// imports. Only those titles are checked, as the launch pass would;
    /// custom names are never touched, and a trip whose stays have not
    /// arrived has nothing to match until a later pass. Respelling instead of
    /// clearing keeps an older device from regenerating the same spelling.
    /// `scope` bounds the check to the trips a history window touched.
    /// Returns false when a required read or the save failed.
    nonisolated static func repairLegacyTitleSpellings(
        modelContainer: ModelContainer, scope: LegacyTitleRepairScope = .all
    ) -> Bool {
        let context = ModelContext(modelContainer)
        guard let trips = legacyTitleRepairCandidates(scope, in: context) else {
            Logger(subsystem: "com.travellog.app", category: "TripTitleSpellingRepair")
                .error("Titled trips unreadable; stored title spellings not checked.")
            return false
        }
        return repairLegacyTitleSpellings(of: trips, in: context)
    }

    /// The trips `scope` names, in `context`; nil when a read failed. A row
    /// deleted since the window, or a stay with no trip, contributes nothing.
    nonisolated private static func legacyTitleRepairCandidates(
        _ scope: LegacyTitleRepairScope, in context: ModelContext
    ) -> [Trip]? {
        switch scope {
        case .all:
            var descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> {
                ($0.customName ?? "") == "" && ($0.aiGeneratedTitle ?? "") != ""
            })
            // The spelling check reads every candidate's stays.
            descriptor.relationshipKeyPathsForPrefetching = [\.stays]
            return try? context.fetch(descriptor)
        case .changed(let tripRows, let stayRows):
            var trips: [PersistentIdentifier: Trip] = [:]
            do {
                for row in tripRows {
                    if let trip = try context.fetch(FetchDescriptor<Trip>(
                        predicate: #Predicate<Trip> { $0.persistentModelID == row })).first {
                        trips[trip.persistentModelID] = trip
                    }
                }
                for row in stayRows {
                    if let trip = try context.fetch(FetchDescriptor<Stay>(
                        predicate: #Predicate<Stay> { $0.persistentModelID == row })).first?.trip {
                        trips[trip.persistentModelID] = trip
                    }
                }
            } catch {
                return nil
            }
            return Array(trips.values)
        }
    }

    /// The spelling check and repair for `trips`, on a caller's context with
    /// no pending changes: a failure rolls the context back. Trips with a
    /// custom name or no generated title are skipped.
    nonisolated static func repairLegacyTitleSpellings(of trips: [Trip], in context: ModelContext) -> Bool {
        let logger = Logger(subsystem: "com.travellog.app", category: "TripTitleSpellingRepair")
        var changed = 0
        for trip in trips where !trip.isDeleted {
            guard trip.customName?.isEmpty != false,
                  let title = trip.aiGeneratedTitle, !title.isEmpty,
                  TripClassifier.legacyTitleSpellingRepair(title, for: trip) != nil else { continue }
            let homePlaces: Set<String>
            do {
                homePlaces = try TripClassifier.homePlaceNames(for: trip, in: context)
            } catch {
                context.rollback()
                logger.error("Home places unreadable; stored title spellings not repaired.")
                return false
            }
            if applyStoredTitlePolicy(title, to: trip, homePlaces: homePlaces, in: context) {
                changed += 1
            }
        }
        guard changed > 0 else { return true }
        do {
            try context.save()
        } catch {
            context.rollback()
            logger.error("Save failed while repairing stored title spellings: \(error.localizedDescription)")
            return false
        }
        logger.info("Respelled or invalidated \(changed) stored title(s) in the retired prompt spelling.")
        return true
    }

    // MARK: - locality == country name sweep (post-V10, May-2026)

    /// Completion key for the locality-equals-country sweep.
    nonisolated static let localityCountryNameSweepCompletedKey = "localityCountryNameSweep_v1"

    /// Clear country names stored as localities so they cannot reach display or title inputs.
    /// Run AFTER offline geocoding has populated legitimate localities; save all entity changes together.
    nonisolated static func runLocalityCountryNameSweepIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: localityCountryNameSweepCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "LocalityCountrySweep")
        logger.info("Starting one-time locality==country sweep.")

        let passStartedAt = Date.now
        let result = await sweepLocalityCountryNames(modelContainer: modelContainer)

        // Gate on save success.
        guard result.saved else {
            logger.error("Locality==country sweep save failed (or a fetch missed); gate NOT set, will retry next launch.")
            return
        }
        guard mayLatchOneShotBackfill(
            processedRows: backfillRowCount(Stay.self), passStartedAt: passStartedAt) else {
            logger.info("Locality==country sweep ran, but the store may still be hydrating; gate NOT set.")
            return
        }
        defaults.set(true, forKey: localityCountryNameSweepCompletedKey)
        logger.info("""
            Locality==country sweep complete: \
            \(result.stays) stay(s), \
            \(result.pings) ping(s), \
            \(result.hexes) hex visit(s) cleared.
            """)
    }

    nonisolated private static func sweepLocalityCountryNames(
        modelContainer: ModelContainer
    ) async -> (stays: Int, pings: Int, hexes: Int, saved: Bool) {
        let context = ModelContext(modelContainer)
        // Any entity fetch or save failure leaves the pass incomplete; do not latch completion.
        var saved = true
        var titleSnapshots: [TripTitleStore.ParentSemanticSnapshot] = []

        var stays = 0
        if let allStays = try? context.fetch(FetchDescriptor<Stay>()) {
            titleSnapshots = TripTitleStore.parentSemanticSnapshots(
                for: allStays)
            for stay in allStays {
                if let loc = stay.locality, let country = stay.country, loc == country {
                    stay.locality = nil
                    stays += 1
                }
            }
        } else {
            saved = false
        }

        var pings = 0
        if let allPings = try? context.fetch(FetchDescriptor<LocationPing>()) {
            for ping in allPings {
                if let loc = ping.locality, let country = ping.country, loc == country {
                    ping.locality = nil
                    pings += 1
                }
            }
        } else {
            saved = false
        }

        var hexes = 0
        if let allHexes = try? context.fetch(FetchDescriptor<HexVisit>()) {
            for hex in allHexes {
                if let loc = hex.locality, let country = hex.country, loc == country {
                    hex.locality = nil
                    hexes += 1
                }
            }
        } else {
            saved = false
        }

        do {
            // An unreadable home-place index must not latch this one-shot.
            try TripTitleStore.invalidateChangedParentTitles(
                from: titleSnapshots, in: context)
            try context.save()
        } catch {
            context.rollback()
            saved = false
            stays = 0
            pings = 0
            hexes = 0
            Logger(subsystem: "com.travellog.app", category: "LocalityCountrySweep")
                .error("Save failed during locality==country sweep: \(error.localizedDescription)")
        }
        return (stays: stays, pings: pings, hexes: hexes, saved: saved)
    }

    // MARK: - Restore wiped Stay country (May-2026 emergency fix)

    /// Completion key for restoring missing Stay country and ISO fields.
    nonisolated static let restoreWipedStayCountryCompletedKey = "restoreWipedStayCountryCompleted_v1"

    /// Restore missing country data from the stay's own valid ISO, sibling pings, the offline
    /// resolver at its centroid, then a single-country trip. Trip inference is valid only for a
    /// destination stay of a single-country trip; multi-country trips are ambiguous, and trip
    /// codes never describe transit or home stays.
    /// Offline only: the caller holds the global writer gate, and the MapKit fallback could only
    /// add a locality this pass discards, never a country.
    /// Run AFTER offline geocoding and BEFORE summary refresh so recomputation reads restored data.
    nonisolated static func runRestoreWipedStayCountryIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: restoreWipedStayCountryCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "RestoreWipedStayCountry")
        logger.info("Starting one-time restore-wiped-stay-country pass.")

        let passStartedAt = Date.now
        let result = await restoreWipedStayCountry(modelContainer: modelContainer)

        // Only mark complete if the worker actually finished the full
        // pass — a cancellation mid-loop returns partial progress and
        // we want the next launch to pick up the remaining stays.
        if !Task.isCancelled && result.saved
            && mayLatchOneShotBackfill(
                processedRows: backfillRowCount(Stay.self), passStartedAt: passStartedAt) {
            defaults.set(true, forKey: restoreWipedStayCountryCompletedKey)
            logger.info("""
                Restore-wiped-stay-country complete: \
                attempted \(result.attempted), \
                restored \(result.restored) \
                (via ping=\(result.viaPing), trip=\(result.viaTrip), resolver=\(result.viaResolver)). \
                Gate set.
                """)
        } else {
            logger.info("""
                Restore-wiped-stay-country partial: \
                attempted \(result.attempted), \
                restored \(result.restored), \
                saved \(result.saved), cancelled \(Task.isCancelled). \
                Gate NOT set; will resume next launch.
                """)
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var failStayCountryDonorFetchForTesting = false
    #endif

    nonisolated static func restoreWipedStayCountry(
        modelContainer: ModelContainer
    ) async -> (attempted: Int, restored: Int, viaPing: Int, viaTrip: Int, viaResolver: Int, saved: Bool) {
        let context = ModelContext(modelContainer)
        let logger = Logger(subsystem: "com.travellog.app", category: "RestoreWipedStayCountry")
        let englishLocale = Locale(identifier: "en_US")

        let predicate = #Predicate<Stay> { $0.country == nil }
        guard let stays = try? context.fetch(FetchDescriptor<Stay>(predicate: predicate)) else {
            return (attempted: 0, restored: 0, viaPing: 0, viaTrip: 0, viaResolver: 0, saved: false)
        }

        var attempted = 0
        var restored = 0
        var viaPing = 0
        var viaTrip = 0
        var viaResolver = 0
        // Latch the gate only when every save succeeds.
        var saved = true
        // A geocoder that failed to open answers nil everywhere: the pass still restores what
        // it can without it, but stays owed.
        if !(await GeocodeResolver.shared.isAvailable()) {
            saved = false
            logger.error("Offline geocoder unavailable; the country restore stays owed.")
        }
        var pendingTitleSnapshots: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]

        func persistPendingChanges(_ reason: String) -> Bool {
            defer { pendingTitleSnapshots.removeAll() }
            do {
                // An unreadable home-place index must not latch this one-shot.
                try TripTitleStore.invalidateChangedParentTitles(
                    from: Array(pendingTitleSnapshots.values), in: context)
                try context.save()
                return true
            } catch {
                context.rollback()
                logger.error("\(reason): \(error.localizedDescription)")
                return false
            }
        }

        for (i, stay) in stays.enumerated() {
            // Save partial progress before returning on cancellation so a later launch can resume.
            if Task.isCancelled {
                if !persistPendingChanges("Cancellation save failed") {
                    saved = false
                }
                logger.info("Cancelled after \(attempted)/\(stays.count); restored \(restored).")
                return (attempted: attempted, restored: restored, viaPing: viaPing, viaTrip: viaTrip, viaResolver: viaResolver, saved: saved)
            }

            attempted += 1

            var restoredIso: String?
            var restoredCountry: String?
            var via: String = ""

            // 0. A stay that still holds a valid ISO keeps that country: only its name is missing.
            if let known = GeocodeResolver.sanitizedISOCountryCode(stay.isoCountryCode),
               let name = englishLocale.localizedString(forRegionCode: known)?.toLatinAscii {
                restoredIso = known
                restoredCountry = name
                via = "iso"
            }

            // 1. Try sibling pings — same coord cluster, likely already resolved.
            let pingIDs = stay.pingIDs
            if restoredIso == nil, !pingIDs.isEmpty {
                let pingPredicate = #Predicate<LocationPing> { pingIDs.contains($0.id) }
                do {
                    #if DEBUG
                    if failStayCountryDonorFetchForTesting { throw CocoaError(.fileReadUnknown) }
                    #endif
                    let pings = try context.fetch(FetchDescriptor<LocationPing>(predicate: pingPredicate))
                    if let donor = pings.first(where: { $0.isoCountryCode != nil }) {
                        restoredIso = donor.isoCountryCode
                        restoredCountry = donor.country
                        via = "ping"
                    }
                } catch {
                    saved = false
                    logger.error("Stay country donor fetch failed: \(error.localizedDescription)")
                    continue
                }
            }

            // 2. The offline resolver at the stay's own centroid. Never the MapKit fallback: it
            // keeps the offline country fields, so it cannot restore a country, and its quota and
            // network waits would hold the global writer gate.
            if restoredIso == nil {
                if let r = await GeocodeResolver.shared.resolve(
                    latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude
                ), let iso = r.isoCountryCode {
                    restoredIso = iso
                    restoredCountry = r.country
                    via = "resolver"
                }
            }

            // 3. Infer from the trip only for a destination stay of a single-country trip: its
            // codes count destination stays alone, so they say nothing about a transit or home stay.
            if restoredIso == nil, stay.category == .destination, let trip = stay.trip {
                let codes = trip.countryCodes
                    .split(separator: ",")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                if codes.count == 1 {
                    let code = codes[0]
                    restoredIso = code
                    restoredCountry = englishLocale.localizedString(forRegionCode: code)?.toLatinAscii
                    via = "trip"
                }
            }

            if let iso = restoredIso {
                if let trip = stay.trip {
                    let identity = ObjectIdentifier(trip)
                    if pendingTitleSnapshots[identity] == nil {
                        pendingTitleSnapshots[identity] =
                            TripTitleStore.ParentSemanticSnapshot(
                                trip: trip,
                                semantic: TripTitleStore.semanticSnapshot(
                                    for: trip))
                    }
                }
                stay.isoCountryCode = iso
                stay.country = restoredCountry ?? englishLocale.localizedString(forRegionCode: iso)?.toLatinAscii
                restored += 1
                switch via {
                case "ping": viaPing += 1
                case "trip": viaTrip += 1
                case "resolver": viaResolver += 1
                default: break
                }
            }

            if i > 0 && i % 25 == 0 {
                if !persistPendingChanges("Per-batch save failed") {
                    saved = false
                }
                await Task.yield()
            }
        }
        if !persistPendingChanges("Final save failed") {
            saved = false
        }
        return (attempted: attempted, restored: restored, viaPing: viaPing, viaTrip: viaTrip, viaResolver: viaResolver, saved: saved)
    }
}
