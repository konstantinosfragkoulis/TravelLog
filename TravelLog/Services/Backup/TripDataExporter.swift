//
//  TripDataExporter.swift
//  TravelLog
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Backup format (v15)

/// Sendable value mirrors of the store for the off-main backup: `@Model`
/// objects must not cross the actor boundary (Swift 6).
///
/// **Format v15** is the only format this build writes or reads. Earlier
/// files (v1 to v14) restored a reconstruction (one or two synthetic pings per
/// stay, hex cells rebuilt from stays) and left whole models out; a restore
/// now refuses them (`TripDataImportError.olderFormat`).
///
/// Container: one JSON object, gzip-compressed, in a `.travellogbackup` file
/// (`UTType.travelLogBackup`; earlier builds named it `.json.gz`). gzip because the
/// ping history dominates the file and compresses about tenfold, and any tool
/// can open it; the importer also takes the same document uncompressed. It
/// is written member by member and read in place from a memory-mapped copy,
/// so neither side holds the ping history in memory at once
/// (`BackupFileFormat.swift`). A backup protected with a password wraps the
/// same gzip bytes in an AES-GCM envelope (`BackupEncryption.swift`).
///
/// Records: each model row is one JSON object whose keys are the model's
/// attribute names and whose values are the stored values: dates as their
/// exact `timeIntervalSinceReferenceDate`, Doubles in shortest round-trip
/// form (a non-finite one as a string), `Data` as base64, nil left out. A
/// relationship travels as nesting: a trip holds its `stays` and its
/// `localizedTitles`.
///
/// Top-level members: `formatVersion`, `appVersion`, `exportDate` (ISO, for
/// people), `trips`, `unassignedStays` and `homeStays` (every stay without a
/// trip, travel and home/routine), `homes`, `temporaryHomes`,
/// `removedTemporaryHomes`, `routinePlaces`, `homeAreaOverrides`, `visits`,
/// `hiddenPhotos`, `pinnedPhotos`, `yearWrapped`, `plannedTrips`,
/// `photoImportStates`, `hexVisits`, `favouriteTripIDs`,
/// `rememberedCountryCodes`, `removedTrips`, `preferences`, and last `pings`.
///
/// **In** (restored as stored):
///   - Every row of every model in the live schema with every attribute:
///     Trip, Stay, TripTitleVariant, LocationPing, HexVisit (with its
///     re-entry count), Visit, Home, TemporaryHome, RoutinePlace,
///     HomeAreaOverride, HiddenPhoto, PinnedPhoto, YearWrapped (every
///     generation), PlannedTrip, PhotoImportState. Row ids are kept, so
///     identity, ranking and the Removed Trips archives' references hold.
///   - iCloud key-value sets: Favorites and Earlier Travels.
///   - The device-local Removed Trips queue (`DissolvedTripQueue`): every
///     dissolved trip and temporary-home split archive whose Keep has not
///     committed.
///   - Preferences that change what the user sees (`BackupPreferences`):
///     trip sort and filters, the temperature unit, and the dismissed
///     temporary-home suggestions, end hints, flight candidates and split
///     hint.
///
/// **Out** (deliberately):
///   - Physical same-UUID twins: a Trip UUID leaves once (restore keeps the
///     first entry for an id) as the twin holding every stay of its twins,
///     or, when none does, as one trip of all their stays in time order,
///     with its own dates, countries and provenance and no destination
///     summary, which restore derives against the restored Homes; a
///     temporary home leaves as the row every reader resolves its id to,
///     with the kept trips of all its rows.
///   - Localized titles that are unusable or not their language's winner
///     for the canonical title (the title store's own admission).
///   - Derived on restore from restored inputs: `Stay.isAirport` is stamped
///     from the bundled airports, and stays with no offline place layers are
///     healed after the import (`pendingGeocodes()`).
///   - Device-local scheduling state that a drain regenerates: owed coverage
///     reconciliations (the restore queues its own), temporary-home
///     acknowledgements, deferral times, removal hints and last-unit
///     outcomes, the Home alias and ghost-carry logs, sweep first-sighting
///     ages, home-area healing fingerprints and coverage snapshot.
///   - Caches and latches: geocoder caches, the Stats snapshot, search
///     index, title-failure sets, Spotlight tokens, backfill and repair
///     latches, the photo-import checkpoint journal, import fences.
///   - Device settings and consent: iCloud sync, calendar selection,
///     notification toggles and travel state, acceptance floors, onboarding,
///     one-device tips.
///   - Photo-library local identifiers are carried as stored but mean
///     nothing on another device; cloud identifiers map them there.
nonisolated struct ExportStaySnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var durationMinutes: Int = 0
    var centroidLatitude: Double
    var centroidLongitude: Double
    var locality: String? = nil
    var administrativeArea: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var subLocality: String? = nil
    var metroName: String? = nil
    var islandName: String? = nil
    var weatherData: Data? = nil
    var avgTemperatureC: Double? = nil
    var weatherConditionRaw: String? = nil
    var precipitationMm: Double? = nil
    var dayKey: Date? = nil
    var transitFromPreviousRaw: String? = nil
    var distanceFromPreviousKm: Double? = nil
    var stepsWalked: Int? = nil
    var isAirport: Bool = false
    var h3IndexRes6: String = ""
    var pingCount: Int = 0
    var distanceFromHomeKm: Double = 0
    var categoryRaw: String = ""
    var userOverridden: Bool = false
    var temporaryHomeID: UUID? = nil
    var temporaryHomeRevision: Int? = nil
    var continuesPreviousTrip: Bool = false
    var orderInTrip: Int? = nil
    var pingIDsString: String = ""
    var sourceRaw: String = DataSource.liveSLC.rawValue
    var timeZoneIdentifier: String? = nil
}

