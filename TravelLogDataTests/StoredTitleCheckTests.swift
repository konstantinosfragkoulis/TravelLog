//
//  StoredTitleCheckTests.swift
//  TravelLogTests
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
/// Stored titles from older builds (a model title, or one in the retired
/// prompt spelling "Troms" for Tromsø) arriving after the launch pass: from
/// CloudKit and from backups. Each becomes its trip's default title unless
/// it is one of the trip's title alternatives.
@Suite("Stored title check", .serialized)
struct StoredTitleCheckTests {

    private struct Place {
        var locality: String
        var region: String? = nil
        var hours: Double = 24
    }

    /// A complete trip with one destination stay per place, in order.
    private func makeTrip(
        _ places: [Place], title: String?, customName: String? = nil,
        in context: ModelContext
    ) throws -> Trip {
        let start = Date(timeIntervalSinceReferenceDate: 830_844_800)
        let trip = Trip(startDate: start)
        trip.isComplete = true
        trip.aiGeneratedTitle = title
        trip.customName = customName
        context.insert(trip)
        var cursor = start
        for (index, place) in places.enumerated() {
            let stay = makeStay(place, startingAt: cursor, index: index)
            context.insert(stay)
            stay.trip = trip
            stay.orderInTrip = index
            cursor = stay.endTime.addingTimeInterval(3_600)
            trip.endDate = stay.endTime
        }
        try context.save()
        return trip
    }

