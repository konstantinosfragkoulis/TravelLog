//
//  PinnedTripsStorage.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import Foundation
import Observation
import os.log

/// User's set of pinned (favorite) trip IDs, persisted via
/// `NSUbiquitousKeyValueStore` (iCloud Key-Value Storage) so a pin made
/// on one device shows up on every other device signed in to the same
/// iCloud account.
///
/// # Why iCloud KVS, not SwiftData / UserDefaults
///
/// - **UserDefaults** is local-only — a pin on the iPhone wouldn't show
///   on the iPad. The whole point of pinning is "this trip is important to
///   me," which is per-user state, not per-device state.
/// - **SwiftData / CloudKit** would work too but requires a schema bump
///   (V10) for a one-bool-per-trip field plus a CloudKit container
///   re-deploy. KVS sidesteps the schema chain entirely for ~3.6 KB of
///   per-user UUID strings (100 pins × 36 chars = well under the 1 MB
///   per-key, 1 MB total, 1024-key KVS limits).
///
/// # Sync timing
///
/// KVS is best-effort: a pin made on Device A may take seconds to
/// minutes to appear on Device B. `NSUbiquitousKeyValueStore.synchronize()`
/// is a hint to push sooner; the actual propagation runs on Apple's
/// infrastructure when convenient. The
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
/// observer below picks up remote changes and refreshes the in-memory
/// `pinnedIDs` set, which propagates to SwiftUI views via `@Observable`
/// tracking.
///
/// # Conflict resolution
///
/// Last-writer-wins. If Device A pins trip X and Device B unpins it at
/// the same time, the cloud merges arbitrarily (whichever write reaches
/// the server later). Pinning is rare and idempotent enough that
/// real-user conflicts are vanishingly unlikely; the cost of a
/// theoretical race is "the user sees the wrong state for a moment and
/// can re-tap the star."
///
/// # Threading
///
/// Class is `@MainActor` — `pinnedIDs` is read from SwiftUI views which
/// expect main-actor state. The `NSUbiquitousKeyValueStore` instance is
/// `nonisolated let` because notifications arrive on arbitrary queues;
/// `store.set` / `store.data` are thread-safe per Apple docs. The
/// external-change observer hops to MainActor before mutating
/// `pinnedIDs`.
@MainActor
@Observable
final class PinnedTripsStorage {

    static let shared = PinnedTripsStorage()

    /// Single key under which the JSON-encoded `[String]` of UUID strings
    /// lives. One key holds the entire set so external-change
    /// notifications fire when anything changes — KVS doesn't notify on
    /// individual UUID inserts/removes, so set-shaped storage is simpler
    /// than one-key-per-pin.
    private static let storeKey = "pinnedTripIDs"

    /// Main-actor isolated (inherits from the class). All reads / writes
    /// happen from `@MainActor` contexts — init, the user-facing
    /// pin/unpin methods, and `loadFromStore` (called from the
    /// notification observer via `Task { @MainActor in ... }`). The
    /// notification itself fires on an arbitrary queue, but we never
    /// touch `store` from the callback — only the Task body that hops
    /// to MainActor first does. `NSUbiquitousKeyValueStore` is
    /// thread-safe per Apple docs but not `Sendable`, so we keep its
    /// access main-isolated rather than cross-actor.
    private let store = NSUbiquitousKeyValueStore.default

    private let logger = Logger(subsystem: "com.travellog.app", category: "PinnedTripsStorage")

    /// Snapshot of pinned trip IDs. Updated on init, on every local
    /// pin/unpin, and on external-change notifications. Observers using
    /// SwiftUI's `@Observable` tracking auto-redraw when this changes.
    private(set) var pinnedIDs: Set<UUID> = []

    /// iCloud account replacements the observer has seen. Counted on the
    /// posting thread, so an edit that runs before the main-actor handler
    /// still adopts the new account instead of saving the old set into it.
    nonisolated private static let sharedAccountChanges = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private let accountChanges: OSAllocatedUnfairLock<Int>
    /// How many of those `pinnedIDs` already reflects.
    @ObservationIgnored private var adoptedAccountChanges = 0

    #if DEBUG
    private var testDefaults: UserDefaults?

    /// Isolated persistence for tests; never observes or writes the shared KVS.
    init(forTesting defaults: UserDefaults) {
        testDefaults = defaults
        accountChanges = OSAllocatedUnfairLock(initialState: 0)
        loadFromStore()
    }

    /// What the observer records when KVS reports an account change, before
    /// its main-actor handler has run.
    func noteAccountChangeForTesting() {
        accountChanges.withLock { $0 += 1 }
    }
    #endif

