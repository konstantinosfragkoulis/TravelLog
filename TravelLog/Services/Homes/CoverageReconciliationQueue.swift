//
//  CoverageReconciliationQueue.swift
//  TravelLog
//
//  A Home, RoutinePlace or TemporaryHome coverage edit commits on the main
//  context, then a classifier unit reconciles history. This device-local
//  queue records each owed unit before the edit's save, so a kill or a failed
//  unit cannot lose it, and drops it only once the unit settles; launch and
//  activation drain the rest in Settings' order: reconcile, titles, heal.
//  The drain also queues work no local edit owes: a removed or live temporary
//  home whose evidence differs from what its last committed unit left. How
//  each owed temporary-home unit ended is kept for its card and detail.
//

import CryptoKit
import Foundation
import os.log
import SwiftData
import WidgetKit

enum CoverageReconciliationQueue {

    /// `["home|<uuid>", "routinePlace|<uuid>" or "temporaryHome|<uuid>": "<token uuid>"]`.
    nonisolated static let pendingKey = "pendingCoverageReconciliation_v1"

    /// Posted after every write of the pending queue or the temporary-home
    /// status records, so status lines refresh on these writes alone rather
    /// than on every UserDefaults change.
    nonisolated static let statusDidChangeNotification = Notification.Name(
        "CoverageReconciliationQueue.statusDidChange")

    static func postStatusDidChange() {
        NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
    }

    nonisolated enum Kind: String, Sendable {
        case home
        case routinePlace
        case temporaryHome

        /// Drain order: Homes, then routine places, then temporary homes.
        fileprivate var drainRank: Int {
            switch self {
            case .home: 0
            case .routinePlace: 1
            case .temporaryHome: 2
            }
        }
    }

    /// One owed reconciliation. A later edit of the same row replaces the
    /// token, so an older run can never drop the newer edit's entry.
    nonisolated struct Entry: Sendable, Equatable {
        let kind: Kind
        let id: UUID
        let token: UUID
    }

    /// UserDefaults is documented as thread-safe; the box lets the settle
    /// callback carry an injected suite across the classifier hop.
    private nonisolated struct Store: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static func entryKey(_ kind: Kind, _ id: UUID) -> String {
        "\(kind.rawValue)|\(id.uuidString)"
    }

    /// An entry recorded ahead of an edit's save, with the raw token it
    /// superseded. That token belongs to an earlier edit of the same row
    /// that already committed and may still owe its reconciliation.
    nonisolated struct Staged: Sendable, Equatable {
        let entry: Entry
        let superseded: String?
    }

    /// Records (or supersedes) the owed reconciliation for one row.
    @discardableResult
    static func enqueue(_ kind: Kind, id: UUID, defaults: UserDefaults = .standard) -> Entry {
        stage(kind, id: id, defaults: defaults).entry
    }

    /// Records (or supersedes) the owed reconciliation for one row ahead of
    /// its save, remembering the token it replaced for `withdraw`.
    static func stage(_ kind: Kind, id: UUID, defaults: UserDefaults = .standard) -> Staged {
        let entry = Entry(kind: kind, id: id, token: UUID())
        var stored = (defaults.dictionary(forKey: pendingKey) as? [String: String]) ?? [:]
        let key = entryKey(kind, id)
        let superseded = stored[key]
        stored[key] = entry.token.uuidString
        defaults.set(stored, forKey: pendingKey)
        postStatusDidChange()
        return Staged(entry: entry, superseded: superseded)
    }

    /// Undoes `stage` after the edit's save failed: puts back the earlier
    /// committed edit's token, or drops the entry when there was none. Only
    /// while the staged token still owns the row's slot. `complete` is for
    /// settled reconciliations; using it here would erase the earlier debt.
    static func withdraw(_ staged: Staged, defaults: UserDefaults = .standard) {
        var stored = (defaults.dictionary(forKey: pendingKey) as? [String: String]) ?? [:]
        let key = entryKey(staged.entry.kind, staged.entry.id)
        guard stored[key] == staged.entry.token.uuidString else { return }
        stored[key] = staged.superseded
        write(stored, defaults: defaults)
        if staged.entry.kind == .temporaryHome {
            pruneStatus(staged.entry.id, slot: staged.superseded, defaults: defaults)
        }
    }

