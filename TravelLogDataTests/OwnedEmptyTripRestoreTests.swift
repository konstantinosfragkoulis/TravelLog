//
//  OwnedEmptyTripRestoreTests.swift
//  TravelLogTests
//
//  A completed trip with no stays that the user owns (a name, an edit, a
//  Favorite or a hidden or pinned photo) is a row live dedup keeps and the
//  backup writes. A fresh restore beside an unrelated ordinary trip lands it
//  as that empty row with its choices. An unowned shell, an open trip and a
//  trip whose declared members were damaged stay out, as phantoms.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("Owned empty trips survive export and fresh restore")
struct OwnedEmptyTripRestoreTests {

    enum Owner: String, CaseIterable, Sendable {
        case none, name, edited, favourite, hidden, pinned
    }

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private struct Source {
        let container: ModelContainer
        let extras: BackupExtras
        let ordinaryID: UUID
        let emptyID: UUID
    }

    /// An ordinary trip with one stay and a stayless trip owned by `owner`.
    private func makeSource(owner: Owner, emptyIsComplete: Bool = true) throws -> Source {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let ordinary = Trip(startDate: Self.at(0))
        ordinary.isComplete = true
        ordinary.endDate = Self.at(30)
        ordinary.destinationSummary = "Mirto"
        ordinary.countryCodes = "GR"
        context.insert(ordinary)
        let stay = Stay(
            startTime: Self.at(1), endTime: Self.at(20),
            centroidLatitude: 44.3, centroidLongitude: 12.9,
            h3IndexRes6: try #require(H3Service.cellIndex(latitude: 44.3, longitude: 12.9)),
            pingCount: 4, distanceFromHomeKm: 210, pingIDs: [])
        stay.category = .destination
        stay.locality = "Mirto"
        stay.isoCountryCode = "GR"
        context.insert(stay)
        stay.trip = ordinary
        stay.orderInTrip = 0

        let empty = Trip(startDate: Self.at(100))
        empty.isComplete = emptyIsComplete
        empty.endDate = emptyIsComplete ? Self.at(160) : nil
        empty.destinationSummary = "Kalivo"
        empty.countryCodes = "GR"
        var extras = BackupExtras()
        switch owner {
        case .none: break
        case .name: empty.customName = "Lantern Isles"
        case .edited: empty.userEdited = true
        case .favourite: extras.favouriteTripIDs = [empty.id]
        case .hidden: context.insert(HiddenPhoto(localIdentifier: "LOCAL-H", tripID: empty.id))
        case .pinned: context.insert(PinnedPhoto(localIdentifier: "LOCAL-P", tripID: empty.id))
        }
        context.insert(empty)
        try context.save()
        return Source(container: container, extras: extras, ordinaryID: ordinary.id, emptyID: empty.id)
    }

