//
//  TripDataExporter.swift
//  TravelLog
//

import Foundation
import SwiftData

// MARK: - Export Snapshots

/// Sendable value mirrors of Trip/Stay for the off-main JSON export —
/// `@Model` objects must not cross the detached-task boundary (Swift 6).
///
/// Format history:
///   - **v1** (unversioned, pre-June-2026): trips + stays with the display
///     fields only (no names/titles, no provenance, no enrichment).
///   - **v2** (`"formatVersion": 2`): adds the fidelity fields needed for a
///     faithful restore via `TripDataImporter` — custom names, AI titles &
///     summaries, provenance, user overrides, airport flags, the offline-
///     geocoder name layers, and the V11 weather/transit enrichment. Every
///     v2 addition is an optional key, so v1 files remain importable and
///     old exports stay valid.
///   - **v3** (`"formatVersion": 3`): adds the full per-stay weather blob
///     (`weatherData` base64) and `dayKey`; pre-v3 imports recompute the
///     dayKey.
///   - **v4** (`"formatVersion": 4`): adds `summarySourceRaw`, the stored
///     narrative's provenance. Pre-v4 files import with nil provenance
///     rather than a guess.
///   - **v5** (`"formatVersion": 5`): adds a top-level `unassignedStays`
///     array (same stay shape) — the trip-centric walk silently dropped
///     every `trip == nil` stay: tripless transit residue
///     is STEADY STATE since the all-transit assembly rule, and a
///     mid-CloudKit-hydration export can catch a real destination stay
///     before its Trip link arrives. Scope is travel stays only —
///     home/routine dwell stays were never part of the trip-data export
///     (size + privacy) and regenerate from living there.
///   - **v6** (`"formatVersion": 6`): adds top-level
///     `homes`, `homeStays`, and `homeAreaOverrides` arrays. The v5 "home
///     stays regenerate from living there" rationale broke when the home
///     area became LEARNED: home/routine stays are now the orbit's return
///     evidence, and home-area corrections live as sacred `.home` stays plus
///     `HomeAreaOverride` rows — none of which v5 carried, so a restore
///     shrank the home area back to the seed, forgot every "this wasn't a
///     trip" teaching, and welded near-home trips. Home rows ride along so
///     override `homeID` era-scoping stays meaningful on a fresh install
///     (`PlacesDeduplicator` collapses the onboarding twin and re-points
///     override homeIDs — the existing two-device machinery).
///   - **v7** (`"formatVersion": 7`): adds each trip's optional
///     `localizedTitles` array. Every row carries the canonical source title
///     it was derived from, so a restore can reject stale translations rather
///     than attaching them to a different AI-generated title.
///   - **v8** (`"formatVersion": 8`): adds a source revision to the canonical
///     title and every derivative, preventing delayed equal-text CloudKit rows
///     from becoming current after a semantic regeneration.
///   - **v9** (`"formatVersion": 9`): raw Core Location visits.
///   - **v10** (`"formatVersion": 10`): each stay's optional
///     `timeZoneIdentifier` (V18), so a restore keeps the zone the stay was
///     stamped with instead of re-deriving it from longitude. Visits also
///     carry optional `arrivalBits`/`departureBits`: the hex bit pattern of
///     the reference-time Double beside the whole-second ISO strings, since
///     Visit identity (recorder coalescing, sibling grouping) is keyed on
///     exact arrival bits. Additive and optional, so no version bump: older
///     readers ignore them and files without them import at ISO precision.
///   - **v11** (`"formatVersion": 11`): a top-level `temporaryHomes` array
///     (V19), the dated places the user declared as temporary homes. Their
///     `.home` stays already ride in `homeStays` and the corrections keyed
///     to them in `homeAreaOverrides`; the declaration is the anchor that
///     explains both after a restore. `createdAt` and `modifiedAt` carry the
///     same optional exact bits as a Visit date (`createdAtBits`,
///     `modifiedAtBits`), because same-id twins are ranked on them.
///     `startedAt` and `endedAt` ride at whole-second precision, like the
///     stay dates they are compared with.
///   - **v12** (`"formatVersion": 12`, V20): each stay's optional
///     `temporaryHomeID` (the temporary home that made it `.home`), each
///     trip's `keptByTemporaryHome` when true, and a top-level
///     `removedTemporaryHomes` array: one entry per removed temporary home,
///     the `temporaryHomes` keys plus `removedAt`. The live array never holds
///     a removed id, so an older importer cannot bring one back.
///   - **v13** (`"formatVersion": 13`, V21): each temporary home's
///     `coverageRevision` and `keptTripIDs` (a UUID string array, the union
///     over every row with the id, written when non-empty), in both arrays,
///     and each stay's `temporaryHomeRevision` beside its `temporaryHomeID`.
///   - **v14** (`"formatVersion": 14`): each Visit's `isProcessed`, written
///     only when false, so a pending observation restores pending and the
///     clusterer still turns it into history. Earlier files restore every
///     Visit processed, as before.
nonisolated struct ExportStaySnapshot: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let durationMinutes: Int
    let categoryRaw: String
    let latitude: Double
    let longitude: Double
    let pingCount: Int
    let distanceFromHomeKm: Double
    let locality: String?
    let country: String?
    let isoCountryCode: String?
    // v2 fidelity fields
    let userOverridden: Bool
    let isAirport: Bool
    let sourceRaw: String
    let h3IndexRes6: String
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
    // v3 fidelity fields. Defaulted `var`s so the
    // memberwise init stays source-compatible with v2-era call sites.
    var weatherData: Data? = nil
    var dayKey: Date? = nil
    // v10: defaulted for the same source-compatibility reason.
    var timeZoneIdentifier: String? = nil
    // v12: defaulted for the same source-compatibility reason.
    var temporaryHomeID: UUID? = nil
    // v13: the revision beside `temporaryHomeID`, defaulted likewise.
    var temporaryHomeRevision: Int? = nil
}

