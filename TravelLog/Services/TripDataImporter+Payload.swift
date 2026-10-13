//
//  TripDataImporter+Payload.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

// MARK: - Parsed payload (Sendable value mirror of the export JSON)

/// One stay entry parsed from an export file. Only the spatial/temporal
/// core is required; everything else is optional so v1 exports (and
/// hand-trimmed or third-party files) import gracefully.
nonisolated struct ImportedStay: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let latitude: Double
    let longitude: Double
    let categoryRaw: String?
    let pingCount: Int?
    let distanceFromHomeKm: Double?
    let locality: String?
    let country: String?
    let isoCountryCode: String?
    // v2 fidelity fields
    let userOverridden: Bool?
    let isAirport: Bool?
    let sourceRaw: String?
    let h3IndexRes6: String?
    let administrativeArea: String?
    let subLocality: String?
    let metroName: String?
    let islandName: String?
    let transitFromPreviousRaw: String?
    let distanceFromPreviousKm: Double?
    let stepsWalked: Int?
    let weatherConditionRaw: String?
    let avgTemperatureC: Double?
    let precipitationMm: Double?
    // v3 fidelity fields; absent in v1/v2 files.
    var weatherData: Data? = nil
    var dayKey: Date? = nil
    /// v10; absent in earlier files. A missing value is re-derived from
    /// longitude at insertion, never from the importing device's zone.
    var timeZoneIdentifier: String? = nil
    /// v12: the temporary home that made the stay `.home`. Kept only on a
    /// stay that lands as `.home`; absent in earlier files.
    var temporaryHomeID: UUID? = nil
    /// v13: the coverage revision beside `temporaryHomeID`; nil in earlier
    /// files. Kept only with the id, clamped to the declaration the import
    /// keeps.
    var temporaryHomeRevision: Int? = nil

    var admittedH3Index: String? {
        h3IndexRes6.flatMap { $0.isEmpty ? nil : $0 }
            ?? H3Service.cellIndex(latitude: latitude, longitude: longitude)
    }
}

/// v7/v8: one localized title row from a trip's optional `localizedTitles`
/// array. Source-title identity is validated again at insertion time.
typealias ImportedLocalizedTitle = BackupLocalizedTitle

nonisolated struct ImportedTrip: Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date?
    let isComplete: Bool
    let classifiedByAI: Bool
    let stays: [ImportedStay]
    /// Number of member rows declared in the source trip before tolerant
    /// parsing drops malformed entries. Full-trip AI artifacts are faithful
    /// only when every declared member is parsed and uniquely attached.
    var declaredStayCount: Int? = nil
    // v2 fidelity fields
    let customName: String?
    let aiGeneratedTitle: String?
    let aiGeneratedSummary: String?
    let summarySourceRaw: String?
    let userEdited: Bool?
    let sourceRaw: String?
    /// v7; absent in v1-v6 files.
    var localizedTitles: [ImportedLocalizedTitle] = []
    /// v8; absent in v1-v7 files.
    var titleSourceRevision: UUID? = nil
    /// v12: `userEdited` was set by a temporary-home change. Absent is false.
    var keptByTemporaryHome: Bool = false
}

/// v6: one declared home row from the export's `homes` array.
typealias ImportedHome = ExportHomeSnapshot

/// v11: one declared temporary home from the export's `temporaryHomes` array.
/// `removedAt` is set on an entry of `removedTemporaryHomes` only; the v13
/// revision and kept trips are zero and empty in earlier files.
typealias ImportedTemporaryHome = ExportTemporaryHomeSnapshot

/// v6: one routine place from the export's `routinePlaces` array.
typealias ImportedRoutinePlace = ExportRoutinePlaceSnapshot

/// v6: one home-area override from the export's `homeAreaOverrides` array.
typealias ImportedOverride = ExportOverrideSnapshot

typealias ImportedVisit = ExportVisitSnapshot

nonisolated struct ImportPayload: Sendable {
    let formatVersion: Int
    let trips: [ImportedTrip]
    /// Entries dropped by the tolerant parser (missing id/dates/coords).
    let malformedTrips: Int
    let malformedStays: Int
    /// v5: tripless travel stays (steady-state transit residue + hydration
    /// transients). Absent in pre-v5 files — defaulted for source compat.
    var unassignedStays: [ImportedStay] = []
    /// v6: the home-area layer — declared homes, home/routine dwell stays
    /// (orbit return evidence + home-area correction stays), taught overrides.
    /// Absent in pre-v6 files — defaulted for source compat.
    var homes: [ImportedHome] = []
    var homeStays: [ImportedStay] = []
    var homeAreaOverrides: [ImportedOverride] = []
    var routinePlaces: [ImportedRoutinePlace] = []
    var visits: [ImportedVisit] = []
    var malformedVisits: Int = 0
    /// v11: declared temporary homes. Absent in pre-v11 files.
    var temporaryHomes: [ImportedTemporaryHome] = []
    /// v12: removed temporary homes, one per id, each with `removedAt`.
    /// Absent in pre-v12 files.
    var removedTemporaryHomes: [ImportedTemporaryHome] = []

    var totalStays: Int {
        trips.reduce(0) { $0 + $1.stays.count } + unassignedStays.count + homeStays.count
    }
}