/// A localized rendering of one canonical AI-generated title.
typealias ExportLocalizedTitleSnapshot = BackupLocalizedTitle

nonisolated struct ExportTripSnapshot: Codable, Sendable {
    var id: UUID
    var startDate: Date
    var endDate: Date? = nil
    var isComplete: Bool = false
    var customName: String? = nil
    var destinationSummary: String = ""
    var countryCodes: String = ""
    var aiGeneratedTitle: String? = nil
    var titleSourceRevision: UUID? = nil
    var aiGeneratedSummary: String? = nil
    var summaryGeneratedAt: Date? = nil
    var summaryGenerationVersion: Int? = nil
    var summarySourceRaw: String? = nil
    var classifiedByAI: Bool = false
    var userEdited: Bool = false
    var keptByTemporaryHome: Bool = false
    var sourceRaw: String = DataSource.liveSLC.rawValue
    var stays: [ExportStaySnapshot] = []
    var localizedTitles: [ExportLocalizedTitleSnapshot] = []
    /// Import only: the member entries the file declared, before damaged
    /// ones were dropped. Full-trip AI artifacts restore only when every
    /// declared member parsed and attached. Never written.
    var declaredStayCount: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case id, startDate, endDate, isComplete, customName, destinationSummary
        case countryCodes, aiGeneratedTitle, titleSourceRevision, aiGeneratedSummary
        case summaryGeneratedAt, summaryGenerationVersion, summarySourceRaw
        case classifiedByAI, userEdited, keptByTemporaryHome, sourceRaw
        case stays, localizedTitles
    }

    init(
        id: UUID, startDate: Date, endDate: Date? = nil, isComplete: Bool = false,
        customName: String? = nil, destinationSummary: String = "", countryCodes: String = "",
        aiGeneratedTitle: String? = nil, titleSourceRevision: UUID? = nil,
        aiGeneratedSummary: String? = nil, summaryGeneratedAt: Date? = nil,
        summaryGenerationVersion: Int? = nil, summarySourceRaw: String? = nil,
        classifiedByAI: Bool = false, userEdited: Bool = false,
        keptByTemporaryHome: Bool = false, sourceRaw: String = DataSource.liveSLC.rawValue,
        stays: [ExportStaySnapshot] = [], localizedTitles: [ExportLocalizedTitleSnapshot] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.isComplete = isComplete
        self.customName = customName
        self.destinationSummary = destinationSummary
        self.countryCodes = countryCodes
        self.aiGeneratedTitle = aiGeneratedTitle
        self.titleSourceRevision = titleSourceRevision
        self.aiGeneratedSummary = aiGeneratedSummary
        self.summaryGeneratedAt = summaryGeneratedAt
        self.summaryGenerationVersion = summaryGenerationVersion
        self.summarySourceRaw = summarySourceRaw
        self.classifiedByAI = classifiedByAI
        self.userEdited = userEdited
        self.keptByTemporaryHome = keptByTemporaryHome
        self.sourceRaw = sourceRaw
        self.stays = stays
        self.localizedTitles = localizedTitles
    }

    /// Members and title rows decode one by one: a damaged one is dropped
    /// (and, for a member, counted by `declaredStayCount`), not the trip.
    /// Only the rows that decode are kept, so a trip of damaged members never
    /// holds a slot per member.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        destinationSummary = try container.decode(String.self, forKey: .destinationSummary)
        countryCodes = try container.decode(String.self, forKey: .countryCodes)
        aiGeneratedTitle = try container.decodeIfPresent(String.self, forKey: .aiGeneratedTitle)
        titleSourceRevision = try container.decodeIfPresent(UUID.self, forKey: .titleSourceRevision)
        aiGeneratedSummary = try container.decodeIfPresent(String.self, forKey: .aiGeneratedSummary)
        summaryGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .summaryGeneratedAt)
        summaryGenerationVersion = try container.decodeIfPresent(Int.self, forKey: .summaryGenerationVersion)
        summarySourceRaw = try container.decodeIfPresent(String.self, forKey: .summarySourceRaw)
        classifiedByAI = try container.decode(Bool.self, forKey: .classifiedByAI)
        userEdited = try container.decode(Bool.self, forKey: .userEdited)
        keptByTemporaryHome = try container.decode(Bool.self, forKey: .keptByTemporaryHome)
        sourceRaw = try container.decode(String.self, forKey: .sourceRaw)
        var members = try container.nestedUnkeyedContainer(forKey: .stays)
        var stays: [ExportStaySnapshot] = []
        var declared = 0
        while !members.isAtEnd {
            declared += 1
            if let stay = try members.decode(BackupLossy<ExportStaySnapshot>.self).value {
                stays.append(stay)
            }
        }
        self.stays = stays
        declaredStayCount = declared
        var titles: [ExportLocalizedTitleSnapshot] = []
        if container.contains(.localizedTitles), try !container.decodeNil(forKey: .localizedTitles) {
            var rows = try container.nestedUnkeyedContainer(forKey: .localizedTitles)
            while !rows.isAtEnd {
                if let title = try rows.decode(BackupLossy<ExportLocalizedTitleSnapshot>.self).value {
                    titles.append(title)
                }
            }
        }
        localizedTitles = titles
    }
}

/// One declared home row: the era anchor for `homeAreaOverrides` and the
/// windowed classification of `homeStays`.
nonisolated struct ExportHomeSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var label: String = ""
    var latitude: Double
    var longitude: Double
    var radiusKm: Double = 25
    var locality: String? = nil
    var administrativeArea: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var startedAt: Date
    var endedAt: Date? = nil
}

