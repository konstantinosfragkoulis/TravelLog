//
//  HomeCorrectionContinuityTests.swift
//  TravelLogTests
//
//  Corrections (HomeAreaOverride) are scoped to a Home row, and two Home
//  lifecycle events move them:
//
//  - Dedup collapse: the loser is the same logical Home, so its
//    corrections are re-pointed to the survivor. A correction that arrives
//    after the loser row is gone is re-pointed from the device-local alias
//    log on the next PlacesDeduplicator pass or JSON import.
//  - Nearby Home version: the ended Home keeps classifying its own
//    era, so its corrections are copied to the successor, never re-pointed.
//    The Places list withdraws one taught place in every era, and Undo
//    withdraws the copies of what the demotion taught.
//
//  Same square-urban-centre harness as HomeAreaHealingTests.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Serialized: PlacesDeduplicator's and HomeSaveWorker's read-failure seams are static.
@MainActor
@Suite(.serialized)
struct HomeCorrectionContinuityTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private nonisolated static let home = (lat: 38.0, lon: 23.8)
    /// ~3.5 km east: past the 1 km version split, inside the 25 km carry limit.
    private static let movedHome = (lat: 38.0, lon: 23.84)
    /// Beyond the 25 km carry limit: a relocation that carries nothing.
    private static let farHome = (lat: 39.66, lon: 20.85)
    private static let village = (lat: 38.0, lon: 23.99)
    private static let hamlet = (lat: 38.05, lon: 24.1)
    private static let lowID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let highID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
    private let now = Date(timeIntervalSince1970: 1_730_240_000)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (350 + offset) * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestCity", areaKm2: 100,
            rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "HomeCorrectionContinuityTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @discardableResult
    private func insertHome(
        _ ctx: ModelContext, id: UUID? = nil,
        at coord: (lat: Double, lon: Double) = HomeCorrectionContinuityTests.home,
        radiusKm: Double = 3, startDay: Double = -100
    ) -> Home {
        let row = Home(label: "Home", latitude: coord.lat, longitude: coord.lon,
                       radiusKm: radiusKm, startedAt: date(day: startDay))
        if let id { row.id = id }
        row.locality = "Athens"
        row.country = "Greece"
        row.isoCountryCode = "GR"
        ctx.insert(row)
        return row
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, day: Double,
        at coord: (lat: Double, lon: Double), category: StayCategory, hex: String
    ) -> Stay {
        let start = date(day: day)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(4 * 3600),
            centroidLatitude: coord.lat, centroidLongitude: coord.lon,
            h3IndexRes6: hex, pingCount: 2, distanceFromHomeKm: 17, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    private func makeVillageTrip(in ctx: ModelContext, startDay: Double) -> Trip {
        let trip = Trip(startDate: date(day: startDay))
        trip.endDate = date(day: startDay + 0.5)
        trip.isComplete = true
        ctx.insert(trip)
        let stay = makeStay(in: ctx, day: startDay, at: Self.village,
                            category: .destination, hex: "V")
        stay.trip = trip
        return trip
    }

    private func editPayload(
        _ id: UUID, to coord: (lat: Double, lon: Double)
    ) -> HomeSavePayload {
        HomeSavePayload(
            target: .edit(id), label: "Home",
            latitude: coord.lat, longitude: coord.lon, radiusKm: 3,
            locality: "Athens", administrativeArea: "Attica",
            country: "Greece", isoCountryCode: "GR",
            endingExistingHomes: false, shownActiveHomeIDs: [], now: now)
    }

    private func overrides(_ container: ModelContainer) throws -> [HomeAreaOverride] {
        try ModelContext(container).fetch(FetchDescriptor<HomeAreaOverride>())
    }

    // MARK: - late corrections for a collapsed Home

    @Test("an include arriving after its Home was collapsed is re-pointed and classifies again")
    func lateIncludeForCollapsedHomeIsRebound() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: Self.lowID)
        insertHome(ctx, id: Self.highID, at: (Self.home.lat + 0.001, Self.home.lon))
        try ctx.save()

        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        #expect(PlacesDeduplicator.loadHomeAliases(defaults: defaults)
                == [Self.highID: Self.lowID])

        // The lagging device's correction lands after the loser is gone.
        let late = ModelContext(container)
        late.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: Self.highID))
        let tripID = makeVillageTrip(in: late, startDay: 0).id
        try late.save()

        let unrepaired = TripClassifier(modelContainer: container)
        await unrepaired.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        #expect(await unrepaired.healHomeAreaCorrections(pinnedTripIDs: []).moved == 0,
                "bound to the deleted loser, the include claims nothing")

        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        #expect(try overrides(container).map(\.homeID) == [Self.lowID])

        let repaired = TripClassifier(modelContainer: container)
        await repaired.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let healed = await repaired.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(healed.moved == 1)
        #expect(!healed.failed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .allSatisfy { $0.id != tripID })
    }

    @Test("a late exclude is re-pointed too")
    func lateExcludeForCollapsedHomeIsRebound() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: Self.lowID)
        insertHome(ctx, id: Self.highID, at: (Self.home.lat + 0.001, Self.home.lon))
        try ctx.save()
        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))

        let late = ModelContext(container)
        late.insert(HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1, homeID: Self.highID))
        try late.save()

        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        let row = try #require(try overrides(container).first)
        #expect(row.homeID == Self.lowID)
        #expect(row.kind == .exclude)
    }

    @Test("a correction whose Home is missing but never collapsed here is left alone, as is one whose loser row exists")
    func unloggedOrPresentHomesAreNotRebound() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: Self.lowID)
        // The logged loser's row is back (ended), so it owns its rows again.
        let returned = insertHome(ctx, id: Self.highID, at: Self.farHome)
        returned.endedAt = date(day: -50)
        let unsynced = UUID()
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: unsynced))
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1, homeID: Self.highID))
        try ctx.save()
        PlacesDeduplicator.storeHomeAliases([Self.highID: Self.lowID], defaults: defaults)

        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        let homeIDs = Set(try overrides(container).compactMap(\.homeID))
        #expect(homeIDs == [unsynced, Self.highID])
    }

    @Test("alias chains resolve to the newest existing survivor; cycles resolve to nothing")
    func aliasChainsAndCycles() async throws {
        let a = UUID(), b = UUID(), c = UUID(), x = UUID(), y = UUID()
        #expect(PlacesDeduplicator.mergingHomeAliases(
            [c: b], [.init(loser: b, survivor: a)]) == [c: a, b: a])

        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: a)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: c))
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1, homeID: x))
        try ctx.save()
        // An uncompacted chain and a malformed cycle.
        PlacesDeduplicator.storeHomeAliases([c: b, b: a, x: y, y: x], defaults: defaults)

        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        let rows = try overrides(container)
        #expect(rows.first { $0.centerLatitude == Self.village.lat }?.homeID == a)
        #expect(rows.first { $0.centerLatitude == Self.hamlet.lat }?.homeID == x)
    }

    @Test("a failed replay read rolls back and keeps the alias log")
    func replayReadFailureRollsBack() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: Self.lowID)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: Self.highID))
        try ctx.save()
        PlacesDeduplicator.storeHomeAliases([Self.highID: Self.lowID], defaults: defaults)

        PlacesDeduplicator.failOverrideFetchForTestingContainer = container
        defer { PlacesDeduplicator.failOverrideFetchForTestingContainer = nil }
        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults) == false)
        #expect(try overrides(container).map(\.homeID) == [Self.highID])
        #expect(PlacesDeduplicator.loadHomeAliases(defaults: defaults)
                == [Self.highID: Self.lowID])

        PlacesDeduplicator.failOverrideFetchForTestingContainer = nil
        #expect(await PlacesDeduplicator.deduplicateAll(
            modelContainer: container, defaults: defaults))
        #expect(try overrides(container).map(\.homeID) == [Self.lowID])
    }

    @Test("a JSON import logs its own collapse, and a later override-only import naming that Home is re-pointed")
    func importerLogsCollapseAndReplaysLateOverrides() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        insertHome(ctx, id: Self.lowID)
        try ctx.save()
        let importer = TripDataImporter(modelContainer: container)
        await importer.setHomeAliasDefaultsSuiteForTesting(suite)

        let twin = """
        {
          "formatVersion": 6,
          "trips": [],
          "homes": [
            { "id": "\(Self.highID.uuidString)", "label": "Home",
              "latitude": \(Self.home.lat + 0.001), "longitude": \(Self.home.lon),
              "radiusKm": 3, "startedAt": "2024-12-16T00:00:00Z" }
          ]
        }
        """
        let first = await importer.importTrips(from: try TripDataImporter.parse(Data(twin.utf8)))
        #expect(!first.saveFailed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Home>()).map(\.id)
                == [Self.lowID])
        #expect(PlacesDeduplicator.loadHomeAliases(defaults: defaults)
                == [Self.highID: Self.lowID])

        let overrideID = UUID()
        let lateOverride = """
        {
          "formatVersion": 6,
          "trips": [],
          "homeAreaOverrides": [
            { "id": "\(overrideID.uuidString)", "kindRaw": "include",
              "centerLatitude": \(Self.village.lat), "centerLongitude": \(Self.village.lon),
              "radiusKm": 1, "homeID": "\(Self.highID.uuidString)",
              "createdAt": "2025-12-17T00:00:00Z" }
          ]
        }
        """
        let second = await importer.importTrips(
            from: try TripDataImporter.parse(Data(lateOverride.utf8)))
        #expect(!second.saveFailed)
        let row = try #require(try overrides(container).first { $0.id == overrideID })
        #expect(row.homeID == Self.lowID)
    }

    // MARK: - nearby Home versions copy corrections

    @Test("a nearby pin edit copies corrections to the new Home and leaves the originals with the old era")
    func nearbyEditCopiesCorrections() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = insertHome(ctx)
        let originalID = original.id
        let include = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 2.5,
            homeID: originalID, sourceTripName: "Village Weekend")
        let exclude = HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1.5, homeID: originalID)
        ctx.insert(include)
        ctx.insert(exclude)
        try ctx.save()
        let includeID = include.id, excludeID = exclude.id

        let result = HomeSaveWorker.apply(
            editPayload(originalID, to: Self.movedHome), context: ctx,
            pendingDefaults: defaults)
        #expect(!result.failed)
        let successorID = try #require(result.reconcileHomeID)
        #expect(successorID != originalID)

        let rows = try overrides(container)
        #expect(rows.count == 4)
        #expect(rows.first { $0.id == includeID }?.homeID == originalID)
        #expect(rows.first { $0.id == excludeID }?.homeID == originalID)
        for source in rows where source.homeID == originalID {
            let copy = try #require(rows.first {
                $0.homeID == successorID && $0.kindRaw == source.kindRaw
            })
            #expect(copy.id != source.id)
            #expect(copy.centerLatitude == source.centerLatitude)
            #expect(copy.centerLongitude == source.centerLongitude)
            #expect(copy.radiusKm == source.radiusKm)
            #expect(copy.sourceTripName == source.sourceTripName)
            #expect(copy.createdAt == source.createdAt)
        }
    }

    @Test("I Moved - Replace copies; colliding sources copy the deduplicator's winner once")
    func replaceCopiesOnceFromTheOldestSource() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = insertHome(ctx)
        let second = insertHome(ctx, at: (Self.home.lat, Self.home.lon + 0.02))
        let newer = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 4, homeID: first.id)
        newer.createdAt = date(day: 20)
        let older = HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 2, homeID: second.id)
        older.createdAt = date(day: 10)
        ctx.insert(newer)
        ctx.insert(older)
        try ctx.save()

        let result = HomeSaveWorker.apply(
            HomeSavePayload(
                target: .add, label: "New", latitude: Self.movedHome.lat,
                longitude: Self.movedHome.lon, radiusKm: 3, locality: "Athens",
                administrativeArea: "Attica", country: "Greece", isoCountryCode: "GR",
                endingExistingHomes: true, shownActiveHomeIDs: [first.id, second.id],
                now: now),
            context: ctx, pendingDefaults: defaults)
        let successorID = try #require(result.reconcileHomeID)

        let rows = try overrides(container)
        #expect(rows.count == 3)
        let copies = rows.filter { $0.homeID == successorID }
        #expect(copies.count == 1)
        #expect(copies.first?.radiusKm == 2)
        #expect(copies.first?.createdAt == date(day: 10))
    }

    @Test("a relocation beyond the carry limit copies nothing")
    func farMoveCopiesNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = insertHome(ctx)
        let originalID = original.id
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: originalID))
        try ctx.save()

        let result = HomeSaveWorker.apply(
            editPayload(originalID, to: Self.farHome), context: ctx,
            pendingDefaults: defaults)
        #expect(result.reconcileHomeID != nil)
        #expect(try overrides(container).map(\.homeID) == [originalID])
    }

    @Test("after a nearby move, reconciliation keeps the old era's include-claimed home stays")
    func oldEraCorrectionKeepsClassifyingAfterNearbyMove() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = insertHome(ctx)
        let originalID = original.id
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: originalID))
        // An automatic sibling stay the include made home in the old era…
        let sibling = makeStay(in: ctx, day: 1, at: Self.village, category: .home, hex: "S")
        // …and a later journey, so the new Home is not backdated over it.
        makeStay(in: ctx, day: 5, at: Self.farHome, category: .destination, hex: "F")
        try ctx.save()
        let siblingID = sibling.id

        let result = HomeSaveWorker.apply(
            editPayload(originalID, to: Self.movedHome), context: ctx,
            pendingDefaults: defaults)
        let successorID = try #require(result.reconcileHomeID)

        let classifier = TripClassifier(modelContainer: container)
        for coord in [Self.home, Self.movedHome] {
            await classifier.primeShapeForTesting(
                latitude: coord.lat, longitude: coord.lon, shape: Self.squareShape())
        }
        let outcome = await classifier.applyHomeChangeCore(homeID: successorID)
        #expect(outcome.isSettled)
        let stay = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == siblingID })
        #expect(stay.category == .home, "the ended Home's include still claims its era")
    }

    @Test("removing a taught place withdraws it in every Home era and frees the stays each era claimed")
    func placeRemovalWithdrawsEveryEra() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let moveDay = 100.0
        let old = insertHome(ctx)
        old.endedAt = date(day: moveDay)
        let successor = insertHome(ctx, at: Self.movedHome, startDay: moveDay)
        let taughtAt = date(day: -5)
        for owner in [old.id, successor.id] {
            let row = HomeAreaOverride(
                kind: .include, centerLatitude: Self.village.lat,
                centerLongitude: Self.village.lon, radiusKm: 1, homeID: owner)
            row.createdAt = taughtAt
            ctx.insert(row)
        }
        let unrelated = HomeAreaOverride(
            kind: .exclude, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1, homeID: successor.id)
        ctx.insert(unrelated)
        makeStay(in: ctx, day: 1, at: Self.village, category: .home, hex: "OLD")
        makeStay(in: ctx, day: moveDay + 10, at: Self.village, category: .home, hex: "NEW")
        try ctx.save()
        let unrelatedID = unrelated.id

        let classifier = TripClassifier(modelContainer: container)
        for coord in [Self.home, Self.movedHome] {
            await classifier.primeShapeForTesting(
                latitude: coord.lat, longitude: coord.lon, shape: Self.squareShape())
        }
        #expect(await classifier.removeOverrides(
            kindRaw: HomeAreaOverride.Kind.include.rawValue,
            latitude: Self.village.lat, longitude: Self.village.lon))

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<HomeAreaOverride>()).map(\.id) == [unrelatedID])
        for stay in try fresh.fetch(FetchDescriptor<Stay>()) {
            #expect(stay.category == .unclassified, "\(stay.h3IndexRes6) was claimed only by the withdrawn place")
        }
        #expect(await classifier.removeOverrides(
            kindRaw: HomeAreaOverride.Kind.include.rawValue,
            latitude: Self.village.lat, longitude: Self.village.lon) == false)
    }

    @Test("a failed place removal rolls back every era's row and stay, and a retry succeeds")
    func placeRemovalFailureRollsBackWhole() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let old = insertHome(ctx)
        old.endedAt = date(day: 100)
        let successor = insertHome(ctx, at: Self.movedHome, startDay: 100)
        for owner in [old.id, successor.id] {
            ctx.insert(HomeAreaOverride(
                kind: .include, centerLatitude: Self.village.lat,
                centerLongitude: Self.village.lon, radiusKm: 1, homeID: owner))
        }
        makeStay(in: ctx, day: 1, at: Self.village, category: .home, hex: "OLD")
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        for coord in [Self.home, Self.movedHome] {
            await classifier.primeShapeForTesting(
                latitude: coord.lat, longitude: coord.lon, shape: Self.squareShape())
        }
        classifier.failUnHomeStaysFetchForTesting = true
        #expect(await classifier.removeOverrides(
            kindRaw: HomeAreaOverride.Kind.include.rawValue,
            latitude: Self.village.lat, longitude: Self.village.lon) == false)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try overrides(container).count == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first?.category == .home)

        classifier.failUnHomeStaysFetchForTesting = false
        #expect(await classifier.removeOverrides(
            kindRaw: HomeAreaOverride.Kind.include.rawValue,
            latitude: Self.village.lat, longitude: Self.village.lon))
        #expect(try overrides(container).isEmpty)
    }

    @Test("Undo after a nearby move withdraws the demotion's includes and their copies, keeping earlier teaching")
    func undoWithdrawsCarriedCopies() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = insertHome(ctx, radiusKm: 25, startDay: -10)
        let originalID = original.id
        // Earlier, independent teaching somewhere else.
        let earlier = HomeAreaOverride(
            kind: .include, centerLatitude: Self.hamlet.lat,
            centerLongitude: Self.hamlet.lon, radiusKm: 1, homeID: originalID)
        earlier.createdAt = date(day: -5)
        ctx.insert(earlier)
        let trip = makeVillageTrip(in: ctx, startDay: 0)
        try ctx.save()
        let tripID = trip.id

        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.demoteTripToHomeArea(
            tripID: tripID, tripIdentifier: trip.persistentModelID)
        #expect(try overrides(container).count == 2)

        let result = HomeSaveWorker.apply(
            editPayload(originalID, to: Self.movedHome), context: ctx,
            pendingDefaults: defaults)
        #expect(!result.failed)
        #expect(try overrides(container).count == 4, "both teachings carried to the new Home")

        #expect(await classifier.undoLastDemotion() == .undone)
        let remaining = try overrides(container)
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.centerLatitude == Self.hamlet.lat })
    }
}
