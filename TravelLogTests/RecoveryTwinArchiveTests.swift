//
//  RecoveryTwinArchiveTests.swift
//  TravelLogTests
//
//  Healing never archives UUID twins row by row: two partial records under
//  one id would be pruned together when either is restored. A queue that
//  already holds such records loses neither: Restore removes only its own
//  archive, and every pruning path waits until each archive of an id settled.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor @Suite(IsolatedLineageDefaults())
struct RecoveryTwinArchiveTests {

    private static let day: TimeInterval = 24 * 60 * 60
    private static let home = (lat: 44.3, lon: 12.9)
    private static let village = (lat: 44.3, lon: 13.09)

    private func date(day offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: (offset + 9_500) * Self.day)
    }

    private static func squareShape() -> HomeShape {
        HomeShape.urbanCentre(
            id: 1, name: "TestTown", areaKm2: 100,
            rings: [[[12.85, 44.25, 12.95, 44.25, 12.95, 44.35, 12.85, 44.35]]],
            centreLatitude: home.lat, centreLongitude: home.lon)
    }

    private func makeVillageStay(_ ctx: ModelContext, day: Double) -> Stay {
        let start = date(day: day)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(4 * 3_600),
            centroidLatitude: Self.village.lat, centroidLongitude: Self.village.lon,
            h3IndexRes6: "V", pingCount: 2, distanceFromHomeKm: 15, pingIDs: [])
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeVillageTrip(
        _ ctx: ModelContext, day: Double, id: UUID? = nil, complete: Bool = true
    ) -> Trip {
        let trip = Trip(startDate: date(day: day))
        if let id { trip.id = id }
        trip.endDate = complete ? date(day: day + 0.5) : nil
        trip.isComplete = complete
        ctx.insert(trip)
        let stay = makeVillageStay(ctx, day: day)
        stay.trip = trip
        stay.orderInTrip = 0
        return trip
    }

    private func seedHomeWithIncludedVillage(_ ctx: ModelContext) {
        let home = Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: date(day: -100))
        ctx.insert(home)
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: Self.village.lat,
            centerLongitude: Self.village.lon, radiusKm: 1, homeID: home.id))
    }

    private func record(_ id: UUID, at instant: Double, stays: [Stay]) -> DissolvedTripRecord {
        DissolvedTripRecord(
            id: id, dissolvedAt: date(day: instant), displayName: "Village",
            startDate: date(day: 0), endDate: date(day: 2), isComplete: true,
            destinationSummary: "Village", countryCodes: "", classifiedByAI: false,
            aiGeneratedTitle: nil, aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue, customName: nil, userEdited: false,
            stays: stays.enumerated().map {
                .init(id: $0.element.id, categoryRaw: "destination", orderInTrip: $0.offset)
            })
    }

    private func queueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("twin-archive-queue-\(UUID().uuidString)")
    }

    @Test("healing leaves every row of a trip whose id two rows hold, open or completed, and still dissolves an unambiguous trip",
          arguments: [true, false])
    func healingDefersUUIDTwinCohort(secondTwinComplete: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedHomeWithIncludedVillage(ctx)
        let twinID = UUID()
        let first = makeVillageTrip(ctx, day: 0, id: twinID)
        let second = makeVillageTrip(ctx, day: 1, id: twinID, complete: secondTwinComplete)
        let lone = makeVillageTrip(ctx, day: 10)
        try ctx.save()
        let twinRows = Set([first.persistentModelID, second.persistentModelID])
        let twinStayIDs = Set(((first.stays ?? []) + (second.stays ?? [])).map(\.id))
        let loneID = lone.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let outcome = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(!outcome.failed)
        #expect(outcome.moved == 1)
        #expect(await classifier.drainParkedDissolvedTrips().map(\.id) == [loneID])

        let after = ModelContext(container)
        let trips = try after.fetch(FetchDescriptor<Trip>())
        #expect(Set(trips.map(\.persistentModelID)) == twinRows)
        for stay in try after.fetch(FetchDescriptor<Stay>()) where twinStayIDs.contains(stay.id) {
            #expect(stay.trip?.id == twinID, "each twin keeps its own stay")
            #expect(stay.category == .destination)
        }
    }

    @Test("restoring one of two archives a queue holds under one trip id removes that archive alone, and the other then completes the trip")
    func legacyTwinArchivesRestoreOneAtATime() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeVillageStay(ctx, day: 0)
        let b = makeVillageStay(ctx, day: 1)
        a.category = .home
        b.category = .home
        try ctx.save()
        let tripID = UUID()
        let firstArchive = record(tripID, at: 3, stays: [a])
        let secondArchive = record(tripID, at: 3.000_001, stays: [b])
        let dir = queueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An older build's healing appended both in one batch.
        try DissolvedTripQueue.append([firstArchive, secondArchive], in: dir)
        #expect(DissolvedTripQueue.load(from: dir).count == 2)

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(firstArchive, markStaysSacred: true) == .restored)
        try DissolvedTripQueue.remove(archive: firstArchive, in: dir)
        let left = DissolvedTripQueue.load(from: dir)
        #expect(left.count == 1)
        #expect(left.first?.isSameArchive(as: secondArchive) == true)

        // The other archive's stay is still outstanding: no pruning path takes it.
        let read = ModelContext(container)
        let rows = try read.fetch(FetchDescriptor<Trip>())
        let stays = try read.fetch(FetchDescriptor<Stay>())
        #expect(!TripClassifier.returnedTripIsWhole(secondArchive, rows: rows, stays: stays))
        #expect(await classifier.settleReturnedDissolvedTrips([secondArchive]).isEmpty)

        #expect(await classifier.restoreDissolvedTrip(secondArchive, markStaysSacred: true) == .restored)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 1)
        #expect(Set((trips.first?.stays ?? []).map(\.id)) == [a.id, b.id])
    }

    @Test("an id leaves the queue only once every archive under it settled")
    func idsSettleOnlyWhole() {
        let id = UUID()
        let other = UUID()
        let first = record(id, at: 3, stays: [])
        var second = record(id, at: 4, stays: [])
        second.customName = "Second"
        let lone = record(other, at: 5, stays: [])
        let queued = [first, second, lone]
        #expect(DissolvedTripQueue.idsSettledWhole([first, lone], of: queued) == [other])
        #expect(DissolvedTripQueue.idsSettledWhole([first, second, lone], of: queued) == [id, other])
        #expect(DissolvedTripQueue.idsSettledWhole([], of: queued).isEmpty)
    }

    @Test("the rescue and the settle keep both archives of an id while one cannot settle")
    func rescueAndSettleWaitForEveryArchive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeVillageStay(ctx, day: 0)
        let b = makeVillageStay(ctx, day: 1)
        // Two rows of B's id, one unassigned: its archive cannot settle yet.
        let bTwin = makeVillageStay(ctx, day: 1)
        bTwin.id = b.id
        a.category = .home
        b.category = .home
        try ctx.save()
        let tripID = UUID()
        let firstArchive = record(tripID, at: 3, stays: [a])
        let secondArchive = record(tripID, at: 3.000_001, stays: [b])

        let classifier = TripClassifier(modelContainer: container)
        let rescue = await classifier.rescueDissolvedTrips(
            [firstArchive, secondArchive], pinnedTripIDs: [tripID])
        #expect(rescue.restored == [tripID])
        #expect(rescue.unsettled == [tripID], "the second archive keeps the id queued")
        #expect(await classifier.settleReturnedDissolvedTrips([firstArchive, secondArchive]).isEmpty)

        // Once B's rows converge, the second archive settles too.
        let edit = ModelContext(container)
        let copy = try #require(try edit.fetch(FetchDescriptor<Stay>()).first {
            $0.id == b.id && $0.persistentModelID == bTwin.persistentModelID })
        edit.delete(copy)
        try edit.save()
        let retry = await classifier.rescueDissolvedTrips(
            [firstArchive, secondArchive], pinnedTripIDs: [tripID])
        #expect(retry.unsettled.isEmpty)
        #expect(Set(retry.restored + retry.prunable) == [tripID])
        #expect(await classifier.settleReturnedDissolvedTrips([firstArchive, secondArchive]) == [tripID])
    }

    @Test("re-dissolving a trip one of its two archives brought back leaves the other archive restorable")
    func redissolveKeepsTheOtherArchive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedHomeWithIncludedVillage(ctx)
        let a = makeVillageStay(ctx, day: 0)
        let b = makeVillageStay(ctx, day: 1)
        // Two rows of B's id: its archive cannot come back yet.
        let bTwin = makeVillageStay(ctx, day: 1)
        bTwin.id = b.id
        for stay in [a, b, bTwin] { stay.category = .home }
        try ctx.save()
        let tripID = UUID()
        let firstArchive = record(tripID, at: 3, stays: [a])
        let secondArchive = record(tripID, at: 3.000_001, stays: [b])
        let dir = queueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DissolvedTripQueue.append([firstArchive, secondArchive], in: dir)

        // A late pin rescues the first archive; the second stays queued.
        let classifier = TripClassifier(modelContainer: container)
        let rescue = await classifier.rescueDissolvedTrips(
            DissolvedTripQueue.load(from: dir), pinnedTripIDs: [tripID])
        #expect(rescue.restored == [tripID])
        #expect(rescue.unsettled == [tripID])

        // Unpinned, the restored trip is healed away again and archived anew.
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let heal = await classifier.healHomeAreaCorrections(pinnedTripIDs: [])
        #expect(!heal.failed)
        let parked = await classifier.drainParkedDissolvedTrips()
        #expect(parked.map(\.id) == [tripID])
        try DissolvedTripQueue.append(parked, in: dir)

        // The new archive replaces the first; the second keeps its own.
        let queued = DissolvedTripQueue.load(from: dir)
        #expect(queued.count == 2)
        #expect(queued.contains { $0.isSameArchive(as: secondArchive) })
        #expect(!queued.contains { $0.isSameArchive(as: firstArchive) })
        #expect(queued.contains { $0.stays.map(\.id) == [a.id] && !$0.isSameArchive(as: firstArchive) })

        // Once B's rows converge, its archive brings its stay back.
        let edit = ModelContext(container)
        let copy = try #require(try edit.fetch(FetchDescriptor<Stay>()).first {
            $0.id == b.id && $0.persistentModelID == bTwin.persistentModelID })
        edit.delete(copy)
        try edit.save()
        let second = try #require(queued.first { $0.isSameArchive(as: secondArchive) })
        #expect(await classifier.restoreDissolvedTrip(second, markStaysSacred: true) == .restored)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.map(\.id) == [tripID])
        #expect(trips.first?.stays?.map(\.id) == [b.id])
    }

    @Test("a trip healing left for its UUID twins is healed once they converge, without a fingerprint change of its own")
    func deferredTwinHealingRetriesAfterConvergence() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedHomeWithIncludedVillage(ctx)
        let twinID = UUID()
        let first = makeVillageTrip(ctx, day: 0, id: twinID)
        makeVillageTrip(ctx, day: 1, id: twinID)
        try ctx.save()
        let keptRow = first.persistentModelID

        let classifier = TripClassifier(modelContainer: container)
        await classifier.primeShapeForTesting(
            latitude: Self.home.lat, longitude: Self.home.lon, shape: Self.squareShape())
        let suite = "twin-heal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { stale in
                await classifier.healHomeAreaCorrections(pinnedTripIDs: [], staleCoverage: stale)
            },
            drainParked: { await classifier.drainParkedDissolvedTrips() },
            classify: { true },
            generateTitles: {},
            coverage: { try await classifier.homeAreaCoverage() },
            bumpChanges: {},
            reloadWidgets: {})

        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 2)
        let deferredStamp = defaults.string(forKey: HomeAreaHealing.fingerprintKey)
        #expect(deferredStamp != nil)

        // The twins converge onto one row holding both stays.
        let edit = ModelContext(container)
        let rows = try edit.fetch(FetchDescriptor<Trip>())
        let kept = try #require(rows.first { $0.persistentModelID == keptRow })
        for row in rows where row.persistentModelID != keptRow {
            for stay in row.stays ?? [] {
                stay.trip = kept
                stay.orderInTrip = 1
            }
            edit.delete(row)
        }
        try edit.save()

        #expect(await classifier.homeAreaFingerprint() != deferredStamp)
        #expect(await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: stages))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
    }

    @Test("removing one archive keeps the queue's bytes when the file is unreadable")
    func archiveRemovalFailsClosed() throws {
        let dir = queueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(DissolvedTripQueue.fileURL(in: dir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) {
            try DissolvedTripQueue.remove(archive: record(UUID(), at: 3, stays: []), in: dir)
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