/// One declared temporary home, live or removed: the dated anchor for the
/// `.home` stays and `homeAreaOverrides` rows keyed to it.
nonisolated struct ExportTemporaryHomeSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var label: String = ""
    var latitude: Double
    var longitude: Double
    var radiusKm: Double = 25
    var locality: String? = nil
    var administrativeArea: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var startedAt: Date
    var endedAt: Date? = nil
    var timeZoneIdentifier: String? = nil
    var createdAt: Date
    var modifiedAt: Date
    /// Set on a removed one only.
    var removedAt: Date? = nil
    var coverageRevision: Int = 0
    /// The kept trips of every row with the id (a keep on a losing twin
    /// counts too), sorted.
    var keptTripIDs: [UUID] = []
}

/// One routine place: the declaration behind exported `.routine` stays.
nonisolated struct ExportRoutinePlaceSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var label: String = ""
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double = 500
    var isActive: Bool = true
    var startedAt: Date
    var endedAt: Date? = nil
}

/// One home-area override (user include / learned-place exclude).
nonisolated struct ExportOverrideSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var kindRaw: String
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusKm: Double = 1
    var homeID: UUID? = nil
    var sourceTripName: String? = nil
    var createdAt: Date
}

nonisolated struct ExportVisitSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var stayID: UUID? = nil
    var arrivalDate: Date
    var departureDate: Date? = nil
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var receivedAt: Date
    var isProcessed: Bool = true
}

/// One hidden or pinned photo choice. `chosenAt` is `hiddenAt` or `pinnedAt`.
nonisolated struct ExportPhotoChoiceSnapshot: Sendable, Equatable {
    var id: UUID
    var tripID: UUID
    var localIdentifier: String
    var cloudIdentifier: String? = nil
    var chosenAt: Date
}

/// The file shape of a `HiddenPhoto` row.
nonisolated struct ExportHiddenPhotoRecord: Codable, Sendable {
    var id: UUID
    var localIdentifier: String
    var cloudIdentifier: String?
    var tripID: UUID
    var hiddenAt: Date

    init(_ choice: ExportPhotoChoiceSnapshot) {
        id = choice.id
        localIdentifier = choice.localIdentifier
        cloudIdentifier = choice.cloudIdentifier
        tripID = choice.tripID
        hiddenAt = choice.chosenAt
    }

    var choice: ExportPhotoChoiceSnapshot {
        ExportPhotoChoiceSnapshot(
            id: id, tripID: tripID, localIdentifier: localIdentifier,
            cloudIdentifier: cloudIdentifier, chosenAt: hiddenAt)
    }
}

/// The file shape of a `PinnedPhoto` row.
nonisolated struct ExportPinnedPhotoRecord: Codable, Sendable {
    var id: UUID
    var localIdentifier: String
    var cloudIdentifier: String?
    var tripID: UUID
    var pinnedAt: Date

    init(_ choice: ExportPhotoChoiceSnapshot) {
        id = choice.id
        localIdentifier = choice.localIdentifier
        cloudIdentifier = choice.cloudIdentifier
        tripID = choice.tripID
        pinnedAt = choice.chosenAt
    }

    var choice: ExportPhotoChoiceSnapshot {
        ExportPhotoChoiceSnapshot(
            id: id, tripID: tripID, localIdentifier: localIdentifier,
            cloudIdentifier: cloudIdentifier, chosenAt: pinnedAt)
    }
}

nonisolated struct ExportYearWrappedSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var year: Int
    var generatedAt: Date
    var viewedAt: Date? = nil
    var statsData: Data? = nil
    var yearNarrative: String? = nil
    var yearNarrativeSourceRaw: String? = nil
    var weatherCoverage: Double = 0
    var transitCoverage: Double = 0
}

nonisolated struct ExportPlannedTripSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var eventExternalIdentifier: String? = nil
    var eventLocalIdentifier: String = ""
    var title: String = ""
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool = false
    var locationText: String? = nil
    var resolvedLatitude: Double? = nil
    var resolvedLongitude: Double? = nil
    var resolvedLocality: String? = nil
    var resolvedCountry: String? = nil
    var resolvedISOCountryCode: String? = nil
    var distanceFromHomeKm: Double? = nil
    var confidenceRaw: String = "low"
    var signalsRaw: String = ""
    var statusRaw: String = "upcoming"
    var matchedTripID: UUID? = nil
    var forecastWeatherData: Data? = nil
    var createdAt: Date
    var lastSeenAt: Date
}

nonisolated struct ExportPhotoImportStateSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var completedAt: Date? = nil
    var statusRaw: String
    var totalAssetCount: Int = 0
    var processedAssetCount: Int = 0
    var acceptedPingCount: Int = 0
    var watermarkCreationDate: Date? = nil
    var watermarkLocalIdentifier: String? = nil
    var lastError: String? = nil
    var lastUpdated: Date
    var cancelRequested: Bool = false
    var originDeviceID: String = ""
}

nonisolated struct ExportHexVisitSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var h3Index: String
    var firstVisited: Date
    var lastVisited: Date
    var visitCount: Int = 1
    var locality: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var centerLatitude: Double = 0
    var centerLongitude: Double = 0
}

nonisolated struct ExportPingSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double = 0
    var altitude: Double? = nil
    var verticalAccuracy: Double? = nil
    var h3IndexRes6: String = ""
    var locality: String? = nil
    var subLocality: String? = nil
    var administrativeArea: String? = nil
    var country: String? = nil
    var isoCountryCode: String? = nil
    var isGeocoded: Bool = false
    var isProcessed: Bool = false
    var sourceRaw: String = DataSource.liveSLC.rawValue
}

/// Everything a backup carries apart from the streamed pings.
nonisolated struct BackupContents: Sendable {
    var trips: [ExportTripSnapshot] = []
    var layer = ExportSnapshotter.HomeAreaExport()
    var extras = BackupExtras()
}