/// v6: one declared home row — the era anchor for `homeAreaOverrides` and
/// the windowed classification of `homeStays`.
nonisolated struct ExportHomeSnapshot: Sendable {
    let id: UUID
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusKm: Double
    let locality: String?
    let administrativeArea: String?
    let country: String?
    let isoCountryCode: String?
    let startedAt: Date
    let endedAt: Date?
}

/// v11: one declared temporary home, the dated anchor for the `.home` stays
/// and `homeAreaOverrides` rows keyed to it.
nonisolated struct ExportTemporaryHomeSnapshot: Sendable {
    let id: UUID
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusKm: Double
    let locality: String?
    let administrativeArea: String?
    let country: String?
    let isoCountryCode: String?
    let startedAt: Date
    let endedAt: Date?
    let timeZoneIdentifier: String?
    let createdAt: Date
    let modifiedAt: Date
    /// v12: set on a removed one only.
    var removedAt: Date? = nil
    /// v13: the exported row's revision, and the kept trips of every row
    /// with the id (a keep on a losing twin counts too).
    var coverageRevision: Int = 0
    var keptTripIDs: Set<UUID> = []
}

/// v6: one routine place — the declaration behind exported `.routine`
/// stays. Without it a restore leaves routine history unexplained, and any
/// reset path (Reclassify All) turns the gym/office into phantom trip
/// destinations.
nonisolated struct ExportRoutinePlaceSnapshot: Sendable {
    let id: UUID
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let isActive: Bool
    let startedAt: Date
    let endedAt: Date?
}

/// v6: one home-area override (user include / learned-place exclude).
nonisolated struct ExportOverrideSnapshot: Sendable {
    let id: UUID
    let kindRaw: String
    let centerLatitude: Double
    let centerLongitude: Double
    let radiusKm: Double
    let homeID: UUID?
    let sourceTripName: String?
    let createdAt: Date
}

/// v7/v8: a localized rendering of one canonical AI-generated title.
typealias ExportLocalizedTitleSnapshot = BackupLocalizedTitle

nonisolated struct ExportVisitSnapshot: Sendable {
    let id: UUID
    let stayID: UUID?
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let receivedAt: Date
    /// v14: defaulted, so a snapshot that does not say is processed (the
    /// pre-v14 restore rule).
    var isProcessed: Bool = true
}

nonisolated struct ExportTripSnapshot: Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date?
    let isComplete: Bool
    let destinationSummary: String
    let countryCodes: String
    let classifiedByAI: Bool
    let durationDays: Int?
    let stays: [ExportStaySnapshot]
    // v2 fidelity fields
    let customName: String?
    let aiGeneratedTitle: String?
    let aiGeneratedSummary: String?
    let userEdited: Bool
    let sourceRaw: String
    // v4: summary provenance (SummarySource rawValue) — defaulted like the
    // v3 fields so older call sites/tests stay source-compatible.
    var summarySourceRaw: String? = nil
    // v7: defaulted so v1-v6-oriented tests and helper call sites retain
    // their memberwise-initializer source compatibility.
    var localizedTitles: [ExportLocalizedTitleSnapshot] = []
    // v8: canonical source-incarnation identity. Optional for v1-v7 callers.
    var titleSourceRevision: UUID? = nil
    // v12: defaulted like the fields above.
    var keptByTemporaryHome: Bool = false
}

// MARK: - Exporter