    private init() {
        accountChanges = Self.sharedAccountChanges
        loadFromStore()
        // Subscribe to remote-change notifications. Block-based API
        // avoids the `#selector` / NSObject inheritance dance — we
        // don't need a token to remove later because the singleton
        // lives for the app's lifetime.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: nil
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            // An account change replaced the local store with the new
            // account's values: adopt them, a missing key included, and never
            // save the previous account's set into it. Nothing is written.
            if reason == NSUbiquitousKeyValueStoreAccountChange {
                PinnedTripsStorage.sharedAccountChanges.withLock { $0 += 1 }
                Task { @MainActor in
                    PinnedTripsStorage.shared.adoptAccountChanges()
                }
                return
            }
            // Otherwise reconcile only on genuine server / initial-sync value
            // changes; a quota violation shouldn't reconcile.
            guard reason == NSUbiquitousKeyValueStoreServerChange
                || reason == NSUbiquitousKeyValueStoreInitialSyncChange else {
                return
            }
            // Use the static accessor instead of capturing self — keeps
            // the Swift 6 strict-concurrency checker happy (no `var self`
            // capture in a `@Sendable`-typed callback) and is safe because
            // the singleton is fully initialized by the time any
            // notification can fire (init has long since returned).
            Task { @MainActor in
                PinnedTripsStorage.shared.loadFromStore()
                // A pin that arrives AFTER healing dissolved its trip must
                // still protect it — the trip is parked in the dissolve
                // review queue, and this is the moment to bring it back.
                // No-op while the queue is empty.
                await HomeAreaHealing.rescueIfNeeded()
                // Likewise a pin for a duplicate this device already merged
                // away belongs on the trip that received its carry.
                await TripDeduplicator.rekeyCarriedFavourites(
                    modelContainer: AppDelegate.modelContainer,
                    defaults: .standard, pins: PinnedTripsStorage.shared)
            }
        }
        // Hint to KVS to fetch the latest remote state now. Doesn't
        // guarantee immediate propagation but speeds it up.
        store.synchronize()
    }

    // MARK: - Public surface

    func isPinned(_ tripID: UUID) -> Bool {
        pinnedIDs.contains(tripID)
    }

    func pin(_ tripID: UUID) {
        refreshBeforeEdit()
        guard !pinnedIDs.contains(tripID) else { return }
        pinnedIDs.insert(tripID)
        saveToStore()
    }

    func unpin(_ tripID: UUID) {
        refreshBeforeEdit()
        guard pinnedIDs.contains(tripID) else { return }
        pinnedIDs.remove(tripID)
        saveToStore()
    }

    func toggle(_ tripID: UUID) {
        // The intent is what the user saw: read before pin/unpin refresh, so
        // a delivered change to this trip cannot reverse it.
        if isPinned(tripID) {
            unpin(tripID)
        } else {
            pin(tripID)
        }
    }

    /// Backup-restore hook: favourites these trips too and unpins none.
    /// Returns how many were not favourites yet. The union is taken against
    /// the stored set as it is now: a remote change already in the local
    /// store whose notification has not run yet must not be overwritten.
    @discardableResult
    func merge(_ tripIDs: Set<UUID>) -> Int {
        guard !tripIDs.isEmpty else { return 0 }
        refreshBeforeEdit()
        let added = tripIDs.subtracting(pinnedIDs)
        guard !added.isEmpty else { return 0 }
        pinnedIDs.formUnion(added)
        saveToStore()
        return added.count
    }

    /// Adopts an account replacement the observer counted and this set does
    /// not reflect yet: the local store holds the new account's values, so
    /// its missing key means no favourites rather than not yet synced.
    func adoptAccountChanges() {
        let seen = accountChanges.withLock { $0 }
        guard seen != adoptedAccountChanges else { return }
        adoptedAccountChanges = seen
        loadFromStore(missingMeansEmpty: true)
        logger.info("PinnedTripsStorage adopted an iCloud account change.")
    }

    /// Every explicit edit starts from the current account's set as stored
    /// now: a delivered change whose notification has not run yet must not
    /// be overwritten by the whole cached set. A missing value keeps it.
    private func refreshBeforeEdit() {
        adoptAccountChanges()
        loadFromStore()
    }

    // MARK: - Persistence

    private func loadFromStore(missingMeansEmpty: Bool = false) {
        let storedData: Data?
        #if DEBUG
        if let testDefaults {
            storedData = testDefaults.data(forKey: Self.storeKey)
        } else {
            storedData = store.data(forKey: Self.storeKey)
        }
        #else
        storedData = store.data(forKey: Self.storeKey)
        #endif
        guard let data = storedData else {
            // No remote value present. This is NOT the same as "the user
            // cleared all pins": clearing writes an empty `[]` blob, so the key
            // stays present with empty contents (decoded to an empty set below).
            // A nil value means the key has not yet synced to this store
            // (initial iCloud sync pending) or the iCloud account just changed
            // and KVS reset its local cache. Wiping `pinnedIDs` here would
            // silently delete the user's pins on an account switch or before
            // first sync, so leave local state intact. Only an adopted account
            // replacement reads it as the new account's empty set.
            if missingMeansEmpty, !pinnedIDs.isEmpty { pinnedIDs = [] }
            return
        }
        let strings = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        let parsed = Set(strings.compactMap { UUID(uuidString: $0) })
        // Avoid spurious mutation when the parsed set matches the current
        // in-memory state — keeps `@Observable` from re-publishing
        // identical values on rapid sync notifications.
        if parsed != pinnedIDs {
            pinnedIDs = parsed
            logger.debug("PinnedTripsStorage loaded \(parsed.count) pin(s) from store.")
        }
    }

    private func saveToStore() {
        // Sorted for byte-stability — KVS does last-write-wins on the
        // raw blob, so deterministic ordering reduces phantom diffs
        // when two devices write semantically-equal sets.
        let strings = pinnedIDs.map(\.uuidString).sorted()
        guard let data = try? JSONEncoder().encode(strings) else {
            logger.error("PinnedTripsStorage failed to encode pinned IDs.")
            return
        }
        #if DEBUG
        if let testDefaults {
            testDefaults.set(data, forKey: Self.storeKey)
            return
        }
        #endif
        store.set(data, forKey: Self.storeKey)
        store.synchronize()
        logger.debug("PinnedTripsStorage saved \(strings.count) pin(s) to store.")
    }
}