/// What the backup reads outside the store, on the main actor, inside the
/// export's gate unit.
nonisolated struct BackupExtras: Sendable {
    var favouriteTripIDs: Set<UUID> = []
    var rememberedCountryCodes: Set<String> = []
    var removedTrips: [DissolvedTripRecord] = []
    var preferences = BackupPreferences()
    var appVersion = "unknown"
}

/// Why no backup was written: the store holds something its own restore
/// would refuse (`TripDataImporter+Admission`), so the file would come back
/// without it. Nothing is cut short to fit; the user changes the row and
/// exports again.
nonisolated enum BackupExportRefusal: LocalizedError, Equatable {
    /// A trip's name is past the restore's text bound
    /// (`BackupLimits.maxShortText` UTF-8 bytes): the restore would drop the
    /// trip with every stay in it.
    case tripNameTooLong(startDate: Date)

    var errorDescription: String? {
        switch self {
        case .tripNameTooLong(let startDate):
            let day = startDate.formatted(date: .long, time: .omitted)
            return String(localized: "data-export.error.trip-name-too-long", defaultValue: "The trip that starts on \(day) has a name too long to restore from a backup. Shorten its name, then export again.", comment: "Export error when a trip's custom name is longer than a backup can restore. The placeholder is the trip's start date.")
        }
    }
}

// MARK: - Exporter

/// Builds the backup. `ExportSnapshotter` reads the store in its own context
/// off the main actor and writes the file there, page by page.
enum TripDataExporter {

    /// The only format this build writes and reads.
    nonisolated static let formatVersion = 15

    /// Snapshot `@Model` trips into Sendable value mirrors. Call it on the
    /// isolation that owns the trips' `ModelContext`. Throws when a merged
    /// entry's destination summary cannot be read against the Homes.
    nonisolated static func makeSnapshots(from trips: [Trip]) throws -> [ExportTripSnapshot] {
        try collapsingUUIDTwins(trips.map { trip in
            ExportTripSnapshot(
                id: trip.id,
                startDate: trip.startDate,
                endDate: trip.endDate,
                isComplete: trip.isComplete,
                customName: trip.customName,
                destinationSummary: trip.destinationSummary,
                countryCodes: trip.countryCodes,
                aiGeneratedTitle: trip.aiGeneratedTitle,
                titleSourceRevision: trip.titleSourceRevision,
                aiGeneratedSummary: trip.aiGeneratedSummary,
                summaryGeneratedAt: trip.summaryGeneratedAt,
                summaryGenerationVersion: trip.summaryGenerationVersion,
                summarySourceRaw: trip.summarySourceRaw,
                classifiedByAI: trip.classifiedByAI,
                userEdited: trip.userEdited,
                keptByTemporaryHome: trip.keptByTemporaryHome,
                sourceRaw: trip.sourceRaw,
                stays: trip.orderedStays.map { makeStaySnapshot(from: $0) },
                localizedTitles: makeLocalizedTitleSnapshots(
                    from: trip.localizedTitles ?? [],
                    canonicalTitle: trip.aiGeneratedTitle,
                    sourceRevision: trip.titleSourceRevision))
        }, unionSummary: { try unionDestinationSummary(of: $0, among: trips) })
    }

    /// The destination summary `Trip.recomputeSummary` derives for a merged
    /// entry, from the physical stays it took (the twin with the most stays
    /// first, as the merge ranks them) against the store's Homes at its
    /// dates. A failed Home read throws: a summary keeping home-named places
    /// would be restored as it stands.
    nonisolated private static func unionDestinationSummary(
        of entry: ExportTripSnapshot, among trips: [Trip]
    ) throws -> String {
        let twins = trips.enumerated().filter { $0.element.id == entry.id }.sorted { a, b in
            let aCount = a.element.stays?.count ?? 0, bCount = b.element.stays?.count ?? 0
            return aCount != bCount ? aCount > bCount : a.offset < b.offset
        }.map(\.element)
        var staysByID: [UUID: Stay] = [:]
        for twin in twins {
            for stay in twin.orderedStays where staysByID[stay.id] == nil { staysByID[stay.id] = stay }
        }
        let destinationRaw = StayCategory.destination.rawValue
        let destinations = entry.stays
            .filter { $0.categoryRaw == destinationRaw }
            .compactMap { staysByID[$0.id] }
        let names = Trip.summaryNames(
            of: destinations, tripStart: entry.startDate, tripEnd: entry.endDate,
            in: twins.lazy.compactMap(\.modelContext).first)
        guard names.homePlacesRead else { throw TripTitleStore.HomePlaceNamesUnreadable() }
        return names.list.joined(separator: ", ")
    }

    /// Restore keeps the first entry for a Trip UUID, so physical UUID twins
    /// (two devices regrouping one journey before sync settled) leave as one
    /// entry, at the first twin's position: the stays of every twin, each stay
    /// UUID once, the OR of their edit marks and the first name (the twin with
    /// the most stays first). Title prose survives only from a twin whose
    /// membership is that whole union. An entry no twin holds whole is made
    /// coherent on its own: its stops are numbered in time order, its dates
    /// span them, its countries and provenance come from them, and its
    /// destination summary is `unionSummary`'s, derived from them against
    /// the Homes as `Trip.recomputeSummary` would, so a reader that keeps a
    /// whole trip's stored summary restores its names. Without one it is left
    /// empty, and restore derives it against the restored Homes
    /// (`TripDataImporter.importTrips`). Single rows pass through unchanged.
    nonisolated static func collapsingUUIDTwins(
        _ snapshots: [ExportTripSnapshot],
        unionSummary: ((ExportTripSnapshot) throws -> String)? = nil
    ) throws -> [ExportTripSnapshot] {
        var twinsByID: [UUID: [ExportTripSnapshot]] = [:]
        for snapshot in snapshots { twinsByID[snapshot.id, default: []].append(snapshot) }
        guard twinsByID.count < snapshots.count else { return snapshots }
        var emitted = Set<UUID>()
        var collapsed: [ExportTripSnapshot] = []
        for snapshot in snapshots where emitted.insert(snapshot.id).inserted {
            let twins = twinsByID[snapshot.id] ?? [snapshot]
            collapsed.append(twins.count == 1
                ? snapshot : try mergedTwins(twins, unionSummary: unionSummary))
        }
        return collapsed
    }