/// Builds the user-facing JSON export. `ExportSnapshotter` snapshots the
/// store into Sendable values in its own context, off the main actor; the
/// JSON tree build, serialization, and file write run off-main too
/// (`buildExportFile` is called from a detached task by
/// `SettingsView.exportData`).
enum TripDataExporter {

    /// Current export format version. Bump ONLY when adding keys (all keys
    /// must stay optional for the importer's tolerant parser); never remove
    /// or rename existing keys — old app versions and third-party consumers
    /// read them.
    nonisolated static let formatVersion = 14

    /// Snapshot `@Model` trips into Sendable value mirrors. Call it on the
    /// isolation that owns the trips' `ModelContext`.
    nonisolated static func makeSnapshots(from trips: [Trip]) -> [ExportTripSnapshot] {
        trips.map { trip in
            ExportTripSnapshot(
                id: trip.id,
                startDate: trip.startDate,
                endDate: trip.endDate,
                isComplete: trip.isComplete,
                destinationSummary: trip.destinationSummary,
                countryCodes: trip.countryCodes,
                classifiedByAI: trip.classifiedByAI,
                durationDays: trip.durationDays,
                stays: trip.orderedStays.map { makeStaySnapshot(from: $0) },
                customName: trip.customName,
                aiGeneratedTitle: trip.aiGeneratedTitle,
                aiGeneratedSummary: trip.aiGeneratedSummary,
                userEdited: trip.userEdited,
                sourceRaw: trip.sourceRaw,
                summarySourceRaw: trip.summarySourceRaw,
                localizedTitles: makeLocalizedTitleSnapshots(
                    from: trip.localizedTitles ?? [],
                    canonicalTitle: trip.aiGeneratedTitle,
                    sourceRevision: trip.titleSourceRevision),
                titleSourceRevision: trip.titleSourceRevision,
                keptByTemporaryHome: trip.keptByTemporaryHome
            )
        }
    }

    /// Only complete rows are useful outside the store. Stable ordering keeps
    /// otherwise-identical exports byte-stable despite unordered relationship
    /// materialization or CloudKit duplicate rows.
    nonisolated private static func makeLocalizedTitleSnapshots(
        from variants: [TripTitleVariant],
        canonicalTitle: String?,
        sourceRevision: UUID?
    ) -> [ExportLocalizedTitleSnapshot] {
        BackupLocalizedTitle.selected(variants.map {
                ExportLocalizedTitleSnapshot(
                    id: $0.id,
                    languageTag: $0.languageTag,
                    title: $0.title,
                    sourceTitle: $0.sourceTitle,
                    generationVersion: $0.generationVersion,
                    updatedAt: $0.updatedAt,
                    sourceRevision: $0.sourceRevision)
            }, canonicalTitle: canonicalTitle, sourceRevision: sourceRevision)
    }

    /// v5: snapshot the `trip == nil` TRAVEL stays the trip walk misses —
    /// steady-state transit residue plus any destination/unclassified stay
    /// caught mid-CloudKit-hydration. Home/routine dwell stays stay out of
    /// the export deliberately (never carried; size + privacy).
    nonisolated static func makeUnassignedSnapshots(from stays: [Stay]) -> [ExportStaySnapshot] {
        stays
            .filter { $0.trip == nil && $0.category != .home && $0.category != .routine }
            .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
            .map { makeStaySnapshot(from: $0) }
    }

    /// v6: home/routine dwell stays — the learned orbit's return evidence
    /// and the home-area corrections' sacred `.home` rows. Same stay shape.
    nonisolated static func makeHomeStaySnapshots(from stays: [Stay]) -> [ExportStaySnapshot] {
        stays
            .filter { $0.trip == nil && ($0.category == .home || $0.category == .routine) }
            .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
            .map { makeStaySnapshot(from: $0) }
    }

    /// v6: declared home rows, era order.
    nonisolated static func makeHomeSnapshots(from homes: [Home]) -> [ExportHomeSnapshot] {
        homes
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            .map { home in
                ExportHomeSnapshot(
                    id: home.id, label: home.label,
                    latitude: home.latitude, longitude: home.longitude,
                    radiusKm: home.radiusKm,
                    locality: home.locality,
                    administrativeArea: home.administrativeArea,
                    country: home.country, isoCountryCode: home.isoCountryCode,
                    startedAt: home.startedAt, endedAt: home.endedAt)
            }
    }

    /// v11: declared temporary homes, era order. Same-id twins (two devices
    /// importing one backup) export once, as the row every reader resolves
    /// them to. A removed id is left out (`makeRemovedTemporaryHomeSnapshots`).
    /// v13: the kept trips are the union over every row with the id.
    nonisolated static func makeTemporaryHomeSnapshots(from rows: [TemporaryHome]) -> [ExportTemporaryHomeSnapshot] {
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        return HomeAnchors.collapsingTwins(rows).map {
            makeTemporaryHomeSnapshot(from: $0, twins: rowsByID[$0.id] ?? [])
        }
    }

