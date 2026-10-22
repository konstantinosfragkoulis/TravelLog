//
//  TripDeduplicator.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

/// Converges duplicate `Trip` rows left behind by two devices assembling the
/// same journey before CloudKit sync settles.
///
/// # How a duplicate arises
///
/// Stage 2 saves stays as `.destination` with `trip == nil` per model batch,
/// and assembly attaches them in a later save. A second device whose pipeline
/// runs inside that window sees tripless destination stays and mints its own
/// `Trip` (assembly always creates a fresh UUID). Both devices then close the
/// journey at the same homecoming, and every stay's to-one `trip` link
/// converges on ONE of the two rows. The other becomes a completed trip with
/// zero stays — a blank card that nothing else removes: assembly rebuilds only
/// the ongoing row, and every importer deletes the empties it creates itself.
///
/// # The rule
///
/// A completed trip with no stays is a possible ghost. Each physical local
/// row gets `ghostGracePeriod` from its own first empty observation; legacy
/// UUID observations start a fresh grace and, with iCloud on, a successful
/// CloudKit import completed past it. An unannotated empty row can then
/// be removed; carrying user data requires exactly one populated, completed
/// counterpart with identical dates and meaningful geographic evidence.
/// Overlap alone cannot establish the same journey for a carry.
/// A store with completed trips but zero stays is treated as mid-sync, and
/// fetch failures never mean "nothing there".
///
/// Before deleting, carry the losing row's userEdited marker, a custom name
/// the winner lacks, and hidden/pinned photo rows. Conflicting custom names,
/// missing or ambiguous counterparts with user data, and annotation-fetch
/// failures retain the ghost and its observation time for a later sweep.
/// Favourites are rechecked on the main actor before the deletion batch,
/// with no suspension through its save. Newly pinned rows wait for a later
/// sweep. After that recheck the sweep re-reads which candidate UUIDs a
/// populated twin holds: a twin that synced in during the wait owns the
/// ghost's photo rows, so no prepared carry applies, and a failed re-read
/// retains every candidate. The worker does not hold the main actor, so a
/// pin can still land between the recheck and the save; the post-save pass
/// reads live pins, so that pin moves to the carry winner or is removed with
/// its deleted empty row. After saving, the caller re-keys carries and removes dangling pins,
/// preserving a pin when another physical row with that UUID survives.
/// Every carry is also logged before its save, and each production sweep
/// and pin sync moves a favourite still keyed to a deleted, carried ghost
/// onto its winner: the process can end before that reconciliation, and a
/// device that had not yet seen the deletion can pin the ghost afterwards.
/// `PhotoAnnotationDeduplicator.removeOrphans` replays the same log for a
/// hidden or pinned photo row that syncs in keyed to the ghost. A ghost
/// deleted without a winner leaves such a pin or row nowhere to go. The log
/// is device-local, so only the device that carried can replay it.
///
/// Open trips are never touched — assembly owns them and already converges
/// multiple open rows to one deterministic survivor.
nonisolated enum TripDeduplicator {

    private static let logger = Logger(subsystem: "com.travellog.app", category: "TripDedup")
    private static let isRunning = OSAllocatedUnfairLock(initialState: false)

    /// How long a completed trip must stay empty on this device before it is
    /// treated as a lost duplicate rather than a row whose stays are in flight.
    static let ghostGracePeriod: TimeInterval = 24 * 60 * 60

    /// Device-local `[physicalRowKey: firstSeenEmptyEpoch]`. Keeping the defaults
    /// key lets the next healthy sweep prune legacy UUID-only entries as well.
    static let firstObservedGhostsKey = "tripGhostFirstObserved_v1"

    /// Device-local `"ghostUUID winnerUUID"` entries, oldest first, one per
    /// saved carry. Kept after reconciliation because a pin or a hidden or
    /// pinned photo row can sync in later. Carries need two devices minting
    /// one journey, so the cap only bounds a pathological store. Delete
    /// Everything clears it.
    static let carriedFavouritesKey = "tripGhostCarries_v1"
    static let carriedFavouritesLimit = 256

    /// Sorted-key JSON of the saved PersistentIdentifier, base64 encoded with a
    /// namespace prefix. The identifier includes local store/row identity and
    /// remains stable across launches for the same saved row in the same store.
    /// A replaced store or changed encoding conservatively starts fresh grace.
    static func observationKey(for identifier: PersistentIdentifier) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "row:" + (try encoder.encode(identifier)).base64EncodedString()
    }

    /// A favourite that moved from a deleted ghost to its winner.
    nonisolated struct CarriedFavourite: Sendable, Equatable {
        let ghostID: UUID
        let winnerID: UUID
    }

    nonisolated struct Outcome: Sendable, Equatable {
        var deleted = 0
        var observed = 0
        var carried: [CarriedFavourite] = []
        /// UUIDs deleted by this sweep; another physical row may still share one.
        var deletedIDs: Set<UUID> = []
        /// The sweep did not run to its end (single-flight, deferral, fetch or save).
        var incomplete = false
    }

    #if DEBUG
    @MainActor static var afterFavouriteSnapshotForTesting: (() -> Void)?
    @MainActor static var afterSaveForTesting: (() -> Void)?
    @MainActor static var beforeFavouriteRecheckForTesting: ((Set<UUID>, Int) -> Void)?
    @TaskLocal static var ownershipReadFailsForTesting = false
    #endif

    /// False when the sweep did not run to its end.
    @discardableResult
    static func deduplicateAll(modelContainer: ModelContainer) async -> Bool {
        let outcome = await deduplicateAll(modelContainer: modelContainer, now: .now,
                                           defaults: .standard, pins: PinnedTripsStorage.shared)
        return !outcome.incomplete
    }

    /// Exercises the production favourite snapshot and reconciliation with isolated storage.
    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer, now: Date, defaults: UserDefaults,
        pins: PinnedTripsStorage
    ) async -> Outcome {
        let rekeyed = await rekeyCarriedFavourites(
            modelContainer: modelContainer, defaults: defaults, pins: pins)
        let favouriteIDs = await MainActor.run { pins.pinnedIDs }
        #if DEBUG
        await MainActor.run { afterFavouriteSnapshotForTesting?() }
        #endif
        var outcome = await deduplicateAll(
            modelContainer: modelContainer, now: now, defaults: defaults,
            favouriteIDs: favouriteIDs, livePins: pins)
        if !rekeyed { outcome.incomplete = true }
        #if DEBUG
        if outcome.deleted > 0 {
            await MainActor.run { afterSaveForTesting?() }
        }
        #endif
        guard outcome.deleted > 0 else { return outcome }
        let removedFavouriteIDs: Set<UUID>
        do {
            // A twin can arrive during the sweep. Check a fresh context after
            // save, including open rows, before removing any UUID-keyed pin.
            let context = ModelContext(modelContainer)
            let deletedIDs = Array(outcome.deletedIDs)
            let survivors = try context.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { deletedIDs.contains($0.id) }))
            removedFavouriteIDs = outcome.deletedIDs.subtracting(survivors.map(\.id))
        } catch {
            logger.error("Trip ghost sweep: survivor fetch failed (\(error.localizedDescription)); retaining favourites.")
            removedFavouriteIDs = []
            outcome.incomplete = true
        }
        await MainActor.run { [outcome] in
            for carry in outcome.carried where pins.isPinned(carry.ghostID) {
                // Winner first: an exit between the two writes then leaves
                // the favourite on one trip, and the carry log fixes the rest.
                pins.pin(carry.winnerID)
                if removedFavouriteIDs.contains(carry.ghostID) {
                    pins.unpin(carry.ghostID)
                }
            }
            for id in removedFavouriteIDs {
                pins.unpin(id)
            }
        }
        return outcome
    }

    /// Test seam: injectable clock + defaults so the two-pass grace can be
    /// driven deterministically without touching `UserDefaults.standard`.
    /// Returns the favourites the caller must re-key on the main actor.
    @discardableResult
    static func deduplicateAll(
        modelContainer: ModelContainer,
        now: Date,
        defaults: UserDefaults,
        favouriteIDs: Set<UUID> = [],
        livePins: PinnedTripsStorage? = nil
    ) async -> Outcome {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return Outcome(incomplete: true) }
        defer { isRunning.withLock { $0 = false } }

        let context = ModelContext(modelContainer)
        var outcome = Outcome()

        let trips: [Trip]
        let stayCount: Int
        do {
            trips = try context.fetch(FetchDescriptor<Trip>())
            stayCount = try context.fetchCount(FetchDescriptor<Stay>())
        } catch {
            logger.error("Trip ghost sweep: fetch failed (\(error.localizedDescription)); skipping.")
            outcome.incomplete = true
            return outcome
        }
        let completed = trips.filter { $0.isComplete }
        guard !completed.isEmpty else {
            defaults.removeObject(forKey: firstObservedGhostsKey)
            return outcome
        }
        if stayCount == 0 {
            logger.info("Trip ghost sweep: store has completed trips but 0 stays — treating as mid-sync, skipping.")
            outcome.incomplete = true
            return outcome
        }

        let ghosts = completed.filter { ($0.stays ?? []).isEmpty }
        let winners = completed.filter { !($0.stays ?? []).isEmpty }
        let populatedTripIDs = Set(trips.filter { !($0.stays ?? []).isEmpty }.map(\.id))

        let firstObserved = (defaults.dictionary(forKey: firstObservedGhostsKey) as? [String: Double]) ?? [:]
        let nowEpoch = now.timeIntervalSince1970
        // With iCloud on, wall-clock age alone is not enough: an import that
        // stopped mid-way may still owe this row its stays.
        let syncOn = defaults.bool(forKey: AppDelegate.iCloudSyncEnabledKey)
        let lastImport = (defaults.object(forKey: AppDelegate.lastSuccessfulCloudImportAtKey) as? Date)?
            .timeIntervalSince1970
        var nextObserved: [String: Double] = [:]
        var mature: [(ghost: Trip, key: String, firstSeen: Double, carry: PreparedCarry)] = []

        for ghost in ghosts {
            guard let key = try? observationKey(for: ghost.persistentModelID) else {
                // An unencodable identity must never bypass grace.
                continue
            }
            let firstSeen = firstObserved[key] ?? nowEpoch
            guard nowEpoch - firstSeen >= ghostGracePeriod,
                  !syncOn || (lastImport ?? -.infinity) >= firstSeen + ghostGracePeriod else {
                nextObserved[key] = firstSeen
                outcome.observed += 1
                continue
            }
            // Annotations and pins are keyed by UUID. When a populated twin
            // shares this ghost's UUID, they are the twin's rows: carry
            // nothing anywhere, and let the empty row go only if it holds
            // no user data of its own.
            let hasPopulatedTwin = populatedTripIDs.contains(ghost.id)
            let winner = hasPopulatedTwin ? nil
                : Self.winner(for: ghost, among: winners) ?? loggedWinner(for: ghost, among: winners, defaults: defaults)
            guard let carry = hasPopulatedTwin
                    ? PreparedCarry(winner: nil, hidden: [], pinned: [], ownedByTwin: true)
                    : prepareCarry(from: ghost, to: winner, in: context) else {
                nextObserved[key] = firstSeen
                continue
            }
            mature.append((ghost, key, firstSeen, carry))
        }

        // Winner scans and annotation fetches are complete. Only value IDs
        // enter the main-actor closure; apply cached carries only after the veto.
        let candidateIDs = Set(mature.map { $0.ghost.id })
        #if DEBUG
        let preparedWinnerGhostIDs = Set(mature.filter { $0.carry.winner != nil }.map { $0.ghost.id })
        let preparedPhotoCount = mature.reduce(0) { $0 + $1.carry.hidden.count + $1.carry.pinned.count }
        #endif
        let currentFavourites: Set<UUID>
        if let livePins, !candidateIDs.isEmpty {
            currentFavourites = await MainActor.run {
                #if DEBUG
                beforeFavouriteRecheckForTesting?(preparedWinnerGhostIDs, preparedPhotoCount)
                #endif
                return livePins.pinnedIDs.intersection(candidateIDs)
            }
        } else {
            currentFavourites = favouriteIDs
        }
        // Revalidate the long-held winners once, not once for every ghost.
        let liveWinnerIDs = Set(winners.filter {
            !$0.isDeleted && $0.modelContext != nil
        }.map(\.persistentModelID))
        // A populated twin can sync in while the worker waited for the main
        // actor. Re-read who owns each candidate UUID before any cached carry
        // applies; an unreadable store retains every candidate.
        let twinOwnedIDs: Set<UUID>
        do {
            twinOwnedIDs = try populatedOwners(of: candidateIDs, in: context)
        } catch {
            logger.error("Trip ghost sweep: ownership re-read failed (\(error.localizedDescription)); retaining ghosts.")
            for (_, key, firstSeen, _) in mature { nextObserved[key] = firstSeen }
            outcome.incomplete = true
            mature = []
            twinOwnedIDs = []
        }
        for (ghost, key, firstSeen, prepared) in mature {
            guard !ghost.isDeleted, ghost.modelContext != nil,
                  ghost.isComplete, (ghost.stays ?? []).isEmpty else { continue }
            // Annotations and the favourite keyed to a twin's UUID are the
            // twin's: they never move to a winner and do not keep this empty
            // row. Post-save cleanup keeps a pin whose twin survives.
            let ownedByTwin = prepared.ownedByTwin || twinOwnedIDs.contains(ghost.id)
            // A new pin vetoes deletion even if a carry winner is available.
            if !ownedByTwin && currentFavourites.contains(ghost.id) && !favouriteIDs.contains(ghost.id) {
                nextObserved[key] = firstSeen
                continue
            }
            let winner = ownedByTwin ? nil : prepared.winner.flatMap {
                liveWinnerIDs.contains($0.persistentModelID) ? $0 : nil
            }
            guard applyCarry(ownedByTwin ? .twinOwned : prepared, from: ghost, to: winner,
                             isFavourite: !ownedByTwin && favouriteIDs.contains(ghost.id)) else {
                nextObserved[key] = firstSeen
                continue
            }
            if let winner {
                outcome.carried.append(CarriedFavourite(ghostID: ghost.id, winnerID: winner.id))
            }
            outcome.deletedIDs.insert(ghost.id)
            context.delete(ghost)
            outcome.deleted += 1
        }

        // Only currently-empty, not-yet-deleted trips survive in the map, so
        // entries for rows whose stays have since arrived drop out.
        if nextObserved.isEmpty {
            defaults.removeObject(forKey: firstObservedGhostsKey)
        } else {
            defaults.set(nextObserved, forKey: firstObservedGhostsKey)
        }

        guard outcome.deleted > 0 else { return outcome }
        // Log carries before the save so a favourite can follow a deletion
        // whose reconciliation never runs; a failed save restores the log.
        let loggedCarries = defaults.stringArray(forKey: carriedFavouritesKey)
        logCarries(outcome.carried, defaults: defaults)
        do {
            try context.save()
            logger.info("Trip ghost sweep: deleted \(outcome.deleted) empty completed trip(s), carried \(outcome.carried.count) onto their winners.")
        } catch {
            logger.error("Trip ghost sweep: save failed (\(error.localizedDescription)).")
            defaults.set(loggedCarries, forKey: carriedFavouritesKey)
            outcome = Outcome(incomplete: true)
        }
        return outcome
    }

    /// Moves each favourite still keyed to a carried ghost that no longer has
    /// a row onto the surviving end of its carry chain. Leaves pins alone
    /// when a row with the ghost's UUID exists, the chain ends at a missing
    /// trip, or the store cannot be read. False only when that read failed.
    @discardableResult
    static func rekeyCarriedFavourites(
        modelContainer: ModelContainer, defaults: UserDefaults, pins: PinnedTripsStorage
    ) async -> Bool {
        let winnerByGhost = carriedWinners(defaults: defaults)
        guard !winnerByGhost.isEmpty else { return true }
        let pinnedGhosts = await MainActor.run {
            pins.pinnedIDs.intersection(winnerByGhost.keys)
        }
        guard !pinnedGhosts.isEmpty else { return true }
        let ids = Array(Set(winnerByGhost.keys).union(winnerByGhost.values))
        let existing: Set<UUID>
        do {
            existing = Set(try ModelContext(modelContainer).fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { ids.contains($0.id) })).map(\.id))
        } catch {
            logger.error("Trip ghost sweep: carried-favourite fetch failed (\(error.localizedDescription)); retaining favourites.")
            return false
        }
        var moves: [(ghost: UUID, winner: UUID)] = []
        for ghost in pinnedGhosts {
            if let target = terminalWinner(for: ghost, winnerByGhost: winnerByGhost, existing: existing) {
                moves.append((ghost, target))
            }
        }
        guard !moves.isEmpty else { return true }
        await MainActor.run {
            for move in moves where pins.isPinned(move.ghost) {
                pins.pin(move.winner)
                pins.unpin(move.ghost)
            }
        }
        logger.info("Trip ghost sweep: moved \(moves.count) favourite(s) from carried ghosts to their winners.")
        return true
    }

    /// Appends `carries` to the carry log, newest last, within its cap. Keep
    /// as One Trip logs its deleted pieces here too.
    static func logCarries(_ carries: [CarriedFavourite], defaults: UserDefaults) {
        guard !carries.isEmpty else { return }
        let entries = carries.map { "\($0.ghostID.uuidString) \($0.winnerID.uuidString)" }
        let kept = (defaults.stringArray(forKey: carriedFavouritesKey) ?? []).filter { !entries.contains($0) }
        defaults.set(Array((kept + entries).suffix(carriedFavouritesLimit)), forKey: carriedFavouritesKey)
    }

    /// The carry log as `ghost → winner`; a later entry for a ghost wins and
    /// malformed entries are skipped.
    static func carriedWinners(defaults: UserDefaults) -> [UUID: UUID] {
        var winnerByGhost: [UUID: UUID] = [:]
        for entry in defaults.stringArray(forKey: carriedFavouritesKey) ?? [] {
            let parts = entry.split(separator: " ")
            guard parts.count == 2,
                  let ghost = UUID(uuidString: String(parts[0])),
                  let winner = UUID(uuidString: String(parts[1])) else { continue }
            winnerByGhost[ghost] = winner
        }
        return winnerByGhost
    }

    /// The existing trip at the end of `ghost`'s carry chain. Nil when a row
    /// with the ghost's UUID exists, the ghost was never carried, or the
    /// chain ends at a missing trip or loops. `existing` must hold every
    /// UUID of the chain that has a Trip row.
    static func terminalWinner(
        for ghost: UUID, winnerByGhost: [UUID: UUID], existing: Set<UUID>
    ) -> UUID? {
        guard !existing.contains(ghost) else { return nil }
        // A winner can itself become a carried ghost later.
        var target = winnerByGhost[ghost]
        var hops = 0
        while let current = target, !existing.contains(current), hops < winnerByGhost.count {
            target = winnerByGhost[current]
            hops += 1
        }
        guard let target, existing.contains(target) else { return nil }
        return target
    }

    /// Conservative identity evidence for independent assembly UUIDs. This
    /// never carries user data between uncertain counterparts.
    static func winner(for ghost: Trip, among candidates: [Trip]) -> Trip? {
        guard let end = ghost.endDate, end >= ghost.startDate,
              let countries = normalizedCountries(ghost.countryCodes),
              let summary = normalizedSummary(ghost.destinationSummary) else { return nil }
        let matching = candidates.filter { candidate in
            candidate.id != ghost.id
                && candidate.isComplete && !(candidate.stays ?? []).isEmpty
                && candidate.startDate == ghost.startDate && candidate.endDate == end
                && normalizedCountries(candidate.countryCodes) == countries
                && normalizedSummary(candidate.destinationSummary) == summary
        }
        // A conflicting custom name must not disambiguate two geographic
        // matches: the unnamed candidate may be the unrelated journey.
        guard matching.count == 1 else { return nil }
        let candidate = matching[0]
        return namesAreCompatible(ghost, candidate) ? candidate : nil
    }

    /// The counterpart a logged carry already chose for `ghost` (the photo-ping
    /// dedup carries a trip it empties as it empties it, onto the identical
    /// journey or the one holding all its fixes): one populated completed row
    /// of that id whose name agrees.
    private static func loggedWinner(for ghost: Trip, among candidates: [Trip], defaults: UserDefaults) -> Trip? {
        guard let id = carriedWinners(defaults: defaults)[ghost.id], id != ghost.id else { return nil }
        let rows = candidates.filter {
            $0.id == id && $0.isComplete && !($0.stays ?? []).isEmpty
        }
        guard rows.count == 1, namesAreCompatible(ghost, rows[0]) else { return nil }
        return rows[0]
    }

    /// Carries `ghost`'s edit mark, a name the winner lacks and its hidden and
    /// pinned photo rows onto `winner` in the caller's unsaved context, as the
    /// sweep does (`applyCarry`). False on a name conflict, writing nothing;
    /// throws when the photo rows cannot be read.
    static func carryChoices(from ghost: Trip, to winner: Trip, in context: ModelContext) throws -> Bool {
        guard let prepared = prepareCarry(from: ghost, to: winner, in: context) else {
            throw CocoaError(.fileReadUnknown)
        }
        return applyCarry(prepared, from: ghost, to: winner, isFavourite: false)
    }

    private static func namesAreCompatible(_ ghost: Trip, _ candidate: Trip) -> Bool {
        let ghostName = ghost.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = candidate.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ghostName.isEmpty || name.isEmpty || ghostName == name
    }

    private static func normalizedCountries(_ raw: String) -> Set<String>? {
        let codes = raw.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !codes.isEmpty, codes.allSatisfy({ code in
            code.utf8.count == 2 && code.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
            }
        }) else { return nil }
        return Set(codes.map { $0.uppercased() })
    }

    private static func normalizedSummary(_ raw: String) -> String? {
        // Never use curatedJoin: its display truncation can hide a different
        // destination at the end of the persisted summary.
        let summary = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let places = summary.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !summary.isEmpty, !summary.contains("?"),
              places.allSatisfy({ !$0.isEmpty && $0 != "unknown" }) else { return nil }
        return summary
    }

    /// Context-local references only; preparation must not mutate annotations.
    nonisolated private struct PreparedCarry {
        let winner: Trip?
        let hidden: [HiddenPhoto]
        let pinned: [PinnedPhoto]
        /// A populated row shares the ghost's UUID and owns everything keyed to it.
        var ownedByTwin = false

        static var twinOwned: PreparedCarry {
            PreparedCarry(winner: nil, hidden: [], pinned: [], ownedByTwin: true)
        }
    }

    /// The UUIDs among `ids` that a populated physical row holds, read afresh.
    private static func populatedOwners(of ids: Set<UUID>, in context: ModelContext) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        #if DEBUG
        if ownershipReadFailsForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let candidates = Array(ids)
        return Set(try context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { candidates.contains($0.id) }))
            .filter { !($0.stays ?? []).isEmpty }.map(\.id))
    }

    private static func prepareCarry(from ghost: Trip, to winner: Trip?, in context: ModelContext) -> PreparedCarry? {
        let ghostID = ghost.id
        let hidden: [HiddenPhoto]
        let pinned: [PinnedPhoto]
        do {
            hidden = try context.fetch(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { $0.tripID == ghostID }))
            pinned = try context.fetch(FetchDescriptor<PinnedPhoto>(
                predicate: #Predicate { $0.tripID == ghostID }))
        } catch {
            logger.error("Trip ghost sweep: annotation fetch failed (\(error.localizedDescription)); retaining ghost.")
            return nil
        }
        return PreparedCarry(winner: winner, hidden: hidden, pinned: pinned)
    }

    private static func applyCarry(
        _ prepared: PreparedCarry, from ghost: Trip, to winner: Trip?, isFavourite: Bool
    ) -> Bool {
        // UUID twins can share these cached rows. An earlier carry in this
        // batch may already have moved them; never take them from its winner.
        let hidden = prepared.hidden.filter {
            !$0.isDeleted && $0.modelContext != nil && $0.tripID == ghost.id
        }
        let pinned = prepared.pinned.filter {
            !$0.isDeleted && $0.modelContext != nil && $0.tripID == ghost.id
        }
        guard let winner else {
            return hidden.isEmpty && pinned.isEmpty && !ghost.userEdited && !isFavourite
                && (ghost.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Earlier non-vetoed carries may have filled a shared winner's name.
        // Preserve the original conflict rule without repeating winner scans.
        guard namesAreCompatible(ghost, winner) else { return false }
        // A temporary home's mark survives only when every edited copy carried
        // it: an edit of the user's own on either copy owns the merged trip.
        let userOwned = (winner.userEdited && !winner.keptByTemporaryHome)
            || (ghost.userEdited && !ghost.keptByTemporaryHome)
        winner.userEdited = winner.userEdited || ghost.userEdited
        winner.keptByTemporaryHome = winner.userEdited && !userOwned
        if let name = ghost.customName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (winner.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            winner.customName = name
        }
        for row in hidden { row.tripID = winner.id }
        for row in pinned { row.tripID = winner.id }
        return true
    }
}