    private func importer(for container: ModelContainer, queue: URL) async -> TripDataImporter {
        let importer = TripDataImporter(modelContainer: container)
        await importer.setReconciliationDefaultsSuiteForTesting("OwnedEmptyTrip-\(UUID().uuidString)")
        await importer.setHomeAliasDefaultsSuiteForTesting("OwnedEmptyTrip-\(UUID().uuidString)")
        await importer.setRemovedTripsDirectoryForTesting(queue)
        return importer
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnedEmptyTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the launch summary passes leave a restored owned empty trip's summary, countries and provenance")
    func launchSummaryPassesKeepOwnedEmptyTrip() async throws {
        let source = try makeSource(owner: .edited)
        let data = try await ExportSnapshotter(modelContainer: source.container).exportData(source.extras)
        let payload = try TripDataImporter.parse(data)
        let target = try TestSupport.makeInMemoryContainer()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)

        func restored() throws -> Trip {
            try #require(try ModelContext(target).fetch(FetchDescriptor<Trip>()).first { $0.id == source.emptyID })
        }
        let sourceRaw = try restored().sourceRaw
        for hydrating in [true, false] {
            let countries = await AppDelegate.recomputeAllTripCountryCodes(
                modelContainer: target, storeMayBeHydrating: hydrating)
            #expect(countries.saved)
            #expect(countries.owed == 0)
            let refresh = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
                modelContainer: target, storeMayBeHydrating: hydrating)
            #expect(refresh.saved)
            #expect(refresh.owed == 0)
            let trip = try restored()
            #expect((trip.stays ?? []).isEmpty)
            #expect(trip.destinationSummary == "Kalivo")
            #expect(trip.countryCodes == "GR")
            #expect(trip.sourceRaw == sourceRaw)
            #expect(trip.userEdited)
        }
    }

    @Test("an owned empty trip and its choice come back from a fresh restore; an unowned shell does not",
          arguments: Owner.allCases)
    func freshRestoreKeepsOwnedEmptyTrip(owner: Owner) async throws {
        let source = try makeSource(owner: owner)
        let data = try await ExportSnapshotter(modelContainer: source.container).exportData(source.extras)
        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedTrips == 0 && payload.malformedStays == 0)
        let exported = try #require(payload.trips.first { $0.id == source.emptyID })
        #expect(exported.stays.isEmpty)
        let kept = owner != .none
        #expect(payload.trips.filter(payload.ownedEmptyTrips.admits).map(\.id) == (kept ? [source.emptyID] : []))

        let target = try TestSupport.makeInMemoryContainer()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        let choices = [Owner.favourite, .hidden, .pinned].contains(owner) ? 1 : 0
        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == (kept ? 2 : 1))
        #expect(preview.newStays == 1)
        #expect(preview.newChoices == choices)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == (kept ? 2 : 1))
        #expect(outcome.insertedStays == 1)
        #expect(outcome.insertedPhotoChoices == ([Owner.hidden, .pinned].contains(owner) ? 1 : 0))
        #expect(outcome.restorableFavouriteTripIDs == (owner == .favourite ? [source.emptyID] : []))

        let context = ModelContext(target)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let ordinary = try #require(trips.first { $0.id == source.ordinaryID })
        #expect(ordinary.stays?.count == 1)
        let restored = trips.first { $0.id == source.emptyID }
        #expect((restored != nil) == kept)
        if let restored {
            #expect((restored.stays ?? []).isEmpty)
            #expect(restored.isComplete)
            #expect(restored.startDate == Self.at(100) && restored.endDate == Self.at(160))
            #expect(restored.destinationSummary == "Kalivo" && restored.countryCodes == "GR")
            #expect(restored.customName == (owner == .name ? "Lantern Isles" : nil))
            #expect(restored.userEdited == (owner == .edited))
        }
        let hidden = try context.fetch(FetchDescriptor<HiddenPhoto>())
        let pinned = try context.fetch(FetchDescriptor<PinnedPhoto>())
        #expect(hidden.map(\.tripID) == (owner == .hidden ? [source.emptyID] : []))
        #expect(pinned.map(\.tripID) == (owner == .pinned ? [source.emptyID] : []))

        // The Favorite merges into the user's set after the commit.
        let suite = "OwnedEmptyTrip-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favourites = PinnedTripsStorage(forTesting: defaults)
        let countries = RememberedCountriesStorage(forTesting: defaults)
        _ = TripDataImporter.mergeSelections(
            of: outcome, from: payload, favourites: favourites, countries: countries)
        #expect(favourites.pinnedIDs == (owner == .favourite ? [source.emptyID] : []))

        // A second restore of the same file adds nothing.
        let repeated = await importer.importTrips(from: payload)
        #expect(!repeated.saveFailed)
        #expect(repeated.insertedTrips == 0 && repeated.insertedPhotoChoices == 0)
    }

    @Test("an owned stayless trip that is open, or whose declared members were damaged, stays out",
          arguments: [false, true])
    func openOrDamagedEmptyTripStaysOut(damaged: Bool) async throws {
        let source = try makeSource(owner: .name, emptyIsComplete: damaged)
        var data = try await ExportSnapshotter(modelContainer: source.container).exportData(source.extras)
        if damaged {
            // The trip declared a member the parser drops: damaged, not empty.
            let root = try #require(try JSONSerialization.jsonObject(
                with: data, options: [.mutableContainers]) as? NSMutableDictionary)
            let trips = try #require(root["trips"] as? NSMutableArray)
            let entry = try #require(trips.compactMap { $0 as? NSMutableDictionary }
                .first { ($0["id"] as? String) == source.emptyID.uuidString })
            entry["stays"] = [NSNull()]
            data = try JSONSerialization.data(withJSONObject: root)
        }
        let payload = try TripDataImporter.parse(data)
        #expect(payload.malformedStays == (damaged ? 1 : 0))
        #expect(!payload.trips.contains(where: payload.ownedEmptyTrips.admits))

        let target = try TestSupport.makeInMemoryContainer()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        #expect(try await importer.preview(of: payload).newTrips == 1)
        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == 1)
        let trips = try ModelContext(target).fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.id) == [source.ordinaryID])
    }

    /// A file with two entries for one trip id: one declaring its stay and one
    /// declaring it empty with a name. The target already holds the stay, so
    /// the first entry attaches nothing. Emptiness is the entry's own: the
    /// named empty entry never lets the other land as a phantom shell, and
    /// the first entry for the id still decides, as for every duplicate.
    @Test("an owned empty entry never exempts another entry of its trip id from the phantom guard",
          arguments: [false, true])
    func duplicateEntriesAreJudgedOneByOne(emptyEntryFirst: Bool) async throws {
        let source = try makeSource(owner: .none)
        let sourceStays = try ModelContext(source.container).fetch(FetchDescriptor<Stay>())
        let stored = try #require(sourceStays.first)
        var data = try await ExportSnapshotter(modelContainer: source.container).exportData(source.extras)
        let root = try #require(try JSONSerialization.jsonObject(
            with: data, options: [.mutableContainers]) as? NSMutableDictionary)
        let trips = try #require(root["trips"] as? NSMutableArray)
        let entry = try #require(trips.compactMap { $0 as? NSMutableDictionary }
            .first { ($0["id"] as? String) == source.ordinaryID.uuidString })
        let emptyEntry = try #require(entry.mutableCopy() as? NSMutableDictionary)
        emptyEntry["stays"] = NSMutableArray()
        emptyEntry["customName"] = "Lantern Isles"
        let position = trips.index(of: entry)
        trips.insert(emptyEntry, at: emptyEntryFirst ? position : position + 1)
        data = try JSONSerialization.data(withJSONObject: root)
        let payload = try TripDataImporter.parse(data)
        let entries = payload.trips.filter { $0.id == source.ordinaryID }
        #expect(entries.count == 2)
        #expect(entries.map(payload.ownedEmptyTrips.admits) == (emptyEntryFirst ? [true, false] : [false, true]))

        let target = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(target)
        let copy = Stay(
            startTime: stored.startTime, endTime: stored.endTime,
            centroidLatitude: stored.centroidLatitude, centroidLongitude: stored.centroidLongitude,
            h3IndexRes6: stored.h3IndexRes6, pingCount: 4, distanceFromHomeKm: 210, pingIDs: [])
        copy.id = stored.id
        copy.category = .destination
        context.insert(copy)
        try context.save()
        let queue = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: queue) }
        let importer = await importer(for: target, queue: queue)
        let preview = try await importer.preview(of: payload)
        #expect(preview.newTrips == (emptyEntryFirst ? 1 : 0))
        #expect(preview.newStays == 0)

        let outcome = await importer.importTrips(from: payload)
        #expect(!outcome.saveFailed)
        #expect(outcome.insertedTrips == (emptyEntryFirst ? 1 : 0))
        let restored = try ModelContext(target).fetch(FetchDescriptor<Trip>())
        if emptyEntryFirst {
            let trip = try #require(restored.first)
            #expect(restored.count == 1)
            #expect(trip.id == source.ordinaryID)
            #expect(trip.customName == "Lantern Isles")
            #expect((trip.stays ?? []).isEmpty)
        } else {
            #expect(restored.isEmpty, "no phantom shell for the entry whose stay was already stored")
        }
    }
}