    nonisolated private static func mergedTwins(
        _ twins: [ExportTripSnapshot],
        unionSummary: ((ExportTripSnapshot) throws -> String)?
    ) throws -> ExportTripSnapshot {
        // The twin with the most stays first; equal counts keep the export order.
        let ranked = twins.enumerated().sorted { a, b in
            a.element.stays.count != b.element.stays.count
                ? a.element.stays.count > b.element.stays.count : a.offset < b.offset
        }.map(\.element)
        var seenStayIDs = Set<UUID>()
        var union: [ExportStaySnapshot] = []
        for twin in ranked {
            for stay in twin.stays where seenStayIDs.insert(stay.id).inserted { union.append(stay) }
        }
        // A twin holding every stay keeps its own stays, dates and titles.
        let whole = ranked.first { Set($0.stays.map(\.id)) == seenStayIDs }
        var merged = whole ?? ranked[0]
        if whole == nil {
            // Each twin numbered only its own stops; restore keeps a whole
            // membership's stored order, so the union is numbered in time order.
            merged.stays = union.sorted {
                ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString)
            }
            for index in merged.stays.indices { merged.stays[index].orderInTrip = index }
            let populated = ranked.filter { !$0.stays.isEmpty }
            let firstStart = merged.stays.map(\.startTime).min()
            let lastEnd = merged.stays.map(\.endTime).max()
            merged.startDate = (populated.map(\.startDate) + [firstStart].compactMap { $0 })
                .min() ?? merged.startDate
            merged.endDate = merged.endDate.map { end in
                (populated.compactMap(\.endDate) + [end, lastEnd].compactMap { $0 }).max() ?? end
            }
            // The fields `Trip.recomputeSummary` derives from the stays. The
            // destination names leave out home-area places, so they depend on
            // the Homes (below).
            var seenCodes = Set<String>()
            merged.countryCodes = merged.stays
                .filter { $0.categoryRaw == StayCategory.destination.rawValue }
                .compactMap(\.isoCountryCode)
                .filter { seenCodes.insert($0).inserted }
                .joined(separator: ",")
            let sources = Set(merged.stays.map { DataSource.decode($0.sourceRaw) })
            merged.sourceRaw = sources.count == 1
                ? (sources.first ?? .liveSLC).rawValue : DataSource.merged.rawValue
            merged.destinationSummary = ""
            if let unionSummary { merged.destinationSummary = try unionSummary(merged) }
            merged.aiGeneratedTitle = nil
            merged.titleSourceRevision = nil
            merged.aiGeneratedSummary = nil
            merged.summaryGeneratedAt = nil
            merged.summaryGenerationVersion = nil
            merged.summarySourceRaw = nil
            merged.localizedTitles = []
        }
        let userEdited = twins.contains { $0.userEdited }
        // As the ghost sweep's carry: an edit of the user's own on any twin
        // owns the merged trip; the temporary home's mark survives otherwise.
        let userOwned = twins.contains { $0.userEdited && !$0.keptByTemporaryHome }
        merged.customName = ranked.lazy.compactMap(\.customName)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        merged.userEdited = userEdited
        merged.keptByTemporaryHome = userEdited && !userOwned
        return merged
    }

    /// Throws when the restore would not bring back a trip as exported, by
    /// the restore's own admission rule: checked before anything is written.
    nonisolated static func checkRestorable(_ trips: [ExportTripSnapshot]) throws {
        if let trip = trips.first(where: { !BackupLimits.fits($0.customName) }) {
            throw BackupExportRefusal.tripNameTooLong(startDate: trip.startDate)
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

    /// The `trip == nil` travel stays: steady-state transit residue plus any
    /// destination/unclassified stay caught mid-CloudKit-hydration.
    nonisolated static func makeUnassignedSnapshots(from stays: [Stay]) -> [ExportStaySnapshot] {
        stays
            .filter { $0.trip == nil && $0.category != .home && $0.category != .routine }
            .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
            .map { makeStaySnapshot(from: $0) }
    }

    /// Home/routine dwell stays: the learned orbit's return evidence and the
    /// home-area corrections' sacred `.home` rows.
    nonisolated static func makeHomeStaySnapshots(from stays: [Stay]) -> [ExportStaySnapshot] {
        stays
            .filter { $0.trip == nil && ($0.category == .home || $0.category == .routine) }
            .sorted { ($0.startTime, $0.id.uuidString) < ($1.startTime, $1.id.uuidString) }
            .map { makeStaySnapshot(from: $0) }
    }

    /// Declared home rows, era order.
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

    /// Declared temporary homes, era order. Same-id twins (two devices
    /// importing one backup) export once, as the row every reader resolves
    /// them to, with the kept trips of every row. A removed id is left out
    /// (`makeRemovedTemporaryHomeSnapshots`).
    nonisolated static func makeTemporaryHomeSnapshots(from rows: [TemporaryHome]) -> [ExportTemporaryHomeSnapshot] {
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        return HomeAnchors.collapsingTwins(rows).map {
            makeTemporaryHomeSnapshot(from: $0, twins: rowsByID[$0.id] ?? [])
        }
    }

    /// One entry per removed temporary home, its removed rows ranked like
    /// twins, era order.
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
            keptTripIDs: TemporaryHome.keptTripIDs(of: twins)
                .sorted { $0.uuidString < $1.uuidString })
    }

    /// Routine-place declarations, era order.
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

    /// Home-area overrides: the user's taught corrections.
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

    /// Hidden photo choices, every row, in a stable order.
    nonisolated static func makePhotoChoiceSnapshots(from rows: [HiddenPhoto]) -> [ExportPhotoChoiceSnapshot] {
        sortedPhotoChoices(rows.map {
            ExportPhotoChoiceSnapshot(
                id: $0.id, tripID: $0.tripID, localIdentifier: $0.localIdentifier,
                cloudIdentifier: $0.cloudIdentifier, chosenAt: $0.hiddenAt)
        })
    }

    /// Pinned photo choices, every row, in a stable order.
    nonisolated static func makePhotoChoiceSnapshots(from rows: [PinnedPhoto]) -> [ExportPhotoChoiceSnapshot] {
        sortedPhotoChoices(rows.map {
            ExportPhotoChoiceSnapshot(
                id: $0.id, tripID: $0.tripID, localIdentifier: $0.localIdentifier,
                cloudIdentifier: $0.cloudIdentifier, chosenAt: $0.pinnedAt)
        })
    }

    nonisolated private static func sortedPhotoChoices(
        _ choices: [ExportPhotoChoiceSnapshot]
    ) -> [ExportPhotoChoiceSnapshot] {
        choices.sorted {
            ($0.tripID.uuidString, $0.chosenAt, $0.localIdentifier, $0.cloudIdentifier ?? "", $0.id.uuidString)
                < ($1.tripID.uuidString, $1.chosenAt, $1.localIdentifier, $1.cloudIdentifier ?? "", $1.id.uuidString)
        }
    }

    nonisolated static func makeYearWrappedSnapshots(from rows: [YearWrapped]) -> [ExportYearWrappedSnapshot] {
        rows
            .sorted { ($0.year, $0.generatedAt, $0.id.uuidString) < ($1.year, $1.generatedAt, $1.id.uuidString) }
            .map {
                ExportYearWrappedSnapshot(
                    id: $0.id, year: $0.year, generatedAt: $0.generatedAt,
                    viewedAt: $0.viewedAt, statsData: $0.statsData,
                    yearNarrative: $0.yearNarrative,
                    yearNarrativeSourceRaw: $0.yearNarrativeSourceRaw,
                    weatherCoverage: $0.weatherCoverage,
                    transitCoverage: $0.transitCoverage)
            }
    }

    nonisolated static func makePlannedTripSnapshots(from rows: [PlannedTrip]) -> [ExportPlannedTripSnapshot] {
        rows
            .sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
            .map {
                ExportPlannedTripSnapshot(
                    id: $0.id,
                    eventExternalIdentifier: $0.eventExternalIdentifier,
                    eventLocalIdentifier: $0.eventLocalIdentifier,
                    title: $0.title,
                    startDate: $0.startDate, endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    locationText: $0.locationText,
                    resolvedLatitude: $0.resolvedLatitude,
                    resolvedLongitude: $0.resolvedLongitude,
                    resolvedLocality: $0.resolvedLocality,
                    resolvedCountry: $0.resolvedCountry,
                    resolvedISOCountryCode: $0.resolvedISOCountryCode,
                    distanceFromHomeKm: $0.distanceFromHomeKm,
                    confidenceRaw: $0.confidenceRaw,
                    signalsRaw: $0.signalsRaw,
                    statusRaw: $0.statusRaw,
                    matchedTripID: $0.matchedTripID,
                    forecastWeatherData: $0.forecastWeatherData,
                    createdAt: $0.createdAt,
                    lastSeenAt: $0.lastSeenAt)
            }
    }

    nonisolated static func makePhotoImportStateSnapshots(
        from rows: [PhotoImportState]
    ) -> [ExportPhotoImportStateSnapshot] {
        rows
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                ExportPhotoImportStateSnapshot(
                    id: $0.id, startedAt: $0.startedAt, completedAt: $0.completedAt,
                    statusRaw: $0.statusRaw,
                    totalAssetCount: $0.totalAssetCount,
                    processedAssetCount: $0.processedAssetCount,
                    acceptedPingCount: $0.acceptedPingCount,
                    watermarkCreationDate: $0.watermarkCreationDate,
                    watermarkLocalIdentifier: $0.watermarkLocalIdentifier,
                    lastError: $0.lastError,
                    lastUpdated: $0.lastUpdated,
                    cancelRequested: $0.cancelRequested,
                    originDeviceID: $0.originDeviceID)
            }
    }

    nonisolated static func makeHexVisitSnapshots(from rows: [HexVisit]) -> [ExportHexVisitSnapshot] {
        rows
            .sorted { ($0.h3Index, $0.id.uuidString) < ($1.h3Index, $1.id.uuidString) }
            .map {
                ExportHexVisitSnapshot(
                    id: $0.id, h3Index: $0.h3Index,
                    firstVisited: $0.firstVisited, lastVisited: $0.lastVisited,
                    visitCount: $0.visitCount,
                    locality: $0.locality, country: $0.country,
                    isoCountryCode: $0.isoCountryCode,
                    centerLatitude: $0.centerLatitude,
                    centerLongitude: $0.centerLongitude)
            }
    }

    nonisolated static func makePingSnapshot(from ping: LocationPing) -> ExportPingSnapshot {
        ExportPingSnapshot(
            id: ping.id, timestamp: ping.timestamp,
            latitude: ping.latitude, longitude: ping.longitude,
            horizontalAccuracy: ping.horizontalAccuracy,
            altitude: ping.altitude, verticalAccuracy: ping.verticalAccuracy,
            h3IndexRes6: ping.h3IndexRes6,
            locality: ping.locality, subLocality: ping.subLocality,
            administrativeArea: ping.administrativeArea,
            country: ping.country, isoCountryCode: ping.isoCountryCode,
            isGeocoded: ping.isGeocoded, isProcessed: ping.isProcessed,
            sourceRaw: ping.sourceRaw)
    }

    nonisolated private static func makeStaySnapshot(from stay: Stay) -> ExportStaySnapshot {
        ExportStaySnapshot(
            id: stay.id,
            startTime: stay.startTime,
            endTime: stay.endTime,
            durationMinutes: stay.durationMinutes,
            centroidLatitude: stay.centroidLatitude,
            centroidLongitude: stay.centroidLongitude,
            locality: stay.locality,
            administrativeArea: stay.administrativeArea,
            country: stay.country,
            isoCountryCode: stay.isoCountryCode,
            subLocality: stay.subLocality,
            metroName: stay.metroName,
            islandName: stay.islandName,
            weatherData: stay.weatherData,
            avgTemperatureC: stay.avgTemperatureC,
            weatherConditionRaw: stay.weatherConditionRaw,
            precipitationMm: stay.precipitationMm,
            dayKey: stay.dayKey,
            transitFromPreviousRaw: stay.transitFromPreviousRaw,
            distanceFromPreviousKm: stay.distanceFromPreviousKm,
            stepsWalked: stay.stepsWalked,
            isAirport: stay.isAirport,
            h3IndexRes6: stay.h3IndexRes6,
            pingCount: stay.pingCount,
            distanceFromHomeKm: stay.distanceFromHomeKm,
            categoryRaw: stay.categoryRaw,
            userOverridden: stay.userOverridden,
            temporaryHomeID: stay.temporaryHomeID,
            temporaryHomeRevision: stay.temporaryHomeRevision,
            continuesPreviousTrip: stay.continuesPreviousTrip,
            orderInTrip: stay.orderInTrip,
            pingIDsString: stay.pingIDsString,
            sourceRaw: stay.sourceRaw,
            timeZoneIdentifier: stay.timeZoneIdentifier)
    }

    nonisolated static let exportFilePrefix = "TravelLog-Export-"
    /// The backup's own extension, so Files opens it in Travel Log. The bytes
    /// are the gzip document earlier builds wrote as `.json.gz`.
    nonisolated static let backupFileExtension = "travellogbackup"
    /// A picked backup's decompressed copy while it is read (`BackupFile`).
    nonisolated static let restoreStagingPrefix = "TravelLog-Restore-"
    /// A protected backup's sealed copy while its password is asked for.
    nonisolated static let lockedCopyExtension = "locked"
    /// The DEBUG diagnostics export, staged in the same temporary directory.
    nonisolated static let diagnosticsExportFileName = "TravelLog-diagnostics.json"

    /// Removes staged export copies from the temporary directory, including
    /// ones a share interrupted by app termination left behind, half-written
    /// ones, and restore staging copies a kill left (`isStagedExportName`).
    nonisolated static func removeStagedExports() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isStagedExportName(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The staged export's URL for today.
    nonisolated static func exportFileURL(now: Date = .now) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(exportFilePrefix)\(now.formatted(.iso8601.year().month().day())).\(backupFileExtension)")
    }

    /// The whole document in memory, uncompressed: a store-free backup for
    /// tests and tools. The app's export streams the same document
    /// (`ExportSnapshotter.writeBackupFile`).
    nonisolated static func buildExportData(
        _ contents: BackupContents, pings: [ExportPingSnapshot] = []
    ) -> Data? {
        let sink = BackupDataSink()
        do {
            let writer = BackupJSONWriter(sink: sink)
            try writeContents(contents, to: writer)
            try writer.array("pings", pings)
            try writer.finish()
        } catch {
            return nil
        }
        return sink.data
    }

    /// Every member but the trailing `pings`, which the caller streams.
    nonisolated static func writeContents(_ contents: BackupContents, to writer: BackupJSONWriter) throws {
        let layer = contents.layer
        let extras = contents.extras
        try writer.member("formatVersion", formatVersion)
        try writer.member("appVersion", extras.appVersion)
        try writer.member("exportDate", ISO8601DateFormatter().string(from: .now))
        try writer.array("trips", contents.trips)
        try writer.array("unassignedStays", layer.unassignedStays)
        try writer.array("homeStays", layer.homeStays)
        try writer.array("homes", layer.homes)
        try writer.array("temporaryHomes", layer.temporaryHomes)
        try writer.array("removedTemporaryHomes", layer.removedTemporaryHomes.filter { $0.removedAt != nil })
        try writer.array("routinePlaces", layer.routinePlaces)
        try writer.array("homeAreaOverrides", layer.overrides)
        try writer.array("visits", layer.visits)
        try writer.array("hiddenPhotos", layer.hiddenPhotos.map(ExportHiddenPhotoRecord.init))
        try writer.array("pinnedPhotos", layer.pinnedPhotos.map(ExportPinnedPhotoRecord.init))
        try writer.array("yearWrapped", layer.yearWrapped)
        try writer.array("plannedTrips", layer.plannedTrips)
        try writer.array("photoImportStates", layer.photoImportStates)
        try writer.array("hexVisits", layer.hexVisits)
        try writer.member("favouriteTripIDs", extras.favouriteTripIDs.map(\.uuidString).sorted())
        try writer.member("rememberedCountryCodes", extras.rememberedCountryCodes.sorted())
        try writer.array("removedTrips", extras.removedTrips)
        try writer.member("preferences", extras.preferences)
    }
}

