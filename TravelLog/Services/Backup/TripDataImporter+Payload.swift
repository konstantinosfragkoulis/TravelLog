//
//  TripDataImporter+Payload.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

// MARK: - Parsed payload (Sendable value mirror of the backup)

/// One stay entry parsed from a backup: the exported record itself.
typealias ImportedStay = ExportStaySnapshot

extension ExportStaySnapshot {
    /// The stored cell when it is one the app writes; a stay without one, or
    /// with a string that is not a valid cell at the app's resolution, takes
    /// its centroid's (`BackupLimits.cellIndex`). Degenerate coordinates that
    /// H3 cannot index leave the stay out, the photo-import path's policy.
    nonisolated var admittedH3Index: String? {
        BackupLimits.cellIndex(
            h3IndexRes6, latitude: centroidLatitude, longitude: centroidLongitude)
    }
}

/// One localized title row from a trip's `localizedTitles` array.
/// Source-title identity is validated again at insertion time.
typealias ImportedLocalizedTitle = BackupLocalizedTitle

typealias ImportedTrip = ExportTripSnapshot
typealias ImportedHome = ExportHomeSnapshot
/// One declared temporary home; `removedAt` is set on an entry of
/// `removedTemporaryHomes` only.
typealias ImportedTemporaryHome = ExportTemporaryHomeSnapshot
typealias ImportedRoutinePlace = ExportRoutinePlaceSnapshot
typealias ImportedOverride = ExportOverrideSnapshot
typealias ImportedVisit = ExportVisitSnapshot
typealias ImportedPhotoChoice = ExportPhotoChoiceSnapshot

/// The backup's `pings` array, read in place: the history can hold hundreds
/// of thousands of rows, so it is decoded a chunk at a time, by the preview
/// and again by the commit, never all at once.
nonisolated struct BackupPingSection: Sendable {
    /// The whole document (memory-mapped in the app) and the array's range.
    let data: Data
    let range: Range<Int>?

    static let empty = BackupPingSection(data: Data(), range: nil)

    /// Rows per chunk: the most decoded pings either pass holds.
    static let chunkSize = 2_000

    var isEmpty: Bool { range == nil }

    /// Each chunk's admitted pings (`ExportPingSnapshot.admitted`) and the
    /// count of damaged entries in it, an entry past `maxPingBytes` among
    /// them. A chunk that is not valid JSON throws: the file is damaged.
    func forEachChunk(
        size: Int = BackupPingSection.chunkSize,
        _ body: ([ExportPingSnapshot], Int) throws -> Void
    ) throws {
        guard let range else { return }
        let decoder = BackupCoding.makeDecoder()
        do {
            try BackupJSONScanner.forEachChunk(
                ofArrayAt: range, in: data, chunkSize: size, maxElementBytes: BackupLimits.maxPingBytes
            ) { chunk, count in
                let entries: [BackupLossy<ExportPingSnapshot>]
                do {
                    entries = try decoder.decode([BackupLossy<ExportPingSnapshot>].self, from: chunk)
                } catch {
                    throw TripDataImportError.notJSON
                }
                let admitted = entries.compactMap { $0.value?.admitted }
                try body(admitted, count - admitted.count)
            }
        } catch is BackupJSONScanner.Malformed {
            throw TripDataImportError.notJSON
        }
    }
}

nonisolated struct ImportPayload: Sendable {
    let formatVersion: Int
    let trips: [ImportedTrip]
    /// Entries dropped by the parser (missing or invalid core fields), apart
    /// from stays, Visits and the counts below.
    let malformedTrips: Int
    let malformedStays: Int
    /// Tripless travel stays (steady-state transit residue and hydration
    /// transients).
    var unassignedStays: [ImportedStay] = []
    /// The home-area layer: declared homes, home/routine dwell stays (orbit
    /// return evidence and home-area correction stays), taught overrides.
    var homes: [ImportedHome] = []
    var homeStays: [ImportedStay] = []
    var homeAreaOverrides: [ImportedOverride] = []
    var routinePlaces: [ImportedRoutinePlace] = []
    var visits: [ImportedVisit] = []
    var malformedVisits: Int = 0
    var temporaryHomes: [ImportedTemporaryHome] = []
    /// Removed temporary homes, one per id, each with `removedAt`.
    var removedTemporaryHomes: [ImportedTemporaryHome] = []
    var hiddenPhotos: [ImportedPhotoChoice] = []
    var pinnedPhotos: [ImportedPhotoChoice] = []
    /// Favorites and Earlier Travels (iCloud key-value data).
    var favouriteTripIDs: Set<UUID> = []
    var rememberedCountryCodes: Set<String> = []
    var yearWrapped: [ExportYearWrappedSnapshot] = []
    var plannedTrips: [ExportPlannedTripSnapshot] = []
    var photoImportStates: [ExportPhotoImportStateSnapshot] = []
    var hexVisits: [ExportHexVisitSnapshot] = []
    /// The device-local Removed Trips queue the backup carried.
    var removedTrips: [DissolvedTripRecord] = []
    var preferences = BackupPreferences()
    var pings = BackupPingSection.empty
    /// Damaged entries among the records above (pings are counted when the
    /// preview reads them).
    var malformedRecords: Int = 0

    var totalStays: Int {
        trips.reduce(0) { $0 + $1.stays.count } + unassignedStays.count + homeStays.count
    }

    /// Which trip entries the file declares completed with no stays at all for
    /// a trip the user owns: a name, an edit, a Favorite or a hidden or pinned
    /// photo. Live dedup keeps such a row for its owner and export writes it,
    /// so restore lands it as an empty row with its choices instead of taking
    /// it for a phantom. A trip whose declared members all failed to parse or
    /// land is damaged, not empty, and stays out. Judged per entry: another
    /// entry with the same id never exempts one that declared stays.
    var ownedEmptyTrips: OwnedEmptyTripRule {
        OwnedEmptyTripRule(
            favouriteTripIDs: favouriteTripIDs,
            photoChoiceTripIDs: Set(hiddenPhotos.map(\.tripID)).union(pinnedPhotos.map(\.tripID)))
    }
}

