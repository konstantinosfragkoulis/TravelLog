//
//  StayClusterer.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import SwiftH3
import os.log

/// Clusters consecutive `LocationPing` records into `Stay` records.
/// SLC silence leaves endTime at the last ping; closing extends it toward the midpoint, bounded by maxStayExtensionSeconds.
@ModelActor
actor StayClusterer {

    typealias PendingLocality = (id: UUID, latitude: Double, longitude: Double)

    /// Candidates and the Delete All Data floor they were read under. Clustering reads
    /// the floor inside its gate unit, which the wipe's unit excludes, so a batch from
    /// before a committed wipe never reaches MapKit or its cleared cache, however late
    /// its enrichment starts.
    nonisolated struct PendingLocalities: Sendable {
        var candidates: [PendingLocality]
        var wipeFloor: Date?

        static let empty = PendingLocalities(candidates: [], wipeFloor: nil)
    }

    #if DEBUG
    // Task-local scope keeps fault injection per invocation across actor awaits.
    nonisolated enum SaveTestHook {
        @TaskLocal static var beforeSave: (@Sendable () throws -> Void)?
    }

    /// Fails the required Visit backing read for one invocation.
    nonisolated enum ReadTestHook {
        @TaskLocal static var beforeVisitBackingRead: (@Sendable () throws -> Void)?
    }

    func clusterUnprocessedPingsReportingChanges(
        beforeSave: @escaping @Sendable () throws -> Void
    ) async -> (created: Int, needsPublication: Bool, pendingLocalities: PendingLocalities, failed: Bool, changes: StoreChange) {
        await SaveTestHook.$beforeSave.withValue(beforeSave) {
            await clusterUnprocessedPingsReportingChanges()
        }
    }
    #endif

    private let logger = Logger(subsystem: "com.travellog.app", category: "StayClusterer")

    /// Single-flight reentrancy guard for `clusterUnprocessedPings()`.
    /// The method awaits the offline geocoder mid-loop, so actor isolation
    /// alone does not serialize overlapping calls (Swift actors are reentrant).
    private var isRunning = false

    /// One post-gate lookup's answer, witnessed by the res-8 cell it answers for.
    typealias LocalityAnswer = (candidate: PendingLocality, cell: String, locality: String?)

    /// Lookups one enrichment call makes: the first pass and one follow-up for rows
    /// that moved to another cell before the apply.
    private static let localityLookupRounds = 2

    /// Bound on candidates carried between enrichment calls.
    private static let maxRetainedLocalities = 200

    /// Candidates this clusterer still owes a lookup: rows that left their answered cell
    /// before the apply, or that a stopped or failed call did not finish, with the floor
    /// they were retained under. Memory only.
    private var retainedLocalities = PendingLocalities.empty

    /// Candidate UUIDs one apply fetch matches in a single predicate: `Stay.id` has no index,
    /// so a fetch per answer would scan the table once per candidate inside the gate.
    private static let applyFetchSliceSize = 200

    /// The committed instant of the last Delete All Data, which only `DataWipe` advances.
    nonisolated static func wipeFloor(in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) as? Date
    }

    /// Shared distance envelope with PingRecorder import pre-attachment; live and import paths must agree.
    static let distanceThresholdMeters: Double = 3000.0

    /// Time gap threshold in seconds. Pings with a larger gap start a new stay.
    /// Also used by `PingRecorder`'s import pre-attach to size the candidate-
    /// fetch window (`±timeWindowSeconds` around the imported ping).
    static let timeGapThresholdSeconds: TimeInterval = 4 * 60 * 60 // 4 hours

    /// Convenience alias matching the spelling used at the call sites in
    /// `PingRecorder.recordImportedPings` and `findHostStay`. Kept identical
    /// to `timeGapThresholdSeconds` so the live/import paths can't drift.
    static var timeWindowSeconds: TimeInterval { timeGapThresholdSeconds }

    /// Cap midpoint extension at 12 hours for both live and imported pings; sparse imports can be years apart.
    static let maxStayExtensionSeconds: TimeInterval = 12 * 60 * 60 // 12 hours

    /// Every tracked type clustering and visit reconciliation can write; the
    /// fail-open `changes` of a failed save.
    static let clusteringWrites: StoreChange = [.locationPing, .stay, .trip, .visit]

    /// Single-flight across geocoder awaits; actor reentrancy must not double-process unsaved pings.
    /// Overlapping calls return early and leave pending pings for the next pipeline run.
    @discardableResult
    func clusterUnprocessedPings() async -> Int {
        await clusterUnprocessedPingsReportingChanges().created
    }

    /// Publication is based on dirty save attempts, including failures whose
    /// persistence result is uncertain. The outcome belongs to this invocation;
    /// a later rollback or clean save cannot erase an earlier committed batch.
    /// `failed` reports a required read (Visit backing, pings, anchor, homes,
    /// existing starts) or clustering save that left pings unprocessed, or a
    /// Visit reconciliation that rolled back and left Visits unprocessed, so a
    /// caller finishing an import can wait instead of completing.
    /// `changes` is the tracked types this invocation's save attempts wrote, taken
    /// before each save; a failed save fails open to every type clustering writes.
    /// `defaults` holds the wipe floor the returned candidates are stamped with.
    func clusterUnprocessedPingsReportingChanges(
        defaults: UserDefaults = .standard
    ) async -> (created: Int, needsPublication: Bool, pendingLocalities: PendingLocalities, failed: Bool, changes: StoreChange) {
        var needsPublication = false
        // Rows, not coordinates: later pings in this walk move a new stay's centroid,
        // so candidates are read from the saved rows when the run returns.
        var pendingStays: [Stay] = []
        var changes: StoreChange = []
        guard !isRunning else {
            logger.debug("clusterUnprocessedPings() already running; skipping reentrant call.")
            return (0, needsPublication, .empty, false, [])
        }
        isRunning = true
        defer { isRunning = false }
        // Read before any row: callers hold the gate, so no wipe commits during the run.
        let wipeFloor = Self.wipeFloor(in: defaults)

        // A required read: a closed Visit fixes its stay's departure, and the
        // walk's one-shot closing extension would otherwise persist a tail
        // past it that no later pass retracts.
        var visitBackedStayIDs: Set<UUID>
        var closedVisitBackedStayIDs: Set<UUID>
        do {
            let backing = try fetchVisitBackingSets()
            visitBackedStayIDs = backing.all
            closedVisitBackedStayIDs = backing.closed
        } catch {
            logger.error("Failed to fetch Visit backing sets: \(error.localizedDescription)")
            return (0, needsPublication, .empty, true, [])
        }

        let unprocessedPredicate = #Predicate<LocationPing> { $0.isProcessed == false }
        let unprocessedDescriptor = FetchDescriptor<LocationPing>(
            predicate: unprocessedPredicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        let unprocessedPings: [LocationPing]
        do {
            unprocessedPings = try modelContext.fetch(unprocessedDescriptor)
        } catch {
            logger.error("Failed to fetch unprocessed pings: \(error.localizedDescription)")
            return (0, needsPublication, .empty, true, [])
        }

        if unprocessedPings.isEmpty {
            logger.debug("No unprocessed pings to cluster.")
        } else {
            logger.info("Clustering \(unprocessedPings.count) unprocessed ping(s).")
        }

        // The anchor and the homes are required reads: without them the walk
        // would split the ongoing stay or stamp every distance from nowhere.
        var currentStay: Stay?
        let anchors: [HomeAnchor]
        do {
            currentStay = try fetchMostRecentStay()
            anchors = try fetchAllHomes()
        } catch {
            logger.error("Failed to read the clustering anchor or homes: \(error.localizedDescription)")
            return (0, needsPublication, .empty, true, [])
        }
        let homes = anchors.map { HomeWindow($0) }
        // Without a temporary home an extension measures as it always has.
        let hasTemporaryHome = anchors.contains(where: \.isTemporary)
        var currentStayPingCount = currentStay?.pingIDs.count ?? 0
        var currentCentroidLat = currentStay?.centroidLatitude ?? 0
        var currentCentroidLon = currentStay?.centroidLongitude ?? 0
        var currentLastTimestamp = currentStay?.endTime ?? .distantPast

        // Retain the initial live anchor so historical imports cannot split the ongoing stay when the walk reaches live pings.
        let originalAnchor = currentStay
        let originalAnchorEnd = currentLastTimestamp

        // Existing stays a historical walk can cross; read before this run creates any, so extensions stop short of them.
        var existingStartTimes: [Date] = []
        if let first = unprocessedPings.first, first.timestamp < originalAnchorEnd {
            let lower = first.timestamp
            let upper = originalAnchorEnd
            var descriptor = FetchDescriptor<Stay>(
                predicate: #Predicate { $0.startTime > lower && $0.startTime <= upper },
                sortBy: [SortDescriptor(\.startTime, order: .forward)]
            )
            descriptor.propertiesToFetch = [\.startTime]
            do {
                existingStartTimes = try modelContext.fetch(descriptor).map(\.startTime)
            } catch {
                logger.error("Failed to read existing stay starts: \(error.localizedDescription)")
                return (0, needsPublication, .empty, true, [])
            }
        }

        var newStaysCreated = 0
        var titleSnapshots:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]

        for ping in unprocessedPings {
            // Check for cancellation (e.g., BGAppRefreshTask expiration).
            // We save partial progress below, so stopping mid-loop is safe.
            guard !Task.isCancelled else {
                logger.info("Clustering cancelled after processing \(newStaysCreated) stay(s).")
                break
            }

            // Return to the original anchor after historical pings moved the walk backward.
            if let originalAnchor,
               currentStay !== originalAnchor,
               currentLastTimestamp < originalAnchorEnd,
               ping.timestamp >= originalAnchorEnd {
                currentStay = originalAnchor
                currentStayPingCount = originalAnchor.pingIDs.count
                currentCentroidLat = originalAnchor.centroidLatitude
                currentCentroidLon = originalAnchor.centroidLongitude
                currentLastTimestamp = originalAnchor.endTime
            }

            let pingLocation = CLLocation(latitude: ping.latitude, longitude: ping.longitude)
            let timeSinceLast = ping.timestamp.timeIntervalSince(currentLastTimestamp)

            var startsNewStay = false

            if currentStay == nil {
                startsNewStay = true
            } else {
                let centroidLocation = CLLocation(latitude: currentCentroidLat, longitude: currentCentroidLon)
                let distance = pingLocation.distance(from: centroidLocation)

                // A ping before the continuity anchor cannot extend it; start a historical stay without moving live endTime backward.
                if distance > Self.distanceThresholdMeters
                    || timeSinceLast > Self.timeGapThresholdSeconds
                    || timeSinceLast < 0 {
                    startsNewStay = true
                }
            }

            if startsNewStay {
                if let stay = currentStay, timeSinceLast > 0 {
                    captureTitleSnapshot(for: stay, in: &titleSnapshots)
                    // Bound midpoint extension for sparse historical imports using the same cap as live clustering.
                    if !closedVisitBackedStayIDs.contains(stay.id) {
                        let weatherKey = WeatherEnricher.WeatherValidityKey(stay)
                        let cappedDelta = min(timeSinceLast / 2.0, Self.maxStayExtensionSeconds)
                        let midpoint = stay.endTime.addingTimeInterval(cappedDelta)
                        var candidate = min(midpoint, ping.timestamp.addingTimeInterval(-60))
                        // A historical stay must not extend over a stay the store already holds.
                        if stay !== originalAnchor,
                           let next = Self.firstStart(after: stay.startTime, in: existingStartTimes) {
                            candidate = min(candidate, next.addingTimeInterval(-60))
                        }
                        // Floor at current endTime, not startTime: closing may only extend the stay.
                        stay.endTime = max(candidate, stay.endTime)
                        stay.durationMinutes = max(0, Int(stay.endTime.timeIntervalSince(stay.startTime) / 60))
                        // Weather aggregated for the old UTC day span no longer describes the closed stay.
                        WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)
                    }
                }

                let newStay = await createStay(
                    startTime: ping.timestamp,
                    endTime: ping.timestamp,
                    latitude: ping.latitude,
                    longitude: ping.longitude,
                    h3IndexRes6: ping.h3IndexRes6,
                    pingIDs: [ping.id],
                    source: ping.source.derivedRecordSource,
                    seedPing: ping,
                    homes: homes,
                    pendingStays: &pendingStays
                )

                currentStay = newStay
                currentStayPingCount = 1
                currentCentroidLat = ping.latitude
                currentCentroidLon = ping.longitude
                currentLastTimestamp = ping.timestamp
                newStaysCreated += 1
            } else {
                guard let stay = currentStay else { continue }
                captureTitleSnapshot(for: stay, in: &titleSnapshots)
                let weatherKey = WeatherEnricher.WeatherValidityKey(stay)

                currentStayPingCount += 1
                stay.appendPingID(ping.id)
                // Mixed provenance follows StayGeometry's rule: live channels share one lane.
                if stay.source != .merged,
                   stay.source.derivedRecordSource != ping.source.derivedRecordSource {
                    markMerged(stay)
                }
                // pingCount must follow parse-visible IDs; appendPingID alone preserves larger restored counts,
                // which would change PingRecorder’s import-centroid weights.
                stay.pingCount = currentStayPingCount
                // Never move endTime backward or persist endTime < startTime, even for out-of-order pings.
                stay.endTime = max(stay.endTime, ping.timestamp)
                stay.durationMinutes = max(0, Int(stay.endTime.timeIntervalSince(stay.startTime) / 60))

                let n = Double(currentStayPingCount)
                currentCentroidLat = currentCentroidLat + (ping.latitude - currentCentroidLat) / n
                // Use a dateline-safe mean so ±180° pings do not average toward Greenwich.
                currentCentroidLon = GeoMath.runningMeanLongitude(
                    current: currentCentroidLon, adding: ping.longitude, newCount: n
                )
                stay.centroidLatitude = currentCentroidLat
                stay.centroidLongitude = currentCentroidLon

                // Keep H3 aligned with the moving centroid.
                if let updatedH3 = H3Service.cellIndex(latitude: currentCentroidLat, longitude: currentCentroidLon) {
                    stay.h3IndexRes6 = updatedH3
                }
                WeatherEnricher.clearWeatherIfKeyChanged(stay, from: weatherKey)

                // Refresh home distance from the current centroid for classifier inputs.
                stay.distanceFromHomeKm = extendedStayDistance(
                    stay, pingTime: ping.timestamp, homes: homes, hasTemporaryHome: hasTemporaryHome)

                // Re-evaluate airport proximity from the CURRENT centroid; drift can cross the airport boundary.
                stay.isAirport = AirportDetector.shared.isNearAirport(
                    CLLocationCoordinate2D(latitude: currentCentroidLat, longitude: currentCentroidLon)
                )

                currentLastTimestamp = ping.timestamp

                // Coalesce country fields when adopting a locality; island/FUA-only pings may lack country data.
                if stay.locality == nil, let locality = ping.locality {
                    stay.locality = locality
                    stay.administrativeArea = ping.administrativeArea ?? stay.administrativeArea
                    stay.country = ping.country ?? stay.country
                    stay.isoCountryCode = ping.isoCountryCode ?? stay.isoCountryCode
                }
            }

            ping.isProcessed = true
        }

        if !unprocessedPings.isEmpty {
            do {
                invalidateChangedTitles(titleSnapshots)
                needsPublication = modelContext.hasChanges || needsPublication
                changes.formUnion(StoreChange.pending(in: modelContext))
                #if DEBUG
                try SaveTestHook.beforeSave?()
                #endif
                try modelContext.save()
                logger.info("Clustering complete. Created \(newStaysCreated) new stay(s) from \(unprocessedPings.count) ping(s).")
            } catch {
                modelContext.rollback()
                changes.formUnion(Self.clusteringWrites)
                logger.error("Failed to save clustered stays: \(error.localizedDescription)")
                return (0, needsPublication, .empty, true, changes)
            }
        }

        let committedPendingCount = pendingStays.count
        var visitsFailed = false
        var visitSnapshots:
            [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot] = [:]
        do {
            let result = try await reconcileUnprocessedVisits(
                homes: homes,
                visitBackedStayIDs: &visitBackedStayIDs,
                closedVisitBackedStayIDs: &closedVisitBackedStayIDs,
                titleSnapshots: &visitSnapshots,
                pendingStays: &pendingStays
            )
            if result.mutated {
                invalidateChangedTitles(visitSnapshots)
                needsPublication = modelContext.hasChanges || needsPublication
                changes.formUnion(StoreChange.pending(in: modelContext))
                #if DEBUG
                try SaveTestHook.beforeSave?()
                #endif
                try modelContext.save()
            }
            newStaysCreated += result.created
        } catch {
            modelContext.rollback()
            changes.formUnion(Self.clusteringWrites)
            pendingStays.removeSubrange(committedPendingCount...)
            // The committed ping batch keeps its count and candidates.
            visitsFailed = true
            logger.error("Failed to reconcile visits: \(error.localizedDescription)")
        }

        return (newStaysCreated, needsPublication,
                pendingLocalities(for: pendingStays, wipeFloor: wipeFloor), visitsFailed, changes)
    }

    /// Candidates carry each committed row's final centroid, so the post-gate lookup
    /// answers for the res-8 cell the row is in when enrichment applies. A row that
    /// adopted a locality later in the walk needs no lookup.
    private func pendingLocalities(for stays: [Stay], wipeFloor: Date?) -> PendingLocalities {
        var seen: Set<ObjectIdentifier> = []
        let candidates = stays.compactMap { stay -> PendingLocality? in
            guard seen.insert(ObjectIdentifier(stay)).inserted,
                  !stay.isDeleted, stay.locality == nil else { return nil }
            return (stay.id, stay.centroidLatitude, stay.centroidLongitude)
        }
        return PendingLocalities(candidates: candidates, wipeFloor: wipeFloor)
    }

    /// Call after the clustering gate returns, before summaries or title generation.
    /// Only scalar IDs/coordinates leave the write unit; each apply refetches current rows.
    /// A row whose centroid left the answered res-8 cell before the apply (a later
    /// clustering run or import pre-attachment moved it) is looked up once more at its
    /// current centroid; one still moving, or one a stopped or failed call did not
    /// finish, is carried into this clusterer's next call unless Delete All Data commits
    /// first. `defaults` holds the wipe floor.
    @discardableResult
    func enrichPendingLocalities(
        _ pending: PendingLocalities, defaults: UserDefaults = .standard
    ) async -> Bool {
        let wipeFloor = Self.wipeFloor(in: defaults)
        // Carried or new candidates read before a committed wipe name deleted rows.
        var candidates = [retainedLocalities, pending]
            .filter { $0.wipeFloor == wipeFloor }
            .flatMap(\.candidates)
        retainedLocalities = .empty
        var attemptedCells: Set<String> = []
        var namesByCell: [String: String] = [:]
        var saved = false
        var round = 0
        while !candidates.isEmpty, round < Self.localityLookupRounds {
            round += 1
            var answers: [LocalityAnswer] = []
            for candidate in candidates {
                guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical,
                      Self.wipeFloor(in: defaults) == wipeFloor else { break }
                let key = MapKitLocalityCache.cellKey(
                    latitude: candidate.latitude, longitude: candidate.longitude)
                if attemptedCells.insert(key).inserted {
                    // Delete All Data advances the floor before Settings clears the cache, so a
                    // generation read before this check admits the lookup only if no clear followed.
                    let generation = await MapKitLocalityCache.shared.generation
                    guard Self.wipeFloor(in: defaults) == wipeFloor else { break }
                    if let result = await GeocodeResolver.shared.resolveWithFallback(
                        latitude: candidate.latitude, longitude: candidate.longitude,
                        allowRateLimitWait: false, cacheGeneration: generation),
                       let locality = result.localityForStorage {
                        namesByCell[key] = locality
                    }
                }
                answers.append((candidate, key, namesByCell[key]))
            }
            let unattempted = Array(candidates.dropFirst(answers.count))
            guard !answers.isEmpty else { break }
            // Only stays with a name to write take the gate. The others' moved-row witness
            // is a read, so it runs without queueing behind the gate. Partitioned by stay
            // UUID, so every answer for a physical row is judged together.
            let namedIDs = Set(answers.filter { $0.locality != nil }.map { $0.candidate.id })
            let named = answers.filter { namedIDs.contains($0.candidate.id) }
            let witnessOnly = applyLocalities(answers.filter { !namedIDs.contains($0.candidate.id) })
            var retry = witnessOnly.retry
            if !named.isEmpty {
                // Title invalidation and summary recomputation also mutate parent trips.
                let outcome = await PipelineGate.shared.runReturning(touching: [.stay, .trip]) {
                    await self.applyLocalities(named)
                }
                saved = saved || outcome.saved
                retry += outcome.retry
            }
            candidates = retry + unattempted
            // A stopped lookup loop gets no follow-up round.
            guard unattempted.isEmpty else { break }
        }
        // A wipe committed during this call: nothing it carried may survive it.
        guard Self.wipeFloor(in: defaults) == wipeFloor else { return saved }
        retainLocalities(candidates, wipeFloor: wipeFloor)
        return saved
    }

    /// Writes each named answer to the physical rows of its stay that still miss a
    /// locality and whose current centroid is in the answered cell. Returns, at their
    /// current centroid, the rows no answer's cell holds any more, and every candidate
    /// when a read or the save fails. Runs inside the gate when an answer has a name;
    /// with none it only reads.
    private func applyLocalities(_ answers: [LocalityAnswer]) -> (saved: Bool, retry: [PendingLocality]) {
        guard !answers.isEmpty else { return (false, []) }
        // The clusterer's registered stays may predate another writer's update or deletion.
        let context = ModelContext(modelContainer)
        do {
            var named: [PersistentIdentifier: (stay: Stay, locality: String)] = [:]
            var witnessed: Set<PersistentIdentifier> = []
            var moved: [PersistentIdentifier: Stay] = [:]
            let answersByID = Dictionary(grouping: answers, by: { $0.candidate.id })
            let allIDs = Array(answersByID.keys)
            var start = 0
            while start < allIDs.count {
                let ids = Array(allIDs[start ..< min(start + Self.applyFetchSliceSize, allIDs.count)])
                start += ids.count
                let descriptor = FetchDescriptor<Stay>(predicate: #Predicate { ids.contains($0.id) })
                // Witness each physical row: a stay extended into another res-8 cell after
                // the lookup must not take the name answered for its earlier centroid.
                for stay in try context.fetch(descriptor) where stay.locality == nil {
                    let row = stay.persistentModelID
                    let cell = MapKitLocalityCache.cellKey(
                        latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
                    for answer in answersByID[stay.id] ?? [] {
                        guard cell == answer.cell else {
                            moved[row] = stay
                            continue
                        }
                        witnessed.insert(row)
                        if named[row] == nil, let locality = answer.locality {
                            named[row] = (stay, locality)
                        }
                    }
                }
            }
            var retry: [PendingLocality] = []
            for (row, stay) in moved where !witnessed.contains(row) {
                retry.append((stay.id, stay.centroidLatitude, stay.centroidLongitude))
            }
            let changedStays = named.values.map { $0.stay }
            guard !changedStays.isEmpty else { return (false, retry) }
            // A concurrent pass may already have classified and titled these stays.
            let parentSnapshots = TripTitleStore.parentSemanticSnapshots(for: changedStays)
            for entry in named.values {
                entry.stay.locality = entry.locality
            }
            // Live enrichment may keep a summary built without its home-place
            // filter; it latches nothing and the next membership change re-derives it.
            _ = try? TripTitleStore.invalidateChangedParentTitles(from: parentSnapshots, in: context)
            guard context.hasChanges else { return (false, retry) }
            try context.save()
            return (true, retry)
        } catch {
            context.rollback()
            logger.error("Failed to save enriched stay localities: \(error.localizedDescription)")
            return (false, answers.map { $0.candidate })
        }
    }

    /// Keeps the newest candidate per stay and cell, bounded, for the next call. Entries
    /// retained under an older wipe floor are dropped rather than merged.
    private func retainLocalities(_ candidates: [PendingLocality], wipeFloor: Date?) {
        guard !candidates.isEmpty else { return }
        let retained = retainedLocalities.wipeFloor == wipeFloor ? retainedLocalities.candidates : []
        var seen: Set<String> = []
        var newestFirst: [PendingLocality] = []
        for candidate in (retained + candidates).reversed() {
            let key = candidate.id.uuidString + "|" + MapKitLocalityCache.cellKey(
                latitude: candidate.latitude, longitude: candidate.longitude)
            if seen.insert(key).inserted { newestFirst.append(candidate) }
        }
        retainedLocalities = PendingLocalities(
            candidates: Array(newestFirst.prefix(Self.maxRetainedLocalities).reversed()),
            wipeFloor: wipeFloor)
    }

    // MARK: - Helpers

    /// The earliest of the ascending `sortedStarts` after `date`. A historical walk asks once per
    /// closed stay, so this binary search keeps a long import from scanning every existing stay each time.
    nonisolated static func firstStart(
        after date: Date, in sortedStarts: some RandomAccessCollection<Date>
    ) -> Date? {
        var low = sortedStarts.startIndex
        var high = sortedStarts.endIndex
        while low < high {
            let middle = sortedStarts.index(low, offsetBy: sortedStarts.distance(from: low, to: high) / 2)
            if sortedStarts[middle] <= date {
                low = sortedStarts.index(after: middle)
            } else {
                high = middle
            }
        }
        return low == sortedStarts.endIndex ? nil : sortedStarts[low]
    }

    /// Marks a stay `.merged` and its physical parent trip with it, as
    /// `Trip.recomputeSummary` would derive it. A trip left `.photoImport`
    /// would be deleted by a photo discard that keeps this stay.
    private func markMerged(_ stay: Stay) {
        stay.source = .merged
        if let trip = stay.trip, trip.source != .merged {
            trip.source = .merged
        }
    }

    private func captureTitleSnapshot(
        for stay: Stay,
        in snapshots: inout [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot]
    ) {
        guard let trip = stay.trip else { return }
        let identity = ObjectIdentifier(trip)
        guard snapshots[identity] == nil else { return }
        snapshots[identity] = TripTitleStore.ParentSemanticSnapshot(
            trip: trip,
            semantic: TripTitleStore.semanticSnapshot(for: trip))
    }

    private func invalidateChangedTitles(
        _ snapshots: [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot]
    ) {
        for snapshot in snapshots.values {
            let trip = snapshot.trip
            guard !trip.isDeleted,
                  snapshot.semantic != TripTitleStore.semanticSnapshot(for: trip) else {
                continue
            }
            TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
        }
    }

    private func fetchVisitBackingSets() throws -> (all: Set<UUID>, closed: Set<UUID>) {
        #if DEBUG
        try ReadTestHook.beforeVisitBackingRead?()
        #endif
        let predicate = #Predicate<Visit> { $0.stayID != nil }
        let visits = try modelContext.fetch(FetchDescriptor<Visit>(predicate: predicate))
        var all: Set<UUID> = []
        var closed: Set<UUID> = []
        for visit in visits {
            guard let stayID = visit.stayID else { continue }
            all.insert(stayID)
            if visit.departureDate != nil {
                closed.insert(stayID)
            }
        }
        return (all, closed)
    }

    private func reconcileUnprocessedVisits(
        homes: [HomeWindow],
        visitBackedStayIDs: inout Set<UUID>,
        closedVisitBackedStayIDs: inout Set<UUID>,
        titleSnapshots: inout [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot],
        pendingStays: inout [Stay]
    ) async throws -> (created: Int, mutated: Bool) {
        let predicate = #Predicate<Visit> { $0.isProcessed == false }
        let fetched = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.arrivalDate, order: .forward)]))
        let unprocessed = fetched.sorted {
            if $0.arrivalDate != $1.arrivalDate {
                return $0.arrivalDate < $1.arrivalDate
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        var created = 0
        var mutated = false

        for seed in unprocessed where !seed.isProcessed {
            // A completed Visit group is a resumable boundary. Keep the
            // unvisited groups pending so background expiry stops promptly.
            guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical else { break }
            let lowerBound = seed.arrivalDate.addingTimeInterval(-1)
            let upperBound = seed.arrivalDate.addingTimeInterval(1)
            let siblingPredicate = #Predicate<Visit> {
                $0.arrivalDate >= lowerBound && $0.arrivalDate <= upperBound
            }
            let seedArrivalBits = seed.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
            let seedLocation = CLLocation(latitude: seed.latitude, longitude: seed.longitude)
            let siblings = try modelContext.fetch(FetchDescriptor<Visit>(
                predicate: siblingPredicate)).filter {
                $0.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
                    == seedArrivalBits
                    && seedLocation.distance(from: CLLocation(
                        latitude: $0.latitude, longitude: $0.longitude))
                        <= Self.distanceThresholdMeters
            }

            guard let canonical = siblings.min(by: { lhs, rhs in
                let lhsClosed = lhs.departureDate != nil
                let rhsClosed = rhs.departureDate != nil
                if lhsClosed != rhsClosed { return lhsClosed }
                return lhs.id.uuidString < rhs.id.uuidString
            }) else { continue }

            let siblingIDs = Set(siblings.map(\.id))
            let linkedIDs = Set(siblings.compactMap(\.stayID))
            var displacedHostIDs: Set<UUID> = []
            let linkedStayID: UUID?
            if linkedIDs.count <= 1 {
                linkedStayID = linkedIDs.first
            } else {
                let closedLinked = siblings.lazy.filter {
                    $0.departureDate != nil && $0.stayID != nil
                }
                    .min { $0.id.uuidString < $1.id.uuidString }
                let anyLinked = siblings.lazy.filter { $0.stayID != nil }
                    .min { $0.id.uuidString < $1.id.uuidString }
                linkedStayID = closedLinked?.stayID ?? anyLinked?.stayID
                if let linkedStayID {
                    displacedHostIDs = linkedIDs.subtracting([linkedStayID])
                }
            }

            let stay: Stay
            if let linkedStayID {
                guard let linkedStay = try fetchLinkedStay(id: linkedStayID)
                else {
                    for sibling in siblings { sibling.isProcessed = true }
                    mutated = true
                    continue
                }
                stay = linkedStay

                if !displacedHostIDs.isEmpty {
                    for sibling in siblings { sibling.stayID = linkedStayID }
                    for displacedID in displacedHostIDs {
                        guard let displaced = try fetchLinkedStay(id: displacedID),
                              displaced.pingCount == 0 else { continue }
                        // A user's correction or curated trip outweighs the duplicate: keep the host.
                        guard !displaced.userOverridden,
                              displaced.trip?.userEdited != true else { continue }
                        let capturedID: UUID? = displacedID
                        let displacedPredicate = #Predicate<Visit> { $0.stayID == capturedID }
                        let references = try modelContext.fetch(FetchDescriptor<Visit>(
                            predicate: displacedPredicate))
                        guard !references.contains(where: {
                            !siblingIDs.contains($0.id)
                        }) else { continue }
                        // Detach before deleting so stale inverse arrays cannot retain the deleted stay.
                        displaced.trip = nil
                        modelContext.delete(displaced)
                    }
                }
            } else {
                let arrival = canonical.arrivalDate
                let effectiveEnd = canonical.departureDate ?? max(arrival, canonical.receivedAt)
                let earliestStart = arrival.addingTimeInterval(-Self.timeGapThresholdSeconds)
                let latestEnd = effectiveEnd.addingTimeInterval(Self.timeGapThresholdSeconds)
                let candidatePredicate = #Predicate<Stay> {
                    $0.startTime <= latestEnd && $0.endTime >= earliestStart
                }
                let candidates = try modelContext.fetch(FetchDescriptor<Stay>(
                    predicate: candidatePredicate))
                let visitLocation = CLLocation(latitude: canonical.latitude,
                                               longitude: canonical.longitude)
                let scored = candidates.compactMap {
                    candidate -> (Stay, Double, TimeInterval)? in
                    let distance = visitLocation.distance(from: CLLocation(
                        latitude: candidate.centroidLatitude,
                        longitude: candidate.centroidLongitude))
                    guard distance <= Self.distanceThresholdMeters else { return nil }
                    let overlaps = candidate.startTime <= effectiveEnd
                        && candidate.endTime >= arrival
                    let gapAfter = arrival.timeIntervalSince(candidate.endTime)
                    let gapBefore = candidate.startTime.timeIntervalSince(effectiveEnd)
                    guard overlaps
                            || (0...Self.timeGapThresholdSeconds).contains(gapAfter)
                            || (0...Self.timeGapThresholdSeconds).contains(gapBefore)
                    else { return nil }
                    let overlap = max(
                        0,
                        min(candidate.endTime, effectiveEnd).timeIntervalSince(
                            max(candidate.startTime, arrival)))
                    return (candidate, distance, overlap)
                }

                let nearestDistance = scored.lazy.map { $0.1 }.min() ?? 0
                let selected = scored.lazy.filter { $0.1 <= nearestDistance + 300 }
                    .min {
                        $0.2 != $1.2
                            ? $0.2 > $1.2
                            : $0.0.id.uuidString < $1.0.id.uuidString
                    }?.0

                if let selected {
                    stay = selected
                    switch stay.source {
                    case .photoImport, .timelineImport, .gpxImport,
                         .jsonImport, .merged:
                        if stay.source != .merged {
                            captureTitleSnapshot(for: stay, in: &titleSnapshots)
                            markMerged(stay)
                        }
                    case .liveSLC, .foregroundStream:
                        break
                    }
                } else {
                    guard let h3Index = H3Service.cellIndex(latitude: canonical.latitude,
                                                           longitude: canonical.longitude)
                    else {
                        logger.error("Failed to derive H3 index for Visit siblings.")
                        for sibling in siblings { sibling.isProcessed = true }
                        mutated = true
                        continue
                    }
                    stay = await createStay(
                        startTime: arrival,
                        endTime: effectiveEnd,
                        latitude: canonical.latitude,
                        longitude: canonical.longitude,
                        h3IndexRes6: h3Index,
                        pingIDs: [],
                        source: .liveSLC,
                        seedPing: nil,
                        homes: homes,
                        pendingStays: &pendingStays
                    )
                    created += 1
                }
            }

            try applyVisitInterval(canonical, siblings: siblings, to: stay,
                closedVisitBackedStayIDs: closedVisitBackedStayIDs,
                titleSnapshots: &titleSnapshots)
            for sibling in siblings {
                sibling.stayID = stay.id
                sibling.isProcessed = true
            }
            mutated = true
            visitBackedStayIDs.insert(stay.id)
            if canonical.departureDate != nil {
                closedVisitBackedStayIDs.insert(stay.id)
            }
        }

        return (created, mutated)
    }

    private func applyVisitInterval(
        _ visit: Visit,
        siblings: [Visit],
        to stay: Stay,
        closedVisitBackedStayIDs: Set<UUID>,
        titleSnapshots: inout [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot]
    ) throws {
        let originalStart = stay.startTime
        let originalEnd = stay.endTime
        let originalWeatherKey = WeatherEnricher.WeatherValidityKey(stay)
        captureTitleSnapshot(for: stay, in: &titleSnapshots)

        let arrival = visit.arrivalDate
        let effectiveEnd = visit.departureDate ?? max(arrival, visit.receivedAt)
        let siblingIDs = Set(siblings.map(\.id))
        let targetLastMeasuredObservation = try lastMeasuredObservation(for: stay,
                                                                         excluding: siblingIDs)
        var proposedStart = min(stay.startTime, arrival)

        var mutatedPrevious: Stay?
        var previousOriginalStart: Date?
        var previousOriginalEnd: Date?
        var previousWeatherKey: WeatherEnricher.WeatherValidityKey?
        if let previous = try StayClusterer.previousStay(in: modelContext, before: originalStart, excluding: stay.id),
           previous.endTime >= proposedStart {
            previousOriginalStart = previous.startTime
            previousOriginalEnd = previous.endTime
            previousWeatherKey = WeatherEnricher.WeatherValidityKey(previous)
            captureTitleSnapshot(for: previous, in: &titleSnapshots)
            let pullback = arrival.addingTimeInterval(-60)
            let previousLastMeasuredObservation = try lastMeasuredObservation(for: previous,
                                                                               excluding: [])
            if closedVisitBackedStayIDs.contains(previous.id)
                || pullback < previousLastMeasuredObservation {
                proposedStart = previous.endTime.addingTimeInterval(1)
            } else {
                previous.endTime = max(previousLastMeasuredObservation, pullback)
                previous.durationMinutes = max(0, Int(
                    previous.endTime.timeIntervalSince(previous.startTime) / 60))
                mutatedPrevious = previous
            }
        }

        let proposedEnd: Date
        if let departure = visit.departureDate {
            proposedEnd = max(departure, targetLastMeasuredObservation)
        } else {
            proposedEnd = max(stay.endTime, effectiveEnd)
        }

        let successor = try StayClusterer.nextStay(in: modelContext, after: originalStart, excluding: stay.id)
        stay.startTime = proposedStart
        if let successor {
            stay.endTime = max(
                stay.startTime,
                min(proposedEnd, successor.startTime.addingTimeInterval(-1)))
        } else {
            stay.endTime = max(stay.startTime, proposedEnd)
        }

        if stay.pingCount == 0 {
            stay.centroidLatitude = visit.latitude
            stay.centroidLongitude = visit.longitude
            if let h3Index = H3Service.cellIndex(
                latitude: visit.latitude, longitude: visit.longitude) {
                stay.h3IndexRes6 = h3Index
            }
            stay.isAirport = AirportDetector.shared.isNearAirport(
                CLLocationCoordinate2D(
                    latitude: visit.latitude, longitude: visit.longitude))
        }
        stay.durationMinutes = max(0, Int(
            stay.endTime.timeIntervalSince(stay.startTime) / 60))

        refreshParentTripDates(for: [stay] + (mutatedPrevious.map { [$0] } ?? []))
        invalidateIntervalDerivatives(for: stay, originalStart: originalStart,
                                      originalEnd: originalEnd, successor: successor)
        if let previous = mutatedPrevious,
           let previousOriginalStart,
           let previousOriginalEnd {
            invalidateIntervalDerivatives(for: previous,
                                          originalStart: previousOriginalStart,
                                          originalEnd: previousOriginalEnd,
                                          successor: stay)
        }
        // Weather follows the validity key, not the transit threshold: a
        // sub-minute shift across UTC midnight or a zero-ping cell move still
        // invalidates it, while an edit inside the key keeps it.
        WeatherEnricher.clearWeatherIfKeyChanged(stay, from: originalWeatherKey)
        if let previous = mutatedPrevious, let previousWeatherKey {
            WeatherEnricher.clearWeatherIfKeyChanged(previous, from: previousWeatherKey)
        }
    }

    private func lastMeasuredObservation(
        for stay: Stay,
        excluding siblingIDs: Set<UUID>
    ) throws -> Date {
        var lastObservation: Date?
        let pingIDs = stay.pingIDs
        if !pingIDs.isEmpty {
            let predicate = #Predicate<LocationPing> { pingIDs.contains($0.id) }
            for ping in try modelContext.fetch(FetchDescriptor<LocationPing>(
                predicate: predicate)) {
                lastObservation = max(lastObservation ?? ping.timestamp, ping.timestamp)
            }
        }

        let stayID: UUID? = stay.id
        let visitPredicate = #Predicate<Visit> { $0.stayID == stayID }
        for visit in try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: visitPredicate))
        where !siblingIDs.contains(visit.id) {
            let effectiveEnd = visit.departureDate ?? max(visit.arrivalDate,
                                                           visit.receivedAt)
            lastObservation = max(lastObservation ?? effectiveEnd, effectiveEnd)
        }
        return lastObservation ?? stay.startTime
    }

    nonisolated static func previousStay(in context: ModelContext, before targetStart: Date, excluding stayID: UUID) throws -> Stay? {
        let capturedStart = targetStart
        let capturedID = stayID
        let predicate = #Predicate<Stay> {
            $0.startTime < capturedStart && $0.id != capturedID
        }
        var descriptor = FetchDescriptor<Stay>(predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    nonisolated static func nextStay(in context: ModelContext, after targetStart: Date, excluding stayID: UUID) throws -> Stay? {
        let capturedStart = targetStart
        let capturedID = stayID
        let predicate = #Predicate<Stay> {
            $0.startTime > capturedStart && $0.id != capturedID
        }
        var descriptor = FetchDescriptor<Stay>(predicate: predicate,
            sortBy: [SortDescriptor(\.startTime, order: .forward)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchLinkedStay(id stayID: UUID) throws -> Stay? {
        let capturedID = stayID
        let predicate = #Predicate<Stay> { $0.id == capturedID }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.startTime, order: .forward),
                SortDescriptor(\.endTime, order: .forward)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func invalidateIntervalDerivatives(
        for stay: Stay,
        originalStart: Date,
        originalEnd: Date,
        successor: Stay?
    ) {
        guard abs(stay.startTime.timeIntervalSince(originalStart)) >= 60
                || abs(stay.endTime.timeIntervalSince(originalEnd)) >= 60 else {
            return
        }
        stay.transitFromPreviousRaw = nil
        stay.distanceFromPreviousKm = nil
        successor?.transitFromPreviousRaw = nil
        successor?.distanceFromPreviousKm = nil
    }

    private func refreshParentTripDates(for stays: [Stay]) {
        var refreshedTrips: Set<ObjectIdentifier> = []
        for stay in stays {
            guard let trip = stay.trip else { continue }
            let identity = ObjectIdentifier(trip)
            guard refreshedTrips.insert(identity).inserted else { continue }
            let orderedStays = trip.orderedStays
            guard let first = orderedStays.first,
                  let last = orderedStays.last else {
                continue
            }
            trip.startDate = first.startTime
            if trip.isComplete, trip.endDate != nil {
                trip.endDate = last.endTime
            }
        }
    }

    private func createStay(
        startTime: Date,
        endTime: Date,
        latitude: Double,
        longitude: Double,
        h3IndexRes6: String,
        pingIDs: [UUID],
        source: DataSource,
        seedPing: LocationPing?,
        homes: [HomeWindow],
        pendingStays: inout [Stay]
    ) async -> Stay {
        let distFromHome = closestHomeDistance(
            latitude: latitude,
            longitude: longitude,
            atTime: startTime,
            homes: homes
        )

        let newStay = Stay(
            startTime: startTime,
            endTime: endTime,
            centroidLatitude: latitude,
            centroidLongitude: longitude,
            h3IndexRes6: h3IndexRes6,
            pingCount: pingIDs.count,
            distanceFromHomeKm: distFromHome,
            pingIDs: pingIDs,
            // Derived records use one live provenance lane while
            // import sources retain their distinct persisted tokens.
            source: source
        )

        if let seedPing {
            newStay.locality = seedPing.locality
            newStay.administrativeArea = seedPing.administrativeArea
            newStay.country = seedPing.country
            newStay.isoCountryCode = seedPing.isoCountryCode
        }

        // Resolve the centroid for metro/island fields that LocationPing does not store.
        // Network enrichment runs after the caller releases the clustering write gate.
        let resolved = await GeocodeResolver.shared.resolve(
            latitude: latitude,
            longitude: longitude
        )
        if let r = resolved {
            newStay.subLocality = r.subLocalityName
            newStay.metroName = r.metroName
            newStay.islandName = r.islandName
            // The seed ping may still await geocoding; use the resolver’s locality fallback.
            if newStay.locality == nil {
                // Country-name guard — shared definition:
                // `Result.localityForStorage` (nil-over-nil is harmless).
                newStay.locality = r.localityForStorage
                newStay.administrativeArea = newStay.administrativeArea
                    ?? r.administrativeArea
                newStay.country = newStay.country ?? r.country
                newStay.isoCountryCode = newStay.isoCountryCode
                    ?? r.isoCountryCode
            }
            if newStay.locality == nil, r.bestLocalityName == nil {
                pendingStays.append(newStay)
            }
        }

        // Stamped once the country is known: it puts the stay on its side of the date line.
        newStay.timeZoneIdentifier = StayTimeZone.identifier(
            for: source, longitude: longitude,
            isoCountryCode: newStay.isoCountryCode ?? resolved?.isoCountryCode,
            at: startTime)

        // Stamp airport proximity for downstream classification and title generation.
        newStay.isAirport = AirportDetector.shared.isNearAirport(
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )

        modelContext.insert(newStay)
        return newStay
    }

    private func fetchMostRecentStay() throws -> Stay? {
        var descriptor = FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    /// Every home and temporary home, including ended ones, for time-aware distance computation.
    private func fetchAllHomes() throws -> [HomeAnchor] {
        try HomeAnchors.fetch(in: modelContext)
    }

    /// The distance an extended stay keeps at its moved centroid. Without a
    /// temporary home, the homes of the ping's time, as always. With one, a
    /// trip member keeps the distance assembly measured from the trip's
    /// departure home: the centroid moves within the stay, the home it left
    /// does not, and the nearest home at the ping's time can be a base the
    /// trip never left from. A tripless stay is measured at its own start,
    /// as creation measures it.
    private func extendedStayDistance(
        _ stay: Stay, pingTime: Date, homes: [HomeWindow], hasTemporaryHome: Bool
    ) -> Double {
        guard hasTemporaryHome else {
            return closestHomeDistance(
                latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                atTime: pingTime, homes: homes)
        }
        if stay.trip != nil { return stay.distanceFromHomeKm }
        return closestHomeDistance(
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
            atTime: stay.startTime, homes: homes)
    }

    /// Sendable value snapshot of a `Home`'s geometry + active window, so
    /// the canonical distance math below can be shared across actors
    /// (`TripClassifier.applyHomeChange` recomputes stale distances with
    /// the SAME rule that stamped them) and unit-tested without touching
    /// MainActor-isolated `@Model` rows.
    nonisolated struct HomeWindow: Sendable {
        let latitude: Double
        let longitude: Double
        let startedAt: Date
        let endedAt: Date?
        /// A temporary home measures distance inside its own dates only.
        var isTemporary: Bool = false
    }

    /// Compute the distance in km to the nearest home that was active at the given time.
    /// Falls back to any active home if no home was active at that specific time.
    /// Returns `Double.greatestFiniteMagnitude` if there are no homes at all.
    private func closestHomeDistance(
        latitude: Double,
        longitude: Double,
        atTime time: Date,
        homes: [HomeWindow]
    ) -> Double {
        Self.closestHomeDistanceKm(
            latitude: latitude, longitude: longitude, atTime: time, homes: homes)
    }

    /// The canonical `distanceFromHomeKm` rule, pure over value snapshots:
    /// min distance to the homes active AT THE GIVEN TIME (home-at-the-time
    /// semantics), falling back to the current homes for stays that predate
    /// every Home record. `Double.greatestFiniteMagnitude` when no homes
    /// exist at all — consumers treat that as "no measurement".
    nonisolated static func closestHomeDistanceKm(
        latitude: Double,
        longitude: Double,
        atTime time: Date,
        homes: [HomeWindow]
    ) -> Double {
        guard !homes.isEmpty else { return Double.greatestFiniteMagnitude }

        // Find homes that were active at the given time
        let activeAtTime = homes.filter { home in
            if home.startedAt > time { return false }
            if let endedAt = home.endedAt, time > endedAt { return false }
            return true
        }

        // Fall back to current homes if none were active at that time
        // (e.g., user added home after the stay occurred). Real homes only:
        // a temporary home never measures a stay outside its dates.
        // A time before every real home's start is theirs too (the real-only
        // prehistory pass of `TripClassifier.matchesHome`): a backdated temporary
        // home, the only window active then, measures beside the current homes, not alone.
        let realHomes = homes.filter { !$0.isTemporary }
        let currentHomes = realHomes.filter { $0.endedAt == nil }
        let prehistory = !currentHomes.isEmpty && realHomes.allSatisfy { time < $0.startedAt }
        let homesToUse = activeAtTime.isEmpty
            ? currentHomes : (prehistory ? activeAtTime + currentHomes : activeAtTime)

        guard !homesToUse.isEmpty else { return Double.greatestFiniteMagnitude }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        var minDistance = Double.greatestFiniteMagnitude

        for home in homesToUse {
            let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let distKm = location.distance(from: homeLocation) / 1000.0
            minDistance = min(minDistance, distKm)
        }

        return minDistance
    }

    // MARK: - Statistics

    func totalStayCount() -> Int {
        let descriptor = FetchDescriptor<Stay>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

nonisolated extension StayClusterer.HomeWindow {
    /// The distance window of one classification anchor, carrying its kind.
    init(_ anchor: HomeAnchor) {
        self.init(latitude: anchor.latitude, longitude: anchor.longitude,
                  startedAt: anchor.startedAt, endedAt: anchor.endedAt,
                  isTemporary: anchor.isTemporary)
    }
}
