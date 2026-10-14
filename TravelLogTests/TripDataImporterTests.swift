//
//  TripDataImporterTests.swift
//  TravelLogTests
//
//  Covers the JSON trip-data import: tolerant v1/v2 parsing, faithful
//  restore (ids, links, categories, provenance), synthetic-ping semantics
//  (isProcessed, .jsonImport tagging), HexVisit upsert, idempotent
//  re-import, preview counts, and an export→import round trip through
//  TripDataExporter (the real v2 wire format).
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation (@Model types are MainActor-isolated); the importer actor
//  saves before returning, so assertions re-fetch from a fresh context.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("TripDataImporter")
struct TripDataImporterTests {

    // MARK: - Fixtures

    /// A two-stay v1 export (the pre-June-2026 format: no formatVersion,
    /// no fidelity fields), with one malformed stay to exercise tolerance.
    private static let v1JSON = """
    {
      "exportDate": "2025-07-17T00:00:00Z",
      "appVersion": "1.0",
      "tripCount": 1,
      "trips": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "startDate": "2023-11-15T08:00:00Z",
          "endDate": "2023-11-19T18:00:00Z",
          "isComplete": true,
          "destinationSummary": "Kyoto",
          "countryCodes": "JP",
          "classifiedByAI": true,
          "durationDays": 5,
          "stays": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "startTime": "2023-11-15T10:00:00Z",
              "endTime": "2023-11-17T09:00:00Z",
              "durationMinutes": 2820,
              "category": "destination",
              "latitude": 35.0034,
              "longitude": 135.7825,
              "pingCount": 14,
              "distanceFromHomeKm": 9450.5,
              "locality": "Kyoto",
              "country": "Japan",
              "isoCountryCode": "JP"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "startTime": "2023-11-17T12:00:00Z",
              "endTime": "2023-11-19T16:00:00Z",
              "durationMinutes": 3120,
              "category": "destination",
              "latitude": 34.6946,
              "longitude": 135.4651,
              "pingCount": 9,
              "distanceFromHomeKm": 9400.0,
              "locality": "Osaka",
              "country": "Japan",
              "isoCountryCode": "JP"
            },
            {
              "id": "not-a-uuid",
              "startTime": "2023-11-19T12:00:00Z",
              "endTime": "2023-11-19T16:00:00Z",
              "latitude": 34.0,
              "longitude": 135.0
            }
          ]
        }
      ]
    }
    """

