//
//  TripDataTemporaryHomeTests.swift
//  TravelLogTests
//
//  The backup (v15) and the import of temporary homes: every field survives
//  a round trip with its exact dates, a declaration-only backup is admitted,
//  an id already in the store wins over the file, malformed entries are
//  counted and skipped, and every restored declaration (or stay restored
//  under an existing one) has its reconciliation queued before the save that
//  makes it durable. Removals land monotonically and are never undone; a
//  stay's temporary-home provenance and a trip's keep flag travel with them.
//  A declaration carries its coverage revision and kept trips (the union over
//  its rows) and a stay its revision beside its provenance: kept trips merge
//  into a declaration the store keeps without ever dropping one, and an
//  imported stamp never claims a revision above the declaration the store
//  keeps.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("TripDataImporter temporary homes")
struct TripDataTemporaryHomeTests {

    private static let start = Date(timeIntervalSince1970: 1_689_718_400)
    private static let day: TimeInterval = 86_400
    private static let brussels = (lat: 50.8156, lon: 4.3427)
    private static let lisbon = (lat: 38.6859, lon: -9.1851)
    private static let kyoto = (lat: 35.0364, lon: 135.8267)

    // MARK: - Fixtures

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "TripDataTemporaryHomeTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// An importer whose reconciliation queue lives in `suite`, never in
    /// the test host's standard defaults.
    private func makeImporter(
        _ container: ModelContainer, queue suite: String
    ) async -> TripDataImporter {
        let importer = TripDataImporter(modelContainer: container)
        await importer.setReconciliationDefaultsSuiteForTesting(suite)
        return importer
    }

    private func queuedTemporaryHomeIDs(_ defaults: UserDefaults) -> Set<UUID> {
        Set(CoverageReconciliationQueue.pending(defaults: defaults)
            .filter { $0.kind == .temporaryHome }.map(\.id))
    }

    private func queueKey(_ id: UUID) -> String { "temporaryHome|\(id.uuidString)" }

    private func bits(_ date: Date?) -> UInt64? {
        date?.timeIntervalSinceReferenceDate.bitPattern
    }

