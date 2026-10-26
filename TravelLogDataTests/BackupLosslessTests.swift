//
//  BackupLosslessTests.swift
//  TravelLogTests
//
//  The v15 backup is lossless: a store with every model populated with
//  non-default values exports, restores into a fresh store and exports
//  again to the same document, record by record and field by field; every
//  attribute of the live schema is either exported or deliberately left out
//  (listed below); an earlier format is refused with its localized message;
//  the gzip container reads back, rejects a cut-off file and still takes an
//  uncompressed one.
//
//  All places, names and dates are fictional fixtures.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
@Suite("Backup v15 lossless round trip")
struct BackupLosslessTests {

    // MARK: Fixture

    private static let base = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
    private static func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    /// Fictional places at coordinates far from any bundled airport, except
    /// `airport`, which sits on one: the restore re-derives `isAirport` and
    /// gets the stored value back.
    private static let harbour = (lat: 44.3, lon: 12.9)
    private static let village = (lat: 44.1, lon: 13.1)
    private static let airport = (lat: 44.5354, lon: 11.2887)
    private static let home = (lat: 43.2, lon: 11.7)

    private struct Fixture {
        var tripID: UUID
        var removedTripRecord: DissolvedTripRecord
        var extras: BackupExtras
    }

    private static func cell(_ point: (lat: Double, lon: Double)) -> String {
        H3Service.cellIndex(latitude: point.lat, longitude: point.lon) ?? "861e8052fffffff"
    }

