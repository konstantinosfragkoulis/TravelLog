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
        // Host stays' member photos as the base check read them: like the
        // hex cache, valid only within this unit, and dropped with it.
        var baseSpans: [ObjectIdentifier: ImportPhotoSpan] = [:]
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
                do {
                    try attachImportedPing(ping, toHostStay: host, baseSpans: &baseSpans)
                } catch {
                    rollbackImportBatch()
                    throw error
                }
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

    /// The member photo times of an automatic photo-only transit host, and
    /// the start of the first stay after it: the only stay whose verdict
    /// another photo inside its stored interval can change (a longer span is
    /// no longer brief; a later last photo can bring a night into reach), and
    /// one a fix of another source can (its stored interval is then its dwell).
    /// So can that fix a photo-only destination's (`gainsOtherEvidence`): a
    /// stored interval can be brief, or shorter than a departure stop, where
    /// the photos were not, and a photo not yet synced hides what they were.
    /// Nil for any other host. As `stayEvidence` without a timeline: one time
    /// per member id, a UUID twin's earliest, and the next stay is the first
    /// the store holds starting after this one, never a UUID twin. A failed
    /// read throws: the batch rolls back and replays.
    private func journeyStopPhotoReading(
        of stay: Stay, gainsOtherEvidence: Bool
    ) throws -> (times: [Date], nextStart: Date?)? {
        guard stay.source == .photoImport, !stay.userOverridden,
              stay.category == .transit || (stay.category == .destination && gainsOtherEvidence)
        else { return nil }
        #if DEBUG
        if failNextImportMemberPhotoFetchForTesting {
            failNextImportMemberPhotoFetchForTesting = false
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        let times = try memberPhotoTimes(of: stay)
        let start = stay.startTime
        let id = stay.id
        var next = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime > start && $0.id != id },
            sortBy: [SortDescriptor(\.startTime)])
        next.fetchLimit = 1
        let nextStart = try modelContext.fetch(next).first?.startTime
        return (times, nextStart)
    }

    /// The times of `stay`'s member pings the store holds: one per member
    /// id, a UUID twin's earliest. A failed read throws.
    private func memberPhotoTimes(of stay: Stay) throws -> [Date] {
        let ids = stay.pingIDs
        guard !ids.isEmpty else { return [] }
        var times: [UUID: Date] = [:]
        var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id, \.timestamp]
        for ping in try modelContext.fetch(descriptor) where !ping.isDeleted {
            times[ping.id] = min(times[ping.id] ?? ping.timestamp, ping.timestamp)
        }
        return ids.compactMap { times[$0] }
    }

    /// What the base check reads of a photo-only host's member photos once a
    /// photo at `timestamp` joins it: the journey test reads a photo stay as
    /// a base only on its photos, and photos inside a stored interval under
    /// six hours cannot show six. Taken from `spans` (what this batch already
    /// read of the host, kept as photos join it) or the member times the
    /// caller read, else read once. Nil for any other host: a measured one is
    /// read on its stored interval, a home or routine one is a base whatever
    /// it holds. A failed read throws.
    private func baseSpan(of stay: Stay, joining timestamp: Date, read times: [Date]?,
                          spans: [ObjectIdentifier: ImportPhotoSpan]) throws -> ImportPhotoSpan? {
        guard stay.source == .photoImport, stay.category != .home, stay.category != .routine else { return nil }
        if let span = spans[ObjectIdentifier(stay)] { return span }
        if let times { return ImportPhotoSpan(members: stay.pingIDs.count, times: times) }
        let grown = max(stay.endTime, timestamp).timeIntervalSince(min(stay.startTime, timestamp))
        guard grown >= 360 * 60 else { return nil }
        return ImportPhotoSpan(members: stay.pingIDs.count, times: try memberPhotoTimes(of: stay))
    }

    /// Whether the journey test reads `stay` as a base
    /// (`TripClassifier.readsAsBase`), given what the caller read of its
    /// member photos (nil for a photo-only stay: it showed no six hours).
    /// The next stay's start bounds only short stops, which no base is.
    nonisolated private static func readsAsBase(_ stay: Stay, span: ImportPhotoSpan?) -> Bool {
        if stay.category == .home || stay.category == .routine { return true }
        guard let span else {
            return stay.source != .photoImport && TripClassifier.readsAsBase(StayEvidence(measured: stay))
        }
        return TripClassifier.readsAsBase(StayClassificationInputs.evidence(of: stay, span: span, nextStart: nil))
    }

    /// Hands back the stops whose journey test reads `host` as an anchor,
    /// once it starts or stops reading as a base: on each side, as
    /// `TripClassifier.journeyTailRows`, the stays up to and including the
    /// first that cannot be a blip, within `anchorWalkLimit` stays and
    /// stopping at a home or routine stay, never a UUID twin of the host.
    /// The walk reads one row per UUID, as the heuristics judge it
    /// (`TripClassifier.journeyWalk`), and resets every copy of a stop it
    /// hands back, so one decision covers the logical stay. As
    /// `journeyTail`, an automatic destination or transit copy is reset; one
    /// the user set, or one in a trip the user edited or that is complete,
    /// keeps its category. Runs in the caller's transaction; a failed read
    /// throws.
    private func releaseJourneyStops(beside host: Stay) throws {
        for backward in [true, false] {
            let walked = try TripClassifier.journeyWalk(from: host.startTime, backward: backward,
                                                        excluding: host.id, in: modelContext)
            for copy in walked.flatMap({ $0.copies })
            where (copy.category == .destination || copy.category == .transit) && !copy.userOverridden
                && !(copy.trip?.userEdited ?? false) && !(copy.trip?.isComplete ?? false) {
                copy.category = .unclassified
            }
        }
    }

    /// Mirror StayClusterer's stay extension with deliberate import differences:
    /// startTime may extend backward; distanceFromHomeKm retains its original Home-history meaning.
    /// A host whose duration, airport or overnight standing crosses what classification reads,
    /// or whose verdict-bearing evidence changes when its photos stop being its only evidence,
    /// is handed back to it (`StayClassificationInputs.resetIfMoved`), and one that starts or
    /// stops reading as a base hands back the stops beside it (`releaseJourneyStops`); no later
    /// pass revisits a settled historical stay otherwise.
    /// Any heterogeneous import absorption marks known non-shared hosts
    /// mixed. Same-source, shared and unknown hosts retain their source tag.
    /// Never alter userOverridden. Mark the ping processed so clustering skips it.
    /// `baseSpans` is what the batch has read of its photo hosts' member
    /// photos (`baseSpan`), kept as they grow.
    private func attachImportedPing(_ ping: LocationPing, toHostStay stay: Stay,
                                    baseSpans: inout [ObjectIdentifier: ImportPhotoSpan]) throws {
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
        // Timeline/GPX hosts may absorb photos too. Every heterogeneous
        // known source must retain that uncertainty. Preserve a shared host's
        // ownership tag and any unknown future source verbatim; the flight
        // evidence reader unions retained ping raws without rewriting either.
        let attachedSource = DataSource.sourceRawAfterImportAttachment(
            hostRaw: stay.sourceRaw, incomingRaw: ping.sourceRaw)
        let sourceChanged = attachedSource != stay.sourceRaw
        // The one read, before the first mutation. The next stay it finds
        // stays the next one: the photo joins this host inside its window.
        let photoReading = try journeyStopPhotoReading(of: stay, gainsOtherEvidence: sourceChanged)
        let classificationInputs = StayClassificationInputs(
            stay, photoTimes: photoReading?.times, nextStart: photoReading?.nextStart)
        // The stops beside the host were judged on whether it reads as a
        // base, which more photos inside its stored interval can change.
        let baseBefore = try baseSpan(of: stay, joining: ping.timestamp, read: photoReading?.times,
                                      spans: baseSpans)
        let wasBase = Self.readsAsBase(stay, span: baseBefore)
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
        // Set before the reset reads the stay: a photo stop that took other
        // evidence is judged on its stored interval from now on.
        if sourceChanged {
            stay.sourceRaw = attachedSource
        }
        StayClassificationInputs.resetIfMoved(
            stay, from: classificationInputs, photoTimes: photoReading.map { $0.times + [ping.timestamp] },
            nextStart: photoReading?.nextStart, detached: &pendingDetachedMembers)
        var baseAfter = baseBefore
        baseAfter?.add(ping.timestamp)
        baseSpans[ObjectIdentifier(stay)] = baseAfter
        if Self.readsAsBase(stay, span: baseAfter) != wasBase {
            try releaseJourneyStops(beside: stay)
        }
        if sourceChanged, attachedSource == DataSource.merged.rawValue,
           let trip = stay.trip, trip.sourceRaw == DataSource.photoImport.rawValue {
            trip.sourceRaw = DataSource.merged.rawValue
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
    /// A host owed a later pass (`TripTitleStore.mayDeriveSummary`, judged on its stays before
    /// the import grew them) keeps its summary and title, and the launch summary pass is owed it.
    private func applyAffectedTripReconciliation() {
        guard !affectedTripIDs.isEmpty || !affectedTripTitleSnapshots.isEmpty else {
            return
        }
        var hydrating: Bool?
        var deferred = false
        for snapshot in affectedTripTitleSnapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted else { continue }
            widenDates(of: trip)
            guard TripTitleStore.mayDeriveSummary(
                holdsNamedStays: TripTitleStore.heldItsNamedStays(snapshot), hydrating: &hydrating) else {
                deferred = true
                continue
            }
            trip.recomputeSummary()
            if snapshot.semantic != TripTitleStore.semanticSnapshot(for: trip) {
                TripTitleStore.invalidateGeneratedTitles(
                    for: trip, in: modelContext)
            }
        }
        if deferred { TripTitleStore.oweSummaryRefresh() }
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

/// What a stay's member photos show, as an import read them: how many
/// members it lists, how many of their times the store holds, and the
/// earliest and latest of those. Kept as photos join the stay, so a batch
/// reads a host's members once.
nonisolated struct ImportPhotoSpan: Equatable, Sendable {
    private(set) var members: Int
    private(set) var known: Int
    private(set) var first: Date?
    private(set) var last: Date?

    init(members: Int, times: [Date]) {
        self.members = members
        known = times.count
        first = times.min()
        last = times.max()
    }

    /// A photo at `time` joins the stay.
    mutating func add(_ time: Date) {
        members += 1
        known += 1
        first = min(first ?? time, time)
        last = max(last ?? time, time)
    }
}

/// What classification reads from a stay's own geometry: its duration
/// against the thresholds the rules use, its airport standing, whether it
/// spans the night and, for a photo stop whose photos the caller read,
/// whether the evidence it is judged on is brief or shorter than a departure
/// stop and whether a night is possible there. Captured before imported
/// evidence is added to a stay or removed from it, and compared after.
nonisolated struct StayClassificationInputs: Equatable, Sendable {
    /// The duration rule's ceiling: a non-airport stay this short is transit
    /// before any judgment, so no other rule ever labels one.
    static let shortStopMinutes = 20

    /// Minutes: past the duration rule's short stop (21), a brief journey
    /// stop (60), a departure or arrival stop (90), a base (360) and the
    /// sub-day airport rule (1440).
    static let durationThresholdsMinutes = [shortStopMinutes + 1, 60, 90, 360, 1_440]

    /// The journey test's brief photo span: a photo-only stay is a brief
    /// stop only while its photos span less than this.
    static let briefPhotoSpanMinutes = 45

    let durationBand: Int
    let isAirport: Bool
    let overnight: Bool
    /// For a stay whose member photo times and next stay's start the caller
    /// read: the category the duration rules settle on the `StayEvidence`
    /// classification judges it by (the airport stop among them), or nil
    /// when only the journey test can decide. That is its photos' while it
    /// is photo-only and they are all known; its stored interval once it
    /// holds other evidence or a time is missing. Another photo inside an
    /// unchanged interval moves nothing else. Nil without those reads.
    let settledCategory: StayCategory?
    /// Whether that evidence is brief (photos spanning less than
    /// `briefPhotoSpanMinutes`, a stored interval under an hour), read only
    /// while the duration rules leave it to the journey test (a settled
    /// stop's span changes no verdict); nil otherwise.
    let brief: Bool?
    /// Its `StayEvidence.nightPossible`, under the same condition: another
    /// photo inside an unchanged interval can bring solar 03:00 within the
    /// lookahead of its last photo. Nil whenever `brief` is.
    let nightPossible: Bool?
    /// Whether that evidence is certainly shorter than a departure or arrival
    /// stop (90 minutes), under the same condition: photos are bounded by
    /// the next stay's start, a stored interval by itself. Nil whenever
    /// `brief` is.
    let departureShort: Bool?
    /// Whether a photo-only stop of several photos, whose times the caller
    /// read, misses one (a sync has not delivered its ping yet).
    /// Classification then reads its stored interval too, but a verdict
    /// another device reached may rest on all its photos, so evidence of
    /// another source hands it back even where that interval moves nothing.
    /// Nil without those reads.
    let photoMissing: Bool?

    /// `photoTimes` and `nextStart` are what the caller read of a photo
    /// stop: its member photo times, and the start of the first stay after
    /// it (nil when there is none).
    init(_ stay: Stay, photoTimes: [Date]? = nil, nextStart: Date? = nil) {
        durationBand = Self.durationThresholdsMinutes.filter { stay.durationMinutes >= $0 }.count
        isAirport = stay.isAirport
        overnight = CollectionsAggregator.intervalCrossesSolarHour(
            start: stay.startTime, end: stay.endTime, longitude: stay.centroidLongitude, hour: 3)
        let evidence = photoTimes.map { Self.evidence(of: stay, photoTimes: $0, nextStart: nextStart) }
        photoMissing = evidence.map { stay.source == .photoImport && !$0.photoOnly }
        if let evidence {
            let settled = evidence.settledCategory
            settledCategory = settled
            brief = settled == nil ? evidence.isBrief : nil
            nightPossible = settled == nil ? evidence.nightPossible : nil
            departureShort = settled == nil ? evidence.isShorter(than: 90) : nil
        } else {
            settledCategory = nil
            brief = nil
            nightPossible = nil
            departureShort = nil
        }
    }

    /// As `stayEvidence`, from the member photo times and next stay's start
    /// the caller read: one photo spans nothing and stands at the stay's
    /// start; a missing time, or evidence other than photos, leaves the
    /// stored interval as the dwell.
    static func evidence(of stay: Stay, photoTimes: [Date], nextStart: Date?) -> StayEvidence {
        evidence(of: stay, span: ImportPhotoSpan(members: stay.pingIDs.count, times: photoTimes),
                 nextStart: nextStart)
    }

    /// The same, from what the caller read of the member photos.
    static func evidence(of stay: Stay, span: ImportPhotoSpan, nextStart: Date?) -> StayEvidence {
        if stay.source == .photoImport, span.members <= 1 {
            return StayEvidence(photos: stay, firstObservation: stay.startTime,
                                lastObservation: stay.startTime, nextStart: nextStart)
        }
        if stay.source == .photoImport, span.known == span.members,
           let first = span.first, let last = span.last {
            return StayEvidence(photos: stay, firstObservation: first, lastObservation: last, nextStart: nextStart)
        }
        return StayEvidence(measured: stay)
    }

    /// Live growth's form of the short-stop crossing `resetIfMoved` reads:
    /// an automatic transit label on a non-airport stay that was
    /// `shortStopMinutes` or less is the duration rule's alone, so it lapses
    /// once clustering or a Visit grows the stay past it and the stay is
    /// judged again. One the user set, one in a trip the user edited and a
    /// completed trip's member (which only an import detaches) keep theirs.
    static func releaseOutgrownShortStop(_ stay: Stay, fromMinutes before: Int) {
        guard before <= shortStopMinutes, stay.durationMinutes > shortStopMinutes,
              stay.category == .transit, !stay.isAirport, !stay.userOverridden,
              !(stay.trip?.userEdited ?? false), !(stay.trip?.isComplete ?? false) else { return }
        stay.category = .unclassified
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
    static func resetIfMoved(_ stay: Stay, from before: StayClassificationInputs,
                             photoTimes: [Date]? = nil, nextStart: Date? = nil) -> Bool {
        guard StayClassificationInputs(stay, photoTimes: photoTimes, nextStart: nextStart) != before,
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
        _ stay: Stay, from before: StayClassificationInputs, photoTimes: [Date]? = nil,
        nextStart: Date? = nil, detached: inout [UUID: Set<UUID>]
    ) -> Bool {
        let tripID = stay.trip.flatMap { $0.isComplete ? $0.id : nil }
        guard resetIfMoved(stay, from: before, photoTimes: photoTimes, nextStart: nextStart) else { return false }
        if let tripID, stay.trip == nil { detached[tripID, default: []].insert(stay.id) }
        return true
    }
}
