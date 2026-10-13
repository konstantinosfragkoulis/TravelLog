//
//  PingRecorder+Geocoding.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import WidgetKit
import os.log

extension PingRecorder {

    private func saveGeocodeChanges() throws {
        #if DEBUG
        if geocodeSaveFailuresForTesting > 0 {
            geocodeSaveFailuresForTesting -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
        try modelContext.save()
    }

    /// Snapshot a titled parent before a geocoder mutates any prompt-relevant
    /// Stay place field. Each geocode batch reconciles these snapshots before
    /// its own durable save, so an app termination between chunks cannot leave
    /// a now-stale canonical/localized title behind.
    private func captureGeocodeTitleSnapshot(
        for stay: Stay,
        in snapshots: inout ParentTitleSnapshots
    ) {
        guard let trip = stay.trip else { return }
        let identity = ObjectIdentifier(trip)
        guard snapshots[identity] == nil else { return }
        snapshots[identity] = TripTitleStore.ParentSemanticSnapshot(
            trip: trip,
            semantic: TripTitleStore.semanticSnapshot(for: trip))
    }

    /// Recompute changed parents' summaries and clear their generated titles in the same save
    /// as the Stay edits: an interrupted drain must not leave `destinationSummary` or
    /// `countryCodes` behind committed place fields.
    @discardableResult
    private func invalidateGeocodeTitlesIfNeeded(
        _ snapshots: inout ParentTitleSnapshots
    ) throws -> Int {
        defer { snapshots.removeAll(keepingCapacity: true) }
        return try TripTitleStore.invalidateChangedParentTitles(
            from: Array(snapshots.values), in: modelContext)
    }

    private func noteGeocodeTripChange() {
        geocodeTripChange.formUnion(StoreChange.pending(in: modelContext).intersection(.trip))
    }

    func takeGeocodeTripChange() -> StoreChange {
        defer { geocodeTripChange = [] }
        return geocodeTripChange
    }

    /// Retry one oldest ungeocoded ping per SLC wake so stalled rows get priority.
    /// The offline resolver requires no throttle gate.
    /// Internal test seam for opportunistic skip-window progression.
    /// Returns the tracked types its save wrote (a title invalidation writes `.trip`).
    @discardableResult
    func tryOneOpportunisticGeocoding() async -> StoreChange {
        // Roll back no-op geocoding when nothing else was pending: an unsaved dirty row
        // can later overwrite StayClusterer's `isProcessed` update and cause duplicate clustering.
        let hadPendingChanges = modelContext.hasChanges
        let predicate = #Predicate<LocationPing> { $0.isGeocoded == false }
        var descriptor = FetchDescriptor<LocationPing>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        // Window sized from the skip set, NOT a constant: with a fixed limit,
        // that many unresolvable oldest rows would fill the skip set and then
        // every wake would fetch exactly those rows and bail — permanently
        // stalling the lane for resolvable rows behind them. `count + 1`
        // guarantees at least one not-yet-skipped candidate is examined until
        // the set hits its cap (whereupon this lane concedes to the full
        // Settings drain, which covers every row).
        descriptor.fetchLimit = opportunisticGeocodeSkipIDs.count + 1

        guard let pings = try? modelContext.fetch(descriptor),
              let ping = pings.first(where: { !opportunisticGeocodeSkipIDs.contains($0.persistentModelID) }) else { return [] }

        let result = await GeocodeResolver.shared.resolve(
            latitude: ping.latitude,
            longitude: ping.longitude
        )
        ping.applyResolverResult(result)

        // Do not propagate empty resolver data: the ping remains ungeocoded and no Stay can benefit.
        guard ping.isGeocoded else {
            if opportunisticGeocodeSkipIDs.count < 512 {
                opportunisticGeocodeSkipIDs.insert(ping.persistentModelID)
            }
            if !hadPendingChanges { modelContext.rollback() }
            return []
        }

        // The just-geocoded ping's parent Stay might still have nil locality;
        // propagate to it so SwiftUI consumers refresh.
        var titleSnapshots: ParentTitleSnapshots = [:]
        do {
            try propagateGeocodingToStays(
                geocodedPingIDs: [ping.id],
                titleSnapshots: &titleSnapshots)
        } catch {
            // A failed read is not absence: never save the ping without its Stay propagation.
            modelContext.rollback()
            logger.error("Opportunistic SLC retry propagation read failed: \(error.localizedDescription)")
            return [.locationPing, .hexVisit, .stay]
        }
        do {
            try invalidateGeocodeTitlesIfNeeded(&titleSnapshots)
        } catch {
            // A summary built without its home-place filter must not commit with the ping.
            modelContext.rollback()
            logger.error("Opportunistic SLC retry summary read failed: \(error.localizedDescription)")
            return [.locationPing, .hexVisit, .stay]
        }

        var changes = StoreChange.pending(in: modelContext)
        do {
            try modelContext.save()
            logger.debug("Opportunistic SLC retry: 1 ping geocoded via offline resolver.")
        } catch {
            // Fail open to the set the live ping unit always declared.
            changes.formUnion([.locationPing, .hexVisit, .stay])
            modelContext.rollback()
            logger.error("Opportunistic SLC retry save failed: \(error.localizedDescription)")
        }
        return changes
    }

    /// Retry offline geocoding for a bounded bite of pings, propagate to parent stays still
    /// missing locality, then attempt a bite of locality-nil stay centroids even when no ping
    /// is pending. `progress` counts persisted changes, not attempts; `failed` means a required
    /// read or save threw and that step rolled back, so callers must not treat it as done.
    @discardableResult
    func retryFailedGeocoding(limit: Int = 20) async -> (progress: Int, failed: Bool) {
        let predicate = #Predicate<LocationPing> { $0.isGeocoded == false }
        var descriptor = FetchDescriptor<LocationPing>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        var progress = 0
        do {
            let ungeocodedPings = try modelContext.fetch(descriptor)
            if !ungeocodedPings.isEmpty {
                logger.info("Retrying geocoding for \(ungeocodedPings.count) ping(s) via offline resolver.")

                // Collect successfully geocoded ping IDs to propagate to stays.
                // The companion snapshot map makes the place writes, summaries and
                // title invalidation one durable transaction.
                var geocodedPingIDs: [UUID] = []
                var titleSnapshots: ParentTitleSnapshots = [:]

                for ping in ungeocodedPings {
                    let result = await GeocodeResolver.shared.resolve(
                        latitude: ping.latitude,
                        longitude: ping.longitude
                    )
                    ping.applyResolverResult(result)
                    if ping.isGeocoded {
                        geocodedPingIDs.append(ping.id)
                    }
                }

                // Propagate geocoding data to parent stays that still have nil locality.
                if !geocodedPingIDs.isEmpty {
                    try propagateGeocodingToStays(
                        geocodedPingIDs: geocodedPingIDs,
                        titleSnapshots: &titleSnapshots)
                }

                try invalidateGeocodeTitlesIfNeeded(&titleSnapshots)
                noteGeocodeTripChange()
                try saveGeocodeChanges()
                logger.info("Geocoding retry complete. \(geocodedPingIDs.count) ping(s) geocoded.")
                progress = geocodedPingIDs.count
            }
        } catch {
            modelContext.rollback()
            logger.error("Geocoding retry failed: \(error.localizedDescription)")
            return (0, true)
        }

        // Centroid fallback is real progress even when no ping count decreases. It shares this
        // bite's bound so a caller's gate unit stays short.
        do {
            progress += try await geocodeStayCentroids(eligibleStayRows(limit: limit))
        } catch {
            return (progress, true)
        }
        return (progress, false)
    }

    /// Find stays that contain the given ping IDs and backfill geocoding data
    /// from the first geocoded ping in that stay. Both reads are required: a failure
    /// throws so the caller rolls back instead of saving pings without their stays.
    /// Work bound: this reads every locality-nil stay, so a caller's unit is bounded by that
    /// backlog, not by its ping count. No stored ping-to-stay index exists (the link lives in
    /// `pingIDsString`), and paging this scan across units would commit pings before their
    /// stays, which the one-save coupling above forbids.
    private func propagateGeocodingToStays(
        geocodedPingIDs: [UUID],
        titleSnapshots: inout ParentTitleSnapshots
    ) throws {
        let stayPredicate = #Predicate<Stay> { $0.locality == nil }
        let stayDescriptor = FetchDescriptor<Stay>(predicate: stayPredicate)

        #if DEBUG
        try injectGeocodeReadFault(.propagation)
        #endif
        let stays = try modelContext.fetch(stayDescriptor)
        guard !stays.isEmpty else { return }

        let geocodedSet = Set(geocodedPingIDs)
        var backfilledCount = 0

        for stay in stays {
            let matchingIDs = stay.pingIDs.filter { geocodedSet.contains($0) }
            guard !matchingIDs.isEmpty else { continue }

            if let pingID = matchingIDs.first {
                let id = pingID
                let pingPredicate = #Predicate<LocationPing> {
                    $0.id == id && $0.isGeocoded == true
                }
                var pingDescriptor = FetchDescriptor<LocationPing>(predicate: pingPredicate)
                pingDescriptor.fetchLimit = 1

                if let ping = try modelContext.fetch(pingDescriptor).first {
                    // Coalesce, don't wipe, matching applyResolverResult:
                    // a sibling ping's nil country/ISO must not erase known Stay values.
                    captureGeocodeTitleSnapshot(for: stay, in: &titleSnapshots)
                    stay.locality = ping.locality ?? stay.locality
                    stay.administrativeArea = ping.administrativeArea ?? stay.administrativeArea
                    stay.country = ping.country ?? stay.country
                    stay.isoCountryCode = ping.isoCountryCode ?? stay.isoCountryCode
                    backfilledCount += 1
                }
            }
        }

        if backfilledCount > 0 {
            logger.info("Propagated geocoding to \(backfilledCount) stay(s).")
        }
    }

