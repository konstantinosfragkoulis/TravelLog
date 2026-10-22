//
//  DissolvedTripQueue.swift
//  TravelLog
//
//  The soft-delete review queue for healing's dissolve arm. Retroactive
//  healing never hard-deletes a completed trip outright: every dissolved
//  trip leaves behind a full restoration record here, so
//
//  - a LATE-ARRIVING guard (an iCloud-KVS pin made on another device that
//    synced after the heal, a hidden/pinned photo row that CloudKit
//    delivered late) rescues the trip automatically
//    (`HomeAreaHealing.rescueIfNeeded`), closing the KVS-dissolve race that
//    motivated the queue; and
//  - the user can review and restore any dissolved trip manually from
//    Settings › Homes › Near-Home Activity ("Removed Trips").
//
//  DEVICE-LOCAL by design (the StatsSnapshotStore pattern): the dissolve
//  itself syncs through the store (stays re-stamped, Trip row deleted), so
//  only the device that performed it can restore — a queue synced via
//  CloudKit would race its own trip deletions. JSON file in Application
//  Support; a decode failure reads as an empty queue.
//
//  The record snapshots everything a faithful restore needs. The member
//  STAYS survive in the store (healing frees them to `.unclassified` and
//  the pipeline re-stamps them `.home`), so restore = recreate the Trip row
//  (same UUID — favorites and photo choices keyed on it come back) and
//  re-attach the surviving stays with their original categories.
//
//  A temporary home's covering archives here every trip the user engaged
//  with that it splits (`splitByTemporaryHomeID`). Such a record is the
//  original as it was split: no restore path, rescue or pruning touches it,
//  and it leaves the queue only after a committed Keep as One Trip
//  (`TripClassifier.keepSplitTripWhole`) or the user's Forget. It is
//  prepared until the split's deleting save commits (`splitCommitted`): a
//  retried split replaces it then, with the trip as the retry finds it.
//

import Foundation
import os.log

