//
//  PingRecorder+PhotoImport.swift
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

    /// Bucketed in-memory spatio-temporal index over `LocationPing` rows.
    /// Bucket width equals the dedup time window, so every row within
    /// ±window of a timestamp lives in the timestamp's own bucket or one of
    /// its two neighbours — three dictionary lookups bound the search.
    /// A stored altitude is usable only when present AND its accuracy is
    /// non-negative: `CLLocation` (and EXIF) report altitude `0` with
    /// `verticalAccuracy < 0` when there is no vertical lock — which is the
    /// common case for cell/Wi-Fi SLC fixes. Re-import backfill therefore targets
    /// rows WITHOUT a valid altitude (nil, or an invalid placeholder) and never
    /// replaces a valid one — so a valid EXIF altitude can upgrade an invalid
    /// live reading, but a real altitude is never clobbered.
    nonisolated static func hasValidAltitude(_ altitude: Double?, _ verticalAccuracy: Double?) -> Bool {
        altitude != nil && (verticalAccuracy ?? -1) >= 0
    }

    /// The timestamp domain imported pings may carry: finite and within
    /// `Date.distantPast...Date.distantFuture`. Shared by the import ingress
    /// filter and the dedup index so both agree on admission.
    nonisolated static func isImportableTimestamp(_ timestamp: Date) -> Bool {
        let seconds = timestamp.timeIntervalSinceReferenceDate
        return seconds.isFinite
            && seconds >= Date.distantPast.timeIntervalSinceReferenceDate
            && seconds <= Date.distantFuture.timeIntervalSinceReferenceDate
    }

    nonisolated struct ImportDedupIndex {
        /// Matched row identity and altitude validity let re-import backfill only unusable altitude.
        struct Match: Sendable {
            let id: UUID
            let hasValidAltitude: Bool
        }

        private struct Row {
            let t: TimeInterval
            let lat: Double
            let lon: Double
            let id: UUID
            let hasValidAltitude: Bool
            /// Which removal can delete the row (`ImportDedupPolicy.mayRepresent`).
            let source: DataSource
        }

        private let bucketWidth: TimeInterval
        private var buckets: [Int64: [Row]] = [:]

        init(bucketWidth: TimeInterval) {
            self.bucketWidth = bucketWidth
        }

        /// Nil outside the importable domain (non-finite, or beyond
        /// `Date.distantPast...distantFuture`), where the Int64 conversion or
        /// the ±1 neighbour probe could trap. Such a stored row is never
        /// within any importable candidate's window, so skipping it loses no
        /// match.
        private func bucket(for t: TimeInterval) -> Int64? {
            guard PingRecorder.isImportableTimestamp(
                Date(timeIntervalSinceReferenceDate: t)) else { return nil }
            let quotient = (t / bucketWidth).rounded(.down)
            guard quotient.isFinite, abs(quotient) < 1e15 else { return nil }
            return Int64(quotient)
        }

        mutating func insert(timestamp: Date, latitude: Double, longitude: Double, id: UUID,
                             hasValidAltitude: Bool, source: DataSource) {
            let t = timestamp.timeIntervalSinceReferenceDate
            guard let key = bucket(for: t) else { return }
            buckets[key, default: []].append(Row(
                t: t, lat: latitude, lon: longitude, id: id,
                hasValidAltitude: hasValidAltitude, source: source))
        }

        /// First row within the time/space window that may stand in for a
        /// `source` candidate; return identity and altitude validity for backfill.
        func firstDuplicate(timestamp: Date,
                            latitude: Double,
                            longitude: Double,
                            window: TimeInterval,
                            radiusMeters: Double,
                            source: DataSource) -> Match? {
            let t = timestamp.timeIntervalSinceReferenceDate
            guard let b = bucket(for: t) else { return nil }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            for neighbour in (b - 1)...(b + 1) {
                guard let rows = buckets[neighbour] else { continue }
                for row in rows where abs(row.t - t) <= window
                    && ImportDedupPolicy.mayRepresent(existing: row.source, candidate: source) {
                    let rowLocation = CLLocation(latitude: row.lat, longitude: row.lon)
                    if location.distance(from: rowLocation) < radiusMeters {
                        return Match(id: row.id, hasValidAltitude: row.hasValidAltitude)
                    }
                }
            }
            return nil
        }
    }

    /// Build the session dedup index with ONE properties-limited fetch of
    /// every ping. Called by `PhotoImportService.runImportSession` in its own
    /// gate unit before the batch loop; a live rollback drops it. On fetch
    /// failure the index stays nil. Photo commits
    /// require a successful rebuild before replay; generic imports retain
    /// their existing per-batch window-fetch fallback.
    func beginImportDedupSession() {
        do {
            importDedupIndex = try buildImportDedupIndex()
        } catch {
            importDedupIndex = nil
            logger.error("Import dedup index unavailable: \(error.localizedDescription)")
        }
    }

    private func buildImportDedupIndex() throws -> ImportDedupIndex {
        #if DEBUG
        if failNextImportDedupFetchForTesting {
            failNextImportDedupFetchForTesting = false
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        var index = ImportDedupIndex(bucketWidth: ImportDedupPolicy.maxWindowSeconds)
        var descriptor = FetchDescriptor<LocationPing>()
        descriptor.propertiesToFetch = [\.timestamp, \.latitude, \.longitude, \.id, \.altitude, \.verticalAccuracy,
                                        \.sourceRaw]
        let pings = try modelContext.fetch(descriptor)
        for ping in pings {
            // An unknown source has unknown removal ownership. It cannot
            // stand in for this build's import and authorize dropping it.
            guard let source = DataSource(rawValue: ping.sourceRaw) else { continue }
            index.insert(timestamp: ping.timestamp, latitude: ping.latitude, longitude: ping.longitude,
                         id: ping.id, hasValidAltitude: Self.hasValidAltitude(ping.altitude, ping.verticalAccuracy),
                         source: source)
        }
        logger.info("Import dedup index built over \(pings.count) ping(s).")
        return index
    }

    /// Drop the session index. Idempotent; called on every import exit path
    /// (completion, pause, cancel, state-row loss) and on discard.
    func endImportDedupSession() {
        importDedupIndex = nil
    }

    #if DEBUG
    /// Import pings defer geocoding and never send live-arrival notifications.
    /// Photo dedup uses 90 seconds / 200 metres to tolerate photo GPS and timestamp variation.
    /// Does NOT save: callers flush at batch end with saveImportBatch.
    /// True means inserted; false means duplicate or H3 failure, preserving acceptedPingCount accuracy.
    @discardableResult
    func recordImportedPing(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) throws -> Bool {
        try recordImportedPings([
            ImportedPingCandidate(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: horizontalAccuracy
            )
        ]) == 1
    }
    #endif

    /// Batch dedup uses the session index or one window fetch for a temporary index.
    /// Insert accepted pings into the index immediately so later candidates deduplicate against them.
    /// One padded overlap fetch contains every possible host stay: a stay can grow only by
    /// absorbing a batch ping whose timestamp already overlaps that range. Live context objects
    /// expose those extensions to later candidates.
    /// Cache hex rows only within this single PipelineGate unit, where other writers cannot interleave.
    /// Process in array order (ascending asset creationDate) to preserve import reentry semantics.
    /// Does NOT save; callers flush per batch. A dedup-window, host-stay or hex lookup failure
    /// rolls back the unsaved unit and throws for replay. Returns inserted ping count.
    @discardableResult
    func recordImportedPings(_ batch: [ImportedPingCandidate], source: DataSource = .photoImport) throws -> Int {
        // Every external source enters here. A corrupt timestamp (non-finite,
        // or an absurd date such as a Timeline offset of -1e30 minutes) is
        // dropped before it can shape the fetch window or reach the dedup
        // index; it is not a ping and is not counted as inserted.
        let batch = batch.filter { Self.isImportableTimestamp($0.timestamp) }
        guard !batch.isEmpty else { return 0 }

        // Use source-specific dedup thresholds: GPX tracks are already thinned to at least 60 seconds.
        let thresholds = ImportDedupPolicy.thresholds(for: source)
        let window = thresholds.windowSeconds
        let radius = thresholds.radiusMeters

        // PhotoKit delivers batches sorted by creationDate, but be defensive:
        // derive the true bounds.
        var minTimestamp = batch[0].timestamp
        var maxTimestamp = batch[0].timestamp
        for candidate in batch {
            if candidate.timestamp < minTimestamp { minTimestamp = candidate.timestamp }
            if candidate.timestamp > maxTimestamp { maxTimestamp = candidate.timestamp }
        }

        // Use the session index or one batch-window fetch for equivalent dedup coverage.
        let usingSessionIndex = (importDedupIndex != nil)
        var index: ImportDedupIndex
        if let sessionIndex = importDedupIndex {
            index = sessionIndex
            importDedupIndex = nil
        } else {
            // Bucket width must cover the WIDEST source window: probing b-1...b+1
            // is correct only while bucketWidth >= window.
            index = ImportDedupIndex(bucketWidth: ImportDedupPolicy.maxWindowSeconds)
            let windowStart = minTimestamp.addingTimeInterval(-window)
            let windowEnd = maxTimestamp.addingTimeInterval(window)
            let predicate = #Predicate<LocationPing> {
                $0.timestamp >= windowStart && $0.timestamp <= windowEnd
            }
            let rows: [LocationPing]
            do {
                #if DEBUG
                if failNextImportDedupFetchForTesting {
                    failNextImportDedupFetchForTesting = false
                    throw CocoaError(.fileReadUnknown)
                }
                #endif
                rows = try modelContext.fetch(FetchDescriptor<LocationPing>(predicate: predicate))
            } catch {
                rollbackImportBatch()
                throw error
            }
            for row in rows {
                guard let rowSource = DataSource(rawValue: row.sourceRaw) else { continue }
                index.insert(timestamp: row.timestamp, latitude: row.latitude, longitude: row.longitude,
                             id: row.id, hasValidAltitude: Self.hasValidAltitude(row.altitude, row.verticalAccuracy),
                             source: rowSource)
            }
        }

        // Host-stay candidates for the whole batch (superset proof above).
        let earliestStart = minTimestamp.addingTimeInterval(-StayClusterer.timeWindowSeconds)
        let latestEnd = maxTimestamp.addingTimeInterval(StayClusterer.timeWindowSeconds)
        let stayPredicate = #Predicate<Stay> { stay in
            stay.startTime <= latestEnd && stay.endTime >= earliestStart
        }
        let hostCandidates: [Stay]
        do {
            #if DEBUG
            if failNextImportHostStayFetchForTesting {
                failNextImportHostStayFetchForTesting = false
                throw CocoaError(.fileReadUnknown)
            }
            #endif
            hostCandidates = try modelContext.fetch(FetchDescriptor<Stay>(predicate: stayPredicate))
        } catch {
            rollbackImportBatch()
            throw error
        }

        var hexCache: [String: HexVisit] = [:]
        var accepted = 0
        // Deduplicated candidates can backfill existing rows only when candidate altitude is valid
        // and stored altitude is absent or invalid; never overwrite a real altitude.
        var altitudeBackfill: [UUID: (altitude: Double, verticalAccuracy: Double)] = [:]

        for candidate in batch {
            if let match = index.firstDuplicate(
                timestamp: candidate.timestamp,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                window: window,
                radiusMeters: radius,
                source: source
            ) {
                if !match.hasValidAltitude,
                   let altitude = candidate.altitude,
                   let vAcc = candidate.verticalAccuracy, vAcc >= 0 {
                    altitudeBackfill[match.id] = (altitude, vAcc)
                }
                // A duplicate still says where the input went: the next fix
                // accepted in this cell continues that visit, so a retried
                // file's deduplicated prefix never makes its suffix a new one.
                if let cell = H3Service.cellIndex(latitude: candidate.latitude, longitude: candidate.longitude) {
                    lastImportedH3Index = cell
                }
                continue
            }

            guard let h3Index = H3Service.cellIndex(latitude: candidate.latitude, longitude: candidate.longitude) else {
                logger.warning("Import: H3 indexing failed for (\(candidate.latitude, privacy: .private), \(candidate.longitude, privacy: .private))")
                continue
            }

            let ping = LocationPing(
                timestamp: candidate.timestamp,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                horizontalAccuracy: candidate.horizontalAccuracy,
                h3IndexRes6: h3Index,
                altitude: candidate.altitude,
                verticalAccuracy: candidate.verticalAccuracy,
                // Preserve caller-declared source through dedup, pre-attachment, and hex updates.
                source: source
            )
            if let id = candidate.id { ping.id = id }
            modelContext.insert(ping)
            index.insert(timestamp: candidate.timestamp, latitude: candidate.latitude, longitude: candidate.longitude,
                         id: ping.id, hasValidAltitude: Self.hasValidAltitude(ping.altitude, ping.verticalAccuracy),
                         source: source)

            do {
                try upsertHexVisitForImport(
                    h3Index: h3Index,
                    coordinate: CLLocationCoordinate2D(latitude: candidate.latitude, longitude: candidate.longitude),
                    timestamp: candidate.timestamp,
                    cache: &hexCache
                )
            } catch {
                rollbackImportBatch()
                throw error
            }

            // Pre-attach imports inside an existing Stay's spatio-temporal envelope:
            // StayClusterer consults only the newest Stay, so older overlaps otherwise create duplicates.
            if let host = findHostStay(among: hostCandidates, for: ping) {
                attachImportedPing(ping, toHostStay: host)
            }

            accepted += 1
        }

        // Move the session index into a local to avoid a full dictionary copy on mutation.
        // Restore only after batch completion; on failure discard the partial index so later batches rebuild.
        if usingSessionIndex {
            importDedupIndex = index
        }

        // Backfill matched rows in one fetch, preserving every previously valid altitude.
        if !altitudeBackfill.isEmpty {
            let ids = Array(altitudeBackfill.keys)
            let predicate = #Predicate<LocationPing> { ids.contains($0.id) }
            if let existing = try? modelContext.fetch(FetchDescriptor<LocationPing>(predicate: predicate)) {
                for ping in existing where !Self.hasValidAltitude(ping.altitude, ping.verticalAccuracy) {
                    if let value = altitudeBackfill[ping.id] {
                        ping.altitude = value.altitude
                        ping.verticalAccuracy = value.verticalAccuracy
                    }
                }
            }
        }

        return accepted
    }

    /// Photo batches save pings and progress in the same context/transaction.
    /// The caller owns PipelineGate; there are no suspension points between
    /// validating the persisted checkpoint and saving its replacement.
    func commitPhotoImportBatch(
        _ candidates: [ImportedPingCandidate],
        expected: PhotoImportStateSnapshot,
        checkpoint: PhotoImportCohortCheckpoint
    ) throws -> PhotoImportStateSnapshot? {
        guard !Task.isCancelled else { return nil }
        let readContext = ModelContext(modelContainer)
        guard let current = try photoImportRead({ try PhotoImportStateSnapshot.fetch(in: readContext) }),
              current.persistentModelID == expected.persistentModelID,
              current.id == expected.id,
              current.startedAt == expected.startedAt,
              current.originDeviceID == expected.originDeviceID,
              current.status == .running, !current.cancelRequested,
              current.processedAssetCount == expected.processedAssetCount,
              current.acceptedPingCount == expected.acceptedPingCount,
              current.watermarkCreationDate == expected.watermarkCreationDate,
              current.watermarkLocalIdentifier == expected.watermarkLocalIdentifier else {
            return nil
        }
        let stateID = current.persistentModelID
        let predicate = #Predicate<PhotoImportState> { $0.persistentModelID == stateID }
        guard let state = try photoImportRead({
            try modelContext.fetch(FetchDescriptor<PhotoImportState>(predicate: predicate)).first
        }), !state.isDeleted else { return nil }

        // Replays must fail closed if the persisted dedup inputs cannot be
        // read. Generic imports retain their existing fallback behavior.
        if !candidates.isEmpty, importDedupIndex == nil {
            importDedupIndex = try photoImportRead { try buildImportDedupIndex() }
        }
        let inserted = try photoImportRead { try recordImportedPings(candidates) }
        // Always derive values from the fresh snapshot, not this context's
        // possibly registered state object. Lifecycle fields are untouched.
        let processed = current.processedAssetCount + checkpoint.processedIncrement
        let accepted = current.acceptedPingCount + inserted
        state.processedAssetCount = processed
        state.acceptedPingCount = accepted
        state.watermarkCreationDate = checkpoint.creationDate
        state.watermarkLocalIdentifier = checkpoint.legacyLocalIdentifier
        state.lastUpdated = .now
        // Persist intent before the database commit. If this write fails, no
        // pings or checkpoint may become durable without recovery evidence.
        var intended = PhotoImportCheckpointJournal.Checkpoint(current)
        intended.processed = processed
        intended.accepted = accepted
        intended.watermark = checkpoint.creationDate
        intended.legacyIdentifier = checkpoint.legacyLocalIdentifier
        let insertedIDs = modelContext.insertedModelsArray.compactMap { ($0 as? LocationPing)?.id }
        do {
            try PhotoImportCheckpointJournal.begin(previous: current, intended: intended,
                insertedPingIDs: insertedIDs, in: modelContainer)
            try saveImportBatch()
        } catch {
            rollbackImportBatch()
            // This process observed the rollback, so retain its prior durable
            // checkpoint. If this write also fails, pending recovery fails
            // closed rather than treating absent IDs as proof of rollback.
            try? PhotoImportCheckpointJournal.seed(current, in: modelContainer)
            throw error
        }
        // If finalizing the sidecar fails, its durable pending entry still
        // proves this batch via the exact inserted IDs on the next Resume.
        try PhotoImportCheckpointJournal.seed(intended, in: modelContainer)
        #if DEBUG
        let afterSave = afterPhotoImportSaveForTesting
        afterPhotoImportSaveForTesting = nil
        try afterSave?()
        #endif
        guard let committed = try photoImportRead({
            try PhotoImportStateSnapshot.fetch(in: ModelContext(modelContainer))
        }), committed.persistentModelID == current.persistentModelID,
            committed.id == current.id, committed.startedAt == current.startedAt,
            committed.originDeviceID == current.originDeviceID,
            committed.processedAssetCount == processed,
            committed.acceptedPingCount == accepted,
            committed.watermarkCreationDate == checkpoint.creationDate,
            committed.watermarkLocalIdentifier == checkpoint.legacyLocalIdentifier else {
            // The save is durable, but an external write changed its checkpoint.
            // Stop enumeration without rolling back pings or adopting the drift.
            return nil
        }
        // Lifecycle-only changes retain the service's cancellation precedence.
        return committed
    }

    private func photoImportRead<Value>(_ read: () throws -> Value) throws -> Value {
        do { return try read() }
        catch { throw PhotoImportBatchReadError.unavailable(error.localizedDescription) }
    }

    /// Flush pings, HexVisit updates, parent summaries, title invalidations,
    /// and any photo checkpoint staged in this context in one save.
    func saveImportBatch() throws {
        applyAffectedTripReconciliation()
        do {
            #if DEBUG
            importBatchSaveCallCountForTesting += 1
            if failNextImportBatchSaveForTesting
                || failingImportBatchSaveCallForTesting
                    == importBatchSaveCallCountForTesting {
                failNextImportBatchSaveForTesting = false
                failingImportBatchSaveCallForTesting = nil
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
            lastDurableImportedH3Index = lastImportedH3Index
            affectedTripIDs.removeAll()
            affectedTripTitleSnapshots.removeAll()
            recordDetachedMembers()
        } catch {
            rollbackImportBatch()
            throw error
        }
    }

    private func rollbackImportBatch() {
        modelContext.rollback()
        importDedupIndex = nil
        lastImportedH3Index = lastDurableImportedH3Index
        affectedTripIDs.removeAll()
        affectedTripTitleSnapshots.removeAll()
        pendingDetachedMembers.removeAll()
    }

    /// Logs the stays this context's committed save took out of completed
    /// trips (`PhotoLineageStore.detachedMembers`).
    private func recordDetachedMembers() {
        guard !pendingDetachedMembers.isEmpty else { return }
        PhotoLineageStore.recordDetachedMembers(pendingDetachedMembers, defaults: PhotoLineageStore.recorderDefaults)
        pendingDetachedMembers.removeAll()
    }

    /// Keep import reentry tracking separate from live SLC tracking.
    /// Extend firstVisited backward and lastVisited forward to encompass all imported timestamps.
    /// Preserve geocoded names: imports carry none, so deferred geocoding fills missing fields.
    /// Cache model references only for this batch's single PipelineGate unit;
    /// no other writer may delete cached rows mid-call.
    private func upsertHexVisitForImport(
        h3Index: String,
        coordinate: CLLocationCoordinate2D,
        timestamp: Date,
        cache: inout [String: HexVisit]
    ) throws {
        let isNewHex = (h3Index != lastImportedH3Index)
        lastImportedH3Index = h3Index

        let hexVisit: HexVisit?
        if let cached = cache[h3Index] {
            hexVisit = cached
        } else {
            let predicate = #Predicate<HexVisit> { $0.h3Index == h3Index }
            let descriptor = FetchDescriptor<HexVisit>(predicate: predicate)
            do {
                #if DEBUG
                importHexFetchCallCountForTesting += 1
                if failingImportHexFetchCallForTesting == importHexFetchCallCountForTesting {
                    failingImportHexFetchCallForTesting = nil
                    throw CocoaError(.fileReadUnknown)
                }
                #endif
                hexVisit = try modelContext.fetch(descriptor).first
            } catch {
                logger.error("Import: failed to upsert HexVisit for \(h3Index): \(error.localizedDescription)")
                throw error
            }
        }

        if let hexVisit {
            if timestamp < hexVisit.firstVisited {
                hexVisit.firstVisited = timestamp
            }
            if timestamp > hexVisit.lastVisited {
                hexVisit.lastVisited = timestamp
            }
            if isNewHex {
                hexVisit.visitCount += 1
            }
            cache[h3Index] = hexVisit
        } else {
            let centerCoord = H3Service.centerCoordinate(for: h3Index)
            let newVisit = HexVisit(
                h3Index: h3Index,
                firstVisited: timestamp,
                centerLatitude: centerCoord?.latitude ?? coordinate.latitude,
                centerLongitude: centerCoord?.longitude ?? coordinate.longitude
            )
            newVisit.lastVisited = timestamp
            modelContext.insert(newVisit)
            cache[h3Index] = newVisit
        }
    }

    /// Mirror StayClusterer's extension rule: within four hours of the stay window and
    /// three kilometres of its centroid; closest centroid wins when multiple stays match.
    /// No match leaves the ping unprocessed for later clustering.
    /// Prefetched candidates are live context objects, so earlier attachments' window extensions
    /// must remain visible to later candidates in the same batch.
    private func findHostStay(among candidates: [Stay], for ping: LocationPing) -> Stay? {
        guard !candidates.isEmpty else { return nil }

        let earliestStart = ping.timestamp.addingTimeInterval(-StayClusterer.timeWindowSeconds)
        let latestEnd = ping.timestamp.addingTimeInterval(StayClusterer.timeWindowSeconds)
        let pingLocation = CLLocation(latitude: ping.latitude, longitude: ping.longitude)

        var best: (stay: Stay, distance: Double)?
        for stay in candidates {
            guard stay.startTime <= latestEnd && stay.endTime >= earliestStart else { continue }
            let stayLocation = CLLocation(latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
            let distance = pingLocation.distance(from: stayLocation)
            guard distance < StayClusterer.distanceThresholdMeters else { continue }
            if best == nil || distance < best!.distance {
                best = (stay, distance)
            }
        }
        return best?.stay
    }

    /// Mirror StayClusterer's stay extension with deliberate import differences:
    /// startTime may extend backward; distanceFromHomeKm retains its original Home-history meaning.
    /// A host whose duration, airport or overnight standing crosses what classification reads is
    /// handed back to it (`StayClassificationInputs.resetIfMoved`); no later pass revisits a
    /// settled historical stay otherwise.
    /// Any heterogeneous import absorption marks known non-shared hosts
    /// mixed. Same-source, shared and unknown hosts retain their source tag.
    /// Never alter userOverridden. Mark the ping processed so clustering skips it.
    private func attachImportedPing(_ ping: LocationPing, toHostStay stay: Stay) {
        // Capture title semantics before the first mutation. Ping-count,
        // centroid, H3, and provenance-only absorption should not churn titles;
        // boundary or airport changes invalidate them when import reconciles the trip.
        if let trip = stay.trip {
            affectedTripIDs.insert(trip.id)
            let identity = ObjectIdentifier(trip)
            if affectedTripTitleSnapshots[identity] == nil {
                affectedTripTitleSnapshots[identity] =
                    TripTitleStore.ParentSemanticSnapshot(
                        trip: trip,
                        semantic: TripTitleStore.semanticSnapshot(for: trip))
            }
        }
        let weatherKey = WeatherEnricher.WeatherValidityKey(stay)
        let classificationInputs = StayClassificationInputs(stay)
        // appendPingID keeps the row consistent in O(1); per-unit saves need no flush step.
        stay.appendPingID(ping.id)

        if ping.timestamp < stay.startTime {
            stay.startTime = ping.timestamp
        }
        if ping.timestamp > stay.endTime {
            stay.endTime = ping.timestamp
        }
        stay.durationMinutes = max(0, Int(stay.endTime.timeIntervalSince(stay.startTime) / 60))

        // MUST match StayClusterer's running-average formula so live and import paths yield identical centroids.
        let n = Double(stay.pingCount)
        stay.centroidLatitude = stay.centroidLatitude + (ping.latitude - stay.centroidLatitude) / n
        // Use the clusterer's dateline-safe running mean to preserve identical centroids.
        stay.centroidLongitude = GeoMath.runningMeanLongitude(
            current: stay.centroidLongitude, adding: ping.longitude, newCount: n
        )

        // Mirror StayClusterer's H3 update when centroid drift crosses a hex boundary.
        if let updatedH3 = H3Service.cellIndex(latitude: stay.centroidLatitude, longitude: stay.centroidLongitude) {
            stay.h3IndexRes6 = updatedH3
        }
        // Weather fetched for the old cell or UTC days no longer describes the stay.
        WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)

        // Re-stamp airport status from the CURRENT centroid, matching StayClusterer;
        // centroid drift can change proximity in either direction.
        stay.isAirport = AirportDetector.shared.isNearAirport(
            CLLocationCoordinate2D(latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
        )
        StayClassificationInputs.resetIfMoved(stay, from: classificationInputs, detached: &pendingDetachedMembers)

        // Timeline/GPX hosts may absorb photos too. Every heterogeneous
        // known source must retain that uncertainty. Preserve a shared host's
        // ownership tag and any unknown future source verbatim; the flight
        // evidence reader unions retained ping raws without rewriting either.
        let attachedSource = DataSource.sourceRawAfterImportAttachment(
            hostRaw: stay.sourceRaw, incomingRaw: ping.sourceRaw)
        if attachedSource != stay.sourceRaw {
            stay.sourceRaw = attachedSource
            if attachedSource == DataSource.merged.rawValue,
               let trip = stay.trip, trip.sourceRaw == DataSource.photoImport.rawValue {
                trip.sourceRaw = DataSource.merged.rawValue
            }
        }

        // Track the parent for post-batch provenance recomputation.
        // Reading stay.trip?.id is safe inside this actor's SwiftData context.
        ping.isProcessed = true
    }

    /// Clear affected-trip IDs at import start so cancelled sessions cannot carry stale IDs forward;
    /// summary recomputation remains idempotent if stale IDs do occur.
    func clearAffectedTripIDs() {
        affectedTripIDs.removeAll()
        affectedTripTitleSnapshots.removeAll()
    }

    #if DEBUG
    /// Test seams to seed and inspect affected-trip IDs across import-session reset.
    func seedAffectedTripIDsForTesting(_ ids: Set<UUID>) {
        affectedTripIDs.formUnion(ids)
    }

    func affectedTripIDsForTesting() -> Set<UUID> {
        affectedTripIDs
    }
    #endif

    /// Reset on import start/discard so the next import's first ping counts a visit even
    /// in the previous import's final hex: the cursor follows one input run, across its
    /// units, never from one file into the next. Leave the independent live SLC cursor untouched.
    func resetLastImportedH3Index() {
        lastImportedH3Index = nil
        lastDurableImportedH3Index = nil
    }

    /// Recompute touched parent summaries and clear tracked IDs at import completion.
    /// Run regardless of foreground state: `.merged` provenance must reach existing trips
    /// even when background import skips TripClassifier. Repeated recomputation is idempotent.
    private func applyAffectedTripReconciliation() {
        guard !affectedTripIDs.isEmpty || !affectedTripTitleSnapshots.isEmpty else {
            return
        }
        for snapshot in affectedTripTitleSnapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted else { continue }
            widenDates(of: trip)
            trip.recomputeSummary()
            if snapshot.semantic != TripTitleStore.semanticSnapshot(for: trip) {
                TripTitleStore.invalidateGeneratedTitles(
                    for: trip, in: modelContext)
            }
        }
    }

    /// Absorption only grows member stays, and no later pass revisits a completed
    /// trip whose membership did not change, so cover the members here. Widen
    /// only: a wider homecoming or merged span stays. A nil end stays nil.
    private func widenDates(of trip: Trip) {
        let members = (trip.stays ?? []).filter { !$0.isDeleted }
        if let earliest = members.map(\.startTime).min(), earliest < trip.startDate {
            trip.startDate = earliest
        }
        if trip.isComplete, let endDate = trip.endDate,
           let latest = members.map(\.endTime).max(), endDate < latest {
            trip.endDate = latest
        }
    }

    func recomputeAffectedTripSummaries() {
        guard !affectedTripIDs.isEmpty || !affectedTripTitleSnapshots.isEmpty else {
            return
        }
        let ids = affectedTripIDs
        applyAffectedTripReconciliation()
        do {
            try modelContext.save()
            affectedTripIDs.removeAll()
            affectedTripTitleSnapshots.removeAll()
            recordDetachedMembers()
            logger.info("Recomputed summaries for \(ids.count) trip(s) touched by import.")
        } catch {
            modelContext.rollback()
            pendingDetachedMembers.removeAll()
            logger.error("Failed to save trip-summary recomputation: \(error.localizedDescription)")
        }
    }
}