    private static let hexPingPageSize = 500
    /// Associated locality-nil Stay rows one hex unit may fetch, across all its cells.
    private static let hexStayPageSize = 500

    /// Value-only cursor: models and the context never cross the gate boundary.
    private struct HexGeocodeCursor: Sendable {
        let keys: [String]
        var index = 0
        var result: GeocodeResolver.Result?
        var remainingRows = 0
        var pages = 0
        var pageLimit = 0
        var unresolvedRows: Set<PersistentIdentifier> = []
        /// Locality-nil stays of the current cell still to visit, counted once when the cell
        /// resolves, so stays arriving mid-cell cannot extend it (the centroid phase takes them).
        var remainingStays = 0
        /// Visited stays that stay locality-nil (country guard or country-only answer); filled
        /// stays leave the predicate by themselves.
        var visitedStays: Set<PersistentIdentifier> = []
        /// A required read or save threw and the page rolled back; the driver stops.
        var failed = false

        mutating func advance() {
            index += 1
            result = nil
            remainingRows = 0
            pages = 0
            unresolvedRows.removeAll(keepingCapacity: true)
            remainingStays = 0
            visitedStays.removeAll(keepingCapacity: true)
        }
    }

    /// Resolve each res-6 hex center once; each unit visits at most 50 cells and fetches at most
    /// 500 ping rows and 500 associated locality-nil Stay rows.
    /// A supplied gate belongs to each page, never the entire drain.
    @discardableResult
    func geocodeByUniqueHex(limitToHexes: [String]? = nil, gate: PipelineGate? = nil) async -> Int {
        await runHexGeocodePhase(limitToHexes: limitToHexes, gate: gate).progress
    }

