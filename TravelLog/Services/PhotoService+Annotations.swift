
import Photos
import UIKit
import CoreLocation
import SwiftData
import os.log

extension PhotoService {

    var annotationContainer: ModelContainer {
        #if DEBUG
        if let mutationContainerForTesting { return mutationContainerForTesting }
        #endif
        return AppDelegate.modelContainer
    }

    private func enqueueAnnotationMutation(
        touching: StoreChange,
        _ mutation: @escaping @MainActor @Sendable () -> Bool
    ) -> Task<Bool, Never> {
        let previous = annotationMutationTail
        var gate = PipelineGate.shared
        #if DEBUG
        gate = mutationGateForTesting ?? gate
        #endif
        let task = Task {
            _ = await previous?.value
            return await gate.runReturning(touching: touching) {
                await MainActor.run(body: mutation)
            }
        }
        annotationMutationTail = task
        return task
    }

    // MARK: - Hide / Show

    /// Hide only within this trip; the system Photos library is unchanged.
    /// Match local and cloud-resolved IDs to prevent cross-device duplicate annotations.
    /// Cloud-ID resolution is batched off-main; local matching is immediate, cross-device matching eventual.
    @discardableResult
    func hidePhoto(localIdentifier: String, tripID: UUID) -> Task<Bool, Never> {
        enqueueAnnotationMutation(touching: [.hiddenPhoto]) { [self] in
            let context = ModelContext(self.annotationContainer)
            context.autosaveEnabled = false
            guard let matching = matchingHiddenRecords(in: context, localIdentifier: localIdentifier, tripID: tripID) else { return false }
            if !matching.isEmpty {
                // Already hidden — clear the cache and signal any stale view to
                // re-fetch, but don't insert a duplicate row.
                invalidateCache(for: tripID)
                changeToken = UUID()
                return true
            }
            // The view may have disappeared while this request waited.
            guard (try? context.fetchCount(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID }))) ?? 0 > 0 else { return false }
            context.insert(HiddenPhoto(localIdentifier: localIdentifier, tripID: tripID))
            do {
                #if DEBUG
                if failAnnotationSaveForTesting { throw CocoaError(.fileWriteUnknown) }
                #endif
                try context.save()
                logger.info("Hidden photo \(localIdentifier) from trip \(tripID).")
            } catch {
                logger.error("Failed to save hidden photo: \(error.localizedDescription)")
                context.rollback()
                return false
            }
            removeAssetFromCache(localIdentifier: localIdentifier, tripID: tripID)
            scheduleCloudIDBackfill()
            changeToken = UUID()
            return true
        }
    }

    /// Restore every matching local or cloud-resolved row, including cross-device duplicates.
    @discardableResult
    func unhidePhoto(localIdentifier: String, tripID: UUID) -> Task<Bool, Never> {
        enqueueAnnotationMutation(touching: [.hiddenPhoto]) { [self] in
            let context = ModelContext(self.annotationContainer)
            context.autosaveEnabled = false
            guard let matching = matchingHiddenRecords(in: context, localIdentifier: localIdentifier, tripID: tripID) else { return false }
            guard !matching.isEmpty else {
                invalidateCache(for: tripID)
                return true
            }
            for record in matching {
                context.delete(record)
            }
            do {
                #if DEBUG
                if failAnnotationSaveForTesting { throw CocoaError(.fileWriteUnknown) }
                #endif
                try context.save()
                logger.info("Unhidden photo \(localIdentifier) on trip \(tripID) (\(matching.count) row(s)).")
            } catch {
                logger.error("Failed to unhide photo: \(error.localizedDescription)")
                context.rollback()
                return false
            }
            invalidateCache(for: tripID)
            changeToken = UUID()
            return true
        }
    }

    /// All `HiddenPhoto` rows that refer to the same photo as `localIdentifier`
    /// on this device. Matches by stored `localIdentifier` OR by stored
    /// `cloudIdentifier` resolved (via `cloudToLocalCache`) to this device's
    /// local ID. Returns the rows in deterministic order so callers can pick
    /// a primary if needed.
    private func matchingHiddenRecords(
        in context: ModelContext,
        localIdentifier: String,
        tripID: UUID
    ) -> [HiddenPhoto]? {
        guard let allForTrip = try? context.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )) else { return nil }
        let cloudID = cloudIdentifier(forLocalIdentifier: localIdentifier)
        return allForTrip.filter { row in
            row.localIdentifier == localIdentifier
                || (cloudID != nil && row.cloudIdentifier == cloudID)
        }
    }

    /// Returns the user-hidden `PHAsset`s this trip's gallery would show if
    /// they were not hidden, resolved on this device, in chronological order.
    /// Mirrors `pinnedAssets(in:tripID:)` but reads the hidden list. A row the
    /// trip would never show (a split piece inherits every hidden row of the
    /// original) stays stored but is not offered. Rows whose underlying asset
    /// no longer exists on this device (deleted from Photos, or never
    /// iCloud-synced here) are silently omitted by `PHAsset.fetchAssets(withLocalIdentifiers:)`.
    /// Snapshot the trip and identifiers on MainActor; fetch, admit and sort immutable PHAssets on the detached executor.
    /// Nil when the hidden rows could not be read: callers keep what they show.
    func hiddenAssets(for trip: Trip) async -> [PHAsset]? {
        guard Self.isLive(trip) else { return [] }
        let snapshot = Self.photoSnapshot(for: trip)
        let stays = snapshot.photoStays
        guard !stays.isEmpty else { return [] }
        guard let ids = hiddenIdentifiers(for: trip.id) else { return nil }
        guard !ids.isEmpty else { return [] }
        let (windowStart, windowEnd) = snapshot.photoWindow

        return await Task.detached {
            Self.resolveOfferedHiddenAssets(
                withLocalIdentifiers: ids, stays: stays,
                windowStart: windowStart, windowEnd: windowEnd)
        }.value.assets
    }

    /// Whether this device can show at least one of the trip's hidden photos,
    /// the same set `hiddenAssets(for:)` lists. Keeps the recovery route
    /// to Hidden Photos when no visible photo is left. An unreadable hidden
    /// list answers true: unknown must not remove the only way to restore.
    func hasRestorableHiddenPhotos(for trip: Trip) async -> Bool {
        #if DEBUG
        let effectiveAuthorization = authorizationOverrideForTesting ?? authorizationStatus
        #else
        let effectiveAuthorization = authorizationStatus
        #endif
        guard effectiveAuthorization == .authorized || effectiveAuthorization == .limited else {
            return false
        }
        guard Self.isLive(trip) else { return false }
        let snapshot = Self.photoSnapshot(for: trip)
        let stays = snapshot.photoStays
        guard !stays.isEmpty else { return false }
        guard let ids = hiddenIdentifiers(for: trip.id) else { return true }
        guard !ids.isEmpty else { return false }
        #if DEBUG
        if let override = hiddenResolutionOverrideForTesting { return override(ids) > 0 }
        #endif
        let (windowStart, windowEnd) = snapshot.photoWindow
        return await Task.detached {
            !Self.resolveOfferedHiddenAssets(
                withLocalIdentifiers: ids, stays: stays,
                windowStart: windowStart, windowEnd: windowEnd
            ).assets.isEmpty
        }.value
    }

    /// Nonisolated fetch, gallery admission and chronological sort run on the detached executor.
    nonisolated static func resolveOfferedHiddenAssets(
        withLocalIdentifiers ids: Set<String>,
        stays: [StaySnapshot],
        windowStart: Date,
        windowEnd: Date
    ) -> ResolvedAssets {
        let matchContexts = Self.matchContexts(for: stays)
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in
            guard isOfferedHiddenAsset(
                location: asset.location, creationDate: asset.creationDate,
                mediaType: asset.mediaType, mediaSubtypes: asset.mediaSubtypes,
                sourceType: asset.sourceType, isHidden: asset.isHidden,
                windowStart: windowStart, windowEnd: windowEnd, matchContexts: matchContexts
            ) else { return }
            assets.append(asset)
        }
        return ResolvedAssets(
            assets: assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        )
    }

    /// Local and cloud-resolved identifiers hidden on this trip, or nil when
    /// the rows could not be read. Nil is never "nothing hidden".
    func hiddenIdentifiers(for tripID: UUID) -> Set<String>? {
        let context = ModelContext(annotationContainer)
        let descriptor = FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )
        let records: [HiddenPhoto]
        do {
            #if DEBUG
            if failAnnotationReadForTesting { throw CocoaError(.fileReadUnknown) }
            #endif
            records = try context.fetch(descriptor)
        } catch {
            logger.error("Cannot read hidden photos: \(error.localizedDescription)")
            return nil
        }

        var ids = Set<String>()
        for record in records {
            // Always include the stored localID — covers same-device hides
            // and pre-V7 records that never got a cloudID. Harmless on other
            // devices (just doesn't match anything there).
            ids.insert(record.localIdentifier)

            // If we have a cloudID and the cache has translated it to a
            // localID on THIS device, include that too. This is the
            // cross-device match path.
            if let cloudID = record.cloudIdentifier,
               let resolvedLocal = cloudToLocalCache[cloudID] {
                ids.insert(resolvedLocal)
            }
        }
        return ids
    }

    // MARK: - Pin / Unpin

    /// True iff this asset is currently pinned for this trip. Uses the
    /// union semantics of `pinnedIdentifiers(for:)` so a photo pinned on
    /// another device under a different `localIdentifier` still reads as
    /// pinned here (assuming `cloudToLocalCache` is populated).
    func isPinned(localIdentifier: String, tripID: UUID) -> Bool {
        pinnedIdentifiers(for: tripID).contains(localIdentifier)
    }

    /// Pin a photo to the top of a trip. Idempotent (no-op if already pinned,
    /// including cross-device duplicates). Same eventual-consistency pattern
    /// as `hidePhoto`: the cloud ID is captured in the background via the
    /// debounced batched backfill, not inline, so rapid pins coalesce into a
    /// single PhotoKit syscall.
    @discardableResult
    func pinPhoto(localIdentifier: String, tripID: UUID) -> Task<Bool, Never> {
        enqueueAnnotationMutation(touching: [.pinnedPhoto]) { [self] in
            let context = ModelContext(self.annotationContainer)
            context.autosaveEnabled = false
            guard let matching = matchingPinnedRecords(in: context, localIdentifier: localIdentifier, tripID: tripID) else { return false }
            if !matching.isEmpty {
                // Already pinned. Still signal — the caller may have shown a
                // stale "Pin to Top" affordance and observers need to repaint.
                changeToken = UUID()
                return true
            }
            // The view may have disappeared while this request waited.
            guard (try? context.fetchCount(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID }))) ?? 0 > 0 else { return false }
            context.insert(PinnedPhoto(localIdentifier: localIdentifier, tripID: tripID))
            do {
                #if DEBUG
                if failAnnotationSaveForTesting { throw CocoaError(.fileWriteUnknown) }
                #endif
                try context.save()
                logger.info("Pinned photo \(localIdentifier) on trip \(tripID).")
            } catch {
                logger.error("Failed to save pinned photo: \(error.localizedDescription)")
                context.rollback()
                return false
            }
            scheduleCloudIDBackfill()
            changeToken = UUID()
            return true
        }
    }

    /// Remove a pin. Deletes every row that refers to this photo on this
    /// trip — including cross-device duplicates and rows written by another
    /// device under a different `localIdentifier`. Idempotent.
    @discardableResult
    func unpinPhoto(localIdentifier: String, tripID: UUID) -> Task<Bool, Never> {
        enqueueAnnotationMutation(touching: [.pinnedPhoto]) { [self] in
            let context = ModelContext(self.annotationContainer)
            context.autosaveEnabled = false
            guard let matching = matchingPinnedRecords(in: context, localIdentifier: localIdentifier, tripID: tripID) else { return false }
            guard !matching.isEmpty else { return true }
            for record in matching {
                context.delete(record)
            }
            do {
                #if DEBUG
                if failAnnotationSaveForTesting { throw CocoaError(.fileWriteUnknown) }
                #endif
                try context.save()
                logger.info("Unpinned photo \(localIdentifier) on trip \(tripID) (\(matching.count) row(s)).")
            } catch {
                logger.error("Failed to unpin photo: \(error.localizedDescription)")
                context.rollback()
                return false
            }
            changeToken = UUID()
            return true
        }
    }

    /// All `PinnedPhoto` rows that refer to the same photo as `localIdentifier`
    /// on this device. Matches by stored `localIdentifier` OR by stored
    /// `cloudIdentifier` resolved (via `cloudToLocalCache`) to this device's
    /// local ID. Mirrors `matchingHiddenRecords`.
    private func matchingPinnedRecords(
        in context: ModelContext,
        localIdentifier: String,
        tripID: UUID
    ) -> [PinnedPhoto]? {
        guard let allForTrip = try? context.fetch(FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )) else { return nil }
        let cloudID = cloudIdentifier(forLocalIdentifier: localIdentifier)
        return allForTrip.filter { row in
            row.localIdentifier == localIdentifier
                || (cloudID != nil && row.cloudIdentifier == cloudID)
        }
    }

    /// Reverse cloud-ID lookup lets local actions find annotations created under another device’s local ID.
    private func cloudIdentifier(forLocalIdentifier localID: String) -> String? {
        cloudToLocalCache.first(where: { $0.value == localID })?.key
    }

    /// Set of `localIdentifier`s pinned for this trip on **this device** —
    /// including any local IDs resolved from cross-device cloud IDs via
    /// `cloudToLocalCache`. Cheap to call repeatedly (no PhotoKit I/O).
    func pinnedIdentifiers(for tripID: UUID) -> Set<String> {
        let context = ModelContext(AppDelegate.modelContainer)
        let descriptor = FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID }
        )
        let records = (try? context.fetch(descriptor)) ?? []

        var ids = Set<String>()
        for record in records {
            // Stored localID — same-device match + pre-V7 fallback.
            ids.insert(record.localIdentifier)

            // Cross-device match via the cloud-ID cache.
            if let cloudID = record.cloudIdentifier,
               let resolvedLocal = cloudToLocalCache[cloudID] {
                ids.insert(resolvedLocal)
            }
        }
        return ids
    }

    /// Chronological pinned overlay; assets remain in their normal stay groups.
    func pinnedAssets(in tripPhotos: [StayPhotos], tripID: UUID) -> [PHAsset] {
        Self.pinnedAssets(in: tripPhotos, pinnedIdentifiers: pinnedIdentifiers(for: tripID))
    }

    /// Pure test seam for views holding pinned IDs; view bodies must not call the SwiftData-fetching variant.
    static func pinnedAssets(in tripPhotos: [StayPhotos], pinnedIdentifiers: Set<String>) -> [PHAsset] {
        guard !pinnedIdentifiers.isEmpty else { return [] }
        return tripPhotos
            .flatMap(\.assets)
            .filter { pinnedIdentifiers.contains($0.localIdentifier) }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    // MARK: - Cloud Identifier Translation
    //
    // Why this exists: `PHAsset.localIdentifier` is per-device. Two devices
    // with the same iCloud Photos library have DIFFERENT localIdentifiers
    // for the same physical photo. `PHCloudIdentifier` is the device-
    // independent identifier — we capture it at hide/pin time, and translate
    // it back to this device's localIdentifier via `cloudToLocalCache` at
    // read time so the filter actually matches across devices.
    // Archival strings preserve the format previously stored via `stringValue`.
    //
    // All `PHPhotoLibrary` calls below are made on a background task because
    // PhotoKit flags main-thread I/O as a slow-launch hazard. The cache is
    // written via `MainActor.run` so the property stays main-actor-isolated.

    /// Malformed stored identifiers cannot participate in PhotoKit lookup.
    nonisolated static func decodeCloudIdentifiers(_ strings: Set<String>) -> [PHCloudIdentifier] {
        strings.compactMap { PHCloudIdentifier(archivalStringValue: $0) }
    }

    /// Drop mappings that resolve to the local ID every carrying row already stores; they cannot change any admitted set.
    nonisolated static func effectiveCloudMappings(_ cache: [String: String], rowLocalIDsByCloudID: [String: Set<String>]) -> [String: String] {
        cache.filter { cloudID, localID in rowLocalIDsByCloudID[cloudID] != [localID] }
    }

    /// Rebuild cloud-to-local mappings from all stored annotations.
    /// Nonisolated PhotoKit work receives the container explicitly to avoid MainActor access.
    /// A failed annotation read keeps the current mappings (dropping them would
    /// unhide photos hidden on other devices) and leaves the refresh pending.
    /// Failed PhotoKit lookups retain their previous mappings and retry too;
    /// an identifier PhotoKit reports as not found loses its mapping.
    nonisolated func refreshCloudIdentifierCache(modelContainer: ModelContainer) async {
        #if DEBUG
        let (auth, failRead, mappingOverride) = await MainActor.run {
            (self.authorizationOverrideForTesting ?? self.authorizationStatus,
             self.failAnnotationReadForTesting, self.cloudMappingOverrideForTesting)
        }
        #else
        let auth = await MainActor.run { self.authorizationStatus }
        #endif
        guard auth == .authorized || auth == .limited else { return }

        let context = ModelContext(modelContainer)
        let hiddenRows: [(String?, String)]
        let pinnedRows: [(String?, String)]
        do {
            #if DEBUG
            if failRead { throw CocoaError(.fileReadUnknown) }
            #endif
            hiddenRows = try context.fetch(FetchDescriptor<HiddenPhoto>())
                .map { ($0.cloudIdentifier, $0.localIdentifier) }
            pinnedRows = try context.fetch(FetchDescriptor<PinnedPhoto>())
                .map { ($0.cloudIdentifier, $0.localIdentifier) }
        } catch {
            logger.error("Cannot read photo annotations for the cloud-ID refresh: \(error.localizedDescription)")
            await MainActor.run { self.cloudRefreshPending = true }
            return
        }
        var rowLocalIDsByCloudID: [String: Set<String>] = [:]
        for (cloudID, localID) in hiddenRows + pinnedRows {
            guard let cloudID else { continue }
            rowLocalIDsByCloudID[cloudID, default: []].insert(localID)
        }
        let rowLocalIDs = rowLocalIDsByCloudID
        let uniqueCloudIDs = Set(rowLocalIDs.keys)
        let phCloudIDs = Self.decodeCloudIdentifiers(uniqueCloudIDs)
        let skippedCount = uniqueCloudIDs.count - phCloudIDs.count

        #if DEBUG
        let overriddenCache = mappingOverride?(Set(phCloudIDs.map(\.archivalStringValue)))
        #else
        let overriddenCache: [String: String]? = nil
        #endif
        let newCache: [String: String]
        // A photo deleted from the library never resolves again: drop its mapping without a retry.
        var notFoundCloudIDs = Set<String>()
        if let overriddenCache {
            newCache = overriddenCache
        } else if phCloudIDs.isEmpty {
            newCache = [:]
        } else {
            let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: phCloudIDs)
            var built: [String: String] = [:]
            for (phCloudID, result) in mapping {
                switch result {
                case .success(let localID):
                    built[phCloudID.archivalStringValue] = localID
                case .failure(let error):
                    if (error as? PHPhotosError)?.code == .identifierNotFound {
                        notFoundCloudIDs.insert(phCloudID.archivalStringValue)
                    }
                }
            }
            newCache = built
        }

        let failedCloudIDs = Set(phCloudIDs.map(\.archivalStringValue))
            .subtracting(newCache.keys).subtracting(notFoundCloudIDs)
        let resolvedCount = newCache.count
        let totalCount = uniqueCloudIDs.count

        // Apply mappings atomically and invalidate photos only when changed, keeping filters current without refetch storms.
        await MainActor.run {
            self.cloudRefreshPending = !failedCloudIDs.isEmpty
            let oldCache = self.cloudToLocalCache
            // Failed lookups keep known mappings; unreferenced identifiers are pruned.
            var mergedCache = oldCache.filter { failedCloudIDs.contains($0.key) }
            mergedCache.merge(newCache) { _, resolved in resolved }
            self.cloudToLocalCache = mergedCache
            if Self.effectiveCloudMappings(oldCache, rowLocalIDsByCloudID: rowLocalIDs)
                != Self.effectiveCloudMappings(mergedCache, rowLocalIDsByCloudID: rowLocalIDs) {
                self.invalidateTripCaches()
                self.changeToken = UUID()
            }
        }
        logger.info("Cloud-identifier cache refreshed: \(resolvedCount) of \(totalCount) cloud IDs resolved on this device. Skipped \(skippedCount) unparseable cloud IDs.")
    }

    /// One-shot pass over legacy V6 records that have no `cloudIdentifier`
    /// yet. Batch-resolves their local→cloud mappings in a single PhotoKit
    /// call and writes the results back. Best-effort: records that fail to
    /// resolve (e.g. asset not yet iCloud-synced) stay `nil` and get
    /// retried on the next launch.
    nonisolated func backfillCloudIdentifiers(modelContainer: ModelContainer) async {
        let auth = await MainActor.run { self.authorizationStatus }
        guard auth == .authorized || auth == .limited else { return }

        // Only scalar identifiers survive the PhotoKit suspension. Refetch the
        // still-live rows under the gate before applying the resolved mapping.
        let localIDs: [String]
        do {
            let context = ModelContext(modelContainer)
            let hidden = try context.fetch(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { $0.cloudIdentifier == nil }))
            let pinned = try context.fetch(FetchDescriptor<PinnedPhoto>(
                predicate: #Predicate { $0.cloudIdentifier == nil }))
            localIDs = Array(Set(hidden.map(\.localIdentifier) + pinned.map(\.localIdentifier)))
        } catch {
            logger.error("Cannot read photo annotations for backfill: \(error.localizedDescription)")
            return
        }
        for offset in stride(from: 0, to: localIDs.count, by: 200) {
            guard !Task.isCancelled else { return }
            let ids = Array(localIDs[offset..<min(offset + 200, localIDs.count)])
            let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
            let resolved = mapping.compactMapValues { result -> String? in
                if case .success(let cloudID) = result { return cloudID.archivalStringValue }
                return nil
            }
            guard !resolved.isEmpty else { continue }
            await PipelineGate.shared.run(touching: [.hiddenPhoto, .pinnedPhoto]) {
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false
                do {
                    let hidden = try context.fetch(FetchDescriptor<HiddenPhoto>(
                        predicate: #Predicate { $0.cloudIdentifier == nil && ids.contains($0.localIdentifier) }))
                    let pinned = try context.fetch(FetchDescriptor<PinnedPhoto>(
                        predicate: #Predicate { $0.cloudIdentifier == nil && ids.contains($0.localIdentifier) }))
                    for row in hidden { row.cloudIdentifier = resolved[row.localIdentifier] }
                    for row in pinned { row.cloudIdentifier = resolved[row.localIdentifier] }
                    if context.hasChanges { try context.save() }
                } catch {
                    context.rollback()
                    self.logger.error("Cannot save photo cloud identifiers: \(error.localizedDescription)")
                }
            }
        }
    }
}