/// One trip healing dissolved, captured completely enough to restore.
nonisolated struct DissolvedTripRecord: Codable, Sendable, Identifiable, Equatable {

    nonisolated struct StayRef: Codable, Sendable, Equatable {
        let id: UUID
        let categoryRaw: String
        let orderInTrip: Int?
        /// The stay's `temporaryHomeID`, restored only with a home category.
        /// Queue files written before V20 decode it as nil.
        var temporaryHomeID: UUID? = nil
        /// The stay's `temporaryHomeRevision`, the other half of the pair.
        /// Queue files written before V21 decode it as nil.
        var temporaryHomeRevision: Int? = nil
        /// A split record only (`splitByTemporaryHomeID`): the stay's
        /// `userOverridden` before the split, and its category and override
        /// once the split was computed, before its save. A stay the user
        /// corrected after the split no longer matches the latter.
        var wasOverridden: Bool? = nil
        var postSplitCategoryRaw: String? = nil
        var postSplitOverridden: Bool? = nil
    }

    /// A split record only: one piece the split made that held recorded stays
    /// once it was computed, before its save, as assembly left it. Keep as One
    /// Trip tells the user's later work from what the split itself produced.
    nonisolated struct SplitHolderRef: Codable, Sendable, Equatable {
        let tripID: UUID
        let stayIDs: [UUID]
        let userEdited: Bool
        let customName: String?
        /// Hidden rows copied from this archive into the piece. Nil in older
        /// queue files; changes to these rows are later user work for Keep.
        var inheritedHiddenPhotoIDs: [UUID]? = nil
        /// Multiple archives contributed hides to this fresh piece. Keep must
        /// preserve them even if normal dedup keeps only one shared photo row.
        var sharesInheritedHiddenPhotos: Bool? = nil
    }

    /// Optional v2 payload inside the still-v1 queue file. Keeping this field
    /// optional is deliberate: synthesized `Decodable` uses `decodeIfPresent`,
    /// so queue files written before localized titles existed remain readable.
    nonisolated struct LocalizedTitleRef: Codable, Sendable, Equatable {
        let id: UUID
        let languageTag: String
        let title: String
        let sourceTitle: String
        let generationVersion: Int
        let updatedAt: Date
        var sourceRevision: UUID? = nil
    }

    /// One hidden (`isPinned == false`) or pinned photo row keyed to the
    /// parked trip's id.
    nonisolated struct PhotoAnnotationRef: Codable, Sendable, Equatable {
        let id: UUID
        let isPinned: Bool
        let localIdentifier: String
        let cloudIdentifier: String?
        let date: Date
    }

    /// The dissolved trip's own id — restore re-mints the row under it.
    let id: UUID
    let dissolvedAt: Date
    /// Display fields for the review row (the trip no longer exists, so the
    /// list can't derive them).
    let displayName: String
    let startDate: Date
    let endDate: Date?
    /// Heal-dissolved trips are always complete, but demotion can also park
    /// an ongoing trip. Restoring it as complete with a nil endDate excludes
    /// it from Currently Traveling and `closeStaleOpenTrips`, allowing the
    /// rest of the journey to create a second trip. Preserve its completion state.
    let isComplete: Bool
    let destinationSummary: String
    let countryCodes: String
    let classifiedByAI: Bool
    let aiGeneratedTitle: String?
    let aiGeneratedSummary: String?
    let summarySourceRaw: String?
    let sourceRaw: String
    /// Healing-dissolved trips never carry these (customName/userEdited are
    /// interaction guards), but trip demotion parks records too — and a
    /// demoted-then-undone trip must come back with its name and edit flag.
    var customName: String?
    /// A split record only: the names the trip's other same-id rows carried
    /// that differ from `customName` (the first name among its rows, the row
    /// holding the most stays first). Nil otherwise, and in queue files
    /// written before this field.
    var otherCustomNames: [String]? = nil
    var userEdited: Bool
    /// The trip's `keptByTemporaryHome`: its edit mark was a temporary
    /// home's, not the user's. Queue files written before V20 decode it as
    /// nil, which reads as false.
    var keptByTemporaryHome: Bool? = nil
    var stays: [StayRef]
    var localizedTitles: [LocalizedTitleRef]? = nil
    var titleSourceRevision: UUID? = nil
    /// Provenance for derived AI titles. Queue files written before this
    /// identity existed decode both as nil; restore then preserves the graph,
    /// custom name and stored narrative but regenerates titles conservatively.
    var derivedSemanticDigest: String? = nil
    var activeHomeTitleFingerprint: String? = nil
    /// Hidden and pinned photo rows that trip demotion deleted with the trip (a
    /// live row would let the rescue resurrect it). Restore re-inserts them
    /// in the trip's own save. Nil for healing records, whose trips never
    /// carry photo choices (unless one replaced a queued record holding
    /// rows), and for queue files written before this field.
    var photoAnnotations: [PhotoAnnotationRef]? = nil
    /// The temporary home whose covering unit archived this curated trip and
    /// split it, retiring its id. Nil for every other record. A split record
    /// is never restored automatically nor pruned as returned: it leaves the
    /// queue after a committed Keep as One Trip or the user's Forget.
    var splitByTemporaryHomeID: UUID? = nil
    /// A split record only: the trip was a favourite when it was split. Keep
    /// as One Trip pins it again after its commit.
    var wasFavourite: Bool? = nil
    /// A split record only: the pieces the split made that hold recorded
    /// stays once it was computed (`SplitHolderRef`).
    var postSplitHolders: [SplitHolderRef]? = nil
    /// A split record only: true once the split's deleting save committed.
    /// Until then the record is prepared (the sink wrote it before a save
    /// that may still fail), and a newer split of the trip replaces it.
    var splitCommitted: Bool? = nil
    /// A split record only: true once a Keep as One Trip of it committed. A
    /// Keep retried for it then only removes the record.
    var keepCommitted: Bool? = nil
    /// True when "This wasn't a trip" made the record, whose own demotion stamps
    /// its stays home and user-set; false when healing or a temporary home's
    /// unit parked the trip. Queue files written before this field decode nil.
    var dissolvedByDemotion: Bool? = nil

    nonisolated var isSplitRecord: Bool { splitByTemporaryHomeID != nil }

    /// One physical archive, not the trip id alone: two records under one id
    /// (an older queue's partial archives of UUID twins) differ in dissolve
    /// time or recorded stays, which no queue rewrite changes.
    nonisolated func isSameArchive(as other: Self) -> Bool {
        id == other.id && dissolvedAt == other.dissolvedAt
            && stays.map(\.id) == other.stays.map(\.id)
    }

    /// Whether this queued archive records a stay `newer` (a fresh archive of
    /// its trip id) does not: then it is no earlier copy `newer` replaces but
    /// another partial archive, such as an older queue's of UUID twins, whose
    /// trip has not come back. Split and spent records keep their own rules.
    nonisolated func isDistinctArchive(from newer: Self) -> Bool {
        guard !isSplitRecord, keepCommitted != true else { return false }
        return !Set(stays.map(\.id)).isSubset(of: newer.stays.map(\.id))
    }

    /// The record may hold the only copy of these rows, so it leaves the
    /// queue only after they are committed or the user forgets it.
    nonisolated var carriesPhotoAnnotations: Bool {
        !(photoAnnotations ?? []).isEmpty
    }

    /// This record plus the photo rows of `older`, the queued record it
    /// replaces for the same trip, that it lacks. A trip that came back
    /// without its rows (sync, import) and was parked again must not drop
    /// the only copy. A committed split record is the original as it was
    /// split and stays as it is: it only takes the photo rows the newer record
    /// holds that it lacks, and the newer split's after-split state (the trips
    /// holding the stays now). A prepared one, whose split never committed, is
    /// replaced like any other record: the trip it describes is still there,
    /// and a retried split archives it as it is then. One whose Keep committed
    /// is spent: the newer record replaces it whole, its photo rows included,
    /// since that Keep put them back.
    nonisolated func carryingPhotoAnnotations(of older: Self) -> Self {
        if older.keepCommitted == true { return self }
        if older.isSplitRecord, older.splitCommitted == true {
            var kept = older.addingPhotoAnnotations(of: self)
            if isSplitRecord { kept.adoptPostSplitState(of: self) }
            return kept
        }
        return addingPhotoAnnotations(of: older)
    }

    fileprivate nonisolated func addingPhotoAnnotations(of other: Self) -> Self {
        let otherRefs = other.photoAnnotations ?? []
        guard !otherRefs.isEmpty else { return self }
        var refs = photoAnnotations ?? []
        for ref in otherRefs where !refs.contains(where: {
            $0.isPinned == ref.isPinned && $0.localIdentifier == ref.localIdentifier
        }) {
            refs.append(ref)
        }
        var merged = self
        merged.photoAnnotations = refs
        return merged
    }

    /// The after-split fields of `newer` for every stay it records; the rest
    /// keep this record's.
    private nonisolated mutating func adoptPostSplitState(of newer: Self) {
        let newerRefs = Dictionary(
            newer.stays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stays = stays.map { ref in
            guard let fresh = newerRefs[ref.id] else { return ref }
            var updated = ref
            updated.postSplitCategoryRaw = fresh.postSplitCategoryRaw
            updated.postSplitOverridden = fresh.postSplitOverridden
            return updated
        }
        let newerHolders = newer.postSplitHolders ?? []
        let newerHolderIDs = Set(newerHolders.map(\.tripID))
        let held = Set(newerHolders.flatMap(\.stayIDs))
        let older = (postSplitHolders ?? []).filter {
            !newerHolderIDs.contains($0.tripID) && Set($0.stayIDs).isDisjoint(with: held)
        }
        let merged = newerHolders + older
        postSplitHolders = merged.isEmpty ? nil : merged
    }

    /// Resolve the review-row title in the requested app language. The stored
    /// `displayName` remains only a compatibility fallback for queue files
    /// written before the structured title fields existed.
    nonisolated func displayName(languageTag rawLanguageTag: String) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(
            rawLanguageTag) ?? "en"
        if let customName = TripTitleStore.normalized(customName) {
            return customName
        }
        if let canonicalTitle = TripTitleStore.normalized(aiGeneratedTitle) {
            let sourceRevision = titleSourceRevision
            var winner: LocalizedTitleRef?
            for candidate in localizedTitles ?? [] {
                guard AppLanguagePreference.normalizedSupportedTag(
                        candidate.languageTag) == languageTag,
                      let title = TripTitleStore.normalized(candidate.title),
                      TripTitleStore.isUsableVariantTitle(
                          title, languageTag: languageTag),
                      TripTitleStore.normalized(candidate.sourceTitle) == canonicalTitle,
                      candidate.sourceRevision == sourceRevision,
                      candidate.generationVersion >= TripTitleStore.currentGenerationVersion
                else { continue }
                let normalized = LocalizedTitleRef(
                    id: candidate.id,
                    languageTag: languageTag,
                    title: title,
                    sourceTitle: canonicalTitle,
                    generationVersion: candidate.generationVersion,
                    updatedAt: candidate.updatedAt,
                    sourceRevision: sourceRevision)
                guard let existing = winner else {
                    winner = normalized
                    continue
                }
                if TripTitleStore.hasPreferredContent(
                    .init(
                        id: normalized.id,
                        title: normalized.title,
                        generationVersion: normalized.generationVersion,
                        updatedAt: normalized.updatedAt),
                    over: .init(
                        id: existing.id,
                        title: existing.title,
                        generationVersion: existing.generationVersion,
                        updatedAt: existing.updatedAt)) {
                    winner = normalized
                }
            }
            if let winner { return winner.title }
            return canonicalTitle
        }
        let joined = Trip.curatedJoin(
            destinationSummary, languageTag: languageTag)
        if !joined.isEmpty { return joined }
        if let legacy = TripTitleStore.normalized(displayName) { return legacy }
        return AppLanguagePreference.localizedString(
            key: "trip.display-name.fallback",
            defaultValue: "Trip",
            languageTag: languageTag)
    }

    /// Legacy generated titles could carry calendar event names. Titles now
    /// take no calendar input. Deleting Calendar data therefore scrubs parked
    /// records too, otherwise a removed trip
    /// could display or restore the deleted event text later.
    nonisolated func removingGeneratedTitleArtifacts() -> Self {
        let safeDisplayName: String
        if let customName = TripTitleStore.normalized(customName) {
            safeDisplayName = customName
        } else {
            let joined = Trip.curatedJoin(
                destinationSummary, languageTag: "en")
            safeDisplayName = joined.isEmpty ? "Trip" : joined
        }
        return Self(
            id: id, dissolvedAt: dissolvedAt,
            displayName: safeDisplayName,
            startDate: startDate, endDate: endDate,
            isComplete: isComplete,
            destinationSummary: destinationSummary,
            countryCodes: countryCodes,
            classifiedByAI: classifiedByAI,
            aiGeneratedTitle: nil,
            aiGeneratedSummary: aiGeneratedSummary,
            summarySourceRaw: summarySourceRaw,
            sourceRaw: sourceRaw,
            customName: customName,
            otherCustomNames: otherCustomNames,
            userEdited: userEdited,
            keptByTemporaryHome: keptByTemporaryHome,
            stays: stays,
            localizedTitles: nil,
            titleSourceRevision: nil,
            derivedSemanticDigest: derivedSemanticDigest,
            activeHomeTitleFingerprint: activeHomeTitleFingerprint,
            photoAnnotations: photoAnnotations,
            splitByTemporaryHomeID: splitByTemporaryHomeID,
            wasFavourite: wasFavourite,
            postSplitHolders: postSplitHolders,
            splitCommitted: splitCommitted,
            keepCommitted: keepCommitted,
            dissolvedByDemotion: dissolvedByDemotion)
    }
}

