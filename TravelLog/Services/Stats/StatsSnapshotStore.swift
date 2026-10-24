//
//  StatsSnapshotStore.swift
//  TravelLog
//

import Foundation
import os.log

/// Disk cache for the last `StatsAggregator.Aggregates` the Stats page
/// computed: after a force quit, the page would show near-empty
/// placeholders for the 1–2 s the first off-main aggregate takes on a cold
/// launch — while a warm app re-enters the tab instantly off its `@State`.
/// Persisting the last result closes the gap: the view hydrates
/// the snapshot immediately and the fresh compute replaces it when it lands.
/// **Showing second-old stale data while recomputing beats showing nothing**
/// — the deliberate trade, and why the snapshot is never trusted past the
/// first fresh compute of the process.
///
/// Device-local by design (a display cache, not data — CloudKit sync would
/// be wrong: another device's totals include stays this device may not have
/// synced yet). JSON file in Application Support; any decode failure reads
/// as "no snapshot" and the page falls back to today's cold-launch behavior.
nonisolated enum StatsSnapshotStore {

    private static let logger = Logger(subsystem: "com.travellog.app", category: "StatsSnapshotStore")

    /// Bump when aggregate shape or semantics change — a stale-shape
    /// file then simply fails to decode (same outcome as no snapshot), but
    /// the new name avoids even paying the failed decode.
    private static let fileName = "stats-aggregates-snapshot-v8.json"
    private static let legacyFileNames = ["stats-aggregates-snapshot-v1.json", "stats-aggregates-snapshot-v2.json", "stats-aggregates-snapshot-v3.json", "stats-aggregates-snapshot-v4.json", "stats-aggregates-snapshot-v5.json", "stats-aggregates-snapshot-v6.json", "stats-aggregates-snapshot-v7.json"]

    #if DEBUG
    struct StorageForTesting: Sendable {
        let directory: URL
        // Pass a suite name across tasks, never a non-Sendable defaults instance.
        let defaultsSuiteName: String

        var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuiteName)! }
    }

    @TaskLocal static var storageForTesting: StorageForTesting?
    #endif

    /// Request order is assigned on result acceptance, before detached writers
    /// can reorder their execution. One lock serializes disk replacement and wipes.
    struct SaveRequest: Sendable {
        let generation: Int
        fileprivate let revision: UInt64
    }
    private static let publication = OSAllocatedUnfairLock(initialState: [String: UInt64]())

    static func reserveSave(generation: Int) -> SaveRequest? {
        let (request, recovered) = publication.withLock { revisions -> (SaveRequest?, Bool) in
            let recovered = finishInterruptedRevocationLocked()
            guard let url = fileURL, generation == clearGeneration,
                  !revocationPendingLocked else { return (nil, recovered) }
            let next = (revisions[url.path] ?? 0) + 1
            revisions[url.path] = next
            return (SaveRequest(generation: generation, revision: next), recovered)
        }
        if recovered { postCleared() }
        return request
    }

    /// Locale-bearing display values (`lastTrip.name`, longest-trip name,
    /// country labels) live inside `Aggregates`. Keep their app-language tag
    /// beside the payload so a per-app language relaunch never flashes the
    /// previous language while the fresh 1–2 second aggregate runs.
    private struct Snapshot: Codable {
        let generation: Int
        let languageTag: String
        let aggregates: StatsAggregator.Aggregates
    }

    static var fileURL: URL? {
        #if DEBUG
        if let storageForTesting {
            return storageForTesting.directory.appendingPathComponent(fileName)
        }
        #endif
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent(fileName)
    }

    private static var legacyFileURLs: [URL] {
        #if DEBUG
        if let storageForTesting {
            return legacyFileNames.map { storageForTesting.directory.appendingPathComponent($0) }
        }
        #endif
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [] }
        return legacyFileNames.map { base.appendingPathComponent($0) }
    }

    /// Monotonic wipe counter. `clear()` is
    /// called synchronously from Delete All Data, but every Stats compute
    /// spawns a fire-and-forget background `save` — so a compute that read
    /// PRE-wipe state could land AFTER `clear()` removed the file and rewrite
    /// the deleted totals, which the next cold launch would then hydrate. A
    /// wiped app resurrecting its old travel numbers is the one outcome this
    /// file must never produce. Callers capture the generation BEFORE they
    /// start computing; `save` refuses a write whose generation has moved.
    ///
    /// UserDefaults rather than an in-process counter: the race is
    /// process-local, but a persisted counter also survives the case where
    /// the wipe is the last thing that happens before a crash.
    private static let clearGenerationKey = "statsSnapshotClearGeneration_v1"

    /// The wipe generation to capture before computing aggregates, and to
    /// hand back to `save`.
    static var clearGeneration: Int {
        defaults.integer(forKey: clearGenerationKey)
    }

    private static var defaults: UserDefaults {
        #if DEBUG
        storageForTesting?.defaults ?? UserDefaults.standard
        #else
        UserDefaults.standard
        #endif
    }

    /// Delete All Data's durable intent to revoke the snapshot, written
    /// before its store deletes commit and removed once its commit or
    /// rollback has revoked it. While it is set nothing loads or saves. Its
    /// value names the process that wrote it: one left by another process
    /// is a wipe the app did not survive between its commit and that
    /// revocation, so the first load or save here finishes it before
    /// anything can hydrate the deleted totals.
    static let revocationPendingKey = "statsSnapshotRevocationPending_v1"
    private static let processToken = UUID().uuidString

    /// Delete All Data, before its store deletes: revokes the snapshot and
    /// holds every load and save off until `finishRevocation()`.
    static func beginRevocation() {
        publication.withLock { _ in
            defaults.set(processToken, forKey: revocationPendingKey)
            _ = revokeLocked()
        }
        postCleared()
    }

    /// Delete All Data, after its commit or rollback: revokes again what a
    /// compute admitted before the commit could still publish, then lets
    /// loads and saves through. False while a snapshot file remains.
    @discardableResult
    static func finishRevocation() -> Bool {
        let cleared = publication.withLock { _ -> Bool in
            let cleared = revokeLocked()
            defaults.removeObject(forKey: revocationPendingKey)
            return cleared
        }
        postCleared()
        return cleared
    }

    private static var revocationPendingLocked: Bool {
        defaults.string(forKey: revocationPendingKey) != nil
    }

    /// Finishes a revocation another process began; true when it did.
    private static func finishInterruptedRevocationLocked() -> Bool {
        guard let owner = defaults.string(forKey: revocationPendingKey),
              owner != processToken else { return false }
        _ = revokeLocked()
        defaults.removeObject(forKey: revocationPendingKey)
        return true
    }

    /// Moves the generation and removes every snapshot file, under the
    /// publication lock. False while a file is still on disk.
    private static func revokeLocked() -> Bool {
        defaults.set(clearGeneration + 1, forKey: clearGenerationKey)
        var cleared = true
        for url in [fileURL].compactMap({ $0 }) + legacyFileURLs {
            // Only a removal or an already-missing file counts as cleared:
            // `fileExists` is also false for a file it cannot reach.
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                logger.error("A stats snapshot file could not be removed.")
                cleared = false
            }
        }
        return cleared
    }

    private static func postCleared() {
        NotificationCenter.default.post(name: .statsSnapshotCleared, object: nil)
    }

    /// Persist the freshly computed aggregates. Called off-main after every
    /// successful Stats compute; best-effort (a failed write just means the
    /// next cold launch behaves like today's). A degraded result is refused:
    /// hydration must only ever show complete aggregates.
    ///
    /// Synchronous callers reserve and publish together. Asynchronous callers
    /// reserve a request on acceptance and pass it to the request overload.
    /// Both reject a request whose compute predates a wipe.
    static func save(
        _ aggregates: StatsAggregator.Aggregates,
        generation: Int,
        languageTag: String = AppLanguagePreference.currentTag()
    ) {
        guard let request = reserveSave(generation: generation) else { return }
        save(aggregates, request: request, languageTag: languageTag)
    }

    static func save(
        _ aggregates: StatsAggregator.Aggregates,
        request: SaveRequest,
        languageTag: String = AppLanguagePreference.currentTag()
    ) {
        guard aggregates.computeDegraded != true else {
            logger.error("Refusing to persist a degraded stats snapshot.")
            return
        }
        do {
            // Hydration skips date-sensitive memories; persist only the display cache.
            var diskAggregates = aggregates
            diskAggregates.onThisDayGroups = []
            let data = try JSONEncoder().encode(Snapshot(generation: request.generation, languageTag: languageTag, aggregates: diskAggregates))
            try publication.withLock { revisions in
                guard let url = fileURL, request.generation == clearGeneration,
                      revisions[url.path] == request.revision,
                      !revocationPendingLocked else { return }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                for legacy in legacyFileURLs { try? FileManager.default.removeItem(at: legacy) }
            }
        } catch {
            logger.error("Failed to persist stats snapshot: \(error.localizedDescription)")
        }
    }

    /// The last persisted aggregates, or nil (no snapshot yet, or a
    /// stale-shape/corrupt file — both mean "start empty like before").
    /// Never a degraded payload; nil `computeDegraded` (older files) is healthy.
    /// Nil while Delete All Data's revocation is pending.
    static func load(
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> StatsAggregator.Aggregates? {
        let (aggregates, recovered) = publication.withLock { _ -> (StatsAggregator.Aggregates?, Bool) in
            let recovered = finishInterruptedRevocationLocked()
            guard !revocationPendingLocked,
                  let url = fileURL,
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.languageTag == languageTag,
                  snapshot.generation == clearGeneration,
                  snapshot.aggregates.computeDegraded != true else { return (nil, recovered) }
            return (snapshot.aggregates, recovered)
        }
        if recovered { postCleared() }
        return aggregates
    }

    /// Drop the snapshot. Wired into Delete All Data — a wiped store must
    /// not resurrect its old totals for even a second on the next launch.
    ///
    /// The generation bump and deletion share the publication lock, so no
    /// writer can replace the file between the wipe decision and deletion.
    /// Posts `statsSnapshotCleared` after the bump: a clear need not touch any
    /// store type Stats observes (Delete Calendar Data runs in a
    /// `.plannedTrip` unit), yet it revokes the aggregates on screen.
    ///
    /// Returns false when a snapshot file is still on disk afterwards (a
    /// missing one is cleared), so Delete All Data can report the residue.
    @discardableResult
    static func clear() -> Bool {
        let cleared = publication.withLock { _ in revokeLocked() }
        postCleared()
        return cleared
    }
}

extension Notification.Name {
    /// Posted, on the clearing thread, after `StatsSnapshotStore.clear()`
    /// moved the snapshot-clear generation. Carries nothing: observers re-read
    /// `StatsSnapshotStore.clearGeneration`.
    nonisolated static let statsSnapshotCleared = Notification.Name("statsSnapshotCleared")
}
