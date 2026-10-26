//
//  DataWipeTests.swift
//  TravelLogTests
//
//  Pins for the "Delete All Data" wipe contract.
//  Two contracts:
//
//  1. SCHEMA ACCOUNTING — every entity in the current schema appears in
//     exactly one of `DataWipe.wipedModelTypes` / `survivingEntityNames`.
//     This is the self-extending guard for the recurring bug class: a V16
//     entity added to the schema without a wipe decision fails HERE, at
//     compile-adjacent test time, instead of silently surviving "Delete
//     Everything" until an audit finds it (YearWrapped, PlannedTrip, and
//     HomeAreaOverride were each retrofitted that way).
//
//  2. THE WIPE ITSELF — with one row of every entity seeded, execute()
//     empties every wiped table, spares Home/RoutinePlace/TemporaryHome, clears the
//     healing side state, and reports success.
//
//  The partial-failure honesty rule (a failed delete/save must return
//  false) lives in the production code's error paths; forcing a SwiftData
//  batch-delete failure requires a corrupted store, so that arm stays
//  covered by the result plumbing rather than an injected fault.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct DataWipeTests {

    @Test("every schema entity is accounted for: wiped or a documented survivor")
    func schemaEntitiesAreAllAccounted() {
        let schemaNames = Set(
            Schema(versionedSchema: CurrentTravelLogSchema.self).entities.map(\.name)
        )
        let wipedNames = Set(DataWipe.wipedModelTypes.map { String(describing: $0) })
        let survivors = DataWipe.survivingEntityNames

        #expect(wipedNames.isDisjoint(with: survivors),
                "an entity cannot be both wiped and a survivor")
        // The alert promises "your homes and routine places will be kept".
        // A temporary home is one of "your homes": wiping an active one
        // during a stay would make that stay count as travel.
        // Deriving expectations from `survivingEntityNames` alone
        // would let a misclassified entity (moved to survivor to dodge the
        // wipe) pass both tests; this literal pins the user-facing promise.
        #expect(survivors == ["Home", "RoutinePlace", "TemporaryHome"],
                "the survivor set IS the alert-copy promise (homes, temporary homes, routine places) — changing it is a product decision, not a refactor")
        #expect(
            wipedNames.union(survivors) == schemaNames,
            """
            schema entities and the wipe contract diverged. \
            Unaccounted (new entity needs a wipe decision): \
            \(schemaNames.subtracting(wipedNames).subtracting(survivors)). \
            Stale (listed but not in the schema): \
            \(wipedNames.union(survivors).subtracting(schemaNames)).
            """
        )
    }

    @Test("execute empties every wiped table, spares setup, and advances the visit floor")
    func wipeErasesEverythingItPromises() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: 886 * 86_400)

        // One row of EVERY entity.
        let trip = Trip(startDate: base)
        trip.aiGeneratedTitle = "Athens Weekend"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Σαββατοκύριακο στην Αθήνα",
            sourceTitle: "Athens Weekend",
            trip: trip))
        let stay = Stay(
            startTime: base, endTime: base.addingTimeInterval(3_600),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "861f19507ffffff", pingCount: 1,
            distanceFromHomeKm: 40, pingIDs: [])
        stay.category = .destination
        stay.trip = trip
        ctx.insert(stay)
        ctx.insert(LocationPing(
            timestamp: base, latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 30, h3IndexRes6: "861f19507ffffff", source: .liveSLC))
        ctx.insert(HexVisit(
            h3Index: "861f19507ffffff", firstVisited: base,
            centerLatitude: 37.98, centerLongitude: 23.72))
        ctx.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        ctx.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        ctx.insert(PhotoImportState(originDeviceID: "device-A"))
        ctx.insert(YearWrapped(year: 2026))
        ctx.insert(PlannedTrip(
            eventExternalIdentifier: "ext-1", eventLocalIdentifier: "loc-1",
            title: "Cephalonia", startDate: base, endDate: base.addingTimeInterval(86_400),
            isAllDay: false, locationText: nil))
        let home = Home(label: "Home", latitude: 37.98, longitude: 23.72,
                        radiusKm: 25, startedAt: base)
        ctx.insert(home)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 38.0067, centerLongitude: 23.6872,
            radiusKm: 1, homeID: home.id))
        ctx.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(3_600),
            latitude: 37.98, longitude: 23.72, horizontalAccuracy: 30,
            receivedAt: base.addingTimeInterval(3_600)))
        ctx.insert(RoutinePlace(label: "Office", latitude: 37.9867, longitude: 23.6672))
        let temporaryHome = TemporaryHome(
            label: "Erasmus", latitude: 50.85, longitude: 4.35, startedAt: base)
        let keptTripID = trip.id
        temporaryHome.coverageRevision = 3
        temporaryHome.addKeptTrip(keptTripID)
        ctx.insert(temporaryHome)
        // A correction keyed to the temporary home is travel-derived: wiped.
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 51.0291, centerLongitude: 4.1001,
            radiusKm: 1, homeID: temporaryHome.id))
        try ctx.save()

        defaults.set("stale", forKey: HomeAreaHealing.fingerprintKey)
        defaults.set("stale", forKey: HomeAreaHealing.coverageKey)
        defaults.set(Data("stale".utf8), forKey: AppDelegate.postImportHistoryTokenKey)
        let observationKeys = [
            TripDeduplicator.firstObservedGhostsKey,
            PhotoAnnotationDeduplicator.firstObservedOrphansKey,
            PhotoImportPingDeduplicator.orphanPingFirstObservedKey,
        ]
        for key in observationKeys { defaults.set(["stale": 1.0], forKey: key) }
        // A reconciliation owed for the temporary home, the removal hints and
        // the retired coverage trail's key a device that ran it still holds.
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: temporaryHome.id, defaults: defaults)
        defaults.set(["stale": ["digest": "stale", "at": 1.0] as [String: Any]],
                     forKey: CoverageReconciliationQueue.removalHintsKey)
        defaults.set(["stale": [["token": "stale"]]], forKey: "temporaryHomeCoverageTrail_v1")

        let beforeWipe = Date.now
        let succeeded = DataWipe.execute(container: container, defaults: defaults)
        #expect(succeeded, "a clean isolated-store wipe must report success")

        let fresh = ModelContext(container)
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? fresh.fetchCount(FetchDescriptor<T>())) ?? -1
        }
        for type in DataWipe.wipedModelTypes {
            #expect(count(type) == 0,
                    "wiped entity \(String(describing: type)) still has rows after Delete All Data")
        }
        #expect(count(Visit.self) == 0)
        #expect(count(Home.self) == 1, "the user's Home must survive the wipe")
        #expect(count(RoutinePlace.self) == 1, "the user's RoutinePlace must survive the wipe")
        #expect(count(TemporaryHome.self) == 1, "the user's TemporaryHome must survive the wipe")
        // It survives whole: its revision and its kept trips, which a restore
        // of the same backup brings back under the same ids.
        let survivor = try #require(try fresh.fetch(FetchDescriptor<TemporaryHome>()).first)
        #expect(survivor.coverageRevision == 3)
        #expect(survivor.keptTripIDSet == [keptTripID])
        #expect(count(HomeAreaOverride.self) == 0,
                "corrections are wiped, including the one keyed to the temporary home")
        #expect(defaults.string(forKey: HomeAreaHealing.fingerprintKey) == nil,
                "stale healing fingerprint describes the OLD store — must be cleared")
        #expect(defaults.string(forKey: HomeAreaHealing.coverageKey) == nil)
        #expect(defaults.data(forKey: AppDelegate.postImportHistoryTokenKey) == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil,
                "a reconciliation owed for stays the wipe deleted has nothing left to reconcile")
        #expect(defaults.object(forKey: CoverageReconciliationQueue.removalHintsKey) == nil,
                "the removal hints describe stays the wipe deleted")
        #expect(defaults.object(forKey: "temporaryHomeCoverageTrail_v1") == nil,
                "the retired coverage trail goes with the reconciliation it was recorded for")
        for key in observationKeys {
            #expect(defaults.dictionary(forKey: key) == nil,
                    "observation map \(key) describes deleted rows and must be cleared")
        }
        let acceptanceFloor = try #require(
            defaults.object(
                forKey: VisitRecorder.acceptanceFloorKey) as? Date)
        #expect(acceptanceFloor >= beforeWipe)
        #expect((defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) as? Date)
                == acceptanceFloor,
                "the live floor advances at the same committed instant")
    }

    @Test("removed temporary homes survive the wipe as removed; the removal hints and the retired trail key are cleared after a committed wipe and kept by a failed one",
          arguments: [true, false])
    func wipeKeepsRemovedTemporaryHomesAndClearsHintsOnlyAfterCommit(commits: Bool) throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: 886 * 86_400)
        let removedAt = base.addingTimeInterval(30 * 86_400)
        let live = TemporaryHome(label: "Erasmus", latitude: 50.85, longitude: 4.35, startedAt: base)
        let removed = TemporaryHome(label: "Old flat", latitude: 38.6736, longitude: -9.1561, startedAt: base)
        removed.removedAt = removedAt
        // A same-id twin of the removed one, live: still hidden after the wipe.
        let twin = TemporaryHome(label: "Old flat", latitude: 38.6736, longitude: -9.1561, startedAt: base)
        twin.id = removed.id
        for row in [live, removed, twin] { ctx.insert(row) }
        ctx.insert(Trip(startDate: base))
        try ctx.save()
        let hints = [removed.id.uuidString: ["digest": "abc", "at": 1.0] as [String: Any]]
        defaults.set(hints, forKey: CoverageReconciliationQueue.removalHintsKey)
        defaults.set(["stale": [["token": "stale"]]], forKey: "temporaryHomeCoverageTrail_v1")
        defaults.set([live.id.uuidString: ["token": "t", "status": "failed"]],
                     forKey: CoverageReconciliationQueue.temporaryHomeStatusKey)

        let succeeded = DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: { if !commits { throw CocoaError(.fileWriteUnknown) } })

        #expect(succeeded == commits)
        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<TemporaryHome>())
        #expect(rows.count == 3)
        #expect(rows.filter { $0.id == removed.id }.compactMap(\.removedAt) == [removedAt])
        #expect(try HomeAnchors.temporaryHomes(in: fresh).map(\.id) == [live.id])
        #expect(try fresh.fetchCount(FetchDescriptor<Trip>()) == (commits ? 0 : 1))
        if commits {
            #expect(defaults.object(forKey: CoverageReconciliationQueue.removalHintsKey) == nil)
            #expect(defaults.object(forKey: "temporaryHomeCoverageTrail_v1") == nil)
            #expect(defaults.object(forKey: CoverageReconciliationQueue.temporaryHomeStatusKey) == nil)
        } else {
            #expect(defaults.dictionary(forKey: CoverageReconciliationQueue.removalHintsKey) != nil)
            #expect(defaults.object(forKey: "temporaryHomeCoverageTrail_v1") != nil)
            #expect(defaults.dictionary(forKey: CoverageReconciliationQueue.temporaryHomeStatusKey) != nil)
        }
    }

    @Test("the temporary-home acknowledgements are cleared after a committed wipe and kept by a failed one; failing to clear them does not fail the wipe",
          arguments: [true, false])
    func wipeClearsTemporaryHomeAcknowledgementsOnlyAfterCommit(commits: Bool) throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataWipeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let live = TemporaryHome(
            label: "Erasmus", latitude: 50.85, longitude: 4.35,
            startedAt: Date(timeIntervalSinceReferenceDate: 886 * 86_400))
        ctx.insert(live)
        try ctx.save()
        CoverageReconciliationQueue.Acknowledgements.record(
            live.id, digest: "abc", deferred: true, at: .now, in: directory)

        var effects = DataWipe.SideEffects.isolated
        effects.clearTemporaryHomeAcknowledgements = {
            try CoverageReconciliationQueue.Acknowledgements.clear(in: directory)
        }
        let succeeded = DataWipe.execute(
            container: container, defaults: defaults, sideEffects: effects,
            beforeCommit: { if !commits { throw CocoaError(.fileWriteUnknown) } })

        #expect(succeeded == commits)
        #expect(CoverageReconciliationQueue.Acknowledgements.load(from: directory).isEmpty == commits)
        // The declaration survives either way.
        #expect(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).map(\.id) == [live.id])

        // A failure to clear them is logged, not reported: they only schedule work.
        var failing = DataWipe.SideEffects.isolated
        failing.clearTemporaryHomeAcknowledgements = { throw CocoaError(.fileWriteUnknown) }
        #expect(DataWipe.execute(container: container, defaults: defaults, sideEffects: failing))
    }

    @Test("execute on an empty store is a clean no-op")
    func emptyStoreWipeSucceeds() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        #expect(DataWipe.execute(container: container, defaults: defaults))
    }

    @Test("a failed wipe save rolls back every pending deletion")
    func failedSaveCannotLeakWipeIntoLaterSave() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sentinelFloor = Date(timeIntervalSinceReferenceDate: 123)
        defaults.set(
            sentinelFloor, forKey: VisitRecorder.acceptanceFloorKey)
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let trip = Trip(startDate: .now)
        trip.aiGeneratedTitle = "Still Here"
        context.insert(trip)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Noch da",
            sourceTitle: "Still Here", trip: trip))
        let home = Home(
            label: "Home", latitude: 37.98, longitude: 23.72,
            radiusKm: 25, startedAt: .now)
        context.insert(home)
        try context.save()

        var rememberedCodes: Set<String> = ["GR", "IT"]
        let wiped = DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: { throw CocoaError(.fileWriteUnknown) },
            afterCommit: { rememberedCodes = [] })
        #expect(!wiped)

        #expect(rememberedCodes == ["GR", "IT"])

        // A later unrelated main-context save must not commit the failed
        // operation's pending deletions.
        home.label = "Home Updated Later"
        try context.save()
        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try verification.fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 1)
        #expect(try verification.fetch(FetchDescriptor<Home>()).first?.label
                == "Home Updated Later")
        #expect(
            (defaults.object(
                forKey: VisitRecorder.acceptanceFloorKey) as? Date)
                == sentinelFloor)
        #expect(defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) == nil,
                "a rolled-back wipe keeps live retry authority")
    }

    @Test("a failed wipe keeps an earlier unrelated pending edit")
    func failedWipePreservesEarlierPendingEdit() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sentinelFloor = Date(timeIntervalSinceReferenceDate: 123)
        defaults.set(
            sentinelFloor, forKey: VisitRecorder.acceptanceFloorKey)
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(Trip(startDate: .now))
        let home = Home(
            label: "Home", latitude: 37.98, longitude: 23.72,
            radiusKm: 25, startedAt: .now)
        context.insert(home)
        try context.save()
        home.label = "Renamed Before Wipe"

        #expect(!DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: { throw CocoaError(.fileWriteUnknown) }))

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try verification.fetch(FetchDescriptor<Home>()).first?.label
                == "Renamed Before Wipe")
        #expect(
            (defaults.object(
                forKey: VisitRecorder.acceptanceFloorKey) as? Date)
                == sentinelFloor)
        #expect(defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) == nil,
                "a rolled-back wipe keeps live retry authority")
    }

    @Test("queue clear failure falls back to direct queue-file removal")
    func queueClearFailureFallsBackToDirectRemoval() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(Trip(startDate: .now))
        try context.save()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataWipeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: directory))
        try Data("personal trip metadata".utf8).write(to: queueURL)

        var effects = DataWipe.SideEffects.isolated
        effects.clearDissolvedQueue = { throw CocoaError(.fileWriteNoPermission) }
        effects.dissolvedQueueFileURL = { queueURL }
        effects.removeDissolvedQueueFile = { try FileManager.default.removeItem(at: $0) }
        #expect(DataWipe.execute(container: container, defaults: defaults, sideEffects: effects))
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: queueURL.path))
    }

    @Test("queue residue after both clear attempts reports honest failure")
    func queueResidueLeavesWipeFailed() throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(Trip(startDate: .now))
        try context.save()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataWipeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: directory))
        try Data("personal trip metadata".utf8).write(to: queueURL)

        let beforeWipe = Date.now
        var rememberedCodes: Set<String> = ["GR", "IT"]
        var tripsAtClear: Int?
        var effects = DataWipe.SideEffects.isolated
        effects.clearDissolvedQueue = { throw CocoaError(.fileWriteNoPermission) }
        effects.dissolvedQueueFileURL = { queueURL }
        effects.removeDissolvedQueueFile = { _ in throw CocoaError(.fileWriteNoPermission) }
        let wiped = DataWipe.execute(
            container: container, defaults: defaults, sideEffects: effects,
            afterCommit: {
                tripsAtClear = try? ModelContext(container).fetchCount(FetchDescriptor<Trip>())
                rememberedCodes = []
            })
        #expect(!wiped)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 0,
                "the store commit still happened before queue cleanup")
        #expect(rememberedCodes.isEmpty)
        #expect(tripsAtClear == 0, "the checklist is cleared only after the store deletion commits")
        #expect(FileManager.default.fileExists(atPath: queueURL.path),
                "personal queue residue makes the overall wipe fail")
        let acceptanceFloor = try #require(
            defaults.object(
                forKey: VisitRecorder.acceptanceFloorKey) as? Date)
        #expect(acceptanceFloor >= beforeWipe)
        #expect((defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) as? Date)
                == acceptanceFloor,
                "failed post-commit cleanup still advances both floors")
    }

    @Test("a committed wipe drops the ghost carry log, a failed one keeps it, and a later restore cannot re-key through it")
    func wipeClearsCarryLogOnlyAfterCommit() async throws {
        let suiteName = "DataWipeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ghostID = UUID()
        let winnerID = UUID()
        let entry = "\(ghostID.uuidString) \(winnerID.uuidString)"
        defaults.set([entry], forKey: TripDeduplicator.carriedFavouritesKey)
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(Trip(startDate: .now))
        try context.save()

        #expect(!DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: { throw CocoaError(.fileWriteUnknown) }))
        #expect(defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey) == [entry])

        #expect(DataWipe.execute(container: container, defaults: defaults))
        #expect(defaults.stringArray(forKey: TripDeduplicator.carriedFavouritesKey) == nil)

        // A backup restored afterwards brings back the old winner's UUID and
        // a photo row keyed to the old ghost: it stays an ordinary orphan.
        let restore = ModelContext(container)
        let winner = Trip(startDate: .now)
        winner.id = winnerID
        restore.insert(winner)
        restore.insert(HiddenPhoto(localIdentifier: "restored", tripID: ghostID))
        try restore.save()
        let sweep = await PhotoAnnotationDeduplicator.sweepOrphans(
            modelContainer: container, now: .now, defaults: defaults)
        #expect(sweep.completed)
        #expect(sweep.rekeyedOnto.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [ghostID])
    }
}