/// Persistence for the dissolve review queue. All functions take an
/// optional directory override so tests run against scratch space; the
/// default is Application Support (device-local, backed up).
nonisolated enum DissolvedTripQueue {

    private static let logger = Logger(
        subsystem: "com.travellog.app", category: "DissolvedTripQueue")

    private static let fileName = "dissolved-trips-queue-v1.json"
    /// Durable two-phase marker for Delete Calendar Data. It is set before
    /// queue/store/cache work and cleared only after a final queue scrub and
    /// live-title clear succeed. Launch resumes an interrupted operation.
    static let generatedTitleRevocationPendingKey =
        "calendarGeneratedTitleRevocationPending_v1"
    /// Queue mutations can originate from the classifier actor, MainActor
    /// restore UI, and remote-maintenance work. Atomic file replacement does
    /// not make their load/merge/save sequences atomic, so serialize the
    /// complete transaction in this process.
    private static let persistenceLock = NSLock()

    enum PersistenceError: Error {
        case unavailableFileURL
    }

    static func beginGeneratedTitleRevocation(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: generatedTitleRevocationPendingKey)
    }

    static func finishGeneratedTitleRevocation(
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: generatedTitleRevocationPendingKey)
    }

    static func generatedTitleRevocationIsPending(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: generatedTitleRevocationPendingKey)
    }

    static func fileURL(in directory: URL? = nil) -> URL? {
        if let directory { return directory.appendingPathComponent(fileName) }
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent(fileName)
    }

    /// All parked records, newest dissolve first. This UI-facing read is
    /// best-effort; mutation paths use the throwing reader below so a
    /// transient read/decode failure can never be mistaken for an empty queue
    /// and overwritten.
    static func load(from directory: URL? = nil) -> [DissolvedTripRecord] {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return loadUnlocked(from: directory)
    }

    private static func loadUnlocked(
        from directory: URL?
    ) -> [DissolvedTripRecord] {
        (try? loadForMutationUnlocked(from: directory)) ?? []
    }

    private static func loadForMutationUnlocked(
        from directory: URL?
    ) throws -> [DissolvedTripRecord] {
        guard let url = fileURL(in: directory) else {
            throw PersistenceError.unavailableFileURL
        }
        // Missing is the sole legitimate empty state. If the file disappears
        // after this check, the read throws and the caller fails closed.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let records = try JSONDecoder().decode(
            [DissolvedTripRecord].self, from: data)
        return records.sorted { $0.dissolvedAt > $1.dissolvedAt }
    }

    /// Park freshly dissolved trips. Records whose trip id is already
    /// queued are replaced (a re-dissolve after an auto-restore-then-unpin
    /// carries the newer snapshot), keeping the replaced record's photo rows.
    /// A committed split record is kept instead (`carryingPhotoAnnotations`).
    /// Another archive under the id that records a stay the newer one does
    /// not (an older queue's second partial archive of UUID twins, still
    /// unsettled) is no earlier copy of it and stays queued as it is.
    /// A split's commit hands its prepared record back marked committed: it
    /// only marks that record, so one the user forgot meanwhile stays gone.
    static func append(
        _ records: [DissolvedTripRecord],
        in directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        guard !records.isEmpty else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let queued = try loadForMutationUnlocked(from: directory)
        var replaced: [DissolvedTripRecord] = []
        let recordsToPersist = (generatedTitleRevocationIsPending(
            defaults: defaults)
            ? records.map { $0.removingGeneratedTitleArtifacts() }
            : records).compactMap { record -> DissolvedTripRecord? in
                let olders = queued.filter { $0.id == record.id && !$0.isDistinctArchive(from: record) }
                replaced += olders
                guard let older = olders.first else {
                    return record.splitCommitted == true ? nil : record
                }
                // Newest first: the newest replaced copy decides, as before,
                // and every other one hands on its photo rows.
                return olders.dropFirst().reduce(record.carryingPhotoAnnotations(of: older)) {
                    $0.addingPhotoAnnotations(of: $1)
                }
            }
        guard !recordsToPersist.isEmpty else { return }
        let merged = (recordsToPersist + queued.filter { record in
            !replaced.contains { $0.isSameArchive(as: record) }
        })
            .sorted { $0.dissolvedAt > $1.dissolvedAt }
        // Every row is a recovery record for an already-deleted Trip. Never
        // evict an older record merely to bound this small device-local file.
        try save(merged, in: directory)
    }

    /// The records a backup restore would queue: those whose id is neither
    /// queued nor a trip in `existingTripIDs` (the trip is back), and whose
    /// Keep as One Trip has not committed. Preview and restore share it.
    static func restorable(
        _ records: [DissolvedTripRecord],
        queuedIDs: Set<UUID>,
        existingTripIDs: Set<UUID>
    ) -> [DissolvedTripRecord] {
        var seen = queuedIDs
        return records.filter { record in
            record.keepCommitted != true
                && !existingTripIDs.contains(record.id)
                && seen.insert(record.id).inserted
        }
    }

    /// Queues a committed backup restore's records as they were archived
    /// (`restorable`), committed splits included: unlike `append`, nothing
    /// here is a split's own commit. Records already queued stay as they are.
    /// Returns how many were added.
    @discardableResult
    static func restore(
        _ records: [DissolvedTripRecord],
        existingTripIDs: Set<UUID>,
        in directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) throws -> Int {
        guard !records.isEmpty else { return 0 }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let queued = try loadForMutationUnlocked(from: directory)
        let added = restorable(
            records, queuedIDs: Set(queued.map(\.id)), existingTripIDs: existingTripIDs)
        guard !added.isEmpty else { return 0 }
        let persisted = generatedTitleRevocationIsPending(defaults: defaults)
            ? added.map { $0.removingGeneratedTitleArtifacts() } : added
        try save((persisted + queued).sorted { $0.dissolvedAt > $1.dissolvedAt }, in: directory)
        return added.count
    }

    /// The queued record with this id, nil when none is. A required read: an
    /// unreadable file throws instead of reading as an empty queue.
    static func record(id: UUID, in directory: URL? = nil) throws -> DissolvedTripRecord? {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return try loadForMutationUnlocked(from: directory).first { $0.id == id }
    }

    /// Records on the queued split record with this id that its Keep as One
    /// Trip committed. A record no longer queued stays gone.
    static func markKeepCommitted(id: UUID, in directory: URL? = nil) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        var records = try loadForMutationUnlocked(from: directory)
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].keepCommitted != true else { return }
        records[index].keepCommitted = true
        try save(records, in: directory)
    }

    static func remove(ids: Set<UUID>, in directory: URL? = nil) throws {
        guard !ids.isEmpty else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        // Removal is a mutation too: a corrupt/transiently unreadable file
        // must never be mistaken for an empty queue and deleted. Preserve
        // the existing bytes and let the caller retry.
        let remaining = try loadForMutationUnlocked(from: directory).filter {
            !ids.contains($0.id)
        }
        if remaining.isEmpty {
            try clearUnlocked(in: directory)
        } else {
            try save(remaining, in: directory)
        }
    }

    /// Removes this one archive: the queued record with its id, dissolve time
    /// and recorded stays. A queue written before twins were kept from healing
    /// can hold two partial archives under one trip id; restoring one must not
    /// take the other's membership with it. An unreadable file throws and
    /// keeps its bytes.
    static func remove(archive record: DissolvedTripRecord, in directory: URL? = nil) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let records = try loadForMutationUnlocked(from: directory)
        let remaining = records.filter { !$0.isSameArchive(as: record) }
        guard remaining.count != records.count else { return }
        if remaining.isEmpty {
            try clearUnlocked(in: directory)
        } else {
            try save(remaining, in: directory)
        }
    }

    /// The ids of `settled` that no other record of `records` shares unsettled:
    /// an id leaves the queue only once every archive under it is settled.
    static func idsSettledWhole(
        _ settled: [DissolvedTripRecord], of records: [DissolvedTripRecord]
    ) -> Set<UUID> {
        let ids = Set(settled.map(\.id))
        let unsettled = Set(records.filter { record in
            ids.contains(record.id) && !settled.contains { $0.isSameArchive(as: record) }
        }.map(\.id))
        return ids.subtracting(unsettled)
    }

    /// Removes the record with this id only while it records its Keep as One
    /// Trip committed. A later split of the kept trip writes a fresh, unkept
    /// record under the same id (`carryingPhotoAnnotations`), and that archive
    /// stays. An unreadable file throws and keeps its bytes.
    static func removeKeptRecord(id: UUID, in directory: URL? = nil) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let records = try loadForMutationUnlocked(from: directory)
        let remaining = records.filter { $0.id != id || $0.keepCommitted != true }
        guard remaining.count != records.count else { return }
        if remaining.isEmpty {
            try clearUnlocked(in: directory)
        } else {
            try save(remaining, in: directory)
        }
    }

    /// Remove the records a store deletion left past restoring: one of their
    /// recorded stays is in `deletedStayIDs`, and neither a recorded stay (a
    /// UUID twin) nor their trip is among the remaining rows. Restore needs
    /// every recorded stay and a returned trip takes a record's photo rows,
    /// so every other record stays as it is, and an absent stay never counts
    /// as deleted. A split record stays until Keep as One Trip or Forget.
    /// An unreadable file throws and keeps its bytes.
    static func removeRecords(
        deletedStayIDs: Set<UUID>,
        remainingStayIDs: Set<UUID>,
        remainingTripIDs: Set<UUID>,
        in directory: URL? = nil
    ) throws {
        guard !deletedStayIDs.isEmpty else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let records = try loadForMutationUnlocked(from: directory)
        let remaining = records.filter { record in
            record.isSplitRecord
                || !record.stays.contains(where: { deletedStayIDs.contains($0.id) })
                || record.stays.contains(where: { remainingStayIDs.contains($0.id) })
                || remainingTripIDs.contains(record.id)
        }
        guard remaining.count != records.count else { return }
        if remaining.isEmpty {
            try clearUnlocked(in: directory)
        } else {
            try save(remaining, in: directory)
        }
    }

    /// Remove every generated title from parked recovery records. This is a
    /// privacy boundary used by Delete Calendar Data, not a best-effort cache
    /// cleanup: unreadable bytes or a failed rewrite are surfaced and the
    /// original file is preserved.
    static func scrubGeneratedTitles(in directory: URL? = nil) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let records = try loadForMutationUnlocked(from: directory)
        guard !records.isEmpty else { return }
        let scrubbed = records.map { $0.removingGeneratedTitleArtifacts() }
        guard scrubbed != records else { return }
        try save(scrubbed, in: directory)
    }

    /// Wired into Delete All Data — a wiped store's queue records point at
    /// stays that no longer exist.
    static func clear(in directory: URL? = nil) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        try clearUnlocked(in: directory)
    }

    private static func clearUnlocked(in directory: URL?) throws {
        guard let url = fileURL(in: directory) else {
            throw PersistenceError.unavailableFileURL
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("Failed to clear dissolve queue: \(error.localizedDescription)")
            throw error
        }
    }

    private static func save(
        _ records: [DissolvedTripRecord],
        in directory: URL?
    ) throws {
        guard let url = fileURL(in: directory) else {
            throw PersistenceError.unavailableFileURL
        }
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to persist dissolve queue: \(error.localizedDescription)")
            throw error
        }
    }

    /// `load` for a screen that must tell a failed read from an empty queue:
    /// a read or decode failure throws. A missing file is still empty.
    static func loadThrowing(from directory: URL? = nil) throws -> [DissolvedTripRecord] {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return try loadForMutationUnlocked(from: directory)
    }
}
