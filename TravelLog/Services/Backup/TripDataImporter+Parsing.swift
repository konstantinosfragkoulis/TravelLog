//
//  TripDataImporter+Parsing.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

extension TripDataImporter {

    // MARK: Parsing (pure, nonisolated)

    /// Elements decoded at a time from a record section: each is decoded on
    /// its own copy, so a section never sits in the decoder whole.
    private nonisolated static let recordChunkSize = 256

    /// Parses a v15 backup document (uncompressed; `BackupFile` stages a
    /// picked file). Every section but `pings` is decoded here; the pings are
    /// read in place later (`BackupPingSection`). An entry that does not
    /// decode, or that fails admission (`TripDataImporter+Admission`), is
    /// counted and dropped rather than failing the whole file; a file that is
    /// not structurally sound JSON throws, and so does one whose record
    /// sections are larger than any backup this app writes.
    nonisolated static func parse(_ data: Data) throws -> ImportPayload {
        let members: [String: Range<Int>]
        do {
            members = try BackupJSONScanner.members(of: data)
        } catch {
            throw TripDataImportError.notJSON
        }
        let decoder = BackupCoding.makeDecoder()
        func slice(_ range: Range<Int>) -> Data {
            data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
        }
        func value<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            members[key].flatMap { try? decoder.decode(T.self, from: slice($0)) }
        }

        // A file without a version is a v1 export; a v15 file always says.
        let formatVersion = members["formatVersion"].flatMap { range -> Int? in
            range.count <= 32 ? try? decoder.decode(Int.self, from: slice(range)) : nil
        }
        guard members["trips"] != nil || formatVersion != nil else {
            throw TripDataImportError.missingTripsArray
        }
        guard let formatVersion, formatVersion >= TripDataExporter.formatVersion else {
            throw TripDataImportError.olderFormat
        }
        // A newer file can carry data this reader would silently drop, so it
        // is refused rather than half restored.
        guard formatVersion == TripDataExporter.formatVersion else {
            throw TripDataImportError.newerFormat
        }
        guard members["trips"] != nil else {
            throw TripDataImportError.missingTripsArray
        }
        // Everything but the pings is decoded into memory below.
        let recordBytes = members.reduce(0) { $0 + ($1.key == "pings" ? 0 : $1.value.count) }
        guard recordBytes <= BackupLimits.maxRecordSectionBytes else {
            throw TripDataImportError.tooLarge
        }

        /// Calls `body` with each element of the array member `key`, nil
        /// where one does not decode or is larger than `maxBytes`, a chunk at
        /// a time: only what `body` keeps stays in memory, so a section of
        /// damaged entries never holds a slot per entry. An absent member
        /// calls nothing; one that is not an array of JSON values means a
        /// damaged file.
        func forEachEntry<T: Decodable>(
            _ key: String, as type: T.Type, maxBytes: Int = BackupLimits.maxRecordBytes,
            _ body: (T?) -> Void
        ) throws {
            guard let range = members[key] else { return }
            do {
                try BackupJSONScanner.forEachChunk(
                    ofArrayAt: range, in: data, chunkSize: recordChunkSize, maxElementBytes: maxBytes
                ) { chunk, count in
                    let decoded = try decoder.decode([BackupLossy<T>].self, from: chunk)
                    for entry in decoded { body(entry.value) }
                    // Elements past the bound were left out of the chunk.
                    for _ in 0..<(count - decoded.count) { body(nil) }
                }
            } catch {
                throw key == "trips" ? TripDataImportError.missingTripsArray : TripDataImportError.notJSON
            }
        }

        var malformedTrips = 0
        var malformedStays = 0
        var malformedVisits = 0
        var malformedRecords = 0

        func admittedStay(_ candidate: ImportedStay?) -> ImportedStay? {
            guard let stay = candidate?.admitted else {
                malformedStays += 1
                return nil
            }
            return stay
        }

        var trips: [ImportedTrip] = []
        try forEachEntry("trips", as: ImportedTrip.self, maxBytes: BackupLimits.maxTripBytes) { candidate in
            guard var trip = candidate?.admitted else {
                malformedTrips += 1
                return
            }
            let declared = trip.declaredStayCount ?? trip.stays.count
            malformedStays += declared - trip.stays.count
            trip.stays = trip.stays.compactMap(admittedStay)
            trips.append(trip)
        }
        func staySection(_ key: String) throws -> [ImportedStay] {
            var result: [ImportedStay] = []
            try forEachEntry(key, as: ImportedStay.self, maxBytes: BackupLimits.maxStayBytes) { candidate in
                if let stay = admittedStay(candidate) { result.append(stay) }
            }
            return result
        }
        let unassignedStays = try staySection("unassignedStays")
        let homeStays = try staySection("homeStays")