/// What classification reads from a stay's own geometry: its duration
/// against the thresholds the rules and the prompt use, its airport
/// standing and whether it spans the night. Captured before imported
/// evidence is added to a stay or removed from it, and compared after.
nonisolated struct StayClassificationInputs: Equatable, Sendable {
    /// Minutes: the short-stop transit rules (90), the prompt's short stop
    /// (120), the heuristic fallback's short stop beside a farther neighbour
    /// (180), an adjacent base (360) and the sub-day airport rule (1440).
    static let durationThresholdsMinutes = [90, 120, 180, 360, 1_440]

    let durationBand: Int
    let isAirport: Bool
    let overnight: Bool

    init(_ stay: Stay) {
        durationBand = Self.durationThresholdsMinutes.filter { stay.durationMinutes >= $0 }.count
        isAirport = stay.isAirport
        overnight = CollectionsAggregator.intervalCrossesSolarHour(
            start: stay.startTime, end: stay.endTime, longitude: stay.centroidLongitude, hour: 3)
    }

    /// Hands a stay whose inputs moved back to classification: a historical
    /// stay is otherwise never judged again, so a five-minute stop grown into
    /// a six-hour stay would stay transit. Only an automatic destination or
    /// transit is reset; one the user set, one in a trip the user edited,
    /// and home and routine stays (whose provenance a home unit owns) keep
    /// theirs. A stay that shares a completed trip leaves it, so the next
    /// pass regroups the trip around its new category, the trip keeping its
    /// id by its largest overlap; an open trip's stay stays, since assembly
    /// rebuilds open trips. A completed trip's only stay keeps its category:
    /// left empty or holding an unclassified stay, no pass would rebuild the
    /// trip's row and summary. Runs in the caller's transaction. Returns
    /// whether the stay was reset.
    @discardableResult
    static func resetIfMoved(_ stay: Stay, from before: StayClassificationInputs) -> Bool {
        guard StayClassificationInputs(stay) != before,
              !stay.userOverridden,
              stay.category == .transit || stay.category == .destination,
              !(stay.trip?.userEdited ?? false) else { return false }
        var leavesTrip = false
        if let trip = stay.trip, trip.isComplete {
            guard (trip.stays ?? []).contains(where: { $0 !== stay && !$0.isDeleted }) else { return false }
            leavesTrip = true
        }
        stay.category = .unclassified
        if leavesTrip {
            stay.trip = nil
            stay.orderInTrip = nil
        }
        return true
    }

    /// `resetIfMoved`, noting in `detached` (trip id to stay ids) a stay it
    /// took out of a completed trip, for `PhotoLineageStore`'s detached
    /// members once the caller's save commits.
    @discardableResult
    static func resetIfMoved(
        _ stay: Stay, from before: StayClassificationInputs, detached: inout [UUID: Set<UUID>]
    ) -> Bool {
        let tripID = stay.trip.flatMap { $0.isComplete ? $0.id : nil }
        guard resetIfMoved(stay, from: before) else { return false }
        if let tripID, stay.trip == nil { detached[tripID, default: []].insert(stay.id) }
        return true
    }
}