    /// Drops `entry` only while it is still the row's current one.
    static func complete(_ entry: Entry, defaults: UserDefaults = .standard) {
        guard var stored = defaults.dictionary(forKey: pendingKey) as? [String: String] else { return }
        let key = entryKey(entry.kind, entry.id)
        guard stored[key] == entry.token.uuidString else { return }
        stored[key] = nil
        write(stored, defaults: defaults)
        if entry.kind == .temporaryHome { pruneStatus(entry.id, slot: nil, defaults: defaults) }
    }

    private static func write(_ stored: [String: String], defaults: UserDefaults) {
        if stored.isEmpty {
            defaults.removeObject(forKey: pendingKey)
        } else {
            defaults.set(stored, forKey: pendingKey)
        }
        postStatusDidChange()
    }

    /// Owed reconciliations, Homes first and temporary homes last, in a
    /// stable order. Malformed entries, and kinds this build does not know,
    /// are skipped and left in place.
    static func pending(defaults: UserDefaults = .standard) -> [Entry] {
        let stored = (defaults.dictionary(forKey: pendingKey) as? [String: String]) ?? [:]
        return stored.compactMap { key, value -> Entry? in
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let kind = Kind(rawValue: String(parts[0])),
                  let id = UUID(uuidString: String(parts[1])),
                  let token = UUID(uuidString: value) else { return nil }
            return Entry(kind: kind, id: id, token: token)
        }
        .sorted {
            ($0.kind.drainRank, $0.id.uuidString)
                < ($1.kind.drainRank, $1.id.uuidString)
        }
    }

    // MARK: - Removal discovery

    /// `["<temporary home uuid>": ["digest": <hex>, "at": <seconds since the reference date>]]`:
    /// the removal evidence the last committed unit for each removed id left,
    /// and when. Scheduling only: a lost hint costs one extra unit and never
    /// authorizes a change.
    nonisolated static let removalHintsKey = "temporaryHomeRemovalHints_v1"

    /// Evidence that does not change for this long is reconciled again, for
    /// what it cannot see (a stay's trip losing its protection).
    nonisolated static let removalHintLifetime: TimeInterval = 24 * 60 * 60

    /// What one removed temporary home still has on this device.
    nonisolated struct RemovalEvidence: Sendable, Equatable {
        let digest: String
        /// No home stay carries the id and no correction is keyed to it.
        let isEmpty: Bool
    }

