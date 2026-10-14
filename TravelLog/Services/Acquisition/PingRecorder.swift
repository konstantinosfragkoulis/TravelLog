//
//  PingRecorder.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import WidgetKit
import os.log

/// A photo batch could not read the persisted inputs needed for safe replay.
/// Keep this distinct from save failures so recovery UI describes the failure.
nonisolated enum PhotoImportBatchReadError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// Records location pings into SwiftData from any execution context.
/// A Significant Location Change background relaunch grants ~10 seconds;
/// this actor must complete all work within that window.

/// Sendable input value for `PingRecorder.processLocations(_:)` — one live
/// observation carrying the acquisition channel that produced it, so a ping
/// can never silently inherit `.liveSLC` from a defaulted parameter.
nonisolated struct LiveLocationCandidate: Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double
    let verticalAccuracy: Double
    let source: DataSource

    init(_ location: CLLocation, source: DataSource) {
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.altitude = location.altitude
        self.verticalAccuracy = location.verticalAccuracy
        self.source = source
    }
}

/// Sendable input row for `PingRecorder.recordImportedPings(_:)` — one
/// surviving photo-library asset's (timestamp, coordinate, accuracy, altitude).
nonisolated struct ImportedPingCandidate: Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    /// EXIF altitude in metres above sea level; accuracy is metres (1σ), negative means invalid.
    /// Nil means absent. Valid values populate new pings or backfill invalid altitude on re-import.
    var altitude: Double? = nil
    var verticalAccuracy: Double? = nil
}

/// Value-generic test seam for failed-live-save buffer ordering and capacity.
nonisolated enum PingRetryBufferPolicy {
    static let capacity = 200

    static func nextInput<Element>(
        buffered: [Element], incoming: [Element]
    ) -> [Element] {
        buffered + incoming
    }

    static func retainedAfterFailure<Element>(
        _ attempted: [Element], capacity: Int = PingRetryBufferPolicy.capacity
    ) -> [Element] {
        guard capacity > 0 else { return [] }
        return Array(attempted.suffix(capacity))
    }

    /// Drops values stamped before the committed live acceptance floor. A
    /// value exactly at the floor is kept; no floor admits everything.
    static func admitted<Element>(
        _ values: [Element], floor: Date?, timestamp: (Element) -> Date
    ) -> [Element] {
        guard let floor else { return values }
        return values.filter { timestamp($0) >= floor }
    }
}

