//
//  TripDataImporter.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

// MARK: - Importer

/// Lossless restore of the app's own v15 backup (`TripDataExporter`):
/// every row lands as it was stored, with its original id, and merges into
/// a non-empty store by the rules below.
///
/// Design decisions:
///   - **Stays are PRE-LINKED to their trips.** `assembleTrips` only
///     touches stays with `trip == nil`, so imported trips keep their exact
///     boundaries, names, and stay sets — the pipeline cannot tear them
///     apart. Categories come from the file (not `.unclassified`), so the
///     classifier doesn't re-run on them either.
///   - **Pings are the recorded ones**, each with its own processed flag and
///     provenance: a pending ping stays pending, so clustering finishes what
///     the original store owed, and a processed one already backs its stay.
///   - **Idempotent by UUID:** a trip whose id already exists is skipped
///     wholesale (importing the same backup twice is a no-op); a stay, ping,
///     Visit or record whose id exists is skipped individually.
///   - **Hex cells keep their ids and re-entry counts.** A cell the store
///     holds under another id absorbs the file's as the deduplicator would,
///     and keeps its own id (`restoreHexVisits`).
///
/// Gate contract: callers wrap `importTrips(from:)` in
/// `PipelineGate.shared.runReturning` — a store-mutating operation like
/// every other pipeline unit — and `importTrips` itself performs NO geocode
/// awaits, so the unit's duration is bounded by the inserts alone. Stays
/// needing the offline place-layer heal are returned as value snapshots
/// (`pendingGeocodes()`); the caller runs `healPendingGeocodes(_:)` AFTER
/// its unit ends (never inside one — the gate is non-reentrant), which
/// resolves ungated and applies in short per-chunk gate units.
@ModelActor
actor TripDataImporter {
    let logger = Logger(subsystem: "com.travellog.app", category: "TripDataImporter")
    private struct DeferredTitleArtifacts {
        let trip: Trip
        let canonicalTitle: String
        let sourceRevision: UUID?
        let localizedTitles: [ImportedLocalizedTitle]
        /// True for a skipped-existing trip completed by this re-import,
        /// false for a trip this run inserted.
        var completesExistingTrip = false
    }
    #if DEBUG
    nonisolated enum BackfillTestScope {
        @TaskLocal static var defaultsSuiteName: String?
    }

    private var saveCallCountForTesting = 0
    private var failingSaveCallForTesting: Int?
    private var identityFetchCallCountForTesting = 0
    private var failingIdentityFetchCallForTesting: Int?

    func failSaveCallForTesting(_ call: Int) {
        saveCallCountForTesting = 0
        failingSaveCallForTesting = call
    }

    func failIdentityFetchCallForTesting(_ call: Int) {
        identityFetchCallCountForTesting = 0
        failingIdentityFetchCallForTesting = call
    }

    var hexVisitFetchCallCountForTesting = 0
    var failingHexVisitFetchCallForTesting: Int?
    func failHexVisitFetchCallForTesting(_ call: Int) {
        hexVisitFetchCallCountForTesting = 0
        failingHexVisitFetchCallForTesting = call
    }

    var pingChunkSaveCountForTesting = 0
    var failingPingChunkSaveForTesting: Int?
    func failPingChunkSaveForTesting(_ call: Int) {
        pingChunkSaveCountForTesting = 0
        failingPingChunkSaveForTesting = call
    }

    func setRemovedTripsDirectoryForTesting(_ directory: URL) {
        removedTripsDirectory = directory
    }

    func setHomeAliasDefaultsSuiteForTesting(_ suiteName: String) {
        homeAliasDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func setReconciliationDefaultsSuiteForTesting(_ suiteName: String) {
        reconciliationDefaultsSuite = suiteName
    }

    /// `CoverageReconciliationQueue`'s raw entry keys at the moment the
    /// injected save failure fired: what a kill at that save would leave.
    private(set) var queuedReconciliationKeysAtFailedSaveForTesting: Set<String> = []
    #endif

    /// Where the Home dedup alias log lives (`PlacesDeduplicator.homeAliasesKey`).
    private var homeAliasDefaults: UserDefaults = .standard

    /// The Removed Trips queue's directory; nil is Application Support.
    private var removedTripsDirectory: URL?

    /// The suite holding `CoverageReconciliationQueue`'s entries; nil is
    /// `.standard`. A name, not the object: the queue is written on the
    /// main actor and `UserDefaults` is not Sendable.
    private var reconciliationDefaultsSuite: String?

    // MARK: Commit

    /// Insert the payload's rows. Must run
    /// inside `PipelineGate.shared.runReturning` (store-mutating). Return
    /// the outcome and `pendingGeocodes()` snapshot from the same unit.
    ///
    /// Gate contract: this method performs NO geocode
    /// awaits — the caller's gate unit is bounded by the inserts alone.
    /// After the unit ends, run `healPendingGeocodes(_:)` with the captured
    /// snapshots (outside any gate unit) to fill the
    /// offline place layers.
    ///
    /// Temporary homes (v11): each inserted declaration, every declaration
    /// already in the store when a stay lands, and every one whose kept
    /// trips grow (v13), is queued in `CoverageReconciliationQueue` before
    /// the save that makes it durable. Declarations, removals and kept trips
    /// are applied before the trips, so the first checkpoint persists them
    /// with the trip graphs they shape.
    /// The caller drains the queue after the unit ends
    /// (`stagedTemporaryHomeReconciliations`); the classifier is never
    /// called from here.
    @discardableResult
    func importTrips(from payload: ImportPayload) async -> ImportOutcome {
        pendingGeocodeSnapshots = []
        unsavedGeocodeCandidates = []
        // A row no save committed is never healed.
        defer { unsavedGeocodeCandidates = [] }
        var insertedTrips = 0
        var insertedStays = 0
        var insertedVisits = 0
        var skippedExistingTrips = 0
        var skippedInvalidStays = 0
        var anySaveFailed = false
        var committedInsertedTrips = 0
        var committedInsertedStays = 0
        var deferredTitleArtifacts: [DeferredTitleArtifacts] = []
        var tripsInsertedThisRun: [Trip] = []
        // Inserted trips missing some of the file's stays: the stored summary
        // describes the whole trip, so theirs is derived from what landed. So
        // is a whole trip's whose file entry left the summary to the restore.
        var partialTrips: [Trip] = []
        var skippedRowsHoldingFileStays: [Trip] = []
        // Reconciliations staged ahead of the first checkpoint: the temporary
        // homes already in the store, whose restored stays it makes durable,
        // and the declarations, removals and kept trips this import applies.
        var checkpointDebt: [CoverageReconciliationQueue.Staged] = []

        let activeHomeTitleInputsBefore: [TripTitleStore.ActiveHomeTitleInput]
        let existingTripRowsByID: [UUID: [Trip]]
        var existingTripIDs: Set<UUID>
        var existingStayIDs: Set<UUID>
        let storedTemporaryHomeRows: [TemporaryHome]
        let existingTemporaryHomeIDs: Set<UUID>
        do {
            activeHomeTitleInputsBefore = try TripTitleStore
                .fetchActiveHomeTitleInputs(in: modelContext)
            existingTripRowsByID = try Dictionary(
                grouping: fetchExistingTrips(), by: \.id)
            existingTripIDs = Set(existingTripRowsByID.keys)
            existingStayIDs = try fetchExistingIDs(
                FetchDescriptor<Stay>(), id: \.id)
            // Read before any insert: a failed read here must not pass for
            // "no temporary home", which would skip their reconciliation.
            storedTemporaryHomeRows = try fetchTemporaryHomeRows()
            existingTemporaryHomeIDs = Set(storedTemporaryHomeRows.map(\.id))
        } catch {
            let outcome = ImportOutcome(
                insertedTrips: 0, insertedStays: 0,
                skippedExistingTrips: 0, skippedInvalidStays: 0,
                saveFailed: true)
            logger.error("JSON import identity read failed: \(error.localizedDescription)")
            return outcome
        }
        let retainedRevisions = retainedTemporaryHomeRevisions(
            stored: storedTemporaryHomeRows, payload: payload)

        // v11: declared temporary homes, id-idempotent like Homes. A row
        // already in the store wins over the file: a backup never rewrites
        // dates the user has since edited. A removed id is in the store too,
        // so no live entry brings it back; one the file itself removes lands
        // as that removal below.
        let fileRemovedTemporaryHomeIDs = Set(payload.removedTemporaryHomes.map(\.id))
        // The file's kept trips of each id over all its entries: the row an id
        // lands as, from its first entry, carries every one.
        var fileKeptTripIDs: [UUID: Set<UUID>] = [:]
        for imported in payload.temporaryHomes + payload.removedTemporaryHomes {
            fileKeptTripIDs[imported.id, default: []].formUnion(imported.keptTripIDs)
        }
        // A new row with the file entry's content and `keptTripIDs`; the
        // caller inserts it.
        func newTemporaryHome(
            _ imported: ImportedTemporaryHome, keptTripIDs: Set<UUID>
        ) -> TemporaryHome {
            let temporaryHome = TemporaryHome(
                label: imported.label,
                latitude: imported.latitude, longitude: imported.longitude,
                startedAt: imported.startedAt, endedAt: imported.endedAt)
            temporaryHome.id = imported.id
            temporaryHome.radiusKm = imported.radiusKm
            temporaryHome.locality = imported.locality
            temporaryHome.administrativeArea = imported.administrativeArea
            temporaryHome.country = imported.country
            temporaryHome.isoCountryCode = imported.isoCountryCode
            temporaryHome.timeZoneIdentifier = imported.timeZoneIdentifier
            temporaryHome.createdAt = imported.createdAt
            temporaryHome.modifiedAt = imported.modifiedAt
            temporaryHome.coverageRevision = imported.coverageRevision
            for tripID in keptTripIDs { temporaryHome.addKeptTrip(tripID) }
            return temporaryHome
        }
        var insertedTemporaryHomeIDs: [UUID] = []
        var knownTemporaryHomeIDs = existingTemporaryHomeIDs
        for imported in payload.temporaryHomes
        where !knownTemporaryHomeIDs.contains(imported.id)
            && !fileRemovedTemporaryHomeIDs.contains(imported.id) {
            let temporaryHome = newTemporaryHome(
                imported, keptTripIDs: fileKeptTripIDs[imported.id] ?? [])
            modelContext.insert(temporaryHome)
            knownTemporaryHomeIDs.insert(imported.id)
            insertedTemporaryHomeIDs.append(imported.id)
        }

        // v13: a declaration the store keeps takes the file's kept trips it
        // lacks on every row, and nothing else: kept trips only grow, and its
        // content, revision and `modifiedAt` stay as they are.
        let keptTripMerges = keptTripsToMerge(payload, into: storedTemporaryHomeRows)
        let storedTemporaryHomeRowsByID = Dictionary(
            grouping: storedTemporaryHomeRows, by: \.id)
        for (id, tripIDs) in keptTripMerges {
            for row in storedTemporaryHomeRowsByID[id] ?? [] {
                for tripID in tripIDs { row.addKeptTrip(tripID) }
            }
        }

        // v12: removals apply monotonically, whatever the live entries say.
        // An absent id lands as a removed row with the file's content, so a
        // twin that syncs in later is hidden on arrival; a live id has every
        // row stamped, its content and `modifiedAt` left as they are; a
        // removed id is left alone. Removal is never undone.
        var appliedTemporaryHomeRemovalIDs: [UUID] = []
        if !payload.removedTemporaryHomes.isEmpty {
            let storedRows: [TemporaryHome]
            do {
                storedRows = try fetchTemporaryHomeRows()
            } catch {
                modelContext.rollback()
                let outcome = ImportOutcome(
                    insertedTrips: committedInsertedTrips,
                    insertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays,
                    saveFailed: true)
                logger.error("JSON import temporary-home read failed: \(error.localizedDescription)")
                return outcome
            }
            let storedRowsByID = Dictionary(grouping: storedRows, by: \.id)
            var removedIDs = HomeAnchors.removedIDs(storedRows)
            for imported in payload.removedTemporaryHomes {
                guard let removedAt = imported.removedAt,
                      !removedIDs.contains(imported.id) else { continue }
                if let rows = storedRowsByID[imported.id] {
                    for row in rows { row.removedAt = removedAt }
                } else {
                    let temporaryHome = newTemporaryHome(
                        imported, keptTripIDs: fileKeptTripIDs[imported.id] ?? [])
                    temporaryHome.removedAt = removedAt
                    modelContext.insert(temporaryHome)
                }
                removedIDs.insert(imported.id)
                appliedTemporaryHomeRemovalIDs.append(imported.id)
            }
        }
        // All three land before any trip graph they shape: the first save
        // that persists one (the first checkpoint, or the final transaction
        // when the file has none) persists them too, with their debt.
        var declarationDebtIDs: [UUID] = []
        var seenDebtIDs = Set<UUID>()
        for id in insertedTemporaryHomeIDs + appliedTemporaryHomeRemovalIDs
            + keptTripMerges.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seenDebtIDs.insert(id).inserted {
            declarationDebtIDs.append(id)
        }
        var declarationsCommitted = false

        var titleCompletionTripIDs = Set<UUID>()
        let ownedEmptyTrips = payload.ownedEmptyTrips
        for importedTrip in payload.trips {
            if existingTripIDs.contains(importedTrip.id) {
                skippedExistingTrips += 1
                if !titleCompletionTripIDs.contains(importedTrip.id),
                   let target = titleCompletionTarget(
                       for: importedTrip,
                       among: existingTripRowsByID[importedTrip.id] ?? []) {
                    // A prior checkpoint may have committed the Trip graph
                    // before the final Home/title transaction. Re-import is
                    // still UUID-idempotent, but may complete those deferred
                    // artifacts when the durable membership is unchanged.
                    // A duplicate payload entry completes nothing twice.
                    titleCompletionTripIDs.insert(importedTrip.id)
                    deferredTitleArtifacts.append(DeferredTitleArtifacts(
                        trip: target.trip,
                        canonicalTitle: target.title,
                        sourceRevision: importedTrip.titleSourceRevision,
                        localizedTitles: importedTrip.localizedTitles,
                        completesExistingTrip: true))
                }
                // That checkpoint also derived the summary before the file's
                // Homes existed. Only rows (every UUID twin) that still hold
                // exactly the file's stays qualify: a row missing some is
                // still syncing, and a stayless one is a possible ghost the
                // sweep matches by its summary.
                for row in existingTripRowsByID[importedTrip.id] ?? []
                where !(row.stays ?? []).isEmpty
                    && Self.restoresExactMembership(
                        importedTrip,
                        attachedStayIDs: Set((row.stays ?? []).map(\.id)),
                        attachedStayCount: row.stays?.count ?? 0) {
                    skippedRowsHoldingFileStays.append(row)
                }
                continue
            }

            let trip = Trip(startDate: importedTrip.startDate)
            trip.id = importedTrip.id
            trip.sourceRaw = importedTrip.sourceRaw
            trip.endDate = importedTrip.endDate
            trip.isComplete = importedTrip.isComplete
            trip.classifiedByAI = importedTrip.classifiedByAI
            trip.userEdited = importedTrip.userEdited
            // The flag only qualifies an edit flag, so it never lands alone.
            trip.keptByTemporaryHome = trip.userEdited && importedTrip.keptByTemporaryHome
            trip.customName = importedTrip.customName
            trip.destinationSummary = importedTrip.destinationSummary
            trip.countryCodes = importedTrip.countryCodes
            modelContext.insert(trip)
            existingTripIDs.insert(importedTrip.id)

            var attached = 0
            var attachedStayIDs = Set<UUID>()
            var attachedStays: [Stay] = []
            for importedStay in importedTrip.stays.sorted(by: {
                if $0.startTime != $1.startTime {
                    return $0.startTime < $1.startTime
                }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                guard !existingStayIDs.contains(importedStay.id) else {
                    skippedInvalidStays += 1
                    continue
                }
                // Degenerate coordinates that H3 can't index are skipped,
                // the photo-import path's policy.
                guard let h3Index = importedStay.admittedH3Index else {
                    skippedInvalidStays += 1
                    continue
                }

                let stay = insertImportedStay(
                    importedStay, h3Index: h3Index, retainedRevisions: retainedRevisions)
                stay.trip = trip
                attached += 1
                attachedStayIDs.insert(importedStay.id)
                attachedStays.append(stay)
                existingStayIDs.insert(importedStay.id)
                insertedStays += 1
            }

            // Phantom-trip guard: the Trip row is
            // inserted before its stays, so a file whose every stay is
            // invalid or already present would otherwise leave an empty
            // shell trip in the list. `existingTripIDs` keeps the id for
            // THIS run only — it re-derives from the store next import, so
            // a corrected file can retry. A completed trip this entry declares
            // empty and the user owns lands as the empty row it was, so its
            // name, Favorite and photo choices come back with it.
            if attached == 0 && !ownedEmptyTrips.admits(importedTrip) {
                modelContext.delete(trip)
                continue
            }
            tripsInsertedThisRun.append(trip)

            // AI title/summary artifacts describe the complete exported trip.
            // If any stay was skipped as invalid or already present, restoring
            // them would attach full-trip prose and translations to a smaller
            // semantic trip. User-authored customName remains independent.
            let restoresExactMembership = Self.restoresExactMembership(
                importedTrip,
                attachedStayIDs: attachedStayIDs,
                attachedStayCount: attachedStays.count)
            if !restoresExactMembership,
               let first = attachedStays.first,
               let last = attachedStays.last {
                trip.startDate = first.startTime
                trip.endDate = trip.isComplete ? last.endTime : nil
                // The stored order counts stays that did not land.
                for (index, stay) in attachedStays.enumerated() { stay.orderInTrip = index }
                // The stored summary describes the whole trip; this one is
                // derived from the stays that landed, again once Homes have.
                trip.recomputeSummary()
                partialTrips.append(trip)
            }
            // A whole trip that left its destination summary to the restore
            // (an export merging same-id copies no one of which held every
            // stay) takes one from its stays, again once Homes have landed.
            if restoresExactMembership, importedTrip.destinationSummary.isEmpty,
               attachedStays.contains(where: { $0.category == .destination }) {
                trip.recomputeSummary()
                partialTrips.append(trip)
            }
            if restoresExactMembership {
                if let title = TripTitleStore.normalized(importedTrip.aiGeneratedTitle) {
                    // Home rows are imported after the trip batches. Defer
                    // home-sensitive canonical + localized title artifacts
                    // until the final, post-collapse transaction. A crash or
                    // failed final save then leaves checkpointed trips safely
                    // untitled rather than carrying a title validated against
                    // a Home context that never landed.
                    deferredTitleArtifacts.append(DeferredTitleArtifacts(
                        trip: trip,
                        canonicalTitle: title,
                        sourceRevision: importedTrip.titleSourceRevision,
                        localizedTitles: importedTrip.localizedTitles))
                }
                if let summary = importedTrip.aiGeneratedSummary, !summary.isEmpty {
                    trip.aiGeneratedSummary = summary
                    trip.summaryGeneratedAt = importedTrip.summaryGeneratedAt
                    trip.summaryGenerationVersion = importedTrip.summaryGenerationVersion
                    // Restore only known provenance values; never guess for
                    // a hand-edited payload.
                    if let raw = importedTrip.summarySourceRaw,
                       SummarySource(rawValue: raw) != nil {
                        trip.summarySourceRaw = raw
                    }
                }
            }

            insertedTrips += 1

            if insertedTrips % 25 == 0 {
                // The first checkpoint is the first save that persists
                // restored stays and the declarations applied above. Queue
                // the reconciliations before it, so no kill leaves durable
                // stays or declarations without them.
                let firstStaySave = committedInsertedStays == 0
                if firstStaySave {
                    var seen = Set<UUID>()
                    checkpointDebt = await stageTemporaryHomeDebt(
                        (Array(existingTemporaryHomeIDs) + declarationDebtIDs)
                            .filter { seen.insert($0).inserted })
                }
                guard save() else {
                    if firstStaySave {
                        await withdrawTemporaryHomeDebt(checkpointDebt)
                    }
                    let outcome = ImportOutcome(
                        insertedTrips: committedInsertedTrips,
                        insertedStays: committedInsertedStays,
                        skippedExistingTrips: skippedExistingTrips,
                        skippedInvalidStays: skippedInvalidStays,
                        saveFailed: true)
                    return outcome
                }
                committedInsertedTrips = insertedTrips
                committedInsertedStays = insertedStays
                declarationsCommitted = true
            }
        }

        // Tripless travel stays re-enter as exactly what they were:
        // unassigned rows. The pipeline already treats transit residue as
        // steady state and heals orphan destinations (the destination-only
        // dirty gate assembles them into a trip on the next pass). Home stays
        // ride the same trip-less insertion path: they come back as exactly
        // what they were (`.home`/`.routine`, sacred flags intact), so the
        // orbit re-derives its discs from them and trip-demotion history
        // survives the restore.
        for importedStay in (payload.unassignedStays + payload.homeStays)
            .sorted(by: { $0.startTime < $1.startTime }) {
            guard !existingStayIDs.contains(importedStay.id) else {
                skippedInvalidStays += 1
                continue
            }
            guard let h3Index = importedStay.admittedH3Index else {
                skippedInvalidStays += 1
                continue
            }
            _ = insertImportedStay(
                importedStay, h3Index: h3Index, retainedRevisions: retainedRevisions)
            existingStayIDs.insert(importedStay.id)
            insertedStays += 1
        }

        // v6: declared home rows before their overrides (era anchors
        // first). Fetch-before-insert by id — restoring onto a device that
        // already carries the rows is a no-op; a fresh-install restore whose
        // onboarding home duplicates an imported one converges through
        // `PlacesDeduplicator` (≤1 km collapse, override homeIDs re-pointed).
        var insertedHomes = 0
        if !payload.homes.isEmpty {
            // `var` + insert-as-we-go: a duplicate id WITHIN one file must
            // not insert twice — PlacesDeduplicator's shared-id safety net
            // skips such groups forever.
            let fetchedHomeIDs: Set<UUID>
            do {
                fetchedHomeIDs = try fetchExistingIDs(
                    FetchDescriptor<Home>(), id: \.id)
            } catch {
                modelContext.rollback()
                let outcome = ImportOutcome(
                    insertedTrips: committedInsertedTrips,
                    insertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays,
                    saveFailed: true)
                logger.error("JSON import Home identity read failed: \(error.localizedDescription)")
                return outcome
            }
            var existingHomeIDs = fetchedHomeIDs
            for imported in payload.homes where !existingHomeIDs.contains(imported.id) {
                let home = Home(
                    label: imported.label,
                    latitude: imported.latitude, longitude: imported.longitude,
                    radiusKm: imported.radiusKm, startedAt: imported.startedAt)
                home.id = imported.id
                home.endedAt = imported.endedAt
                home.locality = imported.locality
                home.administrativeArea = imported.administrativeArea
                home.country = imported.country
                home.isoCountryCode = imported.isoCountryCode
                modelContext.insert(home)
                existingHomeIDs.insert(imported.id)
                insertedHomes += 1
            }
        }

        var insertedRoutinePlaces = 0
        if !payload.routinePlaces.isEmpty {
            let fetchedPlaceIDs: Set<UUID>
            do {
                fetchedPlaceIDs = try fetchExistingIDs(
                    FetchDescriptor<RoutinePlace>(), id: \.id)
            } catch {
                modelContext.rollback()
                let outcome = ImportOutcome(
                    insertedTrips: committedInsertedTrips,
                    insertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays,
                    saveFailed: true)
                logger.error("JSON import routine-place identity read failed: \(error.localizedDescription)")
                return outcome
            }
            var existingPlaceIDs = fetchedPlaceIDs
            for imported in payload.routinePlaces
            where !existingPlaceIDs.contains(imported.id) {
                let place = RoutinePlace(
                    label: imported.label,
                    latitude: imported.latitude, longitude: imported.longitude,
                    radiusMeters: imported.radiusMeters,
                    startedAt: imported.startedAt)
                place.id = imported.id
                place.isActive = imported.isActive
                place.endedAt = imported.endedAt
                modelContext.insert(place)
                existingPlaceIDs.insert(imported.id)
                insertedRoutinePlaces += 1
            }
        }

        var insertedOverrides = 0
        if !payload.homeAreaOverrides.isEmpty {
            let fetchedOverrideIDs: Set<UUID>
            do {
                fetchedOverrideIDs = try fetchExistingIDs(
                    FetchDescriptor<HomeAreaOverride>(), id: \.id)
            } catch {
                modelContext.rollback()
                let outcome = ImportOutcome(
                    insertedTrips: committedInsertedTrips,
                    insertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays,
                    saveFailed: true)
                logger.error("JSON import override identity read failed: \(error.localizedDescription)")
                return outcome
            }
            var existingOverrideIDs = fetchedOverrideIDs
            for imported in payload.homeAreaOverrides
            where !existingOverrideIDs.contains(imported.id) {
                // Only KNOWN kinds land (the summarySourceRaw rule) — a
                // hand-edited file can't smuggle a value the membership
                // would misread.
                guard let kind = HomeAreaOverride.Kind(rawValue: imported.kindRaw) else {
                    continue
                }
                let row = HomeAreaOverride(
                    kind: kind,
                    centerLatitude: imported.centerLatitude,
                    centerLongitude: imported.centerLongitude,
                    radiusKm: imported.radiusKm,
                    homeID: imported.homeID,
                    sourceTripName: imported.sourceTripName)
                row.id = imported.id
                row.createdAt = imported.createdAt
                modelContext.insert(row)
                existingOverrideIDs.insert(imported.id)
                insertedOverrides += 1
            }
        }

        if !payload.visits.isEmpty {
            let fetchedVisitIDs: Set<UUID>
            do {
                fetchedVisitIDs = try fetchExistingIDs(
                    FetchDescriptor<Visit>(), id: \.id)
            } catch {
                modelContext.rollback()
                let outcome = ImportOutcome(
                    insertedTrips: committedInsertedTrips,
                    insertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays,
                    saveFailed: true,
                    insertedVisits: 0)
                logger.error("JSON import Visit identity read failed: \(error.localizedDescription)")
                return outcome
            }
            var existingVisitIDs = fetchedVisitIDs
            for imported in payload.visits
                .sorted(by: {
                    ($0.arrivalDate, $0.id.uuidString)
                        < ($1.arrivalDate, $1.id.uuidString)
                })
            where !existingVisitIDs.contains(imported.id) {
                modelContext.insert(Visit(
                    id: imported.id,
                    arrivalDate: imported.arrivalDate,
                    departureDate: imported.departureDate,
                    latitude: imported.latitude,
                    longitude: imported.longitude,
                    horizontalAccuracy: imported.horizontalAccuracy,
                    receivedAt: imported.receivedAt,
                    stayID: imported.stayID,
                    // A pending Visit stays pending, so the next clustering
                    // pass turns it into the stay or interval it owes.
                    isProcessed: imported.isProcessed))
                existingVisitIDs.insert(imported.id)
                insertedVisits += 1
            }
        }

        // Photo choices land with the final transaction, only on a trip that
        // exists after this import (stored, or inserted by this run), and only
        // where the trip does not hold the choice yet, under their own row
        // ids (the Removed Trips archives name them). Stored choices are never
        // removed or rewritten.
        // The trips that exist after this import: the stored ones and the
        // ones this run inserted.
        let tripIDsAfterImport = Set(existingTripRowsByID.keys)
            .union(tripsInsertedThisRun.filter { !$0.isDeleted }.map(\.id))
        var insertedPhotoChoices = 0
        var skippedPhotoChoices = 0
        if !payload.hiddenPhotos.isEmpty || !payload.pinnedPhotos.isEmpty {
            let held: (hidden: [HeldPhotoChoice], pinned: [HeldPhotoChoice])
            do {
                held = try heldPhotoChoices(for: payload)
            } catch {
                return failImport(
                    "JSON import photo-choice read failed: \(error.localizedDescription)",
                    committedInsertedTrips: committedInsertedTrips,
                    committedInsertedStays: committedInsertedStays,
                    skippedExistingTrips: skippedExistingTrips,
                    skippedInvalidStays: skippedInvalidStays)
            }
            let hidden = Self.photoChoicesToRestore(
                payload.hiddenPhotos, held: held.hidden, tripIDs: tripIDsAfterImport)
            for choice in hidden.restore {
                let row = HiddenPhoto(localIdentifier: choice.localIdentifier, tripID: choice.tripID)
                row.id = choice.id
                row.cloudIdentifier = choice.cloudIdentifier
                row.hiddenAt = choice.chosenAt
                modelContext.insert(row)
            }
            let pinned = Self.photoChoicesToRestore(
                payload.pinnedPhotos, held: held.pinned, tripIDs: tripIDsAfterImport)
            for choice in pinned.restore {
                let row = PinnedPhoto(localIdentifier: choice.localIdentifier, tripID: choice.tripID)
                row.id = choice.id
                row.cloudIdentifier = choice.cloudIdentifier
                row.pinnedAt = choice.chosenAt
                modelContext.insert(row)
            }
            insertedPhotoChoices = hidden.restore.count + pinned.restore.count
            skippedPhotoChoices = hidden.missingTrip + pinned.missingTrip
        }

        // Wrapped recaps, planned trips, the photo-import state and the hex
        // cells land with the final transaction too.
        let insertedRecordRows: Int
        do {
            insertedRecordRows = try restoreRecords(payload) + restoreHexVisits(payload.hexVisits)
        } catch {
            return failImport(
                "JSON import record read failed: \(error.localizedDescription)",
                committedInsertedTrips: committedInsertedTrips,
                committedInsertedStays: committedInsertedStays,
                skippedExistingTrips: skippedExistingTrips,
                skippedInvalidStays: skippedInvalidStays)
        }

        // A fresh-install restore commonly starts with the Home onboarding
        // just created, then imports its nearby backup twin. Collapse that
        // transient duplicate inside this same transaction so title fidelity
        // is judged against the final prompt context, not the temporary
        // doubled set that Settings would otherwise clean up afterward.
        // Restored corrections naming a Home this device already collapsed
        // (override-only files included) are re-pointed in the same commit.
        var stagedHomeAliases: [UUID: UUID]?
        do {
            let collapsed = try PlacesDeduplicator.deduplicateHomes(in: modelContext)
            let aliases = PlacesDeduplicator.mergingHomeAliases(
                PlacesDeduplicator.loadHomeAliases(defaults: homeAliasDefaults),
                collapsed)
            _ = try PlacesDeduplicator.rebindAliasedOverrides(
                in: modelContext, aliases: aliases)
            if !collapsed.isEmpty { stagedHomeAliases = aliases }
        } catch {
            anySaveFailed = true
            modelContext.rollback()
        }

        // A trip restored whole keeps its stored summary, unless the file left
        // it empty for the restore to derive. A partial one was
        // derived before this file's Homes and home stays existed, so it kept
        // home-named destinations ("Aegina, Athens"): derive it again against
        // the final set, and the same for rows an interrupted earlier run of
        // this file committed. The Home places are a required read here: a
        // summary that kept home-named places would be committed as final,
        // so a failed read rolls the transaction back and the import reports
        // itself incomplete (a re-import derives them for the rows a
        // checkpoint committed).
        if !anySaveFailed {
            TripTitleStore.invalidateHomePlaceIndex()
            var homePlacesRead = true
            for trip in partialTrips
            where homePlacesRead && !trip.isDeleted && trip.modelContext != nil {
                homePlacesRead = trip.recomputeSummary()
            }
            for trip in skippedRowsHoldingFileStays
            where homePlacesRead && !trip.isDeleted && trip.modelContext != nil {
                homePlacesRead = rederiveHomeNamesInSkippedRow(trip)
            }
            if !homePlacesRead {
                logger.error("JSON import Home-place read failed; destination summaries not derived.")
                anySaveFailed = true
                modelContext.rollback()
            }
        }

        var completedExistingTitles = 0
        do {
            let importedTitlesStillMatch = TripTitleStore.hasEquivalentActiveHomePromptContent(
                Self.expectedActiveHomeTitleInputs(of: payload),
                try TripTitleStore.fetchActiveHomeTitleInputs(in: modelContext))
            if importedTitlesStillMatch {
                for artifacts in deferredTitleArtifacts
                where !artifacts.trip.isDeleted {
                    if artifacts.completesExistingTrip {
                        completedExistingTitles += 1
                    }
                    artifacts.trip.aiGeneratedTitle = artifacts.canonicalTitle
                    artifacts.trip.titleSourceRevision = artifacts.sourceRevision
                    // Derivatives carry no independent authority: restore
                    // only deterministic winners for this exact canonical
                    // source and revision.
                    for importedTitle in BackupLocalizedTitle.selected(
                        artifacts.localizedTitles,
                        canonicalTitle: artifacts.canonicalTitle,
                        sourceRevision: artifacts.sourceRevision
                    ) {
                        modelContext.insert(TripTitleVariant(
                            id: importedTitle.id,
                            languageTag: importedTitle.languageTag,
                            title: importedTitle.title,
                            sourceTitle: importedTitle.sourceTitle,
                            sourceRevision: importedTitle.sourceRevision,
                            generationVersion: importedTitle.generationVersion,
                            updatedAt: importedTitle.updatedAt,
                            trip: artifacts.trip))
                    }
                }
            }
            _ = try TripTitleStore
                .invalidateAllGeneratedTitlesIfActiveHomesChanged(
                    from: activeHomeTitleInputsBefore,
                    in: modelContext,
                    preserving: importedTitlesStillMatch
                        ? deferredTitleArtifacts.map(\.trip) : [])
        } catch {
            anySaveFailed = true
            modelContext.rollback()
        }
        // Log collapse aliases before the commit so a kill cannot lose them;
        // a failed commit restores the previous log.
        let loggedHomeAliases = homeAliasDefaults.dictionary(
            forKey: PlacesDeduplicator.homeAliasesKey)
        if !anySaveFailed, let stagedHomeAliases {
            PlacesDeduplicator.storeHomeAliases(
                stagedHomeAliases, defaults: homeAliasDefaults)
        }
        // Queue the temporary-home reconciliations before their rows can
        // become durable, so no kill leaves a restored declaration without
        // one, unless a checkpoint already persisted and queued them. The
        // homes already in the store join when this save is the first to
        // persist a stay (no checkpoint queued them), and so does every id a
        // removal was applied to: its unit frees what it stamped. A
        // declaration whose kept trips grew is queued too: its unit must
        // honour the new keeps.
        var finalDebt: [CoverageReconciliationQueue.Staged] = []
        if !anySaveFailed {
            var owed = declarationsCommitted ? [] : declarationDebtIDs
            if insertedStays > 0, committedInsertedStays == 0 {
                owed += existingTemporaryHomeIDs
            }
            var seen = Set<UUID>()
            finalDebt = await stageTemporaryHomeDebt(owed.filter { seen.insert($0).inserted })
        }
        let finalSaved = !anySaveFailed && save()
        if finalSaved {
            committedInsertedTrips = insertedTrips
            committedInsertedStays = insertedStays
            try? TripTitleStore.recordActiveHomeTitleFingerprint(
                in: modelContext)
        } else {
            anySaveFailed = true
            if stagedHomeAliases != nil {
                homeAliasDefaults.set(
                    loggedHomeAliases, forKey: PlacesDeduplicator.homeAliasesKey)
            }
            // Withdraw only what this transaction queued: what a checkpoint
            // queued for stays that did commit, or an earlier edit of the
            // same row, still owes its reconciliation.
            await withdrawTemporaryHomeDebt(finalDebt)
            finalDebt = []
        }
        if anySaveFailed {
            // No mutation from a failed/skipped final transaction may remain
            // pending on this long-lived actor context and leak into a later
            // unrelated save.
            modelContext.rollback()
        }
        // Never serve a home-place snapshot built from rolled-back rows.
        TripTitleStore.invalidateHomePlaceIndex()
        if finalSaved, committedInsertedStays > 0 {
            // Imported stays can carry pre-cap landmass island names; the import
            // heal skips stays whose islandName is non-nil, so the whole-store
            // backfill runs again.
            #if DEBUG
            let backfillDefaults = BackfillTestScope.defaultsSuiteName
                .flatMap { UserDefaults(suiteName: $0) } ?? .standard
            #else
            let backfillDefaults = UserDefaults.standard
            #endif
            backfillDefaults.removeObject(forKey: AppDelegate.offlineGeocoderBackfillCompletedKey)
        }
        // Backup titles can be in the retired prompt spelling ("Troms"), and
        // the launch pass that respells them may have latched already. Only
        // the trips this import titled are checked; the launch pass owns the
        // rest. If this check cannot finish, the next launch repeats that pass.
        if finalSaved, !deferredTitleArtifacts.isEmpty,
           !AppDelegate.repairLegacyTitleSpellings(
               of: deferredTitleArtifacts.map(\.trip), in: modelContext) {
            UserDefaults.standard.removeObject(forKey: AppDelegate.tripSummaryMetroRefreshCompletedKey)
        }

        // After the graph commits: the Removed Trips archives it can hold
        // (their trips are not back), then the pings, chunk by chunk. Either
        // failing reports the import incomplete; a re-import adds the rest.
        var queuedRemovedTrips = 0
        var insertedPings = 0
        var afterCommitFailed = false
        if finalSaved {
            if !payload.removedTrips.isEmpty {
                do {
                    queuedRemovedTrips = try DissolvedTripQueue.restore(
                        payload.removedTrips, existingTripIDs: tripIDsAfterImport,
                        in: removedTripsDirectory)
                } catch {
                    afterCommitFailed = true
                    logger.error("JSON import Removed Trips restore failed: \(error.localizedDescription)")
                }
            }
            let pings = restorePings(payload.pings)
            insertedPings = pings.inserted
            if pings.failed { afterCommitFailed = true }
        }

        let outcome = ImportOutcome(
            insertedTrips: committedInsertedTrips,
            insertedStays: committedInsertedStays,
            skippedExistingTrips: skippedExistingTrips,
            skippedInvalidStays: skippedInvalidStays,
            saveFailed: anySaveFailed || afterCommitFailed,
            insertedHomes: finalSaved ? insertedHomes : 0,
            insertedOverrides: finalSaved ? insertedOverrides : 0,
            insertedRoutinePlaces: finalSaved ? insertedRoutinePlaces : 0,
            insertedVisits: finalSaved ? insertedVisits : 0,
            restoredTitles: finalSaved ? completedExistingTitles : 0,
            insertedTemporaryHomes: finalSaved || declarationsCommitted
                ? insertedTemporaryHomeIDs.count : 0,
            stagedTemporaryHomeReconciliations: checkpointDebt.count + finalDebt.count,
            appliedTemporaryHomeRemovals: finalSaved || declarationsCommitted
                ? appliedTemporaryHomeRemovalIDs.count : 0,
            insertedPhotoChoices: finalSaved ? insertedPhotoChoices : 0,
            skippedPhotoChoices: skippedPhotoChoices,
            restorableFavouriteTripIDs: finalSaved
                ? payload.favouriteTripIDs.intersection(tripIDsAfterImport) : [],
            insertedPings: insertedPings,
            insertedRecords: (finalSaved ? insertedRecordRows : 0) + queuedRemovedTrips
        )
        logger.info("JSON import: \(insertedTrips) trip(s), \(insertedStays) stay(s), \(insertedVisits) visit(s), \(insertedPings) ping(s), \(insertedPhotoChoices) photo choice(s) inserted; \(skippedExistingTrips) trip(s) already existed; \(skippedInvalidStays) stay(s), \(skippedPhotoChoices) photo choice(s) without a trip skipped.")
        return outcome
    }

    /// The coverage revision of the declaration the store keeps for each id
    /// after this import: the stored row every reader resolves to, live or
    /// removed, when the store holds the id; else the file's entry that lands,
    /// a removal before a live entry, the first of each. An imported stamp is
    /// clamped to it, so it never waits for a copy the import rejected.
    private func retainedTemporaryHomeRevisions(
        stored rows: [TemporaryHome], payload: ImportPayload
    ) -> [UUID: Int] {
        var revisions: [UUID: Int] = [:]
        for home in payload.removedTemporaryHomes + payload.temporaryHomes
        where revisions[home.id] == nil {
            revisions[home.id] = home.coverageRevision
        }
        for row in HomeAnchors.collapsingTwins(rows) + HomeAnchors.removedTwins(rows) {
            revisions[row.id] = row.coverageRevision
        }
        return revisions
    }

    /// v13: for each declaration the store keeps (held live, removed neither
    /// in the store nor by the file), the file's kept trips that none of its
    /// rows holds. Preview and commit share the rule.
    func keptTripsToMerge(
        _ payload: ImportPayload, into rows: [TemporaryHome]
    ) -> [UUID: Set<UUID>] {
        let removed = HomeAnchors.removedIDs(rows)
            .union(payload.removedTemporaryHomes.map(\.id))
        var fileKept: [UUID: Set<UUID>] = [:]
        for home in payload.temporaryHomes where !removed.contains(home.id) {
            fileKept[home.id, default: []].formUnion(home.keptTripIDs)
        }
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        var missing: [UUID: Set<UUID>] = [:]
        for (id, tripIDs) in fileKept {
            guard let twins = rowsByID[id] else { continue }
            let lacking = tripIDs.subtracting(TemporaryHome.keptTripIDs(of: twins))
            if !lacking.isEmpty { missing[id] = lacking }
        }
        return missing
    }

    /// Records one owed temporary-home reconciliation per id. The queue
    /// lives on the main actor, so this hop and `withdrawTemporaryHomeDebt`
    /// are the import's only suspensions; with nothing to queue neither
    /// suspends.
    private func stageTemporaryHomeDebt(
        _ ids: [UUID]
    ) async -> [CoverageReconciliationQueue.Staged] {
        guard !ids.isEmpty else { return [] }
        let suite = reconciliationDefaultsSuite
        return await MainActor.run {
            let defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            return ids.map {
                CoverageReconciliationQueue.stage(.temporaryHome, id: $0, defaults: defaults)
            }
        }
    }

    /// Undoes `stageTemporaryHomeDebt` after the save it preceded failed.
    private func withdrawTemporaryHomeDebt(
        _ staged: [CoverageReconciliationQueue.Staged]
    ) async {
        guard !staged.isEmpty else { return }
        let suite = reconciliationDefaultsSuite
        await MainActor.run {
            let defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            for entry in staged {
                CoverageReconciliationQueue.withdraw(entry, defaults: defaults)
            }
        }
    }

    // MARK: Post-import geocode heal

    /// Snapshots collected by the most recent `importTrips` call — committed
    /// stays whose place layers still need the offline geocode heal, each
    /// with its physical-row witness. Capture inside the import's gate unit,
    /// then feed to `healPendingGeocodes(_:)` outside it.
    var pendingGeocodeSnapshots: [PendingGeocode] = []

    /// Inserted heal candidates no save has committed yet. A successful save
    /// turns them into `pendingGeocodeSnapshots` (their ids are durable only
    /// then); a failed one drops them with the rows it rolled back.
    var unsavedGeocodeCandidates: [Stay] = []

    // MARK: Helpers

    func fetchExistingIDs<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        id: KeyPath<T, UUID>
    ) throws -> Set<UUID> {
        var descriptor = descriptor
        descriptor.propertiesToFetch = [id]
        #if DEBUG
        identityFetchCallCountForTesting += 1
        if failingIdentityFetchCallForTesting == identityFetchCallCountForTesting {
            failingIdentityFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        let rows = try modelContext.fetch(descriptor)
        return Set(rows.map { $0[keyPath: id] })
    }

    /// Rolls back the uncommitted batch and reports the checkpointed totals
    /// as a failed import.
    private func failImport(
        _ message: String,
        committedInsertedTrips: Int, committedInsertedStays: Int,
        skippedExistingTrips: Int, skippedInvalidStays: Int
    ) -> ImportOutcome {
        modelContext.rollback()
        let outcome = ImportOutcome(
            insertedTrips: committedInsertedTrips,
            insertedStays: committedInsertedStays,
            skippedExistingTrips: skippedExistingTrips,
            skippedInvalidStays: skippedInvalidStays,
            saveFailed: true)
        logger.error("\(message)")
        return outcome
    }

    /// Every temporary-home row, removed ones and same-id twins included.
    func fetchTemporaryHomeRows() throws -> [TemporaryHome] {
        #if DEBUG
        identityFetchCallCountForTesting += 1
        if failingIdentityFetchCallForTesting == identityFetchCallCountForTesting {
            failingIdentityFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try modelContext.fetch(FetchDescriptor<TemporaryHome>())
    }

    func fetchExistingTrips() throws -> [Trip] {
        #if DEBUG
        identityFetchCallCountForTesting += 1
        if failingIdentityFetchCallForTesting == identityFetchCallCountForTesting {
            failingIdentityFetchCallForTesting = nil
            throw CocoaError(.fileReadUnknown)
        }
        #endif
        return try modelContext.fetch(FetchDescriptor<Trip>())
    }

    /// Re-derives a skipped row's summary, keeping the result only when all
    /// it does is leave out names the row's own stays carry, the one change
    /// newly landed Homes can make: same countries and provenance, no name
    /// added, no stored name those stays lack. Anything else means the
    /// stored fields came from stays this device does not hold yet (a trip
    /// edited on another device since the backup, still syncing), so they
    /// stay as synced. False, with the row as it was, when the Home places
    /// could not be read.
    private func rederiveHomeNamesInSkippedRow(_ trip: Trip) -> Bool {
        let storedSummary = trip.destinationSummary
        let storedCodes = trip.countryCodes
        let storedSource = trip.sourceRaw
        guard trip.recomputeSummary() else {
            trip.destinationSummary = storedSummary
            trip.countryCodes = storedCodes
            trip.sourceRaw = storedSource
            return false
        }
        let ownNames = Set(trip.destinations.flatMap {
            Trip.summaryComponents(
                $0.placeGroupName ?? Trip.unknownDestinationSentinel)
        })
        let storedNames = Set(Trip.summaryComponents(storedSummary))
        let onlyLeftOutOwnNames = storedNames.isSubset(of: ownNames)
            && Set(Trip.summaryComponents(trip.destinationSummary))
                .isSubset(of: storedNames)
            && Set(Trip.summaryComponents(trip.countryCodes))
                == Set(Trip.summaryComponents(storedCodes))
            && trip.sourceRaw == storedSource
        guard !onlyLeftOutOwnNames else { return true }
        trip.destinationSummary = storedSummary
        trip.countryCodes = storedCodes
        trip.sourceRaw = storedSource
        return true
    }

    @discardableResult
    func save() -> Bool {
        do {
            #if DEBUG
            saveCallCountForTesting += 1
            if failingSaveCallForTesting == saveCallCountForTesting {
                failingSaveCallForTesting = nil
                let queueDefaults = reconciliationDefaultsSuite
                    .flatMap { UserDefaults(suiteName: $0) } ?? .standard
                queuedReconciliationKeysAtFailedSaveForTesting = queueDefaults
                    .dictionary(forKey: CoverageReconciliationQueue.pendingKey)
                    .map { Set($0.keys) } ?? []
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try modelContext.save()
            pendingGeocodeSnapshots += unsavedGeocodeCandidates.map(PendingGeocode.init)
            unsavedGeocodeCandidates = []
            return true
        } catch {
            modelContext.rollback()
            unsavedGeocodeCandidates = []
            logger.error("JSON import save failed: \(error.localizedDescription)")
            return false
        }
    }
}