    /// Every model with every attribute set away from its default.
    private func populate(_ container: ModelContainer) throws -> Fixture {
        let context = ModelContext(container)

        let homeRow = Home(label: "Harbour Flat", latitude: Self.home.lat, longitude: Self.home.lon,
                           radiusKm: 12.5, startedAt: Self.at(-9000))
        homeRow.locality = "Portoleva"
        homeRow.administrativeArea = "West Coast"
        homeRow.country = "Elyria"
        homeRow.isoCountryCode = "GR"
        homeRow.endedAt = Self.at(9000)
        context.insert(homeRow)

        let temporary = TemporaryHome(label: "Summer Studio", latitude: Self.village.lat,
                                      longitude: Self.village.lon, startedAt: Self.at(-400),
                                      endedAt: Self.at(400))
        temporary.radiusKm = 3.5
        temporary.locality = "Kalivo"
        temporary.administrativeArea = "Isles"
        temporary.country = "Elyria"
        temporary.isoCountryCode = "GR"
        temporary.timeZoneIdentifier = "Europe/Athens"
        temporary.createdAt = Self.at(-401.5)
        temporary.modifiedAt = Self.at(-300.25)
        temporary.coverageRevision = 7
        context.insert(temporary)

        let removedTemporary = TemporaryHome(label: "Old Cabin", latitude: Self.harbour.lat,
                                             longitude: Self.harbour.lon, startedAt: Self.at(-2000),
                                             endedAt: Self.at(-1900))
        removedTemporary.radiusKm = 2
        removedTemporary.createdAt = Self.at(-2001)
        removedTemporary.modifiedAt = Self.at(-1800)
        removedTemporary.removedAt = Self.at(-1700)
        removedTemporary.coverageRevision = 3
        removedTemporary.locality = "Mirto"
        removedTemporary.administrativeArea = "Isles"
        removedTemporary.country = "Elyria"
        removedTemporary.isoCountryCode = "GR"
        removedTemporary.timeZoneIdentifier = "Europe/Athens"
        context.insert(removedTemporary)

        let place = RoutinePlace(label: "Studio Desk", latitude: Self.home.lat + 0.01,
                                 longitude: Self.home.lon + 0.01, radiusMeters: 240,
                                 startedAt: Self.at(-5000))
        place.isActive = false
        place.endedAt = Self.at(-100)
        context.insert(place)

        let correction = HomeAreaOverride(kind: .exclude, centerLatitude: Self.village.lat + 0.02,
                                          centerLongitude: Self.village.lon + 0.02, radiusKm: 4.25,
                                          homeID: homeRow.id, sourceTripName: "Lantern Weekend")
        correction.createdAt = Self.at(-50.5)
        context.insert(correction)

        let trip = Trip(startDate: Self.at(0), source: .photoImport)
        trip.endDate = Self.at(72)
        trip.isComplete = true
        trip.customName = "Lantern Isles"
        trip.destinationSummary = "Mirto, Kalivo"
        trip.countryCodes = "GR"
        trip.aiGeneratedTitle = "Lantern Isles Escape"
        trip.titleSourceRevision = UUID()
        trip.aiGeneratedSummary = "Three bright days between two harbours."
        trip.summaryGeneratedAt = Self.at(80.75)
        trip.summaryGenerationVersion = 4
        trip.summarySourceRaw = "foundationModels"
        trip.classifiedByAI = true
        trip.userEdited = true
        trip.keptByTemporaryHome = true
        context.insert(trip)
        temporary.keptTripIDs = trip.id.uuidString

        let variant = TripTitleVariant(
            languageTag: "de", title: "Lanterninseln Auszeit", sourceTitle: "Lantern Isles Escape",
            sourceRevision: trip.titleSourceRevision, generationVersion: 3,
            updatedAt: Self.at(81.5), trip: trip)
        context.insert(variant)

        let pingA = LocationPing(timestamp: Self.at(1), latitude: Self.harbour.lat,
                                 longitude: Self.harbour.lon, horizontalAccuracy: 8.5,
                                 h3IndexRes6: Self.cell(Self.harbour), altitude: 12.25,
                                 verticalAccuracy: 3.5, source: .photoImport)
        pingA.locality = "Mirto"
        pingA.subLocality = "Old Port"
        pingA.administrativeArea = "Isles"
        pingA.country = "Elyria"
        pingA.isoCountryCode = "GR"
        pingA.isGeocoded = true
        pingA.isProcessed = true
        context.insert(pingA)
        let pingB = LocationPing(timestamp: Self.at(2), latitude: Self.harbour.lat + 0.001,
                                 longitude: Self.harbour.lon, horizontalAccuracy: 15,
                                 h3IndexRes6: Self.cell(Self.harbour), source: .liveSLC)
        context.insert(pingB)

        func stay(_ point: (lat: Double, lon: Double), from start: Double, to end: Double,
                  category: StayCategory, pings: [UUID] = []) -> Stay {
            let row = Stay(startTime: Self.at(start), endTime: Self.at(end),
                           centroidLatitude: point.lat, centroidLongitude: point.lon,
                           h3IndexRes6: Self.cell(point), pingCount: 23,
                           distanceFromHomeKm: 345.75, pingIDs: pings, source: .photoImport,
                           timeZoneIdentifier: "Europe/Athens")
            row.durationMinutes = Int((end - start) * 60)
            row.locality = "Mirto"
            row.administrativeArea = "Isles"
            row.country = "Elyria"
            row.isoCountryCode = "GR"
            row.subLocality = "Old Port"
            row.metroName = "Mirto Bay"
            row.islandName = "Lantern"
            row.weatherData = Data([1, 2, 3, 4, 250])
            row.avgTemperatureC = 24.5
            row.weatherConditionRaw = "clear"
            row.precipitationMm = 0.75
            row.dayKey = Self.at(start - 1)
            row.transitFromPreviousRaw = TransitMode.flight.rawValue
            row.distanceFromPreviousKm = 210.5
            row.stepsWalked = 8123
            row.category = category
            row.userOverridden = true
            row.continuesPreviousTrip = true
            return row
        }
        let first = stay(Self.harbour, from: 1, to: 20, category: .destination, pings: [pingA.id, pingB.id])
        first.trip = trip
        first.orderInTrip = 0
        context.insert(first)
        let second = stay(Self.airport, from: 30, to: 32, category: .transit)
        second.isAirport = true
        second.trip = trip
        second.orderInTrip = 1
        context.insert(second)
        let tripless = stay(Self.village, from: 200, to: 210, category: .destination)
        tripless.orderInTrip = 4
        context.insert(tripless)
        let homeStay = stay(Self.village, from: -380, to: -360, category: .home)
        homeStay.setTemporaryHomeProvenance(temporary.id, revision: 6)
        homeStay.orderInTrip = 2
        context.insert(homeStay)

        let hex = HexVisit(h3Index: Self.cell(Self.harbour), firstVisited: Self.at(1),
                           centerLatitude: Self.harbour.lat, centerLongitude: Self.harbour.lon)
        hex.lastVisited = Self.at(20)
        hex.visitCount = 5
        hex.locality = "Mirto"
        hex.country = "Elyria"
        hex.isoCountryCode = "GR"
        context.insert(hex)

        context.insert(Visit(
            arrivalDate: Self.at(1.25), departureDate: Self.at(19.5), latitude: Self.harbour.lat,
            longitude: Self.harbour.lon, horizontalAccuracy: 35.5, receivedAt: Self.at(1.3),
            stayID: first.id, isProcessed: true))

        let hidden = HiddenPhoto(localIdentifier: "LOCAL-H/L0/001", tripID: trip.id)
        hidden.cloudIdentifier = "CLOUD-H"
        hidden.hiddenAt = Self.at(90.5)
        context.insert(hidden)
        let pinned = PinnedPhoto(localIdentifier: "LOCAL-P/L0/001", tripID: trip.id)
        pinned.cloudIdentifier = "CLOUD-P"
        pinned.pinnedAt = Self.at(91.5)
        context.insert(pinned)

        let wrapped = YearWrapped(year: 2026)
        wrapped.generatedAt = Self.at(100.5)
        wrapped.viewedAt = Self.at(101.5)
        wrapped.statsData = Data([9, 8, 7, 6])
        wrapped.yearNarrative = "A year of harbours."
        wrapped.yearNarrativeSourceRaw = "deterministic"
        wrapped.weatherCoverage = 0.75
        wrapped.transitCoverage = 0.5
        context.insert(wrapped)

        let planned = PlannedTrip(
            eventExternalIdentifier: "EXT-1", eventLocalIdentifier: "LOC-1", title: "Lantern Return",
            startDate: Self.at(500), endDate: Self.at(560), isAllDay: true, locationText: "Mirto")
        planned.resolvedLatitude = Self.harbour.lat
        planned.resolvedLongitude = Self.harbour.lon
        planned.resolvedLocality = "Mirto"
        planned.resolvedCountry = "Elyria"
        planned.resolvedISOCountryCode = "GR"
        planned.distanceFromHomeKm = 345.5
        planned.confidenceRaw = "high"
        planned.signalsRaw = "location,title"
        planned.statusRaw = "matched"
        planned.matchedTripID = trip.id
        planned.forecastWeatherData = Data([5, 5, 5])
        planned.createdAt = Self.at(400.5)
        planned.lastSeenAt = Self.at(450.5)
        context.insert(planned)

        let importState = PhotoImportState(originDeviceID: "device-fixture")
        importState.startedAt = Self.at(-20.5)
        importState.completedAt = Self.at(-10.5)
        importState.statusRaw = "completed"
        importState.totalAssetCount = 120
        importState.processedAssetCount = 118
        importState.acceptedPingCount = 77
        importState.watermarkCreationDate = Self.at(-11.5)
        importState.watermarkLocalIdentifier = "LOCAL-W/L0/001"
        importState.lastError = "fixture warning"
        importState.lastUpdated = Self.at(-10.25)
        importState.cancelRequested = true
        context.insert(importState)

        try context.save()

        // A Removed Trips archive whose trip is not in the store.
        let removedTripRecord = DissolvedTripRecord(
            id: UUID(), dissolvedAt: Self.at(300), displayName: "Kalivo",
            startDate: Self.at(250), endDate: Self.at(260), isComplete: true,
            destinationSummary: "Kalivo", countryCodes: "GR", classifiedByAI: true,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: "Kalivo Days",
            userEdited: true, keptByTemporaryHome: false,
            stays: [.init(id: tripless.id, categoryRaw: "destination", orderInTrip: 0)])

        var extras = BackupExtras()
        extras.favouriteTripIDs = [trip.id]
        extras.rememberedCountryCodes = ["GR", "PT"]
        extras.removedTrips = [removedTripRecord]
        extras.preferences = BackupPreferences(
            tripsSortOrder: "oldestFirst", tripFilters: "{\"formatVersion\":2}",
            temperatureUnit: "fahrenheit", splitHintDismissed: true,
            splitHintSeenTripIDs: trip.id.uuidString,
            temporaryHomeSuggestionDismissals: ["suggestion-a"],
            temporaryHomeEndHintDismissals: ["end-hint-a"],
            dismissedFlightCandidates: ["flight-a"],
            tripGapConfirmations: [TripGapAnswers.key(earlier: UUID(), later: UUID())],
            flightTimeOverrides: [FlightTimeOverrides.entry(
                id: UUID(), times: .init(departure: Self.at(251), arrival: Self.at(252)))],
            flightStops: [FlightStops.entry(id: UUID(), codes: ["FRA"])])
        extras.appVersion = "fixture"
        return Fixture(tripID: trip.id, removedTripRecord: removedTripRecord, extras: extras)
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupLossless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func importer(for container: ModelContainer, queue: URL) async -> TripDataImporter {
        let importer = TripDataImporter(modelContainer: container)
        await importer.setReconciliationDefaultsSuiteForTesting("BackupLossless-\(UUID().uuidString)")
        await importer.setHomeAliasDefaultsSuiteForTesting("BackupLossless-\(UUID().uuidString)")
        await importer.setRemovedTripsDirectoryForTesting(queue)
        return importer
    }

    // MARK: Document comparison

    /// The document's sections, each as records by id (order-free), the
    /// scalars as they are. `exportDate` is when, not what.
    private func sections(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var result: [String: Any] = [:]
        for (key, value) in root where key != "exportDate" {
            if let entries = value as? [[String: Any]], entries.allSatisfy({ $0["id"] != nil }) {
                var byID: [String: [String: Any]] = [:]
                for entry in entries { byID["\(entry["id"]!)"] = entry }
                result[key] = byID
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Field-by-field differences between two documents, as key paths.
    private func differences(_ lhs: Any?, _ rhs: Any?, path: String) -> [String] {
        switch (lhs, rhs) {
        case let (l as [String: Any], r as [String: Any]):
            return Set(l.keys).union(r.keys).sorted().flatMap {
                differences(l[$0], r[$0], path: "\(path).\($0)")
            }
        case let (l as [Any], r as [Any]):
            guard l.count == r.count else { return ["\(path): \(l.count) vs \(r.count) entries"] }
            return zip(l, r).enumerated().flatMap { differences($1.0, $1.1, path: "\(path)[\($0)]") }
        case (nil, nil):
            return []
        case let (l?, r?) where (l as AnyObject).isEqual(r as AnyObject):
            return []
        default:
            return ["\(path): \(lhs.map { "\($0)" } ?? "absent") vs \(rhs.map { "\($0)" } ?? "absent")"]
        }
    }

    // MARK: Tests

    @Test("every model, attribute, id and relationship survives export, restore into a fresh store and export again")
    func roundTripIsLossless() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let fixture = try populate(source)
        let original = try await ExportSnapshotter(modelContainer: source).exportData(fixture.extras)

        let payload = try TripDataImporter.parse(original)
        #expect(payload.malformedTrips == 0 && payload.malformedStays == 0)
        #expect(payload.malformedVisits == 0 && payload.malformedRecords == 0)

        let target = try TestSupport.makeInMemoryContainer()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 1)
        #expect(preview.newStays == 4)
        // 2 pings, the hex cell, the recap, the plan, the import state and the archive.
        #expect(preview.newRecords == 7)
        #expect(preview.malformedEntries == 0)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 4)
        #expect(outcome.insertedPings == 2)
        #expect(outcome.insertedRecords == 5)
        #expect(outcome.insertedPhotoChoices == 2)
        #expect(outcome.restorableFavouriteTripIDs == [fixture.tripID])
        #expect(payload.rememberedCountryCodes == ["GR", "PT"])

        // The device-local state lands where the app keeps it.
        let restoredQueue = try DissolvedTripQueue.loadThrowing(from: queue)
        #expect(restoredQueue == [fixture.removedTripRecord])
        let suite = "BackupLossless-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let ubiquitous = try #require(UserDefaults(suiteName: suite + "-kvs"))
        defer {
            defaults.removePersistentDomain(forName: suite)
            ubiquitous.removePersistentDomain(forName: suite + "-kvs")
        }
        #expect(BackupPreferences.restore(payload.preferences, defaults: defaults, ubiquitous: ubiquitous) == 11)
        let restoredPreferences = BackupPreferences.current(defaults: defaults, ubiquitous: ubiquitous)
        #expect(restoredPreferences == fixture.extras.preferences)

        // Spot checks on the restored rows themselves.
        let context = ModelContext(target)
        let pings = try context.fetch(FetchDescriptor<LocationPing>(sortBy: [SortDescriptor(\.timestamp)]))
        #expect(pings.map(\.isProcessed) == [true, false])
        #expect(pings.first?.source == .photoImport)
        #expect(pings.first?.altitude == 12.25)
        let hex = try #require(try context.fetch(FetchDescriptor<HexVisit>()).first)
        #expect(hex.visitCount == 5)
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.destinationSummary == "Mirto, Kalivo")
        #expect(trip.summaryGeneratedAt == Self.at(80.75))
        #expect(trip.localizedTitles?.count == 1)
        #expect(trip.orderedStays.map(\.isAirport) == [false, true])
        #expect(try context.fetch(FetchDescriptor<YearWrapped>()).first?.statsData == Data([9, 8, 7, 6]))
        #expect(try context.fetch(FetchDescriptor<PhotoImportState>()).first?.cancelRequested == true)

        // The restored store exports to the same document, field by field.
        var restoredExtras = BackupExtras()
        restoredExtras.favouriteTripIDs = outcome.restorableFavouriteTripIDs
        restoredExtras.rememberedCountryCodes = payload.rememberedCountryCodes
        restoredExtras.removedTrips = restoredQueue
        restoredExtras.preferences = restoredPreferences
        restoredExtras.appVersion = fixture.extras.appVersion
        let again = try await ExportSnapshotter(modelContainer: target).exportData(restoredExtras)
        let diff = differences(try sections(original), try sections(again), path: "backup")
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")

        // A second restore of the same file adds nothing.
        let repeatPreview = try await importer.preview(
            of: payload, favouriteTripIDs: outcome.restorableFavouriteTripIDs,
            rememberedCountryCodes: payload.rememberedCountryCodes,
            queuedRemovedTripIDs: Set(restoredQueue.map(\.id)))
        #expect(!repeatPreview.hasImportableContent)
        let repeated = await importer.importTrips(from: payload)
        #expect(!repeated.saveFailed)
        #expect(repeated.insertedTrips == 0 && repeated.insertedStays == 0)
        #expect(repeated.insertedPings == 0 && repeated.insertedRecords == 0)
        #expect(repeated.insertedPhotoChoices == 0)
    }

    /// Attributes of the live schema the backup deliberately does not carry
    /// as their own field. Each entry says why. Relationships travel as
    /// nesting and are listed in `nestedRelationships`.
    private static let excludedAttributes: [String: String] = [:]

    /// Relationships carried by nesting: a trip's `stays` and
    /// `localizedTitles` arrays hold the rows, so the inverse is implied.
    private static let nestedRelationships: Set<String> = [
        "Trip.stays", "Trip.localizedTitles", "Stay.trip", "TripTitleVariant.trip",
    ]

    /// Where each entity's rows sit in the document.
    private static let sectionsByEntity: [String: [String]] = [
        "Trip": ["trips"],
        "Stay": ["trips.stays", "unassignedStays", "homeStays"],
        "TripTitleVariant": ["trips.localizedTitles"],
        "LocationPing": ["pings"],
        "HexVisit": ["hexVisits"],
        "Visit": ["visits"],
        "Home": ["homes"],
        "TemporaryHome": ["temporaryHomes", "removedTemporaryHomes"],
        "RoutinePlace": ["routinePlaces"],
        "HomeAreaOverride": ["homeAreaOverrides"],
        "HiddenPhoto": ["hiddenPhotos"],
        "PinnedPhoto": ["pinnedPhotos"],
        "YearWrapped": ["yearWrapped"],
        "PlannedTrip": ["plannedTrips"],
        "PhotoImportState": ["photoImportStates"],
    ]

    @Test("every attribute of every entity in the live schema is exported or deliberately excluded")
    func schemaGuard() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let fixture = try populate(source)
        let data = try await ExportSnapshotter(modelContainer: source).exportData(fixture.extras)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        func records(at path: String) -> [[String: Any]] {
            let parts = path.split(separator: ".").map(String.init)
            var level = (root[parts[0]] as? [[String: Any]]) ?? []
            for part in parts.dropFirst() {
                level = level.flatMap { ($0[part] as? [[String: Any]]) ?? [] }
            }
            return level
        }

        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        var unaccounted: [String] = []
        for entity in schema.entities {
            guard let paths = Self.sectionsByEntity[entity.name] else {
                unaccounted.append("\(entity.name): no section in the backup")
                continue
            }
            let rows = paths.flatMap(records(at:))
            #expect(!rows.isEmpty, "the fixture exports no \(entity.name) row")
            let written = rows.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
            for attribute in entity.attributes {
                let name = "\(entity.name).\(attribute.name)"
                if Self.excludedAttributes[name] == nil, !written.contains(attribute.name) {
                    unaccounted.append("\(name): neither exported nor excluded")
                }
            }
            for relationship in entity.relationships
            where !Self.nestedRelationships.contains("\(entity.name).\(relationship.name)") {
                unaccounted.append("\(entity.name).\(relationship.name): relationship not carried")
            }
        }
        #expect(unaccounted.isEmpty, "\(unaccounted.sorted().joined(separator: "\n"))")
        #expect(Set(schema.entities.map(\.name)) == Set(Self.sectionsByEntity.keys))
    }