    /// v12: one entry per removed temporary home, its removed rows ranked
    /// like twins, era order.
    nonisolated static func makeRemovedTemporaryHomeSnapshots(
        from rows: [TemporaryHome]
    ) -> [ExportTemporaryHomeSnapshot] {
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        return HomeAnchors.removedTwins(rows).map {
            makeTemporaryHomeSnapshot(from: $0, twins: rowsByID[$0.id] ?? [])
        }
    }

    nonisolated private static func makeTemporaryHomeSnapshot(
        from row: TemporaryHome, twins: [TemporaryHome]
    ) -> ExportTemporaryHomeSnapshot {
        ExportTemporaryHomeSnapshot(
            id: row.id, label: row.label,
            latitude: row.latitude, longitude: row.longitude,
            radiusKm: row.radiusKm,
            locality: row.locality,
            administrativeArea: row.administrativeArea,
            country: row.country, isoCountryCode: row.isoCountryCode,
            startedAt: row.startedAt, endedAt: row.endedAt,
            timeZoneIdentifier: row.timeZoneIdentifier,
            createdAt: row.createdAt, modifiedAt: row.modifiedAt,
            removedAt: row.removedAt,
            coverageRevision: row.coverageRevision,
            keptTripIDs: TemporaryHome.keptTripIDs(of: twins))
    }

    /// v6: routine-place declarations, era order.
    nonisolated static func makeRoutinePlaceSnapshots(from places: [RoutinePlace]) -> [ExportRoutinePlaceSnapshot] {
        places
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            .map { place in
                ExportRoutinePlaceSnapshot(
                    id: place.id, label: place.label,
                    latitude: place.latitude, longitude: place.longitude,
                    radiusMeters: place.radiusMeters, isActive: place.isActive,
                    startedAt: place.startedAt, endedAt: place.endedAt)
            }
    }

    /// v6: home-area overrides — the user's taught corrections.
    nonisolated static func makeOverrideSnapshots(from overrides: [HomeAreaOverride]) -> [ExportOverrideSnapshot] {
        overrides
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { row in
                ExportOverrideSnapshot(
                    id: row.id, kindRaw: row.kindRaw,
                    centerLatitude: row.centerLatitude,
                    centerLongitude: row.centerLongitude,
                    radiusKm: row.radiusKm, homeID: row.homeID,
                    sourceTripName: row.sourceTripName, createdAt: row.createdAt)
            }
    }

    nonisolated static func makeVisitSnapshots(from visits: [Visit]) -> [ExportVisitSnapshot] {
        visits
            .sorted { ($0.arrivalDate, $0.id.uuidString) < ($1.arrivalDate, $1.id.uuidString) }
            .map { visit in
                ExportVisitSnapshot(
                    id: visit.id,
                    stayID: visit.stayID,
                    arrivalDate: visit.arrivalDate,
                    departureDate: visit.departureDate,
                    latitude: visit.latitude,
                    longitude: visit.longitude,
                    horizontalAccuracy: visit.horizontalAccuracy,
                    receivedAt: visit.receivedAt,
                    isProcessed: visit.isProcessed)
            }
    }

    nonisolated private static func makeStaySnapshot(from stay: Stay) -> ExportStaySnapshot {
        ExportStaySnapshot(
            id: stay.id,
            startTime: stay.startTime,
            endTime: stay.endTime,
            durationMinutes: stay.durationMinutes,
            categoryRaw: stay.categoryRaw,
            latitude: stay.centroidLatitude,
            longitude: stay.centroidLongitude,
            pingCount: stay.pingCount,
            distanceFromHomeKm: stay.distanceFromHomeKm,
            locality: stay.locality,
            country: stay.country,
            isoCountryCode: stay.isoCountryCode,
            userOverridden: stay.userOverridden,
            isAirport: stay.isAirport,
            sourceRaw: stay.sourceRaw,
            h3IndexRes6: stay.h3IndexRes6,
            administrativeArea: stay.administrativeArea,
            subLocality: stay.subLocality,
            metroName: stay.metroName,
            islandName: stay.islandName,
            transitFromPreviousRaw: stay.transitFromPreviousRaw,
            distanceFromPreviousKm: stay.distanceFromPreviousKm,
            stepsWalked: stay.stepsWalked,
            weatherConditionRaw: stay.weatherConditionRaw,
            avgTemperatureC: stay.avgTemperatureC,
            precipitationMm: stay.precipitationMm,
            weatherData: stay.weatherData,
            dayKey: stay.dayKey,
            timeZoneIdentifier: stay.timeZoneIdentifier,
            temporaryHomeID: stay.temporaryHomeID,
            temporaryHomeRevision: stay.temporaryHomeRevision
        )
    }