nonisolated enum TripDataImportError: LocalizedError {
    case notJSON
    case missingTripsArray

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return String(localized: "data-import.error.invalid-json", defaultValue: "The file is not valid JSON.", comment: "Error shown when an imported file is not valid JSON.")
        case .missingTripsArray:
            return String(localized: "data-import.error.missing-trips", defaultValue: "The file doesn't look like a Travel Log export. No \"trips\" array was found.", comment: "Error shown when an imported JSON file has no trips array.")
        }
    }
}

/// What an import WOULD do — shown in the confirmation alert before commit.
nonisolated struct ImportPreview: Sendable {
    let newTrips: Int
    let newStays: Int
    let existingTrips: Int
    let malformedEntries: Int
    /// v6: id-new Home + HomeAreaOverride + RoutinePlace rows. Counted so
    /// the admission gate admits a home-layer-only restore (a file whose
    /// trips/stays already exist but whose corrections do not).
    /// v11 counts id-new TemporaryHome rows here too, so a backup holding
    /// only new declarations is admitted. v12 counts each removal the store
    /// does not hold yet, so a backup whose only news is a removal is too.
    /// v13 counts each declaration the store keeps that lacks one of the
    /// file's kept trips.
    var newHomeAreaRows: Int = 0
    /// Existing trips whose checkpointed graph an interrupted earlier import
    /// of this file committed without its deferred title artifacts, and that
    /// a re-import may complete (same rule as the commit). Advisory: the
    /// commit re-validates membership and the final Home context.
    var restorableTitles: Int = 0
    /// v9: id-new Visit rows. The commit inserts them, so a file whose only
    /// missing rows are Visits (a failed final transaction) stays admissible.
    var newVisits: Int = 0

    /// The Settings admission rule: anything the commit would write.
    var hasImportableContent: Bool {
        newTrips > 0 || newStays > 0 || newHomeAreaRows > 0
            || restorableTitles > 0 || newVisits > 0
    }
}

nonisolated struct ImportOutcome: Sendable {
    let insertedTrips: Int
    let insertedStays: Int
    let skippedExistingTrips: Int
    let skippedInvalidStays: Int
    /// True when any `modelContext.save()` failed mid-import — the counts
    /// above then overstate what actually persisted.
    var saveFailed: Bool = false
    /// v6: home-area rows that landed (defaulted for source compat with
    /// pre-v6 call sites). Non-zero values tell the caller to bump the
    /// home/override trackers and run the healing pass.
    var insertedHomes: Int = 0
    var insertedOverrides: Int = 0
    var insertedRoutinePlaces: Int = 0
    var insertedVisits: Int = 0
    /// Existing trips whose deferred canonical title (and localized
    /// derivatives) this import completed. Zero unless the final
    /// transaction committed.
    var restoredTitles: Int = 0
    /// v11: temporary homes that landed. Zero unless the final transaction
    /// committed.
    var insertedTemporaryHomes: Int = 0
    /// Temporary-home reconciliations this import left in
    /// `CoverageReconciliationQueue`: one per inserted temporary home, one
    /// per temporary home already in the store when any stay landed, and one
    /// per temporary home whose kept trips this import added to.
    /// Non-zero tells the caller to drain the queue before healing. A run
    /// that fails before its final transaction reports zero; what it queued
    /// at a checkpoint stays queued for the activation drain.
    var stagedTemporaryHomeReconciliations: Int = 0
    /// v12: removed temporary homes this import inserted or stamped. Zero
    /// unless the final transaction committed.
    var appliedTemporaryHomeRemovals: Int = 0
}

/// Value snapshot of an imported stay whose offline place layers
/// (administrativeArea/metroName/islandName) still need the geocode heal —
/// collected during `importTrips` and resolved OUTSIDE its gate unit.
nonisolated struct PendingGeocode: Sendable, Equatable {
    let stayID: UUID
    let latitude: Double
    let longitude: Double
}