    /// One destination stay at `place`, not yet inserted.
    private func makeStay(_ place: Place, startingAt start: Date, index: Int) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(place.hours * 3_600),
            centroidLatitude: 69.6161 - Double(index),
            centroidLongitude: 19.0718,
            h3IndexRes6: "8a2a1072b59ffff",
            pingCount: 2,
            distanceFromHomeKm: 2_000,
            pingIDs: [])
        stay.category = .destination
        stay.durationMinutes = Int(place.hours * 60)
        stay.locality = place.locality
        stay.administrativeArea = place.region
        stay.country = "Norway"
        stay.isoCountryCode = "NO"
        return stay
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "legacy-title-repair-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func storedTitle(of tripID: UUID, in container: ModelContainer) throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == tripID })).first?.aiGeneratedTitle
    }

    @Test("A late title from an older build is checked after the launch pass; custom names and trips without their stays are untouched")
    func lateArrivalsAreRepaired() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tromso = [Place(locality: "Tromsø", region: "Troms")]
        let late = try makeTrip(tromso, title: "Troms", in: context)
        let revision = UUID()
        late.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Troms", sourceTitle: "Troms",
            sourceRevision: revision, trip: late))
        let custom = try makeTrip(tromso, title: "Troms", customName: "Arctic", in: context)
        let stayless = try makeTrip([], title: "Troms", in: context)
        let current = try makeTrip(tromso, title: "Tromsø", in: context)
        let rejected = try makeTrip(tromso, title: "Troms & Paris", in: context)
        // Its summary names a stay this device does not hold yet.
        let partial = try makeTrip(tromso, title: "Troms & Bod", in: context)
        partial.destinationSummary = "Tromsø, Bodø"
        try context.save()

        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        func fetch() throws -> [UUID: Trip] {
            let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
            return Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var byID = try fetch()
        let repaired = try #require(byID[late.id])
        #expect(repaired.aiGeneratedTitle == "Tromsø")
        let repairedRevision = try #require(repaired.titleSourceRevision)
        #expect(repairedRevision != revision)
        #expect((repaired.localizedTitles ?? []).isEmpty)
        #expect(byID[custom.id]?.aiGeneratedTitle == "Troms")
        #expect(byID[custom.id]?.customName == "Arctic")
        #expect(byID[stayless.id]?.aiGeneratedTitle == "Troms")
        #expect(byID[current.id]?.aiGeneratedTitle == "Tromsø")
        #expect(byID[rejected.id]?.aiGeneratedTitle == "Tromsø")
        #expect(byID[partial.id]?.aiGeneratedTitle == "Troms & Bod")

        // Idempotent: a second completed import changes nothing.
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        byID = try fetch()
        #expect(byID[late.id]?.titleSourceRevision == repairedRevision)
        #expect(byID[stayless.id]?.aiGeneratedTitle == "Troms")
    }

    /// A backup of one Tromsø trip titled in the retired spelling.
    private func backupJSON(revision: UUID) -> String {
        """
        {
          "exportDate": "2026-12-24T00:00:00Z",
          "appVersion": "1.0",
          "trips": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "startDate": "2025-04-23T08:00:00Z",
              "endDate": "2025-04-27T18:00:00Z",
              "isComplete": true,
              "destinationSummary": "Tromsø",
              "countryCodes": "NO",
              "classifiedByAI": true,
              "aiGeneratedTitle": "Troms",
              "titleSourceRevision": "\(revision.uuidString)",
              "localizedTitles": [
                {
                  "id": "\(UUID().uuidString)",
                  "languageTag": "de",
                  "title": "Troms",
                  "sourceTitle": "Troms",
                  "sourceRevision": "\(revision.uuidString)",
                  "generationVersion": \(TripTitleStore.currentGenerationVersion),
                  "updatedAt": "2026-12-24T00:00:00Z"
                }
              ],
              "stays": [
                {
                  "id": "55555555-5555-5555-5555-555555555555",
                  "startTime": "2025-04-23T10:00:00Z",
                  "endTime": "2025-04-27T16:00:00Z",
                  "durationMinutes": 6120,
                  "category": "destination",
                  "latitude": 69.6161,
                  "longitude": 19.0718,
                  "pingCount": 14,
                  "distanceFromHomeKm": 2000.0,
                  "locality": "Tromsø",
                  "administrativeArea": "Troms",
                  "country": "Norway",
                  "isoCountryCode": "NO"
                }
              ]
            }
          ]
        }
        """
    }

    @Test("A backup title in the retired spelling becomes the default title on import and loses its derivatives")
    func backupImportRespellsTitles() async throws {
        let revision = UUID()
        let json = backupJSON(revision: revision)
        let payload = try BackupFixture.parse(json: json)
        let container = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: container).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)

        let restored = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(restored.stays?.first?.locality == "Tromsø")
        #expect(restored.aiGeneratedTitle == "Tromsø")
        #expect(restored.titleSourceRevision != nil && restored.titleSourceRevision != revision)
        #expect((restored.localizedTitles ?? []).isEmpty)
    }

    @Test("A backup import checks only the trips it titled")
    func backupImportChecksOnlyItsTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        // Already in the store; the launch pass owns it, not the import.
        let context = ModelContext(container)
        let earlier = try makeTrip(
            [Place(locality: "Tromsø", region: "Troms")], title: "Troms", in: context)
        let payload = try BackupFixture.parse(json: backupJSON(revision: UUID()))
        let outcome = await TripDataImporter(modelContainer: container).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)

        let restoredID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        #expect(try storedTitle(of: restoredID, in: container) == "Tromsø")
        #expect(try storedTitle(of: earlier.id, in: container) == "Troms")
    }

    @Test("The completed-import pass checks the trips its history window touched, including a title whose stays land later")
    func importPassFollowsTheHistoryWindow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tromso = Place(locality: "Tromsø", region: "Troms")
        // Landed before the last completed pass: outside the window.
        let context = ModelContext(container)
        let earlier = try makeTrip([tromso], title: "Troms", in: context)
        func window(now: Date = .now) -> AppDelegate.PostImportHistoryWindow {
            AppDelegate.postImportHistoryWindow(
                modelContainer: container, defaults: defaults, isPersistentStore: true, now: now)
        }
        let first = window()
        #expect(first.titleRepairScope == .all)
        AppDelegate.finishPostImportPass(first, completed: true, defaults: defaults)

        // An older device's title arrives ahead of its stays.
        let remote = ModelContext(container)
        remote.author = "NSCloudKitMirroringDelegate.import"
        let start = Date(timeIntervalSinceReferenceDate: 840_844_800)
        let late = Trip(startDate: start)
        late.isComplete = true
        late.aiGeneratedTitle = "Troms"
        remote.insert(late)
        try remote.save()

        let titleOnly = window()
        #expect(titleOnly.mustRun)
        guard case .changed(let titleTrips, _) = titleOnly.titleRepairScope else {
            Issue.record("A bounded window must scope the title check")
            return
        }
        #expect(titleTrips.contains(late.persistentModelID))
        #expect(!titleTrips.contains(earlier.persistentModelID))
        #expect(AppDelegate.reconcileStoredTitles(
            modelContainer: container, scope: titleOnly.titleRepairScope))
        AppDelegate.finishPostImportPass(titleOnly, completed: true, defaults: defaults)
        #expect(try storedTitle(of: late.id, in: container) == "Troms")
        #expect(try storedTitle(of: earlier.id, in: container) == "Troms")

        // Its stay lands in the next import.
        let stay = makeStay(tromso, startingAt: start, index: 0)
        remote.insert(stay)
        stay.trip = late
        stay.orderInTrip = 0
        late.endDate = stay.endTime
        try remote.save()

        let stayWindow = window()
        #expect(stayWindow.mustRun)
        guard case .changed(_, let stayRows) = stayWindow.titleRepairScope else {
            Issue.record("A bounded window must scope the title check")
            return
        }
        #expect(stayRows.contains(stay.persistentModelID))
        #expect(AppDelegate.reconcileStoredTitles(
            modelContainer: container, scope: stayWindow.titleRepairScope))
        AppDelegate.finishPostImportPass(stayWindow, completed: true, defaults: defaults)
        #expect(try storedTitle(of: late.id, in: container) == "Tromsø")
        #expect(try storedTitle(of: earlier.id, in: container) == "Troms")

        // The daily full pass checks every titled trip.
        let daily = window(now: Date.now.addingTimeInterval(AppDelegate.postImportFullPassInterval + 60))
        #expect(daily.mustRun)
        #expect(daily.titleRepairScope == .all)
        #expect(AppDelegate.reconcileStoredTitles(
            modelContainer: container, scope: daily.titleRepairScope))
        #expect(try storedTitle(of: earlier.id, in: container) == "Tromsø")
    }

    @Test("A window that touched more rows than the limit checks every titled trip")
    func largeWindowChecksEveryTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try makeTrip([Place(locality: "Tromsø")], title: "Troms", in: ModelContext(container))
        let first = AppDelegate.postImportHistoryWindow(
            modelContainer: container, defaults: defaults, isPersistentStore: true)
        AppDelegate.finishPostImportPass(first, completed: true, defaults: defaults)

        let remote = ModelContext(container)
        remote.author = "NSCloudKitMirroringDelegate.import"
        let start = Date(timeIntervalSinceReferenceDate: 850_844_800)
        for index in 0...AppDelegate.storedTitleCheckRowLimit {
            remote.insert(makeStay(
                Place(locality: "Bodø"),
                startingAt: start.addingTimeInterval(Double(index) * 86_400), index: index))
        }
        try remote.save()

        let window = AppDelegate.postImportHistoryWindow(
            modelContainer: container, defaults: defaults, isPersistentStore: true)
        #expect(window.mustRun)
        #expect(window.titleRepairScope == .all)
    }
}
