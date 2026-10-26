//
//  P05RegressionTests.swift
//  TravelLogTests
//
//  Backup admission and restore authority: what an export may promise, what
//  a restore may admit, and which row or request a late answer may land on.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Backup admission and restore authority")
struct P05RegressionTests {

    /// Fictional instants (stored reference-date numbers) and place.
    private static let start: TimeInterval = 800_000_000
    private static let hour: TimeInterval = 3_600
    private static let latitude = 44.3
    private static let longitude = 12.9

    private static func stayEntry(
        id: UUID = UUID(), hour: Double, latitude: Double = latitude, longitude: Double = longitude,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id.uuidString,
            "startTime": start + hour * Self.hour,
            "endTime": start + (hour + 2) * Self.hour,
            "latitude": latitude, "longitude": longitude,
        ]
        entry.merge(extra) { _, new in new }
        return entry
    }

    private static func tripEntry(
        id: UUID = UUID(), stays: [[String: Any]], extra: [String: Any] = [:]
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id.uuidString,
            "startDate": start,
            "endDate": start + 48 * hour,
            "stays": stays,
        ]
        entry.merge(extra) { _, new in new }
        return entry
    }

    private static func stayRow(
        id: UUID, latitude: Double = latitude, in context: ModelContext
    ) -> Stay {
        let begin = Date(timeIntervalSinceReferenceDate: start)
        let stay = Stay(
            startTime: begin, endTime: begin.addingTimeInterval(2 * hour),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude) ?? "",
            pingCount: 0, distanceFromHomeKm: 100, pingIDs: [])
        stay.id = id
        stay.category = .destination
        context.insert(stay)
        return stay
    }

    // MARK: - IMP-003

    private static let healResult = GeocodeResolver.Result(
        country: nil, isoCountryCode: nil,
        administrativeArea: "Fictional Region", metroName: nil,
        localityName: "Fictional Town", subLocalityName: nil,
        islandName: nil)

    /// Restores one trip whose stay has no place layers and returns its
    /// committed heal witness.
    private func importHealCandidate(
        stayID: UUID, into container: ModelContainer
    ) async throws -> (TripDataImporter, PendingGeocode) {
        let payload = try BackupFixture.parse([
            "trips": [Self.tripEntry(stays: [Self.stayEntry(id: stayID, hour: 0)])],
        ])
        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        let pending = await importer.pendingGeocodes()
        #expect(pending.count == 1)
        return (importer, try #require(pending.first { $0.stayID == stayID }))
    }

    @Test("a geocode answer lands only while the witnessed row keeps its centroid")
    func geocodeHealNeedsTheWitnessedCentroid() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = UUID()
        let (importer, witness) = try await importHealCandidate(stayID: stayID, into: container)

        // Another lane moves the stay between the capture and the apply. The
        // importer's own context still caches the restored centroid.
        let lane = ModelContext(container)
        let row = try #require(try lane.fetch(FetchDescriptor<Stay>()).first)
        row.centroidLatitude = Self.latitude + 0.01
        try lane.save()
        #expect(await importer.applyGeocodeHealForTesting(witness, result: Self.healResult) == 0)
        let moved = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(moved.administrativeArea == nil)
        #expect(moved.locality == nil)

        // Back at the witnessed centroid, the same row heals.
        row.centroidLatitude = Self.latitude
        try lane.save()
        #expect(await importer.applyGeocodeHealForTesting(witness, result: Self.healResult) == 1)
        let healed = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(healed.administrativeArea == "Fictional Region")
        #expect(healed.locality == "Fictional Town")
    }

    @Test("a geocode answer heals its own physical row, never a same-id twin or replacement")
    func geocodeHealFollowsThePhysicalRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = UUID()
        let (importer, witness) = try await importHealCandidate(stayID: stayID, into: container)

        // A filled twin with the same id and centroid arrives first.
        let lane = ModelContext(container)
        let twin = Self.stayRow(id: stayID, in: lane)
        twin.administrativeArea = "Twin Region"
        try lane.save()
        let twinRow = twin.persistentModelID
        #expect(await importer.applyGeocodeHealForTesting(witness, result: Self.healResult) == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(rows.count == 2)
        #expect(rows.first { $0.persistentModelID == witness.persistentID }?
            .administrativeArea == "Fictional Region")
        #expect(rows.first { $0.persistentModelID == twinRow }?.administrativeArea == "Twin Region")

        // The witnessed row is replaced by a new one with the same id and centroid.
        let replacing = ModelContext(container)
        for row in try replacing.fetch(FetchDescriptor<Stay>()) { replacing.delete(row) }
        try replacing.save()
        let replacement = Self.stayRow(id: stayID, in: replacing)
        try replacing.save()
        let replacementRow = replacement.persistentModelID
        #expect(await importer.applyGeocodeHealForTesting(witness, result: Self.healResult) == 0)
        let after = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(after.map(\.persistentModelID) == [replacementRow])
        #expect(after.first?.administrativeArea == nil)
    }

    // MARK: - EXP-002

    /// A store holding one completed trip, named `name`, with one stay.
    private func storeWithTrip(named name: String?) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: Self.start))
        trip.endDate = Date(timeIntervalSinceReferenceDate: Self.start + 2 * Self.hour)
        trip.isComplete = true
        trip.customName = name
        trip.userEdited = true
        context.insert(trip)
        let stay = Self.stayRow(id: UUID(), in: context)
        stay.trip = trip
        stay.orderInTrip = 0
        try context.save()
        return container
    }

    @Test("an export refuses a trip name its restore would drop, and never cuts it", arguments: [
        (String(repeating: "a", count: 2_048), false),
        (String(repeating: "a", count: 2_049), true),
        (String(repeating: "😀", count: 512), false),
        (String(repeating: "😀", count: 513), true),
        (String(repeating: "\u{E9}", count: 1_024), false),
        (String(repeating: "\u{E9}", count: 1_025), true),
        (String(repeating: "e\u{301}", count: 682), false),
        (String(repeating: "e\u{301}", count: 683), true),
        (String(repeating: "👨‍👩‍👧", count: 113), false),
        (String(repeating: "👨‍👩‍👧", count: 114), true),
    ])
    func exportRefusesUnrestorableTripName(name: String, refused: Bool) async throws {
        let container = try storeWithTrip(named: name)
        let snapshotter = ExportSnapshotter(modelContainer: container)
        guard !refused else {
            let startDate = Date(timeIntervalSinceReferenceDate: Self.start)
            await #expect(throws: BackupExportRefusal.tripNameTooLong(startDate: startDate)) {
                try await snapshotter.exportData()
            }
            // Refused before publication: nothing at the shared URL, no partial file.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("P05RegressionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("backup.\(TripDataExporter.backupFileExtension)")
            await #expect(throws: BackupExportRefusal.self) {
                try await snapshotter.writeBackupFile(BackupExtras(), to: url)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            // The live name stays exactly as the user wrote it.
            let stored = try ModelContext(container).fetch(FetchDescriptor<Trip>())
            #expect(stored.map(\.customName) == [name])
            return
        }
        let payload = try TripDataImporter.parse(try await snapshotter.exportData())
        let restored = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: restored).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 1)
        let trips = try ModelContext(restored).fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.customName) == [name])
    }

    // MARK: - IMP-004

    nonisolated enum SemanticEdit: CaseIterable, Sendable {
        case none, madeTransit, moved, renamedPlace, reordered
    }

    @Test("a re-import completes a title only while the trip's title inputs are the ones it restores",
          arguments: SemanticEdit.allCases)
    func titleCompletionNeedsUnchangedInputs(edit: SemanticEdit) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let tripID = UUID(), firstID = UUID(), secondID = UUID()
        func tripEntry(title: String?) -> [String: Any] {
            Self.tripEntry(id: tripID, stays: [
                Self.stayEntry(id: firstID, hour: 0, extra: ["orderInTrip": 0, "locality": "Fictional Town"]),
                Self.stayEntry(id: secondID, hour: 4, extra: ["orderInTrip": 1, "locality": "Other Town"]),
            ], extra: title.map { ["aiGeneratedTitle": $0] as [String: Any] } ?? [:])
        }
        // The untitled graph, as an interrupted import's checkpoint leaves it.
        let importer = TripDataImporter(modelContainer: container)
        let seeded = await importer.importTrips(
            from: try BackupFixture.parse(["trips": [tripEntry(title: nil)]]))
        #expect(!seeded.saveFailed)
        #expect(seeded.insertedTrips == 1)
        let titled = try BackupFixture.parse(["trips": [tripEntry(title: "Fictional Getaway")]])
        #expect(try await importer.preview(of: titled).restorableTitles == 1)

        // The user edits the trip in another context; its members stay the same.
        let editor = ModelContext(container)
        let stays = try editor.fetch(FetchDescriptor<Stay>()).sorted { $0.startTime < $1.startTime }
        try #require(stays.count == 2)
        switch edit {
        case .none: break
        case .madeTransit: stays[1].category = .transit
        case .moved: stays[1].endTime = stays[1].endTime.addingTimeInterval(Self.hour)
        case .renamedPlace: stays[0].locality = "Renamed Town"
        case .reordered:
            stays[0].orderInTrip = 1
            stays[1].orderInTrip = 0
        }
        try editor.save()

        let completes = edit == .none
        #expect(try await importer.preview(of: titled).restorableTitles == (completes ? 1 : 0))
        let outcome = await importer.importTrips(from: titled)
        #expect(!outcome.saveFailed)
        #expect(outcome.restoredTitles == (completes ? 1 : 0))
        let trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.aiGeneratedTitle == (completes ? "Fictional Getaway" : nil))
        if edit == .madeTransit {
            #expect(trip.stays?.first { $0.id == secondID }?.category == .transit)
        }
    }

    // MARK: - SET-003

    /// A backup read that waits until the test lets it finish.
    private final class HeldRead: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let started: AsyncStream<Void>
        let startedContinuation: AsyncStream<Void>.Continuation

        init() {
            (started, startedContinuation) = AsyncStream<Void>.makeStream()
        }
    }

    nonisolated enum OlderOutcome: CaseIterable, Sendable {
        case plain, protected, failed
    }

    @Test("an older backup preparation that finishes last never replaces the latest file's import",
          arguments: OlderOutcome.allCases)
    func latestBackupPreparationWins(older: OlderOutcome) async throws {
        let importer = TripDataImporter(modelContainer: try TestSupport.makeInMemoryContainer())
        let model = SettingsModel()
        let olderDocument = try BackupFixture.document(
            ["trips": [Self.tripEntry(stays: [Self.stayEntry(hour: 0)])]])
        let newerDocument = try BackupFixture.document(
            ["trips": [Self.tripEntry(stays: [Self.stayEntry(hour: 10)])]])
        let lockedCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("P05RegressionTests-\(UUID().uuidString).locked")
        try Data("sealed".utf8).write(to: lockedCopy)
        defer { try? FileManager.default.removeItem(at: lockedCopy) }

        let held = HeldRead()
        let olderTask = Task {
            await model.prepareTripImport(importer: importer) {
                held.startedContinuation.yield(())
                _ = held.release.wait(timeout: .now() + 30)
                switch older {
                case .plain: return olderDocument
                case .protected: throw ProtectedBackupFound(lockedCopy: lockedCopy)
                case .failed: throw TripDataImportError.notJSON
                }
            }
        }
        var started = held.started.makeAsyncIterator()
        _ = await started.next()

        // The user opens the newer file; it is read and previewed first.
        await model.prepareTripImport(importer: importer) { newerDocument }
        let newerFingerprint = ImportFence.fingerprint(of: newerDocument)
        #expect(model.pendingTripImport?.fingerprint == newerFingerprint)
        #expect(model.showTripImportConfirmation)

        held.release.signal()
        await olderTask.value
        #expect(model.pendingTripImport?.fingerprint == newerFingerprint)
        #expect(model.showTripImportConfirmation)
        #expect(model.tripImportErrorMessage == nil)
        #expect(!model.showBackupPasswordPrompt)
        #expect(model.lockedBackupURL == nil)
        // A superseded protected file's private copy goes with its request.
        #expect(FileManager.default.fileExists(atPath: lockedCopy.path) == (older != .protected))
    }

    @Test("cancelling the password prompt revokes a preparation still reading")
    func cancelRevokesPreparation() async throws {
        let importer = TripDataImporter(modelContainer: try TestSupport.makeInMemoryContainer())
        let model = SettingsModel()
        let document = try BackupFixture.document(
            ["trips": [Self.tripEntry(stays: [Self.stayEntry(hour: 0)])]])
        let held = HeldRead()
        let task = Task {
            await model.prepareTripImport(importer: importer) {
                held.startedContinuation.yield(())
                _ = held.release.wait(timeout: .now() + 30)
                return document
            }
        }
        var started = held.started.makeAsyncIterator()
        _ = await started.next()
        model.cancelBackupPreparation()
        held.release.signal()
        await task.value
        #expect(model.pendingTripImport == nil)
        #expect(!model.showTripImportConfirmation)
        #expect(model.tripImportResultMessage == nil)
        #expect(model.tripImportErrorMessage == nil)
    }

    // MARK: - IMP-001

    @Test("a backup whose only new content is preferences is admitted, read-only, and restores them once")
    func preferenceOnlyRestoreIsAdmitted() async throws {
        let suite = "P05RegressionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let ubiquitousSuite = "P05RegressionTests-\(UUID().uuidString)"
        let ubiquitous = try #require(UserDefaults(suiteName: ubiquitousSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            ubiquitous.removePersistentDomain(forName: ubiquitousSuite)
        }
        let payload = try BackupFixture.parse([
            "trips": [Any](),
            "preferences": [
                "tripsSortOrder": "dateOldest",
                "dismissedFlightCandidates": ["first-answer", "second-answer", "first-answer"],
            ],
        ])
        let importer = TripDataImporter(modelContainer: try TestSupport.makeInMemoryContainer())

        // Without the preference count, nothing in the file is new.
        #expect(try await importer.preview(of: payload).hasImportableContent == false)
        let additions = BackupPreferences.additions(
            payload.preferences, defaults: defaults, ubiquitous: ubiquitous)
        #expect(additions == 3)
        // Counting writes nothing.
        #expect(defaults.object(forKey: BackupPreferences.tripsSortOrderKey) == nil)
        #expect(defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) == nil)
        let preview = try await importer.preview(of: payload, newPreferences: additions)
        #expect(preview.hasImportableContent)
        #expect(preview.newTrips == 0 && preview.newRecords == 0 && preview.newChoices == 0)

        // The commit applies them; a repeat import has nothing left to add.
        #expect(BackupPreferences.restore(
            payload.preferences, defaults: defaults, ubiquitous: ubiquitous) == 3)
        #expect(defaults.string(forKey: BackupPreferences.tripsSortOrderKey) == "dateOldest")
        #expect(BackupPreferences.additions(
            payload.preferences, defaults: defaults, ubiquitous: ubiquitous) == 0)
        #expect(BackupPreferences.restore(
            payload.preferences, defaults: defaults, ubiquitous: ubiquitous) == 0)
    }

    @Test("a dismissal list at its bound gains nothing from older answers, and is not rewritten")
    func boundedAwayAnswersCountForNothing() throws {
        let suite = "P05RegressionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let held = (0..<200).map { "held-\($0)" }
        defaults.set(held, forKey: TemporaryHomeSuggestion.dismissalsKey)
        var preferences = BackupPreferences()
        preferences.temporaryHomeSuggestionDismissals = ["older-answer"]

        #expect(BackupPreferences.additions(preferences, defaults: defaults, ubiquitous: defaults) == 0)
        #expect(BackupPreferences.restore(preferences, defaults: defaults, ubiquitous: defaults) == 0)
        #expect(defaults.stringArray(forKey: TemporaryHomeSuggestion.dismissalsKey) == held)

        // Below the bound, the older answer lands first.
        defaults.set(Array(held.suffix(10)), forKey: TemporaryHomeSuggestion.dismissalsKey)
        #expect(BackupPreferences.additions(preferences, defaults: defaults, ubiquitous: defaults) == 1)
        #expect(BackupPreferences.restore(preferences, defaults: defaults, ubiquitous: defaults) == 1)
        #expect(defaults.stringArray(forKey: TemporaryHomeSuggestion.dismissalsKey)
            == ["older-answer"] + held.suffix(10))
    }

    // MARK: - IMP-002

    @Test("damaged entries are counted and dropped as they stream, valid siblings and declared counts kept")
    func damagedEntriesStreamAway() throws {
        let tripID = UUID(), keptStayID = UUID(), looseStayID = UUID()
        var trip = Self.tripEntry(id: tripID, stays: [Self.stayEntry(id: keptStayID, hour: 0)])
        // Two damaged members around the valid one, and a damaged title row.
        let validStays = try #require(trip["stays"] as? [Any])
        let members: [Any] = [NSNull()] + validStays + [["id": "not-a-stay"]]
        trip["stays"] = members
        trip["localizedTitles"] = [NSNull()] as [Any]
        let damaged = 3 * 256 + 7  // more than a few parser chunks
        let nulls = [Any](repeating: NSNull(), count: damaged)
        let payload = try BackupFixture.parse([
            "trips": nulls + [trip as Any],
            "unassignedStays": [Self.stayEntry(id: looseStayID, hour: 30) as Any] + nulls,
            "visits": nulls,
        ])
        #expect(payload.malformedTrips == damaged)
        #expect(payload.malformedStays == 2 + damaged)
        #expect(payload.malformedVisits == damaged)
        #expect(payload.trips.map(\.id) == [tripID])
        #expect(payload.trips.first?.stays.map(\.id) == [keptStayID])
        #expect(payload.trips.first?.declaredStayCount == 3)
        #expect(payload.trips.first?.localizedTitles.isEmpty == true)
        #expect(payload.unassignedStays.map(\.id) == [looseStayID])
    }

    // MARK: - DATA-003

    @Test("restored cell strings are the app's own: valid cells kept, others derived from their coordinates")
    func restoredCellsAreCanonical() async throws {
        let cell = try #require(H3Service.cellIndex(latitude: Self.latitude, longitude: Self.longitude))
        let other = try #require(H3Service.cellIndex(latitude: 44.9, longitude: 12.1))
        // The same place's centre child one resolution finer: a valid index the app never writes.
        let raw = try #require(UInt64(cell, radix: 16))
        let finer = String(
            (raw & ~(UInt64(0xF) << 52) | (UInt64(7) << 52)) & ~(UInt64(0b111) << 24), radix: 16)
        #expect(H3Service.canonicalCellIndex(cell) == cell)
        #expect(H3Service.canonicalCellIndex(cell.uppercased()) == cell)
        for damaged in ["", "not-h3", "0", finer, "ffffffffffffffff"] {
            #expect(H3Service.canonicalCellIndex(damaged) == nil)
        }

        func hexVisit(_ index: String) -> [String: Any] {
            ["h3Index": index, "centerLatitude": Self.latitude, "centerLongitude": Self.longitude,
             "firstVisited": Self.start, "lastVisited": Self.start + Self.hour]
        }
        let payload = try BackupFixture.parse([
            "trips": [Any](),
            "unassignedStays": [
                Self.stayEntry(hour: 0, extra: ["h3IndexRes6": "not-h3"]),
                Self.stayEntry(hour: 4, latitude: 44.9, longitude: 12.1, extra: ["h3IndexRes6": other]),
            ],
            "hexVisits": [hexVisit("not-h3"), hexVisit("0"), hexVisit(cell.uppercased()), hexVisit(finer)],
            "pings": [[
                "id": UUID().uuidString, "timestamp": Self.start,
                "latitude": Self.latitude, "longitude": Self.longitude, "h3IndexRes6": "not-h3",
            ]],
        ])
        #expect(payload.malformedStays == 0 && payload.malformedRecords == 0)
        #expect(payload.unassignedStays.map(\.admittedH3Index) == [cell, other])
        #expect(payload.hexVisits.map(\.h3Index) == [cell, cell, cell, cell])
        var pings: [ExportPingSnapshot] = []
        try payload.pings.forEachChunk { chunk, _ in pings += chunk }
        #expect(pings.map(\.h3IndexRes6) == [cell])

        // What lands is what the preview counted: one cell, both stays, the ping.
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<HexVisit>()).map(\.h3Index) == [cell])
        #expect(Set(try context.fetch(FetchDescriptor<Stay>()).map(\.h3IndexRes6)) == [cell, other])
        #expect(try context.fetch(FetchDescriptor<LocationPing>()).map(\.h3IndexRes6) == [cell])
    }
}