    nonisolated static let exportFilePrefix = "TravelLog-Export-"
    /// The DEBUG diagnostics export, staged in the same temporary directory.
    nonisolated static let diagnosticsExportFileName = "TravelLog-diagnostics.json"

    /// Removes staged export copies from the temporary directory, including
    /// ones a share interrupted by app termination left behind.
    nonisolated static func removeStagedExports() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name == diagnosticsExportFileName
            || (name.hasPrefix(exportFilePrefix) && name.hasSuffix(".json")) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Off-main export worker: builds the export JSON and writes it to a
    /// temp file. Returns nil on serialization or write failure.
    ///
    /// v1 keys are emitted exactly as before (same names, same ISO-8601
    /// formatting, same `.prettyPrinted`/`.sortedKeys`) so existing
    /// consumers keep working; v2 adds `formatVersion` plus the optional
    /// fidelity keys.
    nonisolated static func buildExportFile(
        snapshots: [ExportTripSnapshot],
        unassignedStays: [ExportStaySnapshot] = [],
        homes: [ExportHomeSnapshot] = [],
        homeStays: [ExportStaySnapshot] = [],
        homeAreaOverrides: [ExportOverrideSnapshot] = [],
        routinePlaces: [ExportRoutinePlaceSnapshot] = [],
        visits: [ExportVisitSnapshot] = [],
        temporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        removedTemporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        appVersion: String
    ) -> URL? {
        guard let data = buildExportData(
            snapshots: snapshots, unassignedStays: unassignedStays,
            homes: homes, homeStays: homeStays,
            homeAreaOverrides: homeAreaOverrides,
            routinePlaces: routinePlaces, visits: visits,
            temporaryHomes: temporaryHomes,
            removedTemporaryHomes: removedTemporaryHomes,
            appVersion: appVersion
        ) else {
            return nil
        }
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(exportFilePrefix)\(Date.now.formatted(.iso8601.year().month().day())).json")
            // Atomic: a failed or interrupted write never leaves a truncated file at the shared URL.
            try data.write(to: tempURL, options: [.atomic, .completeFileProtection])
            return tempURL
        } catch {
            return nil
        }
    }

    /// Tree-build + serialization, separated from the file write so tests
    /// can round-trip export → import without touching disk.
    nonisolated static func buildExportData(
        snapshots: [ExportTripSnapshot],
        unassignedStays: [ExportStaySnapshot] = [],
        homes: [ExportHomeSnapshot] = [],
        homeStays: [ExportStaySnapshot] = [],
        homeAreaOverrides: [ExportOverrideSnapshot] = [],
        routinePlaces: [ExportRoutinePlaceSnapshot] = [],
        visits: [ExportVisitSnapshot] = [],
        temporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        removedTemporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        appVersion: String
    ) -> Data? {
        let dateFormatter = ISO8601DateFormatter()
        var exportTrips: [[String: Any]] = []
        for trip in snapshots {
            var tripDict: [String: Any] = [
                "id": trip.id.uuidString,
                "startDate": dateFormatter.string(from: trip.startDate),
                "isComplete": trip.isComplete,
                "destinationSummary": trip.destinationSummary,
                "countryCodes": trip.countryCodes,
                "classifiedByAI": trip.classifiedByAI,
                "userEdited": trip.userEdited,
                "sourceRaw": trip.sourceRaw
            ]
            // v12: written only when set, so other trips read as before.
            if trip.keptByTemporaryHome {
                tripDict["keptByTemporaryHome"] = true
            }
            if let endDate = trip.endDate {
                tripDict["endDate"] = dateFormatter.string(from: endDate)
            }
            if let days = trip.durationDays {
                tripDict["durationDays"] = days
            }
            if let name = trip.customName, !name.isEmpty {
                tripDict["customName"] = name
            }
            if let title = trip.aiGeneratedTitle, !title.isEmpty {
                tripDict["aiGeneratedTitle"] = title
            }
            if let revision = trip.titleSourceRevision {
                tripDict["titleSourceRevision"] = revision.uuidString
            }
            if let summary = trip.aiGeneratedSummary, !summary.isEmpty {
                tripDict["aiGeneratedSummary"] = summary
                // v4: provenance travels with the summary it describes.
                if let source = trip.summarySourceRaw {
                    tripDict["summarySourceRaw"] = source
                }
            }
            let localizedTitles = BackupLocalizedTitle.selected(
                trip.localizedTitles,
                canonicalTitle: trip.aiGeneratedTitle,
                sourceRevision: trip.titleSourceRevision)
            if !localizedTitles.isEmpty {
                tripDict["localizedTitles"] = localizedTitles.map { variant in
                    var dictionary = [
                        "id": variant.id.uuidString,
                        "languageTag": variant.languageTag,
                        "title": variant.title,
                        "sourceTitle": variant.sourceTitle,
                        "generationVersion": variant.generationVersion,
                        "updatedAt": dateFormatter.string(from: variant.updatedAt),
                    ] as [String: Any]
                    if let revision = variant.sourceRevision {
                        dictionary["sourceRevision"] = revision.uuidString
                    }
                    return dictionary
                }
            }

            tripDict["stays"] = trip.stays.map { stayDict(for: $0, using: dateFormatter) }
            exportTrips.append(tripDict)
        }

        var exportDict: [String: Any] = [
            "formatVersion": formatVersion,
            "exportDate": dateFormatter.string(from: .now),
            "appVersion": appVersion,
            "tripCount": snapshots.count,
            "trips": exportTrips
        ]
        // v5: tripless travel stays — steady-state transit
        // residue + hydration transients — round-trip too. Key emitted only
        // when non-empty so v4-era consumers see byte-identical output for
        // stores without residue.
        if !unassignedStays.isEmpty {
            exportDict["unassignedStays"] = unassignedStays.map { stayDict(for: $0, using: dateFormatter) }
        }
        // v6: the home-area layer — declared home rows,
        // home/routine dwell stays (the orbit's return evidence + home-area correction
        // sacred stays), and the taught overrides. Keys emitted only when
        // non-empty, the v5 rule.
        if !homes.isEmpty {
            exportDict["homes"] = homes.map { home -> [String: Any] in
                var dict: [String: Any] = [
                    "id": home.id.uuidString,
                    "label": home.label,
                    "latitude": finite(home.latitude),
                    "longitude": finite(home.longitude),
                    "radiusKm": finite(home.radiusKm, fallback: 25),
                    "startedAt": dateFormatter.string(from: home.startedAt)
                ]
                if let endedAt = home.endedAt { dict["endedAt"] = dateFormatter.string(from: endedAt) }
                if let locality = home.locality { dict["locality"] = locality }
                if let admin = home.administrativeArea { dict["administrativeArea"] = admin }
                if let country = home.country { dict["country"] = country }
                if let code = home.isoCountryCode { dict["isoCountryCode"] = code }
                return dict
            }
        }
        if !homeStays.isEmpty {
            exportDict["homeStays"] = homeStays.map { stayDict(for: $0, using: dateFormatter) }
        }
        if !routinePlaces.isEmpty {
            exportDict["routinePlaces"] = routinePlaces.map { place -> [String: Any] in
                var dict: [String: Any] = [
                    "id": place.id.uuidString,
                    "label": place.label,
                    "latitude": finite(place.latitude),
                    "longitude": finite(place.longitude),
                    "radiusMeters": finite(place.radiusMeters, fallback: 500),
                    "isActive": place.isActive,
                    "startedAt": dateFormatter.string(from: place.startedAt)
                ]
                if let endedAt = place.endedAt { dict["endedAt"] = dateFormatter.string(from: endedAt) }
                return dict
            }
        }
        if !homeAreaOverrides.isEmpty {
            exportDict["homeAreaOverrides"] = homeAreaOverrides.map { row -> [String: Any] in
                var dict: [String: Any] = [
                    "id": row.id.uuidString,
                    "kindRaw": row.kindRaw,
                    "centerLatitude": finite(row.centerLatitude),
                    "centerLongitude": finite(row.centerLongitude),
                    "radiusKm": finite(row.radiusKm, fallback: 1),
                    "createdAt": dateFormatter.string(from: row.createdAt)
                ]
                if let homeID = row.homeID { dict["homeID"] = homeID.uuidString }
                if let source = row.sourceTripName { dict["sourceTripName"] = source }
                return dict
            }
        }
        if !visits.isEmpty {
            exportDict["visits"] = visits.map { visit -> [String: Any] in
                var dict: [String: Any] = [
                    "id": visit.id.uuidString,
                    "arrival": dateFormatter.string(from: visit.arrivalDate),
                    "lat": finite(visit.latitude),
                    "lon": finite(visit.longitude),
                    "accuracy": finite(visit.horizontalAccuracy),
                    "receivedAt": dateFormatter.string(from: visit.receivedAt)
                ]
                dict["arrivalBits"] = exactDateBits(visit.arrivalDate)
                if let stayID = visit.stayID { dict["stayID"] = stayID.uuidString }
                if let departure = visit.departureDate {
                    dict["departure"] = dateFormatter.string(from: departure)
                    dict["departureBits"] = exactDateBits(departure)
                }
                // v14: only a pending Visit says so; absent reads as processed.
                if !visit.isProcessed { dict["isProcessed"] = false }
                return dict
            }
        }
        // v11: declared temporary homes. Key emitted only when non-empty,
        // the v5 rule. `createdAt` and `modifiedAt` carry their exact bits
        // beside the ISO string (the Visit rule above). `startedAt` and
        // `endedAt` do not: they are compared with stay dates, which ride at
        // whole-second precision, so both must round the same way.
        func temporaryHomeDict(_ home: ExportTemporaryHomeSnapshot) -> [String: Any] {
            var dict: [String: Any] = [
                "id": home.id.uuidString,
                "label": home.label,
                "latitude": finite(home.latitude),
                "longitude": finite(home.longitude),
                "radiusKm": finite(home.radiusKm, fallback: 25),
                "startedAt": dateFormatter.string(from: home.startedAt),
                "createdAt": dateFormatter.string(from: home.createdAt),
                "createdAtBits": exactDateBits(home.createdAt),
                "modifiedAt": dateFormatter.string(from: home.modifiedAt),
                "modifiedAtBits": exactDateBits(home.modifiedAt)
            ]
            if let endedAt = home.endedAt {
                dict["endedAt"] = dateFormatter.string(from: endedAt)
            }
            if let locality = home.locality { dict["locality"] = locality }
            if let admin = home.administrativeArea { dict["administrativeArea"] = admin }
            if let country = home.country { dict["country"] = country }
            if let code = home.isoCountryCode { dict["isoCountryCode"] = code }
            if let zone = home.timeZoneIdentifier { dict["timeZoneIdentifier"] = zone }
            // v13: the revision always; the kept trips sorted, when there are any.
            dict["coverageRevision"] = home.coverageRevision
            if !home.keptTripIDs.isEmpty {
                dict["keptTripIDs"] = home.keptTripIDs.map(\.uuidString).sorted()
            }
            return dict
        }
        if !temporaryHomes.isEmpty {
            exportDict["temporaryHomes"] = temporaryHomes.map(temporaryHomeDict)
        }
        // v12: removed temporary homes, apart from the live array so an
        // older importer never reads one as live. `removedAt` is a fact, not
        // a rank, so it rides without exact bits.
        let removed = removedTemporaryHomes.filter { $0.removedAt != nil }
        if !removed.isEmpty {
            exportDict["removedTemporaryHomes"] = removed.map { home -> [String: Any] in
                var dict = temporaryHomeDict(home)
                if let removedAt = home.removedAt {
                    dict["removedAt"] = dateFormatter.string(from: removedAt)
                }
                return dict
            }
        }

        return try? JSONSerialization.data(withJSONObject: exportDict, options: [.prettyPrinted, .sortedKeys])
    }

    /// Exact, lossless form of a Visit date: the 16-digit hex bit pattern of
    /// its `timeIntervalSinceReferenceDate`. Read back by
    /// `TripDataImporter.parse` next to the ISO string it refines.
    nonisolated static func exactDateBits(_ date: Date) -> String {
        let hex = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// One stay entry of the export JSON — shared by the per-trip arrays and
    /// the v5 top-level `unassignedStays` array so the shapes cannot drift.
    nonisolated private static func stayDict(
        for stay: ExportStaySnapshot, using dateFormatter: ISO8601DateFormatter
    ) -> [String: Any] {
        var stayDict: [String: Any] = [
            "id": stay.id.uuidString,
            "startTime": dateFormatter.string(from: stay.startTime),
            "endTime": dateFormatter.string(from: stay.endTime),
            "durationMinutes": stay.durationMinutes,
            "category": stay.categoryRaw,
            "latitude": finite(stay.latitude),
            "longitude": finite(stay.longitude),
            "pingCount": stay.pingCount,
            "distanceFromHomeKm": finite(stay.distanceFromHomeKm),
            "userOverridden": stay.userOverridden,
            "isAirport": stay.isAirport,
            "sourceRaw": stay.sourceRaw,
            "h3IndexRes6": stay.h3IndexRes6
        ]
        if let locality = stay.locality { stayDict["locality"] = locality }
        if let country = stay.country { stayDict["country"] = country }
        if let code = stay.isoCountryCode { stayDict["isoCountryCode"] = code }
        if let admin = stay.administrativeArea { stayDict["administrativeArea"] = admin }
        if let sub = stay.subLocality { stayDict["subLocality"] = sub }
        if let metro = stay.metroName { stayDict["metroName"] = metro }
        if let island = stay.islandName { stayDict["islandName"] = island }
        if let transit = stay.transitFromPreviousRaw { stayDict["transitFromPreviousRaw"] = transit }
        if let km = stay.distanceFromPreviousKm, km.isFinite { stayDict["distanceFromPreviousKm"] = km }
        if let steps = stay.stepsWalked { stayDict["stepsWalked"] = steps }
        if let condition = stay.weatherConditionRaw { stayDict["weatherConditionRaw"] = condition }
        if let zone = stay.timeZoneIdentifier { stayDict["timeZoneIdentifier"] = zone }
        if let temporaryHomeID = stay.temporaryHomeID {
            stayDict["temporaryHomeID"] = temporaryHomeID.uuidString
            // v13: the revision travels with the provenance it qualifies.
            if let revision = stay.temporaryHomeRevision {
                stayDict["temporaryHomeRevision"] = revision
            }
        }
        if let temp = stay.avgTemperatureC, temp.isFinite { stayDict["avgTemperatureC"] = temp }
        if let precip = stay.precipitationMm, precip.isFinite { stayDict["precipitationMm"] = precip }
        // v3: the full StayWeather blob (temperature
        // range, wind, humidity — the timeline popover's data) and
        // the (h3IndexRes6, dayKey) weather-cache key, so a restore
        // is weather-faithful, not scalar-only.
        if let blob = stay.weatherData { stayDict["weatherData"] = blob.base64EncodedString() }
        if let dayKey = stay.dayKey { stayDict["dayKey"] = dateFormatter.string(from: dayKey) }
        return stayDict
    }

    /// `JSONSerialization` raises an uncatchable Objective-C
    /// `NSInvalidArgumentException` on non-finite Doubles — `try?` cannot
    /// intercept it, so a single NaN/Inf field would crash the whole app
    /// mid-export. Required numeric fields are clamped to
    /// a neutral value; optional ones are dropped at their call sites.
    nonisolated private static func finite(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }
}

