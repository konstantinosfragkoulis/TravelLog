//
//  BackupHardeningTests.swift
//  TravelLogTests
//
//  A backup can be hand-edited, damaged or hostile. Whatever it holds, the
//  import either succeeds or throws one of its own errors: it never traps,
//  hangs, runs out of memory or leaves a row the live app could not have
//  written. A decompression bomb fails fast; an isolated bad row is dropped
//  and counted; a fuzzer mutates a valid document thousands of ways.
//
//  All places, names and dates are fictional fixtures.
//

import Testing
import Foundation
import SwiftData
import Darwin
@testable import TravelLog

/// A small valid v15 document with a row in every section.
nonisolated enum HardeningFixture {
    static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    static let harbour = (lat: 44.3, lon: 12.9)
    static let village = (lat: 44.1, lon: 13.1)
    static let home = (lat: 43.2, lon: 11.7)

    static func stay(
        _ point: (lat: Double, lon: Double), from start: Double, to end: Double, category: String,
        order: Int? = nil
    ) -> ExportStaySnapshot {
        ExportStaySnapshot(
            id: UUID(), startTime: at(start), endTime: at(end),
            durationMinutes: Int((end - start) * 60),
            centroidLatitude: point.lat, centroidLongitude: point.lon,
            locality: "Mirto", country: "Elyria", isoCountryCode: "GR",
            weatherData: Data([1, 2, 3]), avgTemperatureC: 21.5,
            weatherConditionRaw: "clear", precipitationMm: 0.5,
            distanceFromPreviousKm: 12.5, stepsWalked: 4_000,
            pingCount: 4, distanceFromHomeKm: 210, categoryRaw: category,
            orderInTrip: order, timeZoneIdentifier: "Europe/Athens")
    }

    static func document(pings: Int = 12) -> Data {
        let trip = ExportTripSnapshot(
            id: UUID(), startDate: at(0), endDate: at(60), isComplete: true,
            customName: "Lantern Isles", destinationSummary: "Mirto", countryCodes: "GR",
            aiGeneratedTitle: "Lantern Isles Escape", aiGeneratedSummary: "Two harbours.",
            summaryGeneratedAt: at(61), summaryGenerationVersion: 2,
            stays: [
                stay(harbour, from: 1, to: 20, category: "destination", order: 0),
                stay(village, from: 25, to: 40, category: "destination", order: 1),
            ])
        var layer = ExportSnapshotter.HomeAreaExport()
        layer.unassignedStays = [stay(village, from: 200, to: 210, category: "transit")]
        layer.homeStays = [stay(home, from: -50, to: -10, category: "home")]
        layer.homes = [ExportHomeSnapshot(
            id: UUID(), label: "Flat", latitude: home.lat, longitude: home.lon,
            radiusKm: 10, startedAt: at(-9_000))]
        layer.temporaryHomes = [ExportTemporaryHomeSnapshot(
            id: UUID(), label: "Studio", latitude: village.lat, longitude: village.lon,
            radiusKm: 3, startedAt: at(-400), endedAt: at(-300),
            createdAt: at(-401), modifiedAt: at(-399), coverageRevision: 2,
            keptTripIDs: [trip.id])]
        layer.removedTemporaryHomes = [ExportTemporaryHomeSnapshot(
            id: UUID(), label: "Cabin", latitude: harbour.lat, longitude: harbour.lon,
            startedAt: at(-900), endedAt: at(-800), createdAt: at(-901), modifiedAt: at(-899),
            removedAt: at(-700), coverageRevision: 1)]
        layer.routinePlaces = [ExportRoutinePlaceSnapshot(
            id: UUID(), label: "Desk", latitude: home.lat + 0.01, longitude: home.lon,
            radiusMeters: 300, startedAt: at(-5_000))]
        layer.overrides = [ExportOverrideSnapshot(
            id: UUID(), kindRaw: HomeAreaOverride.Kind.exclude.rawValue,
            centerLatitude: village.lat, centerLongitude: village.lon, radiusKm: 2,
            createdAt: at(-20))]
        layer.visits = [ExportVisitSnapshot(
            id: UUID(), stayID: trip.stays[0].id, arrivalDate: at(1.5), departureDate: at(19),
            latitude: harbour.lat, longitude: harbour.lon, horizontalAccuracy: 30,
            receivedAt: at(1.6))]
        layer.hiddenPhotos = [ExportPhotoChoiceSnapshot(
            id: UUID(), tripID: trip.id, localIdentifier: "LOCAL-H", chosenAt: at(70))]
        layer.pinnedPhotos = [ExportPhotoChoiceSnapshot(
            id: UUID(), tripID: trip.id, localIdentifier: "LOCAL-P", cloudIdentifier: "CLOUD-P",
            chosenAt: at(71))]
        layer.yearWrapped = [ExportYearWrappedSnapshot(
            id: UUID(), year: 2026, generatedAt: at(100), statsData: Data([9, 9]),
            weatherCoverage: 0.5, transitCoverage: 0.25)]
        layer.plannedTrips = [ExportPlannedTripSnapshot(
            id: UUID(), eventLocalIdentifier: "EVENT", title: "Return", startDate: at(500),
            endDate: at(560), resolvedLatitude: harbour.lat, resolvedLongitude: harbour.lon,
            distanceFromHomeKm: 200, createdAt: at(400), lastSeenAt: at(450))]
        layer.photoImportStates = [ExportPhotoImportStateSnapshot(
            id: UUID(), startedAt: at(-30), completedAt: at(-20), statusRaw: "completed",
            totalAssetCount: 10, processedAssetCount: 10, acceptedPingCount: 4, lastUpdated: at(-20))]
        layer.hexVisits = [ExportHexVisitSnapshot(
            id: UUID(), h3Index: H3Service.cellIndex(latitude: harbour.lat, longitude: harbour.lon) ?? "861e8052fffffff",
            firstVisited: at(1), lastVisited: at(20), visitCount: 3,
            centerLatitude: harbour.lat, centerLongitude: harbour.lon)]
        var extras = BackupExtras()
        extras.favouriteTripIDs = [trip.id]
        extras.rememberedCountryCodes = ["GR"]
        extras.removedTrips = [DissolvedTripRecord(
            id: UUID(), dissolvedAt: at(300), displayName: "Kalivo",
            startDate: at(250), endDate: at(260), isComplete: true,
            destinationSummary: "Kalivo", countryCodes: "GR", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil,
            userEdited: false, keptByTemporaryHome: false,
            stays: [.init(id: UUID(), categoryRaw: "destination", orderInTrip: 0)])]
        extras.preferences = BackupPreferences(
            tripsSortOrder: "dateOldest", temperatureUnit: "celsius",
            temporaryHomeSuggestionDismissals: ["suggestion-a"],
            tripGapConfirmations: ["gap-a"])
        let pingRows = (0..<pings).map { index in
            ExportPingSnapshot(
                id: UUID(), timestamp: at(1 + Double(index) * 0.5),
                latitude: harbour.lat + Double(index) * 0.001, longitude: harbour.lon,
                horizontalAccuracy: 10, altitude: 5, verticalAccuracy: 3,
                isProcessed: index % 2 == 0)
        }
        return TripDataExporter.buildExportData(
            BackupContents(trips: [trip], layer: layer, extras: extras), pings: pingRows)!
    }

    static func scratchDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The document gzip-compressed, as the export writes it.
    static func gzip(_ document: Data, to url: URL) throws {
        let sink = try BackupGzipFileSink(path: url.path)
        try sink.write(document)
        try sink.close()
    }

    /// The process's physical footprint, the figure jetsam judges.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// A seeded generator, so a failing mutation can be replayed.
nonisolated struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Suite("Backup import hardening")
struct BackupHardeningTests {

    private func importer(for container: ModelContainer, queue: URL) async -> TripDataImporter {
        let importer = TripDataImporter(modelContainer: container)
        await importer.setReconciliationDefaultsSuiteForTesting("BackupHardening-\(UUID().uuidString)")
        await importer.setHomeAliasDefaultsSuiteForTesting("BackupHardening-\(UUID().uuidString)")
        await importer.setRemovedTripsDirectoryForTesting(queue)
        return importer
    }

    /// The fixture document with `edit` applied to its parsed tree.
    private func edited(_ edit: (NSMutableDictionary) -> Void) throws -> Data {
        let root = try #require(try JSONSerialization.jsonObject(
            with: HardeningFixture.document(), options: [.mutableContainers]) as? NSMutableDictionary)
        edit(root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func firstTripStays(_ root: NSMutableDictionary) -> NSMutableArray {
        ((root["trips"] as! NSMutableArray)[0] as! NSMutableDictionary)["stays"] as! NSMutableArray
    }

    /// Every restored row is one the live app could hold.
    private func expectSoundStore(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        for stay in try context.fetch(FetchDescriptor<Stay>()) {
            #expect(PingRecorder.isImportableTimestamp(stay.startTime))
            #expect(PingRecorder.isImportableTimestamp(stay.endTime))
            #expect(stay.endTime >= stay.startTime)
            #expect(stay.durationMinutes >= 0)
            #expect(stay.pingCount >= 0)
            #expect(abs(stay.centroidLatitude) <= 90 && abs(stay.centroidLongitude) <= 180)
            #expect(stay.avgTemperatureC?.isFinite ?? true)
            #expect(stay.precipitationMm?.isFinite ?? true)
            #expect((stay.orderInTrip ?? 0) <= BackupLimits.maxOrder)
        }
        for trip in try context.fetch(FetchDescriptor<Trip>()) {
            #expect(!(trip.stays ?? []).isEmpty, "a phantom trip landed")
            #expect(trip.endDate.map { $0 >= trip.startDate } ?? true)
        }
        for ping in try context.fetch(FetchDescriptor<LocationPing>()) {
            #expect(PingRecorder.isImportableTimestamp(ping.timestamp))
            #expect(ping.altitude?.isFinite ?? true)
        }
    }

    // MARK: Timestamps and numbers

    @Test("a stay ending at -Infinity, Infinity or a huge time is dropped and counted, and the rest imports without a trap")
    func unboundedStayTimesAreDropped() async throws {
        let document = try edited { root in
            let stays = firstTripStays(root)
            (stays[0] as! NSMutableDictionary)["endTime"] = "Infinity"
            let unassigned = root["unassignedStays"] as! NSMutableArray
            (unassigned[0] as! NSMutableDictionary)["endTime"] = 1e300
            let homeStays = root["homeStays"] as! NSMutableArray
            (homeStays[0] as! NSMutableDictionary)["startTime"] = "-Infinity"
        }
        let payload = try TripDataImporter.parse(document)
        #expect(payload.malformedStays == 3)
        #expect(payload.trips.first?.stays.count == 1)

        let container = try TestSupport.makeInMemoryContainer()
        let queue = try HardeningFixture.scratchDirectory("BackupHardening")
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: container, queue: queue)
        let preview = try await importer.preview(of: payload)
        #expect(preview.malformedEntries == 3)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1 && outcome.insertedStays == 1)
        try expectSoundStore(container)
    }

    @Test("a stay spanning more than ten years is dropped; one across the whole importable domain too")
    func absurdSpansAreDropped() throws {
        let document = try edited { root in
            let stays = firstTripStays(root)
            (stays[0] as! NSMutableDictionary)["startTime"] = Date.distantPast.timeIntervalSinceReferenceDate
            (stays[0] as! NSMutableDictionary)["endTime"] = Date.distantFuture.timeIntervalSinceReferenceDate
            (stays[1] as! NSMutableDictionary)["endTime"] = HardeningFixture.at(24 * 3_651 + 25)
                .timeIntervalSinceReferenceDate
        }
        let payload = try TripDataImporter.parse(document)
        #expect(payload.malformedStays == 2)
        #expect(payload.trips.first?.stays.isEmpty == true)
    }

    @Test("out-of-range measurements and counts are cleared or clamped to what the app writes")
    func measurementsAreBounded() throws {
        let document = try edited { root in
            let stay = firstTripStays(root)[0] as! NSMutableDictionary
            stay["avgTemperatureC"] = 1e6
            stay["precipitationMm"] = -5
            stay["distanceFromPreviousKm"] = "NaN"
            stay["stepsWalked"] = -1
            stay["pingCount"] = Int64.min
            stay["durationMinutes"] = Int64.max
            stay["orderInTrip"] = Int64.max
            stay["distanceFromHomeKm"] = "-Infinity"
            stay["temporaryHomeRevision"] = Int64.max
            let ping = (root["pings"] as! NSMutableArray)[0] as! NSMutableDictionary
            ping["altitude"] = "Infinity"
            ping["verticalAccuracy"] = "NaN"
            let state = (root["photoImportStates"] as! NSMutableArray)[0] as! NSMutableDictionary
            state["totalAssetCount"] = -10
            let cell = (root["hexVisits"] as! NSMutableArray)[0] as! NSMutableDictionary
            cell["visitCount"] = Int64.max
            let wrapped = (root["yearWrapped"] as! NSMutableArray)[0] as! NSMutableDictionary
            wrapped["weatherCoverage"] = "Infinity"
        }
        let payload = try TripDataImporter.parse(document)
        #expect(payload.malformedStays == 0)
        let stay = try #require(payload.trips.first?.stays.first)
        #expect(stay.avgTemperatureC == nil)
        #expect(stay.precipitationMm == nil)
        #expect(stay.distanceFromPreviousKm == nil)
        #expect(stay.stepsWalked == nil)
        #expect(stay.pingCount == 0)
        #expect(stay.durationMinutes == 19 * 60)
        #expect(stay.orderInTrip == nil)
        #expect(stay.distanceFromHomeKm == .greatestFiniteMagnitude)
        #expect(stay.temporaryHomeRevision == BackupLimits.maxRevision)
        var pings: [ExportPingSnapshot] = []
        try payload.pings.forEachChunk { chunk, _ in pings += chunk }
        #expect(pings.count == 12)
        #expect(pings.contains { $0.altitude == nil && $0.verticalAccuracy == nil })
        #expect(payload.photoImportStates.first?.totalAssetCount == 0)
        #expect(payload.hexVisits.first?.visitCount == BackupLimits.maxCount)
        #expect(payload.yearWrapped.first?.weatherCoverage == 0)
    }

    @Test("bad rows in every other section are dropped and counted, never failing the file")
    func badRowsInEverySectionAreCounted() throws {
        let document = try edited { root in
            func first(_ key: String) -> NSMutableDictionary {
                (root[key] as! NSMutableArray)[0] as! NSMutableDictionary
            }
            first("homes")["startedAt"] = "Infinity"
            first("temporaryHomes")["createdAt"] = -1e300
            first("routinePlaces")["latitude"] = 91
            first("homeAreaOverrides")["createdAt"] = "NaN"
            first("visits")["receivedAt"] = 1e300
            first("hiddenPhotos")["hiddenAt"] = "Infinity"
            first("yearWrapped")["year"] = Int64.max
            first("plannedTrips")["endDate"] = 1e300
            first("photoImportStates")["lastUpdated"] = "-Infinity"
            first("hexVisits")["firstVisited"] = "NaN"
            first("removedTrips")["startDate"] = "Infinity"
            first("pings")["timestamp"] = 1e300
        }
        let payload = try TripDataImporter.parse(document)
        #expect(payload.homes.isEmpty && payload.temporaryHomes.isEmpty)
        #expect(payload.routinePlaces.isEmpty && payload.homeAreaOverrides.isEmpty)
        #expect(payload.hiddenPhotos.isEmpty)
        #expect(payload.malformedTrips == 5)
        #expect(payload.malformedVisits == 1)
        #expect(payload.malformedRecords == 5)
        var malformedPings = 0
        try payload.pings.forEachChunk { _, malformed in malformedPings += malformed }
        #expect(malformedPings == 1)
        #expect(payload.trips.count == 1)
    }

    @Test("a trip whose own dates are unusable or reversed is dropped with its stays and counted")
    func unusableTripDatesAreDropped() throws {
        let reversed = try edited { root in
            let trip = (root["trips"] as! NSMutableArray)[0] as! NSMutableDictionary
            trip["endDate"] = HardeningFixture.at(-100).timeIntervalSinceReferenceDate
        }
        #expect(try TripDataImporter.parse(reversed).trips.isEmpty)
        #expect(try TripDataImporter.parse(reversed).malformedTrips == 1)
        let infinite = try edited { root in
            let trip = (root["trips"] as! NSMutableArray)[0] as! NSMutableDictionary
            trip["startDate"] = "-Infinity"
        }
        #expect(try TripDataImporter.parse(infinite).trips.isEmpty)
    }

    // MARK: Sizes

    @Test("a huge string or an oversized element is dropped and counted; the rest of the file imports")
    func hugeFieldsAndElementsAreDropped() throws {
        let document = try edited { root in
            let stays = firstTripStays(root)
            (stays[0] as! NSMutableDictionary)["locality"] = String(repeating: "a", count: BackupLimits.maxShortText + 1)
            let pings = root["pings"] as! NSMutableArray
            (pings[0] as! NSMutableDictionary)["locality"] = String(repeating: "b", count: BackupLimits.maxPingBytes)
            let homes = root["homes"] as! NSMutableArray
            (homes[0] as! NSMutableDictionary)["label"] = String(repeating: "c", count: BackupLimits.maxRecordBytes)
            let trip = (root["trips"] as! NSMutableArray)[0] as! NSMutableDictionary
            trip["aiGeneratedSummary"] = String(repeating: "d", count: BackupLimits.maxLongText + 1)
            (root["trips"] as! NSMutableArray).add(["id": UUID().uuidString])
        }
        let payload = try TripDataImporter.parse(document)
        #expect(payload.trips.isEmpty, "the summary past its bound drops its trip")
        #expect(payload.malformedTrips == 3)
        #expect(payload.homes.isEmpty)
        var malformedPings = 0
        var pings = 0
        try payload.pings.forEachChunk { chunk, malformed in
            pings += chunk.count
            malformedPings += malformed
        }
        #expect(pings == 11 && malformedPings == 1)
    }

    @Test("a gzip bomb fails fast with the too-large error, within a memory budget")
    func gzipBombFailsFast() throws {
        let directory = try HardeningFixture.scratchDirectory("BackupBomb")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bomb = directory.appendingPathComponent("bomb.travellogbackup")
        let sink = try BackupGzipFileSink(path: bomb.path)
        let zeros = Data(count: 1 << 20)
        for _ in 0..<512 { try sink.write(zeros) }
        try sink.close()
        let compressed = try FileManager.default.attributesOfItem(atPath: bomb.path)[.size] as? Int ?? 0
        #expect(compressed < 2 << 20)

        let before = HardeningFixture.footprint()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: TripDataImportError.tooLarge) { try BackupFile.stagedContents(of: bomb) }
        }
        #expect(elapsed < .seconds(10))
        #expect(HardeningFixture.footprint() < before + (64 << 20))
        #expect(TripDataImportError.tooLarge.localizedDescription == String(
            localized: "data-import.error.too-large",
            defaultValue: "This file is larger than any Travel Log backup can be, so it can't be imported. It may be damaged."))
    }

    @Test("concatenated gzip members read as one document, trailing bytes are ignored, a cut-off member is refused")
    func gzipMembers() throws {
        let directory = try HardeningFixture.scratchDirectory("BackupMembers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = HardeningFixture.document()
        let half = document.count / 2
        let first = directory.appendingPathComponent("a.gz")
        let second = directory.appendingPathComponent("b.gz")
        try HardeningFixture.gzip(document.prefix(half), to: first)
        try HardeningFixture.gzip(document.suffix(from: half), to: second)
        let joined = directory.appendingPathComponent("joined.travellogbackup")
        try (Data(contentsOf: first) + Data(contentsOf: second) + Data("trailing".utf8)).write(to: joined)
        #expect(try BackupFile.stagedContents(of: joined) == document)

        let cut = directory.appendingPathComponent("cut.travellogbackup")
        try Data(contentsOf: first).dropLast(9).write(to: cut)
        #expect(throws: TripDataImportError.notJSON) { try BackupFile.stagedContents(of: cut) }
    }

    // MARK: Structure

    @Test("duplicate ids keep their first entry, dangling references stay soft, and a re-import adds nothing")
    func duplicatesAndDanglingReferences() async throws {
        let document = try edited { root in
            let trips = root["trips"] as! NSMutableArray
            let copy = try! JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: trips[0]), options: [.mutableContainers])
            trips.add(copy)
            let visit = (root["visits"] as! NSMutableArray)[0] as! NSMutableDictionary
            visit["stayID"] = UUID().uuidString
            let hidden = (root["hiddenPhotos"] as! NSMutableArray)[0] as! NSMutableDictionary
            hidden["tripID"] = UUID().uuidString
            let override = (root["homeAreaOverrides"] as! NSMutableArray)[0] as! NSMutableDictionary
            override["homeID"] = UUID().uuidString
            let homes = root["homes"] as! NSMutableArray
            homes.add(homes[0])
        }
        let payload = try TripDataImporter.parse(document)
        let container = try TestSupport.makeInMemoryContainer()
        let queue = try HardeningFixture.scratchDirectory("BackupHardening")
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: container, queue: queue)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.skippedExistingTrips == 1)
        #expect(outcome.insertedHomes == 1)
        #expect(outcome.insertedVisits == 1)
        #expect(outcome.skippedPhotoChoices == 1)
        try expectSoundStore(container)
        let again = await importer.importTrips(from: payload)
        #expect(!again.saveFailed && again.insertedTrips == 0 && again.insertedStays == 0)
    }

    @Test("a preference of the wrong type or past its bound is left out alone; the others restore")
    func preferencesDecodeOneByOne() throws {
        let document = try edited { root in
            let preferences = root["preferences"] as! NSMutableDictionary
            preferences["tripsSortOrder"] = 42
            preferences["splitHintDismissed"] = "yes"
            preferences["tripFilters"] = String(repeating: "f", count: (1 << 20) + 1)
            preferences["dismissedFlightCandidates"] = ["ok", 7, String(repeating: "x", count: 2_000)]
            preferences["temporaryHomeEndHintDismissals"] = (0..<12_000).map { "hint-\($0)" }
        }
        let preferences = try TripDataImporter.parse(document).preferences
        #expect(preferences.tripsSortOrder == nil)
        #expect(preferences.splitHintDismissed == nil)
        #expect(preferences.tripFilters == nil)
        #expect(preferences.temperatureUnit == "celsius")
        #expect(preferences.dismissedFlightCandidates == ["ok"])
        #expect(preferences.temporaryHomeEndHintDismissals.count == 10_000)
        #expect(preferences.temporaryHomeEndHintDismissals.last == "hint-11999")
        #expect(preferences.temporaryHomeSuggestionDismissals == ["suggestion-a"])
        #expect(preferences.tripGapConfirmations == ["gap-a"])
    }

    @Test("deeply nested values and a key repeated inside a record never trap the reader")
    func nestingAndRepeatedKeys() throws {
        var text = String(decoding: HardeningFixture.document(), as: UTF8.self)
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        text = text.replacingOccurrences(of: "\"appVersion\":\"unknown\"", with: "\"appVersion\":\(deep)")
        if let brace = text.range(of: "{\"aiGeneratedSummary\"") {
            text.replaceSubrange(brace, with: "{\"startDate\":\"Infinity\",\"aiGeneratedSummary\"")
        }
        let deepStays = text.replacingOccurrences(of: "\"stays\":[", with: "\"stays\":[\(deep),")
        _ = try? TripDataImporter.parse(Data(text.utf8))
        _ = try? TripDataImporter.parse(Data(deepStays.utf8))
    }

    // MARK: Fuzzing

    private enum Mutation: CaseIterable {
        case typeSwap, extremeNumber, removeKey, duplicateElement, hugeString
        case truncate, bitFlip, repeatedKey, rawNumber
    }

    private static let extremes: [Any] = [
        1e308, -1e308, "Infinity", "-Infinity", "NaN", Int64.max, Int64.min, -1, 0,
        5e-324, 6.3e10, -6.3e10, 2_147_483_648, "2026-01-01T00:00:00Z", "", [Any](), [String: Any](),
    ]

    private static func swapped(_ value: Any) -> Any {
        switch value {
        case is String: return 1
        case is NSNumber: return "1"
        case is NSArray: return ["k": "v"]
        case is NSDictionary: return [1, 2]
        default: return true
        }
    }

    /// One mutation of the fixture's tree or text.
    private static func mutate(_ document: Data, _ mutation: Mutation, _ rng: inout SplitMix64) -> Data {
        switch mutation {
        case .truncate:
            return document.prefix(Int.random(in: 0..<document.count, using: &rng))
        case .bitFlip:
            var bytes = [UInt8](document)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let index = Int.random(in: 0..<bytes.count, using: &rng)
                bytes[index] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
            }
            return Data(bytes)
        case .repeatedKey:
            var bytes = [UInt8](document)
            let braces = bytes.indices.filter { bytes[$0] == UInt8(ascii: "{") }
            let key = ["\"id\":\"00000000-0000-0000-0000-000000000000\",", "\"startTime\":1e300,",
                       "\"endTime\":\"-Infinity\",", "\"stays\":7,", "\"timestamp\":null,"]
                .randomElement(using: &rng)!
            let at = braces.randomElement(using: &rng)! + 1
            bytes.insert(contentsOf: Array(key.utf8), at: at)
            return Data(bytes)
        case .rawNumber:
            var text = String(decoding: document, as: UTF8.self)
            let digits = text.ranges(of: /-?[0-9]+(\.[0-9]+)?/)
            guard let range = digits.randomElement(using: &rng) else { return document }
            text.replaceSubrange(range, with: ["1e999", "-1e999", "99999999999999999999999",
                                               "-0", "1e-999", "0x10"].randomElement(using: &rng)!)
            return Data(text.utf8)
        default:
            break
        }
        guard let root = try? JSONSerialization.jsonObject(
            with: document, options: [.mutableContainers]) as? NSMutableDictionary else { return document }
        var slots: [(container: AnyObject, key: Any)] = []
        func collect(_ node: Any) {
            if let dictionary = node as? NSMutableDictionary {
                for key in dictionary.allKeys {
                    slots.append((dictionary, key))
                    collect(dictionary[key]!)
                }
            } else if let array = node as? NSMutableArray {
                for index in 0..<array.count {
                    slots.append((array, index))
                    collect(array[index])
                }
            }
        }
        collect(root)
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            guard let (container, key) = slots.randomElement(using: &rng) else { break }
            let dictionary = container as? NSMutableDictionary
            let array = container as? NSMutableArray
            func current() -> Any? {
                if let dictionary { return dictionary[key] }
                if let array, let index = key as? Int, index < array.count { return array[index] }
                return nil
            }
            func set(_ value: Any) {
                if let dictionary { dictionary[key] = value }
                if let array, let index = key as? Int, index < array.count { array[index] = value }
            }
            switch mutation {
            case .typeSwap:
                if let value = current() { set(swapped(value)) }
            case .extremeNumber:
                set(extremes.randomElement(using: &rng)!)
            case .removeKey:
                if let dictionary { dictionary.removeObject(forKey: key) }
                if let array, let index = key as? Int, index < array.count { array.removeObject(at: index) }
            case .duplicateElement:
                if let array, let index = key as? Int, index < array.count {
                    array.insert(array[index], at: Int.random(in: 0...array.count, using: &rng))
                } else if let value = current() {
                    set([value, value])
                }
            case .hugeString:
                set(String(repeating: "Ω", count: [3_000, 300_000].randomElement(using: &rng)!))
            default:
                break
            }
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? document
    }

    @Test("thousands of mutations of a valid backup each import or throw, within a time and memory budget, and leave a sound store")
    func fuzzedBackupsNeverTrap() async throws {
        let document = HardeningFixture.document()
        var rng = SplitMix64(state: 0x5EED_BAC0)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let footprintBefore = HardeningFixture.footprint()
        var parsed = 0
        var refused = 0
        var imports = 0
        let queue = try HardeningFixture.scratchDirectory("BackupFuzz")
        defer { try? FileManager.default.removeItem(at: queue) }

        for round in 0..<3_000 {
            let mutation = Mutation.allCases[round % Mutation.allCases.count]
            let mutated = Self.mutate(document, mutation, &rng)
            let elapsed = clock.measure {
                guard let payload = try? TripDataImporter.parse(mutated) else {
                    refused += 1
                    return
                }
                parsed += 1
                // The pings are read in place, as preview and commit do.
                _ = try? payload.pings.forEachChunk { _, _ in }
            }
            #expect(elapsed < .seconds(2), "round \(round) (\(mutation)) took \(elapsed)")

            // Every 25th parsed file runs the whole preview and commit.
            if parsed % 25 == 1, imports < 100, let payload = try? TripDataImporter.parse(mutated) {
                imports += 1
                let container = try TestSupport.makeInMemoryContainer()
                let importer = await importer(for: container, queue: queue)
                if (try? await importer.preview(of: payload)) != nil {
                    _ = await importer.importTrips(from: payload)
                }
                try expectSoundStore(container)
            }
        }

        // The gzip layer: cut-off and flipped compressed files.
        let directory = try HardeningFixture.scratchDirectory("BackupFuzzGzip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gzipped = directory.appendingPathComponent("valid.gz")
        try HardeningFixture.gzip(document, to: gzipped)
        let compressed = try Data(contentsOf: gzipped)
        let target = directory.appendingPathComponent("mutated.travellogbackup")
        for round in 0..<300 {
            let mutated = Self.mutate(compressed, round.isMultiple(of: 2) ? .truncate : .bitFlip, &rng)
            try mutated.write(to: target)
            if let staged = try? BackupFile.stagedContents(of: target) {
                _ = try? TripDataImporter.parse(staged)
            }
        }

        print("Fuzz: \(parsed) parsed, \(refused) refused, \(imports) committed")
        #expect(parsed > 300 && refused > 300, "the mutations exercise both outcomes")
        #expect(clock.now - startedAt < .seconds(240))
        #expect(HardeningFixture.footprint() < footprintBefore + (400 << 20))
    }
}
