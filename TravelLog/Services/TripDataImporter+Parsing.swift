//
//  TripDataImporter+Parsing.swift
//  TravelLog
//

import Foundation
import SwiftData
import os.log

extension TripDataImporter {

    // MARK: Parsing (pure, nonisolated)

    /// The highest coverage or stamp revision a file can carry: far above any
    /// count of real edits, and low enough that the next revision never overflows.
    private nonisolated static let maxRevision = 1_000_000_000

    /// Tolerant parser for export JSON of any version. Entries missing their
    /// required core (id, dates, coordinates) are counted and dropped
    /// rather than failing the whole file.
    nonisolated static func parse(_ data: Data) throws -> ImportPayload {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TripDataImportError.notJSON
        }
        guard let tripsArray = root["trips"] as? [[String: Any]] else {
            throw TripDataImportError.missingTripsArray
        }

        let formatVersion = root["formatVersion"] as? Int ?? 1
        let iso = ISO8601DateFormatter()
        // Second formatter for fractional-second timestamps:
        // `ISO8601DateFormatter` defaults to `.withInternetDateTime` ONLY, so
        // it returns nil for a perfectly valid `2024-06-15T10:23:45.000Z`.
        // `startTime`/`endTime` are hard requirements of `parseStay`, so
        // without it every such stay would be silently dropped — a backup
        // written by any exporter that emits milliseconds (including other
        // tools users migrate from) would restore as an empty or partial trip
        // with no error shown.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func date(_ dict: [String: Any], _ key: String) -> Date? {
            guard let raw = dict[key] as? String else { return nil }
            return iso.date(from: raw) ?? isoFractional.date(from: raw)
        }
        func double(_ dict: [String: Any], _ key: String) -> Double? {
            // JSONSerialization may surface integral JSON numbers as Int.
            (dict[key] as? Double) ?? (dict[key] as? Int).map(Double.init)
        }
        // Visit identity is keyed on exact arrival bits, which whole-second
        // ISO strings lose. Prefer the optional exact bit pattern the
        // exporter writes beside them, but only when it is well formed,
        // finite and within one second of the ISO value, so a hand-edited
        // ISO date is never silently overridden by stale bits.
        func exactDate(
            _ dict: [String: Any], bitsKey: String, refining isoDate: Date
        ) -> Date {
            guard let raw = dict[bitsKey] as? String,
                  raw.count == 16,
                  raw.allSatisfy(\.isHexDigit),
                  let bits = UInt64(raw, radix: 16) else {
                return isoDate
            }
            let seconds = Double(bitPattern: bits)
            guard seconds.isFinite else { return isoDate }
            let exact = Date(timeIntervalSinceReferenceDate: seconds)
            return abs(exact.timeIntervalSince(isoDate)) < 1 ? exact : isoDate
        }

        var trips: [ImportedTrip] = []
        var malformedTrips = 0
        var malformedStays = 0
        var malformedVisits = 0

        // Shared by the per-trip arrays and the v5 top-level
        // `unassignedStays` array — one tolerance rule, no shape drift.
        func parseStay(_ stayDict: [String: Any]) -> ImportedStay? {
            guard let stayIDString = stayDict["id"] as? String,
                  let stayID = UUID(uuidString: stayIDString),
                  let startTime = date(stayDict, "startTime"),
                  let endTime = date(stayDict, "endTime"),
                  let latitude = double(stayDict, "latitude"),
                  let longitude = double(stayDict, "longitude"),
                  endTime >= startTime,
                  abs(latitude) <= 90, abs(longitude) <= 180 else {
                return nil
            }
            return ImportedStay(
                id: stayID,
                startTime: startTime,
                endTime: endTime,
                latitude: latitude,
                longitude: longitude,
                categoryRaw: stayDict["category"] as? String,
                pingCount: stayDict["pingCount"] as? Int,
                distanceFromHomeKm: double(stayDict, "distanceFromHomeKm"),
                locality: stayDict["locality"] as? String,
                country: stayDict["country"] as? String,
                isoCountryCode: stayDict["isoCountryCode"] as? String,
                userOverridden: stayDict["userOverridden"] as? Bool,
                isAirport: stayDict["isAirport"] as? Bool,
                sourceRaw: stayDict["sourceRaw"] as? String,
                h3IndexRes6: stayDict["h3IndexRes6"] as? String,
                administrativeArea: stayDict["administrativeArea"] as? String,
                subLocality: stayDict["subLocality"] as? String,
                metroName: stayDict["metroName"] as? String,
                islandName: stayDict["islandName"] as? String,
                transitFromPreviousRaw: stayDict["transitFromPreviousRaw"] as? String,
                distanceFromPreviousKm: double(stayDict, "distanceFromPreviousKm"),
                stepsWalked: stayDict["stepsWalked"] as? Int,
                weatherConditionRaw: stayDict["weatherConditionRaw"] as? String,
                avgTemperatureC: double(stayDict, "avgTemperatureC"),
                precipitationMm: double(stayDict, "precipitationMm"),
                weatherData: (stayDict["weatherData"] as? String).flatMap { Data(base64Encoded: $0) },
                dayKey: date(stayDict, "dayKey"),
                timeZoneIdentifier: stayDict["timeZoneIdentifier"] as? String,
                temporaryHomeID: formatVersion >= 12
                    ? (stayDict["temporaryHomeID"] as? String).flatMap(UUID.init(uuidString:))
                    : nil,
                temporaryHomeRevision: formatVersion >= 13
                    ? (stayDict["temporaryHomeRevision"] as? Int).map { min(max(0, $0), maxRevision) }
                    : nil
            )
        }

        func parseLocalizedTitle(
            _ titleDict: [String: Any]
        ) -> ImportedLocalizedTitle? {
            guard let idString = titleDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let languageTag = titleDict["languageTag"] as? String,
                  !languageTag.isEmpty,
                  let title = titleDict["title"] as? String,
                  !title.isEmpty,
                  let sourceTitle = titleDict["sourceTitle"] as? String,
                  !sourceTitle.isEmpty,
                  let updatedAt = date(titleDict, "updatedAt") else {
                return nil
            }
            return ImportedLocalizedTitle(
                id: id,
                languageTag: languageTag,
                title: title,
                sourceTitle: sourceTitle,
                generationVersion: titleDict["generationVersion"] as? Int ?? 1,
                updatedAt: updatedAt,
                sourceRevision: (titleDict["sourceRevision"] as? String)
                    .flatMap(UUID.init(uuidString:)))
        }

        for tripDict in tripsArray {
            guard let idString = tripDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let startDate = date(tripDict, "startDate") else {
                malformedTrips += 1
                continue
            }

            let declaredStays = (tripDict["stays"] as? [Any]) ?? []
            var stays: [ImportedStay] = []
            for member in declaredStays {
                if let stayDict = member as? [String: Any], let stay = parseStay(stayDict) {
                    stays.append(stay)
                } else {
                    malformedStays += 1
                }
            }

            let localizedTitles = ((tripDict["localizedTitles"] as? [[String: Any]]) ?? [])
                .compactMap(parseLocalizedTitle)
            let endDate = date(tripDict, "endDate")

            trips.append(ImportedTrip(
                id: id,
                startDate: startDate,
                endDate: endDate,
                isComplete: tripDict["isComplete"] as? Bool ?? (endDate != nil),
                classifiedByAI: tripDict["classifiedByAI"] as? Bool ?? false,
                stays: stays,
                declaredStayCount: declaredStays.count,
                customName: tripDict["customName"] as? String,
                aiGeneratedTitle: tripDict["aiGeneratedTitle"] as? String,
                aiGeneratedSummary: tripDict["aiGeneratedSummary"] as? String,
                summarySourceRaw: tripDict["summarySourceRaw"] as? String,
                userEdited: tripDict["userEdited"] as? Bool,
                sourceRaw: tripDict["sourceRaw"] as? String,
                localizedTitles: localizedTitles,
                titleSourceRevision: (tripDict["titleSourceRevision"] as? String)
                    .flatMap(UUID.init(uuidString:)),
                keptByTemporaryHome: formatVersion >= 12
                    && tripDict["keptByTemporaryHome"] as? Bool == true
            ))
        }

        // v5: tripless travel stays round-trip via a top-level array; the
        // key is absent in pre-v5 files and simply empty here then.
        var unassignedStays: [ImportedStay] = []
        for member in (root["unassignedStays"] as? [Any]) ?? [] {
            if let stayDict = member as? [String: Any], let stay = parseStay(stayDict) {
                unassignedStays.append(stay)
            } else {
                malformedStays += 1
            }
        }

        // v6: the home-area layer. Same tolerance rule — an entry missing
        // its required core is counted and dropped, never fails the file.
        var homes: [ImportedHome] = []
        for homeDict in (root["homes"] as? [[String: Any]]) ?? [] {
            let endedAt = date(homeDict, "endedAt")
            guard let idString = homeDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let latitude = double(homeDict, "latitude"),
                  let longitude = double(homeDict, "longitude"),
                  let startedAt = date(homeDict, "startedAt"),
                  abs(latitude) <= 90, abs(longitude) <= 180,
                  // A reversed era is rejected like a reversed stay window
                  // (parseStay's rule): downstream era math must never see
                  // one — `DateInterval` on a reversed range is a
                  // fatalError, and a poisoned Home row would crash every
                  // pipeline pass with no in-app recovery.
                  endedAt.map({ $0 >= startedAt }) ?? true else {
                malformedTrips += 1
                continue
            }
            homes.append(ImportedHome(
                id: id,
                label: homeDict["label"] as? String ?? "",
                latitude: latitude,
                longitude: longitude,
                // Clamped like coordinates are range-checked: an absurd
                // radius (hand-edited file) must not make the planet home
                // and dissolve every trip on the next heal.
                radiusKm: min(max(double(homeDict, "radiusKm") ?? 25, 0.1), 500),
                locality: homeDict["locality"] as? String,
                administrativeArea: homeDict["administrativeArea"] as? String,
                country: homeDict["country"] as? String,
                isoCountryCode: homeDict["isoCountryCode"] as? String,
                startedAt: startedAt,
                endedAt: endedAt))
        }

        // v11: declared temporary homes, under the Home tolerance rule. The
        // key is read only from files that declare v11; no earlier format
        // carried it. An entry that is not an object is malformed on its own.
        func parseTemporaryHome(_ entry: Any) -> ImportedTemporaryHome? {
            guard let homeDict = entry as? [String: Any] else { return nil }
            let endedAt = date(homeDict, "endedAt")
            // The start and end are read as stay dates are, with no exact
            // bits, so a restored stay never lands outside the dates that
            // covered it.
            guard let idString = homeDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let latitude = double(homeDict, "latitude"),
                  let longitude = double(homeDict, "longitude"),
                  let startedAt = date(homeDict, "startedAt"),
                  abs(latitude) <= 90, abs(longitude) <= 180,
                  // A reversed era is rejected like a Home's.
                  endedAt.map({ $0 >= startedAt }) ?? true else {
                return nil
            }
            // Same-id twins are ranked on exact `createdAt` and `modifiedAt`,
            // so each ISO string is refined by its optional bits (the Visit
            // rule). A file without these gets the start date, not the import
            // time, so two devices importing it build identical rows.
            let createdAt = date(homeDict, "createdAt").map {
                exactDate(homeDict, bitsKey: "createdAtBits", refining: $0)
            } ?? startedAt
            let modifiedAt = date(homeDict, "modifiedAt").map {
                exactDate(homeDict, bitsKey: "modifiedAtBits", refining: $0)
            } ?? createdAt
            // v13: a revision is clamped to `0...maxRevision`, so a negative
            // one reads as none and a huge one never overflows the next; a
            // kept trip that is not a UUID string is dropped on its own.
            let coverageRevision = formatVersion >= 13
                ? min(max(0, homeDict["coverageRevision"] as? Int ?? 0), maxRevision) : 0
            let keptTripIDs = formatVersion >= 13
                ? Set(((homeDict["keptTripIDs"] as? [Any]) ?? []).compactMap {
                    ($0 as? String).flatMap(UUID.init(uuidString:))
                }) : []
            return ImportedTemporaryHome(
                id: id,
                label: homeDict["label"] as? String ?? "",
                latitude: latitude,
                longitude: longitude,
                radiusKm: min(max(double(homeDict, "radiusKm") ?? 25, 0.1), 500),
                locality: homeDict["locality"] as? String,
                administrativeArea: homeDict["administrativeArea"] as? String,
                country: homeDict["country"] as? String,
                isoCountryCode: homeDict["isoCountryCode"] as? String,
                startedAt: startedAt,
                endedAt: endedAt,
                timeZoneIdentifier: homeDict["timeZoneIdentifier"] as? String,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                coverageRevision: coverageRevision,
                keptTripIDs: keptTripIDs)
        }
        var temporaryHomes: [ImportedTemporaryHome] = []
        let temporaryHomeEntries = formatVersion >= 11
            ? (root["temporaryHomes"] as? [Any]) ?? [] : []
        for entry in temporaryHomeEntries {
            guard let home = parseTemporaryHome(entry) else {
                malformedTrips += 1
                continue
            }
            temporaryHomes.append(home)
        }
        // v12: removed temporary homes, the same entries plus a readable
        // `removedAt`. Read only from files that declare v12.
        var removedTemporaryHomes: [ImportedTemporaryHome] = []
        let removedTemporaryHomeEntries = formatVersion >= 12
            ? (root["removedTemporaryHomes"] as? [Any]) ?? [] : []
        for entry in removedTemporaryHomeEntries {
            guard var home = parseTemporaryHome(entry),
                  let homeDict = entry as? [String: Any],
                  let removedAt = date(homeDict, "removedAt") else {
                malformedTrips += 1
                continue
            }
            home.removedAt = removedAt
            removedTemporaryHomes.append(home)
        }

        var homeStays: [ImportedStay] = []
        for member in (root["homeStays"] as? [Any]) ?? [] {
            if let stayDict = member as? [String: Any], let stay = parseStay(stayDict) {
                homeStays.append(stay)
            } else {
                malformedStays += 1
            }
        }

        var homeAreaOverrides: [ImportedOverride] = []
        for overrideDict in (root["homeAreaOverrides"] as? [[String: Any]]) ?? [] {
            guard let idString = overrideDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let kindRaw = overrideDict["kindRaw"] as? String,
                  // Unknown kinds are counted, not silently dropped — the
                  // import alert must not report "0 malformed" over a
                  // vanished correction.
                  HomeAreaOverride.Kind(rawValue: kindRaw) != nil,
                  let latitude = double(overrideDict, "centerLatitude"),
                  let longitude = double(overrideDict, "centerLongitude"),
                  abs(latitude) <= 90, abs(longitude) <= 180 else {
                malformedTrips += 1
                continue
            }
            homeAreaOverrides.append(ImportedOverride(
                id: id,
                kindRaw: kindRaw,
                centerLatitude: latitude,
                centerLongitude: longitude,
                // Clamped: an unbounded include disc is a planet-sized home
                // teaching. Real discs are ≤ a few
                // km (p90 cluster radius, floor 1 km).
                radiusKm: min(max(double(overrideDict, "radiusKm") ?? 1, 0.05), 25),
                homeID: (overrideDict["homeID"] as? String).flatMap { UUID(uuidString: $0) },
                sourceTripName: overrideDict["sourceTripName"] as? String,
                createdAt: date(overrideDict, "createdAt") ?? .now))
        }

        var routinePlaces: [ImportedRoutinePlace] = []
        for placeDict in (root["routinePlaces"] as? [[String: Any]]) ?? [] {
            let endedAt = date(placeDict, "endedAt")
            guard let idString = placeDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let latitude = double(placeDict, "latitude"),
                  let longitude = double(placeDict, "longitude"),
                  let startedAt = date(placeDict, "startedAt"),
                  abs(latitude) <= 90, abs(longitude) <= 180,
                  endedAt.map({ $0 >= startedAt }) ?? true else {
                malformedTrips += 1
                continue
            }
            routinePlaces.append(ImportedRoutinePlace(
                id: id,
                label: placeDict["label"] as? String ?? "",
                latitude: latitude,
                longitude: longitude,
                radiusMeters: min(max(double(placeDict, "radiusMeters") ?? 500, 10), 20_000),
                isActive: placeDict["isActive"] as? Bool ?? true,
                startedAt: startedAt,
                endedAt: endedAt))
        }

        var visits: [ImportedVisit] = []
        for visitDict in (root["visits"] as? [[String: Any]]) ?? [] {
            guard let idString = visitDict["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let isoArrival = date(visitDict, "arrival"),
                  let latitude = double(visitDict, "lat"),
                  let longitude = double(visitDict, "lon"),
                  let horizontalAccuracy = double(visitDict, "accuracy"),
                  let receivedAt = date(visitDict, "receivedAt"),
                  latitude.isFinite, (-90...90).contains(latitude),
                  longitude.isFinite, (-180...180).contains(longitude),
                  horizontalAccuracy.isFinite,
                  horizontalAccuracy >= 0, horizontalAccuracy < 5000 else {
                malformedVisits += 1
                continue
            }
            let arrivalDate = exactDate(
                visitDict, bitsKey: "arrivalBits", refining: isoArrival)

            let stayID: UUID?
            if let rawStayID = visitDict["stayID"] {
                guard let stayIDString = rawStayID as? String,
                      let parsedStayID = UUID(uuidString: stayIDString) else {
                    malformedVisits += 1
                    continue
                }
                stayID = parsedStayID
            } else {
                stayID = nil
            }

            let departureDate: Date?
            if visitDict["departure"] != nil {
                // Order on the selected (exact when available) dates: a
                // sub-second visit's ISO strings can be equal.
                guard let isoDeparture = date(visitDict, "departure") else {
                    malformedVisits += 1
                    continue
                }
                let parsedDeparture = exactDate(
                    visitDict, bitsKey: "departureBits", refining: isoDeparture)
                guard parsedDeparture > arrivalDate else {
                    malformedVisits += 1
                    continue
                }
                departureDate = parsedDeparture
            } else {
                departureDate = nil
            }

            visits.append(ImportedVisit(
                id: id,
                stayID: stayID,
                arrivalDate: arrivalDate,
                departureDate: departureDate,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: horizontalAccuracy,
                receivedAt: receivedAt))
        }

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
            removedTemporaryHomes: removedTemporaryHomes
        )
    }
}
