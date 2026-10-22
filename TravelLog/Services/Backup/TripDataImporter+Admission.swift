//
//  TripDataImporter+Admission.swift
//  TravelLog
//
//  What a restored row must look like before the commit sees it. A backup
//  can be hand-edited, damaged or hostile, so every decoded field is held to
//  what the live app itself writes:
//
//    - A file that is clearly not a backup this app wrote (a document past
//      `maxDocumentBytes`, a gzip stream that expands past the ratio, record
//      sections past `maxRecordSectionBytes`) is refused whole, before any
//      write.
//    - An isolated row that breaks a rule (a date outside the importable
//      domain, a window that runs backwards or spans more than ten years,
//      coordinates off the globe, a non-finite core number, a field past its
//      size bound, an element past its section's byte bound) is dropped and
//      counted with the malformed entries the preview names.
//    - A measurement or count out of its range on an otherwise sound row
//      (temperature, precipitation, distance, steps, altitude, a negative or
//      huge count or order) is cleared or clamped to the value the app would
//      have written, so no later `Int(...)` conversion or `+ 1` can trap.
//    - Unknown enum raw values stay as stored: every reader of them falls
//      back (`DataSource.decode`, `StayCategory(rawValue:) ?? .unclassified`,
//      `ImportStatus ... ?? .idle`), and the commit already refuses unknown
//      override kinds and summary sources.
//    - Soft references (a Visit's stay, an override's Home, a plan's matched
//      trip, a stay's temporary home, kept trips) stay as stored: CloudKit
//      delivers rows in any order, so every reader resolves them by lookup
//      and tolerates absence. Photo choices and Favorites without a trip are
//      left out by the commit. The only relationships are nesting (a trip
//      holds its stays and titles), so no reference can form a cycle, and a
//      duplicate id keeps its first entry.
//

import Foundation