    @Test("a v14 file and an unversioned one are refused with the localized older-format message", arguments: [14, nil] as [Int?])
    func olderFormatIsRefused(version: Int?) throws {
        var root: [String: Any] = [
            "exportDate": "2026-02-01T00:00:00Z",
            "appVersion": "1.0",
            "trips": [[
                "id": UUID().uuidString,
                "startDate": "2026-01-10T08:00:00Z",
                "endDate": "2026-01-12T18:00:00Z",
                "isComplete": true,
                "destinationSummary": "Mirto",
                "stays": [[
                    "id": UUID().uuidString,
                    "startTime": "2026-01-10T10:00:00Z",
                    "endTime": "2026-01-12T09:00:00Z",
                    "category": "destination",
                    "latitude": Self.harbour.lat,
                    "longitude": Self.harbour.lon,
                ]],
            ]],
        ]
        if let version { root["formatVersion"] = version }
        let data = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: TripDataImportError.olderFormat) { try TripDataImporter.parse(data) }
        let message = TripDataImportError.olderFormat.localizedDescription
        #expect(message == String(
            localized: "data-import.error.older-format",
            defaultValue: "This backup was made by an earlier version of Travel Log and can't be imported. Update Travel Log on the device that has your trips, then export a new backup there."))
        #expect(!message.contains("\u{2014}") && !message.contains("\u{2013}"))
    }

    @Test("the gzip backup file reads back as the document, a cut-off one is refused, an uncompressed one is taken")
    func gzipContainerRoundTrips() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let fixture = try populate(source)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotter = ExportSnapshotter(modelContainer: source)

        let file = directory.appendingPathComponent("backup.json.gz")
        try await snapshotter.writeBackupFile(fixture.extras, to: file)
        let compressed = try Data(contentsOf: file)
        #expect(compressed.starts(with: [0x1f, 0x8b]))
        let staged = try BackupFile.stagedContents(of: file)
        let plain = try await snapshotter.exportData(fixture.extras)
        #expect(differences(try sections(staged), try sections(plain), path: "backup").isEmpty)
        #expect(try TripDataImporter.parse(staged).trips.map(\.id) == [fixture.tripID])
        // No staging copy outlives the read.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix(TripDataExporter.restoreStagingPrefix) }
        #expect(leftovers.isEmpty)

        let cut = directory.appendingPathComponent("cut.json.gz")
        try compressed.prefix(compressed.count / 2).write(to: cut)
        #expect(throws: TripDataImportError.notJSON) { try BackupFile.stagedContents(of: cut) }

        let uncompressed = directory.appendingPathComponent("plain.json")
        try plain.write(to: uncompressed)
        #expect(try TripDataImporter.parse(BackupFile.stagedContents(of: uncompressed)).trips.count == 1)
    }

    @Test("a v15 backup opens the same as .travellogbackup and as an earlier build's .json.gz, and the original stays")
    func backupOpensUnderEitherName() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let fixture = try populate(source)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotter = ExportSnapshotter(modelContainer: source)

        let current = directory.appendingPathComponent(
            TripDataExporter.exportFileURL().lastPathComponent)
        #expect(current.pathExtension == TripDataExporter.backupFileExtension)
        try await snapshotter.writeBackupFile(fixture.extras, to: current)
        let earlier = directory.appendingPathComponent("TravelLog-Export-earlier.json.gz")
        try FileManager.default.copyItem(at: current, to: earlier)

        for file in [current, earlier] {
            let payload = try TripDataImporter.parse(BackupFile.openedContents(of: file))
            #expect(payload.trips.map(\.id) == [fixture.tripID], "\(file.lastPathComponent)")
            // Only the system's Inbox copy is removed once read.
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(differences(
            try sections(BackupFile.openedContents(of: current)),
            try sections(BackupFile.openedContents(of: earlier)), path: "backup").isEmpty)
    }

    @Test("a ping chunk that fails to save reports the import incomplete, keeps the committed graph, and a re-import fills the gap")
    func failedPingChunkIsRefilledByReimport() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let fixture = try populate(source)
        let payload = try TripDataImporter.parse(
            try await ExportSnapshotter(modelContainer: source).exportData(fixture.extras))

        let target = try TestSupport.makeInMemoryContainer()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        await importer.failPingChunkSaveForTesting(1)
        let failed = await importer.importTrips(from: payload)
        #expect(failed.saveFailed)
        #expect(failed.insertedTrips == 1)
        #expect(failed.insertedPings == 0)
        #expect(try ModelContext(target).fetchCount(FetchDescriptor<LocationPing>()) == 0)

        let preview = try await importer.preview(of: payload)
        #expect(preview.hasImportableContent)
        let refilled = await importer.importTrips(from: payload)
        #expect(!refilled.saveFailed)
        #expect(refilled.insertedTrips == 0)
        #expect(refilled.insertedPings == 2)
        #expect(try ModelContext(target).fetchCount(FetchDescriptor<LocationPing>()) == 2)
    }

    @Test("size of a long ping history: bytes per ping, uncompressed and gzip")
    func pingHistorySize() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let count = TestSupport.soak ? 20_000 : 2_000
        for index in 0..<count {
            // A fictional wander, a ping a minute, like live recording.
            let lat = Self.harbour.lat + Double(index % 400) * 0.000_37
            let lon = Self.harbour.lon + Double(index / 400) * 0.000_41
            let ping = LocationPing(
                timestamp: Self.at(Double(index) / 60), latitude: lat, longitude: lon,
                horizontalAccuracy: Double(5 + index % 60),
                h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "",
                altitude: Double(index % 300) + 0.37, verticalAccuracy: 4)
            ping.isProcessed = true
            if index % 3 == 0 {
                ping.locality = "Mirto"
                ping.country = "Elyria"
                ping.isoCountryCode = "GR"
                ping.isGeocoded = true
            }
            context.insert(ping)
        }
        try context.save()

        let snapshotter = ExportSnapshotter(modelContainer: container)
        let plain = try await snapshotter.exportData()
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("size.json.gz")
        try await snapshotter.writeBackupFile(BackupExtras(), to: file)
        let compressed = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0

        let plainPerPing = Double(plain.count) / Double(count)
        let gzipPerPing = Double(compressed) / Double(count)
        print("Backup size: \(plainPerPing) bytes/ping uncompressed, \(gzipPerPing) bytes/ping gzip")
        #expect(plainPerPing < 700)
        #expect(gzipPerPing < plainPerPing / 2)
        #expect(try TripDataImporter.parse(plain).pings.isEmpty == false)
    }
}
