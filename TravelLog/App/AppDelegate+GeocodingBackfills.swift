//
//  AppDelegate+GeocodingBackfills.swift
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

    // MARK: - MapKit-fallback Stay locality backfill (May-2026)

    /// Completion key for filling unknown Stay localities through the rate-limited MapKit cache.
    /// `_v2`: older builds latched `_v1` even when offline, throttled or backed-off lookups left
    /// candidates unnamed, so every device reruns the pass once under the stricter accounting.
    nonisolated static let stayLocalityFallbackBackfillCompletedKey = "stayLocalityFallbackBackfillCompleted_v2"

    /// Run AFTER the country-name sweep so cleared localities are eligible for fallback.
    /// MapKitLocalityCache caps requests at 30 per 60 seconds and drops excess requests.
    /// Latch only when every candidate received a result or confirmed negative-cache verdict;
    /// rate-limit drops, throttles and transient failures leave completion unset for retry. Negative results expire after seven days.
    nonisolated static func runStayLocalityFallbackBackfillIfNeeded(
        modelContainer container: ModelContainer = AppDelegate.modelContainer,
        defaults: UserDefaults = .standard
    ) async {
        guard !defaults.bool(forKey: stayLocalityFallbackBackfillCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "StayLocalityFallback")
        logger.info("Starting one-time MapKit-fallback stay locality backfill.")

        // Reset the drop counter before starting so we only count drops
        // that happen during this pass (any prior drops from natural
        // StayClusterer flow are irrelevant to this gate).
        _ = await MapKitLocalityCache.shared.consumeDropCount()

        let passStartedAt = Date.now
        let result = await backfillStayLocalityFallback(modelContainer: container, defaults: defaults)

        let drops = await MapKitLocalityCache.shared.consumeDropCount()
        // A candidate whose centroid moved to another cell while its lookup ran was answered for
        // the wrong place; the next launch re-snapshots it at the new centroid.
        if drops == 0 && result.deferred == 0 && !Task.isCancelled && result.saved
            && mayLatchOneShotBackfill(
                processedRows: backfillRowCount(Stay.self, in: container), passStartedAt: passStartedAt) {
            defaults.set(true, forKey: stayLocalityFallbackBackfillCompletedKey)
            logger.info("""
                MapKit-fallback stay locality backfill complete: \
                attempted \(result.attempted) stay(s), \
                filled \(result.filled). Gate set.
                """)
        } else {
            logger.info("""
                MapKit-fallback stay locality backfill partial: \
                attempted \(result.attempted), filled \(result.filled), \
                unresolved \(drops), moved \(result.deferred), cancelled \(Task.isCancelled), \
                saved \(result.saved). \
                Gate NOT set; will resume next launch.
                """)
        }
    }

    /// Value snapshot of a fallback candidate — crosses the gate boundary,
    /// so no `@Model` reference. The physical ID applies each UUID twin separately; the
    /// res-8 cell witnesses the centroid the answer was computed for.
    private struct StayLocalityCandidate: Sendable {
        let persistentID: PersistentIdentifier
        let latitude: Double
        let longitude: Double
    }

    /// One attempted candidate's outcome, applied inside a gate unit. `locality` is nil when the
    /// lookup produced no usable name; apply still witnesses the row so a moved centroid defers.
    private struct StayLocalityResolution: Sendable {
        let persistentID: PersistentIdentifier
        let cell: String
        let locality: String?
        let administrativeArea: String?
        let country: String?
        let isoCountryCode: String?
        let subLocality: String?
        let metroName: String?
        let islandName: String?
    }

    /// Snapshot candidates in a short gate unit, resolve each 25-stay chunk outside the gate,
    /// then apply/save in its own unit so queued SLC saves interleave with MapKit work.
    #if DEBUG
    /// Makes the candidate read fail so tests can pin that a failed read
    /// never reports a latchable pass.
    nonisolated(unsafe) static var failStayLocalityCandidateFetchForTesting = false
    nonisolated(unsafe) static var failStayLocalityApplyFetchForTesting = false
    /// Which apply lookup of the pass throws, so a test can stage one stay first.
    nonisolated(unsafe) static var failStayLocalityApplyFetchCallForTesting = 1
    nonisolated(unsafe) private static var stayLocalityApplyFetchCallCountForTesting = 0
    // Expose only the rollback state, never the gate-owned ModelContext.
    nonisolated(unsafe) static var stayLocalityApplyHasChangesAfterRollbackForTesting: Bool?
    #endif

    nonisolated static func backfillStayLocalityFallback(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard
    ) async -> (attempted: Int, filled: Int, deferred: Int, saved: Bool) {
        let logger = Logger(subsystem: "com.travellog.app", category: "StayLocalityFallback")
        #if DEBUG
        stayLocalityApplyFetchCallCountForTesting = 0
        #endif

        // Delete All Data advances this floor: a centroid snapshotted before it is never looked up after it.
        let wipeFloor = StayClusterer.wipeFloor(in: defaults)
        // A failed read is not "no candidates": report an unsaved pass so
        // the one-shot key stays unset and the backfill retries next launch.
        let candidates: [StayLocalityCandidate]? = await PipelineGate.shared.runReturning(touching: []) {
            let context = ModelContext(modelContainer)
            let predicate = #Predicate<Stay> {
                $0.locality == nil && $0.country != nil
            }
            do {
                #if DEBUG
                if failStayLocalityCandidateFetchForTesting { throw CocoaError(.fileReadUnknown) }
                #endif
                return try context.fetch(FetchDescriptor<Stay>(predicate: predicate)).map {
                    StayLocalityCandidate(
                        persistentID: $0.persistentModelID,
                        latitude: $0.centroidLatitude,
                        longitude: $0.centroidLongitude)
                }
            } catch {
                logger.error("Stay locality candidate fetch failed: \(error.localizedDescription)")
                return nil
            }
        }
        guard let candidates else { return (attempted: 0, filled: 0, deferred: 0, saved: false) }

        var attempted = 0
        var filled = 0
        var deferred = 0
        // Latch the gate only when every save succeeds.
        var saved = true
        let chunkSize = 25
        var index = 0
        while index < candidates.count {
            // Prior chunks are durable; cancellation leaves partial progress available for retry.
            if Task.isCancelled {
                logger.info("Cancelled after attempting \(attempted)/\(candidates.count); filled \(filled).")
                return (attempted: attempted, filled: filled, deferred: deferred, saved: saved)
            }
            let chunk = candidates[index..<min(index + chunkSize, candidates.count)]
            index += chunkSize

            // Resolve the chunk with NO gate held.
            var resolutions: [StayLocalityResolution] = []
            var wiped = false
            for candidate in chunk {
                if Task.isCancelled { break }
                // Settings advances the floor before it clears the cache, so a generation read
                // before this check admits the lookup only if no clear followed.
                let generation = await MapKitLocalityCache.shared.generation
                guard StayClusterer.wipeFloor(in: defaults) == wipeFloor else {
                    wiped = true
                    break
                }
                attempted += 1
                let r = await GeocodeResolver.shared.resolveWithFallback(
                    latitude: candidate.latitude, longitude: candidate.longitude,
                    cacheGeneration: generation
                )
                // Country-name guard — shared definition: `Result.localityForStorage`
                // (nil both when there's no candidate and when the guard
                // fires; either way this stay stays locality-nil).
                resolutions.append(StayLocalityResolution(
                    persistentID: candidate.persistentID,
                    cell: MapKitLocalityCache.cellKey(
                        latitude: candidate.latitude, longitude: candidate.longitude),
                    locality: r?.localityForStorage,
                    administrativeArea: r?.administrativeArea,
                    country: r?.country,
                    isoCountryCode: r?.isoCountryCode,
                    subLocality: r?.subLocalityName,
                    metroName: r?.metroName,
                    islandName: r?.islandName
                ))
            }
            // The wiped rows are gone; unsaved keeps the key unset for whatever the store holds next.
            if wiped {
                logger.info("Delete All Data committed after attempting \(attempted)/\(candidates.count); stopped.")
                return (attempted: attempted, filled: filled, deferred: deferred, saved: false)
            }
            guard !resolutions.isEmpty else { continue }

            // Apply + save the chunk in one short gate unit. Re-fetches each physical row and
            // re-checks eligibility: another lane (clustering, geocode drain) may have filled,
            // moved or deleted the stay while we were outside the gate.
            let toApply = resolutions
            let outcome: (filled: Int, deferred: Int, saved: Bool) = await PipelineGate.shared.runReturning(touching: [.stay, .trip]) {
                let context = ModelContext(modelContainer)
                var applied = 0
                var moved = 0
                var titleSnapshots: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
                for resolution in toApply {
                    let rowID = resolution.persistentID
                    var descriptor = FetchDescriptor<Stay>(
                        predicate: #Predicate { $0.persistentModelID == rowID })
                    descriptor.fetchLimit = 1
                    let stay: Stay
                    do {
                        #if DEBUG
                        if failStayLocalityApplyFetchForTesting {
                            stayLocalityApplyFetchCallCountForTesting += 1
                            if stayLocalityApplyFetchCallCountForTesting == failStayLocalityApplyFetchCallForTesting {
                                throw CocoaError(.fileReadUnknown)
                            }
                        }
                        #endif
                        guard let found = try context.fetch(descriptor).first else { continue }
                        stay = found
                    } catch {
                        context.rollback()
                        #if DEBUG
                        stayLocalityApplyHasChangesAfterRollbackForTesting = context.hasChanges
                        #endif
                        logger.error("Stay locality apply fetch failed: \(error.localizedDescription)")
                        return (filled: 0, deferred: 0, saved: false)
                    }
                    guard stay.locality == nil, stay.country != nil else { continue }
                    // The MapKit name is valid for the res-8 cell it was cached under; the
                    // offline fields below only fill values that are still missing.
                    guard MapKitLocalityCache.cellKey(
                        latitude: stay.centroidLatitude, longitude: stay.centroidLongitude
                    ) == resolution.cell else {
                        moved += 1
                        continue
                    }
                    guard let locality = resolution.locality else { continue }
                    if let trip = stay.trip {
                        let identity = ObjectIdentifier(trip)
                        if titleSnapshots[identity] == nil {
                            titleSnapshots[identity] =
                                TripTitleStore.ParentSemanticSnapshot(
                                    trip: trip,
                                    semantic: TripTitleStore.semanticSnapshot(
                                        for: trip))
                        }
                    }
                    stay.locality = locality
                    stay.administrativeArea = stay.administrativeArea ?? resolution.administrativeArea
                    stay.country = stay.country ?? resolution.country
                    stay.isoCountryCode = stay.isoCountryCode ?? resolution.isoCountryCode
                    stay.subLocality = stay.subLocality ?? resolution.subLocality
                    stay.metroName = stay.metroName ?? resolution.metroName
                    stay.islandName = stay.islandName ?? resolution.islandName
                    applied += 1
                }
                guard applied > 0 else { return (filled: 0, deferred: moved, saved: true) }
                do {
                    try TripTitleStore.invalidateChangedParentTitles(
                        from: Array(titleSnapshots.values), in: context)
                    try context.save()
                } catch {
                    context.rollback()
                    logger.error("Per-chunk save failed: \(error.localizedDescription)")
                    return (filled: 0, deferred: moved, saved: false)
                }
                return (filled: applied, deferred: moved, saved: true)
            }
            filled += outcome.filled
            deferred += outcome.deferred
            if !outcome.saved { saved = false }
        }
        return (attempted: attempted, filled: filled, deferred: deferred, saved: saved)
    }

    // MARK: - Offline-Geocoder Backfill (Stage 1 — no schema change)

    /// Completion key for re-geocoding saved rows with the current resolver data.
    /// Coalesce absent fields to preserve known values; clear a demoted island only when
    /// `Result.demotedIslandName` confirms the coordinate lies on an excluded landmass.
    /// A changed semantic snapshot invalidates titles and triggers summary recomputation.
    /// `_v11`: `_v10` passes applied every UUID twin's result to one physical row, leaving the
    /// others stale and giving a HexVisit another cell's country, so every device reruns once.
    nonisolated static let offlineGeocoderBackfillCompletedKey = "offlineGeocoderBackfillCompleted_v11"

    /// Re-geocode existing Stay, LocationPing, and HexVisit rows without a CloudKit schema change.
    /// Save bounded chunks and yield between them; latch completion once per device.
    nonisolated static func runOfflineGeocoderBackfillIfNeeded(
        modelContainer container: ModelContainer = AppDelegate.modelContainer,
        defaults: UserDefaults = .standard
    ) async {
        guard !defaults.bool(forKey: offlineGeocoderBackfillCompletedKey) else { return }

        let logger = Logger(subsystem: "com.travellog.app", category: "OfflineGeocoderBackfill")
        logger.info("Starting Stage 1 offline-geocoder backfill.")

        let passStartedAt = Date.now
        let result = await backfillOfflineGeocoder(modelContainer: container, defaults: defaults)

        // Latch only after successful saves so stale place data remains retryable.
        guard result.saved else {
            logger.error("Offline-geocoder backfill had a failed fetch/save or was stopped by a wipe; gate NOT set, will retry next launch.")
            return
        }
        guard mayLatchOneShotBackfill(
            processedRows: backfillRowCount(Stay.self, in: container), passStartedAt: passStartedAt) else {
            logger.info("Offline-geocoder backfill ran, but the store may still be hydrating; gate NOT set.")
            return
        }
        defaults.set(true, forKey: offlineGeocoderBackfillCompletedKey)
        logger.info("""
            Offline-geocoder backfill complete: \
            \(result.updatedStays) stay(s), \
            \(result.updatedPings) ping(s), \
            \(result.updatedHexVisits) hex visit(s), \
            \(result.recomputedTrips) trip summary(ies) refreshed.
            """)
    }

    #if DEBUG
    /// DEBUG test probe runs between apply chunks with NO gate held; it awaits a competing
    /// unit to verify the non-reentrant gate is free for other work.
    static var geocoderBackfillInterChunkProbe: (@Sendable () async -> Void)?
    #endif

    /// Awaits the DEBUG inter-chunk probe (no-op in Release / when unset).
    nonisolated private static func fireGeocoderBackfillInterChunkProbe() async {
        #if DEBUG
        let probe = await MainActor.run { geocoderBackfillInterChunkProbe }
        if let probe { await probe() }
        #endif
    }

    /// Internal worker test seam for GeocoderBackfillChunkingTests.
    /// Resolve polygon queries and rate-limited MapKit fallback OUTSIDE the gate;
    /// apply short chunks by re-fetching rows on fresh contexts so SLC saves wait at most one chunk.
    /// Callers MUST invoke this outside PipelineGate: nested acquisition would self-deadlock.
    /// No persisted cursor is needed: deterministic coalescing is idempotent, and completion
    /// latches only after every phase fetches and saves successfully, allowing restart after a kill.
    nonisolated static func backfillOfflineGeocoder(
        modelContainer: ModelContainer,
        gate: PipelineGate = .shared,
        defaults: UserDefaults = .standard
    ) async -> (updatedStays: Int, updatedPings: Int, updatedHexVisits: Int, recomputedTrips: Int, saved: Bool) {
        let logger = Logger(subsystem: "com.travellog.app", category: "OfflineGeocoderBackfill")

        // Latch only when every fetch and save succeeds; partial failures must retry.
        var allSaved = true

        // Phase 1 (UNGATED): snapshot and resolve pings once per unique res-6 hex;
        // empty hex keys resolve per ping.
        // Ping coordinates are immutable, so snapshot resolution needs no drift guard.
        // Every phase carries the physical row: UUID twins each get their own result.
        var pingResolutions: [(identifier: PersistentIdentifier, id: UUID, r: GeocodeResolver.Result)] = []
        do {
            var pingSnapshots: [(identifier: PersistentIdentifier, id: UUID, lat: Double, lon: Double, hex: String)] = []
            let snapshotContext = ModelContext(modelContainer)
            if let pings = try? snapshotContext.fetch(FetchDescriptor<LocationPing>()) {
                pingSnapshots = pings.map { ($0.persistentModelID, $0.id, $0.latitude, $0.longitude, $0.h3IndexRes6) }
            } else {
                allSaved = false
            }
            var resolvedByHex: [String: GeocodeResolver.Result] = [:]
            var unresolvableHexes: Set<String> = []
            for snapshot in pingSnapshots {
                let r: GeocodeResolver.Result?
                if !snapshot.hex.isEmpty, let cached = resolvedByHex[snapshot.hex] {
                    r = cached
                } else if !snapshot.hex.isEmpty, unresolvableHexes.contains(snapshot.hex) {
                    r = nil
                } else {
                    r = await GeocodeResolver.shared.resolve(
                        latitude: snapshot.lat, longitude: snapshot.lon
                    )
                    if !snapshot.hex.isEmpty {
                        if let r { resolvedByHex[snapshot.hex] = r } else { unresolvableHexes.insert(snapshot.hex) }
                    }
                }
                if let r { pingResolutions.append((snapshot.identifier, snapshot.id, r)) }
            }
        }

        // ---------- Phase 2 (GATED, chunked): apply ping resolutions ----------
        var updatedPings = 0
        var pingIndex = 0
        while pingIndex < pingResolutions.count {
            let chunk = Array(pingResolutions[pingIndex ..< min(pingIndex + Self.geocoderBackfillPingChunk, pingResolutions.count)])
            pingIndex += chunk.count
            let outcome: (applied: Int, ok: Bool) = await gate.runReturning(touching: [.locationPing]) {
                let context = ModelContext(modelContainer)
                let ids = chunk.map(\.id)
                let predicate = #Predicate<LocationPing> { ids.contains($0.id) }
                guard let rows = try? context.fetch(FetchDescriptor<LocationPing>(predicate: predicate)),
                      let byIdentifier = try? Self.physicalBackfillRows(
                        for: chunk.map(\.identifier), fetchedByUUID: rows, fetchOne: { identifier in
                            try context.fetch(FetchDescriptor<LocationPing>(
                                predicate: #Predicate<LocationPing> { $0.persistentModelID == identifier })).first
                        }) else {
                    return (0, false)
                }
                var applied = 0
                for entry in chunk {
                    guard let ping = byIdentifier[entry.identifier] else { continue }
                    ping.applyResolverResult(entry.r)
                    applied += 1
                }
                do { try context.save() } catch {
                    logger.error("Per-chunk ping save failed: \(error.localizedDescription)")
                    return (applied, false)
                }
                return (applied, true)
            }
            updatedPings += outcome.applied
            if !outcome.ok { allSaved = false }
            await fireGeocoderBackfillInterChunkProbe()
        }

        // Phase 3 (UNGATED): snapshot and resolve stays with rate-limited MapKit fallback.
        // The cache caps requests at 30 per 60 seconds; dropped requests retry through natural enrichment.
        // Network awaits must never hold the gate.
        var stayResolutions: [(identifier: PersistentIdentifier, id: UUID, lat: Double, lon: Double,
                               r: GeocodeResolver.Result)] = []
        do {
            // Delete All Data advances this floor: a centroid snapshotted before it is never looked up after it.
            let wipeFloor = StayClusterer.wipeFloor(in: defaults)
            var staySnapshots: [(identifier: PersistentIdentifier, id: UUID, lat: Double, lon: Double)] = []
            let snapshotContext = ModelContext(modelContainer)
            if let stays = try? snapshotContext.fetch(FetchDescriptor<Stay>()) {
                staySnapshots = stays.map { ($0.persistentModelID, $0.id, $0.centroidLatitude, $0.centroidLongitude) }
            } else {
                allSaved = false
            }
            for snapshot in staySnapshots {
                // Generation before floor, as in the locality fallback; a pass this check stops stays unlatched.
                let generation = await MapKitLocalityCache.shared.generation
                guard StayClusterer.wipeFloor(in: defaults) == wipeFloor else {
                    logger.info("Delete All Data committed during stay resolution; stopped.")
                    allSaved = false
                    break
                }
                if let r = await GeocodeResolver.shared.resolveWithFallback(
                    latitude: snapshot.lat, longitude: snapshot.lon, cacheGeneration: generation
                ) {
                    stayResolutions.append((snapshot.identifier, snapshot.id, snapshot.lat, snapshot.lon, r))
                }
            }
        }

        // ---------- Phase 4 (GATED, chunked): apply stay resolutions ----------
        var updatedStays = 0
        var recomputedTrips = 0
        var stayIndex = 0
        while stayIndex < stayResolutions.count {
            let chunk = Array(stayResolutions[stayIndex ..< min(stayIndex + Self.geocoderBackfillStayChunk, stayResolutions.count)])
            stayIndex += chunk.count
            let outcome: (applied: Int, changedTrips: Int, ok: Bool) = await gate.runReturning(touching: [.stay, .trip]) {
                let context = ModelContext(modelContainer)
                let ids = chunk.map(\.id)
                let predicate = #Predicate<Stay> { ids.contains($0.id) }
                guard let rows = try? context.fetch(FetchDescriptor<Stay>(predicate: predicate)),
                      let byIdentifier = try? Self.physicalBackfillRows(
                        for: chunk.map(\.identifier), fetchedByUUID: rows, fetchOne: { identifier in
                            try context.fetch(FetchDescriptor<Stay>(
                                predicate: #Predicate<Stay> { $0.persistentModelID == identifier })).first
                        }) else {
                    return (0, 0, false)
                }
                var applied = 0
                var titleSnapshots: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
                for entry in chunk {
                    guard let stay = byIdentifier[entry.identifier] else { continue }
                    // A live ping can move the centroid during ungated resolution; re-resolve drifted stays
                    // at the CURRENT centroid offline. Skip on a miss rather than apply stale coordinates;
                    // MapKit fallback remains available through natural enrichment.
                    var result = entry.r
                    if abs(stay.centroidLatitude - entry.lat) > 0.0005
                        || abs(stay.centroidLongitude - entry.lon) > 0.0005 {
                        guard let fresh = await GeocodeResolver.shared.resolve(
                            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude
                        ) else { continue }
                        result = fresh
                    }
                    if let trip = stay.trip {
                        let identity = ObjectIdentifier(trip)
                        if titleSnapshots[identity] == nil {
                            titleSnapshots[identity] =
                                TripTitleStore.ParentSemanticSnapshot(
                                    trip: trip,
                                    semantic: TripTitleStore.semanticSnapshot(
                                        for: trip))
                        }
                    }
                    // Country-name guard — shared definition: `Result.localityForStorage`.
                    // Outer non-nil test preserves clear-vs-keep semantics (guard
                    // fired → clear; no candidate → keep existing value).
                    if result.bestLocalityName != nil {
                        stay.locality = result.localityForStorage
                    } else if result.isStaleLandmassLocality(stay.locality) {
                        // Clear a landmass-derived locality when the resolver's size cap demotes that landmass.
                        stay.locality = nil
                    }
                    // Coalesce, don't wipe: island-only hits can omit country/ISO;
                    // keep known values so country-based views remain consistent.
                    stay.administrativeArea = result.administrativeArea ?? stay.administrativeArea
                    stay.country = result.country ?? stay.country
                    stay.isoCountryCode = result.isoCountryCode ?? stay.isoCountryCode
                    // Coalesce dedicated place fields too: centroid drift can miss a previously matched polygon.
                    stay.subLocality = result.subLocalityName ?? stay.subLocality
                    stay.metroName = result.metroName ?? stay.metroName
                    if let island = result.islandName {
                        stay.islandName = island
                    } else if result.demotedIslandName != nil {
                        // A confirmed demoted landmass must not survive the island-name coalesce.
                        stay.islandName = nil
                    }
                    applied += 1
                }
                let changedTrips: Int
                do {
                    changedTrips = try TripTitleStore.invalidateChangedParentTitles(
                        from: Array(titleSnapshots.values), in: context)
                    try context.save()
                } catch {
                    context.rollback()
                    logger.error("Per-chunk stay save failed: \(error.localizedDescription)")
                    return (0, 0, false)
                }
                return (applied, changedTrips, true)
            }
            updatedStays += outcome.applied
            recomputedTrips += outcome.changedTrips
            if !outcome.ok { allSaved = false }
            await fireGeocoderBackfillInterChunkProbe()
        }

        // Phase 5 (UNGATED): resolve immutable hex CENTERS; no drift guard is needed.
        // Do not reuse the ping-coordinate memo: different points within one cell can resolve differently.
        // Same-UUID HexVisits can be different cells, so each row keeps its own cell witness.
        var hexResolutions: [(identifier: PersistentIdentifier, id: UUID, cell: String,
                              r: GeocodeResolver.Result)] = []
        do {
            var hexSnapshots: [(identifier: PersistentIdentifier, id: UUID, cell: String,
                                lat: Double, lon: Double)] = []
            let snapshotContext = ModelContext(modelContainer)
            if let hexVisits = try? snapshotContext.fetch(FetchDescriptor<HexVisit>()) {
                hexSnapshots = hexVisits.map {
                    ($0.persistentModelID, $0.id, $0.h3Index, $0.centerLatitude, $0.centerLongitude)
                }
            } else {
                allSaved = false
            }
            for snapshot in hexSnapshots {
                if let r = await GeocodeResolver.shared.resolve(
                    latitude: snapshot.lat, longitude: snapshot.lon
                ) {
                    hexResolutions.append((snapshot.identifier, snapshot.id, snapshot.cell, r))
                }
            }
        }

        // ---------- Phase 6 (GATED, chunked): apply hex resolutions ----------
        var updatedHexVisits = 0
        var hexIndex = 0
        while hexIndex < hexResolutions.count {
            let chunk = Array(hexResolutions[hexIndex ..< min(hexIndex + Self.geocoderBackfillHexChunk, hexResolutions.count)])
            hexIndex += chunk.count
            let outcome: (applied: Int, ok: Bool) = await gate.runReturning(touching: [.hexVisit]) {
                let context = ModelContext(modelContainer)
                let ids = chunk.map(\.id)
                let predicate = #Predicate<HexVisit> { ids.contains($0.id) }
                // A HexVisit ID repair can re-key a row after the snapshot; the
                // identifier lookup still finds it.
                guard let rows = try? context.fetch(FetchDescriptor<HexVisit>(predicate: predicate)),
                      let byIdentifier = try? Self.physicalBackfillRows(
                        for: chunk.map(\.identifier), fetchedByUUID: rows, fetchOne: { identifier in
                            try context.fetch(FetchDescriptor<HexVisit>(
                                predicate: #Predicate<HexVisit> { $0.persistentModelID == identifier })).first
                        }) else {
                    return (0, false)
                }
                var applied = 0
                for entry in chunk {
                    guard let hex = byIdentifier[entry.identifier], hex.h3Index == entry.cell else { continue }
                    let r = entry.r
                    // Country-name guard — shared definition: `Result.localityForStorage`.
                    // Outer non-nil test preserves clear-vs-keep semantics.
                    if r.bestLocalityName != nil {
                        hex.locality = r.localityForStorage
                    } else if r.isStaleLandmassLocality(hex.locality) {
                        hex.locality = nil  // `_v9`, see the Stay block above
                    }
                    // Coalesce instead of wipe — see Stay block above for
                    // the rationale.
                    hex.country = r.country ?? hex.country
                    hex.isoCountryCode = r.isoCountryCode ?? hex.isoCountryCode
                    applied += 1
                }
                do { try context.save() } catch {
                    logger.error("Per-chunk hex save failed: \(error.localizedDescription)")
                    return (applied, false)
                }
                return (applied, true)
            }
            updatedHexVisits += outcome.applied
            if !outcome.ok { allSaved = false }
            await fireGeocoderBackfillInterChunkProbe()
        }

        return (
            updatedStays: updatedStays,
            updatedPings: updatedPings,
            updatedHexVisits: updatedHexVisits,
            recomputedTrips: recomputedTrips,
            saved: allSaved
        )
    }

    /// Each apply chunk owns one short gate unit so wake-ping saves wait at most one chunk.
    /// Stay chunks are smaller because centroid drift can require re-resolution.
    nonisolated static let geocoderBackfillPingChunk = 500
    nonisolated static let geocoderBackfillStayChunk = 100
    nonisolated static let geocoderBackfillHexChunk = 200

    /// Apply-chunk rows keyed by physical identity, so each UUID twin takes its
    /// own snapshot's result. The one UUID fetch covers the chunk; an entry it
    /// missed (re-keyed or deleted since the snapshot) is looked up by identifier.
    /// A deleted row is skipped; a failed read throws.
    nonisolated private static func physicalBackfillRows<T: PersistentModel>(
        for identifiers: [PersistentIdentifier], fetchedByUUID: [T],
        fetchOne: (PersistentIdentifier) throws -> T?
    ) throws -> [PersistentIdentifier: T] {
        var rows: [PersistentIdentifier: T] = [:]
        for row in fetchedByUUID where !row.isDeleted { rows[row.persistentModelID] = row }
        for identifier in identifiers where rows[identifier] == nil {
            if let row = try fetchOne(identifier), !row.isDeleted { rows[identifier] = row }
        }
        return rows
    }
}
