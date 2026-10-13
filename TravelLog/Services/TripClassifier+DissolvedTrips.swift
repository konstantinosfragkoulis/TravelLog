//
//  TripClassifier+DissolvedTrips.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    func setDissolvedRecordSink(
        _ sink: (@Sendable ([DissolvedTripRecord]) throws -> Void)?
    ) {
        dissolvedRecordSink = sink
    }

    /// Production must establish the pre-delete durability barrier. DEBUG
    /// tests may omit the file sink and inspect the actor's parked records
    /// directly, preserving the existing lightweight in-memory harness.
    func persistDissolvedRecords(
        _ records: [DissolvedTripRecord]
    ) throws {
        if let dissolvedRecordSink {
            try dissolvedRecordSink(records)
            return
        }
        #if !DEBUG
        throw DissolvedTripQueue.PersistenceError.unavailableFileURL
        #endif
    }

    func drainParkedDissolvedTrips() -> [DissolvedTripRecord] {
        defer { parkedDissolvedTrips = [] }
        return parkedDissolvedTrips
    }

    func makeDissolvedRecord(
        for trip: Trip, dissolvedByDemotion: Bool? = nil
    ) -> DissolvedTripRecord {
        var localizedTitlesByKey: [[String]: DissolvedTripRecord.LocalizedTitleRef] = [:]
        if let canonicalTitle = TripTitleStore.normalized(trip.aiGeneratedTitle) {
            for variant in trip.localizedTitles ?? [] {
                guard let languageTag = AppLanguagePreference.normalizedSupportedTag(
                        variant.languageTag),
                      languageTag != "en",
                      let title = TripTitleStore.normalized(variant.title),
                      TripTitleStore.isUsableVariantTitle(
                          title, languageTag: languageTag),
                      TripTitleStore.normalized(variant.sourceTitle) == canonicalTitle,
                      variant.sourceRevision == trip.titleSourceRevision,
                      variant.generationVersion >= TripTitleStore.currentGenerationVersion
                else { continue }
                let ref = DissolvedTripRecord.LocalizedTitleRef(
                    id: variant.id,
                    languageTag: languageTag,
                    title: title,
                    sourceTitle: canonicalTitle,
                    generationVersion: variant.generationVersion,
                    updatedAt: variant.updatedAt,
                    sourceRevision: variant.sourceRevision)
                let key = [
                    ref.languageTag,
                    ref.sourceTitle,
                    ref.sourceRevision?.uuidString ?? "legacy",
                ]
                guard let existing = localizedTitlesByKey[key] else {
                    localizedTitlesByKey[key] = ref
                    continue
                }
                if TripTitleStore.hasPreferredContent(
                    .init(
                        id: ref.id,
                        title: ref.title,
                        generationVersion: ref.generationVersion,
                        updatedAt: ref.updatedAt),
                    over: .init(
                        id: existing.id,
                        title: existing.title,
                        generationVersion: existing.generationVersion,
                        updatedAt: existing.updatedAt)) {
                    localizedTitlesByKey[key] = ref
                }
            }
        }
        let localizedTitles = localizedTitlesByKey.values.sorted { left, right in
            if left.languageTag != right.languageTag {
                return left.languageTag < right.languageTag
            }
            if left.sourceTitle != right.sourceTitle {
                return left.sourceTitle < right.sourceTitle
            }
            return left.id.uuidString < right.id.uuidString
        }
        let semanticDigest = TripTitleStore.semanticDigest(
            for: TripTitleStore.semanticSnapshot(for: trip))
        let activeHomeFingerprint = (try? TripTitleStore
            .fetchActiveHomeTitleInputs(in: modelContext)).map {
                TripTitleStore.activeHomeTitleFingerprint(for: $0)
            }

        return DissolvedTripRecord(
            id: trip.id,
            dissolvedAt: .now,
            displayName: trip.displayName,
            startDate: trip.startDate,
            endDate: trip.endDate,
            isComplete: trip.isComplete,
            destinationSummary: trip.destinationSummary,
            countryCodes: trip.countryCodes,
            classifiedByAI: trip.classifiedByAI,
            aiGeneratedTitle: trip.aiGeneratedTitle,
            aiGeneratedSummary: trip.aiGeneratedSummary,
            summarySourceRaw: trip.summarySourceRaw,
            sourceRaw: trip.sourceRaw,
            customName: trip.customName,
            userEdited: trip.userEdited,
            keptByTemporaryHome: trip.keptByTemporaryHome,
            stays: (trip.stays ?? [])
                .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
                .map { DissolvedTripRecord.StayRef(
                    id: $0.id, categoryRaw: $0.categoryRaw, orderInTrip: $0.orderInTrip,
                    temporaryHomeID: $0.temporaryHomeID,
                    temporaryHomeRevision: $0.temporaryHomeRevision) },
            localizedTitles: localizedTitles.isEmpty ? nil : localizedTitles,
            titleSourceRevision: trip.titleSourceRevision,
            derivedSemanticDigest: semanticDigest,
            activeHomeTitleFingerprint: activeHomeFingerprint,
            dissolvedByDemotion: dissolvedByDemotion)
    }

    /// One archive per split id, taken before anything changes. Same-id twins are one
    /// trip: the row with the most stays gives the record and the name Keep restores,
    /// every row's stays and names are kept, and copies of one stay are one ref (nil
    /// when they differ in category or setting). The edit mark is the user's, never a hold.
    func makeSplitRecords(
        _ ids: [UUID], rows: [Trip], temporaryHomeID: UUID, pinnedTripIDs: Set<UUID>
    ) -> [DissolvedTripRecord]? {
        var records: [DissolvedTripRecord] = []
        for id in ids {
            let twins = rows.filter { $0.id == id }.sorted {
                let (a, b) = (($0.stays ?? []).count, ($1.stays ?? []).count)
                return a != b ? a > b : $0.startDate < $1.startDate
            }
            guard let primary = twins.first else { continue }
            var record = makeDissolvedRecord(for: primary)
            var settings: [UUID: Stay] = [:]
            for twin in twins {
                for stay in twin.stays ?? [] {
                    guard let first = settings[stay.id] else {
                        settings[stay.id] = stay
                        continue
                    }
                    guard first.categoryRaw == stay.categoryRaw,
                          first.userOverridden == stay.userOverridden else { return nil }
                }
            }
            var stays: [DissolvedTripRecord.StayRef] = []
            for ref in record.stays where !stays.contains(where: { $0.id == ref.id }) {
                stays.append(ref)
            }
            for twin in twins.dropFirst() {
                for stay in (twin.stays ?? []).sorted(by: { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) })
                where !stays.contains(where: { $0.id == stay.id }) {
                    stays.append(DissolvedTripRecord.StayRef(
                        id: stay.id, categoryRaw: stay.categoryRaw, orderInTrip: stay.orderInTrip,
                        temporaryHomeID: stay.temporaryHomeID,
                        temporaryHomeRevision: stay.temporaryHomeRevision))
                }
            }
            record.stays = stays.map { ref in
                var ref = ref
                ref.wasOverridden = settings[ref.id]?.userOverridden ?? false
                return ref
            }
            let names = twins.compactMap(\.customName)
            record.customName = names.first
            var otherNames: [String] = []
            for name in names.dropFirst() {
                guard let normalized = TripTitleStore.normalized(name),
                      normalized != TripTitleStore.normalized(record.customName),
                      !otherNames.contains(where: { TripTitleStore.normalized($0) == normalized })
                else { continue }
                otherNames.append(name)
            }
            record.otherCustomNames = otherNames.isEmpty ? nil : otherNames
            record.userEdited = twins.contains { $0.userEdited && !$0.keptByTemporaryHome }
            record.keptByTemporaryHome = false
            record.splitByTemporaryHomeID = temporaryHomeID
            record.wasFavourite = pinnedTripIDs.contains(id)
            records.append(record)
        }
        return records
    }

    /// The split as it stands before the unit's save: every recorded stay's
    /// category and setting, and every piece the split made that holds one of
    /// them. A trip that existed before the unit is never one: Keep as One
    /// Trip then finds no baseline for it and blocks instead of deleting it.
    static func recordPostSplitState(
        in record: inout DissolvedTripRecord, stays: [Stay], existingTripIDs: Set<UUID>
    ) {
        let wanted = Set(record.stays.map(\.id))
        let rows = stays.filter { wanted.contains($0.id) }
        let byID = Dictionary(grouping: rows, by: \.id)
        record.stays = record.stays.map { ref in
            var ref = ref
            if let stay = byID[ref.id]?.first {
                ref.postSplitCategoryRaw = stay.categoryRaw
                ref.postSplitOverridden = stay.userOverridden
            }
            return ref
        }
        var holders: [DissolvedTripRecord.SplitHolderRef] = []
        var seen = Set<ObjectIdentifier>()
        for stay in rows.sorted(by: { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }) {
            guard let holder = stay.trip, !holder.isDeleted, !existingTripIDs.contains(holder.id),
                  seen.insert(ObjectIdentifier(holder)).inserted else { continue }
            holders.append(DissolvedTripRecord.SplitHolderRef(
                tripID: holder.id,
                stayIDs: holder.orderedStays.map(\.id),
                userEdited: holder.userEdited,
                customName: holder.customName))
        }
        record.postSplitHolders = holders.isEmpty ? nil : holders
    }

    /// A split changes trip identity, not the user's privacy choice. Each new
    /// logical piece gets its own hidden rows; pins remain with the archive.
    /// The local baseline recognizes these copies, so Keep can still reverse
    /// an untouched split and detects an unhide or a newly hidden photo.
    func inheritHiddenPhotos(in record: inout DissolvedTripRecord) {
        // Match normal annotation dedup before minting fresh ids, so duplicate
        // archived rows cannot make maintenance invalidate an untouched baseline.
        // A row without a cloud id takes the one another archived row of its
        // stored photo carries, a pin included, as cloud-id backfill will give it.
        let annotations = (record.photoAnnotations ?? []).sorted {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }
        let knownCloud = Dictionary(
            annotations.compactMap { ref in ref.cloudIdentifier.map { (ref.localIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first })
        let sorted = annotations.filter { !$0.isPinned }
        func cloudIdentifier(of ref: DissolvedTripRecord.PhotoAnnotationRef) -> String? {
            ref.cloudIdentifier ?? knownCloud[ref.localIdentifier]
        }
        var seenHidden = Set<String>()
        let hidden = sorted.filter { seenHidden.insert(cloudIdentifier(of: $0) ?? $0.localIdentifier).inserted }
        guard !hidden.isEmpty else { return }
        var copied: [UUID: [UUID]] = [:]
        record.postSplitHolders = record.postSplitHolders?.map { baseline in
            var baseline = baseline
            if copied[baseline.tripID] == nil {
                copied[baseline.tripID] = hidden.map { ref in
                    let row = HiddenPhoto(localIdentifier: ref.localIdentifier, tripID: baseline.tripID)
                    row.cloudIdentifier = cloudIdentifier(of: ref)
                    row.hiddenAt = ref.date
                    modelContext.insert(row)
                    return row.id
                }
            }
            baseline.inheritedHiddenPhotoIDs = copied[baseline.tripID]
            return baseline
        }
    }

    /// Fresh pieces are born in this split batch. Keep each archive's own row
    /// ids, and separately flag sharing: dedup may collapse identical hides
    /// from two archives, but keeping one must not erase the other's choice.
    static func markSharedInheritedHiddenPhotos(in records: inout [DissolvedTripRecord]) {
        var archivesByHolder: [UUID: Set<UUID>] = [:]
        for record in records {
            for holder in record.postSplitHolders ?? [] where !(holder.inheritedHiddenPhotoIDs ?? []).isEmpty {
                archivesByHolder[holder.tripID, default: []].insert(record.id)
            }
        }
        for index in records.indices {
            records[index].postSplitHolders = records[index].postSplitHolders?.map { baseline in
                var baseline = baseline
                baseline.sharesInheritedHiddenPhotos = (archivesByHolder[baseline.tripID]?.count ?? 0) > 1 ? true : nil
                return baseline
            }
        }
    }

    /// Restore the original Trip.id and original stay categories/order only when recorded stays are available and unclaimed.
    /// Manual restoration marks stays sacred; auto-rescue relies on the late-arriving pin or photo guard,
    /// so withdrawing that guard allows future healing. Missing stays may still be hydrating: keep the queue record.
    /// Callers decide whether claimed-stay records remain queued. A row with the id that came back without
    /// all its stays is the one the unassigned ones reattach to, so the trip never gains a second identity.
    nonisolated enum RestoreOutcome: Sendable, Equatable {
        case restored
        /// The trip is already present with its stays and none of its
        /// recorded stays is left unassigned, now with every photo row the
        /// record held, so callers may prune the record.
        case alreadyExists
        case staysClaimed
        case staysMissing
        /// Multiple physical rows (or duplicate ids in the record) make an
        /// exact restore ambiguous. Keep the recovery record and retry after
        /// store convergence; never guess which physical row to attach.
        case staysAmbiguous
        /// The graph was assembled in memory but could not be committed.
        /// Callers must keep the queue record so the restore can be retried.
        case saveFailed
    }

    func fetchForDissolvedRestore<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) throws -> [T] {
        #if DEBUG
        dissolvedRestoreFetchCallCountForTesting += 1
        if failingDissolvedRestoreFetchCallForTesting
            == dissolvedRestoreFetchCallCountForTesting {
            failingDissolvedRestoreFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try modelContext.fetch(descriptor)
    }

    func restoreDissolvedTrip(
        _ record: DissolvedTripRecord, markStaysSacred: Bool
    ) -> RestoreOutcome {
        // A split archive comes back only through Keep as One Trip, never here:
        // its stays belong to the pieces of the split.
        guard !record.isSplitRecord else { return .staysClaimed }
        let tripID = record.id
        let existing: [Trip]
        do {
            existing = try fetchForDissolvedRestore(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID }))
        } catch {
            logger.error("Dissolved trip identity read failed: \(error.localizedDescription)")
            return .saveFailed
        }
        // A row holding stays is the trip back by another route (a sync, an
        // import, an earlier restore), possibly before every Stay record that
        // links to it. Populated twins are all the trip: never guess between them.
        let populated = existing.filter { !($0.stays ?? []).isEmpty }
        if populated.count > 1 {
            // Every populated twin is the trip, so each takes a temporary
            // home's keep mark the record carries.
            for twin in populated { Self.mergeTemporaryHomeMarks(of: record, into: twin) }
            return commitPhotoAnnotationsOfReturnedTrip(record) ? .alreadyExists : .saveFailed
        }
        if let returnedTrip = populated.first {
            return completeReturnedTrip(
                returnedTrip, from: record, markStaysSacred: markStaysSacred)
        }
        // A row without stays came back apart from the Stay records that link
        // to it (in flight, or a resurrection after the unlink): the recorded
        // stays reattach to it below, or assembly would re-mint them under a
        // new UUID beside it. Never guess between stayless twins; the ghost
        // sweep converges them.
        guard existing.count <= 1 else { return .staysAmbiguous }
        let returnedTrip = existing.first

        let wantedIDs = record.stays.map(\.id)
        let recordedIDs = Set(wantedIDs)
        guard !wantedIDs.isEmpty else { return .staysMissing }
        guard recordedIDs.count == wantedIDs.count else {
            return .staysAmbiguous
        }
        let candidates: [Stay]
        do {
            candidates = try fetchForDissolvedRestore(FetchDescriptor<Stay>(
                predicate: #Predicate { wantedIDs.contains($0.id) }))
        } catch {
            logger.error("Dissolved stay identity read failed: \(error.localizedDescription)")
            return .saveFailed
        }
        let candidatesByID = Dictionary(grouping: candidates, by: \.id)
        var stays: [Stay] = []
        stays.reserveCapacity(wantedIDs.count)
        for id in wantedIDs {
            guard let rows = candidatesByID[id], !rows.isEmpty else {
                return .staysMissing
            }
            guard rows.count == 1 else { return .staysAmbiguous }
            guard rows[0].trip == nil else { return .staysClaimed }
            stays.append(rows[0])
        }

        let trip: Trip
        if let returnedTrip {
            // Keep the user's intent it synced with; carry only what it lacks,
            // as the ghost sweep's carry does.
            trip = returnedTrip
            if TripTitleStore.normalized(trip.customName) == nil,
               TripTitleStore.normalized(record.customName) != nil {
                trip.customName = record.customName
            }
            Self.mergeEditMarks(of: record, into: trip)
            // Its span describes no stays and may be a lagging device's copy of
            // another membership; the record's describes exactly the stays
            // reattached below. A homecoming another device saw keeps it closed.
            trip.startDate = record.startDate
            if record.isComplete || !trip.isComplete {
                trip.isComplete = record.isComplete
                trip.endDate = record.endDate
            }
        } else {
            trip = Trip(
                startDate: record.startDate,
                source: DataSource(rawValue: record.sourceRaw) ?? .liveSLC)
            trip.id = record.id
            trip.endDate = record.endDate
            // Restore ongoing trips as ongoing; closeStaleOpenTrips handles any homecoming since they were parked.
            trip.isComplete = record.isComplete
            trip.destinationSummary = record.destinationSummary
            trip.countryCodes = record.countryCodes
            trip.classifiedByAI = record.classifiedByAI
            trip.customName = record.customName
            trip.userEdited = record.userEdited
            trip.keptByTemporaryHome = record.userEdited && record.keptByTemporaryHome == true
            modelContext.insert(trip)
        }

        let refByID = Dictionary(
            record.stays.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        for stay in stays {
            guard let ref = refByID[stay.id] else { continue }
            if StayCategory(rawValue: ref.categoryRaw) != nil {
                stay.categoryRaw = ref.categoryRaw
                Self.restoreProvenance(of: stay, from: ref)
            }
            stay.trip = trip
            stay.orderInTrip = ref.orderInTrip
            if markStaysSacred { stay.userOverridden = true }
        }
        if returnedTrip != nil { Self.coverClosedSpan(of: trip, members: stays) }
        // Restored categories, and an undo's freed home stays, change the
        // home-place inputs inside this unit.
        TripTitleStore.invalidateHomePlaceIndex()
        // Photo rows commit with the trip so a restore never lands without them.
        do {
            // Re-derive summary/countries/provenance from the exact restored
            // set. The restore commits once and the record is pruned after
            // it, so an unreadable home-place index rolls back and retries.
            guard trip.recomputeSummary() else { throw TripTitleStore.HomePlaceNamesUnreadable() }
            applyRecordedDerivedArtifacts(
                of: record, to: trip, replacingSynced: returnedTrip != nil)
            try insertMissingPhotoAnnotations(of: record)
            try saveDissolvedRestore()
            return .restored
        } catch {
            modelContext.rollback()
            // Never serve a home-place snapshot built from rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("Dissolved trip restore save failed: \(error.localizedDescription)")
            return .saveFailed
        }
    }

    /// Stay place/boundary/category inputs and active Homes may change while a Trip is parked outside SwiftData.
    /// Restore generated titles only when both snapshots still describe today's prompt; otherwise normal lazy
    /// generation refills them from honest inputs. A stored narrative is never regenerated, so a row without
    /// one takes the record's whatever changed; a row's own gives way only to a record whose semantics still
    /// match. `replacingSynced` marks a returned row, whose own synced titles are dropped unless the record
    /// proves its title (custom names are never touched).
    private func applyRecordedDerivedArtifacts(
        of record: DissolvedTripRecord, to trip: Trip, replacingSynced: Bool
    ) {
        let semanticStillMatches = record.derivedSemanticDigest
            == TripTitleStore.semanticDigest(
                for: TripTitleStore.semanticSnapshot(for: trip))
        let homeFingerprintStillMatches = (try? TripTitleStore
            .fetchActiveHomeTitleInputs(in: modelContext)).map {
                TripTitleStore.activeHomeTitleFingerprintMatches(
                    record.activeHomeTitleFingerprint, currentInputs: $0)
            } ?? false
        #if DEBUG
        let titleRevocationPending =
            generatedTitleRevocationPendingOverrideForTesting
            ?? DissolvedTripQueue.generatedTitleRevocationIsPending()
        #else
        let titleRevocationPending =
            DissolvedTripQueue.generatedTitleRevocationIsPending()
        #endif
        let titleInputsStillMatch = !titleRevocationPending
            && semanticStillMatches
            && homeFingerprintStillMatches

        // A returned row's artifacts were made for whatever membership it
        // synced with. Its title stands only when it is the record's own and
        // the record is proven for these inputs; it keeps every translation.
        var keepsSyncedTitle = false
        if replacingSynced {
            let recordedTitle = TripTitleStore.normalized(record.aiGeneratedTitle)
            keepsSyncedTitle = titleInputsStillMatch && recordedTitle != nil
                && TripTitleStore.normalized(trip.aiGeneratedTitle) == recordedTitle
            if !keepsSyncedTitle {
                TripTitleStore.invalidateGeneratedTitles(for: trip, in: modelContext)
            }
        }

        if semanticStillMatches || (trip.aiGeneratedSummary ?? "").isEmpty,
           let summary = record.aiGeneratedSummary, !summary.isEmpty {
            trip.aiGeneratedSummary = summary
            trip.summarySourceRaw = record.summarySourceRaw
            trip.summaryGeneratedAt = record.endDate ?? record.startDate
        }
        if titleInputsStillMatch, !keepsSyncedTitle,
           let canonicalTitle = TripTitleStore.normalized(
                record.aiGeneratedTitle) {
            trip.aiGeneratedTitle = canonicalTitle
            trip.titleSourceRevision = record.titleSourceRevision
            var localizedTitlesByKey: [[String]: DissolvedTripRecord.LocalizedTitleRef] = [:]
            for ref in record.localizedTitles ?? [] {
                guard let languageTag = AppLanguagePreference.normalizedSupportedTag(
                        ref.languageTag),
                      languageTag != "en",
                      let title = TripTitleStore.normalized(ref.title),
                      TripTitleStore.isUsableVariantTitle(
                          title, languageTag: languageTag),
                      TripTitleStore.normalized(ref.sourceTitle) == canonicalTitle,
                      ref.sourceRevision == record.titleSourceRevision,
                      ref.generationVersion >= TripTitleStore.currentGenerationVersion
                else { continue }
                let normalizedRef = DissolvedTripRecord.LocalizedTitleRef(
                    id: ref.id, languageTag: languageTag, title: title,
                    sourceTitle: canonicalTitle,
                    generationVersion: ref.generationVersion,
                    updatedAt: ref.updatedAt,
                    sourceRevision: ref.sourceRevision)
                let key = [
                    languageTag, canonicalTitle,
                    ref.sourceRevision?.uuidString ?? "legacy",
                ]
                guard let existing = localizedTitlesByKey[key] else {
                    localizedTitlesByKey[key] = normalizedRef
                    continue
                }
                if TripTitleStore.hasPreferredContent(
                    .init(
                        id: normalizedRef.id, title: normalizedRef.title,
                        generationVersion: normalizedRef.generationVersion,
                        updatedAt: normalizedRef.updatedAt),
                    over: .init(
                        id: existing.id, title: existing.title,
                        generationVersion: existing.generationVersion,
                        updatedAt: existing.updatedAt)) {
                    localizedTitlesByKey[key] = normalizedRef
                }
            }
            for ref in localizedTitlesByKey.values {
                modelContext.insert(TripTitleVariant(
                    id: ref.id, languageTag: ref.languageTag,
                    title: ref.title, sourceTitle: ref.sourceTitle,
                    sourceRevision: ref.sourceRevision,
                    generationVersion: ref.generationVersion,
                    updatedAt: ref.updatedAt, trip: trip))
            }
        }
    }

    private func saveDissolvedRestore() throws {
        #if DEBUG
        if failNextDissolvedRestoreSaveForTesting {
            failNextDissolvedRestoreSaveForTesting = false
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
        try modelContext.save()
    }

    /// The recorded stays a returned trip lacks that Restore can reattach: each id's single row without a trip.
    /// Twin rows of an id, one of them unassigned, make the attach ambiguous; stays on a trip or absent stay as
    /// they are. Restore, its settle and the Removed Trips list share this so they agree on when a trip is back.
    nonisolated static func unassignedRecordedStays(
        of record: DissolvedTripRecord, among stays: [Stay]
    ) -> (reattachable: [Stay], ambiguous: Bool) {
        let rowsByID = Dictionary(grouping: stays, by: \.id)
        var seen = Set<UUID>()
        var reattachable: [Stay] = []
        var ambiguous = false
        for ref in record.stays where seen.insert(ref.id).inserted {
            let rows = rowsByID[ref.id] ?? []
            guard rows.contains(where: { $0.trip == nil }) else { continue }
            if rows.count == 1 { reattachable.append(rows[0]) } else { ambiguous = true }
        }
        return (reattachable, ambiguous)
    }

    /// Whether a queued record's trip is back whole as this device's store shows it, so the record may go: a row
    /// with its id holds stays and no recorded stay is left for Restore to reattach. Recorded stays absent from the
    /// store are taken as deleted. Populated twins are all the trip. `rows` are the rows with the record's id,
    /// `stays` the rows with its recorded stay ids.
    nonisolated static func returnedTripIsWhole(
        _ record: DissolvedTripRecord, rows: [Trip], stays: [Stay]
    ) -> Bool {
        // A split archive is never settled as returned: it leaves the
        // queue after a committed Keep as One Trip or the user's Forget.
        guard !record.isSplitRecord else { return false }
        let populated = rows.filter { $0.id == record.id && !($0.stays ?? []).isEmpty }
        guard populated.count == 1 else { return populated.count > 1 }
        let left = unassignedRecordedStays(of: record, among: stays)
        return left.reattachable.isEmpty && !left.ambiguous
    }

    private func fetchRecordedStays(of record: DissolvedTripRecord) throws -> [Stay] {
        let ids = record.stays.map(\.id)
        guard !ids.isEmpty else { return [] }
        return try fetchForDissolvedRestore(FetchDescriptor<Stay>(
            predicate: #Predicate { ids.contains($0.id) }))
    }

    /// A raw category restore skips the setter, so provenance comes back with
    /// it here: the recorded pair with a home category, else none.
    nonisolated private static func restoreProvenance(
        of stay: Stay, from ref: DissolvedTripRecord.StayRef
    ) {
        if ref.categoryRaw == StayCategory.home.rawValue {
            stay.setTemporaryHomeProvenance(ref.temporaryHomeID, revision: ref.temporaryHomeRevision)
        } else {
            stay.setTemporaryHomeProvenance(nil, revision: nil)
        }
    }

    /// A closed trip never ends before one of its stays does.
    nonisolated private static func coverClosedSpan(of trip: Trip, members: [Stay]) {
        guard trip.isComplete, let lastEnd = members.map(\.endTime).max(),
              (trip.endDate ?? .distantPast) < lastEnd else { return }
        trip.endDate = lastEnd
    }

    /// The record's trip is back with stays, possibly before every Stay record that links to it. Reattach the
    /// recorded stays still unassigned as a fresh restore would (recorded category, sacred for a manual restore),
    /// or the next assembly re-mints them under a new UUID beside it (an edited trip is never regrouped). Its own
    /// stays and synced fields stay; twin stay rows keep the record for after convergence.
    /// Carries a record's edit marks onto a trip row it is restored into. The
    /// mark stays a temporary home's only when every edited side's was: an
    /// edit of the user's own on either side owns the trip.
    nonisolated private static func mergeEditMarks(of record: DissolvedTripRecord, into trip: Trip) {
        let userOwned = (trip.userEdited && !trip.keptByTemporaryHome)
            || (record.userEdited && record.keptByTemporaryHome != true)
        if record.userEdited && !trip.userEdited { trip.userEdited = true }
        let keptByTemporaryHome = trip.userEdited && !userOwned
        if trip.keptByTemporaryHome != keptByTemporaryHome {
            trip.keptByTemporaryHome = keptByTemporaryHome
        }
    }

    /// `mergeEditMarks` where a temporary home's keep mark is involved on either
    /// side. A returned row that already holds stays never took the record's
    /// ordinary edit mark, and still does not.
    nonisolated private static func mergeTemporaryHomeMarks(
        of record: DissolvedTripRecord, into trip: Trip
    ) {
        guard record.keptByTemporaryHome == true || trip.keptByTemporaryHome else { return }
        mergeEditMarks(of: record, into: trip)
    }

    private func completeReturnedTrip(
        _ trip: Trip, from record: DissolvedTripRecord, markStaysSacred: Bool
    ) -> RestoreOutcome {
        let left: (reattachable: [Stay], ambiguous: Bool)
        do {
            left = Self.unassignedRecordedStays(
                of: record, among: try fetchRecordedStays(of: record))
        } catch {
            logger.error("Returned trip stay read failed: \(error.localizedDescription)")
            return .saveFailed
        }
        guard !left.ambiguous else { return .staysAmbiguous }
        // A row that came back populated still takes a temporary home's keep mark.
        Self.mergeTemporaryHomeMarks(of: record, into: trip)
        guard !left.reattachable.isEmpty else {
            return commitPhotoAnnotationsOfReturnedTrip(record) ? .alreadyExists : .saveFailed
        }
        let refByID = Dictionary(
            record.stays.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        for stay in left.reattachable {
            if let ref = refByID[stay.id], StayCategory(rawValue: ref.categoryRaw) != nil {
                stay.categoryRaw = ref.categoryRaw
                Self.restoreProvenance(of: stay, from: ref)
            }
            stay.trip = trip
            if markStaysSacred { stay.userOverridden = true }
        }
        // Number the joined membership chronologically, as assembly and a merge
        // do, and widen the span to cover it without narrowing what synced.
        var members = trip.stays ?? []
        for stay in left.reattachable where !members.contains(where: { $0 === stay }) {
            members.append(stay)
        }
        members.sort { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
        for (order, stay) in members.enumerated() where stay.orderInTrip != order {
            stay.orderInTrip = order
        }
        if let first = members.first, first.startTime < trip.startDate {
            trip.startDate = first.startTime
        }
        Self.coverClosedSpan(of: trip, members: members)
        // Restored categories, and an undo's freed home stays, change the
        // home-place inputs inside this unit.
        TripTitleStore.invalidateHomePlaceIndex()
        do {
            // A summary without its home-place filter must not commit with
            // the record's one completion; roll back and keep the record.
            guard trip.recomputeSummary() else { throw TripTitleStore.HomePlaceNamesUnreadable() }
            // The joined membership may not be the one its synced artifacts described.
            applyRecordedDerivedArtifacts(of: record, to: trip, replacingSynced: true)
            try insertMissingPhotoAnnotations(of: record)
            try saveDissolvedRestore()
            return .restored
        } catch {
            modelContext.rollback()
            // Never serve a home-place snapshot built from rolled-back rows.
            TripTitleStore.invalidateHomePlaceIndex()
            logger.error("Returned trip completion save failed: \(error.localizedDescription)")
            return .saveFailed
        }
    }

    /// The record's trip came back by another route (a CloudKit resurrection, an import, an earlier restore) and
    /// callers prune the record next, so commit the photo rows only it may still hold, with the unit's pending
    /// edits (undo's stays). A failed read or save rolls back and returns false so the record stays queued.
    private func commitPhotoAnnotationsOfReturnedTrip(_ record: DissolvedTripRecord) -> Bool {
        do {
            try insertMissingPhotoAnnotations(of: record)
            if modelContext.hasChanges { try saveDissolvedRestore() }
            return true
        } catch {
            modelContext.rollback()
            logger.error("Returned trip photo annotation commit failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Settle queued records whose trip is back whole before the Removed Trips list prunes them: commit the photo
    /// rows only the record may hold. Returns the ids safe to prune. A trip that is gone again or still lacks
    /// unassigned recorded stays (Restore reattaches them), or a failed read or save, keeps its record; this never
    /// re-mints a trip.
    func settleReturnedDissolvedTrips(_ records: [DissolvedTripRecord]) -> [UUID] {
        var settled: [UUID] = []
        for record in records where !record.isSplitRecord {
            let tripID = record.id
            do {
                let rows = try fetchForDissolvedRestore(FetchDescriptor<Trip>(
                    predicate: #Predicate { $0.id == tripID }))
                guard rows.contains(where: { !($0.stays ?? []).isEmpty }),
                      Self.returnedTripIsWhole(
                        record, rows: rows, stays: try fetchRecordedStays(of: record))
                else { continue }
            } catch {
                logger.error("Returned trip identity read failed: \(error.localizedDescription)")
                continue
            }
            if commitPhotoAnnotationsOfReturnedTrip(record) { settled.append(tripID) }
        }
        return settled
    }

    /// Rescue trips protected by late-synced pins or photo choices; those guards provide protection without sacred stay stamps.
    /// A trip with a stay the user set since it was parked (`userSetStaySinceParking`), or whose stays are unreadable, stays
    /// queued for Removed Trips. Prune restored or already-existing trips; keep other outcomes queued for retry.
    func rescueDissolvedTrips(
        _ records: [DissolvedTripRecord], pinnedTripIDs: Set<UUID>
    ) -> (restored: [UUID], prunable: [UUID]) {
        guard !records.isEmpty else { return ([], []) }
        let hiddenTripIDs = Set(((try? modelContext.fetch(
            FetchDescriptor<HiddenPhoto>())) ?? []).compactMap(\.tripID))
        let pinnedPhotoTripIDs = Set(((try? modelContext.fetch(
            FetchDescriptor<PinnedPhoto>())) ?? []).compactMap(\.tripID))
        let guarded = pinnedTripIDs.union(hiddenTripIDs).union(pinnedPhotoTripIDs)

        var restored: [UUID] = []
        var prunable: [UUID] = []
        for record in records where guarded.contains(record.id) && !record.isSplitRecord {
            do {
                if try userSetStaySinceParking(record) { continue }
            } catch {
                logger.error("Dissolved trip rescue skipped; stays unreadable: \(error.localizedDescription)")
                continue
            }
            switch restoreDissolvedTrip(record, markStaysSacred: false) {
            case .restored: restored.append(record.id)
            case .alreadyExists: prunable.append(record.id)
            case .staysClaimed, .staysMissing, .staysAmbiguous, .saveFailed:
                break
            }
        }
        return (restored, prunable)
    }

    /// Undo's sweep of Removed Trips: a sibling the withdrawn teaching freed comes back unsacred, and the undone trip's
    /// own record reports `.alreadyExists`. Nil leaves the record queued, by the rescue's guard: an earlier demotion's
    /// trip, whose stays are still the user's home, never comes back here, nor one whose stays are unreadable.
    func restoreFreedSibling(_ record: DissolvedTripRecord) -> RestoreOutcome? {
        do {
            if try userSetStaySinceParking(record) { return nil }
        } catch {
            logger.error("Undo sibling restore skipped; stays unreadable: \(error.localizedDescription)")
            return nil
        }
        return restoreDissolvedTrip(record, markStaysSacred: false)
    }

    /// Whether the rescue would mint the record's trip again over a recorded stay the user set since it was parked: one
    /// now unassigned and userOverridden with another category than recorded (a restore never rewrites a stay on a
    /// trip). Healing and a temporary home's unit leave no recorded stay so set, so on their records one is always later
    /// user work. A demotion stamps its own stays that way, so its record, and one written before the mark, still
    /// completes a row back under its id.
    private func userSetStaySinceParking(_ record: DissolvedTripRecord) throws -> Bool {
        let recorded = Dictionary(
            record.stays.map { ($0.id, $0.categoryRaw) },
            uniquingKeysWith: { first, _ in first })
        guard try fetchRecordedStays(of: record).contains(where: {
            $0.trip == nil && $0.userOverridden && recorded[$0.id] != $0.categoryRaw
        }) else { return false }
        if record.dissolvedByDemotion == false { return true }
        let tripID = record.id
        return try fetchForDissolvedRestore(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID })).isEmpty
    }

    // MARK: - Keep as One Trip

    /// What Keep as One Trip did with a split archive. Only `kept` lets the
    /// caller pin the favourite again and remove the record.
    nonisolated enum KeepSplitOutcome: Sendable, Equatable {
        /// Committed: the trip is whole under its own id and kept, or it
        /// already was (a finish the caller did not get to before).
        case kept
        /// Work done since the split stands in the way, and nothing changed.
        /// Each reason names it: a trip now holding a recorded stay, or a
        /// recorded stay the user set since.
        case blocked(reasons: [String])
        /// A recorded stay is not on this device (yet).
        case staysMissing
        /// Twin rows make the restore ambiguous; retry after convergence.
        case staysAmbiguous
        /// A read or the save failed; nothing changed.
        case saveFailed
    }

    /// Keep as One Trip: puts a split trip back under its id in one save, or changes
    /// nothing; every read and check comes first. It blocks on work since the split,
    /// measured against the archive's post-split state rather than what the split left
    /// (a piece holding a stay the user had set is edited from birth), and on trips
    /// holding a recorded stay the split did not make. Once its declaration is confirmed
    /// removed, automatically regrouped holders containing only recorded stays and no
    /// user work are also eligible. A row already holding exactly the recorded stays
    /// is a committed Keep and finishes. Otherwise the holders go, the
    /// trip returns with its stays' categories, settings, provenance and photo rows,
    /// edited, and its id joins the kept trips of every row of its temporary home while
    /// that is live. `automatic` (a removal's own Keep) also blocks on a recorded stay,
    /// not home before the split, that is home now or inside a live anchor at its time.
    /// Before the save, each holder's id no populated twin keeps is logged as carried
    /// onto it in `defaults` (`TripDeduplicator.logCarries`); a failed save restores the
    /// log. The caller holds the gate and primed shapes.
    func keepSplitTripWhole(
        _ record: DissolvedTripRecord, pinnedTripIDs: Set<UUID>, automatic: Bool = false,
        defaults: UserDefaults = .standard
    ) -> KeepSplitOutcome {
        guard let declarationID = record.splitByTemporaryHomeID else { return .staysAmbiguous }
        let tripID = record.id
        let wantedIDs = record.stays.map(\.id)
        guard !wantedIDs.isEmpty else { return .staysMissing }
        guard Set(wantedIDs).count == wantedIDs.count else { return .staysAmbiguous }
        let existing: [Trip]
        let candidates: [Stay]
        let declarations: [TemporaryHome]
        do {
            existing = try fetchForDissolvedRestore(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.id == tripID }))
            candidates = try fetchForDissolvedRestore(FetchDescriptor<Stay>(
                predicate: #Predicate { wantedIDs.contains($0.id) }))
            declarations = try fetchForDissolvedRestore(FetchDescriptor<TemporaryHome>(
                predicate: #Predicate { $0.id == declarationID }))
        } catch {
            logger.error("Keep as One Trip skipped; unreadable: \(error.localizedDescription)")
            return .saveFailed
        }
        let rowsByID = Dictionary(grouping: candidates, by: \.id)
        var stays: [Stay] = []
        for id in wantedIDs {
            guard let rows = rowsByID[id], !rows.isEmpty else { return .staysMissing }
            guard rows.count == 1 else { return .staysAmbiguous }
            stays.append(rows[0])
        }
        let declarationWasRemoved = declarations.contains { $0.removedAt != nil }
        let liveDeclaration = !declarations.isEmpty && !declarationWasRemoved
        func finish(_ trip: Trip, replacingSynced: Bool?) -> KeepSplitOutcome {
            if liveDeclaration { for row in declarations { row.addKeptTrip(tripID) } }
            do {
                if let replacingSynced {
                    guard trip.recomputeSummary() else { throw TripTitleStore.HomePlaceNamesUnreadable() }
                    applyRecordedDerivedArtifacts(of: record, to: trip, replacingSynced: replacingSynced)
                }
                try insertMissingPhotoAnnotations(of: record)
                if modelContext.hasChanges { try saveDissolvedRestore() }
                return .kept
            } catch {
                modelContext.rollback()
                // Never serve a home-place snapshot built from rolled-back rows.
                TripTitleStore.invalidateHomePlaceIndex()
                logger.error("Keep as One Trip save failed: \(error.localizedDescription)")
                return .saveFailed
            }
        }

        // A row under the id that holds stays: exactly the recorded ones is
        // this Keep, committed before its record went; anything else is
        // another trip back under that id, which this does not overwrite.
        let populated = existing.filter { !($0.stays ?? []).isEmpty }
        if !populated.isEmpty {
            guard populated.count == 1, let back = populated.first,
                  Set((back.stays ?? []).map(\.id)) == Set(wantedIDs) else {
                return .blocked(reasons: populated.map(\.displayName))
            }
            if !back.userEdited {
                back.userEdited = true
                back.keptByTemporaryHome = !record.userEdited
            }
            return finish(back, replacingSynced: nil)
        }
        guard existing.count <= 1 else { return .staysAmbiguous }

        var holders: [Trip] = []
        for stay in stays {
            if let holder = stay.trip, !holders.contains(where: { $0 === holder }) {
                holders.append(holder)
            }
        }
        let holderIDs = holders.map(\.id)
        let hiddenByTrip: [UUID: Set<UUID>]
        let pinnedPhotoTripIDs: Set<UUID>
        let anchors: [HomeAnchor]
        let overrides: [HomeAreaOverride]
        let homeStays: [Stay]
        let liveKeptTripIDs: Set<UUID>
        do {
            let hidden = try fetchForDissolvedRestore(FetchDescriptor<HiddenPhoto>(
                predicate: #Predicate { holderIDs.contains($0.tripID) }))
            let pinned = try fetchForDissolvedRestore(FetchDescriptor<PinnedPhoto>(
                predicate: #Predicate { holderIDs.contains($0.tripID) }))
            hiddenByTrip = Dictionary(grouping: hidden, by: \.tripID).mapValues { Set($0.map(\.id)) }
            pinnedPhotoTripIDs = Set(pinned.map(\.tripID))
            anchors = try fetchRequiredAnchors()
            overrides = try fetchForDissolvedRestore(FetchDescriptor<HomeAreaOverride>())
            let homeRaw = StayCategory.home.rawValue
            homeStays = try fetchForDissolvedRestore(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.categoryRaw == homeRaw }))
            let temporaryHomes = try fetchForDissolvedRestore(FetchDescriptor<TemporaryHome>())
            let removedIDs = HomeAnchors.removedIDs(temporaryHomes)
            liveKeptTripIDs = TemporaryHome.keptTripIDs(
                of: temporaryHomes.filter { !removedIDs.contains($0.id) })
        } catch {
            logger.error("Keep as One Trip skipped; unreadable: \(error.localizedDescription)")
            return .saveFailed
        }

        // Pieces are minted fresh, so a name, a favourite or a photo choice on
        // one is the user's work since the split; so is an edit mark the split
        // did not leave, another stay of it set since, or a recorded stay set
        // differently since. A piece that gained or lost stays since (a merge
        // or a split) changed whatever its edit mark: one edited from birth
        // carries no new mark for it. A confirmed removal permits only the
        // archived-only generated graph, not a holder carrying anyone else's stays.
        // A trip a live temporary home keeps is the user's explicit choice.
        let before = Dictionary(
            (record.postSplitHolders ?? []).map { ($0.tripID, $0) },
            uniquingKeysWith: { first, _ in first })
        let refByID = Dictionary(
            record.stays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reasons: [String] = []
        for holder in holders.sorted(by: { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }) {
            if liveKeptTripIDs.contains(holder.id) {
                reasons.append(holder.displayName)
                continue
            }
            let baseline = before[holder.id]
            let photosChanged = baseline?.sharesInheritedHiddenPhotos == true
                || hiddenByTrip[holder.id, default: []]
                != Set(baseline?.inheritedHiddenPhotoIDs ?? [])
                || pinnedPhotoTripIDs.contains(holder.id)
            // Removal may automatically regroup the pieces. An explicit Keep
            // can take that generated graph only inside the archived members;
            // absence of the declaration is not proof that it was removed.
            let rebuiltAfterRemoval = declarationWasRemoved
                && Set((holder.stays ?? []).map(\.id)).isSubset(of: Set(wantedIDs))
                && holder.customName == nil && !pinnedTripIDs.contains(holder.id) && !photosChanged
                && (!holder.userEdited || holder.keptByTemporaryHome)
            guard let baseline else {
                if !rebuiltAfterRemoval { reasons.append(holder.displayName) }
                continue
            }
            let laterWork = (holder.customName != nil && holder.customName != baseline.customName)
                || pinnedTripIDs.contains(holder.id) || photosChanged
                || (Set((holder.stays ?? []).map(\.id)) != Set(baseline.stayIDs) && !rebuiltAfterRemoval)
                || (!baseline.userEdited
                    && ((holder.userEdited && !holder.keptByTemporaryHome)
                        || (holder.stays ?? []).contains { $0.userOverridden && refByID[$0.id] == nil }))
            if laterWork { reasons.append(holder.displayName) }
        }
        let homeRings = withShapes(anchors.map { Self.HomeRing($0) }, overrides: overrides)
        for stay in stays {
            guard let ref = refByID[stay.id] else { continue }
            // A setting made since the split, or one the split left that the
            // user gave back to Automatic since: restoring would undo either.
            let changedSince = stay.userOverridden
                ? stay.categoryRaw != ref.postSplitCategoryRaw || ref.postSplitOverridden != true
                : ref.postSplitOverridden == true
            // A removal's own Keep never takes back a stay that was not home
            // before the split and is home now, or inside a live anchor at its
            // time as the pre-filter reads it (a Home whose unit reset it has
            // yet to classify it): an anchor claims it since (a real Home
            // declared after the split), which only the user's Keep overrides.
            // A stay the user had set is no anchor's to claim.
            let claimedSince = automatic && ref.categoryRaw != StayCategory.home.rawValue
                && (stay.category == .home || (ref.wasOverridden != true && Self.matchesHome(
                    stayStart: stay.startTime, latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude, homes: homeRings)))
            guard changedSince || claimedSince else { continue }
            reasons.append(stay.placeGroupName
                ?? stay.startTime.formatted(date: .abbreviated, time: .omitted))
        }
        guard reasons.isEmpty else { return .blocked(reasons: reasons) }

        // Every trip holding a recorded stay goes; its other stays return to
        // the pool. Annotation links do not cascade: accepted inherited rows
        // go with the holder, unless another populated UUID twin keeps them,
        // and with them the id. An id's last holder sees whether one is left.
        var twinKeptIDs = Set<UUID>()
        do {
            for holder in holders {
                if try deletePhotoAnnotationRows(for: holder) == nil {
                    twinKeptIDs.insert(holder.id)
                } else {
                    twinKeptIDs.remove(holder.id)
                }
                for stay in holder.stays ?? [] {
                    stay.trip = nil
                    stay.orderInTrip = nil
                }
                modelContext.delete(holder)
            }
        } catch {
            modelContext.rollback()
            return .saveFailed
        }
        let trip: Trip
        if let shell = existing.first {
            // Came back apart from its stays: they join it.
            trip = shell
            if TripTitleStore.normalized(trip.customName) == nil { trip.customName = record.customName }
        } else {
            trip = Trip(
                startDate: record.startDate,
                source: DataSource(rawValue: record.sourceRaw) ?? .liveSLC)
            trip.id = record.id
            trip.customName = record.customName
            modelContext.insert(trip)
        }
        trip.startDate = record.startDate
        trip.endDate = record.endDate
        trip.isComplete = record.isComplete
        trip.destinationSummary = record.destinationSummary
        trip.countryCodes = record.countryCodes
        trip.classifiedByAI = record.classifiedByAI
        // Kept: edited, as this feature's mark unless the user had edited it.
        let usersOwn = record.userEdited || (trip.userEdited && !trip.keptByTemporaryHome)
        trip.userEdited = true
        trip.keptByTemporaryHome = !usersOwn
        let ordered = stays.sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
        for (order, stay) in ordered.enumerated() {
            if let ref = refByID[stay.id], StayCategory(rawValue: ref.categoryRaw) != nil {
                if stay.categoryRaw != ref.categoryRaw { stay.categoryRaw = ref.categoryRaw }
                Self.restoreProvenance(of: stay, from: ref)
                let overridden = ref.wasOverridden ?? false
                if stay.userOverridden != overridden { stay.userOverridden = overridden }
            }
            stay.trip = trip
            if stay.orderInTrip != order { stay.orderInTrip = order }
        }
        Self.coverClosedSpan(of: trip, members: ordered)
        // Measured as assembly measures a trip: from the home it left.
        stampDistancesFromDepartureHome(
            ordered, homeStays: homeStays.filter { $0.category == .home }, homeRings: homeRings)
        // Restored categories change the home-place inputs inside this unit.
        TripTitleStore.invalidateHomePlaceIndex()
        // A photo choice or favourite another device made on a piece can sync
        // in after the piece went, and follows the carry log. Log before the
        // save, as the ghost sweep does, so an exit right after it loses no
        // carry; a failed save restores the log.
        let loggedCarries = defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey)
        TripDeduplicator.logCarries(
            Set(holderIDs).subtracting(twinKeptIDs).map { .init(ghostID: $0, winnerID: tripID) },
            defaults: defaults)
        let outcome = finish(trip, replacingSynced: existing.first != nil)
        if outcome != .kept { defaults.set(loggedCarries, forKey: TripDeduplicator.carriedFavouritesKey) }
        return outcome
    }

    /// `keepSplitTripWhole` as one gated unit reading favourites inside it, on the
    /// archive reread from `queueDirectory` (a retried split may have replaced the
    /// caller's): unreadable is `saveFailed`, gone `staysMissing`, an already committed
    /// Keep only finishes. A commit re-pins (`pin`), drops the photo cache and marks the
    /// archive committed before the gate lets go. `removedTemporaryHomeIDs` makes it a
    /// removal's own Keep (`automatic`): a reread archive that is no longer a committed,
    /// unkept split of one of them is `staysMissing`, and nothing changes.
    func keepSplitTripWhole(
        _ record: DissolvedTripRecord,
        pinnedTripIDs: @escaping @MainActor @Sendable () -> Set<UUID>,
        gate: PipelineGate = .shared,
        queueDirectory: URL? = nil,
        removedTemporaryHomeIDs: Set<UUID>? = nil,
        pin: @escaping @MainActor @Sendable (UUID) -> Void = { PinnedTripsStorage.shared.pin($0) }
    ) async -> KeepSplitOutcome {
        let id = record.id
        return await gate.runReturning(
            touching: [.temporaryHome, .stay, .trip, .hiddenPhoto, .pinnedPhoto]
        ) {
            let current: DissolvedTripRecord
            do {
                guard let queued = try DissolvedTripQueue.record(id: id, in: queueDirectory) else {
                    return KeepSplitOutcome.staysMissing
                }
                current = queued
            } catch {
                return KeepSplitOutcome.saveFailed
            }
            // A removal's own Keep takes only a committed, unkept split of a removed
            // id: a newer archive under this id (kept since, then split again by a
            // live declaration) is not the one it was handed.
            if let removedTemporaryHomeIDs,
               current.splitByTemporaryHomeID.map({ removedTemporaryHomeIDs.contains($0) }) != true
                || current.splitCommitted != true || current.keepCommitted == true {
                return KeepSplitOutcome.staysMissing
            }
            if current.keepCommitted == true { return KeepSplitOutcome.kept }
            guard await self.primeHomeShapes() else { return KeepSplitOutcome.saveFailed }
            let pinned = await pinnedTripIDs()
            let outcome = await self.keepSplitTripWhole(
                current, pinnedTripIDs: pinned, automatic: removedTemporaryHomeIDs != nil)
            guard outcome == .kept else { return outcome }
            await MainActor.run {
                if current.wasFavourite == true { pin(current.id) }
                if current.carriesPhotoAnnotations { PhotoService.shared.invalidateCache(for: current.id) }
            }
            // Without this mark a retry finds the trip whole and finishes it
            // through the completion path above, as before the mark existed.
            try? DissolvedTripQueue.markKeepCommitted(id: current.id, in: queueDirectory)
            return KeepSplitOutcome.kept
        }
    }
}