/// `ImportPayload.ownedEmptyTrips`: ownership through a Favorite or a photo
/// choice is the trip id's, emptiness and the name and edit are the entry's.
nonisolated struct OwnedEmptyTripRule: Sendable {
    let favouriteTripIDs: Set<UUID>
    let photoChoiceTripIDs: Set<UUID>

    func admits(_ trip: ImportedTrip) -> Bool {
        trip.isComplete && trip.stays.isEmpty && (trip.declaredStayCount ?? 0) == 0
            && (trip.userEdited || favouriteTripIDs.contains(trip.id)
                || photoChoiceTripIDs.contains(trip.id)
                || !(trip.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

nonisolated enum TripDataImportError: LocalizedError {
    case notJSON
    case missingTripsArray
    /// The file's `formatVersion` is above `TripDataExporter.formatVersion`.
    case newerFormat
    /// The file was written in a format before this build's (or carries no
    /// version): such a backup holds a reconstruction, not the history.
    case olderFormat
    /// The file expands past `BackupLimits` (a decompression bomb, or record
    /// sections no backup reaches): refused before anything is written.
    case tooLarge
    /// A password-protected backup whose password did not match its check.
    case wrongPassword
    /// A password-protected backup whose header is out of bounds, or whose
    /// contents failed authentication: changed or cut off since it was made.
    case protectedBackupDamaged
    /// A password-protected backup in an envelope version this build does
    /// not know.
    case protectedBackupNewer

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return String(localized: "data-import.error.invalid-json", defaultValue: "The file is not valid JSON.", comment: "Error shown when an imported file is not valid JSON.")
        case .missingTripsArray:
            return String(localized: "data-import.error.missing-trips", defaultValue: "The file doesn't look like a Travel Log export. No \"trips\" array was found.", comment: "Error shown when an imported JSON file has no trips array.")
        case .newerFormat:
            return String(localized: "data-import.error.newer-format", defaultValue: "This backup was made by a newer version of Travel Log. Update the app to import it.", comment: "Error shown when an imported backup was written by a newer app version than this one.")
        case .olderFormat:
            return String(localized: "data-import.error.older-format", defaultValue: "This backup was made by an earlier version of Travel Log and can't be imported. Update Travel Log on the device that has your trips, then export a new backup there.", comment: "Error shown when an imported backup was written in a format older than the one this app version reads.")
        case .tooLarge:
            return String(localized: "data-import.error.too-large", defaultValue: "This file is larger than any Travel Log backup can be, so it can't be imported. It may be damaged.", comment: "Error shown when an imported backup expands to more data than a real backup holds, such as a damaged or altered file.")
        case .wrongPassword:
            return String(localized: "data-import.error.wrong-password", defaultValue: "That password is incorrect. Check it and try again.", comment: "Error shown when the password entered for a protected backup does not match.")
        case .protectedBackupDamaged:
            return String(localized: "data-import.error.protected-damaged", defaultValue: "This protected backup is damaged or was changed after it was made, so it can't be opened.", comment: "Error shown when a password-protected backup fails its integrity check or is cut off.")
        case .protectedBackupNewer:
            return String(localized: "data-import.error.protected-newer", defaultValue: "This protected backup was made by a newer version of Travel Log. Update the app to open it.", comment: "Error shown when a password-protected backup uses an encryption format newer than this app version reads.")
        }
    }
}

/// What an import WOULD do — shown in the confirmation alert before commit.
nonisolated struct ImportPreview: Sendable {
    let newTrips: Int
    let newStays: Int
    let existingTrips: Int
    let malformedEntries: Int
    /// Id-new Home, HomeAreaOverride, RoutinePlace and TemporaryHome rows,
    /// each removal the store does not hold yet, and each declaration the
    /// store keeps that lacks one of the file's kept trips. Counted so a
    /// home-layer-only restore is admitted.
    var newHomeAreaRows: Int = 0
    /// Existing trips whose checkpointed graph an interrupted earlier import
    /// of this file committed without its deferred title artifacts, and that
    /// a re-import may complete (same rule as the commit). Advisory: the
    /// commit re-validates membership and the final Home context.
    var restorableTitles: Int = 0
    /// Id-new Visit rows. The commit inserts them, so a file whose only
    /// missing rows are Visits (a failed final transaction) stays admissible.
    var newVisits: Int = 0
    /// Hidden and pinned photo choices the commit would add (the commit's
    /// rule), and the Favorites and Earlier Travels it would add after it.
    var newChoices: Int = 0
    /// Id-new pings, Wrapped recaps, planned trips and photo-import states,
    /// hex cells the store lacks, and Removed Trips archives the commit
    /// would queue: the history's records outside trips.
    var newRecords: Int = 0
    /// Settings and answers the restore of the file's preferences would add
    /// after a committed import (`BackupPreferences.additions`, read on the
    /// main actor). The commit reads the storage again when it applies them.
    var newPreferences: Int = 0

    /// The Settings admission rule: anything the commit would write.
    var hasImportableContent: Bool {
        newTrips > 0 || newStays > 0 || newHomeAreaRows > 0
            || restorableTitles > 0 || newVisits > 0 || newChoices > 0
            || newRecords > 0 || newPreferences > 0
    }
}

nonisolated struct ImportOutcome: Sendable {
    let insertedTrips: Int
    let insertedStays: Int
    let skippedExistingTrips: Int
    let skippedInvalidStays: Int
    /// True when any save failed mid-import — the counts above then
    /// overstate what actually persisted.
    var saveFailed: Bool = false
    /// Home-area rows that landed. Non-zero values tell the caller to bump
    /// the home/override trackers and run the healing pass.
    var insertedHomes: Int = 0
    var insertedOverrides: Int = 0
    var insertedRoutinePlaces: Int = 0
    var insertedVisits: Int = 0
    /// Existing trips whose deferred canonical title (and localized
    /// derivatives) this import completed. Zero unless the final
    /// transaction committed.
    var restoredTitles: Int = 0
    /// Temporary homes that landed. Zero unless the final transaction or a
    /// checkpoint committed them.
    var insertedTemporaryHomes: Int = 0
    /// Temporary-home reconciliations this import left in
    /// `CoverageReconciliationQueue`: one per inserted temporary home, one
    /// per temporary home already in the store when any stay landed, and one
    /// per temporary home whose kept trips this import added to.
    /// Non-zero tells the caller to drain the queue before healing. A run
    /// that fails before its final transaction reports zero; what it queued
    /// at a checkpoint stays queued for the activation drain.
    var stagedTemporaryHomeReconciliations: Int = 0
    /// Removed temporary homes this import inserted or stamped.
    var appliedTemporaryHomeRemovals: Int = 0
    /// Hidden and pinned photo choices that landed. Zero unless the final
    /// transaction committed.
    var insertedPhotoChoices: Int = 0
    /// Photo choices left out because their trip does not exist after the
    /// import (choices a trip already holds are not counted).
    var skippedPhotoChoices: Int = 0
    /// The file's Favorites whose trip exists after the import, for the
    /// caller to merge. Empty unless the final transaction committed.
    var restorableFavouriteTripIDs: Set<UUID> = []
    /// Pings that landed (their chunks committed).
    var insertedPings: Int = 0
    /// Wrapped recaps, planned trips, photo-import states and hex cells that
    /// landed or merged with the final transaction, and Removed Trips
    /// archives queued after it.
    var insertedRecords: Int = 0
}

/// Value snapshot of an imported stay whose offline place layers
/// (administrativeArea/metroName/islandName) still need the geocode heal —
/// collected during `importTrips` and resolved OUTSIDE its gate unit. It is
/// the witness the answer applies under: the physical row (its durable id,
/// taken after the save that committed it), its logical id and the exact
/// centroid the resolver answered for.
nonisolated struct PendingGeocode: Sendable, Equatable {
    let persistentID: PersistentIdentifier
    let stayID: UUID
    let latitude: Double
    let longitude: Double

    init(_ stay: Stay) {
        persistentID = stay.persistentModelID
        stayID = stay.id
        latitude = stay.centroidLatitude
        longitude = stay.centroidLongitude
    }

    /// The row is still the one the answer was resolved for, at the same
    /// centroid, and still has none of the offline place layers. A row moved,
    /// replaced or filled by another lane meanwhile takes nothing.
    func matches(_ stay: Stay) -> Bool {
        stay.id == stayID
            && stay.centroidLatitude == latitude && stay.centroidLongitude == longitude
            && stay.administrativeArea == nil && stay.metroName == nil && stay.islandName == nil
    }
}
