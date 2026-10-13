//
//  TripDataImportRecoveryTests.swift
//  TravelLogTests
//
//  Backup restore recovery and fidelity: an interrupted import whose only
//  missing work is deferred titles or Visits stays admissible and completes
//  on retry (preview and commit share one rule); malformed localized titles
//  never win import or export; Visit dates round-trip bit-exactly so the
//  recorder still coalesces the original callback after a restore.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("TripDataImporter recovery and fidelity")
struct TripDataImportRecoveryTests {

    private static let start = Date(timeIntervalSince1970: 1_719_958_400)

    private struct Callback: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }
    private static let athens = (lat: 37.9838, lon: 23.7275)

    // MARK: - Fixtures

    private func stayJSON(id: UUID, at stayStart: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "id": id.uuidString,
            "startTime": iso.string(from: stayStart),
            "endTime": iso.string(from: stayStart.addingTimeInterval(3_600)),
            "category": "destination",
            "latitude": Self.athens.lat,
            "longitude": Self.athens.lon,
        ]
    }

    private func tripJSON(
        id: UUID = UUID(),
        stayIDs: [UUID] = [UUID()],
        at tripStart: Date,
        title: String?,
        revision: UUID?,
        localizedTitle: String? = nil
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var trip: [String: Any] = [
            "id": id.uuidString,
            "startDate": iso.string(from: tripStart),
            "endDate": iso.string(from: tripStart.addingTimeInterval(3_600)),
            "isComplete": true,
            "classifiedByAI": true,
            "stays": stayIDs.map { stayJSON(id: $0, at: tripStart) },
        ]
        if let title {
            trip["aiGeneratedTitle"] = title
            if let revision { trip["titleSourceRevision"] = revision.uuidString }
            if let localizedTitle {
                var row: [String: Any] = [
                    "id": UUID().uuidString,
                    "languageTag": "de",
                    "title": localizedTitle,
                    "sourceTitle": title,
                    "generationVersion": TripTitleStore.currentGenerationVersion,
                    "updatedAt": iso.string(from: Self.start),
                ]
                if let revision { row["sourceRevision"] = revision.uuidString }
                trip["localizedTitles"] = [row]
            }
        }
        return trip
    }

    private func makePayload(
        trips: [[String: Any]],
        formatVersion: Int = 8,
        extra: [String: Any] = [:]
    ) throws -> ImportPayload {
        var root: [String: Any] = [
            "formatVersion": formatVersion,
            "appVersion": "test",
            "trips": trips,
        ]
        root.merge(extra) { _, new in new }
        return try TripDataImporter.parse(
            JSONSerialization.data(withJSONObject: root))
    }

    private func titledTrips(count: Int, revision: UUID) -> [[String: Any]] {
        (0..<count).map { index in
            tripJSON(
                at: Self.start.addingTimeInterval(Double(index) * 86_400),
                title: "Imported Title \(index)", revision: revision,
                localizedTitle: "Importierter Titel \(index)")
        }
    }

    @discardableResult
    private func seedTrip(
        in context: ModelContext,
        id: UUID,
        stayID: UUID,
        customName: String? = nil,
        aiGeneratedTitle: String? = nil
    ) -> Trip {
        let trip = Trip(startDate: Self.start)
        trip.id = id
        trip.isComplete = true
        trip.endDate = Self.start.addingTimeInterval(3_600)
        trip.customName = customName
        trip.aiGeneratedTitle = aiGeneratedTitle
        let stay = Stay(
            startTime: Self.start,
            endTime: Self.start.addingTimeInterval(3_600),
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: "existing-\(stayID.uuidString)",
            pingCount: 2, distanceFromHomeKm: 100, pingIDs: [])
        stay.id = stayID
        stay.category = .destination
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        return trip
    }

    // MARK: - Payload identity claims

    nonisolated enum IdentityCollision: CaseIterable, Sendable {
        case tripTwins, stayTwins, tripAndTripless, phantomFirstTripTwin
    }

    @Test("preview follows commit's first-entry identity claims without writing",
          arguments: IdentityCollision.allCases)
    func previewClaimsPayloadIdentities(collision: IdentityCollision) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID()
        let firstStayID = UUID()
        let secondStayID = UUID()
        let first = tripJSON(
            id: tripID, stayIDs: [firstStayID], at: Self.start,
            title: nil, revision: nil)
        let second = tripJSON(
            id: tripID, stayIDs: [secondStayID],
            at: Self.start.addingTimeInterval(86_400),
            title: nil, revision: nil)
        let payload: ImportPayload
        switch collision {
        case .tripTwins:
            payload = try makePayload(trips: [first, second])
        case .stayTwins:
            payload = try makePayload(trips: [tripJSON(
                id: tripID, stayIDs: [firstStayID, firstStayID],
                at: Self.start, title: nil, revision: nil)])
        case .tripAndTripless:
            let duplicateStay = stayJSON(id: firstStayID, at: Self.start)
            payload = try makePayload(trips: [first], extra: [
                "unassignedStays": [duplicateStay],
                "homeStays": [duplicateStay],
            ])
        case .phantomFirstTripTwin:
            // The first payload trip claims its id even when its only stay
            // already belongs to another trip. Its twin cannot revive it.
            seedTrip(in: context, id: UUID(), stayID: firstStayID)
            try context.save()
            payload = try makePayload(trips: [first, second])
        }
        let phantom = collision == .phantomFirstTripTwin
        let expectedNew = phantom ? 0 : 1
        let initialCount = phantom ? 1 : 0
        let importer = TripDataImporter(modelContainer: container)
        let preview = try await importer.preview(of: payload)

        #expect(preview.newTrips == expectedNew)
        #expect(preview.newStays == expectedNew)
        #expect(preview.existingTrips == (
            collision == .tripTwins || phantom ? 1 : 0))
        #expect(preview.hasImportableContent == !phantom)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == initialCount)
        #expect(try context.fetchCount(FetchDescriptor<Stay>()) == initialCount)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == preview.newTrips)
        #expect(outcome.insertedStays == preview.newStays)
        #expect(outcome.skippedExistingTrips == preview.existingTrips)
        let verification = ModelContext(container)
        let trips = try verification.fetch(FetchDescriptor<Trip>())
        let stays = try verification.fetch(FetchDescriptor<Stay>())
        #expect(trips.count == 1)
        #expect(stays.map(\.id) == [firstStayID])
        #expect(!stays.contains { $0.id == secondStayID })
        if !phantom {
            #expect(trips.first?.id == tripID)
            #expect(stays.first?.trip?.id == tripID)
        }
    }

    // MARK: - title-only and Visit-only recovery

    /// Every trip commits at a checkpoint when the inserted count is a
    /// multiple of 25; the final transaction then holds only the titles. The
    /// retry has no new rows, so admission must count the titles it restores.
    @Test("a title-only retry after a failed final transaction is admitted and completes",
          arguments: [25, 50])
    func titleOnlyRecoveryIsAdmittedAndCompletes(tripCount: Int) async throws {
        let revision = UUID()
        let payload = try makePayload(trips: titledTrips(count: tripCount, revision: revision))
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        // One checkpoint save per 25 trips; the next save is the final one.
        await importer.failSaveCallForTesting(tripCount / 25 + 1)

        let first = await importer.importTrips(from: payload)
        #expect(first.saveFailed)
        #expect(first.insertedTrips == tripCount)
        #expect(first.restoredTitles == 0)
        let durable = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(durable.count == tripCount)
        #expect(durable.allSatisfy { $0.aiGeneratedTitle == nil })

        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.newHomeAreaRows == 0)
        #expect(preview.newVisits == 0)
        #expect(preview.restorableTitles == tripCount)
        #expect(preview.hasImportableContent)

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedTrips == 0)
        #expect(retry.skippedExistingTrips == tripCount)
        #expect(retry.restoredTitles == tripCount)
        let verification = ModelContext(container)
        let completed = try verification.fetch(FetchDescriptor<Trip>())
        #expect(completed.count == tripCount)
        #expect(completed.allSatisfy { $0.aiGeneratedTitle != nil })
        #expect(completed.allSatisfy { $0.titleSourceRevision == revision })
        #expect(try verification.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == tripCount)

        let settled = try await importer.preview(of: payload)
        #expect(settled.restorableTitles == 0)
        #expect(!settled.hasImportableContent)
    }

    @Test("preview and commit share the conservative title-completion rule, first payload entry wins")
    func previewAndCommitAgreeOnTitleCompletion() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let revision = UUID()
        let eligibleID = UUID(), eligibleStayID = UUID()
        seedTrip(in: context, id: eligibleID, stayID: eligibleStayID)
        let changedID = UUID()
        seedTrip(in: context, id: changedID, stayID: UUID())
        let userTitledID = UUID(), userTitledStayID = UUID()
        seedTrip(in: context, id: userTitledID, stayID: userTitledStayID,
                 customName: "My own title")
        let aiTitledID = UUID(), aiTitledStayID = UUID()
        seedTrip(in: context, id: aiTitledID, stayID: aiTitledStayID,
                 aiGeneratedTitle: "Keep local AI title")
        try context.save()

        let payload = try makePayload(trips: [
            tripJSON(id: eligibleID, stayIDs: [eligibleStayID], at: Self.start,
                     title: "First entry", revision: revision,
                     localizedTitle: "Erster Eintrag"),
            // A duplicate payload entry must not complete the trip twice.
            tripJSON(id: eligibleID, stayIDs: [eligibleStayID], at: Self.start,
                     title: "Second entry", revision: revision,
                     localizedTitle: "Zweiter Eintrag"),
            tripJSON(id: changedID, stayIDs: [UUID()], at: Self.start,
                     title: "Do not resurrect", revision: revision),
            tripJSON(id: userTitledID, stayIDs: [userTitledStayID], at: Self.start,
                     title: "Do not cover user title", revision: revision),
            tripJSON(id: aiTitledID, stayIDs: [aiTitledStayID], at: Self.start,
                     title: "Do not replace AI title", revision: revision),
        ])
        let importer = TripDataImporter(modelContainer: container)

        let preview = try await importer.preview(of: payload)
        #expect(preview.existingTrips == 5)
        #expect(preview.restorableTitles == 1)
        #expect(preview.hasImportableContent)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.restoredTitles == 1)
        let verification = ModelContext(container)
        let trips = try verification.fetch(FetchDescriptor<Trip>())
        #expect(trips.first { $0.id == eligibleID }?.aiGeneratedTitle == "First entry")
        #expect(trips.first { $0.id == changedID }?.aiGeneratedTitle == nil)
        #expect(trips.first { $0.id == userTitledID }?.aiGeneratedTitle == nil)
        #expect(trips.first { $0.id == aiTitledID }?.aiGeneratedTitle
                == "Keep local AI title")
        let variants = try verification.fetch(FetchDescriptor<TripTitleVariant>())
        #expect(variants.map(\.title) == ["Erster Eintrag"])
    }

    @Test("a title-only retry is refused when the file's Home context no longer matches")
    func homeMismatchRefusesTitleOnlyRecovery() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID(), stayID = UUID()
        seedTrip(in: context, id: tripID, stayID: stayID)
        let home = Home(
            label: "Home", latitude: 51.5405, longitude: -0.1587,
            startedAt: Self.start.addingTimeInterval(-86_400))
        home.locality = "London"
        context.insert(home)
        try context.save()
        let importer = TripDataImporter(modelContainer: container)
        let trips = [tripJSON(
            id: tripID, stayIDs: [stayID], at: Self.start,
            title: "Title generated without a Home", revision: UUID())]

        // v6+ files carry their Home prompt context: this one had none.
        let current = try makePayload(trips: trips, formatVersion: 8)
        let preview = try await importer.preview(of: current)
        #expect(preview.restorableTitles == 0)
        #expect(!preview.hasImportableContent)
        let outcome = await importer.importTrips(from: current)
        #expect(!outcome.saveFailed)
        #expect(outcome.restoredTitles == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .first?.aiGeneratedTitle == nil)

        // Pre-v6 files never carried Homes and keep unconditional restore.
        let legacy = try makePayload(trips: trips, formatVersion: 5)
        #expect(try await importer.preview(of: legacy).restorableTitles == 1)
        #expect(await importer.importTrips(from: legacy).restoredTitles == 1)
    }

    /// The store holds the file's Home plus a nearby twin with no locality
    /// that sorts first. Only the commit's `deduplicateHomes` fills the
    /// survivor's locality from the donor, so the preview must not refuse
    /// against the transient doubled set the commit collapses.
    @Test("a pending Home collapse keeps a title-only retry admissible and the commit restores")
    func pendingHomeCollapseKeepsTitleOnlyRetryAdmissible() async throws {
        let suite = "TripDataImportRecoveryTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID(), stayID = UUID()
        seedTrip(in: context, id: tripID, stayID: stayID)
        let homeStart = Self.start.addingTimeInterval(-86_400)
        let survivorID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let donorID = try #require(
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let survivor = Home(
            label: "Home", latitude: 51.5405, longitude: -0.1587,
            startedAt: homeStart)
        survivor.id = survivorID
        survivor.country = "United Kingdom"
        survivor.isoCountryCode = "GB"
        context.insert(survivor)
        let donor = Home(
            label: "Home", latitude: 51.5411, longitude: -0.1587,
            startedAt: homeStart)
        donor.id = donorID
        donor.locality = "London"
        donor.country = "United Kingdom"
        donor.isoCountryCode = "GB"
        context.insert(donor)
        try context.save()
        let importer = TripDataImporter(modelContainer: container)
        await importer.setHomeAliasDefaultsSuiteForTesting(suite)

        let donorJSON: [String: Any] = [
            "id": donorID.uuidString,
            "label": "Home",
            "latitude": 51.5411,
            "longitude": -0.1587,
            "locality": "London",
            "country": "United Kingdom",
            "isoCountryCode": "GB",
            "startedAt": ISO8601DateFormatter().string(from: homeStart),
        ]
        let payload = try makePayload(
            trips: [tripJSON(
                id: tripID, stayIDs: [stayID], at: Self.start,
                title: "Title generated with the London Home", revision: UUID())],
            extra: ["homes": [donorJSON]])

        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.newHomeAreaRows == 0)
        #expect(preview.newVisits == 0)
        #expect(preview.restorableTitles == 1)
        #expect(preview.hasImportableContent)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.restoredTitles == 1)
        let verification = ModelContext(container)
        let homes = try verification.fetch(FetchDescriptor<Home>())
        #expect(homes.map(\.id) == [survivorID])
        #expect(homes.first?.locality == "London")
        #expect(try verification.fetch(FetchDescriptor<Trip>()).first?
            .aiGeneratedTitle == "Title generated with the London Home")
    }

    @Test("physical Trip twins complete only the single row holding the file's stays")
    func titleCompletionTargetsTheOneExactHolder() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID(), stayID = UUID()
        let holder = seedTrip(in: context, id: tripID, stayID: stayID)
        let ghost = Trip(startDate: Self.start)
        ghost.id = tripID
        context.insert(ghost)
        try context.save()
        let holderIdentifier = holder.persistentModelID
        let importer = TripDataImporter(modelContainer: container)
        let payload = try makePayload(trips: [tripJSON(
            id: tripID, stayIDs: [stayID], at: Self.start,
            title: "Holder title", revision: UUID())])

        #expect(try await importer.preview(of: payload).restorableTitles == 1)
        #expect(await importer.importTrips(from: payload).restoredTitles == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(rows.count == 2)
        #expect(rows.first { $0.persistentModelID == holderIdentifier }?
            .aiGeneratedTitle == "Holder title")
        #expect(rows.first { $0.persistentModelID != holderIdentifier }?
            .aiGeneratedTitle == nil)
    }

    @Test("ambiguous twins that both hold the file's stays receive nothing")
    func ambiguousTwinsReceiveNoTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID(), stayID = UUID()
        // A Stay UUID twin lets both Trip UUID twins match exactly.
        seedTrip(in: context, id: tripID, stayID: stayID)
        seedTrip(in: context, id: tripID, stayID: stayID)
        try context.save()
        let importer = TripDataImporter(modelContainer: container)
        let payload = try makePayload(trips: [tripJSON(
            id: tripID, stayIDs: [stayID], at: Self.start,
            title: "Ambiguous title", revision: UUID())])

        #expect(try await importer.preview(of: payload).restorableTitles == 0)
        #expect(await importer.importTrips(from: payload).restoredTitles == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .allSatisfy { $0.aiGeneratedTitle == nil })
    }

    @Test("a custom name added between preview and commit wins over the promised title")
    func mutationBetweenPreviewAndCommitIsRespected() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID(), stayID = UUID()
        let trip = seedTrip(in: context, id: tripID, stayID: stayID)
        try context.save()
        let importer = TripDataImporter(modelContainer: container)
        let payload = try makePayload(trips: [tripJSON(
            id: tripID, stayIDs: [stayID], at: Self.start,
            title: "Promised title", revision: UUID())])
        #expect(try await importer.preview(of: payload).restorableTitles == 1)

        trip.customName = "Named meanwhile"
        try context.save()

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.restoredTitles == 0)
        let reloaded = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedTitle == nil)
        #expect(reloaded.customName == "Named meanwhile")
    }

    @Test("Visits stranded by a failed final transaction keep the retry admissible")
    func visitOnlyRecoveryIsAdmittedAndCompletes() async throws {
        let iso = ISO8601DateFormatter()
        let visitID = UUID()
        let trips = (0..<25).map { index in
            tripJSON(
                at: Self.start.addingTimeInterval(Double(index) * 86_400),
                title: nil, revision: nil)
        }
        let payload = try makePayload(trips: trips, formatVersion: 9, extra: [
            "visits": [[
                "id": visitID.uuidString,
                "arrival": iso.string(from: Self.start),
                "departure": iso.string(from: Self.start.addingTimeInterval(3_600)),
                "lat": Self.athens.lat,
                "lon": Self.athens.lon,
                "accuracy": 24.0,
                "receivedAt": iso.string(from: Self.start.addingTimeInterval(3_601)),
            ]],
        ])
        let container = try TestSupport.makeInMemoryContainer()
        let importer = TripDataImporter(modelContainer: container)
        await importer.failSaveCallForTesting(2)

        let first = await importer.importTrips(from: payload)
        #expect(first.saveFailed)
        #expect(first.insertedTrips == 25)
        #expect(first.insertedVisits == 0)

        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == 0)
        #expect(preview.newStays == 0)
        #expect(preview.restorableTitles == 0)
        #expect(preview.newVisits == 1)
        #expect(preview.hasImportableContent)

        let retry = await importer.importTrips(from: payload)
        #expect(!retry.saveFailed)
        #expect(retry.insertedVisits == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .map(\.id) == [visitID])
        let settled = try await importer.preview(of: payload)
        #expect(!settled.hasImportableContent)
    }

    // MARK: - malformed localized titles

    @Test("import restores the valid translation over a newer incomplete-list twin")
    func importIgnoresMalformedLocalizedTitle() async throws {
        let iso = ISO8601DateFormatter()
        let revision = UUID()
        let validID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let malformedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        var trip = tripJSON(at: Self.start, title: "Athens and Crete", revision: revision)
        func row(id: UUID, title: String, generation: Int, updatedAt: Date) -> [String: Any] {
            [
                "id": id.uuidString,
                "languageTag": "el",
                "title": title,
                "sourceTitle": "Athens and Crete",
                "sourceRevision": revision.uuidString,
                "generationVersion": generation,
                "updatedAt": iso.string(from: updatedAt),
            ]
        }
        trip["localizedTitles"] = [
            row(id: malformedID, title: "Αθήνα και", generation: 2,
                updatedAt: Self.start.addingTimeInterval(100)),
            row(id: validID, title: "Αθήνα και Κρήτη", generation: 1,
                updatedAt: Self.start),
        ]
        let payload = try makePayload(trips: [trip])
        let container = try TestSupport.makeInMemoryContainer()

        let outcome = await TripDataImporter(modelContainer: container)
            .importTrips(from: payload)

        #expect(!outcome.saveFailed)
        let variants = try ModelContext(container).fetch(
            FetchDescriptor<TripTitleVariant>())
        #expect(variants.map(\.id) == [validID])
        #expect(variants.first?.title == "Αθήνα και Κρήτη")
        let restored = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>()).first)
        #expect(restored.displayName(languageTag: "el") == "Αθήνα και Κρήτη")
    }

    @Test("export carries only usable translations")
    func exportDropsMalformedLocalizedTitle() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let validID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let malformedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let trip = Trip(startDate: Self.start)
        trip.aiGeneratedTitle = "Athens and Crete"
        context.insert(trip)
        context.insert(TripTitleVariant(
            id: validID,
            languageTag: "el", title: "Αθήνα και Κρήτη",
            sourceTitle: "Athens and Crete", generationVersion: 1,
            updatedAt: Self.start, trip: trip))
        context.insert(TripTitleVariant(
            id: malformedID,
            languageTag: "el", title: "Αθήνα και",
            sourceTitle: "Athens and Crete", generationVersion: 2,
            updatedAt: Self.start.addingTimeInterval(100), trip: trip))
        // A language whose only row is malformed exports nothing at all.
        context.insert(TripTitleVariant(
            languageTag: "fr", title: "Athènes et",
            sourceTitle: "Athens and Crete", generationVersion: 1,
            updatedAt: Self.start, trip: trip))
        try context.save()

        let snapshots = TripDataExporter.makeSnapshots(from: [trip])
        #expect(snapshots.first?.localizedTitles.map(\.title) == ["Αθήνα και Κρήτη"])
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: snapshots, appVersion: "test"))
        let parsed = try TripDataImporter.parse(data)
        #expect(parsed.trips.first?.localizedTitles.map(\.title) == ["Αθήνα και Κρήτη"])
    }

    // MARK: - exact Visit dates

    @Test("Visit dates round-trip bit-exactly, including a sub-second closed visit")
    func visitDatesRoundTripExactly() throws {
        let arrival = Date(timeIntervalSinceReferenceDate: 799_958_400.123456789)
        let closed = ExportVisitSnapshot(
            id: UUID(), stayID: nil,
            arrivalDate: arrival,
            // Both ISO strings read ...:00Z; only the bits keep it valid.
            departureDate: arrival.addingTimeInterval(0.25),
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 20, receivedAt: arrival.addingTimeInterval(1))
        let open = ExportVisitSnapshot(
            id: UUID(), stayID: nil,
            arrivalDate: Date(timeIntervalSinceReferenceDate: 800_058_400.987654321),
            departureDate: nil,
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 20,
            receivedAt: Date(timeIntervalSinceReferenceDate: 800_058_401))

        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], visits: [closed, open], appVersion: "test"))
        let root = try #require(try JSONSerialization.jsonObject(
            with: data) as? [String: Any])
        #expect(root["formatVersion"] as? Int == TripDataExporter.formatVersion)
        let rows = try #require(root["visits"] as? [[String: Any]])
        let openRow = try #require(rows.first { $0["id"] as? String == open.id.uuidString })
        #expect(openRow["arrivalBits"] is String)
        #expect(openRow["departureBits"] == nil)

        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedVisits == 0)
        let restoredClosed = try #require(payload.visits.first { $0.id == closed.id })
        #expect(restoredClosed.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
                == closed.arrivalDate.timeIntervalSinceReferenceDate.bitPattern)
        #expect(restoredClosed.departureDate?.timeIntervalSinceReferenceDate.bitPattern
                == closed.departureDate?.timeIntervalSinceReferenceDate.bitPattern)
        let restoredOpen = try #require(payload.visits.first { $0.id == open.id })
        #expect(restoredOpen.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
                == open.arrivalDate.timeIntervalSinceReferenceDate.bitPattern)
        #expect(restoredOpen.departureDate == nil)
    }

    @Test("unusable exact bits fall back to the ISO date, arrival and departure independently")
    func unusableVisitBitsFallBackToISO() throws {
        let iso = ISO8601DateFormatter()
        let arrival = Date(timeIntervalSinceReferenceDate: 799_958_400)
        let departure = arrival.addingTimeInterval(3_600)
        let exactArrival = arrival.addingTimeInterval(0.5)
        func visit(arrivalBits: String?, departureBits: String?) -> [String: Any] {
            var row: [String: Any] = [
                "id": UUID().uuidString,
                "arrival": iso.string(from: arrival),
                "departure": iso.string(from: departure),
                "lat": Self.athens.lat,
                "lon": Self.athens.lon,
                "accuracy": 20.0,
                "receivedAt": iso.string(from: departure),
            ]
            if let arrivalBits { row["arrivalBits"] = arrivalBits }
            if let departureBits { row["departureBits"] = departureBits }
            return row
        }
        let farBits = TripDataExporter.exactDateBits(arrival.addingTimeInterval(5))
        let rows = [
            visit(arrivalBits: TripDataExporter.exactDateBits(exactArrival),
                  departureBits: "zzzzzzzzzzzzzzzz"),
            visit(arrivalBits: farBits, departureBits: nil),
            visit(arrivalBits: "7ff8000000000000", departureBits: "7ff0000000000000"),
            visit(arrivalBits: "12", departureBits: nil),
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": TripDataExporter.formatVersion,
            "trips": [],
            "visits": rows,
        ])

        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedVisits == 0)
        #expect(payload.visits.count == 4)
        let ids = rows.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
        #expect(ids.count == 4)
        let byID = Dictionary(uniqueKeysWithValues: payload.visits.map { ($0.id, $0) })
        func parsed(_ index: Int) throws -> ImportedVisit {
            try #require(byID[ids[index]])
        }
        #expect(try parsed(0).arrivalDate == exactArrival)
        #expect(try parsed(0).departureDate == departure)
        #expect(try parsed(1).arrivalDate == arrival, "bits more than a second away are stale")
        #expect(try parsed(2).arrivalDate == arrival, "NaN bits are unusable")
        #expect(try parsed(2).departureDate == departure, "infinite bits are unusable")
        #expect(try parsed(3).arrivalDate == arrival, "short hex is malformed")
    }

    /// Visit identity is the exact arrival bit pattern. After a fresh-store
    /// restore the recorder must still coalesce the original callback onto
    /// the imported row instead of inserting an unprocessed duplicate.
    @Test("a restored open Visit coalesces the original callback's departure")
    func restoredVisitCoalescesOriginalCallback() async throws {
        let suiteName = "TripDataImportRecoveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let arrival = Date(timeIntervalSinceReferenceDate: 799_958_400.123456789)
        let original = try TestSupport.makeInMemoryContainer()
        let originalContext = ModelContext(original)
        originalContext.insert(Visit(
            arrivalDate: arrival,
            latitude: Self.athens.lat, longitude: Self.athens.lon,
            horizontalAccuracy: 25, receivedAt: arrival.addingTimeInterval(1),
            isProcessed: true))
        try originalContext.save()
        let layer = try await ExportSnapshotter(modelContainer: original)
            .snapshotHomeAreaLayer()
        let data = try #require(TripDataExporter.buildExportData(
            snapshots: [], visits: layer.visits, appVersion: "test"))

        let restoredStore = try TestSupport.makeInMemoryContainer()
        let restorePayload = try TripDataImporter.parse(data)
        let outcome = await TripDataImporter(modelContainer: restoredStore)
            .importTrips(from: restorePayload)
        #expect(outcome.insertedVisits == 1)

        let departure = arrival.addingTimeInterval(1_800)
        await VisitRecorder(modelContainer: restoredStore).record(
            VisitObservation(
                source: Callback(
                    coordinate: CLLocationCoordinate2D(
                        latitude: Self.athens.lat, longitude: Self.athens.lon),
                    horizontalAccuracy: 25,
                    arrivalDate: arrival,
                    departureDate: departure),
                receivedAt: departure.addingTimeInterval(1)),
            defaults: defaults)

        let visits = try ModelContext(restoredStore).fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1)
        let row = try #require(visits.first)
        #expect(row.departureDate == departure)
        #expect(!row.isProcessed)
    }
}
