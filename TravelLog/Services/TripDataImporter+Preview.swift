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
    /// Earlier Travels, read on the main actor, say which of the file's are new.
    func preview(
        of payload: ImportPayload,
        favouriteTripIDs: Set<UUID> = [],
        rememberedCountryCodes: Set<String> = []
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
                // won't insert.
                let insertableStays = trip.stays.filter { stay in
                    guard !existingStayIDs.contains(stay.id) else { return false }
                    let h3Index = stay.admittedH3Index
                    guard h3Index != nil else { return false }
                    existingStayIDs.insert(stay.id)
                    return true
                }
                guard !insertableStays.isEmpty else { continue }
                newTripIDs.insert(trip.id)
                newTrips += 1
                newStays += insertableStays.count
            }
        }
        // v5: unassigned stays count toward the preview's stay total under
        // the same insertability rules (id-new + H3-indexable). v6 home
        // stays follow the identical rule.
        for stay in payload.unassignedStays + payload.homeStays
        where !existingStayIDs.contains(stay.id) {
            let h3Index = stay.admittedH3Index
            if h3Index != nil {
                existingStayIDs.insert(stay.id)
                newStays += 1
            }
        }
        // v6: the home-area layer counts toward admission (id-new only).
        let existingHomeIDs = try fetchExistingIDs(
            FetchDescriptor<Home>(), id: \.id)
        let existingOverrideIDs = try fetchExistingIDs(
            FetchDescriptor<HomeAreaOverride>(), id: \.id)
        let existingPlaceIDs = try fetchExistingIDs(
            FetchDescriptor<RoutinePlace>(), id: \.id)
        let newHomeIDs = Set(payload.homes.map(\.id)).subtracting(existingHomeIDs)
        // v11: temporary homes are home-layer rows too (id-new only). Read
        // only when the file carries any. A live entry the file also removes
        // lands as the removal (the commit's rule).
        let fileRemovedTemporaryHomeIDs = Set(payload.removedTemporaryHomes.map(\.id))
        var newTemporaryHomes = 0
        if !payload.temporaryHomes.isEmpty {
            let storedTemporaryHomeRows = try fetchTemporaryHomeRows()
            newTemporaryHomes = Set(payload.temporaryHomes.map(\.id))
                .subtracting(storedTemporaryHomeRows.map(\.id))
                .subtracting(fileRemovedTemporaryHomeIDs).count
            // v13: so does a declaration the store keeps that lacks one of
            // the file's kept trips (the commit's merge).
            newTemporaryHomes += keptTripsToMerge(
                payload, into: storedTemporaryHomeRows).count
        }
        // v12: a removal counts when the store does not hold it yet, whether
        // the id is absent or live there.
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
           payload.formatVersion >= 6, newHomeIDs.isEmpty {
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

        // v14: photo choices count under the commit's rule, against the trips
        // that exist after it, and so do the Favorites and Earlier Travels
        // the merge after it would add.
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

        return ImportPreview(
            newTrips: newTrips,
            newStays: newStays,
            existingTrips: existingTrips,
            malformedEntries: payload.malformedTrips + payload.malformedStays
                + payload.malformedVisits,
            newHomeAreaRows: newHomeAreaRows,
            restorableTitles: titleCompletionTripIDs.count,
            newVisits: newVisits,
            newChoices: newChoices
        )
    }

    /// The one physical row a re-import may complete deferred title
    /// artifacts on: the file trip carries a canonical title and at least one
    /// declared stay, exactly one physical row with its UUID holds exactly
    /// the file's stays, and that row has neither an AI title nor a custom
    /// name. Preview and commit share this rule, so neither depends on the
    /// fetch order of UUID twins and an ambiguous twin set receives nothing.
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
              TripTitleStore.normalized(row.customName) == nil else {
            return nil
        }
        return (row, title)
    }

    /// The Home prompt context a v6+ file's titles were generated against.
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

    /// v14: the file's photo choices of one kind that the commit inserts:
    /// each whose trip exists after the import and that neither a stored row
    /// of that trip nor an earlier choice already holds, under the identity
    /// the dedup and the trip merge's copy use. Oldest first, so of two file
    /// duplicates the one the dedup would keep lands. Preview and commit
    /// share the rule.
    nonisolated static func photoChoicesToRestore(
        _ choices: [ImportedPhotoChoice],
        held: [HeldPhotoChoice],
        tripIDs: Set<UUID>
    ) -> (restore: [ImportedPhotoChoice], missingTrip: Int) {
        var identities: [UUID: PhotoAnnotationDeduplicator.ChoiceIdentities] = [:]
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

    /// v14: merges a committed import's Favorites (those whose trip exists
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
    typealias HeldPhotoChoice = (tripID: UUID, localIdentifier: String, cloudIdentifier: String?)

    /// The stored photo choices of both kinds. A kind the file does not
    /// carry is not read.
    func heldPhotoChoices(
        for payload: ImportPayload
    ) throws -> (hidden: [HeldPhotoChoice], pinned: [HeldPhotoChoice]) {
        var hidden: [HeldPhotoChoice] = []
        if !payload.hiddenPhotos.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<HiddenPhoto>()) {
                hidden.append((row.tripID, row.localIdentifier, row.cloudIdentifier))
            }
        }
        var pinned: [HeldPhotoChoice] = []
        if !payload.pinnedPhotos.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<PinnedPhoto>()) {
                pinned.append((row.tripID, row.localIdentifier, row.cloudIdentifier))
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