    /// One completed trip holding one destination stay, `index` days after `start`.
    private func tripJSON(_ index: Int) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let begin = Self.start.addingTimeInterval(Double(index) * Self.day)
        let end = begin.addingTimeInterval(3_600)
        return [
            "id": UUID().uuidString,
            "startDate": iso.string(from: begin),
            "endDate": iso.string(from: end),
            "isComplete": true,
            "classifiedByAI": false,
            "stays": [[
                "id": UUID().uuidString,
                "startTime": iso.string(from: begin),
                "endTime": iso.string(from: end),
                "category": "destination",
                "latitude": Self.kyoto.lat,
                "longitude": Self.kyoto.lon,
            ]],
        ]
    }

    private func temporaryHomeJSON(
        id: UUID, label: String = "Erasmus",
        startedAt: Date, endedAt: Date? = nil, removedAt: Date? = nil,
        coverageRevision: Int? = nil, keptTripIDs: [UUID]? = nil
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var row: [String: Any] = [
            "id": id.uuidString,
            "label": label,
            "latitude": Self.brussels.lat,
            "longitude": Self.brussels.lon,
            "startedAt": iso.string(from: startedAt),
        ]
        if let endedAt { row["endedAt"] = iso.string(from: endedAt) }
        if let removedAt { row["removedAt"] = iso.string(from: removedAt) }
        if let coverageRevision { row["coverageRevision"] = coverageRevision }
        if let keptTripIDs { row["keptTripIDs"] = keptTripIDs.map(\.uuidString) }
        return row
    }

    /// One stay entry `day` days after `start`, at Brussels for a home stay
    /// and at Kyoto otherwise.
    private func stayJSON(
        day: Double, category: StayCategory, temporaryHomeID: UUID? = nil,
        temporaryHomeRevision: Int? = nil
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let begin = Self.start.addingTimeInterval(day * Self.day)
        let place = category == .home ? Self.brussels : Self.kyoto
        var row: [String: Any] = [
            "id": UUID().uuidString,
            "startTime": iso.string(from: begin),
            "endTime": iso.string(from: begin.addingTimeInterval(3_600)),
            "category": category.rawValue,
            "latitude": place.lat,
            "longitude": place.lon,
        ]
        if let temporaryHomeID { row["temporaryHomeID"] = temporaryHomeID.uuidString }
        if let temporaryHomeRevision { row["temporaryHomeRevision"] = temporaryHomeRevision }
        return row
    }

    /// A v15 payload from hand-written entries (`BackupFixture` fills them out).
    private func makePayload(
        trips: [[String: Any]] = [],
        temporaryHomes: [[String: Any]]? = nil,
        removedTemporaryHomes: [[String: Any]]? = nil,
        homeStays: [[String: Any]]? = nil,
        unassignedStays: [[String: Any]]? = nil
    ) throws -> ImportPayload {
        var root: [String: Any] = [
            "appVersion": "test",
            "trips": trips,
        ]
        if let temporaryHomes { root["temporaryHomes"] = temporaryHomes }
        if let removedTemporaryHomes { root["removedTemporaryHomes"] = removedTemporaryHomes }
        if let homeStays { root["homeStays"] = homeStays }
        if let unassignedStays { root["unassignedStays"] = unassignedStays }
        return try BackupFixture.parse(root)
    }

    private func snapshot(
        id: UUID = UUID(), label: String = "Erasmus",
        startedAt: Date, endedAt: Date? = nil
    ) -> ExportTemporaryHomeSnapshot {
        ExportTemporaryHomeSnapshot(
            id: id, label: label,
            latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            radiusKm: 25,
            locality: "Brussels", administrativeArea: nil,
            country: "Belgium", isoCountryCode: "BE",
            startedAt: startedAt, endedAt: endedAt,
            timeZoneIdentifier: "Europe/Brussels",
            createdAt: startedAt.addingTimeInterval(-Self.day),
            modifiedAt: startedAt.addingTimeInterval(-3_600))
    }

    private func seedTemporaryHome(
        in container: ModelContainer, id: UUID, label: String = "Erasmus",
        startedAt: Date, endedAt: Date? = nil
    ) throws {
        let context = ModelContext(container)
        let row = TemporaryHome(
            label: label, latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: startedAt, endedAt: endedAt)
        row.id = id
        context.insert(row)
        try context.save()
    }

    // MARK: - Export and round trip

    @Test("an open-ended, an ended, a future-dated and a removed temporary home keep every field through export and import into a fresh store, every date bit-exact; the removed one stays removed and a home stay keeps the temporary home that stamped it")
    func everyFieldSurvivesARoundTrip() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)

        let open = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: Date(timeIntervalSinceReferenceDate: 769_718_400.123456789))
        open.radiusKm = 12.5
        open.locality = "Brussels"
        open.administrativeArea = "Brussels-Capital"
        open.country = "Belgium"
        open.isoCountryCode = "BE"
        open.timeZoneIdentifier = "Europe/Brussels"
        open.createdAt = Date(timeIntervalSinceReferenceDate: 768_718_400.987654321)
        open.modifiedAt = Date(timeIntervalSinceReferenceDate: 769_218_400.555555555)

        // No label, place metadata or zone: the optional keys are left out.
        let ended = TemporaryHome(
            label: "", latitude: Self.lisbon.lat, longitude: Self.lisbon.lon,
            startedAt: Date(timeIntervalSinceReferenceDate: 689_718_400.25),
            endedAt: Date(timeIntervalSinceReferenceDate: 702_718_400.75))
        ended.createdAt = Date(timeIntervalSinceReferenceDate: 688_718_400.5)
        ended.modifiedAt = Date(timeIntervalSinceReferenceDate: 702_718_401.125)

        // Both dates lie decades ahead of any clock this test runs under.
        let future = TemporaryHome(
            label: "Sabbatical", latitude: Self.kyoto.lat, longitude: Self.kyoto.lon,
            startedAt: Date(timeIntervalSinceReferenceDate: 2_000_000_000.375),
            endedAt: Date(timeIntervalSinceReferenceDate: 2_010_000_000.625))
        future.timeZoneIdentifier = "Asia/Tokyo"
        future.createdAt = Date(timeIntervalSinceReferenceDate: 770_718_400.0625)
        future.modifiedAt = Date(timeIntervalSinceReferenceDate: 770_718_400.0625)
        let originals = [open, ended, future]
        for row in originals { context.insert(row) }

        // Removed: it travels apart from the live ones and lands removed.
        let gone = TemporaryHome(
            label: "Old flat", latitude: Self.lisbon.lat, longitude: Self.lisbon.lon,
            startedAt: Date(timeIntervalSinceReferenceDate: 639_718_400.5),
            endedAt: Date(timeIntervalSinceReferenceDate: 649_718_400.5))
        gone.locality = "Lisbon"
        gone.createdAt = Date(timeIntervalSinceReferenceDate: 638_718_400.125)
        gone.modifiedAt = Date(timeIntervalSinceReferenceDate: 703_718_400.25)
        gone.removedAt = Date(timeIntervalSinceReferenceDate: 703_718_400)
        context.insert(gone)

        // A home stay at the temporary home and a correction keyed to it
        // already travel in `homeStays` and `homeAreaOverrides`.
        let stayStart = open.startedAt.addingTimeInterval(10 * Self.day)
        let h3 = try #require(H3Service.cellIndex(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon))
        let homeStay = Stay(
            startTime: stayStart, endTime: stayStart.addingTimeInterval(8 * 3_600),
            centroidLatitude: Self.brussels.lat, centroidLongitude: Self.brussels.lon,
            h3IndexRes6: h3,
            pingCount: 3, distanceFromHomeKm: 0, pingIDs: [])
        homeStay.category = .home
        homeStay.temporaryHomeID = open.id
        context.insert(homeStay)
        context.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 50.8451, centerLongitude: 4.6915,
            radiusKm: 1, homeID: open.id))
        try context.save()

        let layer = try await ExportSnapshotter(modelContainer: source)
            .snapshotHomeAreaLayer()
        #expect(layer.temporaryHomes.map(\.id) == [ended, open, future].map(\.id),
                "era order")
        #expect(layer.removedTemporaryHomes.map(\.id) == [gone.id])
        #expect(layer.homeStays.map(\.id) == [homeStay.id])
        #expect(layer.overrides.map(\.homeID) == [open.id])

        let data = try await ExportSnapshotter(modelContainer: source).exportData()
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == TripDataExporter.formatVersion)
        let rows = try #require(root["temporaryHomes"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(!rows.contains { $0["id"] as? String == gone.id.uuidString })
        let removedRows = try #require(root["removedTemporaryHomes"] as? [[String: Any]])
        #expect(removedRows.count == 1)
        #expect(removedRows.first?["id"] as? String == gone.id.uuidString)
        #expect(removedRows.first?["removedAt"] as? Double
                == BackupFixture.stored(try #require(gone.removedAt)))
        let stayRows = try #require(root["homeStays"] as? [[String: Any]])
        #expect(stayRows.first?["temporaryHomeID"] as? String == open.id.uuidString)
        let openRow = try #require(rows.first { $0["id"] as? String == open.id.uuidString })
        #expect(openRow["endedAt"] == nil)
        #expect(openRow["timeZoneIdentifier"] as? String == "Europe/Brussels")
        // Dates are their stored reference-date numbers, fractions and all.
        #expect(openRow["startedAt"] as? Double == BackupFixture.stored(open.startedAt))
        #expect(openRow["createdAt"] as? Double == BackupFixture.stored(open.createdAt))
        #expect(openRow["modifiedAt"] as? Double == BackupFixture.stored(open.modifiedAt))
        let endedRow = try #require(rows.first { $0["id"] as? String == ended.id.uuidString })
        #expect(endedRow["endedAt"] as? Double
                == BackupFixture.stored(try #require(ended.endedAt)))
        #expect(endedRow["locality"] == nil)
        #expect(endedRow["timeZoneIdentifier"] == nil)

        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)
        #expect(payload.malformedTrips == 0)
        let restoredStore = try TestSupport.makeInMemoryContainer()
        let importer = await makeImporter(restoredStore, queue: suite)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 3)
        #expect(outcome.appliedTemporaryHomeRemovals == 1)
        #expect(outcome.insertedStays == 1)
        #expect(outcome.insertedOverrides == 1)
        #expect(outcome.stagedTemporaryHomeReconciliations == 4)
        #expect(queuedTemporaryHomeIDs(defaults) == Set((originals + [gone]).map(\.id)))

        let verification = ModelContext(restoredStore)
        let restored = try verification.fetch(FetchDescriptor<TemporaryHome>())
        #expect(restored.count == 4)
        #expect(Set(try HomeAnchors.temporaryHomes(in: verification).map(\.id))
                == Set(originals.map(\.id)))
        for original in originals + [gone] {
            let row = try #require(restored.first { $0.id == original.id })
            #expect(row.label == original.label)
            #expect(row.latitude == original.latitude)
            #expect(row.longitude == original.longitude)
            #expect(row.radiusKm == original.radiusKm)
            #expect(row.locality == original.locality)
            #expect(row.administrativeArea == original.administrativeArea)
            #expect(row.country == original.country)
            #expect(row.isoCountryCode == original.isoCountryCode)
            #expect(row.timeZoneIdentifier == original.timeZoneIdentifier)
            #expect(bits(row.startedAt) == bits(original.startedAt))
            #expect(bits(row.endedAt) == bits(original.endedAt))
            #expect(bits(row.createdAt) == bits(original.createdAt))
            #expect(bits(row.modifiedAt) == bits(original.modifiedAt))
            #expect(row.removedAt == original.removedAt)
        }
        #expect(try verification.fetch(FetchDescriptor<Stay>()).map(\.category) == [.home])
        #expect(try verification.fetch(FetchDescriptor<Stay>()).map(\.temporaryHomeID) == [open.id])
        #expect(try verification.fetch(FetchDescriptor<HomeAreaOverride>())
            .map(\.homeID) == [open.id])
    }

    @Test("a home stay that began in the same second as its temporary home, a fraction later, is still inside the dates and still counts as staying after export and import")
    func stayAtTheStartSecondSurvivesARestore() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        // Both lie inside one second: the declaration at .5, the stay at .75.
        let declared = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: Self.start.addingTimeInterval(0.5),
            endedAt: Self.start.addingTimeInterval(30 * Self.day + 0.25))
        context.insert(declared)
        let stayStart = Self.start.addingTimeInterval(0.75)
        let h3 = try #require(H3Service.cellIndex(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon))
        let homeStay = Stay(
            startTime: stayStart, endTime: stayStart.addingTimeInterval(4 * Self.day),
            centroidLatitude: Self.brussels.lat, centroidLongitude: Self.brussels.lon,
            h3IndexRes6: h3, pingCount: 3, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        homeStay.category = .home
        // Recorded by the declaration, as the classifier stamps it.
        homeStay.temporaryHomeID = declared.id
        context.insert(homeStay)
        try context.save()
        let now = Self.start.addingTimeInterval(60 * Self.day)
        let before = try TemporaryHomeLedger.result(
            travelling: [], container: source, now: now, fallbackZone: utc, checkCancellation: {})
        // 18 to 22 July 2023 in UTC.
        #expect(before.staying.count == 5)

        let layer = try await ExportSnapshotter(modelContainer: source)
            .snapshotHomeAreaLayer()
        let data = try #require(BackupFixture.buildExportData(
            snapshots: [], homeStays: layer.homeStays,
            temporaryHomes: layer.temporaryHomes, appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        let restoredStore = try TestSupport.makeInMemoryContainer()
        let outcome = await makeImporter(restoredStore, queue: suite)
            .importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 1)
        #expect(outcome.insertedStays == 1)

        let verification = ModelContext(restoredStore)
        let restoredHome = try #require(try verification.fetch(FetchDescriptor<TemporaryHome>()).first)
        let restoredStay = try #require(try verification.fetch(FetchDescriptor<Stay>()).first)
        #expect(restoredStay.category == .home)
        #expect(restoredStay.startTime >= restoredHome.startedAt)
        #expect(HomeAnchor(restoredHome).covers(restoredStay.startTime))
        let known = Set(try verification.fetch(FetchDescriptor<TemporaryHome>()).map(\.id))
        #expect(HomeAnchors.recordedOwner(
            temporaryHomeID: restoredStay.temporaryHomeID, knownTemporaryHomeIDs: known)
            == .temporary(declared.id))
        let after = try TemporaryHomeLedger.result(
            travelling: [], container: restoredStore, now: now, fallbackZone: utc,
            checkCancellation: {})
        #expect(after.staying == before.staying)
    }

    @Test("two rows with one id export once, as the row with the latest modifiedAt, whichever was inserted first")
    func sameIDTwinsExportOnce() async throws {
        for newerFirst in [true, false] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let id = UUID()
            let older = TemporaryHome(
                label: "Older", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: Self.start)
            older.id = id
            older.createdAt = Self.start
            older.modifiedAt = Self.start
            let newerEnd = Self.start.addingTimeInterval(90 * Self.day)
            let newer = TemporaryHome(
                label: "Newer", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: Self.start, endedAt: newerEnd)
            newer.id = id
            newer.createdAt = Self.start
            newer.modifiedAt = Self.start.addingTimeInterval(Self.day)
            for row in (newerFirst ? [newer, older] : [older, newer]) { context.insert(row) }
            try context.save()

            let layer = try await ExportSnapshotter(modelContainer: container)
                .snapshotHomeAreaLayer()
            #expect(layer.temporaryHomes.map(\.label) == ["Newer"])
            #expect(layer.temporaryHomes.first?.endedAt == newerEnd)
        }
    }

    @Test("an export from a store with no temporary home carries empty temporaryHomes and removedTemporaryHomes arrays")
    func exportWithoutTemporaryHomesWritesEmptyArrays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let layer = try await ExportSnapshotter(modelContainer: container)
            .snapshotHomeAreaLayer()
        #expect(layer.temporaryHomes.isEmpty)
        let data = try await ExportSnapshotter(modelContainer: container).exportData()
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        #expect((root["temporaryHomes"] as? [Any])?.isEmpty == true)
        #expect((root["removedTemporaryHomes"] as? [Any])?.isEmpty == true)
        let payload = try TripDataImporter.parse(data)
        #expect(payload.temporaryHomes.isEmpty)
        #expect(payload.removedTemporaryHomes.isEmpty)
    }

    // MARK: - Admission and idempotence

    @Test("a backup holding only new temporary homes is admitted and inserts them; importing it again inserts nothing and changes nothing")
    func declarationOnlyBackupIsAdmittedAndIdempotent() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let semester = snapshot(
            startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(150 * Self.day))
        let openEnded = snapshot(
            label: "", startedAt: Self.start.addingTimeInterval(400 * Self.day))
        let data = try #require(BackupFixture.buildExportData(
            snapshots: [], temporaryHomes: [semester, openEnded], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        let container = try TestSupport.makeInMemoryContainer()
        let importer = await makeImporter(container, queue: suite)

        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.newVisits == 0)
        #expect(preview.newHomeAreaRows == 2)
        #expect(preview.hasImportableContent)

        let first = await importer.importTrips(from: payload)
        #expect(!first.saveFailed)
        #expect(first.insertedTrips == 0)
        #expect(first.insertedStays == 0)
        #expect(first.insertedTemporaryHomes == 2)
        #expect(first.stagedTemporaryHomeReconciliations == 2)
        let queued = CoverageReconciliationQueue.pending(defaults: defaults)
        #expect(Set(queued.map(\.id)) == [semester.id, openEnded.id])
        #expect(queued.allSatisfy { $0.kind == .temporaryHome })

        let settled = try await importer.preview(of: payload)
        #expect(settled.newHomeAreaRows == 0)
        #expect(!settled.hasImportableContent)

        let second = await importer.importTrips(from: payload)
        #expect(!second.saveFailed)
        #expect(second.insertedTemporaryHomes == 0)
        #expect(second.stagedTemporaryHomeReconciliations == 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.count == 2)
        for original in [semester, openEnded] {
            let row = try #require(rows.first { $0.id == original.id })
            #expect(row.label == original.label)
            #expect(row.locality == original.locality)
            #expect(row.startedAt == original.startedAt)
            #expect(row.endedAt == original.endedAt)
            #expect(row.createdAt == original.createdAt)
            #expect(row.modifiedAt == original.modifiedAt)
        }
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == queued,
                "the first import's entries are untouched")
    }

    @Test("a temporary home already in the store keeps its label and dates when the file carries the same id with different ones")
    func existingIDWinsOverTheFile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        let storedEnd = Self.start.addingTimeInterval(120 * Self.day)
        try seedTemporaryHome(
            in: container, id: id, startedAt: Self.start, endedAt: storedEnd)
        let payload = try makePayload(temporaryHomes: [temporaryHomeJSON(
            id: id, label: "From the backup",
            startedAt: Self.start.addingTimeInterval(-30 * Self.day),
            endedAt: storedEnd.addingTimeInterval(30 * Self.day))])
        #expect(payload.temporaryHomes.count == 1)
        let importer = await makeImporter(container, queue: suite)

        let preview = try await importer.preview(of: payload)
        #expect(preview.newHomeAreaRows == 0)
        #expect(!preview.hasImportableContent)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.stagedTemporaryHomeReconciliations == 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.count == 1)
        #expect(rows.first?.label == "Erasmus")
        #expect(rows.first?.startedAt == Self.start)
        #expect(rows.first?.endedAt == storedEnd)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    // MARK: - Tolerant parse

    @Test("temporary homes missing an id or a start date, out of coordinate range or with a reversed era are counted and skipped; the rest of the file imports")
    func malformedTemporaryHomesAreSkippedAndCounted() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clampedID = UUID()
        let instantID = UUID()
        let json = """
        {
          "trips": [],
          "temporaryHomes": [
            { "latitude": 50.8156, "longitude": 4.3427,
              "startedAt": "2025-05-05T00:00:00Z" },
            { "id": "\(UUID().uuidString)", "latitude": 91.0, "longitude": 4.3427,
              "startedAt": "2025-05-05T00:00:00Z" },
            { "id": "\(UUID().uuidString)", "latitude": 50.8156, "longitude": 181,
              "startedAt": "2025-05-05T00:00:00Z" },
            { "id": "\(UUID().uuidString)", "latitude": 50.8156, "longitude": 4.3427,
              "startedAt": "2025-09-04T00:00:00Z", "endedAt": "2024-09-04T00:00:00Z" },
            { "id": "\(UUID().uuidString)", "latitude": 50.8156, "longitude": 4.3427 },
            { "id": "\(clampedID.uuidString)", "label": "Erasmus",
              "latitude": 50.8156, "longitude": 4.3427, "radiusKm": 99999,
              "startedAt": "2025-05-05T00:00:00Z",
              "somethingNewer": { "nested": true } },
            { "id": "\(instantID.uuidString)", "latitude": 50.8156, "longitude": 4.3427,
              "radiusKm": 0,
              "startedAt": "2025-05-05T00:00:00Z", "endedAt": "2025-05-05T00:00:00Z" }
          ]
        }
        """
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any])
        root["trips"] = [tripJSON(0)]
        let payload = try BackupFixture.parse(root)

        #expect(payload.temporaryHomes.map(\.id) == [clampedID, instantID])
        #expect(payload.malformedTrips == 5)
        let clamped = try #require(payload.temporaryHomes.first)
        #expect(clamped.label == "Erasmus", "an unknown key is ignored")
        #expect(clamped.radiusKm == 500, "the radius clamps like a Home's")
        let instant = try #require(payload.temporaryHomes.last)
        #expect(instant.label == "")
        #expect(instant.radiusKm == 0.1)
        #expect(instant.endedAt == instant.startedAt, "an end equal to the start is not reversed")

        let container = try TestSupport.makeInMemoryContainer()
        let importer = await makeImporter(container, queue: suite)
        let preview = try await importer.preview(of: payload)
        #expect(preview.malformedEntries == 5)
        #expect(preview.newTrips == 1)
        #expect(preview.newHomeAreaRows == 2)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 1)
        #expect(outcome.insertedTemporaryHomes == 2)
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(Set(try verification.fetch(FetchDescriptor<TemporaryHome>()).map(\.id))
                == [clampedID, instantID])
    }

    @Test("entries of the temporaryHomes array that are not objects are counted and skipped one by one, and the objects around them still import")
    func nonObjectEntriesAreSkippedOneByOne() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstID = UUID(), secondID = UUID()
        let entries: [Any] = [
            temporaryHomeJSON(id: firstID, startedAt: Self.start),
            NSNull(), "not an object", 7, [1, 2],
            temporaryHomeJSON(id: secondID, label: "Second",
                              startedAt: Self.start.addingTimeInterval(400 * Self.day)),
        ]
        let root: [String: Any] = [
            "trips": [[String: Any]](),
            "temporaryHomes": entries,
        ]
        let payload = try BackupFixture.parse(root)

        #expect(payload.temporaryHomes.map(\.id) == [firstID, secondID])
        #expect(payload.malformedTrips == 4)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = await makeImporter(container, queue: suite)
        let preview = try await importer.preview(of: payload)
        #expect(preview.malformedEntries == 4)
        #expect(preview.newHomeAreaRows == 2)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 2)
        #expect(Set(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).map(\.id))
                == [firstID, secondID])
        #expect(queuedTemporaryHomeIDs(defaults) == [firstID, secondID])
    }

    // MARK: - Removals, provenance and keeps

    @Test("a trip's keep flag and its members' provenance survive export and import; a trip without the flag writes false and a stay without provenance writes no key")
    func keepFlagAndProvenanceSurviveARoundTrip() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        let temporaryHomeID = UUID()
        func stay(_ day: Double, _ category: StayCategory) throws -> Stay {
            let begin = Self.start.addingTimeInterval(day * Self.day)
            let place = category == .home ? Self.brussels : Self.kyoto
            let row = Stay(
                startTime: begin, endTime: begin.addingTimeInterval(3_600),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: try #require(H3Service.cellIndex(latitude: place.lat, longitude: place.lon)),
                pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
            row.category = category
            context.insert(row)
            return row
        }
        let kept = Trip(startDate: Self.start)
        kept.endDate = Self.start.addingTimeInterval(2 * Self.day)
        kept.isComplete = true
        kept.userEdited = true
        kept.keptByTemporaryHome = true
        let plain = Trip(startDate: Self.start.addingTimeInterval(10 * Self.day))
        plain.endDate = Self.start.addingTimeInterval(11 * Self.day)
        plain.isComplete = true
        context.insert(kept)
        context.insert(plain)
        let base = try stay(0, .home)
        base.temporaryHomeID = temporaryHomeID
        base.trip = kept
        base.orderInTrip = 0
        let away = try stay(1, .destination)
        away.trip = kept
        away.orderInTrip = 1
        let elsewhere = try stay(10, .destination)
        elsewhere.trip = plain
        elsewhere.orderInTrip = 0
        try context.save()

        let data = try await ExportSnapshotter(modelContainer: source).exportData()
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        let trips = try #require(root["trips"] as? [[String: Any]])
        let keptRow = try #require(trips.first { $0["id"] as? String == kept.id.uuidString })
        let plainRow = try #require(trips.first { $0["id"] as? String == plain.id.uuidString })
        #expect(keptRow["keptByTemporaryHome"] as? Bool == true)
        #expect(plainRow["keptByTemporaryHome"] as? Bool == false)
        let keptStays = try #require(keptRow["stays"] as? [[String: Any]])
        #expect(keptStays.map { $0["temporaryHomeID"] as? String }
                == [temporaryHomeID.uuidString, nil])

        let restoredStore = try TestSupport.makeInMemoryContainer()
        let outcome = await makeImporter(restoredStore, queue: suite)
            .importTrips(from: try TripDataImporter.parse(data))
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 2)
        let verification = ModelContext(restoredStore)
        let restoredTrips = try verification.fetch(FetchDescriptor<Trip>())
        let restoredKept = try #require(restoredTrips.first { $0.id == kept.id })
        #expect(restoredKept.userEdited && restoredKept.keptByTemporaryHome)
        let restoredPlain = try #require(restoredTrips.first { $0.id == plain.id })
        #expect(!restoredPlain.keptByTemporaryHome)
        let stays = try verification.fetch(FetchDescriptor<Stay>())
        #expect(stays.first { $0.id == base.id }?.temporaryHomeID == temporaryHomeID)
        #expect(stays.first { $0.id == away.id }?.temporaryHomeID == nil)
        #expect(stays.first { $0.id == elsewhere.id }?.temporaryHomeID == nil)
    }

    @Test("only a stay that lands as a home stay takes provenance from the file, in a trip, among home stays or among unassigned ones; a keep flag never lands without the edit flag")
    func nonHomeStaysNeverTakeProvenanceFromTheFile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporaryHomeID = UUID()
        let member = stayJSON(day: 0, category: .home, temporaryHomeID: temporaryHomeID)
        let destination = stayJSON(day: 1, category: .destination, temporaryHomeID: temporaryHomeID)
        var trip = tripJSON(0)
        trip["stays"] = [member, destination]
        trip["userEdited"] = false
        trip["keptByTemporaryHome"] = true
        let homeStay = stayJSON(day: 5, category: .home, temporaryHomeID: temporaryHomeID)
        let routine = stayJSON(day: 6, category: .routine, temporaryHomeID: temporaryHomeID)
        let transit = stayJSON(day: 7, category: .transit, temporaryHomeID: temporaryHomeID)
        let payload = try makePayload(
            trips: [trip], homeStays: [homeStay, routine], unassignedStays: [transit])
        #expect(payload.trips.first?.keptByTemporaryHome == true)

        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await makeImporter(container, queue: suite).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedStays == 5)
        let verification = ModelContext(container)
        let restoredTrip = try #require(try verification.fetch(FetchDescriptor<Trip>()).first)
        #expect(!restoredTrip.userEdited)
        #expect(!restoredTrip.keptByTemporaryHome)
        let stays = try verification.fetch(FetchDescriptor<Stay>())
        func provenance(_ json: [String: Any]) -> UUID? {
            stays.first { $0.id.uuidString == json["id"] as? String }?.temporaryHomeID
        }
        #expect(provenance(member) == temporaryHomeID)
        #expect(provenance(homeStay) == temporaryHomeID)
        #expect(provenance(destination) == nil)
        #expect(provenance(routine) == nil)
        #expect(provenance(transit) == nil)
    }

    @Test("a removal in the file lands monotonically: an absent id becomes a removed row with the file's content, a live id has every row stamped with its content and modifiedAt kept, a removed id is left alone; the first two are admitted, counted and queued, and a second import changes nothing",
          arguments: ["absent", "live", "removed"])
    func aFileRemovalAppliesMonotonically(store: String) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        let fileEnd = Self.start.addingTimeInterval(150 * Self.day)
        let fileRemovedAt = Self.start.addingTimeInterval(200 * Self.day)
        let storedModifiedAt = Self.start.addingTimeInterval(5 * Self.day)
        let earlierRemoval = Self.start.addingTimeInterval(100 * Self.day)
        let seed = ModelContext(container)
        switch store {
        case "live":
            // Two devices' copies of one declaration.
            for label in ["Erasmus", "Twin"] {
                let row = TemporaryHome(
                    label: label, latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                    startedAt: Self.start)
                row.id = id
                row.modifiedAt = storedModifiedAt
                seed.insert(row)
            }
        case "removed":
            let row = TemporaryHome(
                label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: Self.start)
            row.id = id
            row.removedAt = earlierRemoval
            seed.insert(row)
        default:
            break
        }
        try seed.save()
        let payload = try makePayload(removedTemporaryHomes: [temporaryHomeJSON(
            id: id, label: "From the backup", startedAt: Self.start, endedAt: fileEnd,
            removedAt: fileRemovedAt)])
        #expect(payload.removedTemporaryHomes.map(\.id) == [id])
        #expect(payload.removedTemporaryHomes.first?.removedAt == fileRemovedAt)
        let importer = await makeImporter(container, queue: suite)
        let applies = store != "removed"

        let preview = try await importer.preview(of: payload)
        #expect(preview.newHomeAreaRows == (applies ? 1 : 0))
        #expect(preview.hasImportableContent == applies)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.appliedTemporaryHomeRemovals == (applies ? 1 : 0))
        #expect(outcome.stagedTemporaryHomeReconciliations == (applies ? 1 : 0))
        #expect(queuedTemporaryHomeIDs(defaults) == (applies ? [id] : []))

        let verification = ModelContext(container)
        let rows = try verification.fetch(FetchDescriptor<TemporaryHome>())
        #expect(try HomeAnchors.temporaryHomes(in: verification).isEmpty)
        switch store {
        case "absent":
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.id == id)
            #expect(row.label == "From the backup")
            #expect(row.startedAt == Self.start)
            #expect(row.endedAt == fileEnd)
            #expect(row.removedAt == fileRemovedAt)
        case "live":
            #expect(rows.count == 2)
            #expect(Set(rows.map(\.label)) == ["Erasmus", "Twin"])
            #expect(rows.allSatisfy {
                $0.removedAt == fileRemovedAt && $0.modifiedAt == storedModifiedAt
                    && $0.endedAt == nil
            })
        default:
            #expect(rows.count == 1)
            #expect(rows.first?.removedAt == earlierRemoval)
        }

        let again = await importer.importTrips(from: payload)
        #expect(!again.saveFailed)
        #expect(again.appliedTemporaryHomeRemovals == 0)
        #expect(again.stagedTemporaryHomeReconciliations == 0)
        let settled = try await importer.preview(of: payload)
        #expect(!settled.hasImportableContent)
    }

    @Test("a live entry never brings back a removed id: one the store holds removed is skipped, and one the same file also removes lands removed")
    func aLiveEntryNeverResurrectsARemovedID() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let removedAt = Self.start.addingTimeInterval(100 * Self.day)

        // Removed in the store; a backup made before the removal.
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        let seed = ModelContext(container)
        let tombstone = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: Self.start)
        tombstone.id = id
        tombstone.removedAt = removedAt
        seed.insert(tombstone)
        try seed.save()
        let before = try makePayload(temporaryHomes: [temporaryHomeJSON(
            id: id, label: "From the backup", startedAt: Self.start)])
        let importer = await makeImporter(container, queue: suite)
        let skipped = try await importer.preview(of: before)
        #expect(skipped.newHomeAreaRows == 0)
        let outcome = await importer.importTrips(from: before)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.stagedTemporaryHomeReconciliations == 0)
        let rows = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.count == 1)
        #expect(rows.first?.removedAt == removedAt)
        #expect(rows.first?.label == "Erasmus")
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        // Live and removed in one file, the id absent from the store.
        let fresh = try TestSupport.makeInMemoryContainer()
        let other = UUID()
        let both = try makePayload(
            temporaryHomes: [temporaryHomeJSON(id: other, label: "Live", startedAt: Self.start)],
            removedTemporaryHomes: [temporaryHomeJSON(
                id: other, label: "Removed", startedAt: Self.start, removedAt: removedAt)])
        let freshImporter = await makeImporter(fresh, queue: suite)
        let admitted = try await freshImporter.preview(of: both)
        #expect(admitted.newHomeAreaRows == 1)
        let landed = await freshImporter.importTrips(from: both)
        #expect(!landed.saveFailed)
        #expect(landed.insertedTemporaryHomes == 0)
        #expect(landed.appliedTemporaryHomeRemovals == 1)
        let freshRows = try ModelContext(fresh).fetch(FetchDescriptor<TemporaryHome>())
        #expect(freshRows.count == 1)
        #expect(freshRows.first?.label == "Removed")
        #expect(freshRows.first?.removedAt == removedAt)
        #expect(try HomeAnchors.temporaryHomes(in: ModelContext(fresh)).isEmpty)
    }

    // MARK: - Revisions and kept trips

    @Test("a declaration's coverage revision and the kept trips of all its rows, a removed one's too, and a home stay's revision beside its provenance survive export and import; a stamp without a revision writes no key")
    func revisionsAndKeptTripsSurviveARoundTrip() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        let id = UUID()
        let keptOnWinner = UUID(), keptOnTwin = UUID(), keptOnRemoved = UUID()
        // Two devices' copies of one declaration: the later edit wins the
        // content, and each copy holds a keep the other lacks.
        let winner = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: Self.start)
        winner.id = id
        winner.modifiedAt = Self.start.addingTimeInterval(2 * Self.day)
        winner.coverageRevision = 5
        winner.addKeptTrip(keptOnWinner)
        let twin = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: Self.start)
        twin.id = id
        twin.modifiedAt = Self.start.addingTimeInterval(Self.day)
        twin.coverageRevision = 4
        twin.addKeptTrip(keptOnTwin)
        let gone = TemporaryHome(
            label: "Old flat", latitude: Self.lisbon.lat, longitude: Self.lisbon.lon,
            startedAt: Self.start.addingTimeInterval(-400 * Self.day),
            endedAt: Self.start.addingTimeInterval(-300 * Self.day))
        gone.coverageRevision = 2
        gone.addKeptTrip(keptOnRemoved)
        gone.removedAt = Self.start.addingTimeInterval(-200 * Self.day)
        for row in [winner, twin, gone] { context.insert(row) }
        let h3 = try #require(H3Service.cellIndex(
            latitude: Self.brussels.lat, longitude: Self.brussels.lon))
        func homeStay(_ day: Double, revision: Int?) -> Stay {
            let begin = Self.start.addingTimeInterval(day * Self.day)
            let row = Stay(
                startTime: begin, endTime: begin.addingTimeInterval(8 * 3_600),
                centroidLatitude: Self.brussels.lat, centroidLongitude: Self.brussels.lon,
                h3IndexRes6: h3, pingCount: 3, distanceFromHomeKm: 0, pingIDs: [])
            row.category = .home
            row.setTemporaryHomeProvenance(id, revision: revision)
            context.insert(row)
            return row
        }
        let stamped = homeStay(3, revision: 5)
        let legacy = homeStay(4, revision: nil)
        // A trip member stamped home travels in the trip's own stays.
        let trip = Trip(startDate: Self.start.addingTimeInterval(5 * Self.day))
        trip.endDate = Self.start.addingTimeInterval(6 * Self.day)
        trip.isComplete = true
        context.insert(trip)
        let member = homeStay(5, revision: 4)
        member.trip = trip
        member.orderInTrip = 0
        try context.save()

        let snapshotter = ExportSnapshotter(modelContainer: source)
        let layer = try await snapshotter.snapshotHomeAreaLayer()
        let trips = try await snapshotter.snapshotTrips()
        #expect(layer.temporaryHomes.map(\.coverageRevision) == [5])
        // The union of both rows' keeps, in uuidString order.
        #expect(layer.temporaryHomes.map(\.keptTripIDs)
                == [[keptOnWinner, keptOnTwin].sorted { $0.uuidString < $1.uuidString }] as [[UUID]])
        #expect(layer.removedTemporaryHomes.map(\.coverageRevision) == [2])
        let data = try #require(BackupFixture.buildExportData(
            snapshots: trips, homeStays: layer.homeStays,
            temporaryHomes: layer.temporaryHomes,
            removedTemporaryHomes: layer.removedTemporaryHomes, appVersion: "test"))
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == TripDataExporter.formatVersion)
        let live = try #require((root["temporaryHomes"] as? [[String: Any]])?.first)
        #expect(live["coverageRevision"] as? Int == 5)
        #expect(live["keptTripIDs"] as? [String]
                == [keptOnWinner, keptOnTwin].map(\.uuidString).sorted())
        let removed = try #require((root["removedTemporaryHomes"] as? [[String: Any]])?.first)
        #expect(removed["coverageRevision"] as? Int == 2)
        #expect(removed["keptTripIDs"] as? [String] == [keptOnRemoved.uuidString])
        let stayRows = try #require(root["homeStays"] as? [[String: Any]])
        #expect(stayRows.map { $0["temporaryHomeRevision"] as? Int } == [5, nil])
        #expect(stayRows.allSatisfy { $0["temporaryHomeID"] as? String == id.uuidString })
        let tripStays = try #require((root["trips"] as? [[String: Any]])?.first?["stays"]
            as? [[String: Any]])
        #expect(tripStays.map { $0["temporaryHomeRevision"] as? Int } == [4])

        let restoredStore = try TestSupport.makeInMemoryContainer()
        let outcome = await makeImporter(restoredStore, queue: suite)
            .importTrips(from: try TripDataImporter.parse(data))
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 1)
        #expect(outcome.appliedTemporaryHomeRemovals == 1)
        let verification = ModelContext(restoredStore)
        let rows = try verification.fetch(FetchDescriptor<TemporaryHome>())
        let restored = try #require(rows.first { $0.id == id })
        #expect(restored.coverageRevision == 5)
        #expect(restored.keptTripIDSet == [keptOnWinner, keptOnTwin])
        let restoredGone = try #require(rows.first { $0.id == gone.id })
        #expect(restoredGone.coverageRevision == 2)
        #expect(restoredGone.keptTripIDSet == [keptOnRemoved])
        let stays = try verification.fetch(FetchDescriptor<Stay>())
        func pair(_ stay: Stay) -> (UUID?, Int?)? {
            stays.first { $0.id == stay.id }.map { ($0.temporaryHomeID, $0.temporaryHomeRevision) }
        }
        #expect(pair(stamped)?.0 == id)
        #expect(pair(stamped)?.1 == 5)
        #expect(pair(legacy)?.0 == id)
        #expect(pair(legacy)?.1 == nil)
        #expect(pair(member)?.0 == id)
        #expect(pair(member)?.1 == 4)
    }

    @Test("an imported stamp never claims a revision above the declaration the store keeps: the store's winning row when it holds the id, the file's entry when the file brings it; a stamp without a revision, an id neither holds and a stay that is not home are left as the provenance rule says")
    func importedStampsAreClampedToTheKeptDeclaration() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let seed = ModelContext(container)
        let kept = UUID(), brought = UUID(), removed = UUID(), unknown = UUID()
        // The store's copies of `kept`: readers resolve to the later edit, at
        // revision 2, whatever the other copy's revision.
        for (revision, modifiedDay) in [(2, 3.0), (6, 1.0)] {
            let row = TemporaryHome(
                label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: Self.start)
            row.id = kept
            row.coverageRevision = revision
            row.modifiedAt = Self.start.addingTimeInterval(modifiedDay * Self.day)
            seed.insert(row)
        }
        let tombstone = TemporaryHome(
            label: "Old flat", latitude: Self.lisbon.lat, longitude: Self.lisbon.lon,
            startedAt: Self.start)
        tombstone.id = removed
        tombstone.coverageRevision = 3
        tombstone.removedAt = Self.start.addingTimeInterval(Self.day)
        seed.insert(tombstone)
        try seed.save()

        let stays: [(json: [String: Any], id: UUID?, revision: Int?)] = [
            (stayJSON(day: 1, category: .home, temporaryHomeID: kept, temporaryHomeRevision: 9), kept, 2),
            (stayJSON(day: 2, category: .home, temporaryHomeID: kept, temporaryHomeRevision: 1), kept, 1),
            (stayJSON(day: 3, category: .home, temporaryHomeID: kept), kept, nil),
            (stayJSON(day: 4, category: .home, temporaryHomeID: brought, temporaryHomeRevision: 4), brought, 4),
            (stayJSON(day: 5, category: .home, temporaryHomeID: brought, temporaryHomeRevision: 7), brought, 4),
            (stayJSON(day: 6, category: .home, temporaryHomeID: removed, temporaryHomeRevision: 5), removed, 3),
            (stayJSON(day: 7, category: .home, temporaryHomeID: unknown, temporaryHomeRevision: 8), unknown, 8),
            (stayJSON(day: 8, category: .destination, temporaryHomeID: kept, temporaryHomeRevision: 9), nil, nil),
        ]
        var trip = tripJSON(0)
        trip["stays"] = [stays[0].json, stays[7].json]
        let payload = try makePayload(
            trips: [trip],
            temporaryHomes: [
                // Rejected: the store holds this id.
                temporaryHomeJSON(id: kept, label: "From the backup", startedAt: Self.start,
                                  coverageRevision: 9),
                temporaryHomeJSON(id: brought, startedAt: Self.start, coverageRevision: 4),
            ],
            homeStays: stays[1...6].map { $0.json })

        let outcome = await makeImporter(container, queue: suite).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedStays == stays.count)
        #expect(outcome.insertedTemporaryHomes == 1)
        let verification = ModelContext(container)
        let restored = try verification.fetch(FetchDescriptor<Stay>())
        for (json, id, revision) in stays {
            let stay = try #require(restored.first { $0.id.uuidString == json["id"] as? String })
            #expect(stay.temporaryHomeID == id, "\(json)")
            #expect(stay.temporaryHomeRevision == revision, "\(json)")
        }
        // The store's declaration and its revisions are untouched.
        let rows = try verification.fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.filter { $0.id == kept }.map(\.coverageRevision).sorted() == [2, 6])
        #expect(rows.filter { $0.id == kept }.allSatisfy { $0.label == "Erasmus" })
        #expect(rows.first { $0.id == brought }?.coverageRevision == 4)
    }

    @Test("a file's huge coverage revision and stamp revisions read capped at a billion, so the next coverage change on the restored declaration still counts up")
    func hugeImportedRevisionsAreCapped() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cap = 1_000_000_000
        let id = UUID(), unknown = UUID()
        let payload = try makePayload(
            temporaryHomes: [temporaryHomeJSON(
                id: id, startedAt: Self.start, coverageRevision: Int.max)],
            homeStays: [
                stayJSON(day: 1, category: .home, temporaryHomeID: id,
                         temporaryHomeRevision: Int.max),
                stayJSON(day: 2, category: .home, temporaryHomeID: unknown,
                         temporaryHomeRevision: Int.max),
            ])
        #expect(payload.temporaryHomes.map(\.coverageRevision) == [cap])
        #expect(payload.homeStays.map(\.temporaryHomeRevision) == [cap, cap])

        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await makeImporter(container, queue: suite).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 1)
        let verification = ModelContext(container)
        let stays = try verification.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        #expect(stays.allSatisfy { $0.temporaryHomeRevision == cap })
        let rows = try verification.fetch(FetchDescriptor<TemporaryHome>())
        // An uncapped revision would trap in the sum below.
        try #require(rows.map(\.coverageRevision) == [cap])
        #expect(TemporaryHome.nextCoverageRevision(of: rows) == cap + 1)
    }

    @Test("when the store's declaration wins, the file's kept trips join every row of it and none is dropped; it is admitted and queued once, a removed declaration takes none, and importing again changes nothing")
    func keptTripsMergeMonotonically() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let seed = ModelContext(container)
        let id = UUID(), removedID = UUID()
        let onPhone = UUID(), onTablet = UUID(), inBackup = UUID(), onRemoved = UUID()
        let storedModifiedAt = Self.start.addingTimeInterval(Self.day)
        for keptTrip in [onPhone, onTablet] {
            let row = TemporaryHome(
                label: "Erasmus", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                startedAt: Self.start)
            row.id = id
            row.modifiedAt = storedModifiedAt
            row.coverageRevision = 3
            row.addKeptTrip(keptTrip)
            seed.insert(row)
        }
        let tombstone = TemporaryHome(
            label: "Old flat", latitude: Self.lisbon.lat, longitude: Self.lisbon.lon,
            startedAt: Self.start)
        tombstone.id = removedID
        tombstone.removedAt = Self.start.addingTimeInterval(Self.day)
        seed.insert(tombstone)
        try seed.save()

        // The backup lacks the phone's keep and holds one the store lacks.
        let payload = try makePayload(temporaryHomes: [
            temporaryHomeJSON(
                id: id, label: "From the backup", startedAt: Self.start,
                coverageRevision: 7, keptTripIDs: [onTablet, inBackup]),
            temporaryHomeJSON(id: removedID, startedAt: Self.start, keptTripIDs: [onRemoved]),
        ])
        let importer = await makeImporter(container, queue: suite)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newHomeAreaRows == 1, "the kept trip the store lacks is news")
        #expect(preview.hasImportableContent)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.stagedTemporaryHomeReconciliations == 1)
        #expect(queuedTemporaryHomeIDs(defaults) == [id])

        let verification = ModelContext(container)
        let rows = try verification.fetch(FetchDescriptor<TemporaryHome>())
        let merged = rows.filter { $0.id == id }
        #expect(merged.count == 2)
        #expect(TemporaryHome.keptTripIDs(of: merged) == [onPhone, onTablet, inBackup])
        #expect(merged.allSatisfy { $0.keptTripIDSet.contains(inBackup) })
        #expect(merged.allSatisfy {
            $0.label == "Erasmus" && $0.coverageRevision == 3
                && $0.modifiedAt == storedModifiedAt
        }, "only the kept trips change")
        #expect(rows.first { $0.id == removedID }?.keptTripIDs.isEmpty == true)

        // Nothing new the second time; a file that lacks a keep drops none.
        let settled = try await importer.preview(of: payload)
        #expect(!settled.hasImportableContent)
        let again = await importer.importTrips(from: payload)
        #expect(!again.saveFailed)
        #expect(again.stagedTemporaryHomeReconciliations == 0)
        let lacking = try makePayload(temporaryHomes: [temporaryHomeJSON(
            id: id, startedAt: Self.start, keptTripIDs: [])])
        _ = await importer.importTrips(from: lacking)
        let after = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
            .filter { $0.id == id }
        #expect(TemporaryHome.keptTripIDs(of: after) == [onPhone, onTablet, inBackup])
    }

    // Previously only the first entry's kept trips landed.
    @Test("a file holding two live entries for one declaration the store lacks lands it once with the kept trips of both, in either order; importing it again changes nothing",
          arguments: [false, true])
    func duplicateEntriesLandEveryKeptTrip(reversed: Bool) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID(), onPhone = UUID(), onTablet = UUID()
        var entries = [
            temporaryHomeJSON(id: id, startedAt: Self.start, coverageRevision: 2,
                              keptTripIDs: [onPhone]),
            temporaryHomeJSON(id: id, startedAt: Self.start, coverageRevision: 2,
                              keptTripIDs: [onTablet]),
        ]
        if reversed { entries.reverse() }
        let payload = try makePayload(temporaryHomes: entries)
        let importer = await makeImporter(container, queue: suite)

        let first = await importer.importTrips(from: payload)
        #expect(!first.saveFailed)
        #expect(first.insertedTemporaryHomes == 1)
        let landed = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(landed.count == 1)
        #expect(landed.first?.keptTripIDSet == [onPhone, onTablet])
        let stored = try #require(landed.first?.keptTripIDs)

        let second = await importer.importTrips(from: payload)
        #expect(!second.saveFailed)
        #expect(second.insertedTemporaryHomes == 0)
        let again = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(again.count == 1)
        #expect(again.first?.keptTripIDs == stored)
    }

    @Test("a stamp a backup restores is clamped to the declaration the store keeps before the checkpoint save that persists it, so a failed final save leaves none above it, and the retry clamps the rest")
    func stampsAreClampedBeforeEveryCheckpoint() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        try seedTemporaryHome(in: container, id: id, startedAt: Self.start)
        let seed = ModelContext(container)
        for row in try seed.fetch(FetchDescriptor<TemporaryHome>()) { row.coverageRevision = 2 }
        try seed.save()
        // 26 trips, each holding one home stay the backup's copy at revision 9 stamped.
        let trips: [[String: Any]] = (0..<26).map { index in
            var trip = tripJSON(index)
            trip["stays"] = [stayJSON(day: Double(index), category: .home,
                                      temporaryHomeID: id, temporaryHomeRevision: 9)]
            return trip
        }
        let payload = try makePayload(
            trips: trips,
            temporaryHomes: [temporaryHomeJSON(id: id, startedAt: Self.start, coverageRevision: 9)],
            homeStays: [stayJSON(day: 30, category: .home,
                                 temporaryHomeID: id, temporaryHomeRevision: 9)])
        let importer = await makeImporter(container, queue: suite)
        func revisions() throws -> [Int?] {
            try ModelContext(container).fetch(FetchDescriptor<Stay>()).map(\.temporaryHomeRevision)
        }

        // Save 1 is the 25-trip checkpoint; save 2, the final transaction, fails.
        await importer.failSaveCallForTesting(2)
        let failed = await importer.importTrips(from: payload)
        #expect(failed.saveFailed)
        #expect(failed.insertedTrips == 25)
        #expect(try revisions() == Array(repeating: 2, count: 25))

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(try revisions() == Array(repeating: 2, count: 27))
        let rows = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.map(\.coverageRevision) == [2])
    }

    @Test("a removal the backup brings for a declaration the store holds live lands, the newer stamps it brings are clamped to the store's copy, and the removal's unit frees them all the same")
    func importedRemovalIsTerminalForNewerStamps() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        try seedTemporaryHome(in: container, id: id, startedAt: Self.start)
        let seed = ModelContext(container)
        for row in try seed.fetch(FetchDescriptor<TemporaryHome>()) { row.coverageRevision = 2 }
        try seed.save()
        let payload = try makePayload(
            removedTemporaryHomes: [temporaryHomeJSON(
                id: id, startedAt: Self.start,
                removedAt: Self.start.addingTimeInterval(10 * Self.day), coverageRevision: 3)],
            homeStays: [stayJSON(day: 5, category: .home,
                                 temporaryHomeID: id, temporaryHomeRevision: 9)])

        let outcome = await makeImporter(container, queue: suite).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.appliedTemporaryHomeRemovals == 1)
        #expect(queuedTemporaryHomeIDs(defaults) == [id])
        let restored = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(restored.temporaryHomeRevision == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
            .allSatisfy { $0.removedAt != nil })

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: [])
                == .committed(stamped: 0, freed: 1, rebuiltTrips: 0, protectedTrips: 0))
        let freed = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(freed.category == .unclassified)
        #expect(freed.temporaryHomeID == nil)
        #expect(freed.temporaryHomeRevision == nil)
    }

    // MARK: - Reconciliation debt

    @Test("an inserted temporary home lands with the first checkpoint, queued before it: when that save fails the entry is withdrawn and nothing lands; when the final save fails the declaration, its entry and the checkpointed trips stay, and the retry inserts it no second time")
    func failedFinalSaveWithdrawsInsertedDebt() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let homeID = UUID()
        let payload = try makePayload(
            trips: (0..<26).map { tripJSON($0) },
            temporaryHomes: [temporaryHomeJSON(id: homeID, startedAt: Self.start)])
        let importer = await makeImporter(container, queue: suite)
        // Save 1 is the 25-trip checkpoint, which also holds the temporary
        // home; save 2 is the final transaction.
        await importer.failSaveCallForTesting(1)

        let failedCheckpoint = await importer.importTrips(from: payload)
        #expect(failedCheckpoint.saveFailed)
        #expect(failedCheckpoint.insertedTrips == 0)
        #expect(failedCheckpoint.insertedTemporaryHomes == 0)
        #expect(failedCheckpoint.stagedTemporaryHomeReconciliations == 0)
        let queuedAtSave = await importer.queuedReconciliationKeysAtFailedSaveForTesting
        #expect(queuedAtSave == [queueKey(homeID)])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        let afterCheckpoint = ModelContext(container)
        #expect(try afterCheckpoint.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try afterCheckpoint.fetchCount(FetchDescriptor<TemporaryHome>()) == 0)

        await importer.failSaveCallForTesting(2)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 25)
        #expect(outcome.insertedTemporaryHomes == 1)
        #expect(outcome.stagedTemporaryHomeReconciliations == 1)
        #expect(queuedTemporaryHomeIDs(defaults) == [homeID])
        let afterFailure = ModelContext(container)
        #expect(try afterFailure.fetchCount(FetchDescriptor<Trip>()) == 25)
        #expect(try afterFailure.fetch(FetchDescriptor<TemporaryHome>()).map(\.id) == [homeID])

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedTrips == 1)
        #expect(retry.insertedTemporaryHomes == 0)
        #expect(retry.stagedTemporaryHomeReconciliations == 1)
        #expect(queuedTemporaryHomeIDs(defaults) == [homeID])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
            .map(\.id) == [homeID])
    }

    @Test("a kept trip and its declaration's keep choice land in the same checkpoint: after a failed final save the reconciliation that checkpoint queued keeps the trip whole, and a retry leaves its identity, members and keep as they are")
    func keepChoicesLandWithTheirTripsCheckpoint() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let id = UUID()
        try seedTemporaryHome(in: container, id: id, startedAt: Self.start)
        // Trip 0 holds a stay at the base, so the declaration's covering
        // would split it; the user kept it whole on the other device.
        let iso = ISO8601DateFormatter()
        var kept = tripJSON(0)
        let keptID = try #require((kept["id"] as? String).flatMap(UUID.init(uuidString:)))
        var atBase = stayJSON(day: 0.2, category: .destination)
        atBase["latitude"] = Self.brussels.lat
        atBase["longitude"] = Self.brussels.lon
        let away = stayJSON(day: 0.6, category: .destination)
        kept["stays"] = [atBase, away]
        kept["endDate"] = iso.string(from: Self.start.addingTimeInterval(0.6 * Self.day + 3_600))
        kept["userEdited"] = true
        kept["customName"] = "Term kept whole"
        let memberIDs = try [atBase, away].map {
            try #require(($0["id"] as? String).flatMap(UUID.init(uuidString:)))
        }
        let payload = try makePayload(
            trips: [kept] + (1..<26).map { tripJSON($0) },
            temporaryHomes: [temporaryHomeJSON(id: id, startedAt: Self.start, keptTripIDs: [keptID])])
        let importer = await makeImporter(container, queue: suite)
        func keptTrips() throws -> Set<UUID> {
            TemporaryHome.keptTripIDs(of: try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()))
        }
        func members() throws -> [UUID] {
            let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
                .filter { $0.id == keptID }
            try #require(rows.count == 1)
            #expect(rows[0].customName == "Term kept whole")
            return rows[0].orderedStays.map(\.id)
        }

        // Save 1 is the 25-trip checkpoint; save 2, the final transaction, fails.
        await importer.failSaveCallForTesting(2)
        let failed = await importer.importTrips(from: payload)
        #expect(failed.saveFailed)
        #expect(failed.insertedTrips == 25)
        #expect(try keptTrips() == [keptID])
        #expect(queuedTemporaryHomeIDs(defaults) == [id])

        // The drain runs the queued unit before the user retries.
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: id, pinnedTripIDs: [])
            .isSettled)
        #expect(try members() == memberIDs)

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(try members() == memberIDs)
        #expect(try keptTrips() == [keptID])
    }

    @Test("a failed save puts back the entry an earlier edit of the same temporary home still owes")
    func failedSaveRestoresEarlierDebt() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let homeID = UUID()
        let earlier = CoverageReconciliationQueue.enqueue(
            .temporaryHome, id: homeID, defaults: defaults)
        let payload = try makePayload(
            temporaryHomes: [temporaryHomeJSON(id: homeID, startedAt: Self.start)])
        let importer = await makeImporter(container, queue: suite)
        await importer.failSaveCallForTesting(1)

        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])
    }

    @Test("importing stays into a store that already has a temporary home queues that home once; importing the file again queues nothing")
    func restoredStaysQueueExistingTemporaryHomes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let homeID = UUID()
        // Two physical rows with one id, as two devices importing one backup leave.
        try seedTemporaryHome(in: container, id: homeID, startedAt: Self.start)
        try seedTemporaryHome(in: container, id: homeID, startedAt: Self.start)
        let payload = try makePayload(trips: [tripJSON(0)])
        let importer = await makeImporter(container, queue: suite)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedStays == 1)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.stagedTemporaryHomeReconciliations == 1)
        let queued = CoverageReconciliationQueue.pending(defaults: defaults)
        #expect(queued.map(\.id) == [homeID])
        #expect(queued.map(\.kind) == [.temporaryHome])

        let again = await importer.importTrips(from: payload)
        #expect(again.insertedStays == 0)
        #expect(again.stagedTemporaryHomeReconciliations == 0)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == queued)
    }

    @Test("a declaration-only import queues the temporary home it inserts and not the one already in the store")
    func declarationOnlyImportLeavesExistingHomesAlone() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        try seedTemporaryHome(in: container, id: UUID(), startedAt: Self.start)
        let insertedID = UUID()
        let payload = try makePayload(temporaryHomes: [temporaryHomeJSON(
            id: insertedID, startedAt: Self.start.addingTimeInterval(400 * Self.day))])

        let outcome = await makeImporter(container, queue: suite)
            .importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTemporaryHomes == 1)
        #expect(outcome.stagedTemporaryHomeReconciliations == 1)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).map(\.id) == [insertedID])
    }

    @Test("stays restored at a checkpoint queue the temporary home already in the store before that save: a failed checkpoint withdraws the entry, a later failure keeps it")
    func checkpointedStaysQueueExistingTemporaryHomes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let homeID = UUID()
        try seedTemporaryHome(in: container, id: homeID, startedAt: Self.start)
        let payload = try makePayload(trips: (0..<26).map { tripJSON($0) })
        let importer = await makeImporter(container, queue: suite)

        await importer.failSaveCallForTesting(1)
        let failedCheckpoint = await importer.importTrips(from: payload)
        #expect(failedCheckpoint.saveFailed)
        #expect(failedCheckpoint.insertedStays == 0)
        let queuedAtCheckpoint = await importer.queuedReconciliationKeysAtFailedSaveForTesting
        #expect(queuedAtCheckpoint == [queueKey(homeID)])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 0)

        // Save 1 now commits 25 trips; the final save fails.
        await importer.failSaveCallForTesting(2)
        let failedFinal = await importer.importTrips(from: payload)
        #expect(failedFinal.saveFailed)
        #expect(failedFinal.insertedTrips == 25)
        #expect(failedFinal.stagedTemporaryHomeReconciliations == 1)
        #expect(queuedTemporaryHomeIDs(defaults) == [homeID])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 25)
    }

    @Test("with no temporary home in the store or the file, an import that crosses a checkpoint never writes the queue")
    func noTemporaryHomeMeansNoQueueWrite() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let payload = try makePayload(trips: (0..<26).map { tripJSON($0) })

        let outcome = await makeImporter(container, queue: suite)
            .importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 26)
        #expect(outcome.insertedTemporaryHomes == 0)
        #expect(outcome.stagedTemporaryHomeReconciliations == 0)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("when the temporary homes cannot be read, preview throws and the import inserts nothing instead of restoring stays without queueing the homes")
    func unreadableTemporaryHomesFailClosed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let existingID = UUID()
        try seedTemporaryHome(in: container, id: existingID, startedAt: Self.start)
        let insertedID = UUID()
        let payload = try makePayload(
            trips: [tripJSON(0)],
            temporaryHomes: [temporaryHomeJSON(
                id: insertedID, startedAt: Self.start.addingTimeInterval(400 * Self.day))])
        let importer = await makeImporter(container, queue: suite)

        // Preview reads trips, stays, homes, overrides and routine places
        // first; the temporary homes are its sixth identity read.
        await importer.failIdentityFetchCallForTesting(6)
        var previewThrew = false
        do {
            _ = try await importer.preview(of: payload)
        } catch {
            previewThrew = true
        }
        #expect(previewThrew)

        // The commit reads trips and stays first; temporary homes are third.
        await importer.failIdentityFetchCallForTesting(3)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.insertedStays == 0)
        #expect(outcome.insertedTemporaryHomes == 0)
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try verification.fetch(FetchDescriptor<TemporaryHome>()).map(\.id) == [existingID])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedStays == 1)
        #expect(retry.insertedTemporaryHomes == 1)
        #expect(retry.stagedTemporaryHomeReconciliations == 2)
        #expect(queuedTemporaryHomeIDs(defaults) == [existingID, insertedID])
    }

    // MARK: - Framework assumption

    /// The importer queues through a `UserDefaults` object it creates on the
    /// main actor for each hop, while the app and these tests read through
    /// their own object for the same suite.
    @Test("two UserDefaults objects for one suite see each other's writes at once")
    func suiteObjectsShareStorage() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = try #require(UserDefaults(suiteName: suite))

        other.set(["key": "value"], forKey: "probe")
        #expect(defaults.dictionary(forKey: "probe") as? [String: String] == ["key": "value"])
        defaults.removeObject(forKey: "probe")
        #expect(other.object(forKey: "probe") == nil)
    }
}