    /// `completed` is false after a failed required read or save (fail fast: storage failures
    /// are usually systemic), cancellation, or a thermal pause.
    private func runHexGeocodePhase(
        limitToHexes: [String]?, gate: PipelineGate?
    ) async -> (progress: Int, completed: Bool) {
        #if DEBUG
        hexPageStatsForTesting = ([], 0, [])
        #endif
        let ungeocodedPredicate: Predicate<LocationPing>
        if let hexes = limitToHexes {
            ungeocodedPredicate = #Predicate<LocationPing> {
                $0.isGeocoded == false && hexes.contains($0.h3IndexRes6)
            }
        } else {
            ungeocodedPredicate = #Predicate<LocationPing> { $0.isGeocoded == false }
        }
        let descriptor = FetchDescriptor<LocationPing>(predicate: ungeocodedPredicate)
        let keys: [String]
        let ungeocodedCount: Int
        do {
            keys = try limitToHexes ?? listUngeocodedHexKeys()
            ungeocodedCount = try modelContext.fetchCount(descriptor)
        } catch {
            logger.error("geocodeByUniqueHex backlog read failed: \(error.localizedDescription)")
            return (0, false)
        }
        guard ungeocodedCount > 0 else { return (0, true) }
        var cursor = HexGeocodeCursor(keys: keys)
        var pingsGeocoded = 0
        var completed = true
        logger.info("geocodeByUniqueHex: \(ungeocodedCount) ungeocoded ping(s) across \(cursor.keys.count) unique hex(es).")
        while cursor.index < cursor.keys.count {
            if Task.isCancelled {
                logger.info("geocodeByUniqueHex cancelled at \(cursor.index)/\(cursor.keys.count) hex(es); \(pingsGeocoded) ping(s) geocoded.")
                completed = false
                break
            }
            if ProcessInfo.processInfo.thermalState == .critical || (gate != nil && shouldPauseDrainForHeat) {
                logger.info("geocodeByUniqueHex stopping at \(cursor.index)/\(cursor.keys.count) hex(es) — thermal pause")
                completed = false
                break
            }
            let input = cursor
            let page: (HexGeocodeCursor, Int)
            if let gate {
                page = await gate.runReturning(touching: [.stay, .locationPing, .hexVisit]) {
                    let page = await self.geocodeHexPage(input)
                    // A geocoded locality can clear a generated title or move a summary.
                    await StoreChangeTracker.shared.bump(await self.takeGeocodeTripChange())
                    return page
                }
            } else {
                page = await geocodeHexPage(input)
            }
            cursor = page.0
            pingsGeocoded += page.1
            #if DEBUG
            if let afterHexPageForTesting { await afterHexPageForTesting() }
            #endif
            if cursor.failed {
                completed = false
                break
            }
            await Task.yield()
        }
        let hexesProcessed = cursor.index
        logger.info("geocodeByUniqueHex complete: processed \(hexesProcessed) hex(es), geocoded \(pingsGeocoded) ping(s).")
        return (pingsGeocoded, completed && !Task.isCancelled)
    }

    private func geocodeHexPage(_ input: HexGeocodeCursor) async -> (HexGeocodeCursor, Int) {
        var cursor = input
        let endIndex = min(cursor.index + Self.gatedHexChunkSize, cursor.keys.count)
        var rowsFetched = 0
        var stayRowsFetched = 0
        var hexVisitTouched = false
        var pingsGeocoded = 0
        var titleSnapshots: ParentTitleSnapshots = [:]

        do {
            while cursor.index < endIndex
                    && rowsFetched < Self.hexPingPageSize
                    && stayRowsFetched < Self.hexStayPageSize {
                if Task.isCancelled || ProcessInfo.processInfo.thermalState == .critical { break }
                let h3 = cursor.keys[cursor.index]
                if cursor.result == nil {
                    guard let center = H3Service.centerCoordinate(for: h3) else {
                        cursor.advance()
                        continue
                    }
                    let result: GeocodeResolver.Result?
                    #if DEBUG
                    if let hexResolverForTesting {
                        result = await hexResolverForTesting(center.latitude, center.longitude)
                    } else {
                        result = await GeocodeResolver.shared.resolve(latitude: center.latitude, longitude: center.longitude)
                    }
                    #else
                    result = await GeocodeResolver.shared.resolve(latitude: center.latitude, longitude: center.longitude)
                    #endif
                    guard let result else {
                        // True no-result hex (mid-ocean / polar): leave its pings ungeocoded.
                        cursor.advance()
                        continue
                    }
                    cursor.result = result
                    let predicate = #Predicate<LocationPing> { $0.isGeocoded == false && $0.h3IndexRes6 == h3 }
                    cursor.remainingRows = try modelContext.fetchCount(FetchDescriptor(predicate: predicate))
                    // Associated rows are healed only for a cell that still has pings to geocode.
                    guard cursor.remainingRows > 0 else {
                        cursor.advance()
                        continue
                    }
                    // One extra attempt allows a cell to begin in a partly filled unit.
                    // Concurrent arrivals cannot extend this drain indefinitely.
                    cursor.pageLimit = (cursor.remainingRows + Self.hexPingPageSize - 1) / Self.hexPingPageSize + 1
                    #if DEBUG
                    hexPageStatsForTesting.associatedUpdates += 1
                    #endif
                    // Backfill missing HexVisit fields, never overwrite. One row per cell.
                    let hexPredicate = #Predicate<HexVisit> { $0.h3Index == h3 }
                    if let hex = try modelContext.fetch(FetchDescriptor<HexVisit>(predicate: hexPredicate)).first {
                        hexVisitTouched = true
                        if hex.locality == nil { hex.locality = result.localityForStorage }
                        if hex.country == nil {
                            hex.country = result.country
                            hex.isoCountryCode = result.isoCountryCode
                        } else if hex.isoCountryCode == nil, hex.country == result.country {
                            // Heal ISO only when the country pair stays consistent.
                            hex.isoCountryCode = result.isoCountryCode
                        }
                    }
                    let stayCountPredicate = #Predicate<Stay> {
                        $0.h3IndexRes6 == h3 && $0.locality == nil
                    }
                    cursor.remainingStays = try modelContext.fetchCount(
                        FetchDescriptor<Stay>(predicate: stayCountPredicate))
                }
                guard let result = cursor.result else { break }

                // Associated locality-nil stays come first, in pages that share the unit's stay
                // budget, so a cell holding thousands of them cannot hold the gate.
                if cursor.remainingStays > 0 {
                    let visited = cursor.visitedStays
                    let stayPredicate = #Predicate<Stay> {
                        $0.h3IndexRes6 == h3 && $0.locality == nil
                            && !visited.contains($0.persistentModelID)
                    }
                    var stayDescriptor = FetchDescriptor<Stay>(predicate: stayPredicate)
                    stayDescriptor.fetchLimit = min(
                        Self.hexStayPageSize - stayRowsFetched, cursor.remainingStays)
                    let stays = try modelContext.fetch(stayDescriptor)
                    guard !stays.isEmpty else {
                        cursor.remainingStays = 0
                        continue
                    }
                    stayRowsFetched += stays.count
                    cursor.remainingStays = max(0, cursor.remainingStays - stays.count)
                    let resolvedLocality = result.localityForStorage
                    for stay in stays {
                        // The hex centre is coarser than the stay's own centroid: never move a stay to another country.
                        if let known = stay.isoCountryCode, let incoming = result.isoCountryCode, known != incoming {
                            cursor.visitedStays.insert(stay.persistentModelID)
                            continue
                        }
                        if stay.isoCountryCode == nil, let known = stay.country, let incoming = result.country, known != incoming {
                            cursor.visitedStays.insert(stay.persistentModelID)
                            continue
                        }
                        // Fill only missing fields, so restored or centroid values survive.
                        captureGeocodeTitleSnapshot(for: stay, in: &titleSnapshots)
                        stay.locality = resolvedLocality ?? stay.locality
                        stay.administrativeArea = stay.administrativeArea ?? result.administrativeArea
                        stay.country = stay.country ?? result.country
                        stay.isoCountryCode = stay.isoCountryCode ?? result.isoCountryCode
                        // A country-only answer leaves the row in the predicate: never refetch it.
                        if stay.locality == nil { cursor.visitedStays.insert(stay.persistentModelID) }
                    }
                    continue
                }

                if cursor.pages >= cursor.pageLimit {
                    logger.info("geocodeByUniqueHex reached page cap \(cursor.pageLimit) for \(h3); remaining rows wait for the next drain.")
                    cursor.advance()
                    continue
                }
                let excluded = cursor.unresolvedRows
                let predicate = #Predicate<LocationPing> {
                    $0.isGeocoded == false && $0.h3IndexRes6 == h3 && !excluded.contains($0.persistentModelID)
                }
                var descriptor = FetchDescriptor<LocationPing>(predicate: predicate)
                let pageSize = min(Self.hexPingPageSize - rowsFetched, cursor.remainingRows)
                descriptor.fetchLimit = pageSize
                guard pageSize > 0 else {
                    cursor.advance()
                    continue
                }
                let pings = try modelContext.fetch(descriptor)
                guard !pings.isEmpty else {
                    cursor.advance()
                    continue
                }
                cursor.pages += 1
                rowsFetched += pings.count
                cursor.remainingRows -= pings.count
                for ping in pings {
                    ping.applyResolverResult(result)
                    if ping.isGeocoded {
                        pingsGeocoded += 1
                    } else {
                        cursor.unresolvedRows.insert(ping.persistentModelID)
                    }
                }
                if cursor.remainingRows == 0 { cursor.advance() }
            }
            #if DEBUG
            hexPageStatsForTesting.rows.append(rowsFetched)
            hexPageStatsForTesting.stayRows.append(stayRowsFetched)
            #endif
            if rowsFetched > 0 || stayRowsFetched > 0 || hexVisitTouched {
                try invalidateGeocodeTitlesIfNeeded(&titleSnapshots)
                noteGeocodeTripChange()
                try saveGeocodeChanges()
            }
        } catch {
            // A failed read is not absence: the whole unsaved page rolls back.
            modelContext.rollback()
            pingsGeocoded = 0
            cursor.failed = true
            // Do not immediately refetch a rolled-back page forever.
            if cursor.result != nil { cursor.advance() }
            logger.error("geocodeByUniqueHex page failed: \(error.localizedDescription)")
        }
        return (cursor, pingsGeocoded)
    }

    /// Per-launch drain authority, in two parts. `pingsAndHexes` is the ungeocoded count, newest
    /// timestamp and incomplete hex rows; the stay terms fingerprint locality-nil stays by physical
    /// row and the res-8 cell of their centroid (the witness granularity locality enrichment uses),
    /// so a stay moved into another cell counts while an ongoing stay's running-mean drift inside
    /// its cell does not. A settled stay excluded at its exact centroid also witnesses whether that
    /// exclusion still holds, so any move that lapses it counts. Skip only unchanged completed
    /// inputs; a change in the stay terms alone reruns only the stay phase. Do not persist: every
    /// first activation after launch must provide a full recovery pass.
    nonisolated struct GeocodeBacklogToken: Equatable {
        let pingsAndHexes: String
        let stayCount: Int
        let stayFingerprint: Int
    }

    private nonisolated struct StayBacklogWitness: Hashable {
        let id: PersistentIdentifier
        let cell: String
        let excluded: Bool
    }

    /// Nil when any term cannot be read: an unknown backlog never matches a recorded token.
    private func geocodeBacklogToken() -> GeocodeBacklogToken? {
        do {
            let ungeocoded = #Predicate<LocationPing> { $0.isGeocoded == false }
            let count = try modelContext.fetchCount(FetchDescriptor<LocationPing>(predicate: ungeocoded))
            var newestDescriptor = FetchDescriptor<LocationPing>(
                predicate: ungeocoded,
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            newestDescriptor.fetchLimit = 1
            newestDescriptor.propertiesToFetch = [\.timestamp]
            let newest = try modelContext.fetch(newestDescriptor).first?.timestamp.timeIntervalSinceReferenceDate ?? 0
            // The hex term MUST mirror backfillHexVisitCountries selection, including ISO-only gaps;
            // otherwise those backlog changes cannot trigger their repair.
            let hexPredicate = #Predicate<HexVisit> { $0.country == nil || $0.locality == nil }
            let hexCount = try modelContext.fetchCount(FetchDescriptor<HexVisit>(predicate: hexPredicate))
            // Counted separately rather than as a third OR clause: the combined
            // predicate exceeds the Swift type-checker's budget here.
            let isoPredicate = #Predicate<HexVisit> { $0.isoCountryCode == nil }
            let isoCount = try modelContext.fetchCount(FetchDescriptor<HexVisit>(predicate: isoPredicate))
            // The stay term mirrors the centroid phase's selection. Count and start time alone
            // miss an existing stay whose centroid moved into a resolvable area.
            var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.locality == nil })
            stayDescriptor.propertiesToFetch = [\.centroidLatitude, \.centroidLongitude]
            let stays = try modelContext.fetch(stayDescriptor)
            let stayFingerprint = Set(stays.map {
                StayBacklogWitness(
                    id: $0.persistentModelID,
                    cell: MapKitLocalityCache.cellKey(
                        latitude: $0.centroidLatitude, longitude: $0.centroidLongitude),
                    excluded: unresolvableStayIDs[$0.persistentModelID] == StayCentroid(
                        latitude: $0.centroidLatitude, longitude: $0.centroidLongitude))
            }).hashValue
            return GeocodeBacklogToken(
                pingsAndHexes: "\(count)|\(newest)|\(hexCount)|\(isoCount)",
                stayCount: stays.count,
                stayFingerprint: stayFingerprint)
        } catch {
            logger.error("Geocode backlog token read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Activation-path wrapper around the gated drain: skips it entirely
    /// when its inputs are unchanged since the last completed pass this
    /// launch, and runs only the stay phase when only locality-nil stays
    /// changed. Used by RootView's scenePhase hook (UNGATED — the drain
    /// takes the gate per chunk itself); the import-finalize and Settings
    /// callers use the unconditional `retryAllFailedGeocodingGated()`
    /// (explicit user/import intent).
    func retryAllFailedGeocodingIfNeeded(gate: PipelineGate = .shared) async {
        let token = geocodeBacklogToken()
        if let token, let last = lastDrainedBacklogToken {
            if token == last {
                logger.debug("Geocode drain skipped — backlog token unchanged (\(token.pingsAndHexes)).")
                return
            }
            if token.pingsAndHexes == last.pingsAndHexes {
                // A new stay or one moved into another cell: the ping and hex phases would
                // re-examine exactly the inputs the last completed drain already handled.
                let stayPhase = await runStayCentroidPhase(gate: gate)
                await reloadWidgetsAfterDrainProgress(stayPhase.progress)
                lastDrainedBacklogToken = stayPhase.completed && !Task.isCancelled ? token : nil
                return
            }
        }
        let completed = await retryAllFailedGeocodingGated(gate: gate)
        // Latch only a COMPLETED drain: failure, cancellation or thermal pause must remain
        // retryable on later activation even when backlog counts are unchanged. Record the
        // PRE-run token, the inputs this drain actually examined: rows that arrive or move
        // during the drain change the next token and get their own pass. A drain that made
        // progress therefore costs one confirming pass, which finds nothing and latches.
        lastDrainedBacklogToken = completed ? token : nil
    }

    /// Each hex-phase gate unit visits at most 50 cells and fetches at most 500 ping rows and
    /// 500 associated Stay rows.
    private static let gatedHexChunkSize = 50

    /// Distinct H3 keys of the ungeocoded backlog — one column-projected
    /// pass (`propertiesToFetch`) instead of materializing full rows.
    /// Sorted for deterministic chunk boundaries.
    private func listUngeocodedHexKeys() throws -> [String] {
        var descriptor = FetchDescriptor<LocationPing>(
            predicate: #Predicate { $0.isGeocoded == false }
        )
        descriptor.propertiesToFetch = [\.h3IndexRes6]
        let pings = try modelContext.fetch(descriptor)
        return Set(pings.map(\.h3IndexRes6)).sorted()
    }

    /// Idempotent backlog drain for import finalization, Settings, and foreground activation.
    /// Each bounded chunk owns its gate unit so SLC wake saves can interleave within ~10 seconds.
    /// Callers MUST NOT wrap this method in PipelineGate.run: nested acquisition deadlocks.
    /// Actor serialization coordinates concurrent callers.
    /// Polygon resolution and SwiftData writes consume CPU; stop at thermal `.serious`
    /// and resume after cooling. Low Power Mode deliberately does not stop progress because
    /// it can persist for days; yield between chunks to keep work cooperative.
    private var shouldPauseDrainForHeat: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// True means natural completion with every required read and save succeeding. A failed
    /// unit (rolled back), thermal pause or cancellation returns false, which callers MUST NOT
    /// latch as completed backlog handling. Earlier committed units stand either way.
    @discardableResult
    func retryAllFailedGeocodingGated(gate: PipelineGate = .shared) async -> Bool {
        let drain = await runGeocodeDrainPhases(gate: gate)
        await reloadWidgetsAfterDrainProgress(drain.progress)
        return drain.completed && !Task.isCancelled
    }

    /// Widget timelines only need a reload when something changed; a per-activation reload
    /// spins up the widget extension for nothing. Publish on every exit: a later failed or
    /// interrupted unit must not hide earlier durable work.
    private func reloadWidgetsAfterDrainProgress(_ progress: Int) async {
        guard progress > 0 else { return }
        await MainActor.run {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Phases in order: hex-first pings, remaining pings by ID, stay centroids, HexVisit heal.
    /// Every unit commits its own Stay edits with the parents' summaries and titles, so no
    /// whole-store tail step is needed and an interrupted drain leaves nothing stale.
    private func runGeocodeDrainPhases(gate: PipelineGate) async -> (progress: Int, completed: Bool) {
        // The hex driver owns one gate unit per bounded page, reusing each cell's resolution.
        let hexPhase = await runHexGeocodePhase(limitToHexes: nil, gate: gate)
        var progress = hexPhase.progress
        if hexPhase.progress > 0 {
            logger.info("retryAllFailedGeocodingGated: hex-first phase geocoded \(hexPhase.progress) ping(s).")
        }
        guard hexPhase.completed, !Task.isCancelled, !shouldPauseDrainForHeat else {
            return (progress, false)
        }

        // Retry every remaining ping by ID in bounded gate units: a hex-center miss can
        // still resolve at an individual ping's coordinates. Snapshot all IDs each pass;
        // a newest-N limit can strand older resolvable rows behind unresolvable newer ones.
        // Stop only when a FULL pass geocodes nothing, so unresolvable backlog cannot spin
        // forever or mask unattempted rows.
        let chunkSize = 200
        var totalGeocoded = 0
        var pass = 0
        while !Task.isCancelled {
            if shouldPauseDrainForHeat {
                logger.info("retryAllFailedGeocodingGated pausing in Phase 1 pass \(pass) — thermalState \(String(describing: ProcessInfo.processInfo.thermalState.rawValue)); resumes on next foreground.")
                return (progress, false)
            }
            let remainingIDs: [UUID]
            do {
                remainingIDs = try listUngeocodedPingIDs()
            } catch {
                // A failed read is not an empty backlog.
                logger.error("retryAllFailedGeocodingGated ID read failed: \(error.localizedDescription)")
                return (progress, false)
            }
            if remainingIDs.isEmpty {
                logger.info("retryAllFailedGeocodingGated drained backlog after \(pass) Phase-1 pass(es); \(totalGeocoded) geocoded.")
                break
            }
            var passGeocoded = 0
            var i = 0
            while i < remainingIDs.count {
                if Task.isCancelled || shouldPauseDrainForHeat { return (progress, false) }
                let chunk = Array(remainingIDs[i ..< min(i + chunkSize, remainingIDs.count)])
                i += chunk.count
                let unit: (progress: Int, failed: Bool) =
                    await gate.runReturning(touching: [.stay, .locationPing, .hexVisit]) {
                        let outcome = await self.geocodePings(ids: chunk)
                        // A geocoded locality can clear a generated title or move a summary.
                        await StoreChangeTracker.shared.bump(await self.takeGeocodeTripChange())
                        return outcome
                    }
                if unit.failed { return (progress, false) }
                passGeocoded += unit.progress
                progress += unit.progress
                await Task.yield()
            }
            totalGeocoded += passGeocoded
            pass += 1
            if passGeocoded == 0 {
                logger.info("retryAllFailedGeocodingGated stopping after \(pass) Phase-1 pass(es): \(remainingIDs.count) unresolvable ping(s) remain (full sweep made no progress).")
                break
            }
        }
        if Task.isCancelled { return (progress, false) }

        // Stay centroids run whether or not pings remain: restored, late or moved stays can
        // be the whole backlog.
        let stayPhase = await runStayCentroidPhase(gate: gate)
        progress += stayPhase.progress
        guard stayPhase.completed else { return (progress, false) }

        // HexVisit heal does not feed summaries or widgets; its units publish `.hexVisit` only
        // when they change a row, so a no-op activation bumps nothing.
        let heal = await backfillHexVisitCountries(gate: gate)
        return (progress, heal.completed)
    }

    /// Ids of every ping still needing geocoding (id-only fetch — no row
    /// hydration). Ordering is irrelevant: the Phase-1 sweep attempts all of
    /// them each pass, and resolved ones drop out of the next snapshot.
    private func listUngeocodedPingIDs() throws -> [UUID] {
        #if DEBUG
        try injectGeocodeReadFault(.ungeocodedPingIDs)
        #endif
        let predicate = #Predicate<LocationPing> { $0.isGeocoded == false }
        var descriptor = FetchDescriptor<LocationPing>(predicate: predicate)
        descriptor.propertiesToFetch = [\.id]
        return try modelContext.fetch(descriptor).map(\.id)
    }

    /// Geocode specified ping IDs and propagate to their parent stays; return committed pings.
    /// Walking the full ID snapshot prevents newest-first bias from stranding older resolvable rows.
    private func geocodePings(ids: [UUID]) async -> (progress: Int, failed: Bool) {
        guard !ids.isEmpty else { return (0, false) }
        let predicate = #Predicate<LocationPing> { ids.contains($0.id) && $0.isGeocoded == false }
        do {
            let pings = try modelContext.fetch(FetchDescriptor<LocationPing>(predicate: predicate))
            guard !pings.isEmpty else { return (0, false) }

            var geocodedPingIDs: [UUID] = []
            var titleSnapshots: ParentTitleSnapshots = [:]
            for ping in pings {
                let result = await GeocodeResolver.shared.resolve(
                    latitude: ping.latitude,
                    longitude: ping.longitude
                )
                // No answer would only re-assign `isGeocoded = false` to a row selected for
                // being ungeocoded; skip it so a permanent backlog is not dirtied every drain.
                guard let answer = result else { continue }
                ping.applyResolverResult(answer)
                if ping.isGeocoded {
                    geocodedPingIDs.append(ping.id)
                }
            }

            if !geocodedPingIDs.isEmpty {
                try propagateGeocodingToStays(
                    geocodedPingIDs: geocodedPingIDs,
                    titleSnapshots: &titleSnapshots)
            }
            try invalidateGeocodeTitlesIfNeeded(&titleSnapshots)
            noteGeocodeTripChange()
            try saveGeocodeChanges()
            return (geocodedPingIDs.count, false)
        } catch {
            modelContext.rollback()
            logger.error("geocodePings(ids:) failed: \(error.localizedDescription)")
            return (0, true)
        }
    }

    private static let unresolvableSettleSeconds: TimeInterval = 48 * 60 * 60
    private static let stayDrainAttemptCap = 200
    /// Each stay-centroid drain unit attempts at most this many stays.
    private static let stayDrainUnitSize = 50

    nonisolated struct StayCentroid: Hashable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    /// Snapshot place fields to measure actual CHANGE, the drain's termination oracle.
    /// Country-without-locality hits remain in the locality-nil fetch, so counting non-nil state
    /// as progress would loop forever and bypass unresolvable exclusion.
    nonisolated struct StayPlaceFields: Equatable {
        var locality: String?
        var country: String?
        var isoCountryCode: String?
        var administrativeArea: String?

        /// Coalesce, don't wipe: a nil resolver field never overwrites a known value.
        func coalescing(
            locality: String?,
            country: String?,
            isoCountryCode: String?,
            administrativeArea: String?
        ) -> StayPlaceFields {
            StayPlaceFields(
                locality: locality ?? self.locality,
                country: country ?? self.country,
                isoCountryCode: isoCountryCode ?? self.isoCountryCode,
                administrativeArea: administrativeArea ?? self.administrativeArea
            )
        }
    }

    /// Pure shared decision for drain progress and unresolvable exclusion;
    /// the call site must use this result so its behavior cannot drift from the tested rule.
    nonisolated enum StayGeocodeOutcome: Equatable {
        /// The answer genuinely added something: write the fields, count progress.
        case progressed(StayPlaceFields)
        /// Exclude settled no-gain stays so they cannot occupy the newest-first window forever.
        case exhausted
        /// Retry recent no-gain stays after possible centroid drift, but do NOT count progress.
        case retryLater
    }

    /// Count a resolver answer only when fields CHANGE; country-without-locality state
    /// alone must never keep the drain alive or bypass settled-stay exclusion.
    nonisolated static func stayGeocodeOutcome(
        current: StayPlaceFields,
        resolvedLocality: String?,
        resolvedCountry: String?,
        resolvedISOCountryCode: String?,
        resolvedAdministrativeArea: String?,
        stayHasSettled: Bool
    ) -> StayGeocodeOutcome {
        let merged = current.coalescing(
            locality: resolvedLocality,
            country: resolvedCountry,
            isoCountryCode: resolvedISOCountryCode,
            administrativeArea: resolvedAdministrativeArea
        )
        guard merged == current else { return .progressed(merged) }
        return stayHasSettled ? .exhausted : .retryLater
    }

    /// One bounded call: attempts at most `attemptCap` (default 200) eligible stays, newest
    /// first. A failed read or save rolls back and reports zero.
    @discardableResult
    func geocodeUngeocodedStays(attemptCap: Int? = nil) async -> Int {
        do {
            return try await geocodeStayCentroids(
                eligibleStayRows(limit: attemptCap ?? Self.stayDrainAttemptCap))
        } catch {
            return 0
        }
    }

    /// Locality-nil physical stays to attempt, newest first, at most `limit`, from one read.
    /// A row excluded at its current centroid is skipped in memory, so the newest `limit` plus
    /// exclusion-count rows hold every row the limit admits. A complete read (`limit` nil) also
    /// forgets exclusions whose row moved, gained a locality or disappeared.
    private func eligibleStayRows(limit: Int?) throws -> [PersistentIdentifier] {
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.locality == nil },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        descriptor.propertiesToFetch = [\.centroidLatitude, \.centroidLongitude]
        if let limit { descriptor.fetchLimit = max(1, limit + unresolvableStayIDs.count) }
        #if DEBUG
        try injectGeocodeReadFault(.stayCentroids)
        #endif
        var eligible: [PersistentIdentifier] = []
        var kept: [PersistentIdentifier: StayCentroid] = [:]
        for stay in try modelContext.fetch(descriptor) {
            let rowID = stay.persistentModelID
            let centroid = StayCentroid(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
            if unresolvableStayIDs[rowID] == centroid {
                kept[rowID] = centroid
                continue
            }
            if let limit, eligible.count >= limit { break }
            eligible.append(rowID)
        }
        if limit == nil { unresolvableStayIDs = kept }
        return eligible
    }

    /// Attempt those of `rows` that still miss a locality and are not excluded at their current
    /// centroid, newest first, then save once. The read and the save throw after rolling back
    /// the unsaved unit.
    private func geocodeStayCentroids(_ rows: [PersistentIdentifier]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        var geocodedCount = 0
        var attempted = 0
        var titleSnapshots: ParentTitleSnapshots = [:]

        do {
            let ids = Set(rows)
            let stays = try modelContext.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { ids.contains($0.persistentModelID) },
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]))
            for stay in stays where stay.locality == nil {
                if Task.isCancelled { break }
                let rowID = stay.persistentModelID
                let centroid = StayCentroid(
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
                // Another call may have excluded the row at this centroid since it was selected.
                guard unresolvableStayIDs[rowID] != centroid else { continue }
                attempted += 1
                let settled = stay.endTime
                    < Date.now.addingTimeInterval(-Self.unresolvableSettleSeconds)
                guard let result = await GeocodeResolver.shared.resolve(
                    latitude: centroid.latitude,
                    longitude: centroid.longitude
                ) else {
                    // Exclude only SETTLED stays; recent centroid drift can make a no-result stay resolvable.
                    if settled { unresolvableStayIDs[rowID] = centroid }
                    continue
                }

                // Use Result.localityForStorage to exclude country names from locality.
                // Coalesce known country/ISO values when an island-only resolver hit omits them.
                // Progress must be a CHANGE; use stayGeocodeOutcome as the single decision rule.
                switch Self.stayGeocodeOutcome(
                    current: StayPlaceFields(
                        locality: stay.locality,
                        country: stay.country,
                        isoCountryCode: stay.isoCountryCode,
                        administrativeArea: stay.administrativeArea
                    ),
                    resolvedLocality: result.localityForStorage,
                    resolvedCountry: result.country,
                    resolvedISOCountryCode: result.isoCountryCode,
                    resolvedAdministrativeArea: result.administrativeArea,
                    stayHasSettled: settled
                ) {
                case .progressed(let fields):
                    // Write only on change: an unchanged assignment still dirties
                    // the row for SwiftData and costs a CloudKit export cycle.
                    captureGeocodeTitleSnapshot(for: stay, in: &titleSnapshots)
                    stay.locality = fields.locality
                    stay.country = fields.country
                    stay.isoCountryCode = fields.isoCountryCode
                    stay.administrativeArea = fields.administrativeArea
                    geocodedCount += 1
                case .exhausted:
                    unresolvableStayIDs[rowID] = centroid
                case .retryLater:
                    break
                }
            }

            if attempted > 0 {
                logger.info("Attempted geocoding \(attempted) stay centroid(s) via offline resolver.")
            }

            if geocodedCount > 0 {
                try invalidateGeocodeTitlesIfNeeded(&titleSnapshots)
                noteGeocodeTripChange()
                try saveGeocodeChanges()
                logger.info("Geocoded \(geocodedCount) stay centroid(s).")
            }
        } catch {
            modelContext.rollback()
            logger.error("Stay centroid geocoding failed: \(error.localizedDescription)")
            throw error
        }
        return geocodedCount
    }

    /// Drain phase: the stays eligible when it starts, newest first, in units of at most 50,
    /// each in its own gate unit. One read at the start selects the rows and checks every
    /// exclusion, so a unit reads only its own rows however many earlier units attempted or
    /// excluded. Each stay is tried at most once per drain, at its centroid when its unit
    /// runs; stays that arrive, and excluded stays that move, during it are left to a later drain.
    private func runStayCentroidPhase(gate: PipelineGate) async -> (progress: Int, completed: Bool) {
        let backlog: [PersistentIdentifier]
        do {
            backlog = try eligibleStayRows(limit: nil)
        } catch {
            logger.error("Stay centroid backlog read failed: \(error.localizedDescription)")
            return (0, false)
        }
        var progress = 0
        var start = 0
        while start < backlog.count {
            if Task.isCancelled || shouldPauseDrainForHeat { return (progress, false) }
            let rows = Array(backlog[start ..< min(start + Self.stayDrainUnitSize, backlog.count)])
            start += rows.count
            let unit: (progress: Int, failed: Bool) = await gate.runReturning(touching: []) {
                let outcome = await self.geocodeStayCentroidUnit(rows)
                // Publish `.stay` only for a write (fail open after a failed save), so a
                // no-op activation bumps nothing; a moved summary or cleared title adds `.trip`.
                var changes = await self.takeGeocodeTripChange()
                if outcome.progress > 0 || outcome.failed { changes.formUnion(.stay) }
                await StoreChangeTracker.shared.bump(changes)
                return outcome
            }
            #if DEBUG
            if let afterDrainUnitForTesting { await afterDrainUnitForTesting() }
            #endif
            if unit.failed { return (progress, false) }
            progress += unit.progress
            await Task.yield()
        }
        return (progress, !Task.isCancelled)
    }

    private func geocodeStayCentroidUnit(
        _ rows: [PersistentIdentifier]
    ) async -> (progress: Int, failed: Bool) {
        do {
            return (try await geocodeStayCentroids(rows), false)
        } catch {
            return (0, true)
        }
    }

    // MARK: - Statistics

    /// Committed rows healed, and whether every unit ran; `completed` is false after a failed
    /// read or save (that unit rolled back), cancellation, or a thermal pause.
    nonisolated struct HexHealOutcome: Equatable, Sendable {
        var healed = 0
        var completed = true
    }

    /// Each hex-heal gate unit touches at most this many physical HexVisit rows.
    private static let hexHealUnitSize = 50

    /// Backfill missing hex place fields from a geocoded ping in the cell, then offline center resolution.
    /// Self-gating: each bounded unit owns its gate unit, so callers MUST NOT wrap this in
    /// PipelineGate.run (the gate is non-reentrant). Only non-nil values are assigned, so a
    /// no-op heal stays clean and publishes nothing.
    @discardableResult
    func backfillHexVisitCountries(gate: PipelineGate = .shared) async -> HexHealOutcome {
        #if DEBUG
        hexHealUnitRowsForTesting = []
        #endif
        let ids: [PersistentIdentifier]
        do {
            ids = try listIncompleteHexVisitIDs()
        } catch {
            logger.error("Hex visit backfill selection failed: \(error.localizedDescription)")
            return HexHealOutcome(healed: 0, completed: false)
        }
        guard !ids.isEmpty else {
            logger.debug("No hex visits need backfill.")
            return HexHealOutcome()
        }
        logger.info("Backfilling \(ids.count) hex visit(s).")

        var outcome = HexHealOutcome()
        var index = 0
        while index < ids.count {
            if Task.isCancelled || shouldPauseDrainForHeat {
                outcome.completed = false
                break
            }
            let chunk = Array(ids[index ..< min(index + Self.hexHealUnitSize, ids.count)])
            index += chunk.count
            let unit: (healed: Int, failed: Bool) = await gate.runReturning(touching: []) {
                let result = await self.healHexVisits(chunk)
                // Fail open after a failed save; a no-op unit publishes nothing.
                if result.healed > 0 || result.failed {
                    await StoreChangeTracker.shared.bump(.hexVisit)
                }
                return result
            }
            #if DEBUG
            if let afterDrainUnitForTesting { await afterDrainUnitForTesting() }
            #endif
            if unit.failed {
                outcome.completed = false
                break
            }
            outcome.healed += unit.healed
            await Task.yield()
        }
        if outcome.healed > 0 {
            logger.info("Hex visit backfill healed \(outcome.healed) row(s).")
        }
        if Task.isCancelled { outcome.completed = false }
        return outcome
    }

    /// Physical rows missing a place field. Two fetches deduped by PHYSICAL row: a three-arm OR
    /// predicate exceeds the type-checker budget, and UUID dedup would drop a CloudKit twin.
    private func listIncompleteHexVisitIDs() throws -> [PersistentIdentifier] {
        let missingPlace = FetchDescriptor<HexVisit>(
            predicate: #Predicate { $0.country == nil || $0.locality == nil })
        let missingISO = FetchDescriptor<HexVisit>(
            predicate: #Predicate { $0.isoCountryCode == nil })
        var ids = try modelContext.fetchIdentifiers(missingPlace)
        var seen = Set(ids)
        for id in try modelContext.fetchIdentifiers(missingISO) where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    /// One bounded heal unit. The donor read is required: a failure rolls back every row this
    /// unit staged instead of saving a partial heal.
    private func healHexVisits(_ ids: [PersistentIdentifier]) async -> (healed: Int, failed: Bool) {
        let idSet = Set(ids)
        do {
            let rows = try modelContext.fetch(FetchDescriptor<HexVisit>(
                predicate: #Predicate { idSet.contains($0.persistentModelID) }))
            var healed = 0
            for hex in rows {
                guard hex.locality == nil || hex.country == nil || hex.isoCountryCode == nil else {
                    continue
                }
                let before = (hex.locality, hex.country, hex.isoCountryCode)

                // Strategy 1: find a geocoded ping in the same hex.
                let h3 = hex.h3Index
                let pingPredicate = #Predicate<LocationPing> {
                    $0.h3IndexRes6 == h3 && $0.isGeocoded == true
                }
                var pingDescriptor = FetchDescriptor<LocationPing>(predicate: pingPredicate)
                pingDescriptor.fetchLimit = 1
                #if DEBUG
                try injectGeocodeReadFault(.hexDonor)
                #endif
                if let ping = try modelContext.fetch(pingDescriptor).first {
                    // Heal country and ISO independently; either donor field may be missing.
                    if hex.locality == nil, let value = ping.locality { hex.locality = value }
                    if hex.country == nil, let value = ping.country { hex.country = value }
                    if hex.isoCountryCode == nil, let value = ping.isoCountryCode {
                        hex.isoCountryCode = value
                    }
                }

                // Strategy 2: resolve the hex center via the offline resolver.
                if hex.locality == nil || hex.country == nil || hex.isoCountryCode == nil,
                   let result = await GeocodeResolver.shared.resolve(
                    latitude: hex.centerLatitude,
                    longitude: hex.centerLongitude
                   ) {
                    // Country-name guard — shared definition:
                    // `Result.localityForStorage`.
                    if hex.locality == nil, let value = result.localityForStorage {
                        hex.locality = value
                    }
                    if hex.country == nil, let value = result.country { hex.country = value }
                    if hex.isoCountryCode == nil, let value = result.isoCountryCode {
                        hex.isoCountryCode = value
                    }
                }
                if (hex.locality, hex.country, hex.isoCountryCode) != before { healed += 1 }
            }
            #if DEBUG
            hexHealUnitRowsForTesting.append(healed)
            #endif
            guard healed > 0 else { return (0, false) }
            try saveGeocodeChanges()
            return (healed, false)
        } catch {
            // Roll back the failed unit so a later live or import save cannot adopt it.
            modelContext.rollback()
            logger.error("Hex visit backfill failed: \(error.localizedDescription)")
            return (0, true)
        }
    }
}