/// The bounds a backup and each of its rows must meet.
nonisolated enum BackupLimits {
    /// The decompressed document. Far above a long history (a ping costs
    /// about 300 bytes) and small enough to stage and map on a phone.
    static let maxDocumentBytes: Int64 = 2 << 30
    /// A gzip stream past this many output bytes per input byte is a
    /// decompression bomb: real backups compress about tenfold. Judged once
    /// the output passes `ratioFloorBytes`, so a small file may compress well.
    static let maxCompressionRatio: Int64 = 100
    static let ratioFloorBytes: Int64 = 64 << 20
    /// Every member but `pings` together: these are decoded into memory.
    static let maxRecordSectionBytes = 512 << 20

    /// One array element's JSON, per section. Past it the element is not
    /// decoded at all and counts as malformed.
    static let maxTripBytes = 64 << 20
    static let maxStayBytes = 8 << 20
    static let maxPingBytes = 16 << 10
    static let maxRecordBytes = 1 << 20
    static let maxLargeRecordBytes = 16 << 20

    /// Names, labels, place names, identifiers, raw values (UTF-8 bytes).
    static let maxShortText = 2_048
    /// Summaries, narratives, joined lists.
    static let maxLongText = 256 << 10
    /// A stay's comma-joined ping ids (37 bytes each).
    static let maxPingIDsText = 4 << 20
    static let maxWeatherBytes = 64 << 10
    static let maxForecastBytes = 256 << 10
    static let maxStatsBytes = 4 << 20
    static let maxListEntries = 100_000
    /// A temporary home's kept trips, stored joined on one synced row.
    static let maxKeptTrips = 10_000

    /// The longest window a stay may span. The app's own day loops stop at
    /// ten years (`TravelDays`, `StatsAggregator`).
    static let maxSpan: TimeInterval = 3_650 * 86_400
    static let maxCount = 10_000_000
    static let maxOrder = 1_000_000
    static let maxVersion = 1_000_000
    static let maxRevision = 1_000_000_000
    static let maxDistanceKm = 50_000.0

    static func isDate(_ date: Date) -> Bool {
        PingRecorder.isImportableTimestamp(date)
    }

    static func isDate(_ date: Date?) -> Bool {
        date.map(isDate) ?? true
    }

    static func isOnGlobe(_ latitude: Double, _ longitude: Double) -> Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180
    }

    static func fits(_ text: String?, _ limit: Int = maxShortText) -> Bool {
        (text?.utf8.count ?? 0) <= limit
    }

    static func fits(_ texts: [String]?, _ limit: Int = maxShortText) -> Bool {
        guard let texts else { return true }
        return texts.count <= maxListEntries && texts.allSatisfy { fits($0, limit) }
    }

    static func fits(_ data: Data?, _ limit: Int) -> Bool {
        (data?.count ?? 0) <= limit
    }

    static func clamped(
        _ value: Double, _ lower: Double, _ upper: Double, fallback: Double
    ) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }

    /// The value when finite and in range, else nil.
    static func measure(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func measure(_ value: Int?, _ range: ClosedRange<Int>) -> Int? {
        guard let value, range.contains(value) else { return nil }
        return value
    }

    static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// A date out of the importable domain reads as absent.
    static func date(_ date: Date?) -> Date? {
        date.flatMap { isDate($0) ? $0 : nil }
    }

    /// A restored cell string as the app writes one: a valid cell at the
    /// app's resolution, spelled as `H3Service.cellIndex` spells it.
    /// Anything else (a damaged or hand-edited string, another resolution)
    /// is derived again from the row's coordinates, as live recording
    /// derives it, so the widget's count and the app's maps and Stats read
    /// the same cells; nil when the coordinates index nothing either.
    static func cellIndex(_ stored: String, latitude: Double, longitude: Double) -> String? {
        H3Service.canonicalCellIndex(stored)
            ?? H3Service.cellIndex(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Trip graph

extension ExportStaySnapshot {
    /// The stay as the commit may insert it, or nil when its core is unusable.
    nonisolated var admitted: ExportStaySnapshot? {
        typealias L = BackupLimits
        guard L.isDate(startTime), L.isDate(endTime), endTime >= startTime,
              endTime.timeIntervalSince(startTime) <= L.maxSpan,
              L.isOnGlobe(centroidLatitude, centroidLongitude),
              L.fits(locality), L.fits(administrativeArea), L.fits(country),
              L.fits(isoCountryCode), L.fits(subLocality), L.fits(metroName),
              L.fits(islandName), L.fits(weatherConditionRaw), L.fits(transitFromPreviousRaw),
              L.fits(h3IndexRes6), L.fits(categoryRaw), L.fits(sourceRaw),
              L.fits(timeZoneIdentifier), L.fits(pingIDsString, L.maxPingIDsText),
              L.fits(weatherData, L.maxWeatherBytes) else { return nil }
        var stay = self
        // The app writes the window's whole minutes; anything else would
        // feed sums and labels a value no stay can have.
        let window = Int(endTime.timeIntervalSince(startTime) / 60)
        if !(0...(window + 1)).contains(durationMinutes) { stay.durationMinutes = window }
        stay.dayKey = L.date(dayKey)
        stay.avgTemperatureC = L.measure(avgTemperatureC, -100...100)
        stay.precipitationMm = L.measure(precipitationMm, 0...10_000)
        stay.distanceFromPreviousKm = L.measure(distanceFromPreviousKm, 0...L.maxDistanceKm)
        stay.stepsWalked = L.measure(stepsWalked, 0...L.maxCount)
        stay.pingCount = L.clamped(pingCount, 0...L.maxCount)
        // `greatestFiniteMagnitude` is the app's own "no home" distance.
        if distanceFromHomeKm.isNaN || distanceFromHomeKm < 0 || distanceFromHomeKm.isInfinite {
            stay.distanceFromHomeKm = .greatestFiniteMagnitude
        }
        stay.orderInTrip = L.measure(orderInTrip, 0...L.maxOrder)
        // A negative revision reads as none and a huge one never overflows the next.
        stay.temporaryHomeRevision = temporaryHomeRevision.map { L.clamped($0, 0...L.maxRevision) }
        return stay
    }
}

extension ExportTripSnapshot {
    /// The trip's own fields admitted; its stays are admitted by the parser,
    /// which counts the ones it drops. Nil when its dates are unusable.
    nonisolated var admitted: ExportTripSnapshot? {
        typealias L = BackupLimits
        guard L.isDate(startDate), L.isDate(endDate),
              endDate.map({ $0 >= startDate }) ?? true,
              L.fits(customName), L.fits(aiGeneratedTitle), L.fits(summarySourceRaw),
              L.fits(sourceRaw), L.fits(destinationSummary, L.maxLongText),
              L.fits(countryCodes, L.maxLongText), L.fits(aiGeneratedSummary, L.maxLongText)
        else { return nil }
        var trip = self
        trip.summaryGeneratedAt = L.date(summaryGeneratedAt)
        trip.summaryGenerationVersion = L.measure(summaryGenerationVersion, 0...L.maxVersion)
        // A derivative carries no authority of its own, so a bad one is
        // dropped quietly, as one that does not decode is.
        trip.localizedTitles = localizedTitles.filter {
            L.isDate($0.updatedAt) && L.fits($0.languageTag) && L.fits($0.title)
                && L.fits($0.sourceTitle) && (0...L.maxVersion).contains($0.generationVersion)
        }
        return trip
    }
}

// MARK: - Home layer

extension ExportHomeSnapshot {
    nonisolated var admitted: ExportHomeSnapshot? {
        typealias L = BackupLimits
        // A reversed era is rejected like a reversed stay window:
        // `DateInterval` on a reversed range is a fatalError, and a
        // poisoned Home row would crash every pipeline pass.
        guard L.isOnGlobe(latitude, longitude), L.isDate(startedAt), L.isDate(endedAt),
              endedAt.map({ $0 >= startedAt }) ?? true,
              L.fits(label), L.fits(locality), L.fits(administrativeArea),
              L.fits(country), L.fits(isoCountryCode) else { return nil }
        var home = self
        // An absurd radius (hand-edited file) must not make the planet
        // home and dissolve every trip on the next heal.
        home.radiusKm = BackupLimits.clamped(radiusKm, 0.1, 500, fallback: 25)
        return home
    }
}

extension ExportTemporaryHomeSnapshot {
    nonisolated var admitted: ExportTemporaryHomeSnapshot? {
        typealias L = BackupLimits
        guard L.isOnGlobe(latitude, longitude), L.isDate(startedAt), L.isDate(endedAt),
              endedAt.map({ $0 >= startedAt }) ?? true,
              L.isDate(createdAt), L.isDate(modifiedAt), L.isDate(removedAt),
              keptTripIDs.count <= L.maxKeptTrips,
              L.fits(label), L.fits(locality), L.fits(administrativeArea),
              L.fits(country), L.fits(isoCountryCode), L.fits(timeZoneIdentifier) else { return nil }
        var home = self
        home.radiusKm = BackupLimits.clamped(radiusKm, 0.1, 500, fallback: 25)
        home.coverageRevision = L.clamped(coverageRevision, 0...L.maxRevision)
        return home
    }
}

extension ExportRoutinePlaceSnapshot {
    nonisolated var admitted: ExportRoutinePlaceSnapshot? {
        typealias L = BackupLimits
        guard L.isOnGlobe(latitude, longitude), L.isDate(startedAt), L.isDate(endedAt),
              endedAt.map({ $0 >= startedAt }) ?? true, L.fits(label) else { return nil }
        var place = self
        place.radiusMeters = BackupLimits.clamped(radiusMeters, 10, 20_000, fallback: 500)
        return place
    }
}

extension ExportOverrideSnapshot {
    nonisolated var admitted: ExportOverrideSnapshot? {
        typealias L = BackupLimits
        // Unknown kinds are counted, not silently dropped: the import
        // alert must not report "0 malformed" over a vanished correction.
        guard HomeAreaOverride.Kind(rawValue: kindRaw) != nil,
              L.isOnGlobe(centerLatitude, centerLongitude), L.isDate(createdAt),
              L.fits(sourceTripName) else { return nil }
        var row = self
        // An unbounded include disc is a planet-sized home teaching.
        row.radiusKm = BackupLimits.clamped(radiusKm, 0.05, 25, fallback: 1)
        return row
    }
}

extension ExportVisitSnapshot {
    nonisolated var admitted: ExportVisitSnapshot? {
        typealias L = BackupLimits
        guard L.isOnGlobe(latitude, longitude), L.isDate(arrivalDate),
              L.isDate(departureDate), L.isDate(receivedAt),
              horizontalAccuracy.isFinite, horizontalAccuracy >= 0, horizontalAccuracy < 5000,
              departureDate.map({ $0 > arrivalDate }) ?? true else { return nil }
        return self
    }
}

extension ExportPhotoChoiceSnapshot {
    /// A photo choice needs a date and an identifier to match a photo by.
    nonisolated var admitted: ExportPhotoChoiceSnapshot? {
        typealias L = BackupLimits
        guard L.isDate(chosenAt), L.fits(localIdentifier), L.fits(cloudIdentifier) else { return nil }
        var choice = self
        if choice.cloudIdentifier?.isEmpty == true { choice.cloudIdentifier = nil }
        return choice.localIdentifier.isEmpty && choice.cloudIdentifier == nil ? nil : choice
    }
}

// MARK: - Records

extension ExportYearWrappedSnapshot {
    nonisolated var admitted: ExportYearWrappedSnapshot? {
        typealias L = BackupLimits
        guard (1...9_999).contains(year), L.isDate(generatedAt),
              L.fits(statsData, L.maxStatsBytes), L.fits(yearNarrative, L.maxLongText),
              L.fits(yearNarrativeSourceRaw) else { return nil }
        var record = self
        record.viewedAt = L.date(viewedAt)
        record.weatherCoverage = L.measure(weatherCoverage, 0...1) ?? 0
        record.transitCoverage = L.measure(transitCoverage, 0...1) ?? 0
        return record
    }
}

extension ExportPlannedTripSnapshot {
    nonisolated var admitted: ExportPlannedTripSnapshot? {
        typealias L = BackupLimits
        guard L.isDate(startDate), L.isDate(endDate), endDate >= startDate,
              endDate.timeIntervalSince(startDate) <= L.maxSpan,
              L.isDate(createdAt), L.isDate(lastSeenAt),
              L.fits(eventExternalIdentifier), L.fits(eventLocalIdentifier), L.fits(title),
              L.fits(locationText, L.maxLongText), L.fits(resolvedLocality),
              L.fits(resolvedCountry), L.fits(resolvedISOCountryCode), L.fits(confidenceRaw),
              L.fits(signalsRaw, L.maxLongText), L.fits(statusRaw),
              L.fits(forecastWeatherData, L.maxForecastBytes) else { return nil }
        var record = self
        // A resolved place is a coordinate pair on the globe, or none.
        let resolvesOnGlobe = resolvedLatitude.flatMap { latitude in
            resolvedLongitude.map { L.isOnGlobe(latitude, $0) }
        } ?? false
        if !resolvesOnGlobe {
            record.resolvedLatitude = nil
            record.resolvedLongitude = nil
        }
        record.distanceFromHomeKm = L.measure(distanceFromHomeKm, 0...L.maxDistanceKm)
        return record
    }
}

extension ExportPhotoImportStateSnapshot {
    nonisolated var admitted: ExportPhotoImportStateSnapshot? {
        typealias L = BackupLimits
        guard L.isDate(startedAt), L.isDate(lastUpdated), L.fits(statusRaw),
              L.fits(watermarkLocalIdentifier), L.fits(lastError, L.maxLongText),
              L.fits(originDeviceID) else { return nil }
        var record = self
        record.completedAt = L.date(completedAt)
        record.watermarkCreationDate = L.date(watermarkCreationDate)
        record.totalAssetCount = L.clamped(totalAssetCount, 0...L.maxCount)
        record.processedAssetCount = L.clamped(processedAssetCount, 0...L.maxCount)
        record.acceptedPingCount = L.clamped(acceptedPingCount, 0...L.maxCount)
        return record
    }
}

extension ExportHexVisitSnapshot {
    nonisolated var admitted: ExportHexVisitSnapshot? {
        typealias L = BackupLimits
        guard !h3Index.isEmpty, L.fits(h3Index, 32), visitCount >= 1,
              L.isDate(firstVisited), L.isDate(lastVisited),
              L.isOnGlobe(centerLatitude, centerLongitude),
              L.fits(locality), L.fits(country), L.fits(isoCountryCode),
              let index = L.cellIndex(h3Index, latitude: centerLatitude, longitude: centerLongitude)
        else { return nil }
        var cell = self
        cell.h3Index = index
        cell.visitCount = min(visitCount, L.maxCount)
        return cell
    }
}

extension ExportPingSnapshot {
    /// A real fix: an importable time, coordinates on the globe and a finite
    /// accuracy. A non-finite or absurd altitude reading is cleared.
    nonisolated var admitted: ExportPingSnapshot? {
        typealias L = BackupLimits
        guard L.isDate(timestamp), L.isOnGlobe(latitude, longitude),
              horizontalAccuracy.isFinite, L.fits(h3IndexRes6, 32),
              L.fits(locality), L.fits(subLocality), L.fits(administrativeArea),
              L.fits(country), L.fits(isoCountryCode), L.fits(sourceRaw),
              let index = L.cellIndex(h3IndexRes6, latitude: latitude, longitude: longitude)
        else { return nil }
        var ping = self
        ping.h3IndexRes6 = index
        ping.altitude = L.measure(altitude, -1_000_000...1_000_000)
        ping.verticalAccuracy = L.measure(verticalAccuracy, -1_000_000...1_000_000)
        return ping
    }
}

extension DissolvedTripRecord {
    /// An archive Keep as One Trip can put back: its dates usable, its order
    /// and revisions in range, its text within bounds. Its fields are
    /// constants, so a record that breaks one is dropped, not repaired.
    nonisolated var isAdmissible: Bool {
        typealias L = BackupLimits
        let staysAdmissible = stays.count <= L.maxListEntries && stays.allSatisfy {
            L.fits($0.categoryRaw) && L.fits($0.postSplitCategoryRaw)
                && ($0.orderInTrip.map { (0...L.maxOrder).contains($0) } ?? true)
                && ($0.temporaryHomeRevision.map { (0...L.maxRevision).contains($0) } ?? true)
        }
        let holdersAdmissible = (postSplitHolders ?? []).allSatisfy {
            $0.stayIDs.count <= L.maxListEntries && L.fits($0.customName)
                && ($0.inheritedHiddenPhotoIDs?.count ?? 0) <= L.maxListEntries
        }
        let titlesAdmissible = (localizedTitles ?? []).allSatisfy {
            L.isDate($0.updatedAt) && L.fits($0.languageTag) && L.fits($0.title)
                && L.fits($0.sourceTitle) && (0...L.maxVersion).contains($0.generationVersion)
        }
        let photosAdmissible = (photoAnnotations ?? []).count <= L.maxListEntries
            && (photoAnnotations ?? []).allSatisfy {
                L.isDate($0.date) && L.fits($0.localIdentifier) && L.fits($0.cloudIdentifier)
            }
        return L.isDate(dissolvedAt) && L.isDate(startDate) && L.isDate(endDate)
            && (endDate.map { $0 >= startDate } ?? true)
            && L.fits(displayName) && L.fits(customName) && L.fits(otherCustomNames)
            && L.fits(destinationSummary, L.maxLongText) && L.fits(countryCodes, L.maxLongText)
            && L.fits(aiGeneratedTitle) && L.fits(aiGeneratedSummary, L.maxLongText)
            && L.fits(summarySourceRaw) && L.fits(sourceRaw)
            && L.fits(derivedSemanticDigest) && L.fits(activeHomeTitleFingerprint)
            && staysAdmissible && holdersAdmissible && titlesAdmissible && photosAdmissible
    }
}