@ModelActor
actor PingRecorder {
    let logger = Logger(subsystem: "com.travellog.app", category: "PingRecorder")

    /// Live hex-reentry cursor: count a visit only when the hex changes.
    /// Keep it separate from the import cursor so interleaved streams cannot corrupt reentry counts.
    private var lastRecordedH3Index: String?

    /// Import-only reentry cursor: consecutive photos in one hex count one visit;
    /// an interleaved live fix must not create an imported reentry.
    var lastImportedH3Index: String?
    /// Roll a failed batch's in-memory re-entry cursor back to the last
    /// successfully committed value so retrying cannot inherit unsaved state.
    var lastDurableImportedH3Index: String?

    /// Live candidates whose last batch did not save. Deliberately
    /// actor-local and unpersisted; bounded drop-oldest retention prevents a
    /// prolonged storage outage from growing memory without limit. A failed
    /// batch rolls its inserts back, so this buffer is the only owner of
    /// failed live input.
    private var failedLiveCandidates: [LiveLocationCandidate] = []

    /// Device-local committed-deletion authority for live acquisition.
    /// `DataWipe` advances it only after the store wipe commits, so buffered
    /// or late-delivered fixes and failed-save retries stamped before the
    /// wipe cannot restore wiped history. Separate from the Visit floor,
    /// which monitoring start also seeds.
    nonisolated static let liveAcceptanceFloorKey = "liveAcceptanceFloor"

    /// Live pings inserted by the current batch, published to the photo
    /// session dedup index only after the batch saves.
    nonisolated private struct PendingLiveIndexEntry {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let id: UUID
        let hasValidAltitude: Bool
    }
    private var pendingLiveIndexEntries: [PendingLiveIndexEntry] = []

    /// Parent Trips touched by import absorption; summary recomputation propagates `.merged`
    /// even during background import, when TripClassifier is deliberately skipped.
    var affectedTripIDs: Set<UUID> = []
    typealias ParentTitleSnapshots =
        [ObjectIdentifier: TripTitleStore.ParentSemanticSnapshot]
    var affectedTripTitleSnapshots: ParentTitleSnapshots = [:]

    #if DEBUG
    var geocodeSaveFailuresForTesting = 0

    func setFailNextGeocodeSaveForTesting(_ shouldFail: Bool) {
        geocodeSaveFailuresForTesting = shouldFail ? 1 : 0
    }

    private var failNextLiveSaveForTesting = false

    func setFailNextLiveSaveForTesting(_ shouldFail: Bool) {
        failNextLiveSaveForTesting = shouldFail
    }

    /// One-shot hook awaited after the first candidate of the next live batch
    /// is processed, while its insert is still unsaved.
    private var afterFirstLiveCandidateForTesting: (@Sendable () async -> Void)?

    func setAfterFirstLiveCandidateForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterFirstLiveCandidateForTesting = hook
    }

    /// Live fixes that reached the travel-notification check.
    private(set) var travelNotificationCheckCountForTesting = 0
    /// Fails the next `count` geocode saves.
    func setGeocodeSaveFailuresForTesting(_ count: Int) {
        geocodeSaveFailuresForTesting = count
    }

    /// Required geocode reads a test can make throw until it clears them.
    nonisolated enum GeocodeReadFault: Hashable, Sendable {
        case ungeocodedPingIDs, propagation, stayCentroids, hexDonor
    }
    private var geocodeReadFaultsForTesting: Set<GeocodeReadFault> = []

    func setGeocodeReadFaultForTesting(_ fault: GeocodeReadFault, enabled: Bool) {
        if enabled {
            geocodeReadFaultsForTesting.insert(fault)
        } else {
            geocodeReadFaultsForTesting.remove(fault)
        }
    }

    func injectGeocodeReadFault(_ fault: GeocodeReadFault) throws {
        if geocodeReadFaultsForTesting.contains(fault) { throw CocoaError(.fileReadUnknown) }
    }

    func hasPendingGeocodeChangesForTesting() -> Bool { modelContext.hasChanges }
    #endif

    private func saveLiveChanges() throws {
        #if DEBUG
        if failNextLiveSaveForTesting {
            failNextLiveSaveForTesting = false
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
        try modelContext.save()
    }

    /// Per-process skip set leaves failures retryable next launch; Settings drains all rows.
    /// Key by PHYSICAL row identity: CloudKit cannot enforce UUID uniqueness, and counting
    /// shared UUIDs once would prevent the skip-based fetch window from advancing.
    var opportunisticGeocodeSkipIDs: Set<PersistentIdentifier> = []

    /// `.trip` when a geocode drain save since the last take changed a trip (a
    /// cleared title, a recomputed summary). A failed save leaves it set: fail open.
    var geocodeTripChange: StoreChange = []

    /// Process live candidates sequentially to respect geocoding rate limits.
    /// Returns the tracked types this batch's saves wrote, for the caller's gate unit to publish.
    /// Candidates stamped before the committed live acceptance floor are
    /// dropped permanently, retries included. The batch saves or rolls back
    /// as one unit: a failed save discards its inserts and restores the live
    /// reentry cursor, leaving the bounded retry buffer as the only owner.
    @discardableResult
    func processLocations(
        _ candidates: [LiveLocationCandidate],
        defaults: UserDefaults = .standard
    ) async -> StoreChange {
        let acceptanceFloor = defaults.object(
            forKey: Self.liveAcceptanceFloorKey) as? Date
        let retried = PingRetryBufferPolicy.admitted(
            failedLiveCandidates, floor: acceptanceFloor, timestamp: { $0.timestamp })
        let incoming = PingRetryBufferPolicy.admitted(
            candidates, floor: acceptanceFloor, timestamp: { $0.timestamp })
        let rejectedCount = failedLiveCandidates.count + candidates.count
            - retried.count - incoming.count
        failedLiveCandidates.removeAll(keepingCapacity: true)
        if rejectedCount > 0 {
            logger.notice("Rejected \(rejectedCount) live fix(es) stamped before the acceptance floor.")
        }
        let candidatesToProcess = PingRetryBufferPolicy.nextInput(
            buffered: retried,
            incoming: incoming
        )
        // A batch made only of rejected fixes writes nothing.
        guard !candidatesToProcess.isEmpty else { return [] }
        let attemptedBatchContainsSLC = candidatesToProcess.contains {
            $0.source == .liveSLC
        }
        let durableLiveCursor = lastRecordedH3Index
        insertedNewHexInBatch = false
        pendingLiveIndexEntries.removeAll(keepingCapacity: true)
        for (offset, candidate) in candidatesToProcess.enumerated() {
            // Retried fixes already ran their notification check when first attempted.
            await processOneLocation(candidate, isRetry: offset < retried.count)
            #if DEBUG
            if let hook = afterFirstLiveCandidateForTesting {
                afterFirstLiveCandidateForTesting = nil
                await hook()
            }
            #endif
        }

        var changes = StoreChange.pending(in: modelContext)
        do {
            try saveLiveChanges()
            publishPendingLiveIndexEntries()
            logger.info("Saved \(candidatesToProcess.count) ping(s) to database.")
            // Reload widgets only for a NEW hex: hex count is the only widget-visible ping change;
            // stay/trip-derived counts have separate gated reload sites.
            // Background SLC batches share a 15-minute slot so a drive cannot burn the budget;
            // a suppressed reload is owed to the next batch.
            let decision = AppDelegate.hexWidgetReloadDecision(
                insertedNewHex: insertedNewHexInBatch,
                pending: AppDelegate.hexWidgetReloadPending.withLock { $0 },
                batchIsSLC: attemptedBatchContainsSLC,
                claimSlot: { AppDelegate.claimHexWidgetReloadSlot() })
            AppDelegate.hexWidgetReloadPending.withLock { $0 = decision.pending }
            if decision.reload {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // Fail open to the set this unit always declared.
            changes.formUnion([.locationPing, .hexVisit, .stay])
            // Save or roll back: no unsaved live residue may be adopted by a
            // later save, and the cursor and dedup index must describe only
            // committed rows.
            modelContext.rollback()
            lastRecordedH3Index = durableLiveCursor
            pendingLiveIndexEntries.removeAll(keepingCapacity: true)
            // A session index built while this batch was suspended read its
            // unsaved inserts; drop it like rollbackImportBatch so the next
            // photo commit rebuilds from committed rows.
            importDedupIndex = nil
            failedLiveCandidates = PingRetryBufferPolicy.retainedAfterFailure(
                candidatesToProcess)
            logger.error("Failed to save pings: \(error.localizedDescription)")
        }

        // Retry strictly ONE old ping per SLC wake to keep work within the ~10-second budget.
        if attemptedBatchContainsSLC {
            changes.formUnion(await tryOneOpportunisticGeocoding())
        }
        return changes
    }

    /// Keep the import-session dedup index coherent with committed live pings
    /// (nil outside import sessions, so no cost).
    private func publishPendingLiveIndexEntries() {
        defer { pendingLiveIndexEntries.removeAll(keepingCapacity: true) }
        guard importDedupIndex != nil else { return }
        for entry in pendingLiveIndexEntries {
            importDedupIndex?.insert(timestamp: entry.timestamp, latitude: entry.latitude,
                                     longitude: entry.longitude, id: entry.id,
                                     hasValidAltitude: entry.hasValidAltitude)
        }
    }

    private func processOneLocation(_ candidate: LiveLocationCandidate, isRetry: Bool) async {
        let coordinate = CLLocationCoordinate2D(
            latitude: candidate.latitude,
            longitude: candidate.longitude
        )

        // Deduplicate SLC redelivery on background relaunch.
        if isDuplicatePing(
            timestamp: candidate.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) {
            logger.debug("Skipping duplicate ping at \(candidate.timestamp)")
            return
        }

        guard let h3Index = H3Service.cellIndex(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            logger.warning("H3 indexing failed for (\(coordinate.latitude, privacy: .private), \(coordinate.longitude, privacy: .private))")
            return
        }

        // Persist raw altitude and accuracy; negative verticalAccuracy means invalid, not a lost fix.
        // Consumers must check validity; the upstream airborne filter still rejects clear airborne GPS fixes.
        let ping = LocationPing(
            timestamp: candidate.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: candidate.horizontalAccuracy,
            h3IndexRes6: h3Index,
            altitude: candidate.altitude,
            verticalAccuracy: candidate.verticalAccuracy,
            source: candidate.source
        )

        // Resolve offline without network requests or rate limits.
        let result = await GeocodeResolver.shared.resolve(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        ping.applyResolverResult(result)
        if result == nil {
            logger.info("Resolver returned no result for (\(coordinate.latitude, privacy: .private), \(coordinate.longitude, privacy: .private)) — likely mid-ocean or polar coord.")
        }

        modelContext.insert(ping)

        // A live ping that lands mid-import joins the session dedup index
        // only once its batch saves; a rolled-back ping must not dedup photos.
        if importDedupIndex != nil {
            pendingLiveIndexEntries.append(PendingLiveIndexEntry(
                timestamp: ping.timestamp, latitude: ping.latitude, longitude: ping.longitude,
                id: ping.id, hasValidAltitude: Self.hasValidAltitude(ping.altitude, ping.verticalAccuracy)))
        }

        upsertHexVisit(
            h3Index: h3Index,
            coordinate: coordinate,
            timestamp: candidate.timestamp,
            locality: ping.locality,
            country: ping.country,
            isoCountryCode: ping.isoCountryCode
        )

        logger.debug("Recorded ping: \(ping.locality ?? "?", privacy: .private), \(ping.country ?? "?", privacy: .private) [hex: \(h3Index, privacy: .private)]")

        guard !isRetry else { return }
        #if DEBUG
        travelNotificationCheckCountForTesting += 1
        #endif
        await checkTravelNotifications(
            isoCountryCode: ping.isoCountryCode,
            countryName: ping.country,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Live dedup uses 60 seconds / 100 metres for SLC redelivery; photo import widens this
    /// to 90 seconds / 200 metres for variable photo GPS accuracy and shutter timestamp drift.
    /// Callers share the implementation but supply source-specific thresholds.
    private func isDuplicatePing(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        timeWindowSeconds: TimeInterval = 60,
        spatialThresholdMeters: Double = 100
    ) -> Bool {
        let windowStart = timestamp.addingTimeInterval(-timeWindowSeconds)
        let windowEnd = timestamp.addingTimeInterval(timeWindowSeconds)

        let predicate = #Predicate<LocationPing> {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }
        // Check ALL pings in the bounded time window: an unordered fetch limit can exclude
        // the actual near-duplicate during dense imports or SLC redelivery.
        let descriptor = FetchDescriptor<LocationPing>(predicate: predicate)

        let nearby: [LocationPing]
        do {
            nearby = try modelContext.fetch(descriptor)
        } catch {
            // On dedup fetch failure, admit and log: a repairable duplicate is less harmful
            // than dropping immutable source data, but failure must not look like a clean verdict.
            logger.error("Ping dedup window fetch failed (\(error.localizedDescription)); admitting ping without dedup.")
            return false
        }
        guard !nearby.isEmpty else { return false }

        let newLocation = CLLocation(latitude: latitude, longitude: longitude)
        return nearby.contains { ping in
            let existingLocation = CLLocation(latitude: ping.latitude, longitude: ping.longitude)
            return newLocation.distance(from: existingLocation) < spatialThresholdMeters
        }
    }

    /// True when the current `processLocations` batch inserted at least one
    /// brand-new HexVisit row — the signal that gates the widget reload
    /// (hex count is the only widget-visible value a ping save can change).
    private var insertedNewHexInBatch = false

    /// Count a new visit only when the hex differs from the live reentry cursor.
    private func upsertHexVisit(
        h3Index: String,
        coordinate: CLLocationCoordinate2D,
        timestamp: Date,
        locality: String?,
        country: String?,
        isoCountryCode: String?
    ) {
        let isNewHex = (h3Index != lastRecordedH3Index)
        lastRecordedH3Index = h3Index

        let predicate = #Predicate<HexVisit> { $0.h3Index == h3Index }
        let descriptor = FetchDescriptor<HexVisit>(predicate: predicate)

        do {
            let existing = try modelContext.fetch(descriptor)

            if let hexVisit = existing.first {
                if isNewHex {
                    hexVisit.recordReentry(at: timestamp)
                }
                if hexVisit.locality == nil, let locality {
                    hexVisit.locality = locality
                }
                if hexVisit.country == nil, let country {
                    hexVisit.country = country
                    hexVisit.isoCountryCode = isoCountryCode
                }
            } else {
                let centerCoord = H3Service.centerCoordinate(for: h3Index)
                let hexVisit = HexVisit(
                    h3Index: h3Index,
                    firstVisited: timestamp,
                    centerLatitude: centerCoord?.latitude ?? coordinate.latitude,
                    centerLongitude: centerCoord?.longitude ?? coordinate.longitude
                )
                hexVisit.locality = locality
                hexVisit.country = country
                hexVisit.isoCountryCode = isoCountryCode
                modelContext.insert(hexVisit)
                insertedNewHexInBatch = true
            }
        } catch {
            logger.error("Failed to upsert HexVisit for \(h3Index): \(error.localizedDescription)")
        }
    }

    // MARK: - Photo Import Path

    /// Session dedup index is updated on EVERY local insert, including live SLC during import.
    /// CloudKit inserts bypass it; PhotoImportPingDeduplicator converges cross-device duplicates.
    /// Deletions between batches can leave stale entries that skip a photo whose twin was deleted;
    /// each fresh session rebuilds the index from the store.
    var importDedupIndex: ImportDedupIndex?

    #if DEBUG
    var afterPhotoImportSaveForTesting: (@Sendable () throws -> Void)?

    func setAfterPhotoImportSaveForTesting(_ hook: @escaping @Sendable () throws -> Void) {
        afterPhotoImportSaveForTesting = hook
    }

    var importHexFetchCallCountForTesting = 0
    var failingImportHexFetchCallForTesting: Int?
    var failNextImportDedupFetchForTesting = false
    var failNextImportHostStayFetchForTesting = false
    var failNextImportBatchSaveForTesting = false
    var importBatchSaveCallCountForTesting = 0
    var failingImportBatchSaveCallForTesting: Int?

    func failImportHexFetchCallForTesting(_ call: Int) {
        importHexFetchCallCountForTesting = 0
        failingImportHexFetchCallForTesting = call
    }

    func setFailNextImportDedupFetchForTesting(_ shouldFail: Bool) {
        failNextImportDedupFetchForTesting = shouldFail
    }

    func setFailNextImportHostStayFetchForTesting(_ shouldFail: Bool) {
        failNextImportHostStayFetchForTesting = shouldFail
    }

    func setFailNextImportBatchSaveForTesting(_ shouldFail: Bool) {
        failNextImportBatchSaveForTesting = shouldFail
    }

    func failImportBatchSaveCallForTesting(_ call: Int) {
        importBatchSaveCallCountForTesting = 0
        failingImportBatchSaveCallForTesting = call
    }
    #endif

    // MARK: - Travel Notifications

    /// Check if the current ping should trigger a country welcome or welcome home notification.
    /// A disabled alert still ends its pending trip state at home (a recorded
    /// Country Welcome claim, a recorded Welcome Home departure), so turning
    /// it back on later neither suppresses the next trip nor announces a
    /// stale one. With the alert off and nothing pending, no work is done.
    private func checkTravelNotifications(
        isoCountryCode: String?,
        countryName: String?,
        latitude: Double,
        longitude: Double
    ) async {
        let defaults = NotificationService.stateDefaults
        let countryWelcomeEnabled = defaults.bool(
            forKey: NotificationService.countryWelcomeEnabledKey)
        let welcomeHomeEnabled = defaults.bool(
            forKey: NotificationService.welcomeHomeEnabledKey)
        // Only a ping with a country can reset the country trip.
        let needsCountryReset = !countryWelcomeEnabled && isoCountryCode != nil
            && NotificationService.hasCountryWelcomeDedupState(defaults: defaults)
        let needsHomeReset = !welcomeHomeEnabled
            && NotificationService.hasWelcomeHomeDepartureState(defaults: defaults)
        let checksCountry = countryWelcomeEnabled || needsCountryReset
        let checksHome = welcomeHomeEnabled || needsHomeReset
        guard checksCountry || checksHome else { return }

        let predicate = #Predicate<Home> { $0.endedAt == nil }
        guard let homes = try? modelContext.fetch(FetchDescriptor<Home>(predicate: predicate)),
              !homes.isEmpty else {
            return
        }

        if checksCountry {
            // A temporary home's country is quiet while its dates cover now.
            // Best effort on purpose: a failed read keeps the real-home set,
            // because the alternative is no notification check for this ping.
            let temporaryHomes = (try? HomeAnchors.temporaryHomes(in: modelContext)) ?? []
            // Resolve home countries canonically, including stay-derived fallback for ungeocoded homes,
            // so missing home ISO cannot trigger a false country-arrival notification.
            var homeStayGeo: [(iso: String?, latitude: Double, longitude: Double)] = []
            if homes.contains(where: { $0.isoCountryCode == nil }) {
                let homeCategory = StayCategory.home.rawValue
                var stayDescriptor = FetchDescriptor<Stay>(
                    predicate: #Predicate<Stay> { $0.categoryRaw == homeCategory },
                    sortBy: [SortDescriptor(\.startTime, order: .reverse)]
                )
                stayDescriptor.fetchLimit = 1000
                // A temporary home's stays never resolve the real Home's
                // country, the rule `StatsAggregator.compute` applies: only a
                // stay its writer recorded as the real Home's does, never the
                // nearest centre.
                let temporaryHomeIDs = Set(temporaryHomes.map(\.id))
                let homeStays = ((try? modelContext.fetch(stayDescriptor)) ?? []).filter { stay in
                    HomeAnchors.recordedOwner(
                        temporaryHomeID: stay.temporaryHomeID,
                        knownTemporaryHomeIDs: temporaryHomeIDs) == .realHome
                }
                homeStayGeo = homeStays.map { ($0.isoCountryCode, $0.centroidLatitude, $0.centroidLongitude) }
            }
            let homeCountryCodes = StatsAggregator.resolveHomeCountryCodes(
                homes: homes.map {
                    StatsAggregator.ActiveHomeGeo(
                        isoCountryCode: $0.isoCountryCode,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        radiusKm: $0.radiusKm
                    )
                },
                homeStays: homeStayGeo
            )
            await NotificationService.checkCountryWelcome(
                isoCountryCode: isoCountryCode,
                countryName: countryName,
                homeCountryCodes: Self.countryWelcomeQuietCodes(
                    homeCountryCodes: homeCountryCodes,
                    temporaryHomes: temporaryHomes,
                    now: .now
                )
            )
        }

        if checksHome {
            // Welcome Home uses the LIVE home SEED: measured city, or declared circle if unmeasured.
            // Full classification membership includes learned work spots, and an oversized declared
            // circle can include an airport; neither should consume the true homecoming.
            let isWithinHome = await AppDelegate.tripClassifier
                .currentHomeSeedCovers(latitude: latitude, longitude: longitude)
            await NotificationService.checkWelcomeHome(isWithinHomeRadius: isWithinHome)
        }
    }

    /// The countries Country Welcome stays quiet in: the real-home codes plus
    /// the country of every temporary home whose dates cover `now`. A ping in
    /// any of them also ends the trip's notified set, as a home country does.
    /// An ended or not yet started temporary home adds nothing. With no
    /// real-home code the set stays empty and the check stays silent, so a
    /// temporary home cannot make the user's own unresolved country an arrival.
    nonisolated static func countryWelcomeQuietCodes(
        homeCountryCodes: Set<String>,
        temporaryHomes: [HomeAnchor],
        now: Date
    ) -> Set<String> {
        guard !homeCountryCodes.isEmpty else { return homeCountryCodes }
        return homeCountryCodes.union(
            temporaryHomes.filter { $0.covers(now) }.compactMap(\.isoCountryCode))
    }

    #if DEBUG
    var hexResolverForTesting: (@Sendable (Double, Double) async -> GeocodeResolver.Result?)?
    var afterHexPageForTesting: (@Sendable () async -> Void)?
    /// Per unit: ping rows (`rows`) and associated Stay rows (`stayRows`) fetched.
    var hexPageStatsForTesting: (rows: [Int], associatedUpdates: Int, stayRows: [Int]) = ([], 0, [])
    /// Runs after every stay-centroid and hex-heal drain unit, outside the gate.
    var afterDrainUnitForTesting: (@Sendable () async -> Void)?
    /// Rows each hex-heal unit changed, in unit order.
    var hexHealUnitRowsForTesting: [Int] = []

    func setHexResolverForTesting(
        _ resolver: @escaping @Sendable (Double, Double) async -> GeocodeResolver.Result?
    ) {
        hexResolverForTesting = resolver
    }

    func setAfterHexPageForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterHexPageForTesting = hook
    }

    func setAfterDrainUnitForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterDrainUnitForTesting = hook
    }
    #endif

    var lastDrainedBacklogToken: GeocodeBacklogToken?

    /// Geocode locality-nil stays at their centroids; return only actual field gains as drain progress.
    /// Exclude settled no-result stays for this launch so they cannot occupy the newest-first window
    /// and strand older resolvable stays. Exclusions are keyed by PHYSICAL row and remember the
    /// centroid they were tried at: a moved centroid makes the row eligible again. Recent stays
    /// remain retryable because centroids can drift; resolver data changes on app update, so
    /// exclusions must stay per-process.
    var unresolvableStayIDs: [PersistentIdentifier: StayCentroid] = [:]
    /// Restore the live reentry cursor from the most recent raw LIVE observation only;
    /// imports have their own cursor and historical photos cannot represent current device location.
    /// A successful empty fetch (a wiped store) clears the cursor; a failed fetch keeps it.
    func restoreLastH3Index() {
        let liveSource = DataSource.liveSLC.rawValue
        let foregroundStreamSource = DataSource.foregroundStream.rawValue
        var descriptor = FetchDescriptor<LocationPing>(
            predicate: #Predicate {
                $0.sourceRaw == liveSource
                    || $0.sourceRaw == foregroundStreamSource
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            if let lastPing = try modelContext.fetch(descriptor).first {
                lastRecordedH3Index = lastPing.h3IndexRes6
                logger.debug("Restored last H3 index: \(lastPing.h3IndexRes6)")
            } else {
                lastRecordedH3Index = nil
            }
        } catch {
            logger.warning("Could not restore last H3 index: \(error.localizedDescription)")
        }
    }

    // MARK: - Statistics (cont.)

    func totalPingCount() -> Int {
        let descriptor = FetchDescriptor<LocationPing>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// Cells, not rows: `HexVisitDeduplicator` keeps ambiguous same-cell groups.
    func totalHexCount() -> Int {
        var descriptor = FetchDescriptor<HexVisit>()
        descriptor.propertiesToFetch = [\.h3Index]
        guard let rows = try? modelContext.fetch(descriptor) else { return 0 }
        return Set(rows.map(\.h3Index)).count
    }

}
