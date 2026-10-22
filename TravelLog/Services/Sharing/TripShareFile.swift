//
//  TripShareFile.swift
//  TravelLog
//
//  The shared-trip document: one JSON file that carries one or more trips
//  from one Travel Log user to another as a one-time copy of their evidence.
//  It is its own format (`shareFormatVersion`), separate from the backup:
//  a backup restores one person's whole history, this file hands another
//  person the fixes behind a few trips, with every home-derived row and field
//  left out (`TripShareExport.excludingHomeAreas`).
//
//  Dates are seconds since 2001-01-01 UTC (Foundation's reference date), so
//  every instant survives the round trip bit for bit. Unknown keys are
//  ignored and missing collections read as empty, so a later version 1 file
//  with more fields still opens.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Exported in Info.plist (`UTExportedTypeDeclarations`), opened through
    /// `CFBundleDocumentTypes`: AirDrop, Messages, Mail and Files hand it to
    /// Travel Log. It conforms to data and content but not JSON, so Files
    /// opens it in Travel Log instead of previewing it as text; the bytes
    /// are JSON all the same.
    nonisolated static let travelLogTrip = UTType(exportedAs: "com.kfragkoulis.travellog.trip", conformingTo: .data)
}

nonisolated struct TripShareFile: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "travellogtrip"
    /// A file larger than this is refused before it is decoded.
    static let maximumFileBytes = 64 * 1024 * 1024

    var shareFormatVersion: Int = TripShareFile.currentVersion
    var exportedAt: Date
    /// The name the sender chose to show, if any.
    var senderName: String?
    var appVersion: String?
    var trips: [SharedTrip]

    enum DecodeError: Error, Equatable {
        case tooLarge
        case unreadable
        case unsupportedVersion(Int)
        case empty
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Decodes and sanitizes an untrusted file: rows with impossible
    /// coordinates or instants are dropped, and a trip left with no stay and
    /// no fix is dropped.
    static func decode(_ data: Data) throws(DecodeError) -> TripShareFile {
        guard data.count <= maximumFileBytes else { throw .tooLarge }
        struct Header: Decodable { let shareFormatVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.dataDecodingStrategy = .base64
        guard let header = try? decoder.decode(Header.self, from: data) else { throw .unreadable }
        guard header.shareFormatVersion == currentVersion else {
            throw .unsupportedVersion(header.shareFormatVersion)
        }
        guard var file = try? decoder.decode(TripShareFile.self, from: data) else { throw .unreadable }
        file.senderName = TripTitleStore.normalized(file.senderName)
        file.trips = file.trips.compactMap { $0.sanitized() }
        // One entry per share id: the first wins, as an export writes them.
        var seen = Set<UUID>()
        file.trips = file.trips.filter { seen.insert($0.shareID).inserted }
        guard !file.trips.isEmpty else { throw .empty }
        return file
    }
}

nonisolated struct SharedTrip: Codable, Sendable, Equatable, Identifiable {
    /// The sender's trip UUID: re-sharing the same trip updates the
    /// recipient's import of it instead of adding another.
    var shareID: UUID
    var customName: String?
    var canonicalTitle: String?
    var localizedTitles: [SharedLocalizedTitle] = []
    var startDate: Date
    var endDate: Date?
    var isComplete: Bool
    /// Destination countries in visit order.
    var countryCodes: [String] = []
    var destinationSummary: String = ""
    var stays: [SharedStay] = []
    var pings: [SharedPing] = []
    var visits: [SharedVisit] = []

    var id: UUID { shareID }

    init(shareID: UUID, customName: String? = nil, canonicalTitle: String? = nil,
         localizedTitles: [SharedLocalizedTitle] = [], startDate: Date, endDate: Date?,
         isComplete: Bool, countryCodes: [String] = [], destinationSummary: String = "",
         stays: [SharedStay] = [], pings: [SharedPing] = [], visits: [SharedVisit] = []) {
        self.shareID = shareID
        self.customName = customName
        self.canonicalTitle = canonicalTitle
        self.localizedTitles = localizedTitles
        self.startDate = startDate
        self.endDate = endDate
        self.isComplete = isComplete
        self.countryCodes = countryCodes
        self.destinationSummary = destinationSummary
        self.stays = stays
        self.pings = pings
        self.visits = visits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareID = try c.decode(UUID.self, forKey: .shareID)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        canonicalTitle = try c.decodeIfPresent(String.self, forKey: .canonicalTitle)
        localizedTitles = try c.decodeIfPresent([SharedLocalizedTitle].self, forKey: .localizedTitles) ?? []
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? (endDate != nil)
        countryCodes = try c.decodeIfPresent([String].self, forKey: .countryCodes) ?? []
        destinationSummary = try c.decodeIfPresent(String.self, forKey: .destinationSummary) ?? ""
        stays = try c.decodeIfPresent([SharedStay].self, forKey: .stays) ?? []
        pings = try c.decodeIfPresent([SharedPing].self, forKey: .pings) ?? []
        visits = try c.decodeIfPresent([SharedVisit].self, forKey: .visits) ?? []
    }

    /// The name to show for this trip in `languageTag`: the sender's own
    /// name, a usable title in that language, the canonical title, the
    /// places, then nil.
    func displayTitle(languageTag: String = AppLanguagePreference.currentTag()) -> String? {
        if let name = TripTitleStore.normalized(customName) { return name }
        let tag = AppLanguagePreference.normalizedSupportedTag(languageTag) ?? "en"
        if tag != "en", let localized = localizedTitles.first(where: {
            AppLanguagePreference.normalizedSupportedTag($0.languageTag) == tag
        }), let title = TripTitleStore.normalized(localized.title) {
            return title
        }
        if let title = TripTitleStore.normalized(canonicalTitle) { return title }
        return TripTitleStore.normalized(destinationSummary)
    }

    /// Destination stays in time order.
    var destinations: [SharedStay] {
        stays.filter { $0.categoryRaw == StayCategory.destination.rawValue }
            .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
    }

    /// Distinct destination place names in visit order.
    var placeNames: [String] {
        var seen = Set<String>()
        return destinations.compactMap(\.placeName).filter { seen.insert($0).inserted }
    }

    /// Every fix in time order, then by id.
    var orderedPings: [SharedPing] {
        pings.sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
    }

    /// Drops impossible rows; nil when nothing remains to show or import.
    func sanitized() -> SharedTrip? {
        var trip = self
        trip.customName = TripTitleStore.normalized(customName)
        trip.canonicalTitle = TripTitleStore.normalized(canonicalTitle)
        trip.pings = pings.filter(\.isPlausible)
        trip.visits = visits.filter(\.isPlausible)
        trip.stays = stays.filter(\.isPlausible)
        trip.countryCodes = countryCodes.filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        guard SharedPing.isPlausible(startDate), endDate.map(SharedPing.isPlausible) ?? true,
              !trip.stays.isEmpty || !trip.pings.isEmpty else { return nil }
        return trip
    }
}

nonisolated struct SharedLocalizedTitle: Codable, Sendable, Equatable {
    var languageTag: String
    var title: String
}

/// A destination or transit stay as the sender's pipeline built it. Read by
/// the preview; the recipient's pipeline builds its own stays from the fixes.
/// Home-derived fields (`distanceFromHomeKm`, the temporary-home stamp) are
/// never written.
nonisolated struct SharedStay: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var durationMinutes: Int
    var categoryRaw: String
    var latitude: Double
    var longitude: Double
    var h3IndexRes6: String?
    var pingCount: Int
    var pingIDs: [UUID]
    var orderInTrip: Int?
    var locality: String?
    var subLocality: String?
    var administrativeArea: String?
    var country: String?
    var isoCountryCode: String?
    var metroName: String?
    var islandName: String?
    var isAirport: Bool
    var sourceRaw: String
    var userOverridden: Bool
    var continuesPreviousTrip: Bool
    /// Leg from the previous stay this file carries; nil on the first one,
    /// whose previous stay is the sender's home, and on one that ran across
    /// removed evidence or through a home.
    var transitFromPreviousRaw: String?
    var distanceFromPreviousKm: Double?
    var stepsWalked: Int?
    var weatherData: Data?
    var avgTemperatureC: Double?
    var weatherConditionRaw: String?
    var precipitationMm: Double?
    var dayKey: Date?
    var timeZoneIdentifier: String?

    /// Metro, else island, else locality, as `Stay.placeGroupName`.
    var placeName: String? {
        TripTitleStore.normalized(metroName) ?? TripTitleStore.normalized(islandName)
            ?? TripTitleStore.normalized(locality)
    }

    var isPlausible: Bool {
        SharedPing.isPlausible(latitude: latitude, longitude: longitude)
            && SharedPing.isPlausible(startTime) && SharedPing.isPlausible(endTime)
            && endTime >= startTime
            && (categoryRaw == StayCategory.destination.rawValue
                || categoryRaw == StayCategory.transit.rawValue)
    }
}

/// One raw fix. `sourceRaw` is the sender's provenance (a live fix, a photo
/// location, an import); the recipient stores every fix as `.sharedImport`.
nonisolated struct SharedPing: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double?
    var verticalAccuracy: Double?
    var sourceRaw: String

    var isPlausible: Bool {
        Self.isPlausible(latitude: latitude, longitude: longitude) && Self.isPlausible(timestamp)
            && horizontalAccuracy.isFinite
            && (altitude?.isFinite ?? true) && (verticalAccuracy?.isFinite ?? true)
    }

    static func isPlausible(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func isPlausible(_ date: Date) -> Bool {
        PingRecorder.isImportableTimestamp(date)
    }
}

/// A Core Location visit inside one of the shared stays.
nonisolated struct SharedVisit: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var stayID: UUID?

    var isPlausible: Bool {
        SharedPing.isPlausible(latitude: latitude, longitude: longitude)
            && SharedPing.isPlausible(arrivalDate)
            && (departureDate.map { SharedPing.isPlausible($0) && $0 >= arrivalDate } ?? true)
            && horizontalAccuracy.isFinite
    }
}
