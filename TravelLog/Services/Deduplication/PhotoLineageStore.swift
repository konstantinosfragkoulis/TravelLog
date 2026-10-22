//
//  PhotoLineageStore.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Hidden-photo lineage across ordinary regrouping.
///
/// A historical regroup can retire a trip's UUID (a merge's losing
/// constituent, a split piece arbitration gave a fresh id) while the stays
/// it held live on in other trips. Hiding is a privacy choice, not a
/// property of one id, so it follows the stays:
///
/// 1. Before it detaches or deletes the old trips, the regrouping unit reads
///    their hidden choices as values (`hiddenChoices(of:in:)`).
/// 2. After final identity arbitration it copies them onto every output that
///    holds any of the old trip's stays (`inheritHidden(_:onto:in:)`), in
///    the same save, as fresh rows each output can unhide on its own.
/// 3. Before that save it records `retired → successors` for every UUID no
///    output kept (`record(_:defaults:)`), restoring the returned entries if
///    the save fails, as the duplicate sweep does with its carry log.
///
/// A hidden row that syncs in later keyed to a retired UUID (another device
/// hid the photo before it saw the regroup) is then no orphan:
/// `PhotoAnnotationDeduplicator` copies it onto every existing trip at the
/// end of the lineage and removes the late row. A lineage whose successors
/// are all gone leaves the row to age like any other orphan. An id one
/// output kept needs no lineage: its rows stay valid on that output. When
/// that output is one piece of a split, the split's provenance
/// (`SplitProvenance`) passes a late row hidden before the split on to the
/// other pieces once.
///
/// Pinned photos and favourites are not inherited: which piece keeps a pin
/// is a product decision this store does not make. The log is device-local,
/// like the carry log, so only the regrouping device replays it; Delete All
/// Data clears it.
nonisolated enum PhotoLineageStore {

    /// Device-local `"retiredUUID successorUUID,successorUUID"` entries,
    /// oldest first; a later entry for a retired id replaces an earlier one.
    static let defaultsKey = "tripHiddenLineage_v1"
    static let limit = 256

    /// A retired trip id and the trips that took over its stays.
    nonisolated struct Lineage: Sendable, Equatable {
        let retiredID: UUID
        let successorIDs: Set<UUID>
    }

    /// A hidden choice as a value, safe to hold across a regroup's deletes.
    nonisolated struct HiddenChoice: Sendable, Hashable {
        let localIdentifier: String
        let cloudIdentifier: String?
        let hiddenAt: Date
    }

    // MARK: - Regrouping unit

    /// The hidden choices each of `tripIDs` holds now. Throws on a failed
    /// read: a regroup must not proceed as if the old trips hid nothing.
    static func hiddenChoices(
        of tripIDs: Set<UUID>, in context: ModelContext
    ) throws -> [UUID: [HiddenChoice]] {
        try hiddenRows(of: tripIDs, in: context).choices
    }

    /// `hiddenChoices(of:in:)`, with the ids of the rows that hold them.
    static func hiddenRows(
        of tripIDs: Set<UUID>, in context: ModelContext
    ) throws -> (choices: [UUID: [HiddenChoice]], rowIDs: [UUID: Set<UUID>]) {
        guard !tripIDs.isEmpty else { return ([:], [:]) }
        let ids = Array(tripIDs)
        let rows = try context.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { ids.contains($0.tripID) }))
        var choices: [UUID: [HiddenChoice]] = [:]
        var rowIDs: [UUID: Set<UUID>] = [:]
        for row in rows where !row.isDeleted {
            choices[row.tripID, default: []].append(HiddenChoice(
                localIdentifier: row.localIdentifier,
                cloudIdentifier: row.cloudIdentifier,
                hiddenAt: row.hiddenAt))
            rowIDs[row.tripID, default: []].insert(row.id)
        }
        return (choices, rowIDs)
    }

    /// Inserts a fresh hidden row on `tripID` for each choice it does not
    /// hold yet under the dedup identity, oldest first, keeping the original
    /// identifiers and hide time; a missing cloud id is taken from another
    /// choice of the same local photo. Rows this context inserted and has
    /// not saved count as held, so repeated calls in one unit coalesce.
    /// Returns how many rows it inserted; throws on a failed read.
    @discardableResult
    static func inheritHidden(
        _ choices: [HiddenChoice], onto tripID: UUID, in context: ModelContext
    ) throws -> Int {
        guard !choices.isEmpty else { return 0 }
        let held = try context.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID }))
        var identities = PhotoAnnotationDeduplicator.ChoiceIdentities()
        for row in held where !row.isDeleted {
            identities.hold(localIdentifier: row.localIdentifier, cloudIdentifier: row.cloudIdentifier)
        }
        let knownCloud = Dictionary(
            choices.compactMap { choice in choice.cloudIdentifier.map { (choice.localIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first })
        let ordered = choices.sorted {
            $0.hiddenAt != $1.hiddenAt ? $0.hiddenAt < $1.hiddenAt : $0.localIdentifier < $1.localIdentifier
        }
        var inserted = 0
        for choice in ordered {
            let cloud = choice.cloudIdentifier ?? knownCloud[choice.localIdentifier]
            guard identities.admit(localIdentifier: choice.localIdentifier, cloudIdentifier: cloud) else { continue }
            let row = HiddenPhoto(localIdentifier: choice.localIdentifier, tripID: tripID)
            row.cloudIdentifier = cloud
            row.hiddenAt = choice.hiddenAt
            context.insert(row)
            inserted += 1
        }
        return inserted
    }

    /// Appends `lineages` (newest last, within the cap) and returns the
    /// entries as they were, for `restore(_:defaults:)` after a failed save.
    /// A lineage with no successor, or naming itself, is not recorded.
    @discardableResult
    static func record(_ lineages: [Lineage], defaults: UserDefaults) -> [String]? {
        let prior = defaults.stringArray(forKey: defaultsKey)
        let valid = lineages.filter {
            !$0.successorIDs.subtracting([$0.retiredID]).isEmpty
        }
        guard !valid.isEmpty else { return prior }
        let retired = Set(valid.map(\.retiredID))
        let kept = (prior ?? []).filter { entry in
            guard let id = entry.split(separator: " ").first.flatMap({ UUID(uuidString: String($0)) }) else {
                return false
            }
            return !retired.contains(id)
        }
        let entries = valid.map { lineage in
            let successors = lineage.successorIDs.subtracting([lineage.retiredID])
                .map(\.uuidString).sorted().joined(separator: ",")
            return "\(lineage.retiredID.uuidString) \(successors)"
        }
        defaults.set(Array((kept + entries).suffix(limit)), forKey: defaultsKey)
        return prior
    }

    /// Puts back the entries `record` returned.
    static func restore(_ prior: [String]?, defaults: UserDefaults) {
        if let prior {
            defaults.set(prior, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    // MARK: - Splits that keep the original id

    /// A split whose original id one piece kept: a hidden row of the
    /// original that another device made before the split, and that syncs in
    /// after it, still belongs on the other pieces, as the rows read at the
    /// split did. Each such row is copied onto them once (`settledRowIDs`
    /// then holds it), so unhiding on a piece sticks. A row hidden at or after
    /// `splitAt` is the kept piece's own choice and is never forwarded.
    nonisolated struct SplitProvenance: Codable, Sendable, Equatable {
        let parentID: UUID
        let successorIDs: Set<UUID>
        let splitAt: Date
        /// The original's hidden rows already passed on: read at the split,
        /// or copied by a later sweep.
        var settledRowIDs: Set<UUID>
    }

    /// Device-local JSON `[SplitProvenance]`, oldest first. Each split is its
    /// own event: a later split of the same original keeps the earlier one's
    /// entry, with its own cutoff, pieces and settled rows, so a row hidden
    /// before the first split still reaches the first split's pieces, and a
    /// row hidden between the splits reaches only the later one's. Delete
    /// All Data clears it.
    static let splitDefaultsKey = "tripHiddenSplitProvenance_v1"

    /// The latest split of each original; unreadable data reads as empty.
    static func splits(defaults: UserDefaults) -> [UUID: SplitProvenance] {
        Dictionary(splitEntries(defaults: defaults).map { ($0.parentID, $0) },
                   uniquingKeysWith: { _, later in later })
    }

    /// Every recorded split of each original, oldest first.
    static func splitEvents(defaults: UserDefaults) -> [UUID: [SplitProvenance]] {
        Dictionary(grouping: splitEntries(defaults: defaults), by: \.parentID)
    }

    private static func splitEntries(defaults: UserDefaults) -> [SplitProvenance] {
        guard let data = defaults.data(forKey: splitDefaultsKey),
              let entries = try? JSONDecoder().decode([SplitProvenance].self, from: data) else { return [] }
        return entries
    }

    /// Appends `splits` (within the cap) and returns the log as it was, for
    /// `restoreSplits(_:defaults:)` after a failed save. Only an entry of the
    /// same original at the same instant is replaced.
    @discardableResult
    static func recordSplits(_ splits: [SplitProvenance], defaults: UserDefaults) -> Data? {
        let prior = defaults.data(forKey: splitDefaultsKey)
        let valid = splits.filter { !$0.successorIDs.subtracting([$0.parentID]).isEmpty }
        guard !valid.isEmpty else { return prior }
        let replaced = Set(valid.map { [$0.parentID.uuidString, "\($0.splitAt.timeIntervalSinceReferenceDate)"] })
        let kept = (prior.flatMap { try? JSONDecoder().decode([SplitProvenance].self, from: $0) } ?? [])
            .filter { !replaced.contains([$0.parentID.uuidString, "\($0.splitAt.timeIntervalSinceReferenceDate)"]) }
        write(Array((kept + valid).suffix(limit)), defaults: defaults)
        return prior
    }

    /// Puts back the log `recordSplits` returned.
    static func restoreSplits(_ prior: Data?, defaults: UserDefaults) {
        if let prior {
            defaults.set(prior, forKey: splitDefaultsKey)
        } else {
            defaults.removeObject(forKey: splitDefaultsKey)
        }
    }

    /// Marks rows passed on by a sweep whose save committed, on every split
    /// of their original (the sweep judged each row against all of them).
    static func settle(_ rowIDs: [UUID: Set<UUID>], defaults: UserDefaults) {
        guard !rowIDs.isEmpty, let data = defaults.data(forKey: splitDefaultsKey),
              var entries = try? JSONDecoder().decode([SplitProvenance].self, from: data) else { return }
        for index in entries.indices {
            if let settled = rowIDs[entries[index].parentID] {
                entries[index].settledRowIDs.formUnion(settled)
            }
        }
        write(entries, defaults: defaults)
    }

    private static func write(_ entries: [SplitProvenance], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: splitDefaultsKey)
    }

    // MARK: - Members a completed trip lost before its regroup

    /// Device-local JSON `[UUID: Set<UUID>]`, trip id to stay ids: the stays
    /// an import or a shared removal took out of a completed trip to be
    /// judged again (`StayClassificationInputs.resetIfMoved`), recorded once
    /// that save commits. The regroup that follows still sees the trip as it
    /// was: its id follows its largest overlap with every stay it held, and
    /// its hidden choices reach each piece holding one of them. Assembly
    /// drops an entry when it regroups the trip or the trip is no longer an
    /// automatic completed one, and a stay once another trip holds it.
    /// Delete All Data clears it.
    static let detachedMembersKey = "tripDetachedMembers_v1"

    /// The log; unreadable data reads as empty.
    static func detachedMembers(defaults: UserDefaults) -> [UUID: Set<UUID>] {
        guard let data = defaults.data(forKey: detachedMembersKey),
              let log = try? JSONDecoder().decode([UUID: Set<UUID>].self, from: data) else { return [:] }
        return log
    }

    /// Adds `members` to the log, each trip's stays to any it holds.
    static func recordDetachedMembers(_ members: [UUID: Set<UUID>], defaults: UserDefaults) {
        guard !members.isEmpty else { return }
        var log = detachedMembers(defaults: defaults)
        for (tripID, stayIDs) in members { log[tripID, default: []].formUnion(stayIDs) }
        writeDetachedMembers(log, defaults: defaults)
    }

    /// Replaces the log and returns the bytes it replaced, for
    /// `restoreDetachedMembers(_:defaults:)` after a failed save.
    @discardableResult
    static func writeDetachedMembers(_ log: [UUID: Set<UUID>], defaults: UserDefaults) -> Data? {
        let prior = defaults.data(forKey: detachedMembersKey)
        if log.isEmpty {
            defaults.removeObject(forKey: detachedMembersKey)
        } else if let data = try? JSONEncoder().encode(log) {
            defaults.set(data, forKey: detachedMembersKey)
        }
        return prior
    }

    /// Puts back the log `writeDetachedMembers` returned.
    static func restoreDetachedMembers(_ prior: Data?, defaults: UserDefaults) {
        if let prior {
            defaults.set(prior, forKey: detachedMembersKey)
        } else {
            defaults.removeObject(forKey: detachedMembersKey)
        }
    }

    /// Where the import and shared-removal paths record detached members:
    /// the classifier's lineage defaults (`TripClassifier.hiddenLineageDefaults`).
    static var recorderDefaults: UserDefaults {
        #if DEBUG
        if let suite = TripClassifier.hiddenLineageSuiteNameForTesting { return UserDefaults(suiteName: suite)! }
        #endif
        return .standard
    }

    // MARK: - Late arrivals

    /// The log as `retired → successors`; malformed entries are skipped.
    static func successors(defaults: UserDefaults) -> [UUID: Set<UUID>] {
        var successorsByRetired: [UUID: Set<UUID>] = [:]
        for entry in defaults.stringArray(forKey: defaultsKey) ?? [] {
            let parts = entry.split(separator: " ")
            guard parts.count == 2, let retired = UUID(uuidString: String(parts[0])) else { continue }
            let successors = Set(parts[1].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            guard !successors.isEmpty else { continue }
            successorsByRetired[retired] = successors
        }
        return successorsByRetired
    }

    /// The existing trips at the ends of `retired`'s lineage: a successor
    /// that was itself retired later passes on to its own successors. Empty
    /// when a trip with `retired`'s id exists, it was never retired, or
    /// every end is missing. `existing` must hold every id with a Trip row.
    static func terminalSuccessors(
        of retired: UUID, lineage: [UUID: Set<UUID>], existing: Set<UUID>
    ) -> Set<UUID> {
        guard !existing.contains(retired), lineage[retired] != nil else { return [] }
        var visited: Set<UUID> = [retired]
        var frontier = lineage[retired] ?? []
        var ends = Set<UUID>()
        while let next = frontier.popFirst() {
            guard visited.insert(next).inserted else { continue }
            if existing.contains(next) {
                ends.insert(next)
            } else if let further = lineage[next] {
                frontier.formUnion(further)
            }
        }
        return ends
    }
}