        /// The home-layer tolerance rule: an entry that does not decode or
        /// fails admission is counted with the trips, never fails the file.
        func admitted<Entry: Decodable, T>(
            _ key: String, as type: Entry.Type, _ admit: (Entry) -> T?
        ) throws -> [T] {
            var result: [T] = []
            try forEachEntry(key, as: type) { candidate in
                guard let entry = candidate, let admitted = admit(entry) else {
                    malformedTrips += 1
                    return
                }
                result.append(admitted)
            }
            return result
        }

        let homes = try admitted("homes", as: ImportedHome.self) { $0.admitted }
        let temporaryHomes = try admitted(
            "temporaryHomes", as: ImportedTemporaryHome.self
        ) { home -> ImportedTemporaryHome? in
            guard var admitted = home.admitted else { return nil }
            admitted.removedAt = nil
            return admitted
        }
        let removedTemporaryHomes = try admitted(
            "removedTemporaryHomes", as: ImportedTemporaryHome.self
        ) { home -> ImportedTemporaryHome? in
            home.removedAt == nil ? nil : home.admitted
        }
        let homeAreaOverrides = try admitted(
            "homeAreaOverrides", as: ImportedOverride.self) { $0.admitted }
        let routinePlaces = try admitted(
            "routinePlaces", as: ImportedRoutinePlace.self) { $0.admitted }

        var visits: [ImportedVisit] = []
        try forEachEntry("visits", as: ImportedVisit.self) { candidate in
            guard let visit = candidate?.admitted else {
                malformedVisits += 1
                return
            }
            visits.append(visit)
        }

        let hiddenPhotos = try admitted(
            "hiddenPhotos", as: ExportHiddenPhotoRecord.self) { $0.choice.admitted }
        let pinnedPhotos = try admitted(
            "pinnedPhotos", as: ExportPinnedPhotoRecord.self) { $0.choice.admitted }

        /// Records outside the trip graph, counted on their own.
        func records<T: Decodable>(
            _ key: String, as type: T.Type, maxBytes: Int = BackupLimits.maxRecordBytes,
            _ admit: (T) -> T?
        ) throws -> [T] {
            var result: [T] = []
            try forEachEntry(key, as: type, maxBytes: maxBytes) { candidate in
                guard let record = candidate.flatMap(admit) else {
                    malformedRecords += 1
                    return
                }
                result.append(record)
            }
            return result
        }
        let yearWrapped = try records(
            "yearWrapped", as: ExportYearWrappedSnapshot.self,
            maxBytes: BackupLimits.maxLargeRecordBytes) { $0.admitted }
        let plannedTrips = try records("plannedTrips", as: ExportPlannedTripSnapshot.self) { $0.admitted }
        let photoImportStates = try records(
            "photoImportStates", as: ExportPhotoImportStateSnapshot.self) { $0.admitted }
        let hexVisits = try records("hexVisits", as: ExportHexVisitSnapshot.self) { $0.admitted }
        let removedTrips = try records(
            "removedTrips", as: DissolvedTripRecord.self,
            maxBytes: BackupLimits.maxLargeRecordBytes) { $0.isAdmissible ? $0 : nil }

        // An entry that is not a trip UUID or a real country code is dropped
        // on its own (the storage's rule).
        let favouriteTripIDs = Set((value("favouriteTripIDs", as: [BackupLossy<String>].self) ?? [])
            .prefix(BackupLimits.maxListEntries)
            .compactMap { $0.value.flatMap(UUID.init(uuidString:)) })
        let rememberedCountryCodes = RememberedCountriesStorage.normalized(
            (value("rememberedCountryCodes", as: [BackupLossy<String>].self) ?? [])
                .prefix(BackupLimits.maxListEntries).compactMap(\.value))
        // Each preference decodes on its own (`BackupPreferences`); a member
        // that is not an object restores none.
        let preferences = value("preferences", as: BackupPreferences.self) ?? BackupPreferences()

        let pingRange = members["pings"]
        return ImportPayload(
            formatVersion: formatVersion,
            trips: trips,
            malformedTrips: malformedTrips,
            malformedStays: malformedStays,
            unassignedStays: unassignedStays,
            homes: homes,
            homeStays: homeStays,
            homeAreaOverrides: homeAreaOverrides,
            routinePlaces: routinePlaces,
            visits: visits,
            malformedVisits: malformedVisits,
            temporaryHomes: temporaryHomes,
            removedTemporaryHomes: removedTemporaryHomes,
            hiddenPhotos: hiddenPhotos,
            pinnedPhotos: pinnedPhotos,
            favouriteTripIDs: favouriteTripIDs,
            rememberedCountryCodes: rememberedCountryCodes,
            yearWrapped: yearWrapped,
            plannedTrips: plannedTrips,
            photoImportStates: photoImportStates,
            hexVisits: hexVisits,
            removedTrips: removedTrips,
            preferences: preferences,
            pings: pingRange.map { BackupPingSection(data: data, range: $0) } ?? .empty,
            malformedRecords: malformedRecords)
    }
}
