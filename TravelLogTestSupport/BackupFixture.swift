//
//  BackupFixture.swift
//  TravelLogTests
//
//  v15 backup documents for tests: from snapshots (the exporter's own
//  writer) or from short hand-written JSON that this fills out to the full
//  record shape the reader requires.
//

import Foundation
@testable import TravelLog

nonisolated enum BackupFixture {

    /// A v15 document from snapshots, written by the exporter's writer.
    static func buildExportData(
        snapshots: [ExportTripSnapshot],
        unassignedStays: [ExportStaySnapshot] = [],
        homes: [ExportHomeSnapshot] = [],
        homeStays: [ExportStaySnapshot] = [],
        homeAreaOverrides: [ExportOverrideSnapshot] = [],
        routinePlaces: [ExportRoutinePlaceSnapshot] = [],
        visits: [ExportVisitSnapshot] = [],
        temporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        removedTemporaryHomes: [ExportTemporaryHomeSnapshot] = [],
        hiddenPhotos: [ExportPhotoChoiceSnapshot] = [],
        pinnedPhotos: [ExportPhotoChoiceSnapshot] = [],
        hexVisits: [ExportHexVisitSnapshot] = [],
        favouriteTripIDs: Set<UUID> = [],
        rememberedCountryCodes: Set<String> = [],
        removedTrips: [DissolvedTripRecord] = [],
        pings: [ExportPingSnapshot] = [],
        appVersion: String = "test"
    ) -> Data? {
        var layer = ExportSnapshotter.HomeAreaExport()
        layer.unassignedStays = unassignedStays
        layer.homes = homes
        layer.homeStays = homeStays
        layer.overrides = homeAreaOverrides
        layer.routinePlaces = routinePlaces
        layer.visits = visits
        layer.temporaryHomes = temporaryHomes
        layer.removedTemporaryHomes = removedTemporaryHomes
        layer.hiddenPhotos = hiddenPhotos
        layer.pinnedPhotos = pinnedPhotos
        layer.hexVisits = hexVisits
        var extras = BackupExtras()
        extras.favouriteTripIDs = favouriteTripIDs
        extras.rememberedCountryCodes = rememberedCountryCodes
        extras.removedTrips = removedTrips
        extras.appVersion = appVersion
        return TripDataExporter.buildExportData(
            BackupContents(trips: snapshots, layer: layer, extras: extras), pings: pings)
    }

    // MARK: Hand-written documents

    /// A v15 document from hand-written JSON. `formatVersion` is 15 unless
    /// the root names one. In every record: a date may be written as an ISO
    /// 8601 string, an attribute left out takes the model's default, and in
    /// a stay `latitude`/`longitude`/`category` stand for
    /// `centroidLatitude`/`centroidLongitude`/`categoryRaw`, in a Visit
    /// `arrival`/`departure` for `arrivalDate`/`departureDate`.
    static func document(_ root: [String: Any]) throws -> Data {
        var root = root
        if root["formatVersion"] == nil { root["formatVersion"] = TripDataExporter.formatVersion }
        for (key, fill) in sections {
            guard let entries = root[key] as? [Any] else { continue }
            root[key] = entries.map { entry in
                (entry as? [String: Any]).map(fill) ?? entry
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func document(json: String) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let root = root as? [String: Any] else {
            return Data(json.utf8)
        }
        return try document(root)
    }

    static func parse(_ root: [String: Any]) throws -> ImportPayload {
        try TripDataImporter.parse(document(root))
    }

    static func parse(json: String) throws -> ImportPayload {
        try TripDataImporter.parse(document(json: json))
    }

    /// The reference-date number a date is stored as.
    static func stored(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }

    private static var sections: [(String, ([String: Any]) -> [String: Any])] { [
        ("trips", trip),
        ("unassignedStays", stay),
        ("homeStays", stay),
        ("homes", home),
        ("temporaryHomes", temporaryHome),
        ("removedTemporaryHomes", temporaryHome),
        ("routinePlaces", routinePlace),
        ("homeAreaOverrides", override),
        ("visits", visit),
        ("hiddenPhotos", photoChoice),
        ("pinnedPhotos", photoChoice),
        ("hexVisits", hexVisit),
        ("pings", ping),
        ("yearWrapped", { filled($0, [:]) }),
        ("plannedTrips", { filled($0, [:]) }),
        ("photoImportStates", { filled($0, [:]) }),
    ] }

    private static let dateKeys: Set<String> = [
        "startTime", "endTime", "startDate", "endDate", "dayKey", "startedAt", "endedAt",
        "createdAt", "modifiedAt", "removedAt", "arrivalDate", "departureDate", "receivedAt",
        "hiddenAt", "pinnedAt", "updatedAt", "generatedAt", "viewedAt", "lastSeenAt",
        "completedAt", "watermarkCreationDate", "lastUpdated", "firstVisited", "lastVisited",
        "timestamp", "summaryGeneratedAt",
    ]

    private static func isoDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: string) ?? fractional.date(from: string)
    }

    /// Renames, then dates as stored numbers, then the defaults for absent keys.
    private static func filled(
        _ entry: [String: Any], _ defaults: [String: Any], renames: [String: String] = [:]
    ) -> [String: Any] {
        var entry = entry
        for (from, to) in renames where entry[to] == nil {
            if let value = entry.removeValue(forKey: from) { entry[to] = value }
        }
        for (key, value) in entry where dateKeys.contains(key) {
            if let string = value as? String, let date = isoDate(string) {
                entry[key] = stored(date)
            }
        }
        for (key, value) in defaults where entry[key] == nil {
            entry[key] = value
        }
        return entry
    }

    private static func stay(_ entry: [String: Any]) -> [String: Any] {
        var entry = filled(entry, [
            "durationMinutes": 0, "isAirport": false, "h3IndexRes6": "", "pingCount": 0,
            "distanceFromHomeKm": 0.0, "categoryRaw": "destination", "userOverridden": false,
            "continuesPreviousTrip": false, "pingIDsString": "",
            "sourceRaw": DataSource.liveSLC.rawValue,
        ], renames: [
            "latitude": "centroidLatitude", "longitude": "centroidLongitude",
            "category": "categoryRaw",
        ])
        if entry["durationMinutes"] as? Int == 0,
           let start = entry["startTime"] as? Double, let end = entry["endTime"] as? Double {
            entry["durationMinutes"] = max(0, Int((end - start) / 60))
        }
        return entry
    }

    private static func trip(_ entry: [String: Any]) -> [String: Any] {
        var entry = filled(entry, [
            "destinationSummary": "", "countryCodes": "", "classifiedByAI": false,
            "userEdited": false, "keptByTemporaryHome": false,
            "sourceRaw": DataSource.liveSLC.rawValue, "stays": [Any](),
        ])
        if entry["isComplete"] == nil { entry["isComplete"] = entry["endDate"] != nil }
        if let stays = entry["stays"] as? [Any] {
            entry["stays"] = stays.map { ($0 as? [String: Any]).map(stay) ?? $0 }
        }
        if let titles = entry["localizedTitles"] as? [Any] {
            entry["localizedTitles"] = titles.map { ($0 as? [String: Any]).map { filled($0, [:]) } ?? $0 }
        }
        return entry
    }

    private static func home(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, ["label": "", "radiusKm": 25.0])
    }

    private static func temporaryHome(_ entry: [String: Any]) -> [String: Any] {
        var entry = filled(entry, [
            "label": "", "radiusKm": 25.0, "coverageRevision": 0, "keptTripIDs": [Any](),
        ])
        for key in ["createdAt", "modifiedAt"] where entry[key] == nil {
            entry[key] = entry["startedAt"]
        }
        return entry
    }

    private static func routinePlace(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, ["label": "", "radiusMeters": 500.0, "isActive": true])
    }

    private static func override(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, ["radiusKm": 1.0, "createdAt": 0.0])
    }

    private static func visit(_ entry: [String: Any]) -> [String: Any] {
        var entry = filled(entry, ["horizontalAccuracy": 10.0, "isProcessed": true], renames: [
            "arrival": "arrivalDate", "departure": "departureDate",
        ])
        if entry["receivedAt"] == nil { entry["receivedAt"] = entry["arrivalDate"] }
        return entry
    }

    private static func photoChoice(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, ["id": UUID().uuidString])
    }

    private static func hexVisit(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, [
            "id": UUID().uuidString, "visitCount": 1, "centerLatitude": 0.0, "centerLongitude": 0.0,
        ])
    }

    private static func ping(_ entry: [String: Any]) -> [String: Any] {
        filled(entry, [
            "horizontalAccuracy": 0.0, "h3IndexRes6": "", "isGeocoded": false,
            "isProcessed": false, "sourceRaw": DataSource.liveSLC.rawValue,
        ])
    }
}
