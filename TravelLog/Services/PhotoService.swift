import Photos
import UIKit
import CoreLocation
import SwiftData
import os.log

/// `@unchecked Sendable`: the only reference-type field is `[PHAsset]`, and
/// `PHAsset` (a `PHObject`) is an immutable, thread-safe snapshot of the
/// photo-library state — Apple documents PhotoKit objects as safe to read
/// from any thread. This lets `photosForTrip` build its groups off the main
/// actor (in a `Task.detached`) and return them across the actor hop.
struct StayPhotos: Identifiable, @unchecked Sendable {
    let stayID: UUID
    let stayLocality: String?
    let stayStartTime: Date
    let assets: [PHAsset]
    var id: UUID { stayID }
}

/// What `photosForTrip` hands a caller. `.loaded` is publishable, including a
/// legitimately empty trip, missing photo access, or an uncached best-effort
/// snapshot after bounded invalidation retries. `.unavailable` means the
/// hidden list could not be read or the caller's row died while suspended:
/// keep the previous state and let the next trigger retry.
enum TripPhotosOutcome: Sendable {
    case loaded([StayPhotos])
    case unavailable

    var groups: [StayPhotos]? {
        if case .loaded(let groups) = self { return groups }
        return nil
    }
}

@MainActor
@Observable
final class PhotoService: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoService()

    private(set) var authorizationStatus: PHAuthorizationStatus

    /// Identity-only library-change signal; views with cached photo snapshots must observe it and refetch.
    var changeToken: UUID = UUID()

    /// One cached `photosForTrip` result plus the stay-shape token it was
    /// computed against — a self-invalidating pair; see `stayShapeToken(for:)`.
    private struct CachedTripPhotos {
        let stayShapeToken: Int
        let groups: [StayPhotos]
    }

    /// Coalesce only identical trip, stay-shape, and invalidation-epoch inputs; generations must never share results.
    private struct PhotoComputeKey: Hashable {
        let tripID: UUID
        let stayShapeToken: Int
        let globalEpoch: Int
        let tripEpoch: Int
    }

    /// In-flight computes by key. MainActor-confined; each task removes its
    /// own entry on completion.
    private var inFlightPhotoComputes: [PhotoComputeKey: Task<TripPhotosOutcome, Never>] = [:]

    #if DEBUG
    /// Test seams override authorization and detached computation to observe single-flight behavior.
    var authorizationOverrideForTesting: PHAuthorizationStatus?
    var computeOverrideForTesting: (@Sendable () async -> [StayPhotos])?
    var countOverrideForTesting: (@Sendable () async -> Int)?
    var singleFlightAdmissionForTesting: (@MainActor (Bool) -> Void)?
    var mutationContainerForTesting: ModelContainer?
    var mutationGateForTesting: PipelineGate?
    var failAnnotationSaveForTesting = false
    /// Makes every HiddenPhoto/PinnedPhoto read below throw, as a storage failure would.
    var failAnnotationReadForTesting = false
    /// Stands in for PhotoKit resolution and gallery admission of hidden identifiers; returns how many this trip offers.
    var hiddenResolutionOverrideForTesting: (@Sendable (Set<String>) -> Int)?
    /// Receives the hidden identifiers a gallery compute was admitted with.
    var computeHiddenInputForTesting: (@MainActor (Set<String>) -> Void)?

    func seedCloudMappingsForTesting(_ mappings: [String: String]) {
        cloudToLocalCache = mappings
    }

    var cloudMappingsForTesting: [String: String] { cloudToLocalCache }
    #endif

    /// Set when a cloud-mapping refresh could not read the annotation tables;
    /// the foreground retry timer then refreshes as well as backfilling.
    @ObservationIgnored var cloudRefreshPending = false

    /// Observe photoCacheGeneration instead of the dictionary so prewarm can batch view invalidations.
    @ObservationIgnored private var tripPhotoCache: [UUID: CachedTripPhotos] = [:]

    /// Evict heavy entries in write order; uncapped counts must survive for sorting and prewarm idempotence.
    static let tripPhotoCacheCap = 50

    /// Write order of `tripPhotoCache` keys — first element is the next
    /// eviction victim. Maintained solely by `storeCachedTripPhotos` and
    /// the invalidation paths.
    @ObservationIgnored private var tripPhotoCacheOrder: [UUID] = []

    /// Photo count + the shape token it was computed against, mirrored on
    /// every heavy-cache write. Deliberately uncapped (an `Int` per trip):
    /// `cachedPhotoCount` (the TripSorter contract) and the
    /// `prewarmPhotoCounts` skip-check read from here, so evicting a heavy
    /// entry neither degrades the photo sort nor makes the prewarm re-fetch
    /// PhotoKit for evicted trips on every pass. A global invalidation keeps
    /// the count readable; `epoch` marks it stale so prewarm recounts it.
    private struct CachedPhotoCount {
        let stayShapeToken: Int
        let count: Int
        let epoch: Int
    }
    @ObservationIgnored private var tripPhotoCounts: [UUID: CachedPhotoCount] = [:]

    /// Single write path for `tripPhotoCache`: stores the entry, mirrors
    /// its count, and enforces `tripPhotoCacheCap` by evicting the
    /// least-recently-written keys. Eviction is NOT an invalidation — no
    /// epoch is bumped; a later `photosForTrip` simply misses the cache
    /// and recomputes. Internal as the cap test seam.
    func storeCachedTripPhotos(tripID: UUID, stayShapeToken: Int, groups: [StayPhotos]) {
        tripPhotoCache[tripID] = CachedTripPhotos(stayShapeToken: stayShapeToken, groups: groups)
        tripPhotoCounts[tripID] = CachedPhotoCount(
            stayShapeToken: stayShapeToken,
            count: groups.reduce(0) { $0 + $1.assets.count },
            epoch: cacheInvalidationEpoch
        )
        tripPhotoCacheOrder.removeAll { $0 == tripID }
        tripPhotoCacheOrder.append(tripID)
        while tripPhotoCacheOrder.count > Self.tripPhotoCacheCap {
            let evicted = tripPhotoCacheOrder.removeFirst()
            tripPhotoCache.removeValue(forKey: evicted)
            // The count survives deliberately — see `tripPhotoCounts`.
        }
    }

    /// Whether a HEAVY cache entry (the PHAsset groups) is currently
    /// retained for this trip. Test seam for the eviction cap.
    func cachedGroupsExist(for tripID: UUID) -> Bool {
        tripPhotoCache[tripID] != nil
    }

    /// Snapshot before actor hops, sorting exactly as grouping does: equal-order
    /// stays keep their relationship order because assignment ties use the first.
    static func photoSnapshot(for trip: Trip) -> TripPhotoSnapshot {
        let stays = (trip.stays ?? []).compactMap { stay -> StaySnapshot? in
            // Check isDeleted before other model properties, which trap after invalidation.
            guard !stay.isDeleted else { return nil }
            return StaySnapshot(
                id: stay.id, latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                startTime: stay.startTime, endTime: stay.endTime,
                orderInTrip: stay.orderInTrip ?? 0, durationMinutes: stay.durationMinutes,
                locality: stay.locality, categoryRaw: stay.categoryRaw
            )
        }.sorted { $0.orderInTrip < $1.orderInTrip }
        return TripPhotoSnapshot(startDate: trip.startDate, endDate: trip.endDate, stays: stays)
    }

    static func stayShapeToken(for trip: Trip) -> Int {
        photoSnapshot(for: trip).shapeToken
    }

    /// Coarse invalidation signal for `tripPhotoCache`-derived view state
    /// (`cachedPhotoCount` in the trips-list sort/filter path). Bumped on
    /// every individual cache mutation outside a prewarm pass; the prewarm
    /// batches bumps (one per 25 trips + one at completion).
    private(set) var photoCacheGeneration = 0

    /// True while `prewarmPhotoCounts` is filling the cache — individual
    /// bumps are suppressed and the loop publishes batched ones itself.
    @ObservationIgnored private var suppressGenerationBumps = false

    /// New prewarm runs supersede old ones; only the current run may clear generation-bump suppression.
    @ObservationIgnored private var prewarmGeneration = 0

    private func bumpPhotoCacheGeneration() {
        guard !suppressGenerationBumps else { return }
        photoCacheGeneration &+= 1
    }

    /// `PHCloudIdentifier.archivalStringValue` → this device's `PHAsset.localIdentifier`.
    /// Populated by `refreshCloudIdentifierCache()` (which calls PhotoKit
    /// off-main and then hops back to the main actor to write here); read on
    /// the main thread by `hiddenIdentifiers(for:)` / `pinnedIdentifiers(for:)`
    /// to translate a CloudKit-synced cloud ID into the local ID we need to
    /// match against `PHAsset`s on this device.
    var cloudToLocalCache: [String: String] = [:]

    /// Lazy creation prevents a PhotoKit connection before permission; loadImage requires a post-grant PHAsset.
    /// ObservationIgnored is required because Observable cannot track lazy storage.
    @ObservationIgnored
    private lazy var imageManager = PHCachingImageManager()
    let logger = Logger(subsystem: "com.travellog.app", category: "PhotoService")

    /// MainActor-confined debounce tasks coalesce bursts by cancellation and rescheduling.

    /// Coalesces rapid-fire `photoLibraryDidChange(_:)` callbacks (iCloud
    /// Photos sync emits these in bursts) into a single
    /// `handleSystemPhotoLibraryChange()` invocation per 300 ms window.
    private var changeDebounceTask: Task<Void, Never>?

    /// Batch hide/pin cloud-ID work after a 500 ms quiet window.
    private var backfillDebounceTask: Task<Void, Never>?

    /// Long-running, lifetime-of-singleton retry loop that calls
    /// `backfillCloudIdentifiers` every 5 minutes while the app is
    /// foregrounded (iOS naturally suspends `Task.sleep` when backgrounded).
    /// Catches records whose initial cloud-ID resolution failed because the
    /// asset hadn't yet uploaded to iCloud Photos at hide/pin time.
    private var retryTimerTask: Task<Void, Never>?

    /// Defer observer registration while authorization is notDetermined: first-use PhotoKit access can prompt.
    /// Without access there are no usable library changes to observe.
    private var isChangeObserverRegistered = false

    #if DEBUG
    /// Isolated cache/single-flight tests must not share epochs with the app
    /// singleton or register system observers and background retry timers.
    init(forTesting: Void) {
        authorizationStatus = .notDetermined
        super.init()
    }
    #endif

    private override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        // Register only after the permission answer so singleton creation cannot prompt.
        // Registration lasts for this process-lifetime singleton; no deinit PhotoKit access is needed.
        if authorizationStatus != .notDetermined {
            registerChangeObserverIfNeeded()
        }
        // Retry unresolved cloud IDs while foreground execution permits; iOS suspends the background timer.
        startCloudIDRetryTimer()
    }

    private func registerChangeObserverIfNeeded() {
        guard !isChangeObserverRegistered else { return }
        isChangeObserverRegistered = true
        PHPhotoLibrary.shared().register(self)
        logger.info("Registered as PHPhotoLibraryChangeObserver.")
    }

    private func startCloudIDRetryTimer() {
        retryTimerTask?.cancel()
        retryTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // `backfillCloudIdentifiers` short-circuits when no records
                // have `cloudIdentifier == nil`, so the steady-state cost is
                // one fetch every 5 minutes. A refresh that failed to read
                // its annotations retries here too.
                self.enqueueCloudIDMaintenance(backfill: true, refresh: self.cloudRefreshPending)
            }
        }
    }

    // MARK: - Cloud-ID maintenance chain

    /// Serialize EVERY backfill/refresh through one FIFO chain to prevent conflicting cross-context saves.
    /// Each pass awaits its predecessor; debouncing bounds the queue and completed links release.
    private var cloudIDMaintenanceChain: Task<Void, Never>?

    @discardableResult
    private func enqueueCloudIDMaintenance(backfill: Bool, refresh: Bool) -> Task<Void, Never> {
        let container = annotationContainer
        let previous = cloudIDMaintenanceChain
        let next = Task.detached { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            if backfill { await self.backfillCloudIdentifiers(modelContainer: container) }
            if refresh { await self.refreshCloudIdentifierCache(modelContainer: container) }
        }
        cloudIDMaintenanceChain = next
        return next
    }

    /// Awaitable entry point for the launch-maintenance and remote-
    /// notification paths, which need the pass complete before continuing
    /// (launch: before `handleStaleStateOnLaunch`; remote notification: the
    /// refresh must land after `invalidateTripCaches` and before
    /// `notifyChange`). Runs on the same FIFO chain as the debounced
    /// triggers, so it cannot interleave with them.
    func runCloudIDMaintenance(backfill: Bool, refresh: Bool) async {
        await enqueueCloudIDMaintenance(backfill: backfill, refresh: refresh).value
    }

    // MARK: - PHPhotoLibraryChangeObserver
    //
    // PhotoKit callbacks arrive on arbitrary queues: this method MUST be nonisolated.
    // Hop to MainActor before mutating state.

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // No retained PHFetchResult exists for incremental updates; debounce full invalidation on MainActor.
        Task { @MainActor in
            self.scheduleDebouncedChangeHandling()
        }
    }

    private func scheduleDebouncedChangeHandling() {
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.handleSystemPhotoLibraryChange()
        }
    }

    /// Debounce cloud-ID resolution; the batched backfill touches only unresolved rows.
    func scheduleCloudIDBackfill() {
        backfillDebounceTask?.cancel()
        backfillDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.enqueueCloudIDMaintenance(backfill: true, refresh: true)
        }
    }

    private func handleSystemPhotoLibraryChange() {
        // Auth may have transitioned via the system limited-library picker
        // or a Settings.app revoke — re-read it first so downstream consumers
        // see the current value even if no other state changes this cycle.
        refreshAuthorizationStatus()

        // Any cached `[StayPhotos]` may now hold dead `PHAsset` references,
        // and any cover photo may itself be the deleted asset. Wipe both;
        // preserve `cloudToLocalCache`, which has a separate lifecycle.
        invalidateTripCaches()

        changeToken = UUID()

        // Refresh cloud-to-local mappings off-main through the FIFO chain.
        enqueueCloudIDMaintenance(backfill: true, refresh: true)

        logger.info("Photo library changed; trip caches invalidated, changeToken bumped.")
    }

    /// Notify views to refetch after external annotation changes, including CloudKit sync.
    func notifyChange() {
        changeToken = UUID()
    }

    // MARK: - Authorization

    func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        // The user has now answered the permission question (whatever the
        // answer), so the deferred change-observer registration can no
        // longer surface an unexpected prompt.
        registerChangeObserverIfNeeded()
        return status
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // Catches grants made outside the in-app prompt (Settings.app, the
        // limited-library picker): every photo surface calls this on appear/
        // foreground, so the deferred registration lands at the first
        // opportunity after the status leaves `.notDetermined`.
        if authorizationStatus != .notDetermined {
            registerChangeObserverIfNeeded()
        }
    }

    // MARK: - Photo Fetching

    /// Snapshot inputs on MainActor, fetch and group immutable PhotoKit objects off-main, then cache on MainActor.
    /// Every return after a suspension re-checks the caller's own row: a saved deletion clears
    /// `isDeleted` but detaches the model, so liveness is `!isDeleted && modelContext != nil`.
    func photosForTrip(_ trip: Trip, retryBudget: Int = 3) async -> TripPhotosOutcome {
        // Callers hold trips across awaits; reject deleted models before any property read except isDeleted.
        guard Self.isLive(trip) else { return .unavailable }
        let snapshot = Self.photoSnapshot(for: trip)
        let token = snapshot.shapeToken
        if let cached = tripPhotoCache[trip.id], cached.stayShapeToken == token {
            return .loaded(cached.groups)
        }

        #if DEBUG
        let effectiveAuthorization = authorizationOverrideForTesting ?? authorizationStatus
        #else
        let effectiveAuthorization = authorizationStatus
        #endif
        guard effectiveAuthorization == .authorized || effectiveAuthorization == .limited else {
            return .loaded([])
        }

        let snapshots = snapshot.photoStays
        guard !snapshots.isEmpty else { return .loaded([]) }

        let tripID = trip.id
        // An invalidation in another trip must not discard this compute.
        let epoch = invalidationToken(for: tripID)

        // Identical trip, shape, and epoch inputs share one detached compute.
        let key = PhotoComputeKey(
            tripID: tripID, stayShapeToken: token,
            globalEpoch: epoch.global, tripEpoch: epoch.trip)
        #if DEBUG
        singleFlightAdmissionForTesting?(inFlightPhotoComputes[key] != nil)
        #endif
        if let inFlight = inFlightPhotoComputes[key] {
            let outcome = await inFlight.value
            // The creator's row is not this caller's row (UUID twins); fence our own.
            return Self.isLive(trip) ? outcome : .unavailable
        }

        // A failed block-list read is not "nothing hidden": publishing or caching
        // would expose hidden photos. No compute, cache fill or generation bump.
        guard let hidden = hiddenIdentifiers(for: tripID) else {
            logger.error("Hidden photos for trip \(tripID) could not be read; gallery load deferred.")
            return .unavailable
        }

        let (startDate, endDate) = snapshot.photoWindow
        let displayName = trip.displayName

        let work = Task { () -> TripPhotosOutcome in
            // Runs on completion (any path, incl. the retry recursion below —
            // whose new epoch makes a DIFFERENT key, so no self-collision).
            defer { inFlightPhotoComputes.removeValue(forKey: key) }

            #if DEBUG
            computeHiddenInputForTesting?(hidden)
            let grouped: [StayPhotos]
            if let override = computeOverrideForTesting {
                grouped = await override()
            } else {
                grouped = await Task.detached {
                    Self.computePhotoGroups(
                        stays: snapshots,
                        windowStart: startDate,
                        windowEnd: endDate,
                        hidden: hidden
                    )
                }.value
            }
            #else
            let grouped = await Task.detached {
                Self.computePhotoGroups(
                    stays: snapshots,
                    windowStart: startDate,
                    windowEnd: endDate,
                    hidden: hidden
                )
            }.value
            #endif

            // Liveness before epoch or cache: a row deleted during the compute
            // neither caches nor recurses into its detached stays. Joiners with
            // a live twin still get this snapshot of identical inputs; if it was
            // superseded meanwhile, notify so they reload under a fresh epoch
            // key, because no recursion runs for them (the exhaustion policy).
            guard Self.isLive(trip) else {
                if epoch != self.invalidationToken(for: tripID) {
                    self.logger.info("Photo compute for \(displayName) superseded after its trip row was deleted; notifying observers.")
                    self.changeToken = UUID()
                }
                return .loaded(grouped)
            }

            // Never cache a result computed before invalidation.
            guard epoch == self.invalidationToken(for: tripID) else {
                guard retryBudget > 0 else {
                    // Exhausted: publish the best-effort snapshot uncached, then
                    // notify so observers reload under a fresh epoch key. Not every
                    // invalidation site notifies, so this is the guaranteed follow-up.
                    self.logger.info("Photo compute for \(displayName) kept being superseded; returning an uncached snapshot.")
                    self.changeToken = UUID()
                    return .loaded(grouped)
                }
                self.logger.info("Photo compute for \(displayName) superseded by a cache invalidation; recomputing.")
                return await self.photosForTrip(trip, retryBudget: retryBudget - 1)
            }

            // Store the token from the SAME snapshot as the groups so later shape changes invalidate the pair.
            self.storeCachedTripPhotos(tripID: tripID, stayShapeToken: token, groups: grouped)
            self.bumpPhotoCacheGeneration()
            let matchedCount = grouped.reduce(0) { $0 + $1.assets.count }
            self.logger.info("Matched \(matchedCount) photos for trip \(displayName) (\(hidden.count) hidden)")
            return .loaded(grouped)
        }
        inFlightPhotoComputes[key] = work
        let outcome = await work.value
        return Self.isLive(trip) ? outcome : .unavailable
    }

    /// A saved deletion clears `isDeleted` but detaches the row from its context.
    static func isLive(_ trip: Trip) -> Bool {
        !trip.isDeleted && trip.modelContext != nil
    }

    // Preserve UI submission order even while an earlier edit waits for the gate.
    var annotationMutationTail: Task<Bool, Never>?

    // MARK: - Image Loading

    /// Return the request ID so cells can cancel image loading when they scroll offscreen.
    /// The completion's Bool is true for a degraded placeholder delivered before the final image.
    @discardableResult
    nonisolated func loadThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping @Sendable (UIImage?, Bool) -> Void
    ) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        // `.fast` bounds decoding near targetSize; `.none` is only a selection hint and can decode full-size photos.
        // Avoid `.exact`, which square-crops this aspectFill request.
        options.resizeMode = .fast

        return PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            completion(image, (info?[PHImageResultIsDegradedKey] as? Bool) ?? false)
        }
    }

    /// Cancel an image request; harmless after completion.
    nonisolated func cancelImageRequest(_ id: PHImageRequestID) {
        PHImageManager.default().cancelImageRequest(id)
    }

    /// Share images use aspectFit and a bounded targetSize to preserve aspect ratio; never request PHImageManagerMaximumSize.
    func loadFullSizeImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await loadImage(for: asset, targetSize: targetSize)
    }

    private func loadImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let manager = imageManager
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        // Request an image near targetSize; PhotoKit may return other dimensions.
        // `.fast` resizing + `.aspectFit` preserves the photo's aspect ratio
        // for sharing while avoiding a request for the original full-size image.
        options.resizeMode = .fast

        return await PhotoImageRequest.load { completion in
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                completion(image)
            }
        } cancel: { id in
            manager.cancelImageRequest(id)
        }
    }

    // MARK: - Cache Management

    /// Global invalidation rejects in-flight stale results; MainActor-confined like the cache.
    /// Per-trip changes use tripInvalidationEpochs so unrelated trips retain their work.
    private(set) var cacheInvalidationEpoch = 0

    /// Missing per-trip epochs are zero; whole-cache invalidation clears them because the global epoch supersedes them.
    private var tripInvalidationEpochs: [UUID: Int] = [:]

    /// The staleness token `photosForTrip` captures before its detached
    /// compute: (global epoch, this trip's epoch). Changes iff an
    /// invalidation that could affect THIS trip landed. A tuple, not a sum
    /// — summing lets a whole-cache wipe (+1 global, per-trip cleared)
    /// collide with a captured per-trip epoch of exactly 1.
    func invalidationToken(for tripID: UUID) -> (global: Int, trip: Int) {
        (cacheInvalidationEpoch, tripInvalidationEpochs[tripID] ?? 0)
    }

    func invalidateCache(for tripID: UUID) {
        tripPhotoCache.removeValue(forKey: tripID)
        tripPhotoCacheOrder.removeAll { $0 == tripID }
        // Unlike eviction, an invalidation means the DATA is stale — the
        // mirrored count must go too (prewarm refills it).
        tripPhotoCounts.removeValue(forKey: tripID)
        tripInvalidationEpochs[tripID, default: 0] &+= 1
        bumpPhotoCacheGeneration()
    }

    /// Hiding preserves remaining asset grouping, so remove the asset and empty groups directly.
    /// Unhiding must invalidate because restoring an asset requires stay matching.
    func removeAssetFromCache(localIdentifier: String, tripID: UUID) {
        // Bump the epoch first even without a cache entry: in-flight pre-hide results must be invalidated.
        tripInvalidationEpochs[tripID, default: 0] &+= 1
        guard let cached = tripPhotoCache[tripID] else {
            // Without heavy groups the count cannot be patched; drop it and publish photoCacheGeneration for sort/filter observers.
            if tripPhotoCounts.removeValue(forKey: tripID) != nil {
                bumpPhotoCacheGeneration()
            }
            return
        }
        let filtered = cached.groups.compactMap { group -> StayPhotos? in
            guard group.assets.contains(where: { $0.localIdentifier == localIdentifier }) else {
                return group
            }
            let remaining = group.assets.filter { $0.localIdentifier != localIdentifier }
            guard !remaining.isEmpty else { return nil }
            return StayPhotos(
                stayID: group.stayID,
                stayLocality: group.stayLocality,
                stayStartTime: group.stayStartTime,
                assets: remaining
            )
        }
        // Same stay shape — the surgical edit only changes which assets are
        // visible, so the original token stays valid.
        storeCachedTripPhotos(
            tripID: tripID, stayShapeToken: cached.stayShapeToken, groups: filtered
        )
        tripInvalidationEpochs[tripID, default: 0] &+= 1
        bumpPhotoCacheGeneration()
    }

    /// Invalidate trip photos while preserving cloud-to-local mappings, which have an independent lifecycle.
    func invalidateTripCaches() {
        tripPhotoCache.removeAll()
        tripPhotoCacheOrder.removeAll()
        // Counts stay readable for sort and filter until prewarm recounts
        // them under the new epoch.
        cacheInvalidationEpoch &+= 1
        // The global bump above already changes every trip's token.
        tripInvalidationEpochs.removeAll()
        bumpPhotoCacheGeneration()
    }

    /// Drop only the cloud→local translation cache. Call this if the
    /// underlying mapping is known stale (auth change to `.limited`,
    /// the user toggled iCloud Photos off, etc.). On the next read,
    /// `refreshCloudIdentifierCache` will rebuild it from scratch.
    func invalidateCloudIdentifierCache() {
        cloudToLocalCache.removeAll()
    }

    /// Wipe everything — per-trip caches + the cloud→local translation
    /// cache. Reserved for global "wipe all photo state" operations such
    /// as `SettingsView.deleteAllData` where there is no remaining
    /// underlying SwiftData state for either cache to mirror.
    func invalidateAllCaches() {
        invalidateTripCaches()
        tripPhotoCounts.removeAll()
        invalidateCloudIdentifierCache()
    }

    // MARK: - Photo Count (for sort)

    /// Pure cached count for TripSorter; nil sorts as zero until prewarm fills it.
    func cachedPhotoCount(for tripID: UUID) -> Int? {
        // Register the Observation dependency views need now that the cache
        // dictionary itself is untracked (see `photoCacheGeneration`).
        _ = photoCacheGeneration
        // Reads the uncapped count mirror, not the heavy cache — a count
        // stays available after its PHAsset groups were evicted.
        return tripPhotoCounts[tripID]?.count
    }

    /// Cancellable serial prewarm yields between trips and skips shape-valid counts.
    /// Without photo access, counts are zero and photo sorting has no effect.
    func prewarmPhotoCounts(for trips: [Trip]) async {
        #if DEBUG
        let effectiveAuthorization = authorizationOverrideForTesting ?? authorizationStatus
        #else
        let effectiveAuthorization = authorizationStatus
        #endif
        guard effectiveAuthorization == .authorized || effectiveAuthorization == .limited else {
            // Retained counts must not outlive access.
            if !tripPhotoCounts.isEmpty {
                tripPhotoCounts.removeAll()
                photoCacheGeneration &+= 1
            }
            return
        }
        // Publish every 25 fills and at exit, including cancellation and concurrent hide/unhide changes.
        // New task(id:) runs supersede old runs; only the newest may clear suppression in defer.
        prewarmGeneration &+= 1
        let generation = prewarmGeneration
        suppressGenerationBumps = true
        defer {
            if generation == prewarmGeneration {
                suppressGenerationBumps = false
            }
            photoCacheGeneration &+= 1
        }
        var filledSincePublish = 0
        for trip in trips {
            if Task.isCancelled || generation != prewarmGeneration { return }
            // Saving a deletion clears isDeleted but detaches the trip from its context.
            guard !trip.isDeleted, trip.modelContext != nil else { continue }
            // Consult shape-valid count mirrors so eviction of heavy groups does not trigger repeated PhotoKit fetches.
            if let cached = tripPhotoCounts[trip.id],
               cached.epoch == cacheInvalidationEpoch,
               cached.stayShapeToken == Self.stayShapeToken(for: trip) {
                continue
            }
            await prewarmPhotoCount(for: trip, generation: generation)
            filledSincePublish += 1
            if filledSincePublish >= 25 {
                photoCacheGeneration &+= 1
                filledSincePublish = 0
            }
            await Task.yield()
        }
    }

    // MARK: - Private Helpers

    private func prewarmPhotoCount(for trip: Trip, generation: Int, retryBudget: Int = 3) async {
        guard !trip.isDeleted, trip.modelContext != nil,
              !Task.isCancelled, generation == prewarmGeneration else { return }
        #if DEBUG
        let effectiveAuthorization = authorizationOverrideForTesting ?? authorizationStatus
        #else
        let effectiveAuthorization = authorizationStatus
        #endif
        guard effectiveAuthorization == .authorized || effectiveAuthorization == .limited else { return }

        let tripID = trip.id
        let snapshot = Self.photoSnapshot(for: trip)
        let token = snapshot.shapeToken
        let epoch = invalidationToken(for: tripID)
        let key = PhotoComputeKey(
            tripID: tripID, stayShapeToken: token,
            globalEpoch: epoch.global, tripEpoch: epoch.trip)
        if let inFlight = inFlightPhotoComputes[key] {
            #if DEBUG
            singleFlightAdmissionForTesting?(true)
            #endif
            // The gallery owns publication of its groups and matching count mirror.
            _ = await inFlight.value
            return
        }

        let snapshots = snapshot.photoStays
        guard !snapshots.isEmpty else {
            // A retained count from before the trip lost its stays is stale.
            tripPhotoCounts[tripID] = nil
            return
        }
        let (startDate, endDate) = snapshot.photoWindow
        // An unreadable block-list must not count hidden photos. Any retained
        // count stays as it was, and its stale epoch makes the next prewarm retry.
        guard let hidden = hiddenIdentifiers(for: tripID) else { return }
        let count: Int
        #if DEBUG
        if let override = countOverrideForTesting {
            count = await override()
        } else {
            count = await Task.detached {
                Self.computePhotoCount(stays: snapshots, windowStart: startDate, windowEnd: endDate, hidden: hidden)
            }.value
        }
        #else
        count = await Task.detached {
            Self.computePhotoCount(stays: snapshots, windowStart: startDate, windowEnd: endDate, hidden: hidden)
        }.value
        #endif

        guard !trip.isDeleted, trip.modelContext != nil,
              !Task.isCancelled, generation == prewarmGeneration else { return }
        guard epoch == invalidationToken(for: tripID) else {
            if retryBudget > 0 {
                await prewarmPhotoCount(for: trip, generation: generation, retryBudget: retryBudget - 1)
            }
            return
        }
        guard token == Self.stayShapeToken(for: trip) else { return }
        tripPhotoCounts[tripID] = CachedPhotoCount(
            stayShapeToken: token, count: count, epoch: cacheInvalidationEpoch
        )
    }

}