// MARK: - Off-main snapshotting

/// The export reads the store OFF the main actor, in this actor's context,
/// and writes the file here: home/routine dwell stays are the majority of all
/// stays on a long-lived install, and pings outnumber them many times over.
@ModelActor
actor ExportSnapshotter {

    nonisolated struct HomeAreaExport: Sendable {
        var homes: [ExportHomeSnapshot] = []
        var homeStays: [ExportStaySnapshot] = []
        var overrides: [ExportOverrideSnapshot] = []
        var routinePlaces: [ExportRoutinePlaceSnapshot] = []
        var unassignedStays: [ExportStaySnapshot] = []
        var visits: [ExportVisitSnapshot] = []
        var temporaryHomes: [ExportTemporaryHomeSnapshot] = []
        var removedTemporaryHomes: [ExportTemporaryHomeSnapshot] = []
        var hiddenPhotos: [ExportPhotoChoiceSnapshot] = []
        var pinnedPhotos: [ExportPhotoChoiceSnapshot] = []
        var yearWrapped: [ExportYearWrappedSnapshot] = []
        var plannedTrips: [ExportPlannedTripSnapshot] = []
        var photoImportStates: [ExportPhotoImportStateSnapshot] = []
        var hexVisits: [ExportHexVisitSnapshot] = []
    }

    /// Rows per ping page: one page of snapshots is all the export holds.
    static let pingPageSize = 5_000

    /// Every trip, newest first, with its ordered stays and title variants.
    /// A failed fetch throws: an empty array would serialize into a file that
    /// looks like a valid backup.
    func snapshotTrips() throws -> [ExportTripSnapshot] {
        let trips = try modelContext.fetch(FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]))
        return try TripDataExporter.makeSnapshots(from: trips)
    }

    /// Every other model but the pings, in one pass. Throws like
    /// `snapshotTrips()`.
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
        result.hiddenPhotos = TripDataExporter.makePhotoChoiceSnapshots(
            from: try modelContext.fetch(FetchDescriptor<HiddenPhoto>()))
        result.pinnedPhotos = TripDataExporter.makePhotoChoiceSnapshots(
            from: try modelContext.fetch(FetchDescriptor<PinnedPhoto>()))
        result.yearWrapped = TripDataExporter.makeYearWrappedSnapshots(
            from: try modelContext.fetch(FetchDescriptor<YearWrapped>()))
        result.plannedTrips = TripDataExporter.makePlannedTripSnapshots(
            from: try modelContext.fetch(FetchDescriptor<PlannedTrip>()))
        result.photoImportStates = TripDataExporter.makePhotoImportStateSnapshots(
            from: try modelContext.fetch(FetchDescriptor<PhotoImportState>()))
        result.hexVisits = TripDataExporter.makeHexVisitSnapshots(
            from: try modelContext.fetch(FetchDescriptor<HexVisit>()))

        // One tripless fetch, partitioned in memory — the home/routine rows
        // and the travel residue are exact complements of `trip == nil`.
        let tripless = try modelContext.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate<Stay> { $0.trip == nil }))
        result.homeStays = TripDataExporter.makeHomeStaySnapshots(from: tripless)
        result.unassignedStays = TripDataExporter.makeUnassignedSnapshots(from: tripless)
        return result
    }

    /// Writes the whole backup through gzip to `url`, by way of a partial
    /// file renamed into place, so a failed or interrupted write never leaves
    /// a truncated backup at the shared URL. With `sealing`, the gzip stream
    /// is sealed with the password's key as it is written
    /// (`BackupEncryption`). Call it inside the export's read-only gate unit,
    /// so no gated write lands between its reads.
    func writeBackupFile(
        _ extras: BackupExtras, to url: URL, sealing: BackupEncryption.Sealing? = nil
    ) throws {
        let fileManager = FileManager.default
        let partial = url.deletingLastPathComponent().appendingPathComponent(
            "\(TripDataExporter.exportFilePrefix)\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: partial) }
        guard fileManager.createFile(
            atPath: partial.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw BackupWriteError()
        }
        let sink: any BackupSink = try sealing.map {
            try BackupEncryptedFileSink(path: partial.path, sealing: $0)
        } ?? BackupGzipFileSink(path: partial.path)
        try writeBackup(extras, to: sink)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: partial, to: url)
    }

    /// The same document, uncompressed, in memory (tests).
    func exportData(_ extras: BackupExtras = BackupExtras()) throws -> Data {
        let sink = BackupDataSink()
        try writeBackup(extras, to: sink)
        return sink.data
    }

    private func writeBackup(_ extras: BackupExtras, to sink: any BackupSink) throws {
        let trips = try snapshotTrips()
        try TripDataExporter.checkRestorable(trips)
        let contents = BackupContents(
            trips: trips, layer: try snapshotHomeAreaLayer(), extras: extras)
        let writer = BackupJSONWriter(sink: sink)
        try TripDataExporter.writeContents(contents, to: writer)
        try writer.beginArray("pings")
        try forEachPingPage { page in
            for ping in page { try writer.append(TripDataExporter.makePingSnapshot(from: ping)) }
        }
        try writer.endArray()
        try writer.finish()
    }

    /// Every ping, oldest first, a page at a time in a fresh context, so the
    /// rows of one page are released before the next is read.
    private func forEachPingPage(_ body: ([LocationPing]) throws -> Void) throws {
        var offset = 0
        while true {
            let fetched = try autoreleasepool { () throws -> Int in
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<LocationPing>(
                    sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.id)])
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = Self.pingPageSize
                let page = try context.fetch(descriptor)
                try body(page)
                return page.count
            }
            offset += fetched
            if fetched < Self.pingPageSize { return }
        }
    }
}

extension UTType {
    /// Exported in Info.plist and opened through `CFBundleDocumentTypes`, so
    /// Files and AirDrop hand a backup to Travel Log. It conforms to data and
    /// content, not gzip, so no archive tool claims it.
    nonisolated static let travelLogBackup = UTType(exportedAs: "com.kfragkoulis.travellog.backup", conformingTo: .data)
}