    private func importV1(into container: ModelContainer) async throws -> ImportOutcome {
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)
        return await importer.importTrips(from: payload)
    }

    // MARK: - Parsing

    @Test("v1 parses: missing formatVersion defaults to 1; malformed stay is counted, not fatal")
    func parseV1Tolerantly() throws {
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        #expect(payload.formatVersion == 1)
        #expect(payload.trips.count == 1)
        #expect(payload.trips.first?.stays.count == 2)
        #expect(payload.malformedStays == 1)
        #expect(payload.malformedTrips == 0)
        #expect(payload.visits.isEmpty)
        #expect(payload.malformedVisits == 0)
    }

    @Test("invalid stay array members are counted while valid siblings import",
          arguments: ["stays", "unassignedStays", "homeStays"])
    func malformedArrayMembersKeepValidSiblings(section: String) async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        var trips = try #require(root["trips"] as? [[String: Any]])
        let stays = try #require(trips[0]["stays"] as? [[String: Any]])
        var first = stays[0]
        var second = stays[1]
        if section == "homeStays" {
            first["category"] = "home"
            second["category"] = "home"
        }
        let members: [Any] = [first, NSNull(), second, 42, "broken"]
        if section == "stays" {
            trips[0]["stays"] = members
        } else {
            trips[0]["stays"] = []
            root[section] = members
        }
        root["trips"] = trips
        let payload = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(payload.malformedStays == 3)
        if section == "stays" {
            #expect(payload.trips.first?.stays.count == 2)
            #expect(payload.trips.first?.declaredStayCount == 5)
        } else if section == "unassignedStays" {
            #expect(payload.unassignedStays.count == 2)
        } else {
            #expect(payload.homeStays.count == 2)
        }
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        let restored = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let expectedIDs = [first, second].compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
        #expect(expectedIDs.count == 2)
        #expect(Set(restored.map(\.id)) == Set(expectedIDs))
    }

    @Test("v1-v8 payloads without visits remain compatible")
    func preV9PayloadsHaveNoVisits() throws {
        let baseRoot = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])

        for version in 1...8 {
            var root = baseRoot
            root["formatVersion"] = version
            let payload = try TripDataImporter.parse(
                JSONSerialization.data(withJSONObject: root))
            #expect(payload.formatVersion == version)
            #expect(payload.visits.isEmpty)
            #expect(payload.malformedVisits == 0)
        }
    }

    @Test("v10 carries a stay's timeZoneIdentifier; older files parse it as nil")
    func v10StayZoneParses() throws {
        let baseRoot = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        let legacy = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: baseRoot))
        #expect(legacy.trips.first?.stays.first?.timeZoneIdentifier == nil)

        var root = baseRoot
        root["formatVersion"] = 10
        var trips = try #require(root["trips"] as? [[String: Any]])
        var stays = try #require(trips[0]["stays"] as? [[String: Any]])
        stays[0]["timeZoneIdentifier"] = "Asia/Tokyo"
        trips[0]["stays"] = stays
        root["trips"] = trips
        let payload = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(payload.formatVersion == 10)
        #expect(payload.trips.first?.stays.first?.timeZoneIdentifier == "Asia/Tokyo")
    }

    @Test("a trip without isComplete is complete exactly when its endDate parses, fractional seconds included; an explicit flag wins either way")
    func isCompleteDefaultsToParsedEndDate() throws {
        let baseRoot = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        let baseTrip = try #require((baseRoot["trips"] as? [[String: Any]])?.first)
        let cases: [(endDate: String?, isComplete: Bool?, hasEnd: Bool, complete: Bool)] = [
            ("2023-11-19T18:00:00Z", nil, true, true),
            ("2023-11-19T18:00:00.250Z", nil, true, true),
            ("not a date", nil, false, false),
            (nil, nil, false, false),
            ("2023-11-19T18:00:00Z", false, true, false),
            (nil, true, false, true),
        ]
        for testCase in cases {
            var trip = baseTrip
            trip.removeValue(forKey: "endDate")
            trip.removeValue(forKey: "isComplete")
            if let endDate = testCase.endDate { trip["endDate"] = endDate }
            if let isComplete = testCase.isComplete { trip["isComplete"] = isComplete }
            var root = baseRoot
            root["trips"] = [trip]
            let parsed = try #require(try TripDataImporter.parse(
                JSONSerialization.data(withJSONObject: root)).trips.first)
            #expect((parsed.endDate != nil) == testCase.hasEnd)
            #expect(parsed.isComplete == testCase.complete)
        }
    }

    @Test("v9 omits empty visits and round-trips every raw Visit field")
    func v9VisitShapeRoundTrips() throws {
        let emptyData = try #require(TripDataExporter.buildExportData(
            snapshots: [], appVersion: "test"))
        let emptyRoot = try #require(try JSONSerialization.jsonObject(
            with: emptyData) as? [String: Any])
        #expect(emptyRoot["formatVersion"] as? Int == TripDataExporter.formatVersion)
        #expect(emptyRoot["visits"] == nil)

        let stayID = UUID()
        let closed = ExportVisitSnapshot(
            id: UUID(), stayID: stayID,
            arrivalDate: Date(timeIntervalSince1970: 1_685_484_800.875),
            departureDate: Date(timeIntervalSince1970: 1_685_488_400.625),
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 31.25,
            receivedAt: Date(timeIntervalSince1970: 1_685_488_401.75))
        let open = ExportVisitSnapshot(
            id: UUID(), stayID: nil,
            arrivalDate: Date(timeIntervalSince1970: 1_685_494_800.5),
            departureDate: nil,
            latitude: -33.8188, longitude: 151.2674,
            horizontalAccuracy: 12.5,
            receivedAt: Date(timeIntervalSince1970: 1_685_494_801.25))

        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], visits: [closed, open], appVersion: "test"))
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        let rows = try #require(root["visits"] as? [[String: Any]])
        #expect(rows.count == 2)
        let openRow = try #require(rows.first {
            $0["id"] as? String == open.id.uuidString
        })
        #expect(openRow["stayID"] == nil)
        #expect(openRow["departure"] == nil)
        #expect(openRow["isProcessed"] == nil)

        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedVisits == 0)
        #expect(payload.visits.count == 2)
        let restoredClosed = try #require(payload.visits.first {
            $0.id == closed.id
        })
        #expect(restoredClosed.stayID == stayID)
        #expect(restoredClosed.departureDate != nil)
        #expect(restoredClosed.latitude == closed.latitude)
        #expect(restoredClosed.longitude == closed.longitude)
        #expect(restoredClosed.horizontalAccuracy == closed.horizontalAccuracy)
        #expect(abs(restoredClosed.arrivalDate.timeIntervalSince(
            closed.arrivalDate)) < 1)
        let restoredDeparture = try #require(restoredClosed.departureDate)
        let originalDeparture = try #require(closed.departureDate)
        #expect(abs(restoredDeparture.timeIntervalSince(originalDeparture)) < 1)
        #expect(abs(restoredClosed.receivedAt.timeIntervalSince(
            closed.receivedAt)) < 1)

        let restoredOpen = try #require(payload.visits.first {
            $0.id == open.id
        })
        #expect(restoredOpen.stayID == nil)
        #expect(restoredOpen.departureDate == nil)
        #expect(restoredOpen.latitude == open.latitude)
        #expect(restoredOpen.longitude == open.longitude)
        #expect(restoredOpen.horizontalAccuracy == open.horizontalAccuracy)
        #expect(abs(restoredOpen.arrivalDate.timeIntervalSince(
            open.arrivalDate)) < 1)
        #expect(abs(restoredOpen.receivedAt.timeIntervalSince(
            open.receivedAt)) < 1)
    }

    @Test("malformed Visit rows are counted, dropped, and included in the preview total")
    func malformedVisitsAreDropped() async throws {
        let iso = ISO8601DateFormatter()
        let arrival = Date(timeIntervalSince1970: 1_685_484_800)
        func row(id: String = UUID().uuidString) -> [String: Any] {
            [
                "id": id,
                "arrival": iso.string(from: arrival),
                "departure": iso.string(from: arrival.addingTimeInterval(3_600)),
                "lat": 37.9838,
                "lon": 23.7275,
                "accuracy": 30.0,
                "receivedAt": iso.string(from: arrival.addingTimeInterval(3_601)),
            ]
        }

        var missingArrival = row()
        missingArrival.removeValue(forKey: "arrival")
        var invalidLatitude = row()
        invalidLatitude["lat"] = 95.0
        var invalidAccuracy = row()
        invalidAccuracy["accuracy"] = 5_000.0
        var reversedDeparture = row()
        reversedDeparture["departure"] = iso.string(from: arrival)
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 9,
            "trips": [],
            "visits": [
                row(), row(id: "not-a-uuid"), missingArrival,
                invalidLatitude, invalidAccuracy, reversedDeparture,
            ],
        ])

        let payload = try TripDataImporter.parse(data)
        #expect(payload.visits.count == 1)
        #expect(payload.malformedVisits == 5)
        let importer = TripDataImporter(
            modelContainer: try TestSupport.makeInMemoryContainer())
        let preview = try await importer.preview(of: payload)
        #expect(preview.malformedEntries == 5)
    }

    @Test("a v1 payload with no geocoder layers is healed by the offline resolver AFTER import returns")
    func importHealsMissingGeocodeLayers() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)
        let (_, pending) = await PipelineGate(forTesting: ()).runReturning(touching: []) {
            let outcome = await importer.importTrips(from: payload)
            let pending = await importer.pendingGeocodes()
            return (outcome, pending)
        }

        // Gate contract: `importTrips`; the phase
        // callers hold a PipelineGate unit across; performs NO geocode
        // awaits. It returns with the place layers still nil and the
        // candidates snapshotted for the post-unit heal phase; pre-fix,
        // the per-stay resolver awaits ran inside the caller's held unit
        // and starved queued SLC wake-ping saves.
        let preHeal = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(preHeal.allSatisfy {
            $0.administrativeArea == nil && $0.metroName == nil && $0.islandName == nil
        })
        #expect(pending.count == 2)

        // Post-import healing: ungated resolution + short gated apply chunks (an
        // injected fresh gate; distinct in-memory stores must not
        // contend on the shared gate across suites).
        let healed = await importer.healPendingGeocodes(pending, gate: PipelineGate(forTesting: ()))
        #expect(healed == 2)

        let ctx = ModelContext(container)
        let stays = try ctx.fetch(FetchDescriptor<Stay>()).sorted { $0.startTime < $1.startTime }
        let kyoto = try #require(stays.first)
        // v1 exports predate administrativeArea/metroName/islandName, and
        // the one-shot geocoder backfills are latched on any previously-used
        // device; pre-fix these fields stayed nil forever on restored stays
        // The offline resolver heals them post-import;
        // payload-carried values are never overwritten.
        #expect(kyoto.administrativeArea != nil)
        #expect(kyoto.locality == "Kyoto")
        #expect(kyoto.country == "Japan")
        #expect(kyoto.isoCountryCode == "JP")

        // Idempotent: re-healing the same snapshots is a no-op (the
        // apply re-validates the all-three-nil condition by re-fetch).
        let rehealed = await importer.healPendingGeocodes(pending, gate: PipelineGate(forTesting: ()))
        #expect(rehealed == 0)
    }

    @Test("a successful v10 stay import re-arms the demotion-aware geocoder backfill")
    func importRearmsDemotionAwareGeocoderBackfill() async throws {
        let key = AppDelegate.offlineGeocoderBackfillCompletedKey
        let suiteName = "TripDataImporterTests.backfill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: key)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(defaults.bool(forKey: key))

        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 10
        var trips = try #require(root["trips"] as? [[String: Any]])
        var stays = try #require(trips[0]["stays"] as? [[String: Any]])
        stays[0]["locality"] = "Great Britain"
        stays[0]["islandName"] = "Great Britain"
        trips[0]["stays"] = [stays[0]]
        root["trips"] = trips
        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let importer = TripDataImporter(
            modelContainer: try TestSupport.makeInMemoryContainer())

        let outcome = await TripDataImporter.BackfillTestScope.$defaultsSuiteName.withValue(suiteName) {
            await importer.importTrips(from: payload)
        }

        #expect(!outcome.saveFailed)
        #expect(outcome.insertedStays == 1)
        #expect(!defaults.bool(forKey: key))
    }

    @Test("a place-name geocode heal invalidates generated title derivatives", arguments: [false, true])
    func geocodeHealInvalidatesTitles(homePlaceReadFails: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        trip.aiGeneratedTitle = "Island Escape"
        let stay = Stay(
            startTime: trip.startDate,
            endTime: trip.startDate.addingTimeInterval(3_600),
            centroidLatitude: 38.20133, centroidLongitude: 20.43706,
            h3IndexRes6: "geocode-title", pingCount: 2,
            distanceFromHomeKm: 150, pingIDs: [])
        stay.category = .destination
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Inselflucht",
            sourceTitle: "Island Escape", trip: trip))
        try context.save()

        let importer = TripDataImporter(modelContainer: container)
        let result = GeocodeResolver.Result(
            country: "Greece", isoCountryCode: "GR",
            administrativeArea: "Ionian Islands", metroName: nil,
            localityName: "Lixoúri", subLocalityName: nil,
            islandName: "Cephalonia")
        let stayID = stay.id
        let healed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(homePlaceReadFails) {
            await importer.applyGeocodeHealForTesting(stayID: stayID, result: result)
        }
        #expect(healed == 1)

        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedTitle == nil)
        #expect((reloaded.localizedTitles ?? []).isEmpty)
        #expect(reloaded.destinationSummary.contains("Cephalonia"))
    }

    @Test("a heal with unchanged title inputs still refreshes the parent summary")
    func geocodeHealRefreshesUnchangedParent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        trip.aiGeneratedTitle = "Kyoto"
        trip.destinationSummary = "Stale summary"
        let stay = Stay(
            startTime: trip.startDate,
            endTime: trip.startDate.addingTimeInterval(3_600),
            centroidLatitude: 35.0034, centroidLongitude: 135.7825,
            h3IndexRes6: "unchanged-title", pingCount: 2,
            distanceFromHomeKm: 150, pingIDs: [])
        stay.category = .destination
        stay.locality = "Kyoto"
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Kyoto",
            sourceTitle: "Kyoto", trip: trip))
        try context.save()

        let importer = TripDataImporter(modelContainer: container)
        let result = GeocodeResolver.Result(
            country: nil, isoCountryCode: nil,
            administrativeArea: nil, metroName: nil,
            localityName: "Kyoto", subLocalityName: "District",
            islandName: nil)
        #expect(await importer.applyGeocodeHealForTesting(
            stayID: stay.id, result: result) == 1)

        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.destinationSummary == "Kyoto")
        #expect(reloaded.aiGeneratedTitle == "Kyoto")
        #expect((reloaded.localizedTitles ?? []).count == 1)
        #expect(reloaded.orderedStays.first?.subLocality == "District")
    }

    @Test("non-JSON data and JSON without a trips array throw distinct errors")
    func parseRejectsGarbage() {
        #expect(throws: TripDataImportError.notJSON) {
            try TripDataImporter.parse(Data("not json at all".utf8))
        }
        #expect(throws: TripDataImportError.missingTripsArray) {
            try TripDataImporter.parse(Data("{\"hello\": 1}".utf8))
        }
    }

    @Test("a backup in a newer format than this reader is refused, so nothing in it is silently dropped; the current format still parses")
    func parseRejectsNewerFormat() throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = TripDataExporter.formatVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: TripDataImportError.newerFormat) {
            try TripDataImporter.parse(newer)
        }
        #expect(TripDataImportError.newerFormat.errorDescription?.isEmpty == false)

        root["formatVersion"] = TripDataExporter.formatVersion
        let current = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(current.formatVersion == TripDataExporter.formatVersion)
    }

    // MARK: - Faithful restore

    @Test("import creates linked trips/stays with original UUIDs, categories, and synthetic pings")
    func importCreatesFaithfulGraph() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = try await importV1(into: container)

        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 2)
        #expect(outcome.skippedExistingTrips == 0)

        let ctx = ModelContext(container)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        let trip = try #require(trips.first)
        #expect(trip.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(trip.isComplete)
        #expect(trip.endDate != nil)
        // recomputeSummary ran against the linked stays.
        #expect(trip.countryCodes.contains("JP"))

        let stays = try ctx.fetch(FetchDescriptor<Stay>()).sorted { $0.startTime < $1.startTime }
        #expect(stays.count == 2)
        let kyoto = try #require(stays.first)
        #expect(kyoto.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(kyoto.category == .destination)
        #expect(kyoto.trip?.id == trip.id)
        #expect(kyoto.orderInTrip == 0)
        #expect(kyoto.locality == "Kyoto")
        // v1 carries no provenance → .jsonImport.
        #expect(kyoto.source == .jsonImport)
        // Synthetic pings: two per stay (start + end), processed, tagged.
        #expect(kyoto.pingIDs.count == 2)

        let pings = try ctx.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 4)
        #expect(pings.allSatisfy { $0.isProcessed })
        #expect(pings.allSatisfy { $0.source == .jsonImport })
        #expect(pings.allSatisfy { $0.isGeocoded })

        // HexVisit rows exist for both stay hexes (Kyoto/Osaka are
        // distinct res-6 cells).
        let hexes = try ctx.fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.count == 2)
        #expect(hexes.allSatisfy { $0.visitCount == 1 })
    }

    @Test("re-importing the same file is a no-op (idempotent by UUID)")
    func reimportIsIdempotent() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        _ = try await importV1(into: container)

        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)
        let second = await importer.importTrips(from: payload)

        #expect(second.insertedTrips == 0)
        #expect(second.insertedStays == 0)
        #expect(second.skippedExistingTrips == 1)

        let ctx = ModelContext(container)
        #expect(try ctx.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try ctx.fetchCount(FetchDescriptor<Stay>()) == 2)
        #expect(try ctx.fetchCount(FetchDescriptor<LocationPing>()) == 4)
    }

    @Test("v9 import restores processed Visits and is idempotent by Visit UUID")
    func importRestoresVisitsProcessed() async throws {
        let attachedVisitID = UUID()
        let unattachedVisitID = UUID()
        let attachedStayID = try #require(UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"))
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 9
        root["visits"] = [
            [
                "id": attachedVisitID.uuidString,
                "stayID": attachedStayID.uuidString,
                "arrival": "2023-11-15T10:00:00Z",
                "departure": "2023-11-15T12:00:00Z",
                "lat": 35.0034,
                "lon": 135.7825,
                "accuracy": 24.0,
                "receivedAt": "2023-11-15T12:00:01Z",
            ],
            [
                "id": unattachedVisitID.uuidString,
                "arrival": "2023-11-17T12:00:00Z",
                "lat": 34.6946,
                "lon": 135.4651,
                "accuracy": 40.0,
                "receivedAt": "2023-11-17T12:00:01Z",
            ],
        ]
        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)

        let first = await importer.importTrips(from: payload)
        #expect(!first.saveFailed)
        #expect(first.insertedVisits == 2)

        let verification = ModelContext(container)
        let restored = try verification.fetch(FetchDescriptor<Visit>())
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.isProcessed })
        #expect(restored.first { $0.id == attachedVisitID }?.stayID
                == attachedStayID)
        #expect(restored.first { $0.id == unattachedVisitID }?.stayID == nil)

        let second = await importer.importTrips(from: payload)
        #expect(second.insertedVisits == 0)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<Visit>()) == 2)
    }

    @Test("a Visit-only difference is counted and admitted by the preview")
    func visitOnlyPayloadIsAdmitted() async throws {
        let visit = ExportVisitSnapshot(
            id: UUID(), stayID: nil,
            arrivalDate: Date(timeIntervalSince1970: 1_685_484_800),
            departureDate: nil,
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 30,
            receivedAt: Date(timeIntervalSince1970: 1_685_484_801))
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], visits: [visit], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        let importer = TripDataImporter(
            modelContainer: try TestSupport.makeInMemoryContainer())

        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.newHomeAreaRows == 0)
        #expect(preview.newVisits == 1)
        #expect(preview.hasImportableContent)
    }

    @Test("a failed final save reports zero inserted Visits")
    func finalSaveFailureReportsNoVisits() async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 9
        root["visits"] = [[
            "id": UUID().uuidString,
            "arrival": "2023-11-15T10:00:00Z",
            "departure": "2023-11-15T12:00:00Z",
            "lat": 35.0034,
            "lon": 135.7825,
            "accuracy": 24.0,
            "receivedAt": "2023-11-15T12:00:01Z",
        ]]
        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        await importer.failSaveCallForTesting(1)

        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedVisits == 0)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<Visit>()) == 0)
    }

    @Test("off-main trip snapshots serialize identically to snapshots of the same saved rows")
    func offMainTripSnapshotsMatchDirectSnapshots() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_685_484_800)
        for tripIndex in 0..<3 {
            let start = base.addingTimeInterval(Double(tripIndex) * 864_000)
            let trip = Trip(startDate: start, source: .liveSLC)
            trip.endDate = start.addingTimeInterval(200_000)
            trip.isComplete = true
            trip.customName = tripIndex == 1 ? "Renamed" : nil
            context.insert(trip)
            // Inserted in reverse so `orderInTrip`, not insertion, decides the order.
            for stayIndex in (0..<4).reversed() {
                let begin = start.addingTimeInterval(Double(stayIndex) * 40_000)
                let stay = Stay(
                    startTime: begin, endTime: begin.addingTimeInterval(30_000),
                    centroidLatitude: 37.9838, centroidLongitude: 23.7275,
                    h3IndexRes6: "", pingCount: 0,
                    distanceFromHomeKm: 100, pingIDs: [], source: .liveSLC)
                stay.category = stayIndex == 2 ? .transit : .destination
                stay.locality = "Place \(tripIndex)-\(stayIndex)"
                context.insert(stay)
                stay.trip = trip
                stay.orderInTrip = stayIndex
            }
        }
        try context.save()

        let direct = TripDataExporter.makeSnapshots(from: try context.fetch(
            FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])))
        let offMain = try await ExportSnapshotter(modelContainer: container).snapshotTrips()

        #expect(offMain.map(\.id) == direct.map(\.id))
        #expect(offMain.map(\.startDate) == offMain.map(\.startDate).sorted(by: >))
        #expect(offMain.map { $0.stays.map(\.id) } == direct.map { $0.stays.map(\.id) })
        #expect(offMain.map(\.customName) == direct.map(\.customName))
        #expect(offMain.allSatisfy { $0.stays.count == 4 })

        // Whole-document equality, minus the wall-clock export stamp.
        func document(_ snapshots: [ExportTripSnapshot]) throws -> NSDictionary {
            let data = try #require(TripDataExporter.buildExportData(
                snapshots: snapshots, appVersion: "test"))
            var root = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            root["exportDate"] = nil
            return root as NSDictionary
        }
        #expect(try document(offMain) == document(direct))
    }

    @Test("export-wipe-import restores a pending Visit pending, and clustering settles it without a duplicate Stay")
    func exportWipeImportRestoresVisitsWithoutDuplicateStays() async throws {
        let suiteName = "TripDataImporterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_685_484_800.75)
        let end = start.addingTimeInterval(7_200)
        let h3 = try #require(H3Service.cellIndex(
            latitude: 37.9838, longitude: 23.7275))
        let trip = Trip(startDate: start, source: .liveSLC)
        trip.endDate = end
        trip.isComplete = true
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: h3, pingCount: 0,
            distanceFromHomeKm: 100, pingIDs: [], source: .liveSLC)
        stay.category = .destination
        stay.trip = trip
        stay.orderInTrip = 0
        let visit = Visit(
            arrivalDate: start, departureDate: end,
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 25, receivedAt: end.addingTimeInterval(1),
            stayID: stay.id, isProcessed: false)
        context.insert(trip)
        context.insert(stay)
        context.insert(visit)
        try context.save()

        let snapshots = TripDataExporter.makeSnapshots(from: [trip])
        let homeLayer = try await ExportSnapshotter(modelContainer: container)
            .snapshotHomeAreaLayer()
        #expect(homeLayer.visits.count == 1)
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: snapshots,
            visits: homeLayer.visits,
            appVersion: "test"))

        #expect(DataWipe.execute(
            container: container, defaults: defaults, clearDissolvedQueue: {}))
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<Trip>()) == 0)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<Stay>()) == 0)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<Visit>()) == 0)

        let payload = try TripDataImporter.parse(data)
        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 1)
        #expect(outcome.insertedVisits == 1)

        let restoredContext = ModelContext(container)
        let restoredStay = try #require(try restoredContext.fetch(
            FetchDescriptor<Stay>()).first)
        let restoredVisit = try #require(try restoredContext.fetch(
            FetchDescriptor<Visit>()).first)
        #expect(!restoredVisit.isProcessed)
        #expect(restoredVisit.stayID == restoredStay.id)

        let created = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPings()
        #expect(created == 0)
        let settledContext = ModelContext(container)
        #expect(try settledContext.fetchCount(FetchDescriptor<Stay>()) == 1)
        #expect(try settledContext.fetchCount(FetchDescriptor<Trip>()) == 1)
        let settled = try #require(try settledContext.fetch(
            FetchDescriptor<Visit>()).first)
        #expect(settled.isProcessed)
        #expect(settled.stayID == restoredStay.id)
    }

    @Test("a closed pending Visit whose stay never existed restores pending and clustering creates its stay; older files stay processed")
    func pendingVisitWithoutStayIsClusteredAfterRestore() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(source)
        let arrival = Date(timeIntervalSince1970: 1_685_484_800.25)
        let departure = arrival.addingTimeInterval(3 * 3_600)
        let pending = Visit(
            arrivalDate: arrival, departureDate: departure,
            latitude: 48.8566, longitude: 2.3522,
            horizontalAccuracy: 20, receivedAt: departure.addingTimeInterval(1),
            stayID: nil, isProcessed: false)
        let consumed = Visit(
            arrivalDate: arrival.addingTimeInterval(-86_400),
            departureDate: arrival.addingTimeInterval(-82_800),
            latitude: 48.8566, longitude: 2.3522,
            horizontalAccuracy: 20, receivedAt: arrival.addingTimeInterval(-82_799),
            stayID: nil, isProcessed: true)
        sourceContext.insert(pending)
        sourceContext.insert(consumed)
        try sourceContext.save()

        let layer = try await ExportSnapshotter(modelContainer: source)
            .snapshotHomeAreaLayer()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], visits: layer.visits, appVersion: "test"))
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        let rows = try #require(root["visits"] as? [[String: Any]])
        #expect(rows.first { $0["id"] as? String == pending.id.uuidString }?["isProcessed"] as? Bool == false)
        #expect(rows.first { $0["id"] as? String == consumed.id.uuidString }?["isProcessed"] == nil)

        // A file older than the key restores every Visit processed.
        var older = root
        older["formatVersion"] = 13
        let olderPayload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: older))
        #expect(olderPayload.visits.allSatisfy { $0.isProcessed })

        let payload = try TripDataImporter.parse(data)
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        #expect(try await importer.preview(of: payload).newVisits == 2)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedVisits == 2)
        let restored = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(restored.first { $0.id == pending.id }?.isProcessed == false)
        #expect(restored.first { $0.id == consumed.id }?.isProcessed == true)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 0)

        let created = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPings()
        #expect(created == 1)
        let settledContext = ModelContext(container)
        let stays = try settledContext.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        let stay = try #require(stays.first)
        #expect(stay.startTime == arrival)
        #expect(stay.endTime == departure)
        let settled = try settledContext.fetch(FetchDescriptor<Visit>())
        #expect(settled.first { $0.id == pending.id }?.isProcessed == true)
        #expect(settled.first { $0.id == pending.id }?.stayID == stay.id)
        #expect(settled.first { $0.id == consumed.id }?.stayID == nil)

        // Re-importing the same file changes nothing.
        let again = await importer.importTrips(from: payload)
        #expect(again.insertedVisits == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Visit>()) == 2)
    }

    /// A completed trip of measured stays: each stay is (start, end,
    /// latitude, its genuine ping times), its pings already clustered.
    private static func insertMeasuredTrip(
        _ stays: [(start: Date, end: Date, latitude: Double, longitude: Double, pingTimes: [Date])],
        in context: ModelContext
    ) throws -> (trip: Trip, stays: [Stay]) {
        let first = try #require(stays.first)
        let last = try #require(stays.last)
        let trip = Trip(startDate: first.start, source: .liveSLC)
        trip.endDate = last.end
        trip.isComplete = true
        context.insert(trip)
        var inserted: [Stay] = []
        for (order, entry) in stays.enumerated() {
            let h3 = try #require(H3Service.cellIndex(
                latitude: entry.latitude, longitude: entry.longitude))
            let pings = entry.pingTimes.map { time -> LocationPing in
                let ping = LocationPing(
                    timestamp: time, latitude: entry.latitude, longitude: entry.longitude,
                    horizontalAccuracy: 10, h3IndexRes6: h3)
                ping.isProcessed = true
                context.insert(ping)
                return ping
            }
            let stay = Stay(
                startTime: entry.start, endTime: entry.end,
                centroidLatitude: entry.latitude, centroidLongitude: entry.longitude,
                h3IndexRes6: h3, pingCount: pings.count,
                distanceFromHomeKm: 100, pingIDs: pings.map(\.id), source: .liveSLC)
            stay.category = .destination
            stay.trip = trip
            stay.orderInTrip = order
            context.insert(stay)
            inserted.append(stay)
        }
        return (trip, inserted)
    }

    /// Backs up `trip` and the source store's Visits, and restores the file
    /// into a new store.
    private static func restoreTripAndVisits(
        _ trip: Trip, from source: ModelContainer
    ) async throws -> ModelContainer {
        let layer = try await ExportSnapshotter(modelContainer: source)
            .snapshotHomeAreaLayer()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: TripDataExporter.makeSnapshots(from: [trip]),
            visits: layer.visits, appVersion: "test"))
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container)
            .importTrips(from: try TripDataImporter.parse(data))
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedVisits == layer.visits.count)
        return container
    }

    @Test(
        "a restored pending departure retracts a stay's tail past its last genuine ping, as it does in the original store; a genuine later ping still holds the stay open",
        arguments: [false, true])
    func restoredPendingDepartureRetractsTheTail(genuineLaterPing: Bool) async throws {
        let midnight = Date(timeIntervalSince1970: 1_685_404_800)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            midnight.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        }
        // The last genuine ping is at 10:00 and clustering extended the end to
        // 12:15; the departure at 11:55 was still pending at backup time.
        let source = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(source)
        let measured = try Self.insertMeasuredTrip(
            [(at(10), at(12, 15), 37.9838, 23.7275, [at(10)])], in: sourceContext)
        let stayID = try #require(measured.stays.first).id
        let departure = Visit(
            arrivalDate: at(10, 5), departureDate: at(11, 55),
            latitude: 37.9838, longitude: 23.7275,
            horizontalAccuracy: 20, receivedAt: at(11, 56),
            stayID: nil, isProcessed: false)
        sourceContext.insert(departure)
        try sourceContext.save()

        let container = try await Self.restoreTripAndVisits(measured.trip, from: source)
        _ = await StayClusterer(modelContainer: source).clusterUnprocessedPings()
        let original = try #require(try ModelContext(source).fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(original.endTime == at(11, 55))

        // A ping recorded after the restore, past the departure, is measured.
        if genuineLaterPing {
            let context = ModelContext(container)
            let restored = try #require(try context.fetch(
                FetchDescriptor<Stay>()).first { $0.id == stayID })
            let ping = LocationPing(
                timestamp: at(12, 10), latitude: 37.9838, longitude: 23.7275,
                horizontalAccuracy: 10, h3IndexRes6: restored.h3IndexRes6)
            ping.isProcessed = true
            context.insert(ping)
            restored.pingIDs += [ping.id]
            restored.pingCount += 1
            try context.save()
        }

        let created = await StayClusterer(modelContainer: container)
            .clusterUnprocessedPings()
        #expect(created == 0)
        let settledContext = ModelContext(container)
        let settled = try #require(try settledContext.fetch(
            FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(settled.startTime == at(10))
        #expect(settled.endTime == (genuineLaterPing ? at(12, 10) : at(11, 55)))
        let visit = try #require(try settledContext.fetch(FetchDescriptor<Visit>()).first)
        #expect(visit.isProcessed)
        #expect(visit.stayID == stayID)
    }

    @Test("a restored pending arrival pulls back the preceding stay's tail past its last genuine ping, as it does in the original store")
    func restoredPendingArrivalPullsBackThePreviousStay() async throws {
        let midnight = Date(timeIntervalSince1970: 1_685_404_800)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            midnight.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        }
        // The first stay's last genuine ping is at 18:00 and its end was
        // extended to 20:00; the next stay, about 5 km away, has a pending Visit
        // arriving at 19:00.
        let source = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(source)
        let measured = try Self.insertMeasuredTrip([
            (at(17), at(20), 37.9838, 23.7275, [at(17), at(18)]),
            (at(21, 30), at(22), 38.0154, 23.6919, [at(21, 30), at(22)]),
        ], in: sourceContext)
        let previousID = measured.stays[0].id
        let nextID = measured.stays[1].id
        sourceContext.insert(Visit(
            arrivalDate: at(19), departureDate: at(23),
            latitude: 38.0154, longitude: 23.6919,
            horizontalAccuracy: 20, receivedAt: at(23, 1),
            stayID: nil, isProcessed: false))
        try sourceContext.save()

        let container = try await Self.restoreTripAndVisits(measured.trip, from: source)
        for store in [source, container] {
            let created = await StayClusterer(modelContainer: store)
                .clusterUnprocessedPings()
            #expect(created == 0)
            let stays = try ModelContext(store).fetch(FetchDescriptor<Stay>())
            let previous = try #require(stays.first { $0.id == previousID })
            let next = try #require(stays.first { $0.id == nextID })
            #expect(previous.endTime == at(18, 59))
            #expect(next.startTime == at(19))
            #expect(next.endTime == at(23))
        }
    }

    @Test("a failed checkpoint rolls back and aborts before using invalidated batch caches")
    func checkpointFailureAbortsImport() async throws {
        let iso = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let trips: [[String: Any]] = (0..<26).map { index in
            let stayStart = start.addingTimeInterval(Double(index) * 86_400)
            return [
                "id": UUID().uuidString,
                "startDate": iso.string(from: stayStart),
                "endDate": iso.string(from: stayStart.addingTimeInterval(3_600)),
                "isComplete": true,
                "classifiedByAI": false,
                "stays": [[
                    "id": UUID().uuidString,
                    "startTime": iso.string(from: stayStart),
                    "endTime": iso.string(from: stayStart.addingTimeInterval(3_600)),
                    "category": "destination",
                    "latitude": 37.9838,
                    "longitude": 23.7275,
                ]],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 8,
            "exportDate": iso.string(from: start),
            "appVersion": "test",
            "tripCount": trips.count,
            "trips": trips,
        ])
        let payload = try TripDataImporter.parse(data)
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        await importer.failSaveCallForTesting(1)

        let (outcome, pending) = await PipelineGate(forTesting: ()).runReturning(touching: []) {
            let outcome = await importer.importTrips(from: payload)
            let pending = await importer.pendingGeocodes()
            return (outcome, pending)
        }

        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.insertedStays == 0)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HexVisit>()) == 0)
        #expect(pending.isEmpty)
    }

    @Test("checkpointed trips never persist titles before final Home validation")
    func finalHomeSaveFailureLeavesCheckpointedTripsUntitled() async throws {
        let iso = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let revision = UUID()
        let trips: [[String: Any]] = (0..<26).map { index in
            let stayStart = start.addingTimeInterval(Double(index) * 86_400)
            return [
                "id": UUID().uuidString,
                "startDate": iso.string(from: stayStart),
                "endDate": iso.string(from: stayStart.addingTimeInterval(3_600)),
                "isComplete": true,
                "classifiedByAI": true,
                "aiGeneratedTitle": "Imported Title \(index)",
                "titleSourceRevision": revision.uuidString,
                "localizedTitles": [[
                    "id": UUID().uuidString,
                    "languageTag": "de",
                    "title": "Importierter Titel \(index)",
                    "sourceTitle": "Imported Title \(index)",
                    "sourceRevision": revision.uuidString,
                    "generationVersion": TripTitleStore.currentGenerationVersion,
                    "updatedAt": iso.string(from: start),
                ]],
                "stays": [[
                    "id": UUID().uuidString,
                    "startTime": iso.string(from: stayStart),
                    "endTime": iso.string(from: stayStart.addingTimeInterval(3_600)),
                    "category": "destination",
                    "latitude": 37.9838,
                    "longitude": 23.7275,
                ]],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 8,
            "exportDate": iso.string(from: start),
            "appVersion": "test",
            "tripCount": trips.count,
            "trips": trips,
            "homes": [[
                "id": UUID().uuidString,
                "label": "Different Home",
                "latitude": 51.5314,
                "longitude": -0.2222,
                "radiusKm": 25.0,
                "startedAt": iso.string(from: start.addingTimeInterval(-86_400)),
            ]],
        ])
        let payload = try TripDataImporter.parse(data)
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        // Call 1 commits the first 25 trips; call 2 is the final Home/title
        // transaction and is intentionally failed.
        await importer.failSaveCallForTesting(2)

        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 25)
        let verification = ModelContext(container)
        let durableTrips = try verification.fetch(FetchDescriptor<Trip>())
        #expect(durableTrips.count == 25)
        #expect(durableTrips.allSatisfy { $0.aiGeneratedTitle == nil })
        #expect(durableTrips.allSatisfy { $0.titleSourceRevision == nil })
        #expect(try verification.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<Home>()) == 0)

        // Retry the same idempotent payload. The first 25 graphs are skipped
        // by UUID, but their still-empty title artifacts must complete in the
        // final Home-validated transaction alongside trip 26.
        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedTrips == 1)
        #expect(retry.skippedExistingTrips == 25)
        let retried = ModelContext(container)
        let completedTrips = try retried.fetch(FetchDescriptor<Trip>())
        #expect(completedTrips.count == 26)
        #expect(completedTrips.allSatisfy { $0.aiGeneratedTitle != nil })
        #expect(completedTrips.allSatisfy {
            $0.titleSourceRevision == revision
        })
        #expect(try retried.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 26)
        #expect(try retried.fetchCount(FetchDescriptor<Home>()) == 1)
    }

    @Test("skipped-existing title completion requires exact membership and never overwrites user or AI titles")
    func skippedExistingTitleCompletionIsConservative() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let iso = ISO8601DateFormatter()
        let revision = UUID()
        let localRevision = UUID()

        func seedTrip(
            id: UUID, stayID: UUID,
            customName: String? = nil,
            aiGeneratedTitle: String? = nil,
            titleSourceRevision: UUID? = nil
        ) {
            let trip = Trip(startDate: start)
            trip.id = id
            trip.isComplete = true
            trip.endDate = start.addingTimeInterval(3_600)
            trip.customName = customName
            trip.aiGeneratedTitle = aiGeneratedTitle
            trip.titleSourceRevision = titleSourceRevision
            let stay = Stay(
                startTime: start,
                endTime: start.addingTimeInterval(3_600),
                centroidLatitude: 37.9838, centroidLongitude: 23.7275,
                h3IndexRes6: "existing-\(stayID.uuidString)",
                pingCount: 2, distanceFromHomeKm: 100, pingIDs: [])
            stay.id = stayID
            stay.category = .destination
            context.insert(trip)
            context.insert(stay)
            stay.trip = trip
        }

        func payloadTrip(id: UUID, stayID: UUID, title: String) -> [String: Any] {
            [
                "id": id.uuidString,
                "startDate": iso.string(from: start),
                "endDate": iso.string(from: start.addingTimeInterval(3_600)),
                "isComplete": true,
                "aiGeneratedTitle": title,
                "titleSourceRevision": revision.uuidString,
                "stays": [[
                    "id": stayID.uuidString,
                    "startTime": iso.string(from: start),
                    "endTime": iso.string(from: start.addingTimeInterval(3_600)),
                    "category": "destination",
                    "latitude": 37.9838,
                    "longitude": 23.7275,
                ]],
            ]
        }

        let eligibleID = UUID()
        let eligibleStayID = UUID()
        seedTrip(id: eligibleID, stayID: eligibleStayID)
        let changedMembershipID = UUID()
        seedTrip(id: changedMembershipID, stayID: UUID())
        let userTitledID = UUID()
        let userTitledStayID = UUID()
        seedTrip(
            id: userTitledID, stayID: userTitledStayID,
            customName: "My own title")
        let aiTitledID = UUID()
        let aiTitledStayID = UUID()
        seedTrip(
            id: aiTitledID, stayID: aiTitledStayID,
            aiGeneratedTitle: "Keep local AI title",
            titleSourceRevision: localRevision)
        try context.save()

        let changedPayloadStayID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 8,
            "trips": [
                payloadTrip(
                    id: eligibleID, stayID: eligibleStayID,
                    title: "Restore eligible title"),
                payloadTrip(
                    id: changedMembershipID, stayID: changedPayloadStayID,
                    title: "Do not resurrect"),
                payloadTrip(
                    id: userTitledID, stayID: userTitledStayID,
                    title: "Do not cover user title"),
                payloadTrip(
                    id: aiTitledID, stayID: aiTitledStayID,
                    title: "Do not replace AI title"),
            ],
        ])
        let payload = try TripDataImporter.parse(data)
        let importer = TripDataImporter(modelContainer: container)

        let outcome = await importer.importTrips(from: payload)

        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.skippedExistingTrips == 4)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let byID = Dictionary(
            trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byID[eligibleID]?.aiGeneratedTitle == "Restore eligible title")
        #expect(byID[eligibleID]?.titleSourceRevision == revision)
        #expect(byID[changedMembershipID]?.aiGeneratedTitle == nil)
        #expect(byID[userTitledID]?.aiGeneratedTitle == nil)
        #expect(byID[userTitledID]?.customName == "My own title")
        #expect(byID[aiTitledID]?.aiGeneratedTitle == "Keep local AI title")
        #expect(byID[aiTitledID]?.titleSourceRevision == localRevision)
    }

    @Test("preview reports new vs existing without mutating the store")
    func previewCountsWithoutWriting() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)

        let fresh = try await importer.preview(of: payload)
        #expect(fresh.newTrips == 1)
        #expect(fresh.newStays == 2)
        #expect(fresh.existingTrips == 0)
        #expect(fresh.malformedEntries == 1)

        let ctx = ModelContext(container)
        #expect(try ctx.fetchCount(FetchDescriptor<Trip>()) == 0)

        _ = await importer.importTrips(from: payload)
        let after = try await importer.preview(of: payload)
        #expect(after.newTrips == 0)
        #expect(after.existingTrips == 1)
    }

    @Test("identity read failures abort preview and import without inserting duplicates")
    func identityReadFailureFailsClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)

        await importer.failIdentityFetchCallForTesting(1)
        var previewThrew = false
        do {
            _ = try await importer.preview(of: payload)
        } catch {
            previewThrew = true
        }
        #expect(previewThrew)

        await importer.failIdentityFetchCallForTesting(1)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.insertedStays == 0)

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<LocationPing>()) == 0)
    }

    // MARK: - v2 round trip (export → parse → import)

    @Test("v8 localized titles export and import exact-source deterministic winners")
    func v8LocalizedTitleFidelity() async throws {
        let canonicalTitle = "Island Summer"
        let storedCanonicalTitle = "  \(canonicalTitle)  "
        let sourceRevision = UUID()
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let olderGenerationID = try #require(UUID(
            uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let higherGenerationID = try #require(UUID(
            uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
        let largerTieID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"))
        let exportWinnerID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        let germanID = UUID()
        let normalizedGermanID = UUID()

        let stay = ExportStaySnapshot(
            id: UUID(),
            startTime: start,
            endTime: start.addingTimeInterval(3_600),
            durationMinutes: 60,
            categoryRaw: StayCategory.destination.rawValue,
            latitude: 37.9838, longitude: 23.7275,
            pingCount: 1, distanceFromHomeKm: 120,
            locality: "Athens", country: "Greece", isoCountryCode: "GR",
            userOverridden: false, isAirport: false,
            sourceRaw: DataSource.liveSLC.rawValue,
            h3IndexRes6: H3Service.cellIndex(
                latitude: 37.9838, longitude: 23.7275) ?? "",
            administrativeArea: nil, subLocality: nil,
            metroName: nil, islandName: nil,
            transitFromPreviousRaw: nil, distanceFromPreviousKm: nil,
            stepsWalked: nil, weatherConditionRaw: nil,
            avgTemperatureC: nil, precipitationMm: nil)

        let snapshot = ExportTripSnapshot(
            id: UUID(), startDate: start,
            endDate: start.addingTimeInterval(86_400),
            isComplete: true, destinationSummary: "Athens",
            countryCodes: "GR", classifiedByAI: true,
            durationDays: 2, stays: [stay], customName: nil,
            aiGeneratedTitle: storedCanonicalTitle, aiGeneratedSummary: nil,
            userEdited: false, sourceRaw: DataSource.liveSLC.rawValue,
            summarySourceRaw: nil,
            localizedTitles: [
                // Generation beats timestamp.
                .init(id: olderGenerationID, languageTag: "el",
                      title: "Παλιότερη γενιά", sourceTitle: canonicalTitle,
                      generationVersion: 1,
                      updatedAt: start.addingTimeInterval(30_000),
                      sourceRevision: sourceRevision),
                .init(id: higherGenerationID, languageTag: "el",
                      title: "Νεότερη γενιά", sourceTitle: canonicalTitle,
                      generationVersion: 2, updatedAt: start,
                      sourceRevision: sourceRevision),
                // Within a generation, timestamp then smaller UUID win.
                .init(id: largerTieID, languageTag: "el",
                      title: "Μεγαλύτερο UUID", sourceTitle: canonicalTitle,
                      generationVersion: 2,
                      updatedAt: start.addingTimeInterval(10_000),
                      sourceRevision: sourceRevision),
                // Same physical UUID/metadata still needs an order-independent
                // content winner; the lexically smaller normalized title wins.
                .init(id: exportWinnerID, languageTag: "el",
                      title: "Ω χαμένος", sourceTitle: canonicalTitle,
                      generationVersion: 2,
                      updatedAt: start.addingTimeInterval(10_000),
                      sourceRevision: sourceRevision),
                .init(id: exportWinnerID, languageTag: "el",
                      title: "Καλοκαίρι στα νησιά", sourceTitle: canonicalTitle,
                      generationVersion: 2,
                      updatedAt: start.addingTimeInterval(10_000),
                      sourceRevision: sourceRevision),
                .init(id: germanID, languageTag: "de",
                      title: "Inselsommer", sourceTitle: canonicalTitle,
                      generationVersion: 1, updatedAt: start,
                      sourceRevision: sourceRevision),
                // Equivalent tag/source spellings collapse and normalize.
                .init(id: normalizedGermanID, languageTag: "DE_de",
                      title: "  Inselurlaub  ", sourceTitle: storedCanonicalTitle,
                      generationVersion: 2, updatedAt: start,
                      sourceRevision: sourceRevision),
                // Stale and incomplete derivatives are not usable exports.
                .init(id: UUID(), languageTag: "fr",
                      title: "Ancien titre", sourceTitle: "Old Canonical",
                      generationVersion: 9, updatedAt: start,
                      sourceRevision: sourceRevision),
                .init(id: UUID(), languageTag: "ja", title: "",
                      sourceTitle: canonicalTitle,
                      generationVersion: 1, updatedAt: start,
                      sourceRevision: sourceRevision),
            ],
            titleSourceRevision: sourceRevision)

        let homeSnapshot = ExportHomeSnapshot(
            id: UUID(), label: "Athens Home",
            latitude: 37.9838, longitude: 23.7275, radiusKm: 25,
            locality: "Athens", administrativeArea: "Attica",
            country: "Greece", isoCountryCode: "GR",
            startedAt: start.addingTimeInterval(-86_400), endedAt: nil)
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [snapshot], homes: [homeSnapshot], appVersion: "test"))
        var root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == TripDataExporter.formatVersion)
        var trips = try #require(root["trips"] as? [[String: Any]])
        var tripJSON = try #require(trips.first)
        #expect(tripJSON["titleSourceRevision"] as? String == sourceRevision.uuidString)
        var titleRows = try #require(
            tripJSON["localizedTitles"] as? [[String: Any]])
        #expect(titleRows.count == 2,
                "export emits one exact-source winner per language")
        let exportedGreek = try #require(
            titleRows.first { $0["languageTag"] as? String == "el" })
        #expect(exportedGreek["id"] as? String == exportWinnerID.uuidString)
        let exportedGerman = try #require(
            titleRows.first { $0["languageTag"] as? String == "de" })
        #expect(exportedGerman["id"] as? String == normalizedGermanID.uuidString)
        #expect(exportedGerman["sourceTitle"] as? String == canonicalTitle)
        #expect(exportedGerman["title"] as? String == "Inselurlaub")

        // Hand-edited/third-party v8 input can still contain duplicates and a
        // stale derivative. Import must independently enforce the same rule.
        let importWinnerID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"))
        let importLargerTieID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000004"))
        let iso = ISO8601DateFormatter()
        let generationThreeDate = iso.string(from: start.addingTimeInterval(-10_000))
        func injected(
            id: UUID, languageTag: String, title: String,
            sourceTitle: String, generation: Int
        ) -> [String: Any] {
            [
                "id": id.uuidString,
                "languageTag": languageTag,
                "title": title,
                "sourceTitle": sourceTitle,
                "generationVersion": generation,
                "updatedAt": generationThreeDate,
                "sourceRevision": sourceRevision.uuidString,
            ]
        }
        titleRows.append(injected(
            id: importLargerTieID, languageTag: "el",
            title: "Μεγαλύτερο UUID εισαγωγής",
            sourceTitle: canonicalTitle, generation: 3))
        titleRows.append(injected(
            id: importWinnerID, languageTag: "el",
            title: "Ω χαμένος εισαγωγής",
            sourceTitle: canonicalTitle, generation: 3))
        titleRows.append(injected(
            id: importWinnerID, languageTag: "el",
            title: "Νικητής εισαγωγής",
            sourceTitle: canonicalTitle, generation: 3))
        titleRows.append(injected(
            id: UUID(), languageTag: "fr", title: "Périmé",
            sourceTitle: "Old Canonical", generation: 99))
        tripJSON["localizedTitles"] = titleRows
        trips[0] = tripJSON
        root["trips"] = trips
        let importData = try JSONSerialization.data(withJSONObject: root)

        let payload = try TripDataImporter.parse(importData)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)
        let container = try TestSupport.makeInMemoryContainer()
        let existingContext = ModelContext(container)
        let preexistingRevision = UUID()
        let preexistingTrip = Trip(
            startDate: start.addingTimeInterval(-1_000_000))
        preexistingTrip.aiGeneratedTitle = "Pre-import Title"
        preexistingTrip.titleSourceRevision = preexistingRevision
        existingContext.insert(preexistingTrip)
        existingContext.insert(TripTitleVariant(
            languageTag: "de", title: "Titel vor Import",
            sourceTitle: "Pre-import Title",
            sourceRevision: preexistingRevision,
            trip: preexistingTrip))
        try existingContext.save()

        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let verification = ModelContext(container)
        let restored = try verification.fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(restored.count == 2)
        let greek = try #require(restored.first { $0.languageTag == "el" })
        #expect(greek.id == importWinnerID)
        #expect(greek.title == "Νικητής εισαγωγής")
        #expect(greek.sourceTitle == canonicalTitle)
        #expect(restored.first { $0.languageTag == "de" }?.id == normalizedGermanID)
        #expect(restored.allSatisfy { $0.trip?.id == snapshot.id })
        #expect(restored.allSatisfy { $0.sourceTitle == canonicalTitle })
        #expect(restored.allSatisfy { $0.sourceRevision == sourceRevision })
        let restoredTrip = try #require(restored.first?.trip)
        #expect(restoredTrip.titleSourceRevision == sourceRevision)
        #expect(restoredTrip.aiGeneratedTitle == canonicalTitle)
        #expect(try verification.fetch(FetchDescriptor<Home>()).count == 1)

        let reloadedPreexisting = try #require(try verification.fetch(
            FetchDescriptor<Trip>()).first { $0.id == preexistingTrip.id })
        #expect(reloadedPreexisting.aiGeneratedTitle == nil,
                "the imported Home still invalidates pre-existing titles")
        #expect(reloadedPreexisting.titleSourceRevision == nil)
        #expect((reloadedPreexisting.localizedTitles ?? []).isEmpty)
    }

    @Test("v8 titles survive collapsing the fresh-install onboarding Home twin")
    func v8TitlesSurviveOnboardingHomeCollapse() async throws {
        let revision = UUID()
        let importedHomeID = try #require(UUID(
            uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE"))
        let onboardingHomeID = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"))
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 8
        var trips = try #require(root["trips"] as? [[String: Any]])
        var trip = try #require(trips.first)
        var stays = try #require(trip["stays"] as? [[String: Any]])
        stays.removeLast() // remove the intentionally malformed v1 fixture row
        trip["stays"] = stays
        trip["aiGeneratedTitle"] = "Japan Journey"
        trip["titleSourceRevision"] = revision.uuidString
        trip["localizedTitles"] = [[
            "id": UUID().uuidString,
            "languageTag": "de",
            "title": "Japanreise",
            "sourceTitle": "Japan Journey",
            "sourceRevision": revision.uuidString,
            "generationVersion": TripTitleStore.currentGenerationVersion,
            "updatedAt": "2025-07-17T00:00:00Z",
        ]]
        trips[0] = trip
        root["trips"] = trips
        root["homes"] = [[
            "id": importedHomeID.uuidString,
            "label": "Athens Home",
            "latitude": 37.9838,
            "longitude": 23.7275,
            "radiusKm": 25.0,
            "country": "Greece",
            "isoCountryCode": "GR",
            "startedAt": "2019-07-17T00:00:00Z",
        ]]

        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let container = try TestSupport.makeInMemoryContainer()
        let seed = ModelContext(container)
        let onboardingHome = Home(
            label: "Athens Home", latitude: 37.9840,
            longitude: 23.7275, radiusKm: 25,
            startedAt: Date(timeIntervalSince1970: 1_563_321_600))
        onboardingHome.id = onboardingHomeID
        onboardingHome.country = "Greece"
        onboardingHome.isoCountryCode = "GR"
        seed.insert(onboardingHome)
        try seed.save()

        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        // Settings still runs the shared deduplicator after import. It must be
        // an idempotent no-op, not a second title-invalidating transition.
        await PlacesDeduplicator.deduplicateAll(modelContainer: container)

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil })) == 1)
        let restored = try #require(try verification.fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == "Japan Journey")
        #expect(restored.titleSourceRevision == revision)
        let variant = try #require(restored.localizedTitles?.first)
        #expect(variant.languageTag == "de")
        #expect(variant.title == "Japanreise")
        #expect(variant.sourceRevision == revision)
    }

    @Test("partial import preserves a custom name but drops full-trip AI artifacts")
    func partialImportInvalidatesDerivedTitles() async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 8
        var trips = try #require(root["trips"] as? [[String: Any]])
        var trip = try #require(trips.first)
        let revision = UUID()
        trip["customName"] = "My Japan Journey"
        trip["aiGeneratedTitle"] = "Kyoto & Osaka"
        trip["titleSourceRevision"] = revision.uuidString
        trip["aiGeneratedSummary"] = "A narrative about both Kyoto and Osaka."
        trip["summarySourceRaw"] = SummarySource.foundationModels.rawValue
        trip["localizedTitles"] = [[
            "id": UUID().uuidString,
            "languageTag": "de",
            "title": "Kyoto & Osaka auf Deutsch",
            "sourceTitle": "Kyoto & Osaka",
            "sourceRevision": revision.uuidString,
            "generationVersion": 1,
            "updatedAt": "2025-07-17T00:00:00Z",
        ]]
        trips[0] = trip
        root["trips"] = trips
        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // One payload stay already exists, so the new Trip can restore only
        // Kyoto. This is the importer's real skip-existing partial path.
        let existing = Stay(
            startTime: Date(timeIntervalSince1970: 1_700_225_600),
            endTime: Date(timeIntervalSince1970: 1_700_312_400),
            centroidLatitude: 34.6946, centroidLongitude: 135.4651,
            h3IndexRes6: "existing-osaka", pingCount: 9,
            distanceFromHomeKm: 9_400, pingIDs: [])
        existing.id = try #require(UUID(
            uuidString: "33333333-3333-3333-3333-333333333333"))
        existing.category = .destination
        context.insert(existing)
        try context.save()

        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.customName == "My Japan Journey")
        #expect(restored.aiGeneratedTitle == nil)
        #expect(restored.titleSourceRevision == nil)
        #expect(restored.aiGeneratedSummary == nil)
        #expect((restored.localizedTitles ?? []).isEmpty)
        #expect(restored.stays?.count == 1)
        let restoredStay = try #require(restored.stays?.first)
        #expect(restored.startDate == restoredStay.startTime)
        #expect(restored.endDate == restoredStay.endTime)
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("a malformed declared member prevents full-trip AI artifact restore", arguments: [false, true])
    func malformedMemberInvalidatesDerivedTitles(nonObject: Bool) async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 8
        var trips = try #require(root["trips"] as? [[String: Any]])
        var trip = try #require(trips.first)
        if nonObject {
            var members = try #require(trip["stays"] as? [Any])
            members[2] = NSNull()
            trip["stays"] = members
        }
        let revision = UUID()
        trip["aiGeneratedTitle"] = "Kyoto & Osaka"
        trip["titleSourceRevision"] = revision.uuidString
        trip["aiGeneratedSummary"] = "A narrative about the complete trip."
        trip["localizedTitles"] = [[
            "id": UUID().uuidString,
            "languageTag": "de",
            "title": "Kyoto und Osaka",
            "sourceTitle": "Kyoto & Osaka",
            "sourceRevision": revision.uuidString,
            "generationVersion": 1,
            "updatedAt": "2025-07-17T00:00:00Z",
        ]]
        trips[0] = trip
        root["trips"] = trips

        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let importedTrip = try #require(payload.trips.first)
        #expect(importedTrip.declaredStayCount == 3)
        #expect(importedTrip.stays.count == 2)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.stays?.count == 2)
        #expect(restored.aiGeneratedTitle == nil)
        #expect(restored.titleSourceRevision == nil)
        #expect(restored.aiGeneratedSummary == nil)
        #expect((restored.localizedTitles ?? []).isEmpty)
    }

    @Test("equal-start imported stays receive deterministic UUID order")
    func equalStartStayOrderIsDeterministic() async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        var trips = try #require(root["trips"] as? [[String: Any]])
        var trip = try #require(trips.first)
        var stays = try #require(trip["stays"] as? [[String: Any]])
        stays = Array(stays.prefix(2).reversed())
        stays[0]["startTime"] = "2023-11-15T10:00:00Z"
        stays[1]["startTime"] = "2023-11-15T10:00:00Z"
        trip["stays"] = stays
        trips[0] = trip
        root["trips"] = trips

        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        let container = try TestSupport.makeInMemoryContainer()
        _ = await TripDataImporter(modelContainer: container)
            .importTrips(from: payload)

        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        let ids = (restored.stays ?? [])
            .sorted { ($0.orderInTrip ?? 0) < ($1.orderInTrip ?? 0) }
            .map(\.id.uuidString)
        #expect(ids == ids.sorted())
    }

    @Test("v4 round-trips summary provenance; unknown and absent values stay nil")
    func summaryProvenanceRoundTrips() async throws {
        // Without `summarySourceRaw` in the export, a restore would drop the
        // stored narrative's provenance.
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        // One insertable stay per trip; the importer's phantom-trip guard
        // (deliberately) drops trips whose every stay is uninsertable.
        func snapshot(id: UUID, sourceRaw: String?) -> ExportTripSnapshot {
            let stay = ExportStaySnapshot(
                id: UUID(),
                startTime: start.addingTimeInterval(3600),
                endTime: start.addingTimeInterval(7200),
                durationMinutes: 60,
                categoryRaw: "destination",
                latitude: 37.9838, longitude: 23.7275,
                pingCount: 1, distanceFromHomeKm: 10,
                locality: "Athens", country: "Greece", isoCountryCode: "GR",
                userOverridden: false, isAirport: false, sourceRaw: "liveSLC",
                h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? "",
                administrativeArea: nil, subLocality: nil,
                metroName: nil, islandName: nil,
                transitFromPreviousRaw: nil, distanceFromPreviousKm: nil,
                stepsWalked: nil, weatherConditionRaw: nil,
                avgTemperatureC: nil, precipitationMm: nil
            )
            return ExportTripSnapshot(
                id: id, startDate: start, endDate: start.addingTimeInterval(86400),
                isComplete: true, destinationSummary: "Athens", countryCodes: "GR",
                classifiedByAI: false, durationDays: 2, stays: [stay],
                customName: nil, aiGeneratedTitle: nil,
                aiGeneratedSummary: "A deterministic story.",
                userEdited: false, sourceRaw: "liveSLC",
                summarySourceRaw: sourceRaw
            )
        }
        let knownID = UUID()
        let bogusID = UUID()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [
                snapshot(id: knownID, sourceRaw: SummarySource.deterministic.rawValue),
                // A hand-edited file must not smuggle unknown provenance.
                snapshot(id: bogusID, sourceRaw: "chatbot9000"),
            ],
            appVersion: "test"
        ))
        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let ctx = ModelContext(container)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        let known = try #require(trips.first { $0.id == knownID })
        #expect(known.summarySourceRaw == SummarySource.deterministic.rawValue)
        let bogus = try #require(trips.first { $0.id == bogusID })
        #expect(bogus.summarySourceRaw == nil)
        #expect(bogus.aiGeneratedSummary == "A deterministic story.")
    }

    @Test("v5: tripless travel stays round-trip through the top-level unassignedStays array")
    func v5UnassignedStaysRoundTrip() async throws {
        // The trip-centric walk silently dropped every trip==nil stay
        // because transit residue is steady state, and a mid-sync
        // export can catch a destination stay before its Trip link arrives.
        let orphanID = UUID()
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let orphan = ExportStaySnapshot(
            id: orphanID,
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            durationMinutes: 60,
            categoryRaw: "transit",
            latitude: 37.9838,
            longitude: 23.7275,
            pingCount: 3,
            distanceFromHomeKm: 120,
            locality: "Gérakas",
            country: "Greece",
            isoCountryCode: "GR",
            userOverridden: false,
            isAirport: false,
            sourceRaw: "liveSLC",
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? "",
            administrativeArea: "Attica",
            subLocality: nil,
            metroName: "Athens",
            islandName: nil,
            transitFromPreviousRaw: nil,
            distanceFromPreviousKm: nil,
            stepsWalked: nil,
            weatherConditionRaw: nil,
            avgTemperatureC: nil,
            precipitationMm: nil
        )
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], unassignedStays: [orphan], appVersion: "test"
        ))
        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)
        #expect(payload.unassignedStays.count == 1)
        #expect(payload.totalStays == 1)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newStays == 1)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedStays == 1)

        let ctx = ModelContext(container)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.id == orphanID)
        #expect(stay.trip == nil)          // residue re-enters as residue
        #expect(stay.category == .transit)
        #expect(stay.pingCount >= 2)       // synthetic pings minted
        // No phantom trip was created for it.
        #expect(try ctx.fetch(FetchDescriptor<Trip>()).isEmpty)

        // Re-import is a no-op (id-idempotent, same as trips).
        let second = await importer.importTrips(from: payload)
        #expect(second.insertedStays == 0)
    }

    @Test("v6: homes, home stays protected by demotion, and overrides round-trip")
    func v6HomeAreaLayerRoundTrips() async throws {
        // Without v6 a restore lost the orbit's return evidence and every
        // "this wasn't a trip" teaching; the home area shrank to the seed
        // and near-home trips welded.
        let homeID = UUID()
        let overrideID = UUID()
        let sacredStayID = UUID()
        let start = Date(timeIntervalSince1970: 1_685_484_800)

        let home = ExportHomeSnapshot(
            id: homeID, label: "Athens Home",
            latitude: 38.0, longitude: 23.8, radiusKm: 25,
            locality: "Athens", administrativeArea: "Attica",
            country: "Greece", isoCountryCode: "GR",
            startedAt: start.addingTimeInterval(-90 * 86400), endedAt: nil)
        let sacredHomeStay = ExportStaySnapshot(
            id: sacredStayID,
            startTime: start,
            endTime: start.addingTimeInterval(4 * 3600),
            durationMinutes: 240,
            categoryRaw: "home",
            latitude: 38.0,
            longitude: 23.99,
            pingCount: 3,
            distanceFromHomeKm: 17,
            locality: "Vílla",
            country: "Greece",
            isoCountryCode: "GR",
            userOverridden: true,   // Protected home stay from trip demotion
            isAirport: false,
            sourceRaw: "liveSLC",
            h3IndexRes6: H3Service.cellIndex(latitude: 38.0, longitude: 23.99) ?? "",
            administrativeArea: "Attica",
            subLocality: nil,
            metroName: "Athens",
            islandName: nil,
            transitFromPreviousRaw: nil,
            distanceFromPreviousKm: nil,
            stepsWalked: nil,
            weatherConditionRaw: nil,
            avgTemperatureC: nil,
            precipitationMm: nil
        )
        let overrideRow = ExportOverrideSnapshot(
            id: overrideID, kindRaw: "include",
            centerLatitude: 38.0, centerLongitude: 23.99,
            radiusKm: 1, homeID: homeID,
            sourceTripName: "Village Weekend", createdAt: start)

        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], homes: [home], homeStays: [sacredHomeStay],
            homeAreaOverrides: [overrideRow], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)
        #expect(payload.homes.count == 1)
        #expect(payload.homeStays.count == 1)
        #expect(payload.homeAreaOverrides.count == 1)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedHomes == 1)
        #expect(outcome.insertedOverrides == 1)
        #expect(outcome.insertedStays == 1)

        let ctx = ModelContext(container)
        let restoredHome = try #require(try ctx.fetch(FetchDescriptor<Home>()).first)
        #expect(restoredHome.id == homeID)
        #expect(restoredHome.label == "Athens Home")
        #expect(restoredHome.endedAt == nil)
        let restoredStay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(restoredStay.id == sacredStayID)
        #expect(restoredStay.category == .home)
        #expect(restoredStay.userOverridden, "trip demotion history survives the restore")
        let restoredOverride = try #require(try ctx.fetch(
            FetchDescriptor<HomeAreaOverride>()).first)
        #expect(restoredOverride.id == overrideID)
        #expect(restoredOverride.kind == .include)
        #expect(restoredOverride.homeID == homeID,
                "era-scoping survives — the Home row rode along")
        #expect(restoredOverride.sourceTripName == "Village Weekend")

        // Re-import is a no-op across all three v6 arrays.
        let second = await importer.importTrips(from: payload)
        #expect(second.insertedHomes == 0)
        #expect(second.insertedOverrides == 0)
        #expect(second.insertedStays == 0)

        // Pre-v6 files (no home-area keys) parse to empty arrays.
        let v5Data = try #require(TripDataExporter.buildExportData(
            snapshots: [], appVersion: "test"))
        let v5Payload = try TripDataImporter.parse(v5Data)
        #expect(v5Payload.homes.isEmpty)
        #expect(v5Payload.homeStays.isEmpty)
        #expect(v5Payload.homeAreaOverrides.isEmpty)
    }

    @Test("pre-v6 canonical titles restore even when the target has an active Home")
    func preV6TitlesIgnoreUnavailableHomeContext() async throws {
        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = 5
        var trips = try #require(root["trips"] as? [[String: Any]])
        var trip = try #require(trips.first)
        var stays = try #require(trip["stays"] as? [[String: Any]])
        stays.removeLast() // remove the intentionally malformed fixture row
        trip["stays"] = stays
        trip["aiGeneratedTitle"] = "Legacy Japan Journey"
        trips[0] = trip
        root["trips"] = trips
        let payload = try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
        #expect(payload.formatVersion == 5)
        #expect(payload.homes.isEmpty)

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(
            label: "Current Home", latitude: 37.9838,
            longitude: 23.7275, radiusKm: 25,
            startedAt: Date(timeIntervalSince1970: 1_485_484_800)))
        try context.save()

        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)

        #expect(!outcome.saveFailed)
        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.aiGeneratedTitle == "Legacy Japan Journey")
        #expect(restored.titleSourceRevision == nil,
                "pre-v8 payloads have no source revision to restore")
    }

    @Test("v6 hardening: reversed home eras are rejected, radii clamp, duplicate ids insert once, routine places round-trip")
    func v6RejectsPoisonAndClampsRadii() async throws {
        // A reversed home era used to import verbatim and fatalError every
        // pipeline pass (`DateInterval` on a reversed range); unrecoverable
        // crash loop for a malformed backup.
        let goodHomeID = UUID()
        let dupOverrideID = UUID()
        let placeID = UUID()
        let json = """
        {
          "formatVersion": 6,
          "trips": [],
          "homes": [
            { "id": "\(UUID().uuidString)", "latitude": 38.0, "longitude": 23.8,
              "startedAt": "2025-07-17T00:00:00Z", "endedAt": "2024-07-17T00:00:00Z" },
            { "id": "\(goodHomeID.uuidString)", "label": "Home",
              "latitude": 38.0, "longitude": 23.8, "radiusKm": 99999,
              "startedAt": "2023-07-17T00:00:00Z" }
          ],
          "homeAreaOverrides": [
            { "id": "\(dupOverrideID.uuidString)", "kindRaw": "include",
              "centerLatitude": 38.0, "centerLongitude": 23.99,
              "radiusKm": 1000000, "createdAt": "2025-07-17T00:00:00Z" },
            { "id": "\(dupOverrideID.uuidString)", "kindRaw": "include",
              "centerLatitude": 38.0, "centerLongitude": 23.99,
              "radiusKm": 1, "createdAt": "2025-07-17T00:00:00Z" },
            { "id": "\(UUID().uuidString)", "kindRaw": "somethingNew",
              "centerLatitude": 38.0, "centerLongitude": 23.99 }
          ],
          "routinePlaces": [
            { "id": "\(placeID.uuidString)", "label": "Gym",
              "latitude": 38.01, "longitude": 23.81, "radiusMeters": 400,
              "isActive": true, "startedAt": "2024-12-15T00:00:00Z" }
          ]
        }
        """
        let payload = try TripDataImporter.parse(Data(json.utf8))
        #expect(payload.homes.count == 1, "the reversed-era home is malformed, not imported")
        #expect(payload.homes.first?.radiusKm == 500, "home radius clamps")
        #expect(payload.homeAreaOverrides.count == 2, "unknown kindRaw is malformed, not silently dropped")
        #expect(payload.homeAreaOverrides.allSatisfy { $0.radiusKm <= 25 }, "override radius clamps — no planet-sized home teaching")
        #expect(payload.malformedTrips == 2)
        #expect(payload.routinePlaces.count == 1)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedOverrides == 1, "duplicate ids WITHIN one file insert once")
        #expect(outcome.insertedHomes == 1)
        #expect(outcome.insertedRoutinePlaces == 1)

        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<HomeAreaOverride>()).count == 1)
        let place = try #require(try ctx.fetch(FetchDescriptor<RoutinePlace>()).first)
        #expect(place.id == placeID)
        #expect(place.label == "Gym")
        #expect(place.radiusMeters == 400)
        // The admission preview counts home-area rows, so a corrections-only
        // file passes the gate (it used to be refused as "nothing to import").
        let freshImporter = TripDataImporter(modelContainer: try TestSupport.makeInMemoryContainer())
        let preview = try await freshImporter.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newHomeAreaRows == 3)
    }

    @Test("a restore leaves home-named destinations out of trip summaries")
    func restoredSummariesDropHomeNamedDestinations() async throws {
        // The per-trip recompute runs before the file's Homes and home stays
        // land, so on a fresh install it kept the Agia Kyriakií Spáton ferry-port "Athens"
        // wait and restored "Aegina, Athens" for an Athens resident.
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        func stay(
            _ offsetHours: Double, hours: Double, category: String,
            latitude: Double, longitude: Double, locality: String,
            metro: String?, island: String?
        ) -> ExportStaySnapshot {
            ExportStaySnapshot(
                id: UUID(),
                startTime: start.addingTimeInterval(offsetHours * 3600),
                endTime: start.addingTimeInterval((offsetHours + hours) * 3600),
                durationMinutes: Int(hours * 60),
                categoryRaw: category,
                latitude: latitude, longitude: longitude,
                pingCount: 3, distanceFromHomeKm: 30,
                locality: locality, country: "Greece", isoCountryCode: "GR",
                userOverridden: false, isAirport: false, sourceRaw: "liveSLC",
                h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude) ?? "",
                administrativeArea: "Attica", subLocality: nil,
                metroName: metro, islandName: island,
                transitFromPreviousRaw: nil, distanceFromPreviousKm: nil,
                stepsWalked: nil, weatherConditionRaw: nil,
                avgTemperatureC: nil, precipitationMm: nil)
        }
        func trip(_ id: UUID, _ stays: [ExportStaySnapshot]) -> ExportTripSnapshot {
            ExportTripSnapshot(
                id: id, startDate: stays[0].startTime,
                endDate: stays[stays.count - 1].endTime, isComplete: true,
                destinationSummary: "", countryCodes: "GR",
                classifiedByAI: false, durationDays: 4, stays: stays,
                customName: nil, aiGeneratedTitle: nil,
                aiGeneratedSummary: nil, userEdited: false, sourceRaw: "liveSLC")
        }
        let aeginaTripID = UUID()
        let portOnlyTripID = UUID()
        let home = ExportHomeSnapshot(
            id: UUID(), label: "Home",
            latitude: 38.0, longitude: 23.8, radiusKm: 25,
            locality: "Athens", administrativeArea: "Attica",
            country: "Greece", isoCountryCode: "GR",
            startedAt: start.addingTimeInterval(-730 * 86400), endedAt: nil)
        let homeStay = stay(-240, hours: 20, category: "home",
                            latitude: 38.0, longitude: 23.8, locality: "Athens",
                            metro: "Athens", island: nil)
        let aeginaTrip = trip(aeginaTripID, [
            stay(0, hours: 3, category: "destination",
                 latitude: 37.99336, longitude: 23.97796, locality: "Agia Kyriakií Spáton",
                 metro: "Athens", island: nil),
            stay(6, hours: 80, category: "destination",
                 latitude: 37.74667, longitude: 23.4275, locality: "Aegina",
                 metro: nil, island: "Aegina"),
        ])
        let portOnlyTrip = trip(portOnlyTripID, [
            stay(200, hours: 5, category: "destination",
                 latitude: 37.99336, longitude: 23.97796, locality: "Agia Kyriakií Spáton",
                 metro: "Athens", island: nil),
        ])

        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [aeginaTrip, portOnlyTrip], homes: [home],
            homeStays: [homeStay], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container)
            .importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 2)

        TripTitleStore.invalidateHomePlaceIndex()
        let ctx = ModelContext(container)
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        let restored = try #require(trips.first { $0.id == aeginaTripID })
        #expect(restored.destinationSummary == "Aegina")
        restored.recomputeSummary()
        #expect(restored.destinationSummary == "Aegina")
        let portOnly = try #require(trips.first { $0.id == portOnlyTripID })
        #expect(portOnly.destinationSummary == "Athens",
                "a trip with nothing else keeps its home name")
    }

    private static let restoreFixtureStart = Date(timeIntervalSince1970: 1_685_484_800)

    private static func restoreFixtureStay(
        _ offsetHours: Double, hours: Double, category: String = "destination",
        latitude: Double, longitude: Double, locality: String,
        metro: String? = nil, island: String? = nil,
        country: String = "Greece", isoCountryCode: String = "GR",
        administrativeArea: String = "Attica"
    ) -> ExportStaySnapshot {
        let start = restoreFixtureStart
        return ExportStaySnapshot(
            id: UUID(),
            startTime: start.addingTimeInterval(offsetHours * 3600),
            endTime: start.addingTimeInterval((offsetHours + hours) * 3600),
            durationMinutes: Int(hours * 60),
            categoryRaw: category,
            latitude: latitude, longitude: longitude,
            pingCount: 3, distanceFromHomeKm: 30,
            locality: locality, country: country, isoCountryCode: isoCountryCode,
            userOverridden: false, isAirport: false, sourceRaw: "liveSLC",
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude) ?? "",
            administrativeArea: administrativeArea, subLocality: nil,
            metroName: metro, islandName: island,
            transitFromPreviousRaw: nil, distanceFromPreviousKm: nil,
            stepsWalked: nil, weatherConditionRaw: nil,
            avgTemperatureC: nil, precipitationMm: nil)
    }

    private static func restoreFixtureTrip(
        _ id: UUID, _ stays: [ExportStaySnapshot]
    ) -> ExportTripSnapshot {
        ExportTripSnapshot(
            id: id, startDate: stays[0].startTime,
            endDate: stays[stays.count - 1].endTime, isComplete: true,
            destinationSummary: "", countryCodes: "GR",
            classifiedByAI: false, durationDays: 4, stays: stays,
            customName: nil, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, userEdited: false, sourceRaw: "liveSLC")
    }

    /// A Agia Kyriakií Spáton ferry-port wait, which carries the "Athens" metro, then Aegina.
    private static func aeginaStays(at offsetHours: Double = 0) -> [ExportStaySnapshot] {
        [
            restoreFixtureStay(offsetHours, hours: 3,
                               latitude: 37.99336, longitude: 23.97796,
                               locality: "Agia Kyriakií Spáton", metro: "Athens"),
            restoreFixtureStay(offsetHours + 6, hours: 80,
                               latitude: 37.74667, longitude: 23.4275,
                               locality: "Aegina", island: "Aegina"),
        ]
    }

    /// An Athens resident's backup of `trips`, with the declared Home and a
    /// home stay unless `withHomes` is false.
    private static func restorePayload(
        _ trips: [ExportTripSnapshot], withHomes: Bool = true
    ) throws -> ImportPayload {
        let home = ExportHomeSnapshot(
            id: UUID(), label: "Home",
            latitude: 38.0, longitude: 23.8, radiusKm: 25,
            locality: "Athens", administrativeArea: "Attica",
            country: "Greece", isoCountryCode: "GR",
            startedAt: restoreFixtureStart.addingTimeInterval(-730 * 86400),
            endedAt: nil)
        let homeStay = restoreFixtureStay(
            -240, hours: 20, category: "home",
            latitude: 38.0, longitude: 23.8, locality: "Athens", metro: "Athens")
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: trips, homes: withHomes ? [home] : [],
            homeStays: withHomes ? [homeStay] : [], appVersion: "test"))
        return try TripDataImporter.parse(data)
    }

    /// The Aegina trip, followed by `extraTrips` one-stay Cephalonia trips.
    private static func aeginaRestoreFixture(
        aeginaTripID: UUID, extraTrips: Int = 0
    ) throws -> ImportPayload {
        let cephaloniaTrips = (0..<extraTrips).map { index in
            restoreFixtureTrip(UUID(), [
                restoreFixtureStay(Double(index + 1) * 240, hours: 30,
                                   latitude: 38.20133, longitude: 20.43706,
                                   locality: "Lixoúri", island: "Cephalonia"),
            ])
        }
        return try restorePayload(
            [restoreFixtureTrip(aeginaTripID, aeginaStays())] + cephaloniaTrips)
    }

    @Test("a retried restore re-derives the summaries an interrupted run checkpointed before its Homes landed")
    func retriedRestoreRederivesCheckpointedSummaries() async throws {
        let aeginaTripID = UUID()
        let payload = try Self.aeginaRestoreFixture(
            aeginaTripID: aeginaTripID, extraTrips: 25)
        let container = try TestSupport.makeInMemoryContainer()

        // Save 1 commits trips 1-25 with summaries derived before any Home
        // or home stay exists; save 2 is the final Home transaction and
        // fails, leaving the store where a kill at that point would.
        let interrupted = TripDataImporter(modelContainer: container)
        await interrupted.failSaveCallForTesting(2)
        let first = await interrupted.importTrips(from: payload)
        #expect(first.saveFailed)
        #expect(first.insertedTrips == 25)
        let afterInterruption = ModelContext(container)
        #expect(try afterInterruption.fetchCount(FetchDescriptor<Home>()) == 0)
        let checkpointed = try #require(try afterInterruption
            .fetch(FetchDescriptor<Trip>()).first { $0.id == aeginaTripID })
        #expect(checkpointed.destinationSummary.contains("Athens"))

        // The retry skips trips 1-25 by UUID while their Homes land now.
        let retry = await TripDataImporter(modelContainer: container)
            .importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedTrips == 1)
        #expect(retry.skippedExistingTrips == 25)
        #expect(retry.insertedHomes == 1)

        let restored = try #require(try ModelContext(container)
            .fetch(FetchDescriptor<Trip>()).first { $0.id == aeginaTripID })
        #expect(restored.destinationSummary == "Aegina")
    }

    @Test("the post-Home recompute keeps stayless trip rows' summaries for the ghost sweep")
    func postHomeRecomputeKeepsStaylessRowSummary() async throws {
        // A completed row with no stays is a possible ghost; the sweep finds
        // its winner by summary and countries, so a recompute to "" would
        // strand any user data it carries. The file may list such a row
        // with the trip's stays or, exported as a ghost itself, with none.
        let aeginaTripID = UUID()
        let exportedGhostID = UUID()
        let ghostStart = Self.restoreFixtureStart.addingTimeInterval(240 * 3600)
        let exportedGhost = ExportTripSnapshot(
            id: exportedGhostID, startDate: ghostStart,
            endDate: ghostStart.addingTimeInterval(86 * 3600), isComplete: true,
            destinationSummary: "Aegina", countryCodes: "GR",
            classifiedByAI: false, durationDays: 4, stays: [],
            customName: nil, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, userEdited: false, sourceRaw: "liveSLC")
        let payload = try Self.restorePayload([
            Self.restoreFixtureTrip(aeginaTripID, Self.aeginaStays()),
            exportedGhost,
        ])
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for (id, start) in [(aeginaTripID, Self.restoreFixtureStart),
                            (exportedGhostID, ghostStart)] {
            let ghost = Trip(startDate: start)
            ghost.id = id
            ghost.isComplete = true
            ghost.endDate = start.addingTimeInterval(86 * 3600)
            ghost.destinationSummary = "Aegina"
            ghost.countryCodes = "GR"
            context.insert(ghost)
        }
        try context.save()

        let outcome = await TripDataImporter(modelContainer: container)
            .importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.skippedExistingTrips == 2)
        #expect(outcome.insertedHomes == 1)

        let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        for id in [aeginaTripID, exportedGhostID] {
            let row = try #require(rows.first { $0.id == id })
            #expect((row.stays ?? []).isEmpty)
            #expect(row.destinationSummary == "Aegina")
            #expect(row.countryCodes == "GR")
        }
    }

    @Test("the post-Home recompute keeps skipped rows whose summaries came from stays this device lacks")
    func postHomeRecomputeKeepsSummariesFromStaysNotHeld() async throws {
        // Skipped rows the owning device changed after the backup, whose Trip
        // record synced ahead of the stay changes. Re-deriving them from the
        // stays at hand would sync a wrong summary over the right one, and
        // nothing re-derives a completed trip when its stays arrive later.
        let checkpointedID = UUID()
        let stillSyncingID = UUID()
        let grewElsewhereID = UUID()
        let shrankElsewhereID = UUID()
        let checkpointed = Self.restoreFixtureTrip(checkpointedID, Self.aeginaStays())
        let syncedAegina = Self.restoreFixtureStay(
            240, hours: 40, latitude: 37.74667, longitude: 23.4275,
            locality: "Aegina", island: "Aegina")
        let bodrum = Self.restoreFixtureStay(
            290, hours: 40, latitude: 37.03, longitude: 27.43,
            locality: "Bodrum", country: "Türkiye", isoCountryCode: "TR",
            administrativeArea: "Muğla")
        let grewElsewhere = Self.restoreFixtureTrip(
            grewElsewhereID, Self.aeginaStays(at: 480))
        let shrankElsewhere = Self.restoreFixtureTrip(shrankElsewhereID, [
            Self.restoreFixtureStay(720, hours: 40, latitude: 37.74667, longitude: 23.4275,
                                    locality: "Aegina", island: "Aegina"),
            Self.restoreFixtureStay(770, hours: 40, latitude: 38.20133, longitude: 20.43706,
                                    locality: "Lixoúri", island: "Cephalonia"),
        ])
        let container = try TestSupport.makeInMemoryContainer()

        // What this device holds before the restore, derived without Homes.
        let held = await TripDataImporter(modelContainer: container)
            .importTrips(from: try Self.restorePayload([
                checkpointed,
                Self.restoreFixtureTrip(stillSyncingID, [syncedAegina]),
                grewElsewhere, shrankElsewhere,
            ], withHomes: false))
        #expect(!held.saveFailed)
        #expect(held.insertedTrips == 4)
        let context = ModelContext(container)
        let heldRows = try context.fetch(FetchDescriptor<Trip>())
        let heldCheckpointed = try #require(heldRows.first { $0.id == checkpointedID })
        #expect(heldCheckpointed.destinationSummary == "Athens, Aegina")
        // Bodrum has not arrived yet.
        let stillSyncing = try #require(heldRows.first { $0.id == stillSyncingID })
        stillSyncing.destinationSummary = "Aegina, Bodrum"
        stillSyncing.countryCodes = "GR,TR"
        // A Cephalonia stay was added to the trip; it has not arrived yet.
        try #require(heldRows.first { $0.id == grewElsewhereID })
            .destinationSummary = "Aegina, Cephalonia"
        // The Cephalonia stay was moved out of the trip; the move has not arrived.
        try #require(heldRows.first { $0.id == shrankElsewhereID })
            .destinationSummary = "Aegina"
        try context.save()

        let outcome = await TripDataImporter(modelContainer: container)
            .importTrips(from: try Self.restorePayload([
                checkpointed,
                Self.restoreFixtureTrip(stillSyncingID, [syncedAegina, bodrum]),
                grewElsewhere, shrankElsewhere,
            ]))
        #expect(!outcome.saveFailed)
        #expect(outcome.skippedExistingTrips == 4)
        #expect(outcome.insertedHomes == 1)

        let fields = Dictionary(
            try ModelContext(container).fetch(FetchDescriptor<Trip>())
                .map { ($0.id, [$0.destinationSummary, $0.countryCodes]) },
            uniquingKeysWith: { first, _ in first })
        #expect(fields[checkpointedID] == ["Aegina", "GR"],
                "a row holding its own derivation drops the home name")
        #expect(fields[stillSyncingID] == ["Aegina, Bodrum", "GR,TR"])
        #expect(fields[grewElsewhereID] == ["Aegina, Cephalonia", "GR"])
        #expect(fields[shrankElsewhereID] == ["Aegina", "GR"])
    }

    @Test("a v2 export round-trips: names, titles, overrides, and provenance survive")
    func v2ExportRoundTrips() async throws {
        let tripID = UUID()
        let stayID = UUID()
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let end = start.addingTimeInterval(3 * 86400)

        let staySnapshot = ExportStaySnapshot(
            id: stayID,
            startTime: start.addingTimeInterval(3600),
            endTime: end.addingTimeInterval(-3600),
            durationMinutes: 4200,
            categoryRaw: "destination",
            latitude: 37.9838,
            longitude: 23.7275,
            pingCount: 42,
            distanceFromHomeKm: 0,
            locality: "Gérakas",
            country: "Greece",
            isoCountryCode: "GR",
            userOverridden: true,
            isAirport: false,
            sourceRaw: "photoImport",
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? "",
            administrativeArea: "Attica",
            subLocality: nil,
            metroName: "Athens",
            islandName: nil,
            transitFromPreviousRaw: "flight",
            distanceFromPreviousKm: 2100.5,
            stepsWalked: 12345,
            weatherConditionRaw: "clear",
            avgTemperatureC: 31.0,
            precipitationMm: 0
        )
        let tripSnapshot = ExportTripSnapshot(
            id: tripID,
            startDate: start,
            endDate: end,
            isComplete: true,
            destinationSummary: "Athens",
            countryCodes: "GR",
            classifiedByAI: true,
            durationDays: 4,
            stays: [staySnapshot],
            customName: "Family week",
            aiGeneratedTitle: "Athens",
            aiGeneratedSummary: "A three-day stay in Athens.",
            userEdited: true,
            sourceRaw: "photoImport"
        )

        let data = try #require(TripDataExporter.buildExportData(snapshots: [tripSnapshot], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)
        #expect(payload.malformedTrips == 0)
        #expect(payload.malformedStays == 0)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedStays == 1)

        let ctx = ModelContext(container)
        let trip = try #require(try ctx.fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.id == tripID)
        #expect(trip.customName == "Family week")
        #expect(trip.aiGeneratedTitle == "Athens")
        #expect(trip.aiGeneratedSummary == "A three-day stay in Athens.")
        #expect(trip.userEdited)

        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.id == stayID)
        #expect(stay.userOverridden)
        // v2 provenance is preserved on the stay (and derived on the trip)…
        #expect(stay.source == .photoImport)
        #expect(trip.source == .photoImport)
        #expect(stay.metroName == "Athens")
        #expect(stay.transitFromPreviousRaw == "flight")
        #expect(stay.stepsWalked == 12345)
        #expect(stay.weatherConditionRaw == "clear")

        // …but synthetic pings are ALWAYS .jsonImport, never .photoImport
        // (they must not enter the photo-import discard/dedup machinery).
        let pings = try ctx.fetch(FetchDescriptor<LocationPing>())
        #expect(!pings.isEmpty)
        #expect(pings.allSatisfy { $0.source == .jsonImport })
    }

    @Test("importing a trip whose stays land in an existing hex extends bounds without inflating visitCount")
    func hexUpsertIsConservative() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Pre-existing hex row for Kyoto's cell with a LATER firstVisited.
        let kyotoHex = try #require(H3Service.cellIndex(latitude: 35.0034, longitude: 135.7825))
        let existing = HexVisit(
            h3Index: kyotoHex,
            firstVisited: Date(timeIntervalSince1970: 1_885_484_800),
            centerLatitude: 35.0034,
            centerLongitude: 135.7825
        )
        existing.visitCount = 7
        ctx.insert(existing)
        try ctx.save()

        _ = try await importV1(into: container)

        let freshCtx = ModelContext(container)
        let predicate = #Predicate<HexVisit> { $0.h3Index == kyotoHex }
        let rows = try freshCtx.fetch(FetchDescriptor<HexVisit>(predicate: predicate))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        // Bounds extended backward to the imported stay's start…
        #expect(row.firstVisited < Date(timeIntervalSince1970: 1_885_484_800))
        // …but no re-entry inflation (the export carries no visit counts).
        #expect(row.visitCount == 7)
    }

    // MARK: - v3 weather fidelity

    @Test("v3 round-trips the full weather blob and dayKey; v2 files get dayKey recomputed")
    func weatherBlobAndDayKeyRoundTrip() async throws {
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let blob = Data("weather-blob-bytes".utf8)
        let stayID = UUID()
        var staySnapshot = ExportStaySnapshot(
            id: stayID,
            startTime: start,
            endTime: start.addingTimeInterval(7200),
            durationMinutes: 120,
            categoryRaw: "destination",
            latitude: 37.9838,
            longitude: 23.7275,
            pingCount: 3,
            distanceFromHomeKm: 12,
            locality: "Athens",
            country: "Greece",
            isoCountryCode: "GR",
            userOverridden: false,
            isAirport: false,
            sourceRaw: "slc",
            h3IndexRes6: H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275) ?? "",
            administrativeArea: nil,
            subLocality: nil,
            metroName: nil,
            islandName: nil,
            transitFromPreviousRaw: nil,
            distanceFromPreviousKm: nil,
            stepsWalked: nil,
            weatherConditionRaw: "clear",
            avgTemperatureC: 31,
            precipitationMm: 0
        )
        staySnapshot.weatherData = blob
        staySnapshot.dayKey = WeatherEnricher.computeDayKey(for: start)
        let tripSnapshot = ExportTripSnapshot(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(86_400),
            isComplete: true,
            destinationSummary: "Athens",
            countryCodes: "GR",
            classifiedByAI: false,
            durationDays: 1,
            stays: [staySnapshot],
            customName: nil,
            aiGeneratedTitle: nil,
            aiGeneratedSummary: nil,
            userEdited: false,
            sourceRaw: "slc"
        )

        let data = try #require(TripDataExporter.buildExportData(snapshots: [tripSnapshot], appVersion: "test"))
        let payload = try TripDataImporter.parse(data)
        #expect(payload.formatVersion == TripDataExporter.formatVersion)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let ctx = ModelContext(container)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.weatherData == blob)
        #expect(stay.dayKey == WeatherEnricher.computeDayKey(for: start))
    }

    @Test("a pre-v3 file (no dayKey/weatherData keys) restores with a recomputed UTC dayKey")
    func preV3FileGetsDayKeyBackfilled() async throws {
        // Hand-built v2-shaped payload: the tolerant parser treats the
        // missing keys as nil, and import recomputes dayKey from startTime.
        let json = """
        {
          "formatVersion": 2,
          "trips": [{
            "id": "\(UUID().uuidString)",
            "startDate": "2023-05-30T22:13:20Z",
            "endDate": "2023-05-31T22:13:20Z",
            "isComplete": true,
            "stays": [{
              "id": "\(UUID().uuidString)",
              "startTime": "2023-05-30T22:13:20Z",
              "endTime": "2023-05-31T02:13:20Z",
              "latitude": 37.9838,
              "longitude": 23.7275,
              "category": "destination"
            }]
          }]
        }
        """
        let payload = try TripDataImporter.parse(Data(json.utf8))
        #expect(payload.malformedStays == 0)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        _ = await importer.importTrips(from: payload)

        let ctx = ModelContext(container)
        let stay = try #require(try ctx.fetch(FetchDescriptor<Stay>()).first)
        #expect(stay.weatherData == nil)
        let iso = ISO8601DateFormatter()
        let start = try #require(iso.date(from: "2023-05-30T22:13:20Z"))
        #expect(stay.dayKey == WeatherEnricher.computeDayKey(for: start))
    }

    @Test("a zoneless Samoa stay restores on the side of the date line Samoa kept that year")
    func zonelessDateLineStayRestoresWithItsYearsSide() async throws {
        // Samoa kept the American-side date until 2011-12-30.
        for (start, hours) in [("2010-06-15T12:00:00Z", -11), ("2020-06-15T12:00:00Z", 13)] {
            let json = """
            {
              "formatVersion": 2,
              "trips": [{
                "id": "\(UUID().uuidString)",
                "startDate": "\(start)",
                "endDate": "\(start)",
                "isComplete": true,
                "stays": [{
                  "id": "\(UUID().uuidString)",
                  "startTime": "\(start)",
                  "endTime": "\(start)",
                  "latitude": -13.84704,
                  "longitude": -171.82468,
                  "isoCountryCode": "WS",
                  "category": "destination"
                }]
              }]
            }
            """
            let payload = try TripDataImporter.parse(Data(json.utf8))
            #expect(payload.malformedStays == 0)

            let container = try TestSupport.makeInMemoryContainer()
            let importer = TripDataImporter(modelContainer: container)
            _ = await importer.importTrips(from: payload)

            let stay = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
            #expect(stay.timeZoneIdentifier == TimeZone(secondsFromGMT: hours * 3600)!.identifier, "\(start)")
        }
    }

    // MARK: - Non-finite Doubles

    @Test("a NaN/Inf field cannot abort the export; JSONSerialization would raise an uncatchable NSException")
    func nonFiniteDoublesAreSanitizedBeforeSerialization() throws {
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let staySnapshot = ExportStaySnapshot(
            id: UUID(),
            startTime: start,
            endTime: start.addingTimeInterval(7200),
            durationMinutes: 120,
            categoryRaw: "destination",
            latitude: Double.nan,
            longitude: -Double.infinity,
            pingCount: 3,
            // The no-usable-home sentinel is FINITE and must survive
            // export verbatim (import copies it back unchanged).
            distanceFromHomeKm: Double.greatestFiniteMagnitude,
            locality: "Nowhere",
            country: nil,
            isoCountryCode: nil,
            userOverridden: false,
            isAirport: false,
            sourceRaw: "slc",
            h3IndexRes6: "",
            administrativeArea: nil,
            subLocality: nil,
            metroName: nil,
            islandName: nil,
            transitFromPreviousRaw: nil,
            distanceFromPreviousKm: Double.nan,
            stepsWalked: nil,
            weatherConditionRaw: nil,
            avgTemperatureC: Double.infinity,
            precipitationMm: Double.nan
        )
        let tripSnapshot = ExportTripSnapshot(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(86_400),
            isComplete: true,
            destinationSummary: "Nowhere",
            countryCodes: "",
            classifiedByAI: false,
            durationDays: 1,
            stays: [staySnapshot],
            customName: nil,
            aiGeneratedTitle: nil,
            aiGeneratedSummary: nil,
            userEdited: false,
            sourceRaw: "slc"
        )

        // Pre-fix this line crashed the test process (NSInvalidArgumentException
        // inside JSONSerialization, not a catchable Swift error).
        let data = try #require(TripDataExporter.buildExportData(snapshots: [tripSnapshot], appVersion: "test"))

        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedTrips == 0)
        #expect(payload.malformedStays == 0)

        // Required non-finite fields were clamped; optional ones dropped;
        // the finite sentinel survived.
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trips = try #require(json["trips"] as? [[String: Any]])
        let stays = try #require(trips.first?["stays"] as? [[String: Any]])
        let stay = try #require(stays.first)
        #expect(stay["latitude"] as? Double == 0)
        #expect(stay["longitude"] as? Double == 0)
        #expect(stay["distanceFromHomeKm"] as? Double == Double.greatestFiniteMagnitude)
        #expect(stay["distanceFromPreviousKm"] == nil)
        #expect(stay["avgTemperatureC"] == nil)
        #expect(stay["precipitationMm"] == nil)
    }

    @Test("a HexVisit read failure aborts the import without inserting anything")
    func hexVisitReadFailureFailsClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let payload = try TripDataImporter.parse(Data(Self.v1JSON.utf8))
        let importer = TripDataImporter(modelContainer: container)

        await importer.failHexVisitFetchCallForTesting(1)
        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.insertedStays == 0)

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try verification.fetchCount(FetchDescriptor<HexVisit>()) == 0)
    }

    // MARK: - v14 photo choices

    /// One saved trip with one stay, as a backup source or restore target.
    private static func insertChoiceTrip(
        id: UUID = UUID(), stayID: UUID = UUID(), in context: ModelContext
    ) throws -> Trip {
        let start = Date(timeIntervalSince1970: 1_685_484_800)
        let end = start.addingTimeInterval(7_200)
        let trip = Trip(startDate: start, source: .liveSLC)
        trip.id = id
        trip.endDate = end
        trip.isComplete = true
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: 37.9838, centroidLongitude: 23.7275,
            h3IndexRes6: try #require(H3Service.cellIndex(latitude: 37.9838, longitude: 23.7275)),
            pingCount: 0, distanceFromHomeKm: 100, pingIDs: [], source: .liveSLC)
        stay.id = stayID
        stay.category = .destination
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        return trip
    }

    /// A backup of one trip with a hidden photo (both identifiers), a pinned
    /// one (local only) and a hidden photo of a trip the backup lacks.
    private static func photoChoiceBackup() async throws -> (data: Data, tripID: UUID, stayID: UUID, hiddenAt: Date, pinnedAt: Date) {
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        let stayID = UUID()
        let trip = try insertChoiceTrip(stayID: stayID, in: context)
        let hiddenAt = Date(timeIntervalSince1970: 1_690_000_000.375)
        let pinnedAt = Date(timeIntervalSince1970: 1_690_000_100.625)
        let hidden = HiddenPhoto(localIdentifier: "local-hidden/L0/001", tripID: trip.id)
        hidden.cloudIdentifier = "cloud-hidden"
        hidden.hiddenAt = hiddenAt
        let pinned = PinnedPhoto(localIdentifier: "local-pinned/L0/001", tripID: trip.id)
        pinned.pinnedAt = pinnedAt
        let stranded = HiddenPhoto(localIdentifier: "local-stranded/L0/001", tripID: UUID())
        context.insert(hidden)
        context.insert(pinned)
        context.insert(stranded)
        try context.save()

        let trips = try await ExportSnapshotter(modelContainer: source).snapshotTrips()
        let layer = try await ExportSnapshotter(modelContainer: source).snapshotHomeAreaLayer()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: trips, hiddenPhotos: layer.hiddenPhotos,
            pinnedPhotos: layer.pinnedPhotos, appVersion: "test"))
        return (data, trip.id, stayID, hiddenAt, pinnedAt)
    }

    @Test("v14 photo choices round-trip onto restored trips, drop a missing trip's, and reimport adds nothing")
    func photoChoicesRoundTrip() async throws {
        let backup = try await Self.photoChoiceBackup()
        let payload = try TripDataImporter.parse(backup.data)
        #expect(payload.hiddenPhotos.count == 2)
        #expect(payload.pinnedPhotos.count == 1)

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newChoices == 2)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedPhotoChoices == 2)
        #expect(outcome.skippedPhotoChoices == 1)

        let context = ModelContext(container)
        let hidden = try context.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.count == 1)
        let restoredHidden = try #require(hidden.first)
        #expect(restoredHidden.tripID == backup.tripID)
        #expect(restoredHidden.localIdentifier == "local-hidden/L0/001")
        #expect(restoredHidden.cloudIdentifier == "cloud-hidden")
        #expect(restoredHidden.hiddenAt == backup.hiddenAt)
        let pinned = try context.fetch(FetchDescriptor<PinnedPhoto>())
        #expect(pinned.count == 1)
        let restoredPinned = try #require(pinned.first)
        #expect(restoredPinned.tripID == backup.tripID)
        #expect(restoredPinned.cloudIdentifier == nil)
        #expect(restoredPinned.pinnedAt == backup.pinnedAt)

        let again = try await importer.preview(of: payload)
        #expect(again.newChoices == 0)
        #expect(!again.hasImportableContent)
        let second = await importer.importTrips(from: payload)
        #expect(second.insertedPhotoChoices == 0)
        #expect(second.skippedPhotoChoices == 1)
        #expect(try context.fetchCount(FetchDescriptor<HiddenPhoto>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
    }

    @Test("a pre-v14 file carries no photo choices, even when the keys are present")
    func preV14FileIgnoresPhotoChoices() async throws {
        let backup = try await Self.photoChoiceBackup()
        var root = try #require(try JSONSerialization.jsonObject(with: backup.data) as? [String: Any])
        root["formatVersion"] = 13
        let payload = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(payload.hiddenPhotos.isEmpty)
        #expect(payload.pinnedPhotos.isEmpty)
        #expect(payload.malformedTrips == 0)

        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container).importTrips(from: payload)
        #expect(outcome.insertedTrips == 1)
        #expect(outcome.insertedPhotoChoices == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
    }

    @Test("choices onto an existing trip are admitted alone, keep stored choices as they are, and skip what the trip already holds")
    func photoChoicesMergeIntoExistingTrip() async throws {
        let backup = try await Self.photoChoiceBackup()
        let payload = try TripDataImporter.parse(backup.data)

        // The trip is already here, with the same photo hidden from another
        // device (same cloud id, its own local id and time) and nothing pinned.
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try Self.insertChoiceTrip(id: backup.tripID, stayID: backup.stayID, in: context)
        let storedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = HiddenPhoto(localIdentifier: "other-device/L0/001", tripID: backup.tripID)
        stored.cloudIdentifier = "cloud-hidden"
        stored.hiddenAt = storedAt
        context.insert(stored)
        try context.save()

        let importer = TripDataImporter(modelContainer: container)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.newChoices == 1)
        #expect(preview.hasImportableContent)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 0)
        #expect(outcome.insertedPhotoChoices == 1)

        let verification = ModelContext(container)
        let hidden = try verification.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.count == 1)
        #expect(hidden.first?.localIdentifier == "other-device/L0/001")
        #expect(hidden.first?.hiddenAt == storedAt)
        #expect(try verification.fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
    }

    @Test("the restore identity: a local-only choice the trip holds by local id, and a duplicate within the file, land once")
    func photoChoiceIdentityMatchesTheDedup() {
        let tripID = UUID()
        let other = UUID()
        let at = Date(timeIntervalSince1970: 1_690_000_000)
        let choices = [
            ImportedPhotoChoice(tripID: tripID, localIdentifier: "L1", cloudIdentifier: nil, chosenAt: at),
            ImportedPhotoChoice(tripID: tripID, localIdentifier: "L2", cloudIdentifier: "C2", chosenAt: at),
            ImportedPhotoChoice(tripID: tripID, localIdentifier: "L3", cloudIdentifier: "C2", chosenAt: at.addingTimeInterval(1)),
            ImportedPhotoChoice(tripID: other, localIdentifier: "L1", cloudIdentifier: nil, chosenAt: at),
        ]
        let result = TripDataImporter.photoChoicesToRestore(
            choices,
            held: [(tripID: tripID, localIdentifier: "L1", cloudIdentifier: "C1")],
            tripIDs: [tripID, other])
        #expect(result.missingTrip == 0)
        #expect(result.restore.map(\.localIdentifier).sorted() == ["L1", "L2"])
        #expect(result.restore.first { $0.localIdentifier == "L1" }?.tripID == other)
    }

    // MARK: - v14 Favorites and Earlier Travels

    @Test("v14 Favorites and Earlier Travels round-trip as a union: valid entries only, existing trips only, nothing removed, reimport adds nothing, older files leave them alone")
    func selectionsMergeAsUnion() async throws {
        let suite = "TripDataImporterTests-selections-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favourites = PinnedTripsStorage(forTesting: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)
        let keptFavourite = UUID()
        favourites.pin(keptFavourite)
        _ = countries.merge(["GR"])

        let source = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(source)
        let restoredTrip = try Self.insertChoiceTrip(in: sourceContext)
        try sourceContext.save()
        let missingTrip = UUID()
        let trips = try await ExportSnapshotter(modelContainer: source).snapshotTrips()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: trips,
            favouriteTripIDs: [restoredTrip.id, missingTrip],
            rememberedCountryCodes: ["FR", "JP", "GR"],
            appVersion: "test"))
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["favouriteTripIDs"] as? [String]
                == [restoredTrip.id, missingTrip].map(\.uuidString).sorted())
        #expect(root["rememberedCountryCodes"] as? [String] == ["FR", "GR", "JP"])
        // Hand-edited garbage is dropped entry by entry.
        root["rememberedCountryCodes"] = ["FR", "JP", "GR", "EU", "xx", 7]
        root["favouriteTripIDs"] = [restoredTrip.id.uuidString, missingTrip.uuidString, "nope"]
        let payload = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(payload.rememberedCountryCodes == ["FR", "JP", "GR"])
        #expect(payload.favouriteTripIDs == [restoredTrip.id, missingTrip])

        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        let preview = try await importer.preview(
            of: payload, favouriteTripIDs: favourites.pinnedIDs,
            rememberedCountryCodes: countries.codes)
        #expect(preview.newChoices == 3)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.restorableFavouriteTripIDs == [restoredTrip.id])
        #expect(TripDataImporter.mergeSelections(
            of: outcome, from: payload, favourites: favourites, countries: countries) == 3)
        #expect(favourites.pinnedIDs == [keptFavourite, restoredTrip.id])
        #expect(countries.codes == ["GR", "FR", "JP"])

        // Persisted, not just in memory.
        #expect(PinnedTripsStorage(forTesting: defaults).pinnedIDs == [keptFavourite, restoredTrip.id])
        #expect(RememberedCountriesStorage(forTesting: defaults).codes == ["GR", "FR", "JP"])

        // Only news is admitted: the same file again has nothing left to add.
        let again = try await importer.preview(
            of: payload, favouriteTripIDs: favourites.pinnedIDs,
            rememberedCountryCodes: countries.codes)
        #expect(again.newChoices == 0)
        #expect(!again.hasImportableContent)
        let second = await importer.importTrips(from: payload)
        #expect(TripDataImporter.mergeSelections(
            of: second, from: payload, favourites: favourites, countries: countries) == 0)
        #expect(favourites.pinnedIDs == [keptFavourite, restoredTrip.id])
        #expect(countries.codes == ["GR", "FR", "JP"])

        // A choice-only file is admitted against a store that has its trip.
        favourites.unpin(restoredTrip.id)
        let choiceOnly = try await importer.preview(
            of: payload, favouriteTripIDs: favourites.pinnedIDs,
            rememberedCountryCodes: countries.codes)
        #expect(choiceOnly.newTrips == 0)
        #expect(choiceOnly.newChoices == 1)
        #expect(choiceOnly.hasImportableContent)

        // An older file carries neither key, so the sets stay as they are.
        root["formatVersion"] = 13
        let older = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        #expect(older.favouriteTripIDs.isEmpty)
        #expect(older.rememberedCountryCodes.isEmpty)
        let olderOutcome = await importer.importTrips(from: older)
        #expect(TripDataImporter.mergeSelections(
            of: olderOutcome, from: older, favourites: favourites, countries: countries) == 0)
        #expect(favourites.pinnedIDs == [keptFavourite])
        #expect(countries.codes == ["GR", "FR", "JP"])
    }

    @Test("a failed import merges no Favorites or Earlier Travels")
    func failedImportMergesNoSelections() async throws {
        let suite = "TripDataImporterTests-selections-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favourites = PinnedTripsStorage(forTesting: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)

        var root = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.v1JSON.utf8)) as? [String: Any])
        root["formatVersion"] = TripDataExporter.formatVersion
        root["favouriteTripIDs"] = ["11111111-1111-1111-1111-111111111111"]
        root["rememberedCountryCodes"] = ["FR"]
        let payload = try TripDataImporter.parse(JSONSerialization.data(withJSONObject: root))
        let importer = TripDataImporter(modelContainer: try TestSupport.makeInMemoryContainer())
        await importer.failSaveCallForTesting(1)

        let outcome = await importer.importTrips(from: payload)
        #expect(outcome.saveFailed)
        #expect(outcome.restorableFavouriteTripIDs.isEmpty)
        #expect(TripDataImporter.mergeSelections(
            of: outcome, from: payload, favourites: favourites, countries: countries) == 0)
        #expect(favourites.pinnedIDs.isEmpty)
        #expect(countries.codes.isEmpty)
    }

    @Test("a restore merges Favorites and Earlier Travels into the stored sets as they are now, keeping a change its notification has not delivered yet")
    func selectionMergeReloadsTheStoredSets() throws {
        let suite = "TripDataImporterTests-selections-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favourites = PinnedTripsStorage(forTesting: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)
        let kept = UUID()
        favourites.pin(kept)
        _ = countries.merge(["GR"])

        // Another device's change lands in the stored sets after these were
        // created, and before anything refreshes them.
        let delivered = UUID()
        PinnedTripsStorage(forTesting: defaults).pin(delivered)
        _ = RememberedCountriesStorage(forTesting: defaults).merge(["IT"])
        #expect(favourites.pinnedIDs == [kept])
        #expect(countries.codes == ["GR"])

        let restored = UUID()
        #expect(favourites.merge([restored, kept]) == 1)
        #expect(countries.merge(["FR", "GR"]) == 1)
        #expect(favourites.pinnedIDs == [kept, delivered, restored])
        #expect(countries.codes == ["GR", "IT", "FR"])
        #expect(PinnedTripsStorage(forTesting: defaults).pinnedIDs == [kept, delivered, restored])
        #expect(RememberedCountriesStorage(forTesting: defaults).codes == ["GR", "IT", "FR"])
    }
}