// MARK: - Off-main snapshotting (v6)

/// The export is snapshotted OFF the MainActor: home/routine dwell stays are
/// the majority of all stays on a long-lived install, and walking every
/// trip's stays measured ~0.17 ms per stay on main, seconds on an imported
/// history.
@ModelActor
actor ExportSnapshotter {

    struct HomeAreaExport: Sendable {
        var homes: [ExportHomeSnapshot] = []
        var homeStays: [ExportStaySnapshot] = []
        var overrides: [ExportOverrideSnapshot] = []
        var routinePlaces: [ExportRoutinePlaceSnapshot] = []
        var unassignedStays: [ExportStaySnapshot] = []
        var visits: [ExportVisitSnapshot] = []
        var temporaryHomes: [ExportTemporaryHomeSnapshot] = []
        var removedTemporaryHomes: [ExportTemporaryHomeSnapshot] = []
    }

    /// Every trip, newest first, with its ordered stays and title variants.
    /// A failed fetch throws: an empty array would serialize into a file that
    /// looks like a valid backup.
    func snapshotTrips() throws -> [ExportTripSnapshot] {
        let trips = try modelContext.fetch(FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]))
        return TripDataExporter.makeSnapshots(from: trips)
    }

    /// One pass over the store for everything the v5/v6 top-level arrays
    /// need: home rows, temporary homes (v11) and removed ones (v12), routine places, overrides,
    /// home/routine dwell stays, and the tripless travel residue. Throws
    /// like `snapshotTrips()`.
    func snapshotHomeAreaLayer() throws -> HomeAreaExport {
        var result = HomeAreaExport()
        let homeRows = try modelContext.fetch(FetchDescriptor<Home>())
        result.homes = TripDataExporter.makeHomeSnapshots(from: homeRows)
        let temporaryHomeRows = try modelContext.fetch(FetchDescriptor<TemporaryHome>())
        result.temporaryHomes = TripDataExporter.makeTemporaryHomeSnapshots(from: temporaryHomeRows)
        result.removedTemporaryHomes = TripDataExporter.makeRemovedTemporaryHomeSnapshots(
            from: temporaryHomeRows)
        let placeRows = try modelContext.fetch(FetchDescriptor<RoutinePlace>())
        result.routinePlaces = TripDataExporter.makeRoutinePlaceSnapshots(from: placeRows)
        let overrideRows = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
        result.overrides = TripDataExporter.makeOverrideSnapshots(from: overrideRows)
        let visitRows = try modelContext.fetch(FetchDescriptor<Visit>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .forward)]))
        result.visits = TripDataExporter.makeVisitSnapshots(from: visitRows)

        // One tripless fetch, partitioned in memory — the home/routine rows
        // and the travel residue are exact complements of `trip == nil`.
        let tripless = try modelContext.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate<Stay> { $0.trip == nil }))
        result.homeStays = TripDataExporter.makeHomeStaySnapshots(from: tripless)
        result.unassignedStays = TripDataExporter.makeUnassignedSnapshots(from: tripless)
        return result
    }
}
