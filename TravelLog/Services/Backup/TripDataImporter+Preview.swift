//
//  TripDataImporter+Preview.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

extension TripDataImporter {

    // MARK: Preview (read-only)

    /// What would `importTrips` do with this payload? Read-only fetches —
    /// safe to call outside the pipeline gate. The current Favorites and
    /// Earlier Travels, read on the main actor, and the ids in the Removed
    /// Trips queue say which of the file's are new, and `newPreferences`
    /// (`BackupPreferences.additions`, also read there) how many settings
    /// and answers it would add. Reads every ping chunk, so a damaged one
    /// throws here, before anything is written.
    func preview(
        of payload: ImportPayload,
        favouriteTripIDs: Set<UUID> = [],
        rememberedCountryCodes: Set<String> = [],
        queuedRemovedTripIDs: Set<UUID> = [],
        newPreferences: Int = 0
    ) throws -> ImportPreview {
        let existingTripRowsByID = try Dictionary(
            grouping: fetchExistingTrips(), by: \.id)
        var existingStayIDs = try fetchExistingIDs(
            FetchDescriptor<Stay>(), id: \.id)

        var claimedTripIDs = Set(existingTripRowsByID.keys)
        var newTripIDs = Set<UUID>()
        var newTrips = 0
        var newStays = 0
        var existingTrips = 0
        var titleCompletionTripIDs = Set<UUID>()
        let ownedEmptyTrips = payload.ownedEmptyTrips
        for trip in payload.trips {
            if let rows = existingTripRowsByID[trip.id] {
                existingTrips += 1
                // Same rule and first-entry-wins order as the commit.
                if !titleCompletionTripIDs.contains(trip.id),
                   titleCompletionTarget(for: trip, among: rows) != nil {
                    titleCompletionTripIDs.insert(trip.id)
                }
            } else {
                // Claim before the phantom guard, as the commit does. A later
                // entry with this id cannot revive an empty first entry.
                guard claimedTripIDs.insert(trip.id).inserted else {
                    existingTrips += 1
                    continue
                }
                // Mirror the commit path: stays whose
                // coordinates can't be H3-indexed are dropped there, and a
                // trip whose every stay drops is deleted by the phantom-trip
                // guard — the preview must not promise rows the commit
                // won't insert. An owned trip this entry declares empty lands.
                let insertableStays = trip.stays.filter { stay in
                    guard !existingStayIDs.contains(stay.id) else { return false }
                    let h3Index = stay.admittedH3Index
                    guard h3Index != nil else { return false }
                    existingStayIDs.insert(stay.id)
                    return true
                }
                guard !insertableStays.isEmpty || ownedEmptyTrips.admits(trip) else { continue }
                newTripIDs.insert(trip.id)
                newTrips += 1
                newStays += insertableStays.count
            }
        }
        // Tripless stays count toward the preview's stay total under the
        // same insertability rules (id-new + H3-indexable).
        for stay in payload.unassignedStays + payload.homeStays
        where !existingStayIDs.contains(stay.id) {
            let h3Index = stay.admittedH3Index
            if h3Index != nil {
                existingStayIDs.insert(stay.id)
                newStays += 1
            }
        }
        // The home-area layer counts toward admission (id-new only).
        let existingHomeIDs = try fetchExistingIDs(
            FetchDescriptor<Home>(), id: \.id)
        let existingOverrideIDs = try fetchExistingIDs(
            FetchDescriptor<HomeAreaOverride>(), id: \.id)
        let existingPlaceIDs = try fetchExistingIDs(
            FetchDescriptor<RoutinePlace>(), id: \.id)
        let newHomeIDs = Set(payload.homes.map(\.id)).subtracting(existingHomeIDs)
        // Temporary homes are home-layer rows too (id-new only). Read only
        // when the file carries any. A live entry the file also removes lands
        // as the removal (the commit's rule).
        let fileRemovedTemporaryHomeIDs = Set(payload.removedTemporaryHomes.map(\.id))
        var newTemporaryHomes = 0
        if !payload.temporaryHomes.isEmpty {
            let storedTemporaryHomeRows = try fetchTemporaryHomeRows()
            newTemporaryHomes = Set(payload.temporaryHomes.map(\.id))
                .subtracting(storedTemporaryHomeRows.map(\.id))
                .subtracting(fileRemovedTemporaryHomeIDs).count
            // So does a declaration the store keeps that lacks one of the
            // file's kept trips (the commit's merge).
            newTemporaryHomes += keptTripsToMerge(
                payload, into: storedTemporaryHomeRows).count
        }
        // A removal counts when the store does not hold it yet, whether the
        // id is absent or live there.
        if !fileRemovedTemporaryHomeIDs.isEmpty {
            let storedRemovedIDs = try fetchExistingIDs(
                FetchDescriptor<TemporaryHome>(predicate: #Predicate { $0.removedAt != nil }),
                id: \.id)
            newTemporaryHomes += fileRemovedTemporaryHomeIDs.subtracting(storedRemovedIDs).count
        }
        let newHomeAreaRows =
            newHomeIDs.count
            + Set(payload.homeAreaOverrides.map(\.id)).subtracting(existingOverrideIDs).count
            + Set(payload.routinePlaces.map(\.id)).subtracting(existingPlaceIDs).count
            + newTemporaryHomes

        // The commit restores deferred titles only when the file's active
        // Homes match the final ones. With no Home rows to insert and no
        // nearby active Homes for the commit's `deduplicateHomes` to collapse,
        // the store's current Homes are that final context, so do not promise
        // titles the commit would reject. When Homes land or a collapse is
        // pending (it can fill a survivor's locality from its donor), the
        // count stays advisory and the commit's final check decides.
        if !titleCompletionTripIDs.isEmpty,
           newHomeIDs.isEmpty {
            let activeHomes = try modelContext.fetch(FetchDescriptor<Home>(
                predicate: #Predicate { $0.endedAt == nil }))
            let homeCollapsePending = !PlacesDeduplicator.proximityGroups(
                activeHomes.map { ($0.latitude, $0.longitude) },
                thresholdMeters: PlacesDeduplicator.homeProximityMeters
            ).isEmpty
            if !homeCollapsePending {
                let currentHomeInputs = try TripTitleStore
                    .fetchActiveHomeTitleInputs(in: modelContext)
                if !TripTitleStore.hasEquivalentActiveHomePromptContent(
                    Self.expectedActiveHomeTitleInputs(of: payload),
                    currentHomeInputs) {
                    titleCompletionTripIDs = []
                }
            }
        }

        var newVisits = 0
        if !payload.visits.isEmpty {
            let existingVisitIDs = try fetchExistingIDs(
                FetchDescriptor<Visit>(), id: \.id)
            newVisits = Set(payload.visits.map(\.id))
                .subtracting(existingVisitIDs).count
        }

        // Photo choices count under the commit's rule, against the trips that
        // exist after it, and so do the Favorites and Earlier Travels the
        // merge after it would add.
        let tripIDsAfterImport = Set(existingTripRowsByID.keys).union(newTripIDs)
        var newChoices = payload.favouriteTripIDs.intersection(tripIDsAfterImport)
            .subtracting(favouriteTripIDs).count
            + payload.rememberedCountryCodes.subtracting(rememberedCountryCodes).count
        if !payload.hiddenPhotos.isEmpty || !payload.pinnedPhotos.isEmpty {
            let held = try heldPhotoChoices(for: payload)
            newChoices += Self.photoChoicesToRestore(
                payload.hiddenPhotos, held: held.hidden, tripIDs: tripIDsAfterImport).restore.count
                + Self.photoChoicesToRestore(
                    payload.pinnedPhotos, held: held.pinned, tripIDs: tripIDsAfterImport).restore.count
        }

        // The records outside trips, under the commit's rules.
        let records = try newRecordCount(of: payload)
        let newRecords = records.new
            + DissolvedTripQueue.restorable(
                payload.removedTrips, queuedIDs: queuedRemovedTripIDs,
                existingTripIDs: tripIDsAfterImport).count

        return ImportPreview(
            newTrips: newTrips,
            newStays: newStays,
            existingTrips: existingTrips,
            malformedEntries: payload.malformedTrips + payload.malformedStays
                + payload.malformedVisits + payload.malformedRecords + records.malformedPings,
            newHomeAreaRows: newHomeAreaRows,
            restorableTitles: titleCompletionTripIDs.count,
            newVisits: newVisits,
            newChoices: newChoices,
            newRecords: newRecords,
            newPreferences: newPreferences
        )
    }

    /// The pings, Wrapped recaps, planned trips, photo-import states and hex
    /// cells the commit would write (`restorePings`, `restoreRecords`,
    /// `restoreHexVisits`), and the damaged ping entries met on the way.
    private func newRecordCount(of payload: ImportPayload) throws -> (new: Int, malformedPings: Int) {
        var new = 0
        var malformedPings = 0
        // One fresh context per chunk, like the commit: the store's ids are
        // read for the chunk's ids only.
        try payload.pings.forEachChunk { pings, malformed in
            malformedPings += malformed
            try autoreleasepool {
                let context = ModelContext(modelContainer)
                let ids = pings.map(\.id)
                var descriptor = FetchDescriptor<LocationPing>(
                    predicate: #Predicate { ids.contains($0.id) })
                descriptor.propertiesToFetch = [\.id]
                var known = Set(try context.fetch(descriptor).map(\.id))
                new += pings.filter { known.insert($0.id).inserted }.count
            }
        }
        if !payload.yearWrapped.isEmpty {
            var known = try fetchExistingIDs(FetchDescriptor<YearWrapped>(), id: \.id)
            new += payload.yearWrapped.filter { known.insert($0.id).inserted }.count
        }
        if !payload.plannedTrips.isEmpty {
            var known = try fetchExistingIDs(FetchDescriptor<PlannedTrip>(), id: \.id)
            new += payload.plannedTrips.filter { known.insert($0.id).inserted }.count
        }
        if !payload.photoImportStates.isEmpty,
           try fetchExistingIDs(FetchDescriptor<PhotoImportState>(), id: \.id).isEmpty {
            new += Set(payload.photoImportStates.map(\.id)).count
        }
        if !payload.hexVisits.isEmpty {
            let stored = try modelContext.fetch(FetchDescriptor<HexVisit>())
            let storedIDs = Set(stored.map(\.id))
            var byCell: [String: (first: Date, last: Date, count: Int, locality: Bool, country: Bool)] = [:]
            for row in stored.sorted(by: { $0.id.uuidString < $1.id.uuidString })
            where byCell[row.h3Index] == nil {
                byCell[row.h3Index] = (row.firstVisited, row.lastVisited, row.visitCount,
                                       row.locality != nil, row.country != nil)
            }
            var seen = Set<UUID>()
            for cell in payload.hexVisits where !storedIDs.contains(cell.id) && seen.insert(cell.id).inserted {
                guard let row = byCell[cell.h3Index] else {
                    byCell[cell.h3Index] = (cell.firstVisited, cell.lastVisited, cell.visitCount,
                                            cell.locality != nil, cell.country != nil)
                    new += 1
                    continue
                }
                let changes = cell.firstVisited < row.first || cell.lastVisited > row.last
                    || cell.visitCount > row.count
                    || (!row.locality && cell.locality != nil) || (!row.country && cell.country != nil)
                guard changes else { continue }
                byCell[cell.h3Index] = (min(row.first, cell.firstVisited), max(row.last, cell.lastVisited),
                                        max(row.count, cell.visitCount),
                                        row.locality || cell.locality != nil, row.country || cell.country != nil)
                new += 1
            }
        }
        return (new, malformedPings)
    }

    /// The one physical row a re-import may complete deferred title
    /// artifacts on: the file trip carries a canonical title and at least one
    /// declared stay, exactly one physical row with its UUID holds exactly
    /// the file's stays, that row has neither an AI title nor a custom name,
    /// its title inputs are still the ones this file restores, and the
    /// file's title is one of the titles those inputs derive (an older
    /// build's model title is left for Stage 5 to derive again). Matching
    /// members alone do not show an interrupted import: an edit that keeps
    /// them (a stay made transit, a date or place changed) invalidates the
    /// title, and the file's would describe the trip before it. Preview and
    /// commit share this rule, so neither depends on the fetch order of UUID
    /// twins and an ambiguous twin set receives nothing.
    func titleCompletionTarget(
        for importedTrip: ImportedTrip,
        among rows: [Trip]
    ) -> (trip: Trip, title: String)? {
        guard let title = TripTitleStore.normalized(importedTrip.aiGeneratedTitle),
              !importedTrip.stays.isEmpty else { return nil }
        let holders = rows.filter { row in
            !row.isDeleted && Self.restoresExactMembership(
                importedTrip,
                attachedStayIDs: Set((row.stays ?? []).map(\.id)),
                attachedStayCount: row.stays?.count ?? 0)
        }
        guard holders.count == 1, let row = holders.first,
              TripTitleStore.normalized(row.aiGeneratedTitle) == nil,
              TripTitleStore.normalized(row.customName) == nil,
              let stored = storedTitleInputs(of: row),
              stored.snapshot == restoredSemanticSnapshot(of: importedTrip),
              stored.alternatives.contains(title) else {
            return nil
        }
        return (row, title)
    }

    /// The title inputs a restore gives a trip it brings back whole: the
    /// file's trip and stay fields as `importTrips` stores them, the airport
    /// flag stamped as it stamps it, in `Trip.stablySorted` order.
    func restoredSemanticSnapshot(
        of importedTrip: ImportedTrip
    ) -> TripTitleStore.SemanticSnapshot {
        let stays = importedTrip.stays.map { stay in
            TripTitleStore.SemanticSnapshot.StayInput(
                id: stay.id,
                orderInTrip: stay.orderInTrip,
                startTime: stay.startTime,
                endTime: stay.endTime,
                durationMinutes: stay.durationMinutes,
                categoryRaw: StayCategory(rawValue: stay.categoryRaw) != nil
                    ? stay.categoryRaw : StayCategory.unclassified.rawValue,
                isAirport: restoredIsAirport(stay),
                metroName: stay.metroName,
                islandName: stay.islandName,
                locality: stay.locality,
                administrativeArea: stay.administrativeArea,
                country: stay.country,
                isoCountryCode: stay.isoCountryCode)
        }.sorted { a, b in
            if (a.orderInTrip ?? 0) != (b.orderInTrip ?? 0) {
                return (a.orderInTrip ?? 0) < (b.orderInTrip ?? 0)
            }
            if a.startTime != b.startTime { return a.startTime < b.startTime }
            return a.id.uuidString < b.id.uuidString
        }
        return TripTitleStore.SemanticSnapshot(
            tripID: importedTrip.id,
            startDate: importedTrip.startDate,
            endDate: importedTrip.endDate,
            isComplete: importedTrip.isComplete,
            customName: importedTrip.customName,
            stays: stays)
    }

    /// The row's title inputs as the store holds them now and the titles
    /// they derive, read in a fresh context: this actor's context can keep a
    /// row cached from an earlier run while another context edits it. Nil
    /// when a read fails.
    private func storedTitleInputs(
        of row: Trip
    ) -> (snapshot: TripTitleStore.SemanticSnapshot, alternatives: [String])? {
        let context = ModelContext(modelContainer)
        let identifier = row.persistentModelID
        guard let fresh = try? context.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { $0.persistentModelID == identifier })).first,
              let alternatives = try? TripTitleStore.generatedTitleAlternatives(for: fresh, in: context) else {
            return nil
        }
        return (TripTitleStore.semanticSnapshot(for: fresh), alternatives)
    }

    /// The Home prompt context a file's titles were generated against.
    nonisolated static func expectedActiveHomeTitleInputs(
        of payload: ImportPayload
    ) -> [TripTitleStore.ActiveHomeTitleInput] {
        payload.homes
            .filter { $0.endedAt == nil }
            .map {
                TripTitleStore.ActiveHomeTitleInput(
                    id: $0.id,
                    locality: TripTitleStore.normalized($0.locality)
                        .map(TripTitleStore.normalizedPlaceName),
                    country: $0.country,
                    isoCountryCode: $0.isoCountryCode)
            }
    }

    /// The file's photo choices of one kind that the commit inserts: each
    /// whose row id the store does not hold, whose trip exists after the
    /// import and that neither a stored row of that trip nor an earlier
    /// choice already holds, under the identity the dedup and the trip
    /// merge's copy use. Oldest first, so of two file duplicates the one the
    /// dedup would keep lands. Preview and commit share the rule.
    nonisolated static func photoChoicesToRestore(
        _ choices: [ImportedPhotoChoice],
        held: [HeldPhotoChoice],
        tripIDs: Set<UUID>
    ) -> (restore: [ImportedPhotoChoice], missingTrip: Int) {
        var identities: [UUID: PhotoAnnotationDeduplicator.ChoiceIdentities] = [:]
        var heldIDs = Set(held.map(\.id))
        for row in held {
            identities[row.tripID, default: .init()].hold(
                localIdentifier: row.localIdentifier, cloudIdentifier: row.cloudIdentifier)
        }
        var restore: [ImportedPhotoChoice] = []
        var missingTrip = 0
        for choice in choices.sorted(by: {
            ($0.chosenAt, $0.tripID.uuidString, $0.localIdentifier, $0.cloudIdentifier ?? "")
                < ($1.chosenAt, $1.tripID.uuidString, $1.localIdentifier, $1.cloudIdentifier ?? "")
        }) {
            guard heldIDs.insert(choice.id).inserted else { continue }
            guard tripIDs.contains(choice.tripID) else {
                missingTrip += 1
                continue
            }
            if identities[choice.tripID, default: .init()].admit(
                localIdentifier: choice.localIdentifier,
                cloudIdentifier: choice.cloudIdentifier) {
                restore.append(choice)
            }
        }
        return (restore, missingTrip)
    }

    /// Merges a committed import's Favorites (those whose trip exists
    /// after it) and Earlier Travels into the user's sets. A union: nothing
    /// is removed, and a file without them changes nothing. Returns how many
    /// were added.
    @MainActor
    static func mergeSelections(
        of outcome: ImportOutcome, from payload: ImportPayload,
        favourites: PinnedTripsStorage = .shared,
        countries: RememberedCountriesStorage = .shared
    ) -> Int {
        guard !outcome.saveFailed else { return 0 }
        return favourites.merge(outcome.restorableFavouriteTripIDs)
            + countries.merge(payload.rememberedCountryCodes)
    }

    /// One stored photo choice, as `photoChoicesToRestore` reads it.
    typealias HeldPhotoChoice = (id: UUID, tripID: UUID, localIdentifier: String, cloudIdentifier: String?)

    /// The stored photo choices of both kinds. A kind the file does not
    /// carry is not read.
    func heldPhotoChoices(
        for payload: ImportPayload
    ) throws -> (hidden: [HeldPhotoChoice], pinned: [HeldPhotoChoice]) {
        var hidden: [HeldPhotoChoice] = []
        if !payload.hiddenPhotos.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<HiddenPhoto>()) {
                hidden.append((row.id, row.tripID, row.localIdentifier, row.cloudIdentifier))
            }
        }
        var pinned: [HeldPhotoChoice] = []
        if !payload.pinnedPhotos.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<PinnedPhoto>()) {
                pinned.append((row.id, row.tripID, row.localIdentifier, row.cloudIdentifier))
            }
        }
        return (hidden, pinned)
    }

    nonisolated static func restoresExactMembership(
        _ importedTrip: ImportedTrip,
        attachedStayIDs: Set<UUID>,
        attachedStayCount: Int
    ) -> Bool {
        let declaredStayCount = importedTrip.declaredStayCount
            ?? importedTrip.stays.count
        let parsedStayIDs = Set(importedTrip.stays.map(\.id))
        return importedTrip.stays.count == declaredStayCount
            && parsedStayIDs.count == declaredStayCount
            && attachedStayCount == declaredStayCount
            && attachedStayIDs.count == declaredStayCount
            && attachedStayIDs == parsedStayIDs
    }
}
