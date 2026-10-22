//
//  TripShareExport.swift
//  TravelLog
//
//  Sender side. The snapshotter reads the chosen trips as they are stored;
//  `excludingHomeAreas` then removes everything that locates the sender's
//  homes before anything is written:
//  - only destination and transit stays travel; home, routine and
//    unclassified stays never do, and no Home, TemporaryHome, RoutinePlace or
//    HomeAreaOverride row is read into the file;
//  - every stay, fix and Visit inside any of the sender's home anchors (real
//    or temporary) at any instant of its own time is dropped, judged by
//    `TripClassifier.matchesHome` over the measured rings (seed, learned
//    orbit, taught corrections, prehistory), the rule that stamps `.home`;
//    a stay or Visit is read over its whole span, so one that only departs
//    inside a home's dates, or that a temporary home starts during, goes;
//  - a stay that lost a fix or a Visit is rebuilt from the ones it keeps, so
//    its centroid and times no longer carry them, then judged again over its
//    new span; one with nothing left goes;
//  - `distanceFromHomeKm` and the temporary-home stamp are never written,
//    the first stay's leg (whose origin is the sender's home) is cleared, and
//    so is any leg across removed evidence or through a protected place;
//  - a generated title the kept stays no longer ground (it names a place
//    only a dropped stay held) is composed again from the kept stays, or
//    left out; the sender's own name always travels;
//  - photos travel as nothing: no image, no PhotoKit identifier, no hidden or
//    pinned row. Favourites and other device-local state stay behind.
//  The spans it removed stay beside the file (`TripShareExclusions`), so the
//  GPX route and the card's route break there instead of drawing across.
//

import CoreLocation
import Foundation
import SwiftData