    /// The evidence of every removed temporary home, keyed by id: the `.home`
    /// stays that carry its id, each by physical row with its override flag,
    /// trip and start, and the corrections keyed to it. Same-id stay twins
    /// are distinct rows, so a late twin changes the digest. With no removed
    /// id it reads nothing else.
    static func removalEvidence(in context: ModelContext) throws -> [UUID: RemovalEvidence] {
        var removedDescriptor = FetchDescriptor<TemporaryHome>(predicate: #Predicate { $0.removedAt != nil })
        removedDescriptor.propertiesToFetch = [\.id]
        let removed = Set(try context.fetch(removedDescriptor).map(\.id))
        guard !removed.isEmpty else { return [:] }
        let homeRaw = StayCategory.home.rawValue
        let stays = try context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == homeRaw && $0.temporaryHomeID != nil }))
        var overrideDescriptor = FetchDescriptor<HomeAreaOverride>()
        overrideDescriptor.propertiesToFetch = [\.id, \.homeID]
        let overrides = try context.fetch(overrideDescriptor)
        var lines: [UUID: [String]] = Dictionary(uniqueKeysWithValues: removed.map { ($0, []) })
        for stay in stays {
            guard let id = stay.temporaryHomeID, removed.contains(id) else { continue }
            lines[id, default: []].append([
                "stay", String(describing: stay.persistentModelID),
                stay.userOverridden ? "1" : "0",
                stay.trip?.id.uuidString ?? "",
                String(stay.startTime.timeIntervalSinceReferenceDate.bitPattern),
            ].joined(separator: "|"))
        }
        for override in overrides {
            guard let id = override.homeID, removed.contains(id) else { continue }
            lines[id, default: []].append("override|" + override.id.uuidString)
        }
        return lines.mapValues { entries in
            let digest = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return RemovalEvidence(digest: digest, isEmpty: entries.isEmpty)
        }
    }

    /// The stored hints, malformed elements skipped.
    static func removalHints(
        defaults: UserDefaults = .standard
    ) -> [UUID: (digest: String, at: Date)] {
        let stored = (defaults.dictionary(forKey: removalHintsKey) as? [String: [String: Any]]) ?? [:]
        var hints: [UUID: (digest: String, at: Date)] = [:]
        for (key, value) in stored {
            guard let id = UUID(uuidString: key),
                  let digest = value["digest"] as? String,
                  let at = value["at"] as? Double else { continue }
            hints[id] = (digest, Date(timeIntervalSinceReferenceDate: at))
        }
        return hints
    }

    /// Records what a committed unit left for each id, at `now`.
    static func recordRemovalHints(
        _ evidence: [UUID: RemovalEvidence], at now: Date,
        defaults: UserDefaults = .standard
    ) {
        guard !evidence.isEmpty else { return }
        var stored = defaults.dictionary(forKey: removalHintsKey) ?? [:]
        for (id, value) in evidence {
            stored[id.uuidString] = [
                "digest": value.digest, "at": now.timeIntervalSinceReferenceDate,
            ] as [String: Any]
        }
        defaults.set(stored, forKey: removalHintsKey)
    }

    /// Forgets the hints of `ids`, so the next drain reconciles each again.
    static func clearRemovalHints(_ ids: Set<UUID>, defaults: UserDefaults = .standard) {
        guard var stored = defaults.dictionary(forKey: removalHintsKey),
              ids.contains(where: { stored[$0.uuidString] != nil }) else { return }
        for id in ids { stored[id.uuidString] = nil }
        defaults.set(stored, forKey: removalHintsKey)
    }

    /// Queues a reconciliation for every removed id whose evidence has no
    /// hint (first sight), differs from its hint, or is non-empty and was
    /// last reconciled over `removalHintLifetime` ago. An id already owed is
    /// left as it is.
    /// - Returns: false when the evidence could not be read; nothing is queued then.
    private static func stageRemovalWork(
        defaults: UserDefaults, stages: Stages, now: Date
    ) -> Bool {
        guard let evidence = stages.removalEvidence() else { return false }
        guard !evidence.isEmpty else { return true }
        let hints = removalHints(defaults: defaults)
        let owed = Set(pending(defaults: defaults).filter { $0.kind == .temporaryHome }.map(\.id))
        for (id, current) in evidence.sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where !owed.contains(id) {
            let due: Bool
            if let hint = hints[id] {
                due = hint.digest != current.digest
                    || (!current.isEmpty && now.timeIntervalSince(hint.at) > removalHintLifetime)
            } else {
                due = true
            }
            if due { _ = stage(.temporaryHome, id: id, defaults: defaults) }
        }
        return true
    }

    // MARK: - Live discovery

    /// What the last committed unit of each live temporary home processed and
    /// left, by id, in a device-local JSON file in Application Support (the
    /// `DissolvedTripQueue` pattern). Scheduling state only: a lost or
    /// unreadable file replays each unit once, harmlessly, and never
    /// authorizes a change.
    nonisolated enum Acknowledgements {

        nonisolated struct Entry: Codable, Sendable, Equatable {
            /// The digest of what the unit read and left
            /// (`TripClassifier.temporaryHomeDigests`).
            let digest: String
            let at: Date
            /// When a unit for this id first left a stamp of a newer copy
            /// than the one it read in place; nil while none waits.
            var deferredSince: Date?
        }

        /// How long a deferred stamp waits before the unit reissues its
        /// copy above it (the losing-branch rule), and before the drain
        /// retries deferred work nothing new has touched.
        static let deferralBound: TimeInterval = 24 * 60 * 60

        private static let fileName = "temporary-home-acknowledgements-v1.json"
        private static let logger = Logger(
            subsystem: "com.travellog.app", category: "CoverageReconciliationQueue")
        /// The classifier actor writes and the main actor reads and clears.
        private static let lock = NSLock()

        static func fileURL(in directory: URL? = nil) -> URL? {
            if let directory { return directory.appendingPathComponent(fileName) }
            return FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first?.appendingPathComponent(fileName)
        }

        /// Every entry; empty when the file is missing or unreadable.
        static func load(from directory: URL? = nil) -> [UUID: Entry] {
            lock.lock()
            defer { lock.unlock() }
            return loadUnlocked(from: directory)
        }

        private static func loadUnlocked(from directory: URL?) -> [UUID: Entry] {
            guard let url = fileURL(in: directory),
                  let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
            else { return [:] }
            var entries: [UUID: Entry] = [:]
            for (key, entry) in stored {
                if let id = UUID(uuidString: key) { entries[id] = entry }
            }
            return entries
        }

        /// Records what a committed unit for `id` processed and left. A
        /// deferring unit keeps the first deferral's time; one that deferred
        /// nothing clears it.
        static func record(
            _ id: UUID, digest: String, deferred: Bool, at now: Date,
            in directory: URL? = nil
        ) {
            lock.lock()
            defer { lock.unlock() }
            var entries = loadUnlocked(from: directory)
            let since = deferred ? entries[id]?.deferredSince ?? now : nil
            entries[id] = Entry(digest: digest, at: now, deferredSince: since)
            guard let url = fileURL(in: directory) else { return }
            do {
                let stored = Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
                let data = try JSONEncoder().encode(stored)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Temporary-home acknowledgement not recorded: \(error.localizedDescription)")
            }
        }

        /// Delete All Data clears it after its commit: it describes the old store.
        static func clear(in directory: URL? = nil) throws {
            lock.lock()
            defer { lock.unlock() }
            guard let url = fileURL(in: directory) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                return
            }
        }
    }

    /// Skips a discovery read that could only find what the last one found:
    /// same store generation over the digest's tables (launches, pushes,
    /// imports and gated writes move it), favourites and debt, no unit run
    /// since, younger than `lifetime`. Scheduling only.
    @MainActor
    final class DiscoveryThrottle {
        /// What a digest reads besides the clock.
        nonisolated struct Watermark: Equatable, Sendable {
            let storeGeneration: Int
            let favourites: Set<UUID>
        }

        static let shared = DiscoveryThrottle {
            DiscoveryThrottle.watermark(
                tracker: .shared, favourites: PinnedTripsStorage.shared.pinnedIDs)
        }

        /// The tables a digest reads: stays, trips, the declarations and
        /// their corrections, the photo rows that protect a trip, and the
        /// visits that qualify a home stay.
        static let tables: StoreChange = [
            .stay, .trip, .temporaryHome, .homeAreaOverride, .hiddenPhoto, .pinnedPhoto, .visit,
        ]

        /// An unchanged store is read again after this long, for a write
        /// its change signal missed.
        static let lifetime: TimeInterval = 24 * 60 * 60

        /// Nil while a write to one of `tables` awaits its flush: unknown.
        static func watermark(tracker: StoreChangeTracker, favourites: Set<UUID>) -> Watermark? {
            guard !tracker.hasPendingBump(tables) else { return nil }
            return Watermark(storeGeneration: tracker.token(for: tables), favourites: favourites)
        }

        private let watermark: @MainActor () -> Watermark?
        private var last: (watermark: Watermark, owed: Set<UUID>, at: Date, digests: [UUID: String])?

        init(watermark: @escaping @MainActor () -> Watermark?) {
            self.watermark = watermark
        }

        /// A unit ran: the next drain reads.
        func invalidate() {
            last = nil
        }

        /// The last read's digests while nothing they depend on moved, else
        /// `read()`'s, remembered when it succeeded. `owed` are the tokens of
        /// the temporary-home entries owed now.
        func digests(
            owed: Set<UUID>, now: Date, read: () async -> [UUID: String]?
        ) async -> [UUID: String]? {
            let mark = watermark()
            if let mark, let last, last.watermark == mark, last.owed == owed,
               now >= last.at, now.timeIntervalSince(last.at) < Self.lifetime {
                return last.digests
            }
            let digests = await read()
            if let mark, let digests {
                last = (watermark: mark, owed: owed, at: now, digests: digests)
            } else {
                last = nil
            }
            return digests
        }
    }

    // MARK: - Temporary home status

    /// What the card and detail say about a temporary home's owed
    /// reconciliation.
    nonisolated enum TemporaryHomeStatus: Equatable, Sendable {
        /// Owed, and queued or running.
        case updating
        /// Its last unit left a newer copy's stamps in place: it waits for
        /// that copy, or for the reissue a day after the first deferral.
        case waiting
        /// Its last unit failed; the debt stays for Try Again or the next drain.
        case failed
    }

    /// `["<temporary home uuid>": ["token": "<entry token>", "status": "waiting" | "failed"]]`:
    /// how the last unit of each owed entry ended, on this device. A record
    /// speaks only for the entry whose token it names, so a later edit or a
    /// retry reads as updating until its own unit ends.
    nonisolated static let temporaryHomeStatusKey = "temporaryHomeReconciliationStatus_v1"

    /// Nil when nothing is owed for `id`.
    static func temporaryHomeStatus(
        id: UUID, defaults: UserDefaults = .standard
    ) -> TemporaryHomeStatus? {
        temporaryHomeStatuses(ids: [id], defaults: defaults)[id]
    }

    /// `temporaryHomeStatus(id:)` for several ids, reading the queue and the
    /// status records once. An id owing nothing has no entry.
    static func temporaryHomeStatuses(
        ids: Set<UUID>, defaults: UserDefaults = .standard
    ) -> [UUID: TemporaryHomeStatus] {
        guard !ids.isEmpty else { return [:] }
        let owed = pending(defaults: defaults).filter { $0.kind == .temporaryHome && ids.contains($0.id) }
        guard !owed.isEmpty else { return [:] }
        let records = statusRecords(defaults)
        var statuses: [UUID: TemporaryHomeStatus] = [:]
        for entry in owed where statuses[entry.id] == nil {
            let record = records[entry.id.uuidString]
            guard record?["token"] == entry.token.uuidString else {
                statuses[entry.id] = .updating
                continue
            }
            switch record?["status"] {
            case "waiting": statuses[entry.id] = .waiting
            case "failed": statuses[entry.id] = .failed
            default: statuses[entry.id] = .updating
            }
        }
        return statuses
    }

    /// Records how the unit for `entry` ended, while `entry` still owns its
    /// row's slot: a deferral is waiting, a failure failed, and a commit or
    /// a cancelled unit (one that never ran) leaves no record.
    /// - Returns: whether the record changed.
    @discardableResult
    static func recordTemporaryHomeOutcome(
        _ outcome: TripClassifier.TemporaryHomeReconciliationOutcome, for entry: Entry,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let status: String?
        switch outcome {
        case .deferred: status = "waiting"
        case .failed: status = "failed"
        case .committed, .cancelled: status = nil
        }
        return writeStatus(status, for: entry, defaults: defaults)
    }

    /// Try Again: queues the temporary home afresh, so it reads as updating,
    /// and drains.
    static func retryTemporaryHome(id: UUID) async {
        await retryTemporaryHome(id: id, defaults: .standard, stages: .live)
    }

    static func retryTemporaryHome(id: UUID, defaults: UserDefaults, stages: Stages) async {
        _ = stage(.temporaryHome, id: id, defaults: defaults)
        stages.publishTemporaryHomeStatus()
        await drainIfNeeded(defaults: defaults, stages: stages)
    }

    private static func statusRecords(_ defaults: UserDefaults) -> [String: [String: String]] {
        (defaults.dictionary(forKey: temporaryHomeStatusKey) as? [String: [String: String]]) ?? [:]
    }

    private static func writeStatus(
        _ status: String?, for entry: Entry, defaults: UserDefaults
    ) -> Bool {
        let stored = (defaults.dictionary(forKey: pendingKey) as? [String: String]) ?? [:]
        guard entry.kind == .temporaryHome,
              stored[entryKey(entry.kind, entry.id)] == entry.token.uuidString else { return false }
        var records = statusRecords(defaults)
        let record = status.map { ["token": entry.token.uuidString, "status": $0] }
        guard records[entry.id.uuidString] != record else { return false }
        records[entry.id.uuidString] = record
        writeStatusRecords(records, defaults: defaults)
        return true
    }

    /// Drops `id`'s record unless it names the entry its slot holds now.
    private static func pruneStatus(_ id: UUID, slot: String?, defaults: UserDefaults) {
        var records = statusRecords(defaults)
        guard let record = records[id.uuidString], record["token"] != slot else { return }
        records[id.uuidString] = nil
        writeStatusRecords(records, defaults: defaults)
    }

    private static func writeStatusRecords(
        _ records: [String: [String: String]], defaults: UserDefaults
    ) {
        if records.isEmpty {
            defaults.removeObject(forKey: temporaryHomeStatusKey)
        } else {
            defaults.set(records, forKey: temporaryHomeStatusKey)
        }
        postStatusDidChange()
    }

    /// Queues a reconciliation for every live temporary home whose digest has
    /// no acknowledgement (first sight) or differs from it. An id already
    /// owed is left as it is.
    private static func stageLiveWork(
        _ digests: [UUID: String], acknowledged: [UUID: Acknowledgements.Entry],
        defaults: UserDefaults
    ) {
        let owed = Set(pending(defaults: defaults).filter { $0.kind == .temporaryHome }.map(\.id))
        for (id, digest) in digests.sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where !owed.contains(id) && acknowledged[id]?.digest != digest {
            _ = stage(.temporaryHome, id: id, defaults: defaults)
        }
    }

    /// The drain's collaborators; tests substitute them.
    struct Stages {
        var applyHome: @MainActor @Sendable (
            UUID, _ onSettled: @escaping @MainActor @Sendable () -> Void
        ) async -> TripClassifier.CoverageReconciliationOutcome
        var applyRoutinePlace: @MainActor @Sendable (
            UUID, _ onSettled: @escaping @MainActor @Sendable () -> Void
        ) async -> TripClassifier.CoverageReconciliationOutcome
        /// Unwired, it reports failure, so the entry stays owed.
        var applyTemporaryHome: @MainActor @Sendable (
            UUID, _ onSettled: @escaping @MainActor @Sendable () -> Void
        ) async -> TripClassifier.TemporaryHomeReconciliationOutcome = { _, _ in .failed }
        var generateLocalizedTitles: @MainActor @Sendable () async -> Void
        var publish: @MainActor @Sendable (_ homes: Bool, _ routinePlaces: Bool) -> Void
        /// Publication after a temporary-home reconciliation committed.
        var publishTemporaryHomes: @MainActor @Sendable () -> Void = {}
        var heal: @MainActor @Sendable () async -> Void
        /// False while the app runs on the in-memory fallback container
        /// (the persistent store failed to open). Every queued row reads
        /// as missing there, which would settle and drop markers the real
        /// store still needs.
        var isPersistentStore: @MainActor @Sendable () -> Bool
        /// The evidence of every removed temporary home (`removalEvidence(in:)`),
        /// nil when the read failed. Unwired, the store has no removed one.
        var removalEvidence: @MainActor @Sendable () -> [UUID: RemovalEvidence]? = { [:] }
        /// The digest of every live temporary home
        /// (`TripClassifier.temporaryHomeDiscoveryDigests`), nil when the read
        /// failed. Unwired, the store has no live one.
        var discoveryDigests: @MainActor @Sendable () async -> [UUID: String]? = { [:] }
        /// Where `applyTemporaryHome` acknowledges its units
        /// (`Acknowledgements`); nil is Application Support.
        var acknowledgementDirectory: URL? = nil
        /// Skips unchanged discovery reads; nil reads on every drain.
        var discoveryThrottle: DiscoveryThrottle? = nil
        /// Publication of a changed `temporaryHomeStatus` that no
        /// `publishTemporaryHomes` carried.
        var publishTemporaryHomeStatus: @MainActor @Sendable () -> Void = {}
        /// Keep as One Trip on this device's split archives of the removed
        /// temporary homes whose units committed
        /// (`HomeAreaHealing.keepSplitTrips`), returning the ids whose putting
        /// back could not finish. Unwired, it keeps none.
        var keepSplitTrips: @MainActor @Sendable (_ removedIDs: Set<UUID>) async -> Set<UUID> = { _ in [] }
        /// Whether automatic home or routine stays no place claims any more
        /// wait here (a place edited on another device, or history that synced
        /// in after this device's edit settled), nil when unreadable
        /// (`TripClassifier.hasStaleOrdinaryPlaceStays`). Unwired, none do.
        var staleOrdinaryPlaceStays: @MainActor @Sendable () async -> Bool? = { false }
        /// Frees them for the next pass to judge again
        /// (`TripClassifier.releaseStaleOrdinaryPlaceStays`).
        var releaseStaleOrdinaryPlaceStays: @MainActor @Sendable ()
            async -> TripClassifier.CoverageReconciliationOutcome = { .committed(resetCount: 0) }

        static var live: Stages {
            Stages(
                applyHome: { id, onSettled in
                    await AppDelegate.tripClassifier.applyHomeChange(
                        homeID: id, onSettled: onSettled)
                },
                applyRoutinePlace: { id, onSettled in
                    await AppDelegate.tripClassifier.applyRoutinePlaceChange(
                        placeID: id, onSettled: onSettled)
                },
                applyTemporaryHome: { id, onSettled in
                    // A replay knows only the row: the classifier reads the
                    // favorites inside its unit, on the main actor.
                    await AppDelegate.tripClassifier.applyTemporaryHomeChange(
                        temporaryHomeID: id,
                        pinnedTripIDs: { PinnedTripsStorage.shared.pinnedIDs },
                        onSettled: onSettled)
                },
                generateLocalizedTitles: {
                    _ = await AppDelegate.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                },
                publish: { homes, routinePlaces in
                    var changes: StoreChange = [.stay, .trip]
                    if homes { changes.insert(.home) }
                    if routinePlaces { changes.insert(.routinePlace) }
                    StoreChangeTracker.shared.bump(changes)
                    WidgetCenter.shared.reloadAllTimelines()
                },
                publishTemporaryHomes: {
                    StoreChangeTracker.shared.bump([.temporaryHome, .stay, .trip])
                    WidgetCenter.shared.reloadAllTimelines()
                },
                heal: { _ = await HomeAreaHealing.healIfNeeded() },
                isPersistentStore: {
                    !AppDelegate.modelContainer.configurations.contains(where: \.isStoredInMemoryOnly)
                },
                removalEvidence: {
                    try? CoverageReconciliationQueue.removalEvidence(
                        in: ModelContext(AppDelegate.modelContainer))
                },
                discoveryDigests: {
                    // With no live temporary home there is nothing to wait for the classifier for.
                    let anyLive = try? ModelContext(AppDelegate.modelContainer).fetchCount(
                        FetchDescriptor<TemporaryHome>(predicate: #Predicate { $0.removedAt == nil }))
                    guard let anyLive else { return nil }
                    guard anyLive > 0 else { return [:] }
                    return await AppDelegate.tripClassifier.temporaryHomeDiscoveryDigests(
                        pinnedTripIDs: PinnedTripsStorage.shared.pinnedIDs)
                },
                discoveryThrottle: .shared,
                publishTemporaryHomeStatus: { StoreChangeTracker.shared.bump([.temporaryHome]) },
                keepSplitTrips: { await HomeAreaHealing.keepSplitTrips(splitBy: $0) },
                staleOrdinaryPlaceStays: {
                    await AppDelegate.tripClassifier.hasStaleOrdinaryPlaceStays()
                },
                releaseStaleOrdinaryPlaceStays: {
                    await AppDelegate.tripClassifier.releaseStaleOrdinaryPlaceStays()
                }
            )
        }
    }

    private static var isDraining = false

    /// The receiving side of a Home or routine-place change: the units above
    /// run where the place was edited, so stays another device's edit (or late
    /// history) left claimed by no place are freed here, after this device's
    /// own owed units. Whether nothing is left owed, and whether any were freed.
    private static func releaseStaleOrdinaryPlaceStays(
        stages: Stages
    ) async -> (settled: Bool, released: Bool) {
        guard !Task.isCancelled else { return (false, false) }
        guard let stale = await stages.staleOrdinaryPlaceStays() else { return (false, false) }
        guard stale else { return (true, false) }
        let outcome = await stages.releaseStaleOrdinaryPlaceStays()
        return (outcome.isSettled, outcome.resetCount > 0)
    }

    /// Runs every owed reconciliation after queueing the removal and live work
    /// the store shows; call outside any gate. A deferred temporary home keeps
    /// its debt and runs again once its digest changes or
    /// `Acknowledgements.deferralBound` passes. False while anything is still
    /// owed: failed, cancelled, deferred, another drain running, unreadable
    /// evidence, or the in-memory fallback store (markers kept for a later launch).
    @discardableResult
    static func drainIfNeeded(
        defaults: UserDefaults = .standard,
        stages: Stages = .live
    ) async -> Bool {
        guard !isDraining else { return false }
        let now = Date.now
        let isPersistentStore = stages.isPersistentStore()
        // The fallback store holds no row worth trusting.
        var discovered = isPersistentStore
            ? stageRemovalWork(defaults: defaults, stages: stages, now: now) : true
        var digests: [UUID: String] = [:]
        var acknowledged: [UUID: Acknowledgements.Entry] = [:]
        if isPersistentStore {
            // Read before this drain takes its turn: the read waits for the
            // classifier. One that could only find what the last found is not made.
            let owed = Set(pending(defaults: defaults).filter { $0.kind == .temporaryHome }.map(\.token))
            let found: [UUID: String]?
            if let throttle = stages.discoveryThrottle {
                found = await throttle.digests(owed: owed, now: now) { await stages.discoveryDigests() }
            } else {
                found = await stages.discoveryDigests()
            }
            if let read = found {
                digests = read
                if !read.isEmpty {
                    acknowledged = Acknowledgements.load(from: stages.acknowledgementDirectory)
                    stageLiveWork(read, acknowledged: acknowledged, defaults: defaults)
                }
            } else {
                discovered = false
            }
            // Another drain may have started while this one read.
            guard !isDraining else { return false }
        }
        let entries = pending(defaults: defaults)
        guard !entries.isEmpty else {
            guard isPersistentStore else { return discovered }
            // With no entry to guard this does not take the drain: the look
            // and the release wait for the classifier, whose latch and gate
            // already run them one at a time, and an edit's drain must not
            // find the drain taken meanwhile.
            guard let stale = await stages.staleOrdinaryPlaceStays() else { return false }
            guard stale else { return discovered }
            let outcome = await stages.releaseStaleOrdinaryPlaceStays()
            if outcome.resetCount > 0 {
                await stages.generateLocalizedTitles()
                stages.publish(true, true)
                await stages.heal()
            }
            return discovered && outcome.isSettled
        }
        guard isPersistentStore else { return false }
        isDraining = true
        defer { isDraining = false }

        let store = Store(defaults: defaults)
        var reconciledHome = false
        var reconciledRoutinePlace = false
        var reconciledTemporaryHome = false
        var committedTemporaryHomeIDs: Set<UUID> = []
        var ranUnit = false
        var statusChanged = false
        var allSettled = discovered
        for entry in entries {
            guard !Task.isCancelled else {
                allSettled = false
                break
            }
            // Deferred work nothing has touched since waits out its bound.
            if entry.kind == .temporaryHome,
               let acknowledgement = acknowledged[entry.id],
               let since = acknowledgement.deferredSince,
               digests[entry.id] == acknowledgement.digest,
               now.timeIntervalSince(since) < Acknowledgements.deferralBound {
                allSettled = false
                if writeStatus("waiting", for: entry, defaults: defaults) { statusChanged = true }
                continue
            }
            ranUnit = true
            // A temporary home's hint from an earlier drain goes before its
            // entry, so an exit or a failure between here and the hints
            // recorded below leaves neither and the next drain runs it again.
            let settle: @MainActor @Sendable () -> Void = {
                if entry.kind == .temporaryHome {
                    CoverageReconciliationQueue.clearRemovalHints([entry.id], defaults: store.defaults)
                }
                CoverageReconciliationQueue.complete(entry, defaults: store.defaults)
            }
            let settled: Bool
            let committed: Bool
            switch entry.kind {
            case .home, .routinePlace:
                let outcome = await (entry.kind == .home
                    ? stages.applyHome(entry.id, settle)
                    : stages.applyRoutinePlace(entry.id, settle))
                settled = outcome.isSettled
                // A deferring unit commits too but keeps its debt.
                committed = outcome.didCommit
            case .temporaryHome:
                // Updating while its unit runs, then how that unit ended.
                if writeStatus(nil, for: entry, defaults: defaults) { statusChanged = true }
                // A removed row still runs its reverse pass and commits. A
                // deferring unit commits too but keeps its debt.
                let outcome = await stages.applyTemporaryHome(entry.id, settle)
                if recordTemporaryHomeOutcome(outcome, for: entry, defaults: defaults) {
                    statusChanged = true
                }
                settled = outcome.isSettled
                committed = outcome.didCommit
                if committed { committedTemporaryHomeIDs.insert(entry.id) }
            }
            if settled { settle() } else { allSettled = false }
            guard committed else { continue }
            switch entry.kind {
            case .home: reconciledHome = true
            case .routinePlace: reconciledRoutinePlace = true
            case .temporaryHome: reconciledTemporaryHome = true
            }
        }
        // What the units left for the removed ids among them, read after
        // their commits. A failed read records nothing: the next drain
        // reconciles them once more. First each trip their covering split on
        // this device comes back as Keep as One Trip would put it back, each
        // in its own gate unit, before the publications below; an id whose
        // putting back could not finish records nothing either.
        if !committedTemporaryHomeIDs.isEmpty, let evidence = stages.removalEvidence() {
            let removed = committedTemporaryHomeIDs.filter { evidence[$0] != nil }
            var unfinished: Set<UUID> = []
            if !removed.isEmpty {
                unfinished = await stages.keepSplitTrips(removed)
            }
            if !unfinished.isEmpty { allSettled = false }
            recordRemovalHints(
                evidence.filter { committedTemporaryHomeIDs.contains($0.key) && !unfinished.contains($0.key) },
                at: .now, defaults: defaults)
        }
        let swept = await releaseStaleOrdinaryPlaceStays(stages: stages)
        if !swept.settled { allSettled = false }
        if swept.released {
            reconciledHome = true
            reconciledRoutinePlace = true
        }
        // What the units changed is the next drain's to read.
        if ranUnit || swept.released { stages.discoveryThrottle?.invalidate() }
        if statusChanged, !reconciledTemporaryHome { stages.publishTemporaryHomeStatus() }
        guard reconciledHome || reconciledRoutinePlace || reconciledTemporaryHome else {
            return allSettled
        }
        await stages.generateLocalizedTitles()
        if reconciledHome || reconciledRoutinePlace {
            stages.publish(reconciledHome, reconciledRoutinePlace)
        }
        if reconciledTemporaryHome { stages.publishTemporaryHomes() }
        if reconciledHome || reconciledTemporaryHome { await stages.heal() }
        return allSettled
    }
}