nonisolated enum TripShareExport {

    /// One export: the file, how many trips kept nothing, and where the
    /// route drawings must break.
    struct Export: Sendable {
        var file: TripShareFile
        var omitted: Int
        var exclusions: TripShareExclusions
    }

    /// One trip with its home-derived rows removed, and the spans of the
    /// evidence that went.
    struct Filtered: Sendable {
        var trip: SharedTrip
        var removed: [DateInterval]
    }

    /// The file for `trips`, each filtered against `rings`. Trips that keep
    /// nothing are left out; `omitted` counts them.
    static func export(
        trips: [SharedTrip], rings: [TripClassifier.HomeRing],
        senderName: String?, exportedAt: Date, appVersion: String?
    ) -> Export {
        var kept: [SharedTrip] = []
        var exclusions = TripShareExclusions(rings: rings)
        for trip in trips {
            guard let filtered = filtered(trip, rings: rings) else { continue }
            kept.append(filtered.trip)
            exclusions.removed[filtered.trip.shareID] = TripShareExclusions.merged(filtered.removed)
        }
        return Export(
            file: TripShareFile(
                exportedAt: exportedAt,
                senderName: TripTitleStore.normalized(senderName),
                appVersion: appVersion,
                trips: kept),
            omitted: trips.count - kept.count,
            exclusions: exclusions)
    }

    static func makeFile(
        trips: [SharedTrip], rings: [TripClassifier.HomeRing],
        senderName: String?, exportedAt: Date, appVersion: String?
    ) -> (file: TripShareFile, omitted: Int) {
        let export = export(trips: trips, rings: rings, senderName: senderName,
                            exportedAt: exportedAt, appVersion: appVersion)
        return (export.file, export.omitted)
    }

    static func isInsideHome(
        _ date: Date, latitude: Double, longitude: Double, rings: [TripClassifier.HomeRing]
    ) -> Bool {
        !rings.isEmpty && TripClassifier.matchesHome(
            stayStart: date, latitude: latitude, longitude: longitude, homes: rings)
    }

    /// `trip` with every home-derived row and field removed; nil when no
    /// destination or transit evidence outside the home areas remains.
    static func excludingHomeAreas(
        _ trip: SharedTrip, rings: [TripClassifier.HomeRing]
    ) -> SharedTrip? {
        filtered(trip, rings: rings)?.trip
    }

    static func filtered(
        _ trip: SharedTrip, rings: [TripClassifier.HomeRing]
    ) -> Filtered? {
        let pingsByID = Dictionary(trip.pings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let travel: Set<String> = [StayCategory.destination.rawValue, StayCategory.transit.rawValue]
        let ordered = trip.stays.sorted {
            ($0.orderInTrip ?? 0, $0.startTime, $0.id.uuidString)
                < ($1.orderInTrip ?? 0, $1.startTime, $1.id.uuidString)
        }
        func visitSpan(_ visit: SharedVisit) -> DateInterval {
            // A Visit with no departure may still be going on.
            span(visit.arrivalDate, visit.departureDate ?? .distantFuture)
        }

        var keptStays: [SharedStay] = []
        var keptPings: [UUID: SharedPing] = [:]
        var keptVisits: [SharedVisit] = []
        var removed: [DateInterval] = []
        var previousOriginalIndex: Int?
        for (index, original) in ordered.enumerated() {
            let originalSpan = span(original.startTime, original.endTime)
            guard travel.contains(original.categoryRaw),
                  !isInsideHome(during: originalSpan, latitude: original.latitude,
                                longitude: original.longitude, rings: rings) else {
                removed.append(originalSpan)
                continue
            }
            var stay = original
            let pings = original.pingIDs.compactMap { pingsByID[$0] }.filter {
                !isInsideHome($0.timestamp, latitude: $0.latitude, longitude: $0.longitude, rings: rings)
            }
            let ownVisits = trip.visits.filter { $0.stayID == original.id }
            let visits = ownVisits.filter {
                !isInsideHome(during: visitSpan($0), latitude: $0.latitude, longitude: $0.longitude, rings: rings)
            }
            if pings.count != original.pingIDs.count || visits.count != ownVisits.count {
                // Rebuilt from what is left, so nothing dropped shapes it.
                guard !pings.isEmpty || !visits.isEmpty else {
                    removed.append(originalSpan)
                    continue
                }
                var times = pings.map(\.timestamp)
                times += visits.map(\.arrivalDate)
                times += visits.compactMap(\.departureDate)
                stay.startTime = times.min()!
                stay.endTime = times.max()!
                stay.durationMinutes = max(0, Int(stay.endTime.timeIntervalSince(stay.startTime) / 60))
                let points = pings.isEmpty
                    ? visits.map { (lat: $0.latitude, lon: $0.longitude) }
                    : pings.map { (lat: $0.latitude, lon: $0.longitude) }
                var lat = 0.0
                var lon = 0.0
                for (offset, point) in points.enumerated() {
                    let n = Double(offset + 1)
                    lat += (point.lat - lat) / n
                    lon = offset == 0 ? GeoMath.normalizedLongitude(point.lon)
                        : GeoMath.runningMeanLongitude(current: lon, adding: point.lon, newCount: n)
                }
                stay.latitude = lat
                stay.longitude = lon
                stay.h3IndexRes6 = H3Service.cellIndex(latitude: lat, longitude: lon)
                // Weather was fetched for the old cell and days.
                stay.weatherData = nil
                stay.avgTemperatureC = nil
                stay.weatherConditionRaw = nil
                stay.precipitationMm = nil
                stay.dayKey = nil
                // The new centre and span are judged again.
                guard !isInsideHome(during: span(stay.startTime, stay.endTime), latitude: lat,
                                    longitude: lon, rings: rings) else {
                    removed.append(originalSpan)
                    continue
                }
                removed += ownVisits.filter { visit in !visits.contains { $0.id == visit.id } }.map {
                    span($0.arrivalDate, $0.departureDate ?? max($0.arrivalDate, original.endTime))
                }
            }
            stay.pingIDs = pings.map(\.id)
            stay.pingCount = pings.count
            // The leg into the first stay starts at the sender's home, and a
            // leg whose origin was dropped starts somewhere the file does not
            // show: only a leg between two shared stays keeps its mode, and
            // its distance is measured between them.
            if let previous = keptStays.last, previousOriginalIndex == index - 1 {
                stay.distanceFromPreviousKm = haversineKm(
                    previous.latitude, previous.longitude, stay.latitude, stay.longitude)
            } else {
                stay.transitFromPreviousRaw = nil
                stay.distanceFromPreviousKm = nil
            }
            stay.orderInTrip = keptStays.count
            keptStays.append(stay)
            previousOriginalIndex = index
            for ping in pings { keptPings[ping.id] = ping }
            keptVisits += visits
        }
        guard !keptStays.isEmpty else { return nil }
        removed += trip.pings.filter { keptPings[$0.id] == nil }.map { span($0.timestamp, $0.timestamp) }

        // A leg also goes when evidence was removed while it ran or its line
        // passes a protected place: it would carry time near a home.
        let merged = TripShareExclusions.merged(removed)
        for index in keptStays.indices.dropFirst() {
            let previous = keptStays[index - 1]
            let stay = keptStays[index]
            guard stay.transitFromPreviousRaw != nil || stay.distanceFromPreviousKm != nil else { continue }
            let leg = span(previous.endTime, stay.startTime)
            if TripShareExclusions.overlaps(merged, leg)
                || lineCrossesHome(from: (previous.latitude, previous.longitude),
                                   to: (stay.latitude, stay.longitude), during: leg, rings: rings) {
                keptStays[index].transitFromPreviousRaw = nil
                keptStays[index].distanceFromPreviousKm = nil
            }
        }

        var result = trip
        result.stays = keptStays
        result.pings = keptPings.values.sorted {
            ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString)
        }
        result.visits = keptVisits.sorted {
            ($0.arrivalDate, $0.id.uuidString) < ($1.arrivalDate, $1.id.uuidString)
        }
        result.startDate = keptStays.map(\.startTime).min()!
        if result.endDate != nil { result.endDate = keptStays.map(\.endTime).max()! }
        var seenCodes = Set<String>()
        result.countryCodes = result.destinations.compactMap(\.isoCountryCode)
            .filter { seenCodes.insert($0).inserted }
        result.destinationSummary = result.placeNames.joined(separator: ", ")
        if keptStays.count < trip.stays.count || result.canonicalTitle == nil {
            (result.canonicalTitle, result.localizedTitles) = groundedTitles(of: result)
        }
        return Filtered(trip: result, removed: removed)
    }

    /// The generated title and its renderings when the kept stays still
    /// ground every place it names, as title validation reads it; else a
    /// title composed from the kept stays, or none, and no renderings
    /// (they translate the title that went).
    static func groundedTitles(of trip: SharedTrip) -> (String?, [SharedLocalizedTitle]) {
        let stays = trip.stays.map {
            TripTitlePolicy.StayInput(
                id: $0.id, orderInTrip: $0.orderInTrip, startTime: $0.startTime, endTime: $0.endTime,
                durationMinutes: $0.durationMinutes, categoryRaw: $0.categoryRaw, isAirport: $0.isAirport,
                metroName: $0.metroName, islandName: $0.islandName, locality: $0.locality,
                administrativeArea: $0.administrativeArea, country: $0.country,
                isoCountryCode: $0.isoCountryCode)
        }
        if let title = trip.canonicalTitle,
           TripTitlePolicy.ungroundedTitleFailure(title, stays: stays, homePlaceNames: []) == nil {
            return (title, trip.localizedTitles)
        }
        guard trip.canonicalTitle != nil,
              case .accepted(let composed) = TripTitlePolicy.fallbackTitle(stays: stays, homePlaceNames: [])
        else { return (nil, []) }
        return (TripTitleStore.normalized(composed), [])
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0088
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = GeoMath.wrappedLongitudeDelta(lon2, lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// Reads the chosen trips off the main actor, as stored, for
/// `TripShareExport.excludingHomeAreas`. Physical UUID twins of one trip
/// leave as one entry holding every twin's stays once.
@ModelActor
actor TripShareSnapshotter {

    /// Fetch failures throw: a partial read must not become a file.
    func trips(ids: [UUID]) throws -> [SharedTrip] {
        visitCache = nil
        defer { visitCache = nil }
        let idSet = ids
        let rows = try modelContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { idSet.contains($0.id) }))
        var result: [SharedTrip] = []
        for id in ids {
            let twins = rows.filter { $0.id == id && !$0.isDeleted }
                .sorted { ($0.stays?.count ?? 0) > ($1.stays?.count ?? 0) }
            guard let base = twins.first else { continue }
            var seenStays = Set<UUID>()
            let stays = twins.flatMap(\.orderedStays).filter { !$0.isDeleted && seenStays.insert($0.id).inserted }
            let pingIDs = Array(Set(stays.flatMap(\.pingIDs)))
            var pings: [UUID: SharedPing] = [:]
            for chunk in stride(from: 0, to: pingIDs.count, by: 500) {
                let slice = Array(pingIDs[chunk..<min(chunk + 500, pingIDs.count)])
                for ping in try modelContext.fetch(FetchDescriptor<LocationPing>(
                    predicate: #Predicate { slice.contains($0.id) })) where pings[ping.id] == nil {
                    pings[ping.id] = SharedPing(
                        id: ping.id, timestamp: ping.timestamp,
                        latitude: ping.latitude, longitude: ping.longitude,
                        horizontalAccuracy: ping.horizontalAccuracy,
                        altitude: ping.altitude, verticalAccuracy: ping.verticalAccuracy,
                        sourceRaw: ping.sourceRaw)
                }
            }
            let stayIDs = Set(stays.map(\.id))
            var visits: [SharedVisit] = []
            var seenVisits = Set<UUID>()
            for visit in try linkedVisits()
            where visit.stayID.map(stayIDs.contains) == true && seenVisits.insert(visit.id).inserted {
                visits.append(SharedVisit(
                    id: visit.id, arrivalDate: visit.arrivalDate,
                    departureDate: visit.departureDate,
                    latitude: visit.latitude, longitude: visit.longitude,
                    horizontalAccuracy: visit.horizontalAccuracy, stayID: visit.stayID))
            }
            let named = twins.lazy.compactMap { TripTitleStore.normalized($0.customName) }.first
            result.append(SharedTrip(
                shareID: id,
                customName: named,
                canonicalTitle: TripTitleStore.normalized(base.aiGeneratedTitle),
                localizedTitles: Self.usableTitles(of: base),
                startDate: base.startDate,
                endDate: base.endDate,
                isComplete: base.isComplete,
                countryCodes: base.countryCodes.split(separator: ",").map(String.init),
                destinationSummary: base.destinationSummary,
                stays: stays.map(Self.snapshot),
                pings: Array(pings.values),
                visits: visits))
        }
        return result
    }

    private var visitCache: [Visit]?

    /// Every Visit linked to a stay, read once per snapshot.
    private func linkedVisits() throws -> [Visit] {
        if let visitCache { return visitCache }
        let rows = try modelContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.stayID != nil }))
        visitCache = rows
        return rows
    }

    /// One usable rendering per language of the current canonical title.
    private static func usableTitles(of trip: Trip) -> [SharedLocalizedTitle] {
        guard let canonical = TripTitleStore.normalized(trip.aiGeneratedTitle) else { return [] }
        var chosen: [String: TripTitleVariant] = [:]
        for variant in trip.localizedTitles ?? [] where !variant.isDeleted {
            guard let tag = AppLanguagePreference.normalizedSupportedTag(variant.languageTag),
                  tag != "en",
                  TripTitleStore.isUsableVariantTitle(variant.title, languageTag: tag),
                  TripTitleStore.normalized(variant.sourceTitle) == canonical,
                  variant.sourceRevision == trip.titleSourceRevision else { continue }
            if let incumbent = chosen[tag], !TripTitleStore.hasPreferredContent(variant, over: incumbent) {
                continue
            }
            chosen[tag] = variant
        }
        return chosen.keys.sorted().compactMap { tag in
            chosen[tag].flatMap { variant in
                TripTitleStore.normalized(variant.title).map {
                    SharedLocalizedTitle(languageTag: tag, title: $0)
                }
            }
        }
    }

    private static func snapshot(_ stay: Stay) -> SharedStay {
        SharedStay(
            id: stay.id, startTime: stay.startTime, endTime: stay.endTime,
            durationMinutes: stay.durationMinutes, categoryRaw: stay.categoryRaw,
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
            h3IndexRes6: stay.h3IndexRes6, pingCount: stay.pingCount, pingIDs: stay.pingIDs,
            orderInTrip: stay.orderInTrip,
            locality: stay.locality, subLocality: stay.subLocality,
            administrativeArea: stay.administrativeArea, country: stay.country,
            isoCountryCode: stay.isoCountryCode, metroName: stay.metroName,
            islandName: stay.islandName, isAirport: stay.isAirport, sourceRaw: stay.sourceRaw,
            userOverridden: stay.userOverridden, continuesPreviousTrip: stay.continuesPreviousTrip,
            transitFromPreviousRaw: stay.transitFromPreviousRaw,
            distanceFromPreviousKm: stay.distanceFromPreviousKm,
            stepsWalked: stay.stepsWalked, weatherData: stay.weatherData,
            avgTemperatureC: stay.avgTemperatureC, weatherConditionRaw: stay.weatherConditionRaw,
            precipitationMm: stay.precipitationMm, dayKey: stay.dayKey,
            timeZoneIdentifier: stay.timeZoneIdentifier)
    }
}
